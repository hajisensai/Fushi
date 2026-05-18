<#
.SYNOPSIS
  Hibiki cross-platform debug tool - trigger app events via API calls without mouse/click.
  Supports Android (ADB) and Flutter VM Service (all platforms).

.DESCRIPTION
  Directly calls system and app APIs to trigger events. No coordinate-based input.
  All events produce formatted output: [timestamp] [backend] [category/action] params → result

.EXAMPLE
  .\hibiki-debug.ps1 search 猫                    # Trigger WEB_SEARCH intent
  .\hibiki-debug.ps1 share "テスト文章"            # Trigger SEND intent
  .\hibiki-debug.ps1 process-text 食べる           # Trigger PROCESS_TEXT
  .\hibiki-debug.ps1 volume-up 3                   # Volume up 3 times (reader page turn)
  .\hibiki-debug.ps1 float-dict start              # Start floating dictionary service
  .\hibiki-debug.ps1 launch                        # Launch app
  .\hibiki-debug.ps1 pause                         # Send to background
  .\hibiki-debug.ps1 prefs fontSize                # Read preference
  .\hibiki-debug.ps1 prefs fontSize 22             # Set preference
  .\hibiki-debug.ps1 activity                      # Current activity info
  .\hibiki-debug.ps1 logcat dict                   # Filtered logcat
  .\hibiki-debug.ps1 eval "1+1"                    # Evaluate via VM service
  .\hibiki-debug.ps1 script commands.txt           # Run batch commands
  .\hibiki-debug.ps1 -Backend vm -VmUrl "http://127.0.0.1:xxxxx" eval "expr"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet(
        'search', 'share', 'process-text', 'media-search',
        'volume-up', 'volume-down', 'media-play', 'media-pause', 'media-next', 'media-prev',
        'launch', 'stop', 'pause', 'resume', 'restart',
        'float-dict', 'float-lyric', 'audio-service',
        'prefs', 'db-query',
        'logcat', 'crash-log', 'activity', 'memory', 'processes', 'pid',
        'eval', 'reload', 'widget-tree',
        'broadcast', 'key', 'ime-text',
        'script', 'help'
    )]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments,

    [ValidateSet('android', 'vm', 'auto')]
    [string]$Backend = 'auto',

    [string]$Device = '',
    [string]$Package = 'app.hibiki.reader',
    [string]$VmUrl = '',
    [switch]$Quiet,
    [switch]$Raw
)

# ─── Output Formatting ───────────────────────────────────────────────────────

$script:EventLog = @()

function Format-Event {
    param(
        [string]$BackendName,
        [string]$Category,
        [string]$Action,
        [hashtable]$Params = @{},
        [string]$Result,
        [string]$Status = 'OK'
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $paramStr = ($Params.GetEnumerator() | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }) -join " "

    $entry = [PSCustomObject]@{
        Timestamp = $ts
        Backend   = $BackendName
        Category  = $Category
        Action    = $Action
        Params    = $paramStr
        Status    = $Status
        Result    = $Result
    }
    $script:EventLog += $entry

    if (-not $Quiet) {
        $statusIcon = switch ($Status) {
            'OK'    { '+' }
            'WARN'  { '!' }
            'ERROR' { 'X' }
            default { '?' }
        }
        $line = "[$ts] [$BackendName] [$Category/$Action] $paramStr -> [$statusIcon] $Result"
        if ($Status -eq 'ERROR') {
            Write-Error $line
        } elseif ($Status -eq 'WARN') {
            Write-Warning $line
        } else {
            Write-Output $line
        }
    }

    if ($Raw) { return $entry }
}

# ─── Backend Detection ────────────────────────────────────────────────────────

function Resolve-Backend {
    if ($Backend -ne 'auto') { return $Backend }
    if ($VmUrl) { return 'vm' }

    $adbCheck = $null
    try { $adbCheck = & adb devices 2>$null } catch {}
    if ($adbCheck -and ($adbCheck | Select-String "device$")) {
        return 'android'
    }

    Write-Error "No backend available. Connect Android device or provide -VmUrl."
    return $null
}

function Resolve-Device {
    if ($Device) { return $Device }
    $lines = & adb devices 2>$null | Where-Object { $_ -match '\s+device$' }
    if ($lines) {
        $first = ($lines[0] -split '\s+')[0]
        return $first
    }
    return 'emulator-5554'
}

