<#
.SYNOPSIS
  Hibiki ADB UI tool - tap, swipe, dump, find without manual adb calls
.EXAMPLE
  .\adb-ui.ps1 dump              # full UI tree
  .\adb-ui.ps1 dump -Compact     # only interactive/labeled elements
  .\adb-ui.ps1 tap 540 1140
  .\adb-ui.ps1 tap-text Play
  .\adb-ui.ps1 tap-desc "Previous sentence"
  .\adb-ui.ps1 find sentence
  .\adb-ui.ps1 key back
  .\adb-ui.ps1 swipe 540 1800 540 400
  .\adb-ui.ps1 scroll-down
  .\adb-ui.ps1 scroll-up
  .\adb-ui.ps1 text "hello"
  .\adb-ui.ps1 text "日本語テスト"    # CJK auto-routed via settext.jar
  .\adb-ui.ps1 has-text "Play"
  .\adb-ui.ps1 wait-for-text "Play" 30
  .\adb-ui.ps1 wait-for-gone "Loading" 120
  .\adb-ui.ps1 ensure-home
  .\adb-ui.ps1 screenshot
  .\adb-ui.ps1 launch
#>
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [string]$Device = "",
    [switch]$Compact,
    [string]$Package = "app.hibiki.reader"
)

# ─── Device auto-detection ───────────────────────────────────────────────────

function Resolve-Device {
    if ($script:ResolvedDevice) { return $script:ResolvedDevice }
    if ($Device) {
        $script:ResolvedDevice = $Device
        return $Device
    }
    try {
        $lines = & adb devices 2>$null | Where-Object { $_ -match '\s+device$' }
        if ($lines) {
            $first = ($lines[0] -split '\s+')[0]
            $script:ResolvedDevice = $first
            return $first
        }
    } catch {}
    $script:ResolvedDevice = 'emulator-5554'
    return 'emulator-5554'
}

$script:ResolvedDevice = $null

function Shell([string]$cmd) {
    $dev = Resolve-Device
    return (& adb -s $dev shell $cmd 2>$null)
}

# ─── Screen size detection ───────────────────────────────────────────────────

$script:ScreenW = 0
$script:ScreenH = 0

function Get-ScreenSize {
    if ($script:ScreenW -gt 0 -and $script:ScreenH -gt 0) { return }
    $output = Shell "wm size"
    if ($output -match '(\d+)x(\d+)') {
        $script:ScreenW = [int]$Matches[1]
        $script:ScreenH = [int]$Matches[2]
    } else {
        # Fallback to common resolution
        $script:ScreenW = 1080
        $script:ScreenH = 1920
    }
}

# ─── CJK-aware text input ────────────────────────────────────────────────────

function Ensure-SetTextJar {
    $jarDevice = "/sdcard/settext.jar"
    $localJar = Join-Path $PSScriptRoot "settext.jar"
    $jarCheck = Shell "[ -f $jarDevice ] && echo yes"
    if ($jarCheck -ne 'yes') {
        if (Test-Path $localJar) {
            $dev = Resolve-Device
            & adb -s $dev push $localJar $jarDevice 2>$null | Out-Null
            return $true
        }
        return $false
    }
    return $true
}

function Send-TextInput([string]$text) {
    # Always prefer settext.jar: it replaces the EditText content consistently
    # (input text only appends and cannot handle CJK)
    $jarDevice = "/sdcard/settext.jar"
    $jarReady = Ensure-SetTextJar

    if ($jarReady) {
        $escaped = $text -replace "'", "'\\''"
        $result = Shell "uiautomator runtest $jarDevice -c SetFirstEditTextTest#testSetText -e text '$escaped'"
        Write-Output "Typed (settext.jar): '$text'"
    } elseif ($text -match '^[\x20-\x7E]+$') {
        # Fallback for ASCII-only when jar is not available
        $escaped = $text -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>' -replace "'", "\\'"
        Shell "input text '$escaped'" | Out-Null
        Write-Output "Typed (input text fallback): '$text'"
    } else {
        Write-Error "Cannot type CJK text: settext.jar not found on device or at '$(Join-Path $PSScriptRoot settext.jar)'"
    }
}

# ─── UI node parsing ─────────────────────────────────────────────────────────

function Get-Center([string]$bounds) {
    if ($bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        return @{ X = [math]::Floor(([int]$Matches[1] + [int]$Matches[3]) / 2); Y = [math]::Floor(([int]$Matches[2] + [int]$Matches[4]) / 2) }
    }
    return $null
}

