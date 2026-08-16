# win-worker-bootstrap

把一台 **Windows 桌機**設定成可以被另一台電腦（我的情況是 MacBook）透過 SSH 指揮的
worker——跑那台跑不動、或只有 Windows 能跑的東西。

跑完之後：Mac 可以免密碼 SSH 進來下指令、傳檔、把長工丟過來，而且機器不會睡著。

這個 repo **刻意是公開的、也刻意不含任何機器資訊**——沒有 IP、沒有主機名、沒有帳號、
沒有金鑰。全部從參數傳進去。原因很單純：新機器上還沒有任何 GitHub 認證，
私有 repo 在那個當下 clone 不下來。

---

## 用法

在那台 Windows 桌機上，**用「以系統管理員身分執行」的 PowerShell**：

```powershell
git clone https://github.com/<你的帳號>/win-worker-bootstrap.git
cd win-worker-bootstrap
.\scripts\setup.ps1 -PublicKey "ssh-ed25519 AAAA...換成你的公鑰... me@mac" `
                    -GitUserName "your-name" -GitUserEmail "you@example.com"
.\scripts\verify.ps1
```

沒有 `git` 也沒關係：GitHub 頁面右上角 **Code → Download ZIP**，解壓縮之後一樣跑。
（`setup.ps1` 會幫你把 git 裝起來。）

**公鑰去哪裡拿**：在指揮端的 Mac 上 `cat ~/.ssh/id_ed25519.pub`，整行複製。
沒有的話先 `ssh-keygen -t ed25519`。**貼過去的是 `.pub` 那個檔，不是私鑰。**

### 選項

| | |
|---|---|
| `-DryRun` | 只印出會做什麼，不動任何東西。第一次跑之前建議先看一遍 |
| `-SkipTools` | 不裝 git / node / python / Docker |
| `-SkipDocker` | 裝其他工具但跳過 Docker Desktop |
| `-PublicKeyFile <路徑>` | 公鑰從檔案讀，不想在指令列上貼一長串時用 |
| `-TargetUser <帳號>` | 公鑰要裝給哪個帳號（預設是現在登入的這個） |

**重跑是安全的。** 每一步都先看現況，已經好了就跳過。事實上第一次多半**要跑兩次**——
OpenSSH 裝完需要重開機（見下）。

---

## 它做了什麼

| 步驟 | 內容 |
|---|---|
| 1 | 安裝 OpenSSH Server（Windows 內建功能，不是另外下載的東西） |
| 2 | `sshd` 設成開機自動啟動 + 開防火牆 TCP 22 |
| 3 | 把公鑰寫進**正確的**檔案並收緊 ACL（見下面「三個靜默失敗」） |
| 4 | 接電源時不休眠、硬碟不停轉 |
| 5 | `winget` 裝 Git / Node.js LTS / Python / Docker Desktop |
| 6 | 設 git 作者身分（`--global`） |
| 7 | 印出摘要、還沒完成的事、以及指揮端接著要下的指令 |

它**不做**的事：不裝 Tailscale（要跨網段自己裝，然後用 `100.x` 位址）、
不裝 Claude Code、不碰你的專案、不改預設殼層。

---

## 三個靜默失敗（這支腳本存在的主要理由）

這三個都**看起來成功了**，錯誤要到很後面才浮出來。手動接過一次的人都踩過：

**1. OpenSSH 裝完要重開機，但錯誤訊息不會這樣講。**
`Add-WindowsCapability` 會回 `RestartNeeded : True`——元件裝好了，但 `sshd` 服務
**要重開機才註冊**。串在後面的指令會全部報「找不到服務」，看起來像安裝失敗。
**線索在它自己的回傳值裡，不在那些錯誤訊息裡。** 腳本會把這件事明講出來。

**2. 帳號是系統管理員的話，公鑰放 `~/.ssh/authorized_keys` 完全沒用。**
`sshd_config` 的 `Match Group administrators` 會忽略那個檔，只讀
`C:\ProgramData\ssh\administrators_authorized_keys`。**症狀是一直問密碼**，
而不是任何「找不到金鑰」的訊息。腳本會判斷帳號身分再決定寫哪一份。

**3. 那個檔的權限太寬，`sshd` 會靜默不採用。**
必須只給 Administrators 與 SYSTEM。**症狀還是一直問密碼**，跟上一條分不開。
腳本用 SID（`*S-1-5-32-544`）而不是群組名稱去設，因為非英文版 Windows 的
群組顯示名稱不是 `Administrators`。

（順帶第四個：`authorized_keys` **不能有 BOM**。PowerShell 的 `Out-File -Encoding utf8`
在 5.1 一定帶 BOM，寫出來 sshd 會把第一把金鑰當壞掉的略過。腳本用
`UTF8Encoding($false)` 寫，`verify.ps1` 也會檢查這件事。）

---

## 驗收

`verify.ps1` 是唯讀的，隨時可以重跑。它檢查：OpenSSH 裝了沒、`sshd` 在不在跑、
防火牆、公鑰檔位置／內容／BOM／ACL、會不會睡著、工具在不在、git 身分、
以及**指揮端該用哪個 IP**（會過濾掉 `169.254.x` 與 WSL／Hyper-V 的虛擬網卡——
不過濾的話一台機器可能吐出九個位址，真正能連的只有一個）。

有 `FAIL` 就 `exit 1`，可以直接串在別的腳本後面。

然後在**指揮端**那邊驗一次，兩邊都過才算接好：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=6 <帳號>@<位址> 'echo ok'
```