# ─── Android Backend ──────────────────────────────────────────────────────────

function Adb-Shell {
    param([string]$Cmd)
    $dev = Resolve-Device
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $output = & adb -s $dev shell $Cmd 2>$null
    $ErrorActionPreference = $prevEAP
    return ($output -join "`n").Trim()
}

function Adb-Intent {
    param(
        [string]$Action,
        [string]$Category = 'android.intent.category.DEFAULT',
        [string]$Component = '',
        [hashtable]$Extras = @{},
        [string]$MimeType = '',
        [string]$Data = ''
    )
    $cmd = "am start -a $Action"
    if ($Category) { $cmd += " -c $Category" }
    if ($Component) { $cmd += " -n $Component" }
    if ($MimeType) { $cmd += " -t $MimeType" }
    if ($Data) { $cmd += " -d `"$Data`"" }
    foreach ($kv in $Extras.GetEnumerator()) {
        $val = $kv.Value -replace "'", "\\'"
        $cmd += " --es `"$($kv.Key)`" '$val'"
    }
    return (Adb-Shell $cmd)
}

function Adb-KeyEvent {
    param([string]$Code, [int]$Count = 1)
    $results = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $results += Adb-Shell "input keyevent $Code"
    }
    return ($results -join "`n")
}

function Adb-Service {
    param(
        [string]$Action,  # start or stop
        [string]$ServiceClass,
        [hashtable]$Extras = @{}
    )
    $prefix = if ($Action -eq 'start') { 'am startservice' } else { 'am stopservice' }
    $cmd = "$prefix -n $Package/$ServiceClass"
    foreach ($kv in $Extras.GetEnumerator()) {
        $cmd += " --es `"$($kv.Key)`" '$($kv.Value)'"
    }
    return (Adb-Shell $cmd)
}

# ─── VM Service Backend ───────────────────────────────────────────────────────
# Flutter VM Service Protocol uses JSON-RPC 2.0 over WebSocket.
# VmUrl should be the ws:// URL printed by `flutter run`, e.g.:
#   ws://127.0.0.1:12345/AbCdEfGh=/ws

$script:VmSocket = $null
$script:VmMsgId = 0

function Vm-Connect {
    if ($script:VmSocket -and $script:VmSocket.State -eq 'Open') { return $true }
    if (-not $VmUrl) { return $false }

    try {
        $wsUrl = $VmUrl
        if ($wsUrl -like "http://*") { $wsUrl = $wsUrl -replace '^http://', 'ws://' }
        if ($wsUrl -notlike "*/ws" -and $wsUrl -notlike "*/ws/") { $wsUrl = $wsUrl.TrimEnd('/') + '/ws' }

        $script:VmSocket = New-Object System.Net.WebSockets.ClientWebSocket
        $ct = [System.Threading.CancellationToken]::None
        $task = $script:VmSocket.ConnectAsync([Uri]$wsUrl, $ct)
        $task.Wait(10000) | Out-Null
        if ($script:VmSocket.State -ne 'Open') {
            return $false
        }
        return $true
    } catch {
        $script:VmSocket = $null
        return $false
    }
}

function Vm-SendReceive {
    param([string]$Json)
    if (-not $script:VmSocket -or $script:VmSocket.State -ne 'Open') { return $null }

    $ct = [System.Threading.CancellationToken]::None
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $script:VmSocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(5000) | Out-Null

    $buf = New-Object byte[] 65536
    $result = New-Object System.Text.StringBuilder
    do {
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
        $recv = $script:VmSocket.ReceiveAsync($seg, $ct)
        $recv.Wait(10000) | Out-Null
        $result.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count)) | Out-Null
    } while (-not $recv.Result.EndOfMessage)

    return $result.ToString()
}

function Vm-Call {
    param(
        [string]$Method,
        [hashtable]$Params = @{}
    )
    if (-not $VmUrl) {
        return "ERROR: No VM service URL provided. Use -VmUrl ws://127.0.0.1:<port>/<token>/ws"
    }
    if (-not (Vm-Connect)) {
        return "ERROR: Cannot connect to VM service at $VmUrl"
    }

    $script:VmMsgId++
    $body = @{
        jsonrpc = "2.0"
        id      = "$($script:VmMsgId)"
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 10

    try {
        $respJson = Vm-SendReceive $body
        if (-not $respJson) { return "ERROR: No response from VM service" }
        $resp = $respJson | ConvertFrom-Json
        if ($resp.error) {
            return "ERROR: $($resp.error.message)"
        }
        return ($resp.result | ConvertTo-Json -Depth 5 -Compress)
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Vm-Evaluate {
    param([string]$Expression)
    if (-not $VmUrl) {
        return "ERROR: No VM service URL. Use -VmUrl ws://127.0.0.1:<port>/<token>/ws"
    }

    $vmInfo = Vm-Call "getVM"
    if ($vmInfo -like "ERROR:*") { return $vmInfo }

    $vm = $vmInfo | ConvertFrom-Json
    $isolateId = $null
    if ($vm.isolates -and $vm.isolates.Count -gt 0) {
        $isolateId = $vm.isolates[0].id
    }
    if (-not $isolateId) { return "ERROR: No running isolate found" }

    $result = Vm-Call "evaluate" @{
        isolateId  = $isolateId
        expression = $Expression
    }
    return $result
}

# ─── Command Handlers ─────────────────────────────────────────────────────────

function Handle-Search {
    param([string[]]$CmdArgs)
    $query = $CmdArgs -join " "
    if (-not $query) { return Format-Event 'android' 'intent' 'search' @{} "Missing query text" 'ERROR' }

    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        $result = Adb-Intent -Action 'android.intent.action.WEB_SEARCH' `
            -Extras @{ query = $query } `
            -Component "$Package/.MainActivity"
        Format-Event 'android' 'intent' 'search' @{ query = $query } $result
    } elseif ($backend -eq 'vm') {
        $result = Vm-Evaluate "ref.read(appModelProvider.notifier).searchDictionary('$query')"
        Format-Event 'vm' 'intent' 'search' @{ query = $query } $result
    }
}

function Handle-Share {
    param([string[]]$CmdArgs)
    $text = $CmdArgs -join " "
    if (-not $text) { return Format-Event 'android' 'intent' 'share' @{} "Missing text" 'ERROR' }

    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        $result = Adb-Intent -Action 'android.intent.action.SEND' `
            -MimeType 'text/plain' `
            -Extras @{ 'android.intent.extra.TEXT' = $text } `
            -Component "$Package/.MainActivity"
        Format-Event 'android' 'intent' 'share' @{ text = $text } $result
    } else {
        Format-Event 'vm' 'intent' 'share' @{ text = $text } "Not implemented for VM backend" 'WARN'
    }
}

