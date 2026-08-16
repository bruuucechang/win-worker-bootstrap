#Requires -Version 5.1
<#
  setup.ps1 - 把這台 Windows 桌機設定成一台可以被 Mac 透過 SSH 指揮的 worker。

  用法（在「以系統管理員身分執行」的 PowerShell 裡跑）：

      .\scripts\setup.ps1 -PublicKey "ssh-ed25519 AAAA... me@mac" `
                          -GitUserName "your-name" -GitUserEmail "you@example.com"

  常用選項：
      -DryRun            只印出會做什麼，不動任何東西
      -SkipTools         不裝 git / node / python / Docker
      -SkipDocker        裝其他工具但跳過 Docker Desktop
      -TargetUser <名稱> 公鑰要裝給哪個帳號（預設是現在這個）

  重跑是安全的：每一步都會先看現況，已經好了就跳過。
#>
[CmdletBinding()]
param(
  [string]$PublicKey,
  [string]$PublicKeyFile,
  [string]$GitUserName,
  [string]$GitUserEmail,
  [string]$TargetUser = $env:USERNAME,
  [switch]$SkipTools,
  [switch]$SkipDocker,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:RestartNeeded = $false
$script:Todo = New-Object System.Collections.Generic.List[string]

function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Skip($m){ Write-Host "  [--] $m" -ForegroundColor DarkGray }
function Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Todo($m){ $script:Todo.Add($m); Warn $m }
function Act([string]$what, [scriptblock]$do){
  if($DryRun){ Write-Host "  [dry] $what" -ForegroundColor Magenta; return }
  & $do; OK $what
}

# ---------------------------------------------------------------- 0. 前置檢查
Step "0/7 前置檢查"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
  throw "這支腳本要在「以系統管理員身分執行」的 PowerShell 裡跑。右鍵 PowerShell -> 以系統管理員身分執行，再跑一次。"
}
OK "提權執行中"

if($PublicKeyFile){
  if(-not (Test-Path $PublicKeyFile)){ throw "找不到 -PublicKeyFile 指定的檔案：$PublicKeyFile" }
  $PublicKey = (Get-Content $PublicKeyFile -Raw).Trim()
}
if($PublicKey){
  if($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) '){
    throw "-PublicKey 看起來不像公鑰。要貼的是 .pub 的內容（ssh-ed25519 AAAA... 開頭），不是私鑰。"
  }
  if($PublicKey -match 'PRIVATE KEY'){ throw "你貼的是私鑰。停。要用的是 ~/.ssh/id_ed25519.pub 的內容。" }
  OK "公鑰格式看起來正確"
} else {
  Todo "沒有給 -PublicKey，SSH 會裝但沒有人能免密碼登入。之後補：把 Mac 的 ~/.ssh/id_ed25519.pub 內容再跑一次這支腳本。"
}

Write-Host "  目標帳號：$TargetUser    電腦名稱：$env:COMPUTERNAME"

# ---------------------------------------------------------------- 1. OpenSSH Server
Step "1/7 OpenSSH Server"

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if($cap.State -eq 'Installed'){
  Skip "已安裝"
} else {
  if($DryRun){
    Write-Host "  [dry] Add-WindowsCapability -Online -Name $($cap.Name)" -ForegroundColor Magenta
  } else {
    $r = Add-WindowsCapability -Online -Name $cap.Name
    OK "已安裝 $($cap.Name)"
    # 這裡是最容易誤判的一步：元件裝好了，但 sshd 服務要重開機才註冊。
    # 線索在這個回傳值裡，不在後面那些「找不到服務」的錯誤訊息裡。
    if($r.RestartNeeded){
      $script:RestartNeeded = $true
      Todo "OpenSSH 回報 RestartNeeded=True：sshd 服務要重開機才會註冊。重開機後再跑一次這支腳本。"
    }
  }
}

# ---------------------------------------------------------------- 2. sshd 服務與防火牆
Step "2/7 sshd 服務與防火牆"

$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if(-not $sshd){
  if($script:RestartNeeded){
    Warn "sshd 還沒註冊（預期中，要先重開機）"
  } else {
    Todo "找不到 sshd 服務，而且沒有 RestartNeeded。先重開機再跑一次；還是沒有的話手動確認 OpenSSH.Server 是否真的安裝完成。"
  }
} else {
  if($sshd.StartType -ne 'Automatic'){
    Act "sshd 設為自動啟動" { Set-Service -Name sshd -StartupType Automatic }
  } else { Skip "sshd 已是自動啟動" }

  if($sshd.Status -ne 'Running'){
    Act "啟動 sshd" { Start-Service sshd }
  } else { Skip "sshd 已在執行" }
}

$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if($rule){
  Skip "防火牆規則已存在"
} else {
  Act "開防火牆 TCP 22" {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
      -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
  }
}

# ---------------------------------------------------------------- 3. 公鑰
Step "3/7 公鑰"

if($PublicKey){
  # 帳號是系統管理員的話，sshd 的 Match Group administrators 會【完全忽略】
  # ~/.ssh/authorized_keys，只讀 ProgramData 那一份。放錯地方的症狀是一直問密碼。
  $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name
  $members = @(Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Name })
  $isTargetAdmin = $members -contains "$env:COMPUTERNAME\$TargetUser"

  if($isTargetAdmin){
    $keyPath = "$env:ProgramData\ssh\administrators_authorized_keys"
    Write-Host "  $TargetUser 是系統管理員 -> 用 $keyPath"
  } else {
    $profileDir = (Get-CimInstance Win32_UserProfile |
      Where-Object { $_.LocalPath -like "*\$TargetUser" } | Select-Object -First 1).LocalPath
    if(-not $profileDir){ throw "找不到 $TargetUser 的使用者目錄。那個帳號登入過一次了嗎？" }
    $keyPath = "$profileDir\.ssh\authorized_keys"
    Write-Host "  $TargetUser 不是系統管理員 -> 用 $keyPath"
  }

  $exists = (Test-Path $keyPath) -and ((Get-Content $keyPath -ErrorAction SilentlyContinue) -contains $PublicKey)
  if($exists){
    Skip "這把公鑰已經在裡面了"
  } else {
    Act "寫入公鑰" {
      $dir = Split-Path $keyPath -Parent
      if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      # 一定要 UTF8 無 BOM：sshd 不吃 BOM，會把整行當成壞掉的金鑰而靜默略過。
      $lines = @()
      if(Test-Path $keyPath){ $lines = @(Get-Content $keyPath) }
      $lines += $PublicKey
      [IO.File]::WriteAllLines($keyPath, $lines, (New-Object Text.UTF8Encoding($false)))
    }
    # ACL 太寬 sshd 會【靜默】不採用，症狀一樣是一直問密碼。用 SID 不用名稱，
    # 因為中文版 Windows 的群組顯示名稱不是 Administrators。
    Act "收緊 ACL（只留 Administrators 與 SYSTEM）" {
      icacls $keyPath /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    }
  }
} else {
  Skip "沒有公鑰可裝"
}

# ---------------------------------------------------------------- 4. 電源
Step "4/7 電源（睡著的 worker 等於不存在）"

Act "接電源時不休眠、硬碟不停轉" {
  powercfg /change standby-timeout-ac 0   | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  powercfg /change disk-timeout-ac 0      | Out-Null
}
Write-Host "  （螢幕逾時沒有動，那個不影響 SSH）"

# ---------------------------------------------------------------- 5. 工具
Step "5/7 工具"

if($SkipTools){
  Skip "-SkipTools，跳過"
} elseif(-not (Get-Command winget -ErrorAction SilentlyContinue)){
  Todo "找不到 winget，工具沒裝。從 Microsoft Store 更新「應用程式安裝程式」後重跑，或自己裝 git/node/python。"
} else {
  $pkgs = @(
    @{ Id = 'Git.Git';            Cmd = 'git';    Name = 'Git' },
    @{ Id = 'OpenJS.NodeJS.LTS';  Cmd = 'node';   Name = 'Node.js LTS' },
    @{ Id = 'Python.Python.3.12'; Cmd = 'python'; Name = 'Python 3.12' },
    # jq 是 Claude Code 的 PreToolUse 掛勾（擋錯作者的 commit）用的。沒有它的話
    # 那個掛勾每次 git commit 都會炸——而症狀出現在 commit 當下，離「機器沒裝好」很遠。
    @{ Id = 'jqlang.jq';          Cmd = 'jq';     Name = 'jq' }
  )
  if(-not $SkipDocker){
    $pkgs += @{ Id = 'Docker.DockerDesktop'; Cmd = 'docker'; Name = 'Docker Desktop' }
  }

  $installed = @()
  foreach($p in $pkgs){
    if(Get-Command $p.Cmd -ErrorAction SilentlyContinue){
      Skip "$($p.Name) 已安裝"
    } else {
      Act "安裝 $($p.Name)" {
        winget install --id $p.Id --silent --accept-package-agreements --accept-source-agreements | Out-Null
      }
      $installed += $p.Name
    }
  }
  # 這兩條只有真的裝了東西才提醒——每次重跑都噴一樣的待辦，人就不會再讀它了。
  if($installed -contains 'Docker Desktop'){
    Todo "Docker Desktop 第一次要手動開一次（會裝 WSL 元件並可能要求重開機）。裝完在桌面登入一次，SSH 這側才用得到。"
  }
  if($installed.Count -gt 0){
    Todo "剛裝的（$($installed -join '、')）要新開一個殼層才會進 PATH。這個視窗裡找不到不是失敗。"
  }
}

# ---------------------------------------------------------------- 6. git 身分
Step "6/7 git 作者身分"

if($GitUserName -and $GitUserEmail){
  if(Get-Command git -ErrorAction SilentlyContinue){
    Act "git config --global user.name / user.email" {
      git config --global user.name  $GitUserName
      git config --global user.email $GitUserEmail
    }
  } else {
    Todo "git 還沒進 PATH，身分沒設成。新開一個殼層跑：git config --global user.name `"$GitUserName`"; git config --global user.email `"$GitUserEmail`""
  }
} else {
  Todo "沒給 -GitUserName / -GitUserEmail。身分沒設的話，這台推出去的 commit 會掛在錯的作者底下。"
}

