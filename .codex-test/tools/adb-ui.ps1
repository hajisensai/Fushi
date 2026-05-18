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
  .\adb-ui.ps1 screenshot
  .\adb-ui.ps1 launch
#>
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Args,

    [string]$Device = "emulator-5554",
    [switch]$Compact,
    [string]$Package = "app.hibiki.reader"
)

function Shell([string]$cmd) {
    return (& adb -s $Device shell $cmd 2>$null)
}

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
        if ($Args.Count -lt 2) { Write-Error "Usage: tap <x> <y>"; return }
        Shell "input tap $($Args[0]) $($Args[1])" | Out-Null
        Write-Output "Tapped @ $($Args[0]),$($Args[1])"
    }
    'tap-text' {
        if (-not $Args) { Write-Error "Usage: tap-text <text>"; return }
        $search = $Args -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "both"
        if ($found.Count -eq 0) { Write-Error "Not found: '$search'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped '$search' @ $($c.X),$($c.Y)"
        if ($found.Count -gt 1) { Write-Warning "$($found.Count) matches, tapped first" }
    }
    'tap-desc' {
        if (-not $Args) { Write-Error "Usage: tap-desc <desc>"; return }
        $search = $Args -join " "
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $search "desc"
        if ($found.Count -eq 0) { Write-Error "Not found desc: '$search'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped desc='$search' @ $($c.X),$($c.Y)"
    }
    'tap-id' {
        if (-not $Args) { Write-Error "Usage: tap-id <id>"; return }
        $nodes = Parse-Nodes (Get-RawDump)
        $found = Find-InNodes $nodes $Args[0] "id"
        if ($found.Count -eq 0) { Write-Error "Not found id: '$($Args[0])'"; return }
        $c = Get-Center $found[0]['bounds']
        Shell "input tap $($c.X) $($c.Y)" | Out-Null
        Write-Output "Tapped id='$($Args[0])' @ $($c.X),$($c.Y)"
    }
    'find' {
        if (-not $Args) { Write-Error "Usage: find <text>"; return }
        $search = $Args -join " "
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
        if ($Args.Count -lt 4) { Write-Error "Usage: swipe <x1> <y1> <x2> <y2> [ms]"; return }
        $dur = if ($Args.Count -ge 5) { $Args[4] } else { "300" }
        Shell "input swipe $($Args[0]) $($Args[1]) $($Args[2]) $($Args[3]) $dur" | Out-Null
        Write-Output "Swiped ($($Args[0]),$($Args[1]))->($($Args[2]),$($Args[3])) ${dur}ms"
    }
    'scroll-down' {
        Shell "input swipe 540 1600 540 800 300" | Out-Null
        Write-Output "Scrolled down"
    }
    'scroll-up' {
        Shell "input swipe 540 800 540 1600 300" | Out-Null
        Write-Output "Scrolled up"
    }
    'long-press' {
        if ($Args.Count -lt 2) { Write-Error "Usage: long-press <x> <y> [ms]"; return }
        $dur = if ($Args.Count -ge 3) { $Args[2] } else { "1500" }
        Shell "input swipe $($Args[0]) $($Args[1]) $($Args[0]) $($Args[1]) $dur" | Out-Null
        Write-Output "Long-pressed @ $($Args[0]),$($Args[1]) ${dur}ms"
    }
    'text' {
        if (-not $Args) { Write-Error "Usage: text <string>"; return }
        $input = $Args -join " "
        $escaped = $input -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>'
        Shell "input text '$escaped'" | Out-Null
        Write-Output "Typed: '$input'"
    }
    'key' {
        if (-not $Args) { Write-Error "Usage: key <name>"; return }
        $k = $Args[0].ToLower()
        $code = if ($keyCodes.ContainsKey($k)) { $keyCodes[$k] } else { $Args[0] }
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
        $local = if ($Args -and $Args[0]) { $Args[0] } else { "d:\APP\vs_claude_code\hibiki\.codex-test\screenshot_$ts.png" }
        Shell "screencap -p /sdcard/ss.png" | Out-Null
        & adb -s $Device pull /sdcard/ss.png $local 2>$null | Out-Null
        Write-Output "Screenshot: $local"
    }
    'launch' {
        Shell "am start -n $Package/.MainActivity" | Out-Null
        Write-Output "Launched $Package"
    }
    'wait' {
        $s = if ($Args -and $Args[0]) { [int]$Args[0] } else { 2 }
        Start-Sleep -Seconds $s
        Write-Output "Waited ${s}s"
    }
    default {
        Write-Output "Actions: dump tap tap-text tap-desc tap-id find swipe scroll-down scroll-up long-press text key back home screenshot launch wait"
    }
}