function Get-RawDump {
    Shell "uiautomator dump /sdcard/dump.xml" | Out-Null
    $lines = Shell "cat /sdcard/dump.xml"
    return ($lines -join "")
}

function Parse-Nodes([string]$raw) {
    $nodes = @()
    $regex = [regex]'<node\s([^>]+?)(?:\s*/?>)'
    foreach ($m in $regex.Matches($raw)) {
        $attrs = @{}
        $attrRegex = [regex]'(\w[\w-]*)="([^"]*)"'
        foreach ($a in $attrRegex.Matches($m.Groups[1].Value)) {
            $attrs[$a.Groups[1].Value] = $a.Groups[2].Value
        }
        $nodes += $attrs
    }
    return $nodes
}

function Format-Dump([object[]]$nodes, [bool]$compact) {
    foreach ($n in $nodes) {
        $text = $n['text']
        $desc = $n['content-desc']
        $cls = $n['class'] -replace '^android\.(widget|view|webkit)\.', ''
        $bounds = $n['bounds']
        $resId = $n['resource-id']
        $click = $n['clickable'] -eq 'true'
        $edit = $cls -like '*EditText*'
        $scroll = $n['scrollable'] -eq 'true'
        $longClick = $n['long-clickable'] -eq 'true'

        $hasContent = $text -or $desc
        $interactive = $click -or $edit -or $scroll -or $longClick

        if ($compact -and -not $hasContent -and -not $interactive) { continue }

        $label = ""
        if ($text) { $label = "text=`"$text`"" }
        elseif ($desc) { $label = "desc=`"$desc`"" }

        $flags = @()
        if ($click) { $flags += "CLICK" }
        if ($edit) { $flags += "EDIT" }
        if ($scroll) { $flags += "SCROLL" }
        if ($longClick) { $flags += "LONG" }
        $flagStr = if ($flags) { "[" + ($flags -join ",") + "]" } else { "" }

        $center = Get-Center $bounds
        $coord = if ($center) { "@ $($center.X),$($center.Y)" } else { "" }

        $parts = @($cls)
        if ($label) { $parts += $label }
        if ($resId) { $parts += "id=$resId" }
        if ($flagStr) { $parts += $flagStr }
        if ($coord) { $parts += $coord }
        Write-Output ($parts -join " ")
    }
}

function Find-InNodes([object[]]$nodes, [string]$search, [string]$field = "both") {
    $results = @()
    foreach ($n in $nodes) {
        $match = $false
        switch ($field) {
            "text" { $match = $n['text'] -and $n['text'].Contains($search) }
            "desc" { $match = $n['content-desc'] -and $n['content-desc'].Contains($search) }
            "id" { $match = $n['resource-id'] -and $n['resource-id'].Contains($search) }
            "both" { $match = ($n['text'] -and $n['text'].Contains($search)) -or ($n['content-desc'] -and $n['content-desc'].Contains($search)) }
        }
        if ($match) { $results += $n }
    }
    return $results
}

$keyCodes = @{
    'back' = 'KEYCODE_BACK'; 'home' = 'KEYCODE_HOME'; 'enter' = 'KEYCODE_ENTER'
    'tab' = 'KEYCODE_TAB'; 'menu' = 'KEYCODE_MENU'; 'search' = 'KEYCODE_SEARCH'
    'delete' = 'KEYCODE_DEL'; 'del' = 'KEYCODE_DEL'
    'volumeup' = 'KEYCODE_VOLUME_UP'; 'volumedown' = 'KEYCODE_VOLUME_DOWN'
    'up' = 'KEYCODE_DPAD_UP'; 'down' = 'KEYCODE_DPAD_DOWN'
    'left' = 'KEYCODE_DPAD_LEFT'; 'right' = 'KEYCODE_DPAD_RIGHT'
    'space' = 'KEYCODE_SPACE'; 'escape' = 'KEYCODE_ESCAPE'
    'power' = 'KEYCODE_POWER'; 'appswitch' = 'KEYCODE_APP_SWITCH'
}

switch ($Action) {
    'dump' {
        $raw = Get-RawDump
        $nodes = Parse-Nodes $raw
        Format-Dump $nodes $Compact.IsPresent
    }
    'tap' {
        if ($Rest.Count -lt 2) { Write-Error "Usage: tap <x> <y>"; return }
        Shell "input tap $($Rest[0]) $($Rest[1])" | Out-Null
        Write-Output "Tapped @ $($Rest[0]),$($Rest[1])"
    }
    'tap-text' {
        if (-not $Rest) { Write-Error "Usage: tap-text <text>"; return }
        $search = $Rest -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "both"
        if ($found.Count -eq 0) { Write-Error "Not found: '$search'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped '$search' @ $($c.X),$($c.Y)"
        if ($found.Count -gt 1) { Write-Warning "$($found.Count) matches, tapped first" }
    }
    'tap-desc' {
        if (-not $Rest) { Write-Error "Usage: tap-desc <desc>"; return }
        $search = $Rest -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "desc"
        if ($found.Count -eq 0) { Write-Error "Not found desc: '$search'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped desc='$search' @ $($c.X),$($c.Y)"
    }
    'tap-id' {
        if (-not $Rest) { Write-Error "Usage: tap-id <id>"; return }
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $Rest[0] "id"
        if ($found.Count -eq 0) { Write-Error "Not found id: '$($Rest[0])'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped id='$($Rest[0])' @ $($c.X),$($c.Y)"
    }
    'find' {
        if (-not $Rest) { Write-Error "Usage: find <text>"; return }
        $search = $Rest -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "both"
        if ($found.Count -eq 0) { Write-Output "No matches: '$search'"; return }
        Write-Output "$($found.Count) match(es):"
        foreach ($n in $found) {
            $cls = $n['class'] -replace '^android\.(widget|view|webkit)\.', ''
            $label = if ($n['text']) { "text=`"$($n['text'])`"" } elseif ($n['content-desc']) { "desc=`"$($n['content-desc'])`"" } else { "" }
            $c = Get-Center $n['bounds']
            $coord = if ($c) { "@ $($c.X),$($c.Y)" } else { "" }
            Write-Output "  $cls $label $coord $($n['bounds'])"
        }
    }
    'swipe' {
        if ($Rest.Count -lt 4) { Write-Error "Usage: swipe <x1> <y1> <x2> <y2> [ms]"; return }
        $dur = if ($Rest.Count -ge 5) { $Rest[4] } else { "300" }
        Shell "input swipe $($Rest[0]) $($Rest[1]) $($Rest[2]) $($Rest[3]) $dur" | Out-Null
        Write-Output "Swiped ($($Rest[0]),$($Rest[1]))->($($Rest[2]),$($Rest[3])) ${dur}ms"
    }
    'scroll-down' {
        Get-ScreenSize
        $cx = [math]::Floor($script:ScreenW / 2)
        $fromY = [math]::Floor($script:ScreenH * 0.75)
        $toY = [math]::Floor($script:ScreenH * 0.25)
        Shell "input swipe $cx $fromY $cx $toY 300" | Out-Null
        Write-Output "Scrolled down ($cx, $fromY)->($cx, $toY) on ${script:ScreenW}x${script:ScreenH}"
    }
    'scroll-up' {
        Get-ScreenSize
        $cx = [math]::Floor($script:ScreenW / 2)
        $fromY = [math]::Floor($script:ScreenH * 0.25)
        $toY = [math]::Floor($script:ScreenH * 0.75)
        Shell "input swipe $cx $fromY $cx $toY 300" | Out-Null
        Write-Output "Scrolled up ($cx, $fromY)->($cx, $toY) on ${script:ScreenW}x${script:ScreenH}"
    }
    'long-press' {
        if ($Rest.Count -lt 2) { Write-Error "Usage: long-press <x> <y> [ms]"; return }
        $dur = if ($Rest.Count -ge 3) { $Rest[2] } else { "1500" }
        Shell "input swipe $($Rest[0]) $($Rest[1]) $($Rest[0]) $($Rest[1]) $dur" | Out-Null
        Write-Output "Long-pressed @ $($Rest[0]),$($Rest[1]) ${dur}ms"
    }
    'text' {
        if (-not $Rest) { Write-Error "Usage: text <string>"; return }
        $inputText = $Rest -join " "
        Send-TextInput $inputText
    }
    'ime-text' {
        if (-not $Rest) { Write-Error "Usage: ime-text <string>"; return }
        $inputText = $Rest -join " "
        Send-TextInput $inputText
    }
    'key' {
        if (-not $Rest) { Write-Error "Usage: key <name>"; return }
        $k = $Rest[0].ToLower()
        $code = if ($keyCodes.ContainsKey($k)) { $keyCodes[$k] } else { $Rest[0] }
        Shell "input keyevent $code" | Out-Null
        Write-Output "Key: $code"
    }
    'back' {
        Shell "input keyevent KEYCODE_BACK" | Out-Null
        Write-Output "Back"
    }
    'home' {
        Shell "input keyevent KEYCODE_HOME" | Out-Null
        Write-Output "Home"
    }
    'screenshot' {
        $ts = Get-Date -Format "yyyyMMdd_HHmmss"
        $local = if ($Rest -and $Rest[0]) { $Rest[0] } else { "d:\APP\vs_claude_code\hibiki\.codex-test\screenshot_$ts.png" }
        Shell "screencap -p /sdcard/ss.png" | Out-Null
        $dev = Resolve-Device
        & adb -s $dev pull /sdcard/ss.png $local 2>$null | Out-Null
        Write-Output "Screenshot: $local"
    }
    'launch' {
        Shell "am start -n $Package/.MainActivity" | Out-Null
        Write-Output "Launched $Package"
    }
    'wait' {
        $s = if ($Rest -and $Rest[0]) { [int]$Rest[0] } else { 2 }
        Start-Sleep -Seconds $s
        Write-Output "Waited ${s}s"
    }
    'has-text' {
        if (-not $Rest) { Write-Error "Usage: has-text <text>"; return }
        $search = $Rest -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "both"
        if ($found.Count -gt 0) {
            Write-Output "true"
        } else {
            Write-Output "false"
        }
    }
    'wait-for-text' {
        if (-not $Rest) { Write-Error "Usage: wait-for-text <text> [timeout_seconds]"; return }
        $search = $Rest[0]
        $timeout = 30
        if ($Rest.Count -ge 2 -and $Rest[1] -match '^\d+$') { $timeout = [int]$Rest[1] }
        $elapsed = 0
        $pollInterval = 3
        $found = $false
        while ($elapsed -lt $timeout) {
            $nodes = Parse-Nodes (Get-RawDump)
            $matches = Find-InNodes $nodes $search "both"
            if ($matches.Count -gt 0) {
                $found = $true
                break
            }
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval
        }
        if ($found) {
            Write-Output "FOUND"
        } else {
            Write-Output "TIMEOUT"
        }
    }
    'wait-for-gone' {
        if (-not $Rest) { Write-Error "Usage: wait-for-gone <text> [timeout_seconds]"; return }
        $search = $Rest[0]
        $timeout = 120
        if ($Rest.Count -ge 2 -and $Rest[1] -match '^\d+$') { $timeout = [int]$Rest[1] }
        $elapsed = 0
        $pollInterval = 3
        $gone = $false
        while ($elapsed -lt $timeout) {
            $nodes = Parse-Nodes (Get-RawDump)
            $matches = Find-InNodes $nodes $search "both"
            if ($matches.Count -eq 0) {
                $gone = $true
                break
            }
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval
        }
        if ($gone) {
            Write-Output "GONE"
        } else {
            Write-Output "TIMEOUT"
        }
    }
    'ensure-home' {
        # Navigate back to app home screen: press BACK up to 5 times,
        # then verify app is in foreground; if not, launch it.
        $maxBack = 5
        for ($i = 0; $i -lt $maxBack; $i++) {
            $activityOut = Shell "dumpsys activity activities | grep -E 'mResumedActivity|mFocusedActivity'"
            # If we're at the main launcher activity, stop pressing back
            if ($activityOut -and $activityOut -match "$Package/.MainActivity") {
                break
            }
            # If app is no longer in foreground at all, stop and re-launch
            if ($activityOut -and $activityOut -notmatch $Package) {
                break
            }
            Shell "input keyevent KEYCODE_BACK" | Out-Null
            Start-Sleep -Milliseconds 500
        }
        # Verify app is in foreground; if not, launch it
        $finalCheck = Shell "dumpsys activity activities | grep -E 'mResumedActivity|mFocusedActivity'"
        if (-not $finalCheck -or $finalCheck -notmatch "$Package/.MainActivity") {
            Shell "am start -n $Package/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER" | Out-Null
            Start-Sleep -Milliseconds 800
            Write-Output "ensure-home: re-launched $Package"
        } else {
            Write-Output "ensure-home: already at MainActivity"
        }
    }
    default {
        Write-Output "Actions: dump tap tap-text tap-desc tap-id find swipe scroll-down scroll-up long-press text ime-text key back home screenshot launch wait has-text wait-for-text wait-for-gone ensure-home"
    }
}
