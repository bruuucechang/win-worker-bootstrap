#Requires -Version 5.1
<#
  verify.ps1 - 檢查這台機器夠不夠格當 worker。唯讀，不改任何東西，可以隨時重跑。

      .\scripts\verify.ps1

  從 Mac 用 SSH 跑的話，前面加一行讓中文輸出看得懂：
      powershell -NoProfile -Command "chcp 65001 > $null; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); & C:\path\verify.ps1"
#>
[CmdletBinding()]
param([string]$TargetUser = $env:USERNAME)

$pass = 0; $fail = 0; $warn = 0
# 函式名不要用單字母：PowerShell 的【別名優先於函式】，而 h 是 Get-History 的別名，
# 用 H 當標題函式會變成 "Get-History 身分" 然後噴型別轉換錯誤。
function Good($m){ Write-Host "  [OK]   $m" -ForegroundColor Green;  $script:pass++ }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fail++ }
function Meh($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function Sec($m) { Write-Host "`n$m" -ForegroundColor Cyan }

Sec "身分"
Write-Host "  $env:COMPUTERNAME / $TargetUser / $((Get-CimInstance Win32_OperatingSystem).Caption)"
$cs = Get-CimInstance Win32_ComputerSystem
Write-Host ("  核心 {0} · 記憶體 {1} GB" -f $env:NUMBER_OF_PROCESSORS, [int]($cs.TotalPhysicalMemory/1GB))
if([int]($cs.TotalPhysicalMemory/1GB) -ge 8){ Good "記憶體 >= 8 GB" } else { Meh "記憶體偏小，重活丟過來不一定划算" }

Sec "可以被連進來"
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if($cap.State -eq 'Installed'){ Good "OpenSSH Server 已安裝" } else { Bad "OpenSSH Server 沒裝（跑 setup.ps1）" }

$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if(-not $sshd){ Bad "sshd 服務不存在（多半是裝完還沒重開機）" }
else {
  if($sshd.Status -eq 'Running'){ Good "sshd 執行中" } else { Bad "sshd 沒在跑" }
  if($sshd.StartType -eq 'Automatic'){ Good "sshd 開機自動啟動" } else { Meh "sshd 不是自動啟動，重開機後連不進來" }
}

if(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue){ Good "防火牆放行 TCP 22" }
else { Bad "防火牆沒有 22 的規則" }

$adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name
$members = @(Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$isAdmin = $members -contains "$env:COMPUTERNAME\$TargetUser"
$keyPath = if($isAdmin){ "$env:ProgramData\ssh\administrators_authorized_keys" }
           else { "$env:SystemDrive\Users\$TargetUser\.ssh\authorized_keys" }

if(Test-Path $keyPath){
  $keys = @(Get-Content $keyPath | Where-Object { $_ -match '^(ssh-|ecdsa-)' })
  if($keys.Count -gt 0){ Good "authorized_keys 有 $($keys.Count) 把金鑰（$keyPath）" }
  else { Bad "$keyPath 裡沒有看起來像公鑰的行" }

  $bytes = [IO.File]::ReadAllBytes($keyPath)
  if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){
    Bad "authorized_keys 開頭有 BOM，sshd 會把第一把金鑰當壞掉的略過"
  } else { Good "authorized_keys 沒有 BOM" }

  $acl = (icacls $keyPath) -join "`n"
  if($acl -match 'Everyone|Authenticated Users|BUILTIN\\Users|\bUsers:'){
    Bad "authorized_keys 的 ACL 太寬（看到 Users/Everyone），sshd 會靜默不採用"
  } else { Good "authorized_keys 的 ACL 看起來夠緊" }
} else {
  Bad "找不到 $keyPath（沒有公鑰就只能打密碼）"
}

Sec "不會睡著"
# powercfg 的輸出是在地化的（中文版是「目前的 AC 電源設定索引」），
# 所以不能比對英文字串。抓 AC 那一行的十六進位值；抓不到就退回「倒數第二個」，
# 因為輸出順序固定是 最小/最大/增量/AC/DC。
$q = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
$acLine = $q | Where-Object { $_ -match '(?<![A-Za-z])AC(?![A-Za-z])' } | Select-Object -First 1
$hexAll = @($q | Select-String -Pattern '0x[0-9a-fA-F]{8}' -AllMatches |
           ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
$acHex = $null
if($acLine -and $acLine -match '(0x[0-9a-fA-F]{8})'){ $acHex = $Matches[1] }
elseif($hexAll.Count -ge 2){ $acHex = $hexAll[$hexAll.Count - 2] }

if(-not $acHex){ Meh "讀不到休眠設定，自己確認一次：powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE" }
elseif([Convert]::ToInt64($acHex,16) -eq 0){ Good "接電源時不休眠" }
else {
  $mins = [int]([Convert]::ToInt64($acHex,16) / 60)
  Bad "接電源 $mins 分鐘後會休眠，睡著就連不進來（跑 setup.ps1，或 powercfg /change standby-timeout-ac 0）"
}

Sec "工具"
foreach($t in 'git','node','python','docker','claude'){
  $c = Get-Command $t -ErrorAction SilentlyContinue
  if($c){ Good "$t -> $($c.Source)" }
  elseif($t -eq 'claude'){ Meh "claude 沒裝（只在要派 Claude Code 工作時才需要）" }
  elseif($t -eq 'docker'){ Meh "docker 沒裝（只在要跑服務時才需要）" }
  else { Bad "$t 沒裝或還沒進 PATH（剛裝完要新開殼層）" }
}

Sec "git 作者身分"
if(Get-Command git -ErrorAction SilentlyContinue){
  $n = git config --global user.name
  $e = git config --global user.email
  if($n -and $e){ Good "git 身分：$n <$e>" } else { Bad "git 身分沒設（推出去的 commit 會掛錯作者）" }
} else { Meh "沒有 git，跳過" }

Sec "網路位址（指揮端要用哪一個）"
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' } |
  Select-Object IPAddress, InterfaceAlias, PrefixOrigin | Format-Table -AutoSize
Write-Host "  只有真的網卡（Wi-Fi / 乙太網路）那行有用；vEthernet (WSL...) 那種是虛擬的，連不到。"
Write-Host "  DHCP 的位址會變號，長期用建議在路由器設固定配發，或改走 Tailscale。"

Sec "殼層與編碼（指揮端會踩到的）"
Write-Host "  PowerShell $($PSVersionTable.PSVersion)"
Write-Host "  SSH 預設殼層 : $env:COMSPEC （cmd 的 cd 不換磁碟機，要用 cd /d）"
Write-Host "  主控台碼頁   : $((chcp) -replace '\D','')"

Sec "結果"
Write-Host "  OK $pass · WARN $warn · FAIL $fail"
if($fail -gt 0){
  Write-Host "  有 FAIL，先解掉再叫指揮端接。" -ForegroundColor Red
  exit 1
}
Write-Host "  可以叫指揮端從 Mac 那邊試連了。" -ForegroundColor Green
exit 0
