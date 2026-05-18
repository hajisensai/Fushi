<#
.SYNOPSIS
  Hibiki Flutter UI tool - cross-platform UI element location and interaction
  via Flutter VM Service. Equivalent of adb-ui.ps1 for Windows/macOS/Linux/iOS.

.DESCRIPTION
  Connects to a running Flutter app through the Dart VM Service WebSocket
  protocol. Provides UI tree inspection, element search, tap/swipe/scroll,
  text input, and screenshots - all via evaluated Dart expressions and
  inspector extensions.

  Requires: app running via 'flutter run' with its VM Service URL.

.EXAMPLE
  $vm = "ws://127.0.0.1:12345/AbCdEfGh=/ws"
  .\flutter-ui.ps1 -VmUrl $vm dump
  .\flutter-ui.ps1 -VmUrl $vm dump -Compact
  .\flutter-ui.ps1 -VmUrl $vm tap 200 400
  .\flutter-ui.ps1 -VmUrl $vm tap-text Play
  .\flutter-ui.ps1 -VmUrl $vm find 設定
  .\flutter-ui.ps1 -VmUrl $vm swipe 200 600 200 200
  .\flutter-ui.ps1 -VmUrl $vm scroll-down
  .\flutter-ui.ps1 -VmUrl $vm key back
  .\flutter-ui.ps1 -VmUrl $vm screenshot
  .\flutter-ui.ps1 -VmUrl $vm eval "1 + 1"
#>
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [string]$VmUrl = '',
    [switch]$Compact
)

# ─── VM Service Connection ───────────────────────────────────────────────────

$script:Ws = $null
$script:MsgId = 0
$script:IsoId = $null
$script:LibId = $null

function Vm-Connect {
    if ($script:Ws -and $script:Ws.State -eq 'Open') { return $true }
    if (-not $VmUrl) {
        Write-Error "No VM Service URL. Start app with 'flutter run' and pass -VmUrl ws://..."
        return $false
    }
    try {
        $url = $VmUrl
        if ($url -like 'http://*') { $url = $url -replace '^http://', 'ws://' }
        if ($url -notlike '*/ws' -and $url -notlike '*/ws/') { $url = $url.TrimEnd('/') + '/ws' }
        $script:Ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ct = [System.Threading.CancellationToken]::None
        $script:Ws.ConnectAsync([Uri]$url, $ct).Wait(10000) | Out-Null
        return ($script:Ws.State -eq 'Open')
    } catch {
        $script:Ws = $null
        Write-Error "Connect failed: $($_.Exception.Message)"
        return $false
    }
}

function Vm-SendRecv([string]$json) {
    if (-not $script:Ws -or $script:Ws.State -ne 'Open') { return $null }
    $ct = [System.Threading.CancellationToken]::None
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $script:Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(5000) | Out-Null
    $buf = New-Object byte[] 262144
    $sb = New-Object System.Text.StringBuilder
    do {
        $rseg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
        $recv = $script:Ws.ReceiveAsync($rseg, $ct)
        $recv.Wait(30000) | Out-Null
        $sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count)) | Out-Null
    } while (-not $recv.Result.EndOfMessage)
    return $sb.ToString()
}

function Vm-Call([string]$method, [hashtable]$params = @{}) {
    if (-not (Vm-Connect)) { return $null }
    $script:MsgId++
    $body = @{
        jsonrpc = '2.0'
        id      = "$($script:MsgId)"
        method  = $method
        params  = $params
    } | ConvertTo-Json -Depth 10
    $resp = Vm-SendRecv $body
    if (-not $resp) { return $null }
    $obj = $resp | ConvertFrom-Json
    if ($obj.error) {
        Write-Error "RPC: $($obj.error.message)"
        return $null
    }
    return $obj.result
}

function Ensure-Context {
    if ($script:IsoId -and $script:LibId) { return $true }
    $vm = Vm-Call 'getVM'
    if (-not $vm) { return $false }
    foreach ($iso in $vm.isolates) {
        if ($iso.name -eq 'main') { $script:IsoId = $iso.id; break }
    }
    if (-not $script:IsoId -and $vm.isolates.Count -gt 0) {
        $script:IsoId = $vm.isolates[0].id
    }
    if (-not $script:IsoId) { Write-Error 'No running isolate'; return $false }

    $isoInfo = Vm-Call 'getIsolate' @{ isolateId = $script:IsoId }
    if ($isoInfo -and $isoInfo.rootLib) {
        $script:LibId = $isoInfo.rootLib.id
    }
    if (-not $script:LibId) { Write-Error 'No root library'; return $false }
    return $true
}

