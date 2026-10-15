# komorebi の起動と停止を、半透明の後始末と一緒に行う。
#
#   komorebi-ctl.ps1 start            窓を不透明に戻してから komorebi を起動する
#   komorebi-ctl.ps1 stop             komorebi を止め、窓を不透明に戻す
#   komorebi-ctl.ps1 restore-opacity  窓を不透明に戻すだけ
#   komorebi-ctl.ps1 install-rdp-task RDP で接続したら stop を走らせるタスクを登録する
#
# なぜ: komorebi v0.1.41 は、管理から外れた窓に付けた半透明（WS_EX_LAYERED と alpha）を
# 外さない。komorebi を止めても、komorebic transparency disable でも戻らない
# （LGUG2Z/komorebi#1749、2026-10-15 時点で未修正）。RDP で画面構成が変わると、
# ワークスペースの設定外れ（静的設定を当て直す処理が無い）と最小化窓の残留（#1673）も
# 起きるので、RDP 中は komorebi を止めて、手元に戻ったら手で起動する運用にした。
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restore-opacity', 'install-rdp-task')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$ConfigPath = Join-Path $HOME '.config\komorebi\komorebi.json'
$LogDir = Join-Path $env:LOCALAPPDATA 'komorebi'
$LogPath = Join-Path $LogDir 'komorebi-ctl.log'
$TaskName = 'komorebi-stop-on-rdp'

function Write-Log([string]$Message) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    Add-Content -Path $LogPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1} {2}" -f (Get-Date), $Action, $Message) -Encoding utf8
}

function Get-TransparencyAlpha {
    # komorebi.json の transparency_alpha。未設定なら komorebi の既定値 200。
    try {
        $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        if ($null -ne $config.transparency_alpha) { return [int]$config.transparency_alpha }
    } catch {
        Write-Log "komorebi.json を読めない: $_"
    }
    return 200
}

function Restore-Opacity {
    if (-not ('KomorebiCtl.User32' -as [type])) {
        Add-Type -Namespace KomorebiCtl -Name User32 -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(System.IntPtr h, out uint key, out byte a, out uint f);
'@
    }
    $GWL_EXSTYLE = -20
    $WS_EX_LAYERED = 0x80000
    $LWA_ALPHA = 2
    $alpha = Get-TransparencyAlpha

    # komorebi が付けた半透明だけを外す。目印は「LWA_ALPHA で alpha が設定値と同じ」。
    # alpha 0 で自分を隠している窓（Eagle、Raycast など）や、UpdateLayeredWindow で
    # 描くアプリ（GetLayeredWindowAttributes が失敗する）には触らない。
    # 外し方は komorebi の Window::opaque と同じく、WS_EX_LAYERED を落とす。
    $targets = New-Object System.Collections.Generic.List[System.IntPtr]
    $callback = [KomorebiCtl.User32+EnumProc] {
        param($hwnd, $lparam)
        $ex = [KomorebiCtl.User32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
        if (($ex -band $WS_EX_LAYERED) -ne 0) {
            $key = 0; $a = 0; $flags = 0
            if ([KomorebiCtl.User32]::GetLayeredWindowAttributes($hwnd, [ref]$key, [ref]$a, [ref]$flags) -and
                ($flags -band $LWA_ALPHA) -ne 0 -and $a -eq $alpha) {
                $targets.Add($hwnd)
            }
        }
        return $true
    }
    [KomorebiCtl.User32]::EnumWindows($callback, [System.IntPtr]::Zero) | Out-Null

    foreach ($hwnd in $targets) {
        $ex = [KomorebiCtl.User32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
        [KomorebiCtl.User32]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($ex -band (-bnot $WS_EX_LAYERED))) | Out-Null
    }
    Write-Log ("alpha={0} の窓を {1} 枚不透明に戻した" -f $alpha, $targets.Count)
}

function Stop-Komorebi {
    komorebic.exe stop --whkd 2>&1 | ForEach-Object { Write-Log "komorebic: $_" }
    # 窓の後始末は komorebi の終了を待ってから行う。動いているうちに外すと、
    # komorebi がフォーカスの変化でまた半透明を付けることがある。
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Process -Name komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (Get-Process -Name komorebi -ErrorAction SilentlyContinue) {
        Write-Log 'komorebi が10秒以内に終わらなかった'
    }
    Restore-Opacity
}

function Start-Komorebi {
    if (Get-Process -Name komorebi -ErrorAction SilentlyContinue) {
        Write-Log 'komorebi は動いている。起動しない'
        return
    }
    Restore-Opacity
    komorebic.exe start --whkd 2>&1 | ForEach-Object { Write-Log "komorebic: $_" }
}

function Install-RdpTask {
    # 「リモートで接続したとき」は、タスクスケジューラの組み込みのトリガー
    # （SessionStateChange の RemoteConnect）で受ける。対象は自分のユーザーだけ。
    $pwsh = (Get-Command pwsh.exe).Source
    $script = Join-Path $HOME '.config\komorebi\komorebi-ctl.ps1'
    $class = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
    $trigger = New-CimInstance -CimClass $class -ClientOnly -Property @{
        StateChange = 3  # TASK_SESSION_STATE_CHANGE_TYPE の TASK_REMOTE_CONNECT
        UserId      = "$env:USERDOMAIN\$env:USERNAME"
        Enabled     = $true
    }
    # $action だと引数の $Action と同じ変数になる（PowerShell は大小を区別しない）
    $taskAction = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -File `"$script`" stop"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    Register-ScheduledTask -TaskName $TaskName -Trigger $trigger -Action $taskAction -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "タスク $TaskName を登録した"
}

switch ($Action) {
    'start' { Start-Komorebi }
    'stop' { Stop-Komorebi }
    'restore-opacity' { Restore-Opacity }
    'install-rdp-task' { Install-RdpTask }
}