# ---------------------------------------------------------------- 7. 摘要
Step "7/7 摘要"

# 不過濾的話會列出一堆 169.254.x 與 WSL/Hyper-V 的虛擬網卡；帶上介面名稱，
# 指揮端才看得出該連哪一個。
$ips = @(Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' -and $_.InterfaceAlias -notlike 'vEthernet*' } |
  ForEach-Object { "$($_.IPAddress) ($($_.InterfaceAlias))" })

Write-Host ""
Write-Host "  電腦名稱  : $env:COMPUTERNAME"
Write-Host "  帳號      : $TargetUser"
Write-Host "  位址      : $($ips -join '  |  ')"
Write-Host "  sshd      : $((Get-Service sshd -ErrorAction SilentlyContinue).Status)"
Write-Host ""
Write-Host "  在 Mac 那邊接著做："
Write-Host "    ssh $TargetUser@<上面其中一個位址> `"echo ok`""
Write-Host "    （通了就把它寫進 ~/.ssh/config，別名要短）"
Write-Host ""

if($script:Todo.Count -gt 0){
  Write-Host "  還沒完成的事（$($script:Todo.Count) 項）：" -ForegroundColor Yellow
  $i = 1
  foreach($t in $script:Todo){ Write-Host "   $i. $t" -ForegroundColor Yellow; $i++ }
  Write-Host ""
}
if($script:RestartNeeded){
  Write-Host "  ** 要重開機，然後再跑一次這支腳本。**" -ForegroundColor Yellow
  Write-Host ""
}

Write-Host "  驗收：.\scripts\verify.ps1" -ForegroundColor Cyan
Write-Host ""