function Vm-Eval([string]$expr) {
    if (-not (Ensure-Context)) { return $null }
    $result = Vm-Call 'evaluate' @{
        isolateId  = $script:IsoId
        targetId   = $script:LibId
        expression = $expr
    }
    if (-not $result) { return $null }
    if ($result.type -eq '@Error') {
        Write-Error "Eval: $($result.message)"
        return $null
    }
    if ($result.valueAsStringIsTruncated -eq $true -and $result.id) {
        $full = Vm-Call 'getObject' @{
            isolateId = $script:IsoId
            objectId  = $result.id
            count     = 100000
            offset    = 0
        }
        if ($full -and $full.valueAsString) { return $full.valueAsString }
    }
    return $result.valueAsString
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Escape-Dart([string]$s) {
    $s = $s.Replace('\', '\\')
    $s = $s.Replace('"', '\"')
    $s = $s.Replace('$', '\$')
    $s = $s.Replace("`n", '\n')
    $s = $s.Replace("`r", '')
    return $s
}

function As-Double([string]$v) {
    if ($v.Contains('.')) { return $v }
    return "$v.0"
}

$script:ScreenW = 0
$script:ScreenH = 0

function Ensure-ScreenSize {
    if ($script:ScreenW -gt 0) { return }
    $r = Vm-Eval '(() { try { final v = WidgetsBinding.instance.platformDispatcher.views.first; final s = v.physicalSize / v.devicePixelRatio; return "${s.width.round()},${s.height.round()}"; } catch (e) { return "0,0"; } })()'
    if ($r -and $r -match '^(\d+),(\d+)$') {
        $script:ScreenW = [int]$Matches[1]
        $script:ScreenH = [int]$Matches[2]
    }
    if ($script:ScreenW -eq 0) { $script:ScreenW = 1080; $script:ScreenH = 1920 }
}

function New-PointerId {
    return (Get-Date).Millisecond + 1000
}

# ─── Command Dispatch ────────────────────────────────────────────────────────

switch ($Action) {

    'dump' {
        $filter = if ($Compact.IsPresent) {
            'label != null || flags.isNotEmpty'
        } else {
            'coords != null'
        }
        $limit = if ($Compact.IsPresent) { '300' } else { '500' }
        $tpl = '(() { final sb = StringBuffer(); int n = 0; void v(Element el, int d) { if (d > 25 || n > __LIMIT__) return; final w = el.widget; final ro = el.renderObject; String? label; final flags = <String>[]; final tn = w.runtimeType.toString(); if (w is Text) { var s = w.data ?? ""; if (s.length > 60) s = s.substring(0, 60); label = s.replaceAll("\n", " "); } if (w is EditableText) flags.add("EDIT"); if (w is InkWell) flags.add("TAP"); if (tn.contains("Button")) flags.add("TAP"); if (tn.contains("Scroll") || tn.contains("ListView")) flags.add("SCROLL"); String? coords; if (ro is RenderBox && ro.hasSize) { try { final p = ro.localToGlobal(Offset.zero); final cx = (p.dx + ro.size.width / 2).round(); final cy = (p.dy + ro.size.height / 2).round(); coords = "@ $cx,$cy [${p.dx.round()},${p.dy.round()} ${ro.size.width.round()}x${ro.size.height.round()}]"; } catch (_) {} } if (__FILTER__) { n++; final pad = "  " * (d > 8 ? 8 : d); sb.write("$pad$tn"); if (label != null && label.isNotEmpty) sb.write(" text=$label"); if (flags.isNotEmpty) sb.write(" [${flags.join(",")}]"); if (coords != null) sb.write(" $coords"); sb.writeln(); } el.visitChildren((child) { v(child, d + 1); }); } WidgetsBinding.instance.rootElement?.visitChildren((e) { v(e, 0); }); return sb.toString(); })()'
        $expr = $tpl.Replace('__FILTER__', $filter).Replace('__LIMIT__', $limit)
        $result = Vm-Eval $expr
        if ($result) { Write-Output $result } else { Write-Output '(empty or evaluation failed)' }
    }

    'tree' {
        if (-not (Ensure-Context)) { return }
        $depth = if ($Rest -and $Rest[0] -match '^\d+$') { [int]$Rest[0] } else { 10 }
        $tree = Vm-Call 'ext.flutter.inspector.getRootWidgetSummaryTree' @{
            isolateId   = $script:IsoId
            objectGroup = 'flutter-ui-tool'
            maxDepth    = $depth
        }
        if (-not $tree) { Write-Error 'Inspector call failed'; return }
        $script:TreeN = 0
        function Show-Tree($node, [int]$ind) {
            if ($script:TreeN -gt 300) { return }
            $script:TreeN++
            $desc = if ($node.description) { $node.description } else { '?' }
            Write-Output ("  " * $ind + $desc)
            if ($node.children) {
                foreach ($c in $node.children) { Show-Tree $c ($ind + 1) }
            }
        }
        Show-Tree $tree 0
    }

    'find' {
        if (-not $Rest) { Write-Error 'Usage: find <text>'; return }
        $search = Escape-Dart ($Rest -join ' ')
        $tpl = '(() { final sb = StringBuffer(); int n = 0; void v(Element el) { final w = el.widget; String? text; if (w is Text) text = w.data ?? ""; if (text != null && text.contains("__SEARCH__")) { n++; final ro = el.renderObject; final tn = w.runtimeType.toString(); if (ro is RenderBox && ro.hasSize) { try { final p = ro.localToGlobal(Offset.zero); final cx = (p.dx + ro.size.width / 2).round(); final cy = (p.dy + ro.size.height / 2).round(); sb.writeln("  $tn text=$text @ $cx,$cy [${p.dx.round()},${p.dy.round()} ${ro.size.width.round()}x${ro.size.height.round()}]"); } catch (_) { sb.writeln("  $tn text=$text (no bounds)"); } } else { sb.writeln("  $tn (no render box)"); } } el.visitChildren(v); } WidgetsBinding.instance.rootElement?.visitChildren(v); return "$n match(es):\n$sb"; })()'
        $expr = $tpl.Replace('__SEARCH__', $search)
        $result = Vm-Eval $expr
        if ($result) { Write-Output $result } else { Write-Output 'No matches or evaluation failed' }
    }

    'tap' {
        if ($Rest.Count -lt 2) { Write-Error 'Usage: tap <x> <y>'; return }
        $x = $Rest[0]; $y = $Rest[1]; $p = New-PointerId
        $down = '(() { WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "down"; })()'
        $down = $down.Replace('__X__', (As-Double $x)).Replace('__Y__', (As-Double $y)).Replace('__P__', "$p")
        Vm-Eval $down | Out-Null
        Start-Sleep -Milliseconds 60
        $up = '(() { WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "up"; })()'
        $up = $up.Replace('__X__', (As-Double $x)).Replace('__Y__', (As-Double $y)).Replace('__P__', "$p")
        Vm-Eval $up | Out-Null
        Write-Output "Tapped @ $x,$y"
    }

    'tap-text' {
        if (-not $Rest) { Write-Error 'Usage: tap-text <text>'; return }
        $search = Escape-Dart ($Rest -join ' ')
        $tpl = '(() { String r = ""; void v(Element el) { if (r.isNotEmpty) return; final w = el.widget; String? text; if (w is Text) text = w.data ?? ""; if (text != null && text.contains("__SEARCH__")) { final ro = el.renderObject; if (ro is RenderBox && ro.hasSize) { try { final p = ro.localToGlobal(Offset.zero); r = "${(p.dx + ro.size.width / 2).round()},${(p.dy + ro.size.height / 2).round()}"; } catch (_) {} } } if (r.isEmpty) el.visitChildren(v); } WidgetsBinding.instance.rootElement?.visitChildren(v); return r.isEmpty ? "NOT_FOUND" : r; })()'
        $expr = $tpl.Replace('__SEARCH__', $search)
        $coords = Vm-Eval $expr
        if (-not $coords -or $coords -eq 'NOT_FOUND') {
            Write-Error "Not found: '$($Rest -join ' ')'"
            return
        }
        $parts = $coords -split ','
        $tx = $parts[0]; $ty = $parts[1]; $p = New-PointerId
        $down = '(() { WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "d"; })()'.Replace('__X__', (As-Double $tx)).Replace('__Y__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $down | Out-Null
        Start-Sleep -Milliseconds 60
        $up = '(() { WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "u"; })()'.Replace('__X__', (As-Double $tx)).Replace('__Y__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $up | Out-Null
        Write-Output "Tapped '$($Rest -join ' ')' @ $tx,$ty"
    }

    'tap-desc' {
        if (-not $Rest) { Write-Error 'Usage: tap-desc <desc>'; return }
        Write-Output "tap-desc is the same as tap-text for Flutter (no separate content-desc)."
        Write-Output "Use: tap-text $($Rest -join ' ')"
    }

    'tap-id' {
        if (-not $Rest) { Write-Error 'Usage: tap-id <key>'; return }
        $search = Escape-Dart $Rest[0]
        $tpl = '(() { String r = ""; void v(Element el) { if (r.isNotEmpty) return; final w = el.widget; if (w.key != null && w.key.toString().contains("__SEARCH__")) { final ro = el.renderObject; if (ro is RenderBox && ro.hasSize) { try { final p = ro.localToGlobal(Offset.zero); r = "${(p.dx + ro.size.width / 2).round()},${(p.dy + ro.size.height / 2).round()}"; } catch (_) {} } } if (r.isEmpty) el.visitChildren(v); } WidgetsBinding.instance.rootElement?.visitChildren(v); return r.isEmpty ? "NOT_FOUND" : r; })()'
        $expr = $tpl.Replace('__SEARCH__', $search)
        $coords = Vm-Eval $expr
        if (-not $coords -or $coords -eq 'NOT_FOUND') {
            Write-Error "Not found key: '$($Rest[0])'"
            return
        }
        $parts = $coords -split ','
        $tx = $parts[0]; $ty = $parts[1]; $p = New-PointerId
        $down = '(() { WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "d"; })()'.Replace('__X__', (As-Double $tx)).Replace('__Y__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $down | Out-Null
        Start-Sleep -Milliseconds 60
        $up = '(() { WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "u"; })()'.Replace('__X__', (As-Double $tx)).Replace('__Y__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $up | Out-Null
        Write-Output "Tapped key='$($Rest[0])' @ $tx,$ty"
    }

    'swipe' {
        if ($Rest.Count -lt 4) { Write-Error 'Usage: swipe <x1> <y1> <x2> <y2> [steps]'; return }
        $x1 = $Rest[0]; $y1 = $Rest[1]; $x2 = $Rest[2]; $y2 = $Rest[3]
        $steps = if ($Rest.Count -ge 5) { $Rest[4] } else { '10' }
        $p = New-PointerId
        $tpl = '(() { final b = WidgetsBinding.instance; final p = __P__; final steps = __STEPS__; final dx = (__X2__ - __X1__) / steps; final dy = (__Y2__ - __Y1__) / steps; b.handlePointerEvent(PointerDownEvent(position: Offset(__X1__, __Y1__), pointer: p)); for (var i = 1; i <= steps; i++) { final t = i / steps; b.handlePointerEvent(PointerMoveEvent(position: Offset(__X1__ + (__X2__ - __X1__) * t, __Y1__ + (__Y2__ - __Y1__) * t), pointer: p, delta: Offset(dx, dy))); } b.handlePointerEvent(PointerUpEvent(position: Offset(__X2__, __Y2__), pointer: p)); return "swiped"; })()'
        $expr = $tpl.Replace('__X1__', (As-Double $x1)).Replace('__Y1__', (As-Double $y1)).Replace('__X2__', (As-Double $x2)).Replace('__Y2__', (As-Double $y2)).Replace('__STEPS__', $steps).Replace('__P__', "$p")
        Vm-Eval $expr | Out-Null
        Write-Output "Swiped ($x1,$y1)->($x2,$y2) ${steps} steps"
    }

    'scroll-down' {
        Ensure-ScreenSize
        $cx = [math]::Floor($script:ScreenW / 2)
        $fy = [math]::Floor($script:ScreenH * 0.75)
        $ty = [math]::Floor($script:ScreenH * 0.25)
        $p = New-PointerId
        $tpl = '(() { final b = WidgetsBinding.instance; final p = __P__; final dy = (__TY__ - __FY__) / 10; b.handlePointerEvent(PointerDownEvent(position: Offset(__CX__, __FY__), pointer: p)); for (var i = 1; i <= 10; i++) { final t = i / 10; b.handlePointerEvent(PointerMoveEvent(position: Offset(__CX__, __FY__ + (__TY__ - __FY__) * t), pointer: p, delta: Offset(0, dy))); } b.handlePointerEvent(PointerUpEvent(position: Offset(__CX__, __TY__), pointer: p)); return "scrolled"; })()'
        $expr = $tpl.Replace('__CX__', (As-Double $cx)).Replace('__FY__', (As-Double $fy)).Replace('__TY__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $expr | Out-Null
        Write-Output 'Scrolled down'
    }

    'scroll-up' {
        Ensure-ScreenSize
        $cx = [math]::Floor($script:ScreenW / 2)
        $fy = [math]::Floor($script:ScreenH * 0.25)
        $ty = [math]::Floor($script:ScreenH * 0.75)
        $p = New-PointerId
        $tpl = '(() { final b = WidgetsBinding.instance; final p = __P__; final dy = (__TY__ - __FY__) / 10; b.handlePointerEvent(PointerDownEvent(position: Offset(__CX__, __FY__), pointer: p)); for (var i = 1; i <= 10; i++) { final t = i / 10; b.handlePointerEvent(PointerMoveEvent(position: Offset(__CX__, __FY__ + (__TY__ - __FY__) * t), pointer: p, delta: Offset(0, dy))); } b.handlePointerEvent(PointerUpEvent(position: Offset(__CX__, __TY__), pointer: p)); return "scrolled"; })()'
        $expr = $tpl.Replace('__CX__', (As-Double $cx)).Replace('__FY__', (As-Double $fy)).Replace('__TY__', (As-Double $ty)).Replace('__P__', "$p")
        Vm-Eval $expr | Out-Null
        Write-Output 'Scrolled up'
    }

    'long-press' {
        if ($Rest.Count -lt 2) { Write-Error 'Usage: long-press <x> <y> [ms]'; return }
        $x = $Rest[0]; $y = $Rest[1]
        $ms = if ($Rest.Count -ge 3) { [int]$Rest[2] } else { 1500 }
        $p = New-PointerId
        $down = '(() { WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "d"; })()'.Replace('__X__', (As-Double $x)).Replace('__Y__', (As-Double $y)).Replace('__P__', "$p")
        Vm-Eval $down | Out-Null
        Start-Sleep -Milliseconds $ms
        $up = '(() { WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(position: Offset(__X__, __Y__), pointer: __P__)); return "u"; })()'.Replace('__X__', (As-Double $x)).Replace('__Y__', (As-Double $y)).Replace('__P__', "$p")
        Vm-Eval $up | Out-Null
        Write-Output "Long-pressed @ $x,$y ${ms}ms"
    }

    'text' {
        if (-not $Rest) { Write-Error 'Usage: text <string>'; return }
        $input = Escape-Dart ($Rest -join ' ')
        $tpl = '(() { var r = "no field"; void v(Element el) { if (r != "no field") return; if (el.widget is EditableText) { final w = el.widget as EditableText; w.controller.text = "__TEXT__"; w.controller.selection = TextSelection.collapsed(offset: w.controller.text.length); r = "set"; return; } el.visitChildren(v); } WidgetsBinding.instance.rootElement?.visitChildren(v); return r; })()'
        $expr = $tpl.Replace('__TEXT__', $input)
        $result = Vm-Eval $expr
        if ($result) { Write-Output "Text: $result" } else { Write-Output 'text command failed' }
    }

    'key' {
        if (-not $Rest) { Write-Error 'Usage: key <back|enter|escape>'; return }
        $k = $Rest[0].ToLower()
        switch ($k) {
            'back' {
                Vm-Eval '(() { WidgetsBinding.instance.handlePopRoute(); return "back"; })()' | Out-Null
                Write-Output 'Key: back (pop route)'
            }
            default {
                Write-Output "Key '$k' not directly supported via VM Service."
                Write-Output "Supported: back. For others, use: eval <dart expression>"
            }
        }
    }

    'back' {
        Vm-Eval '(() { WidgetsBinding.instance.handlePopRoute(); return "back"; })()' | Out-Null
        Write-Output 'Back'
    }

    'screenshot' {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $path = if ($Rest -and $Rest[0]) { $Rest[0] } else { "d:\APP\vs_claude_code\hibiki\.codex-test\flutter_screenshot_$ts.png" }
        try {
            Add-Type -AssemblyName System.Drawing
            Add-Type -AssemblyName System.Windows.Forms
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose()
            $bmp.Dispose()
            Write-Output "Screenshot: $path"
        } catch {
            Write-Output "Windows screenshot failed: $($_.Exception.Message)"
            Write-Output "Alternatives:"
            Write-Output "  macOS:  screencapture -x $path"
            Write-Output "  Linux:  import $path   (ImageMagick)"
        }
    }

    'size' {
        Ensure-ScreenSize
        Write-Output "Window: $($script:ScreenW) x $($script:ScreenH)"
    }

    'eval' {
        if (-not $Rest) { Write-Error 'Usage: eval <dart_expression>'; return }
        $expr = $Rest -join ' '
        $result = Vm-Eval $expr
        if ($null -ne $result) { Write-Output $result } else { Write-Output '(null/void)' }
    }

    'launch' {
        Write-Output "For desktop: use 'flutter run' to start the app."
        Write-Output "For iOS sim: use 'flutter run -d <device_id>'."
        Write-Output "Once running, the VM Service URL is printed in the output."
    }

    'wait' {
        $s = if ($Rest -and $Rest[0]) { [int]$Rest[0] } else { 2 }
        Start-Sleep -Seconds $s
        Write-Output "Waited ${s}s"
    }

    default {
        Write-Output 'Flutter UI Tool - Cross-platform UI automation via VM Service'
        Write-Output ''
        Write-Output 'PREREQUISITE: App running via "flutter run". Pass -VmUrl with the'
        Write-Output '  WebSocket URL from the flutter run output (look for "VM Service").'
        Write-Output ''
        Write-Output 'UI INSPECTION:'
        Write-Output '  dump                    All rendered elements with bounds'
        Write-Output '  dump -Compact           Only text + interactive elements with bounds'
        Write-Output '  tree [depth]            Widget tree via inspector (structural, no bounds)'
        Write-Output '  find <text>             Find elements containing text'
        Write-Output '  size                    Window dimensions (logical pixels)'
        Write-Output ''
        Write-Output 'INTERACTION:'
        Write-Output '  tap <x> <y>             Tap at coordinates'
        Write-Output '  tap-text <text>         Find text element and tap its center'
        Write-Output '  tap-id <key>            Find element by widget key and tap'
        Write-Output '  swipe <x1> <y1> <x2> <y2> [steps]  Swipe gesture'
        Write-Output '  scroll-down             Scroll down (center of screen)'
        Write-Output '  scroll-up               Scroll up'
        Write-Output '  long-press <x> <y> [ms] Long press (default 1500ms)'
        Write-Output '  text <string>           Input text to focused EditableText'
        Write-Output '  back                    Pop route (back navigation)'
        Write-Output '  key <name>              Key event (currently: back)'
        Write-Output ''
        Write-Output 'DEBUG:'
        Write-Output '  eval <expression>       Evaluate any Dart expression in the running app'
        Write-Output '  screenshot [path]       Screen capture (Windows .NET; hints for others)'
        Write-Output ''
        Write-Output 'OTHER:'
        Write-Output '  launch                  Instructions for starting the app'
        Write-Output '  wait [seconds]          Delay (default 2s)'
        Write-Output ''
        Write-Output 'EXAMPLES:'
        Write-Output '  $vm = "ws://127.0.0.1:12345/token=/ws"'
        Write-Output '  .\flutter-ui.ps1 -VmUrl $vm dump -Compact'
        Write-Output '  .\flutter-ui.ps1 -VmUrl $vm tap 200 400'
        Write-Output '  .\flutter-ui.ps1 -VmUrl $vm tap-text Settings'
        Write-Output '  .\flutter-ui.ps1 -VmUrl $vm find 辞書'
        Write-Output '  .\flutter-ui.ps1 -VmUrl $vm eval "MediaQuery.of(context).size"'
        Write-Output ''
        Write-Output 'NOTE: tap-desc is aliased to tap-text (Flutter has no separate content-desc).'
    }
}
