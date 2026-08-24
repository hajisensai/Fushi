import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-749 — 瞬态查词覆盖窗命中/绘制区域必须裁到卡片矩形并集（源码扫描守卫）。
///
/// 真机根因链：TODO-1345（BUG-583 round5, d2c57193a）给 reveal bbox 预留级联
/// origin floor 后，瞬态覆盖窗 reveal 时≈铺满整个工作区（真机日志 box 高恒为
/// 全屏高）。该窗是**不透明**窗（无 WS_EX_LAYERED，WebView2 组合面限制），
/// 全窗 region 意味着：卡片在屏时，点剪贴板面板里下一个词的点击落在覆盖窗上
/// → host 判「卡外」→ 关卡 + **点击被吞**（用户症状=「第二个弹窗闪一下消失、
/// 每次都要点两下」）。
///
/// 修复契约：
/// 1. host（global_lookup_host.js）每次 measureAndReport 把各 shell 的
///    窗口相对矩形（CSS px）以 `shellRects` CSV 消息发给 native，且在
///    overlaySize 之前（窗口 reveal 时 region 已就位）。
/// 2. native（global_lookup_window.cpp）在 WebMessageReceived 拦截
///    shellRects（不转发 Dart），`ApplyRoundedRegion` 在 rects 非空时用
///    per-shell 圆角矩形**并集**做 SetWindowRgn——空隙点击物理穿透到底下的
///    应用（面板一次点击=关旧卡+查新词）；窗口矩形本身不动（BUG-583 零位移
///    语义保留）。面板实例（panel mode 短路 measureAndReport）永不发 rects，
///    维持整窗 region。
/// 3. `Hide()` 与 `ForgetDeadWindow()` 清空缓存 rects；host 在 beginLookup
///    重置去重键，保证下一次 lookup 重新发送。
/// 4. host 的 hook 转发 gap 点击（handleGlobalClick 未命中 shell）必须**立即**
///    post dismissPopupAt——同一次物理点击此刻也落进了底下的应用并可能已发起
///    新 lookup，200ms slide 延迟的 dismiss 会杀掉新卡（stale-dismiss 竞态）。
/// 5. galCard 的 CapturePreview 不继承 HWND region；WIC 解码后必须用同一批
///    shell rects 的 per-shell 圆角并集裁 alpha，且异步捕获只能使用调用时快照。
///
/// 覆盖窗真渲染依赖 native WebView2，headless 测不了，故源码扫描钉住契约；
/// 行为面由 node harness（global_lookup_host_test.mjs R1-R3）覆盖。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hdr;
  late String hostJs;
  late String flutterWindow;
  late String voiceReader;
  setUpAll(() {
    cpp = read('windows/runner/global_lookup_window.cpp');
    hdr = read('windows/runner/global_lookup_window.h');
    hostJs = read('assets/popup/global_lookup_host.js');
    flutterWindow = read('windows/runner/flutter_window.cpp');
    voiceReader = read('windows/runner/voice_hook_reader.cpp');
  });

  /// 抽出一个顶层函数体（从签名行到下一个左对齐 `}`）。
  String functionBody(String src, String signature) {
    final int at = src.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: '必须存在：$signature');
    final int end = src.indexOf('\n}', at);
    expect(end, greaterThan(at));
    return src.substring(at, end);
  }

  test('native 拦截 shellRects 且不转发 Dart（region 是纯 Win32 状态）', () {
    final int intercept = cpp.indexOf('"\\"handler\\":\\"shellRects\\""');
    expect(
      intercept,
      greaterThanOrEqualTo(0),
      reason: 'WebMessageReceived 必须按带引号的 handler 名拦截 shellRects',
    );
    final int forward = cpp.indexOf('if (message_cb_)', intercept);
    final int handle = cpp.indexOf('SetShellRectsFromCsv(body)', intercept);
    expect(handle, greaterThanOrEqualTo(0), reason: '拦截后必须解析并应用 region');
    expect(
      handle,
      lessThan(forward),
      reason: 'shellRects 必须在 message_cb_ 转发之前拦截（return，不进 Dart 日志）',
    );
    final String parser = functionBody(
      cpp,
      'void GlobalLookupWindow::SetShellRectsFromCsv(',
    );
    expect(
      parser,
      contains('BeginGeometryRequest(geometry_epoch)'),
      reason:
          'shellRects 必须先推进 geometry high-water，防止旧 resize 在新区 '
          'region 宣布后回滚 HWND',
    );
  });

  test('ApplyRoundedRegion：rects 非空走 per-shell 并集，空退回整窗圆角', () {
    final String body = functionBody(
      cpp,
      'void GlobalLookupWindow::ApplyRoundedRegion()',
    );
    expect(
      body,
      contains('!region_rects.empty()'),
      reason: '必须按已提交的有效 shell rects 有无分流',
    );
    expect(
      body,
      contains('region_rects = shell_rects_css_'),
      reason: 'WM_SIZE/DPI/resize 收尾只能重装与当前可见 DOM 同源的 committed HRGN',
    );
    expect(
      body,
      isNot(contains('pending_shell_rects_css_')),
      reason: 'pending rects 只能在 matching layer-shift 回调里提交，不能抢跑裁旧父卡',
    );
    expect(body, contains('CombineRgn'), reason: '卡片矩形必须以 RGN_OR 并集合成命中/绘制区域');
    expect(body, contains('RGN_OR'), reason: '并集语义（不是交集/差集）');
    expect(
      'CreateRoundRectRgn'.allMatches(body).length,
      greaterThanOrEqualTo(2),
      reason: 'per-shell 圆角矩形 + 整窗圆角回退两条路径都必须存在',
    );
  });

  test('Hide 与 ForgetDeadWindow 清空缓存 rects（防 stale region 裁掉下一张卡）', () {
    final String hide = functionBody(cpp, 'void GlobalLookupWindow::Hide(');
    expect(
      hide,
      contains('shell_rects_css_.clear()'),
      reason: 'Hide 必须清 rects：下一次 lookup 由 host 重新发送',
    );
    expect(
      hide,
      contains('SetWindowRgn(hwnd_, nullptr, FALSE)'),
      reason: '清 C++ vector 不会移除 user32 已接管的旧 HRGN；隐藏时必须同步清实际 region',
    );
    final String forget = functionBody(
      cpp,
      'void GlobalLookupWindow::ForgetDeadWindow()',
    );
    expect(
      forget,
      contains('shell_rects_css_.clear()'),
      reason: '死窗重建路径同样不得携带旧 region',
    );
  });

  test('头文件声明 SetShellRectsFromCsv 与 shell_rects_css_', () {
    expect(
      hdr,
      contains('void SetShellRectsFromCsv(const std::string& body);'),
    );
    expect(
      hdr,
      contains('std::vector<std::array<double, 4>> shell_rects_css_;'),
    );
  });

  test('galCard BGRA 在 CapturePreview 解码后应用 per-shell 圆角 alpha mask', () {
    final String capture = functionBody(
      cpp,
      'void GlobalLookupWindow::CaptureBgraAsync(',
    );
    expect(
      cpp,
      contains('void ApplyRoundedShellUnionAlphaMask('),
      reason: 'CapturePreview 不承诺继承 HWND region，必须在 BGRA 边界裁 alpha',
    );
    expect(
      capture,
      contains('route_context_.source == "galCard"'),
      reason: '像素破坏操作只属于游戏内 galCard 路由',
    );
    expect(
      capture,
      contains('capture_shell_rects = shell_rects_css_'),
      reason: '异步 CapturePreview 必须按值快照本次 lookup 的 shell 几何',
    );
    expect(
      capture,
      contains('ApplyRoundedShellUnionAlphaMask('),
      reason: 'WIC 解码成功后、交给共享内存回调前必须应用 mask',
    );
    expect(
      capture.indexOf('ApplyRoundedShellUnionAlphaMask('),
      lessThan(capture.indexOf('(*sink)(')),
      reason: '裁剪必须发生在 BGRA 发布之前',
    );

    final String mask = functionBody(
      cpp,
      'void ApplyRoundedShellUnionAlphaMask(',
    );
    expect(
      mask,
      contains('for (const PhysicalRoundedShell& shell : shells)'),
      reason: '多级查词卡必须逐 shell 做并集，不得给 union bbox 套一个大圆角',
    );
    expect(
      mask,
      contains('std::max(coverage'),
      reason: '重叠 shell 的 alpha coverage 取并集',
    );
    expect(mask, contains('pixel[3] = 0'), reason: '所有 shell 外的方形画布像素必须变为透明');
  });

  test('galCard 有 shell 几何时走 JPEG 快帧，无几何时保留 PNG alpha', () {
    final String capture = functionBody(
      cpp,
      'void GlobalLookupWindow::CaptureBgraAsync(',
    );
    expect(
      capture,
      contains('use_fast_opaque_capture'),
      reason: '只有可由 shell mask 重建 alpha 时才能选择不带 alpha 的快帧',
    );
    expect(
      capture,
      contains('COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_JPEG'),
      reason: '游戏内滚动不能继续为每帧支付 PNG 编码成本',
    );
    expect(
      capture,
      contains('COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG'),
      reason: 'shell 几何未就绪时必须保留带 alpha 的安全回退',
    );
    expect(
      capture.indexOf('capture_shell_rects.empty()'),
      lessThan(
        capture.indexOf('COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_JPEG'),
      ),
      reason: '快帧选择必须由本次 CapturePreview 的几何快照门控',
    );
  });

  test('galCard 主路直接贴 composition HWND，压缩整帧只作回退', () {
    final String reveal = functionBody(
      cpp,
      'bool GlobalLookupWindow::RevealOverProcessClient(',
    );
    expect(reveal, contains('FindProcessClientWindow(pid)'));
    expect(reveal, contains('ClientToScreen(game, &origin)'));
    expect(
      reveal,
      contains('constexpr double scale = 1.0;'),
      reason: '1:1 gate 只容忍整数取整，不得把 HWND resize 伪装成纹理缩放',
    );
    expect(reveal, contains('std::abs(client_width'));
    expect(reveal, contains('std::abs(client_height'));
    expect(
      reveal,
      contains('GWLP_HWNDPARENT'),
      reason: 'composition popup 的 Z 序必须跟随目标游戏，而不是 Fushi 主窗',
    );
    expect(
      reveal,
      contains('Reveal(screen_width, screen_height, false)'),
      reason:
          'game viewport geometry must not be clamped again to desktop rcWork',
    );

    final String present = functionBody(
      voiceReader,
      'void HandleLookupPresent(',
    );
    expect(present, contains('pump.direct_presenter('));
    expect(present, contains('"directSurface"'));
    expect(
      present.indexOf('pump.direct_presenter('),
      lessThan(present.indexOf('if (!pump.capture)')),
      reason: '只有直接 WebView 呈现失败后才能进入 CapturePreview 回退',
    );
    expect(flutterWindow, contains('SetLookupDirectPresenter('));
    expect(flutterWindow, contains('RevealOverProcessClient('));
  });

  test('galCard nested resize keeps a live direct WebView on-screen', () {
    final String resize = functionBody(
      cpp,
      'void GlobalLookupWindow::ResizeStackForGal(',
    );
    expect(resize, contains('direct_process_client_active_'));
    expect(resize, contains('direct_root_anchor_x_ + dx'));
    expect(resize, contains('direct_root_anchor_y_ + dy'));
    expect(resize, contains('SWP_SHOWWINDOW'));
    expect(resize, contains('const bool one_to_one'));
    expect(resize, contains('constexpr double scale = 1.0;'));
    expect(resize, contains('bool transient_direct_failure = false;'));
    expect(resize, contains('bool deterministic_non_one_to_one = false;'));
    expect(
      resize,
      contains('if (was_direct_visible)'),
      reason: 'a transient resize failure must keep the last good HWND visible',
    );
    expect(
      resize,
      contains('two-phase bitmap retirement not available'),
      reason:
          'non-1:1 cannot fast-fallback until the old direct HWND retires after bitmap commit',
    );
    expect(
      resize.indexOf('SetWindowPos(hwnd_, HWND_TOPMOST'),
      lessThan(resize.indexOf('ResizeOffscreen(width, height)')),
      reason:
          'the direct-active branch must resize in place before the off-screen fallback',
    );
    expect(
      flutterWindow,
      contains(
        'win->ResizeStackForGal(\n                IntFromValue(args, "dx", 0),',
      ),
      reason: 'native must not discard the bbox origin sent by Dart',
    );
    expect(
      flutterWindow,
      contains('cursor_work_x = IntFromValue(args, "capX", 0);'),
      reason: 'the game work-area origin must not be silently reset to 0',
    );
    expect(
      flutterWindow,
      contains('cursor_work_y = IntFromValue(args, "capY", 0);'),
    );
  });

  test('迟到的 shellRects 路由不能覆盖当前 lookup 的 capture mask', () {
    final int intercept = cpp.indexOf('"\\"handler\\":\\"shellRects\\""');
    final int set = cpp.indexOf('SetShellRectsFromCsv(body)', intercept);
    final String gate = cpp.substring(intercept, set);
    expect(gate, contains('RouteForMessage(body)'));
    expect(
      gate,
      contains('shell_route.route_epoch == route_context_.route_epoch'),
    );
    expect(
      gate,
      contains('shell_route.lookup_epoch == route_context_.lookup_epoch'),
    );
  });

  test('host：measureAndReport 发 shellRects 且在 overlaySize 之前', () {
    // 量测按路由快照上报：同一个 host 同时服务桌面与游戏内两条路由。
    final int at = hostJs.indexOf('function measureAndReport(routeSnapshot');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  function ', at + 10);
    final String body = hostJs.substring(at, end > at ? end : hostJs.length);
    final int rects = body.indexOf("postToHost('shellRects'");
    final int size = body.indexOf("postToHost('overlaySize'");
    expect(
      rects,
      greaterThanOrEqualTo(0),
      reason: 'measureAndReport 必须上报 per-shell 矩形',
    );
    expect(
      size,
      greaterThan(rects),
      reason: 'shellRects 必须先于 overlaySize（reveal 时 region 已就位）',
    );
    expect(
      body,
      contains("postToHost('shellRects', [rectsCsv, geometryEpoch]"),
      reason: 'shellRects 与 bbox 必须携带同一个 geometry epoch',
    );
    expect(
      body,
      contains('box.geometryEpoch = geometryEpoch'),
      reason: 'overlaySize bbox 必须把事务 epoch 交给 Dart/native',
    );
  });

  test('pending HRGN 在 layer shift 完成后提交且 composition 不请求整窗重绘', () {
    final int regionAt = cpp.indexOf(
      'void GlobalLookupWindow::ApplyRoundedRegion()',
    );
    expect(regionAt, greaterThanOrEqualTo(0));
    final int regionEnd = cpp.indexOf('\n}', regionAt);
    final String regionBody = cpp.substring(
      regionAt,
      regionEnd > regionAt ? regionEnd : cpp.length,
    );
    expect(
      regionBody,
      contains('composition_active_ ? FALSE : TRUE'),
      reason: 'DComp 仍保留 shell HRGN 供 gap 输入穿透，但不请求 user32 重绘整窗',
    );

    final int at = cpp.indexOf(
      'void GlobalLookupWindow::SetShellRectsFromCsv(',
    );
    expect(at, greaterThanOrEqualTo(0));
    final int end = cpp.indexOf('\n}', at);
    final String body = cpp.substring(at, end > at ? end : cpp.length);
    expect(
      body,
      isNot(contains('ApplyRoundedRegion();')),
      reason: 'shellRects 到达时 HWND/layer 还是旧原点，pending HRGN 不得抢跑',
    );

    final int finalizeAt = cpp.indexOf(
      'void GlobalLookupWindow::FinalizePendingShellGeometry(',
    );
    expect(finalizeAt, greaterThanOrEqualTo(0));
    final int finalizeEnd = cpp.indexOf('\n}', finalizeAt);
    final String finalizeBody = cpp.substring(
      finalizeAt,
      finalizeEnd > finalizeAt ? finalizeEnd : cpp.length,
    );
    expect(
      finalizeBody,
      contains('CommitPendingShellGeometry(geometry_epoch)'),
    );
    expect(finalizeBody, contains('ApplyRoundedRegion();'));
    final String applyBody = functionBody(
      cpp,
      'void GlobalLookupWindow::ApplyRoundedRegion()',
    );
    expect(applyBody, contains('region_rects = shell_rects_css_'));
    expect(applyBody, isNot(contains('pending_shell_rects_css_')));
    expect(
      cpp,
      contains('ICoreWebView2ExecuteScriptCompletedHandler'),
      reason: 'matching commitLayerShift 执行完成后才最终提交 HRGN',
    );
    expect(
      cpp,
      contains('ScriptResultIsTrue(error_code, result_json)'),
      reason: '桌面路径必须确认 host 接受 epoch，JS 失败/null/false 不得 fail-open 提交',
    );

    final String galResize = functionBody(
      cpp,
      'void GlobalLookupWindow::ResizeStackForGal(',
    );
    expect(
      galResize,
      isNot(contains('FinalizePendingShellGeometry(')),
      reason: 'gal ExecuteScript completion 不代表新像素已呈现，不得在这里提交 HRGN',
    );
    final int captureAt = cpp.indexOf(
      'body.find("\\"handler\\":\\"captureReady\\"")',
    );
    expect(captureAt, greaterThanOrEqualTo(0));
    final int finalizeCaptureAt = cpp.indexOf(
      'FinalizePendingShellGeometry(geometry_epoch);',
      captureAt,
    );
    final int forwardAt = cpp.indexOf('if (message_cb_)', captureAt);
    expect(finalizeCaptureAt, greaterThan(captureAt));
    expect(
      finalizeCaptureAt,
      lessThan(forwardAt),
      reason: 'double-rAF captureReady 必须先提交 native geometry，再允许 Dart 捕获/呈现',
    );
  });

  test('host：beginLookup 重置 shellRects 去重键', () {
    final int at = hostJs.indexOf('function beginLookup(');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  }', at);
    final String body = hostJs.substring(at, end);
    expect(
      body,
      contains("lastShellRectsKey = ''"),
      reason: 'native 在 Hide 清掉了 rects，新 lookup 相同几何也必须重发',
    );
  });

  test('host：handleGlobalClick 的 gap dismiss 立即 post（不走 200ms slide）', () {
    final int at = hostJs.indexOf('function handleGlobalClick(');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  }', at);
    final String body = hostJs.substring(at, end);
    expect(
      body,
      contains("postToHost('dismissPopupAt', [0])"),
      reason: 'gap 点击的 dismiss 必须同步 post——同一次点击可能已在底下发起新 lookup',
    );
    expect(
      body.contains('dismissRootWithSlide()'),
      isFalse,
      reason: '不得回退到 slide 延迟路径（stale-dismiss 会杀掉新卡，回归 signature）',
    );
  });
}
