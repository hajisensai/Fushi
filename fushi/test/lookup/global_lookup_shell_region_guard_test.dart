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
///
/// 覆盖窗真渲染依赖 native WebView2，headless 测不了，故源码扫描钉住契约；
/// 行为面由 node harness（global_lookup_host_test.mjs R1-R3）覆盖。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hdr;
  late String hostJs;
  setUpAll(() {
    cpp = read('windows/runner/global_lookup_window.cpp');
    hdr = read('windows/runner/global_lookup_window.h');
    hostJs = read('assets/popup/global_lookup_host.js');
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
    expect(intercept, greaterThanOrEqualTo(0),
        reason: 'WebMessageReceived 必须按带引号的 handler 名拦截 shellRects');
    final int forward = cpp.indexOf('if (message_cb_)', intercept);
    final int handle = cpp.indexOf('SetShellRectsFromCsv(body)', intercept);
    expect(handle, greaterThanOrEqualTo(0), reason: '拦截后必须解析并应用 region');
    expect(handle, lessThan(forward),
        reason: 'shellRects 必须在 message_cb_ 转发之前拦截（return，不进 Dart 日志）');
  });

  test('ApplyRoundedRegion：rects 非空走 per-shell 并集，空退回整窗圆角', () {
    final String body =
        functionBody(cpp, 'void GlobalLookupWindow::ApplyRoundedRegion()');
    expect(body, contains('!shell_rects_css_.empty()'),
        reason: '必须按 shell rects 有无分流');
    expect(body, contains('CombineRgn'), reason: '卡片矩形必须以 RGN_OR 并集合成命中/绘制区域');
    expect(body, contains('RGN_OR'), reason: '并集语义（不是交集/差集）');
    expect(
        'CreateRoundRectRgn'.allMatches(body).length, greaterThanOrEqualTo(2),
        reason: 'per-shell 圆角矩形 + 整窗圆角回退两条路径都必须存在');
  });

  test('Hide 与 ForgetDeadWindow 清空缓存 rects（防 stale region 裁掉下一张卡）', () {
    final String hide = functionBody(cpp, 'void GlobalLookupWindow::Hide(');
    expect(hide, contains('shell_rects_css_.clear()'),
        reason: 'Hide 必须清 rects：下一次 lookup 由 host 重新发送');
    final String forget =
        functionBody(cpp, 'void GlobalLookupWindow::ForgetDeadWindow()');
    expect(forget, contains('shell_rects_css_.clear()'),
        reason: '死窗重建路径同样不得携带旧 region');
  });

  test('头文件声明 SetShellRectsFromCsv 与 shell_rects_css_', () {
    expect(
        hdr, contains('void SetShellRectsFromCsv(const std::string& body);'));
    expect(
        hdr, contains('std::vector<std::array<double, 4>> shell_rects_css_;'));
  });

  test('host：measureAndReport 发 shellRects 且在 overlaySize 之前', () {
    // 量测按路由快照上报：同一个 host 同时服务桌面与游戏内两条路由。
    final int at = hostJs.indexOf('function measureAndReport(routeSnapshot)');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  function ', at + 10);
    final String body = hostJs.substring(at, end > at ? end : hostJs.length);
    final int rects = body.indexOf("postToHost('shellRects'");
    final int size = body.indexOf("postToHost('overlaySize'");
    expect(rects, greaterThanOrEqualTo(0),
        reason: 'measureAndReport 必须上报 per-shell 矩形');
    expect(size, greaterThan(rects),
        reason: 'shellRects 必须先于 overlaySize（reveal 时 region 已就位）');
  });

  test('host：beginLookup 重置 shellRects 去重键', () {
    final int at = hostJs.indexOf('function beginLookup(');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  }', at);
    final String body = hostJs.substring(at, end);
    expect(body, contains("lastShellRectsKey = ''"),
        reason: 'native 在 Hide 清掉了 rects，新 lookup 相同几何也必须重发');
  });

  test('host：handleGlobalClick 的 gap dismiss 立即 post（不走 200ms slide）', () {
    final int at = hostJs.indexOf('function handleGlobalClick(');
    expect(at, greaterThanOrEqualTo(0));
    final int end = hostJs.indexOf('\n  }', at);
    final String body = hostJs.substring(at, end);
    expect(body, contains("postToHost('dismissPopupAt', [0])"),
        reason: 'gap 点击的 dismiss 必须同步 post——同一次点击可能已在底下发起新 lookup');
    expect(body.contains('dismissRootWithSlide()'), isFalse,
        reason: '不得回退到 slide 延迟路径（stale-dismiss 会杀掉新卡，回归 signature）');
  });
}