function Handle-ProcessText {
    param([string[]]$CmdArgs)
    $text = $CmdArgs -join " "
    if (-not $text) { return Format-Event 'android' 'intent' 'process-text' @{} "Missing text" 'ERROR' }

    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        $escaped = $text -replace "'", "\\'"
        $cmd = "am start -a android.intent.action.PROCESS_TEXT -t text/plain --es android.intent.extra.PROCESS_TEXT '$escaped' -n $Package/.PopupDictActivity"
        $result = Adb-Shell $cmd
        Format-Event 'android' 'intent' 'process-text' @{ text = $text } $result
    } else {
        Format-Event 'vm' 'intent' 'process-text' @{ text = $text } "Not implemented for VM backend" 'WARN'
    }
}

function Handle-MediaSearch {
    param([string[]]$CmdArgs)
    $query = $CmdArgs -join " "
    if (-not $query) { return Format-Event 'android' 'intent' 'media-search' @{} "Missing query" 'ERROR' }

    $result = Adb-Intent -Action 'android.intent.action.MEDIA_SEARCH' `
        -Extras @{ query = $query } `
        -Component "$Package/.MainActivity"
    Format-Event 'android' 'intent' 'media-search' @{ query = $query } $result
}

function Handle-VolumeUp {
    param([string[]]$CmdArgs)
    $count = if ($CmdArgs -and $CmdArgs[0] -match '^\d+$') { [int]$CmdArgs[0] } else { 1 }
    $result = Adb-KeyEvent 'KEYCODE_VOLUME_UP' $count
    Format-Event 'android' 'hardware' 'volume_up' @{ count = $count } "sent $count keyevent(s)"
}

function Handle-VolumeDown {
    param([string[]]$CmdArgs)
    $count = if ($CmdArgs -and $CmdArgs[0] -match '^\d+$') { [int]$CmdArgs[0] } else { 1 }
    $result = Adb-KeyEvent 'KEYCODE_VOLUME_DOWN' $count
    Format-Event 'android' 'hardware' 'volume_down' @{ count = $count } "sent $count keyevent(s)"
}