`BatchMode=yes` 是關鍵：它讓「其實還在等密碼」直接失敗，
而不是掛在那裡看起來像連線比較慢。

---

## 接好之後，指揮端要知道的事

| | |
|---|---|
| **預設殼層是 `cmd.exe`** | `cd` **不換磁碟機**，要 `cd /d D:\...`。少了 `/d` 會在 `C:\Users\<帳號>` 底下跑 git，回 `not a git repository`，看起來像 repo 不見了 |
| **PowerShell 5.1 的編碼** | `Get-Content` 預設用系統 ANSI 讀（中文系統會把 UTF-8 的中文讀成亂碼）；`>` 重導向產生 **UTF-16**，unix 的 grep 讀不到 |
| **含中文的 `.ps1` 要存成帶 BOM 的 UTF-8** | 否則 PowerShell 5.1 會用 ANSI 讀、把引號吃掉，症狀是**整支腳本一行都沒跑**、離開碼 1 |
| **SSH 是 session 0，桌面是 session 1** | 從 SSH 碰不到桌面的視窗。要動 GUI 得用 `schtasks /ru <帳號> /it`，而且腳本要自己寫 log |
| **傳大檔用 `scp`** | 不要用 `ssh ... Get-Content` 拉，會卡到逾時。Windows 那端路徑寫 `user@host:D:/path` |

指令複雜到引號要巢狀的時候，**寫成 `.ps1` 用 `scp` 傳過去再 `powershell -File` 跑**，
比在引號裡搏鬥快得多。

---

## 疑難排解

| 症狀 | 多半是 |
|---|---|
| 一直問密碼 | 公鑰放錯檔案（靜默失敗 2）、ACL 太寬（3）、或檔案有 BOM。跑 `verify.ps1` |
| `找不到 sshd 服務` | 還沒重開機（靜默失敗 1） |
| 連線逾時、密碼提示都沒有 | 防火牆，或位址用到了虛擬網卡那個 |
| 昨天還連得到，今天連不到 | DHCP 換號了。路由器設固定配發，或改用 Tailscale |
| SSH 進來的程序在斷線後死掉 | 正常行為。長工要讓連線一直開著，或用排程工作 |

## 授權

MIT