function Handle-MediaPlay {
    Adb-KeyEvent 'KEYCODE_MEDIA_PLAY_PAUSE'
    Format-Event 'android' 'hardware' 'media_play_pause' @{} "sent"
}

function Handle-MediaPause {
    Adb-KeyEvent 'KEYCODE_MEDIA_PAUSE'
    Format-Event 'android' 'hardware' 'media_pause' @{} "sent"
}

function Handle-MediaNext {
    Adb-KeyEvent 'KEYCODE_MEDIA_NEXT'
    Format-Event 'android' 'hardware' 'media_next' @{} "sent"
}

function Handle-MediaPrev {
    Adb-KeyEvent 'KEYCODE_MEDIA_PREVIOUS'
    Format-Event 'android' 'hardware' 'media_prev' @{} "sent"
}

function Handle-Launch {
    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        $result = Adb-Shell "am start -n $Package/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
        Format-Event 'android' 'lifecycle' 'launch' @{ package = $Package } $result
    } else {
        Format-Event 'vm' 'lifecycle' 'launch' @{} "Use flutter run for desktop" 'WARN'
    }
}

function Handle-Stop {
    $result = Adb-Shell "am force-stop $Package"
    Format-Event 'android' 'lifecycle' 'stop' @{ package = $Package } "force-stopped"
}

function Handle-Pause {
    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        Adb-KeyEvent 'KEYCODE_HOME'
        Format-Event 'android' 'lifecycle' 'pause' @{} "sent HOME key (app backgrounded)"
    } else {
        Format-Event 'vm' 'lifecycle' 'pause' @{} "Not applicable for desktop" 'WARN'
    }
}

function Handle-Resume {
    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        $result = Adb-Shell "am start -n $Package/.MainActivity"
        Format-Event 'android' 'lifecycle' 'resume' @{ package = $Package } $result
    } else {
        Format-Event 'vm' 'lifecycle' 'resume' @{} "Not applicable for desktop" 'WARN'
    }
}

function Handle-Restart {
    $backend = Resolve-Backend
    if ($backend -eq 'android') {
        Adb-Shell "am force-stop $Package" | Out-Null
        Start-Sleep -Milliseconds 500
        $result = Adb-Shell "am start -n $Package/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
        Format-Event 'android' 'lifecycle' 'restart' @{ package = $Package } $result
    } else {
        Format-Event 'vm' 'lifecycle' 'restart' @{} "Use hot restart via VM service" 'WARN'
    }
}

function Handle-FloatDict {
    param([string[]]$CmdArgs)
    $action = if ($CmdArgs) { $CmdArgs[0] } else { 'start' }
    if ($action -eq 'start') {
        $result = Adb-Shell "am startservice -n $Package/.FloatingDictService"
        Format-Event 'android' 'service' 'float_dict_start' @{} $result
    } elseif ($action -eq 'stop') {
        $result = Adb-Shell "am stopservice -n $Package/.FloatingDictService"
        Format-Event 'android' 'service' 'float_dict_stop' @{} $result
    } else {
        Format-Event 'android' 'service' 'float_dict' @{ action = $action } "Unknown action. Use: start|stop" 'ERROR'
    }
}

function Handle-FloatLyric {
    param([string[]]$CmdArgs)
    $action = if ($CmdArgs) { $CmdArgs[0] } else { 'start' }
    if ($action -eq 'start') {
        $result = Adb-Shell "am startservice -n $Package/.FloatingLyricService"
        Format-Event 'android' 'service' 'float_lyric_start' @{} $result
    } elseif ($action -eq 'stop') {
        $result = Adb-Shell "am stopservice -n $Package/.FloatingLyricService"
        Format-Event 'android' 'service' 'float_lyric_stop' @{} $result
    } else {
        Format-Event 'android' 'service' 'float_lyric' @{ action = $action } "Unknown action. Use: start|stop" 'ERROR'
    }
}

function Handle-AudioService {
    param([string[]]$CmdArgs)
    $action = if ($CmdArgs) { $CmdArgs[0] } else { 'status' }
    if ($action -eq 'status') {
        $result = Adb-Shell "dumpsys activity services $Package | grep -i audio"
        Format-Event 'android' 'service' 'audio_status' @{} $result
    } else {
        Format-Event 'android' 'service' 'audio' @{ action = $action } "Use: status" 'WARN'
    }
}

function Handle-Prefs {
    param([string[]]$CmdArgs)
    $backend = Resolve-Backend

    if ($backend -eq 'android') {
        # Access SharedPreferences via run-as (debug builds only)
        $prefsDir = "/data/data/$Package/shared_prefs"

        if (-not $CmdArgs -or $CmdArgs.Count -eq 0) {
            # List all pref files
            $result = Adb-Shell "run-as $Package ls shared_prefs/ 2>/dev/null || ls $prefsDir/ 2>/dev/null"
            Format-Event 'android' 'state' 'prefs_list' @{} $result
            return
        }

        $key = $CmdArgs[0]
        if ($CmdArgs.Count -ge 2) {
            # Set preference - use Drift DB since app uses Drift for preferences
            $value = $CmdArgs[1]
            # The app uses Drift SQLite for preferences, not SharedPreferences
            $dbPath = "/data/data/$Package/databases/hibiki.db"
            $sql = "INSERT OR REPLACE INTO preferences (key, value) VALUES ('$key', '$value')"
            $result = Adb-Shell "run-as $Package sqlite3 databases/hibiki.db `"$sql`" 2>&1"
            if (-not $result) { $result = "set (restart app to apply)" }
            Format-Event 'android' 'state' 'prefs_set' @{ key = $key; value = $value } $result
        } else {
            # Read preference
            $sql = "SELECT value FROM preferences WHERE key='$key'"
            $result = Adb-Shell "run-as $Package sqlite3 databases/hibiki.db `"$sql`" 2>&1"
            if (-not $result) { $result = "(not set)" }
            Format-Event 'android' 'state' 'prefs_get' @{ key = $key } $result
        }
    } elseif ($backend -eq 'vm') {
        if ($CmdArgs.Count -ge 2) {
            $result = Vm-Evaluate "ref.read(appModelProvider.notifier).setPreference('$($CmdArgs[0])', '$($CmdArgs[1])')"
            Format-Event 'vm' 'state' 'prefs_set' @{ key = $CmdArgs[0]; value = $CmdArgs[1] } $result
        } elseif ($CmdArgs.Count -eq 1) {
            $result = Vm-Evaluate "ref.read(appModelProvider).preferences['$($CmdArgs[0])']"
            Format-Event 'vm' 'state' 'prefs_get' @{ key = $CmdArgs[0] } $result
        } else {
            $result = Vm-Evaluate "ref.read(appModelProvider).preferences.keys.toList()"
            Format-Event 'vm' 'state' 'prefs_list' @{} $result
        }
    }
}

function Handle-DbQuery {
    param([string[]]$CmdArgs)
    $sql = $CmdArgs -join " "
    if (-not $sql) {
        Format-Event 'android' 'state' 'db_query' @{} "Missing SQL query" 'ERROR'
        return
    }

    # Check if sqlite3 is available on device
    $hasSqlite = Adb-Shell "which sqlite3"
    if (-not $hasSqlite -or $hasSqlite -like '*not found*') {
        Format-Event 'android' 'state' 'db_query' @{ sql = $sql } "sqlite3 not available on device (debug build required)" 'ERROR'
        return
    }

    $escaped = $sql -replace '"', '\"'
    $result = Adb-Shell "run-as $Package sqlite3 databases/hibiki.db `"$escaped`""
    if (-not $result) { $result = "(empty result)" }
    Format-Event 'android' 'state' 'db_query' @{ sql = $sql } $result
}

function Handle-Logcat {
    param([string[]]$CmdArgs)
    $filter = if ($CmdArgs) { $CmdArgs -join " " } else { "" }

    $appPid = Adb-Shell "pidof $Package"
    if ($appPid -and $appPid -match '^\d+$') {
        if ($filter) {
            $result = Adb-Shell "logcat -d -t 80 --pid=$appPid | grep -i '$filter'"
        } else {
            $result = Adb-Shell "logcat -d -t 50 --pid=$appPid"
        }
    } else {
        if ($filter) {
            $result = Adb-Shell "logcat -d -t 80 *:S flutter:V | grep -i '$filter'"
        } else {
            $result = Adb-Shell "logcat -d -t 50 *:S flutter:V"
        }
    }
    if (-not $result) { $result = "(no matching log entries)" }
    Format-Event 'android' 'debug' 'logcat' @{ filter = $filter; pid = $appPid } $result
}

function Handle-CrashLog {
    $result = Adb-Shell "logcat -d -t 200 *:E | grep -A5 '$Package\|FATAL\|AndroidRuntime'"
    if (-not $result) { $result = "(no crashes found)" }
    Format-Event 'android' 'debug' 'crash_log' @{} $result
}

function Handle-Activity {
    $result = Adb-Shell "dumpsys activity activities | grep -A3 '$Package'"
    if (-not $result) { $result = "(app not running)" }
    Format-Event 'android' 'info' 'activity' @{ package = $Package } $result
}

function Handle-Memory {
    $result = Adb-Shell "dumpsys meminfo $Package | head -20"
    Format-Event 'android' 'info' 'memory' @{ package = $Package } $result
}

function Handle-Processes {
    $result = Adb-Shell "ps -A | grep $Package"
    if (-not $result) { $result = "(no processes)" }
    Format-Event 'android' 'info' 'processes' @{ package = $Package } $result
}

function Handle-Pid {
    $result = Adb-Shell "pidof $Package"
    if (-not $result) { $result = "(not running)" }
    Format-Event 'android' 'info' 'pid' @{ package = $Package } $result
}

function Handle-Eval {
    param([string[]]$CmdArgs)
    $expr = $CmdArgs -join " "
    if (-not $expr) {
        Format-Event 'vm' 'eval' 'evaluate' @{} "Missing expression" 'ERROR'
        return
    }
    $result = Vm-Evaluate $expr
    Format-Event 'vm' 'eval' 'evaluate' @{ expression = $expr } $result
}

function Handle-Reload {
    $backend = Resolve-Backend
    if ($backend -eq 'vm') {
        $result = Vm-Call "reloadSources" @{ pause = $false }
        Format-Event 'vm' 'dev' 'hot_reload' @{} $result
    } else {
        Format-Event 'android' 'dev' 'hot_reload' @{} "Requires VM service URL (-VmUrl)" 'ERROR'
    }
}

function Handle-WidgetTree {
    $backend = Resolve-Backend
    if ($backend -eq 'vm') {
        $result = Vm-Call "ext.flutter.inspector.getRootWidgetSummaryTree" @{ objectGroup = "debug-tool" }
        Format-Event 'vm' 'inspect' 'widget_tree' @{} $result
    } else {
        Format-Event 'android' 'inspect' 'widget_tree' @{} "Requires VM service URL" 'ERROR'
    }
}

function Handle-Broadcast {
    param([string[]]$CmdArgs)
    if ($CmdArgs.Count -lt 1) {
        Format-Event 'android' 'intent' 'broadcast' @{} "Usage: broadcast <action> [--es key value ...]" 'ERROR'
        return
    }
    $action = $CmdArgs[0]
    $extras = $CmdArgs[1..($CmdArgs.Count - 1)] -join " "
    $cmd = "am broadcast -a $action"
    if ($extras) { $cmd += " $extras" }
    $cmd += " -p $Package"
    $result = Adb-Shell $cmd
    Format-Event 'android' 'intent' 'broadcast' @{ action = $action; extras = $extras } $result
}

function Handle-Key {
    param([string[]]$CmdArgs)
    if (-not $CmdArgs) {
        Format-Event 'android' 'hardware' 'key' @{} "Usage: key <keycode_name_or_number>" 'ERROR'
        return
    }
    $keyName = $CmdArgs[0].ToUpper()
    if ($keyName -notlike 'KEYCODE_*' -and $keyName -notmatch '^\d+$') {
        $keyName = "KEYCODE_$keyName"
    }
    $count = if ($CmdArgs.Count -ge 2 -and $CmdArgs[1] -match '^\d+$') { [int]$CmdArgs[1] } else { 1 }
    Adb-KeyEvent $keyName $count
    Format-Event 'android' 'hardware' 'key' @{ code = $keyName; count = $count } "sent"
}

function Handle-ImeText {
    param([string[]]$CmdArgs)
    $text = $CmdArgs -join " "
    if (-not $text) {
        Format-Event 'android' 'input' 'ime_text' @{} "Usage: ime-text <text>" 'ERROR'
        return
    }

    if ($text -match '^[\x20-\x7E]+$') {
        # ASCII-only: use `input text` with standard escaping
        $escaped = $text -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>' -replace "'", "\\'"
        Adb-Shell "input text '$escaped'" | Out-Null
        Format-Event 'android' 'input' 'ime_text' @{ text = $text; method = "input_text" } "sent"
    } else {
        # CJK/Unicode: use settext.jar (UiAutomator setText API - standard for non-ASCII)
        $jarPath = "/sdcard/settext.jar"
        $localJar = Join-Path $PSScriptRoot "settext.jar"
        $jarExists = Adb-Shell "[ -f $jarPath ] && echo yes"

        if ($jarExists -ne 'yes' -and (Test-Path $localJar)) {
            $dev = Resolve-Device
            & adb -s $dev push $localJar $jarPath 2>$null | Out-Null
            $jarExists = 'yes'
        }

        if ($jarExists -eq 'yes') {
            $escaped = $text -replace "'", "'\\''"
            $result = Adb-Shell "uiautomator runtest $jarPath -c SetFirstEditTextTest#testSetText -e text '$escaped'"
            Format-Event 'android' 'input' 'ime_text' @{ text = $text; method = "uiautomator" } $result
        } else {
            Format-Event 'android' 'input' 'ime_text' @{ text = $text } "settext.jar not found on device or locally at $localJar" 'ERROR'
        }
    }
}

function Handle-Script {
    param([string[]]$CmdArgs)
    if (-not $CmdArgs -or -not $CmdArgs[0]) {
        Format-Event 'script' 'batch' 'script' @{} "Usage: script <file.txt>" 'ERROR'
        return
    }
    $file = $CmdArgs[0]
    if (-not (Test-Path $file)) {
        Format-Event 'script' 'batch' 'script' @{ file = $file } "File not found" 'ERROR'
        return
    }

    Format-Event 'script' 'batch' 'start' @{ file = $file } "executing..."
    $lines = Get-Content $file -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' }
    $lineNum = 0
    foreach ($line in $lines) {
        $lineNum++
        $parts = $line.Trim() -split '\s+', 2
        $cmd = $parts[0]
        $cmdArgs = if ($parts.Count -gt 1) { $parts[1] -split '\s+' } else { @() }

        # Handle 'wait' as a special command in scripts
        if ($cmd -eq 'wait') {
            $ms = if ($cmdArgs -and $cmdArgs[0] -match '^\d+$') { [int]$cmdArgs[0] } else { 1000 }
            Start-Sleep -Milliseconds $ms
            Format-Event 'script' 'batch' 'wait' @{ ms = $ms; line = $lineNum } "waited"
            continue
        }

        # Recursively invoke the command
        & $PSCommandPath -Command $cmd -Arguments $cmdArgs -Backend $Backend -Device $Device -Package $Package -VmUrl $VmUrl
    }
    Format-Event 'script' 'batch' 'end' @{ file = $file; lines = $lineNum } "completed $lineNum commands"
}

function Handle-Help {
    Write-Output "Hibiki Debug Tool - Cross-platform event triggering via API calls"
    Write-Output ""
    Write-Output "INTENT COMMANDS (trigger app entry points):"
    Write-Output "  search <text>           WEB_SEARCH intent -> dictionary lookup"
    Write-Output "  share <text>            SEND intent -> creator/lookup"
    Write-Output "  process-text <text>     PROCESS_TEXT -> popup dictionary"
    Write-Output "  media-search <text>     MEDIA_SEARCH -> media search"
    Write-Output ""
    Write-Output "HARDWARE EVENTS (no screen interaction):"
    Write-Output "  volume-up [count]       Volume up key (reader: next page)"
    Write-Output "  volume-down [count]     Volume down key (reader: prev page)"
    Write-Output "  media-play              Play/Pause toggle"
    Write-Output "  media-pause             Pause"
    Write-Output "  media-next              Next track"
    Write-Output "  media-prev              Previous track"
    Write-Output "  key <code> [count]      Any keycode (e.g. BACK, ENTER, DPAD_UP)"
    Write-Output ""
    Write-Output "LIFECYCLE:"
    Write-Output "  launch                  Start app"
    Write-Output "  stop                    Force stop"
    Write-Output "  pause                   Send to background (HOME key)"
    Write-Output "  resume                  Bring to foreground"
    Write-Output "  restart                 Force stop + launch"
    Write-Output ""
    Write-Output "SERVICES:"
    Write-Output "  float-dict <start|stop> Floating dictionary service"
    Write-Output "  float-lyric <start|stop> Floating lyric overlay"
    Write-Output "  audio-service status    Audio service status"
    Write-Output ""
    Write-Output "STATE (requires debug build + sqlite3 on device):"
    Write-Output "  prefs                   List preference files/keys"
    Write-Output "  prefs <key>             Read preference value"
    Write-Output "  prefs <key> <value>     Set preference value"
    Write-Output "  db-query <sql>          Direct SQLite query on hibiki.db"
    Write-Output ""
    Write-Output "DEBUG:"
    Write-Output "  logcat [filter]         Filtered app logs (PID-based)"
    Write-Output "  crash-log               Recent crash/fatal logs"
    Write-Output "  activity                Current activity state"
    Write-Output "  memory                  Memory usage"
    Write-Output "  processes               Running processes"
    Write-Output "  pid                     Process ID"
    Write-Output ""
    Write-Output "VM SERVICE (requires -VmUrl ws://host:port/token/ws):"
    Write-Output "  eval <expression>       Evaluate Dart expression in running app"
    Write-Output "  reload                  Hot reload"
    Write-Output "  widget-tree             Widget inspector tree"
    Write-Output ""
    Write-Output "INPUT:"
    Write-Output "  broadcast <action> [...] Raw broadcast intent"
    Write-Output "  ime-text <text>         Input text (ASCII: input text, CJK: settext.jar)"
    Write-Output ""
    Write-Output "BATCH:"
    Write-Output "  script <file.txt>       Execute command file (one command per line)"
    Write-Output ""
    Write-Output "OPTIONS:"
    Write-Output "  -Backend android|vm|auto   Force backend (default: auto-detect)"
    Write-Output "  -Device <serial>           ADB device serial"
    Write-Output "  -Package <id>              App package (default: app.hibiki.reader)"
    Write-Output "  -VmUrl <url>               Flutter VM service WebSocket URL"
    Write-Output "  -Quiet                     Suppress formatted output"
    Write-Output "  -Raw                       Return PSObject instead of text"
    Write-Output ""
    Write-Output "SCRIPT FILE FORMAT (one command per line, # for comments):"
    Write-Output "  search 猫"
    Write-Output "  wait 2000"
    Write-Output "  volume-up 3"
    Write-Output "  process-text 食べる"
}

# ─── Command Dispatch ─────────────────────────────────────────────────────────

switch ($Command) {
    'search'        { Handle-Search $Arguments }
    'share'         { Handle-Share $Arguments }
    'process-text'  { Handle-ProcessText $Arguments }
    'media-search'  { Handle-MediaSearch $Arguments }
    'volume-up'     { Handle-VolumeUp $Arguments }
    'volume-down'   { Handle-VolumeDown $Arguments }
    'media-play'    { Handle-MediaPlay }
    'media-pause'   { Handle-MediaPause }
    'media-next'    { Handle-MediaNext }
    'media-prev'    { Handle-MediaPrev }
    'launch'        { Handle-Launch }
    'stop'          { Handle-Stop }
    'pause'         { Handle-Pause }
    'resume'        { Handle-Resume }
    'restart'       { Handle-Restart }
    'float-dict'    { Handle-FloatDict $Arguments }
    'float-lyric'   { Handle-FloatLyric $Arguments }
    'audio-service' { Handle-AudioService $Arguments }
    'prefs'         { Handle-Prefs $Arguments }
    'db-query'      { Handle-DbQuery $Arguments }
    'logcat'        { Handle-Logcat $Arguments }
    'crash-log'     { Handle-CrashLog }
    'activity'      { Handle-Activity }
    'memory'        { Handle-Memory }
    'processes'     { Handle-Processes }
    'pid'           { Handle-Pid }
    'eval'          { Handle-Eval $Arguments }
    'reload'        { Handle-Reload }
    'widget-tree'   { Handle-WidgetTree }
    'broadcast'     { Handle-Broadcast $Arguments }
    'key'           { Handle-Key $Arguments }
    'ime-text'      { Handle-ImeText $Arguments }
    'script'        { Handle-Script $Arguments }
    'help'          { Handle-Help }
    default         { Handle-Help }
}
