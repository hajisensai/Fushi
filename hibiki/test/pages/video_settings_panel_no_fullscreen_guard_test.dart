import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：侧栏打开时点面板不触发全屏/暂停（BUG-246 / TODO-275）。
///
/// 根因：侧栏 overlay 是视频 controls Stack 的子节点，但外层 [Listener] 用
/// `HitTestBehavior.translucent`，落在面板上的 pointer-up 仍冒泡进 [_handleVideoPointerUp]，
/// 其双击判定（400ms/48px）把「连续两次点面板」误判成「双击画面」→ 桌面全屏/移动暂停。
/// 修复在 [_handleVideoPointerUp] 顶部（`_pokeLockButton()` 之后、双击判定之前）加早返回：
/// 任意侧栏开着（`_videoSidePanel.value != null`）时一律不参与 toggle / 双击 / 暂停 / 全屏，
/// 并清掉双击追踪。
///
/// media_kit controls + 全屏路由跑不了 headless，故锁源码结构不变量。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  String handlerBody() {
    final int start = src.indexOf('void _handleVideoPointerUp(PointerUpEvent');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 _handleVideoPointerUp 方法');
    // 到下一个方法（双击 seek helper）为止。
    final int end = src.indexOf('bool _handleDoubleTapSeek(', start);
    expect(end, greaterThan(start),
        reason: '需有 _handleDoubleTapSeek 作为 handler 段终点');
    return src.substring(start, end);
  }

  test('侧栏打开时早返回门控存在且清双击追踪', () {
    final String body = handlerBody();
    final int gateIdx = body.indexOf('if (_videoSidePanel.value != null) {');
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: '侧栏开着时必须早返回，不参与双击/暂停/全屏判定');
    // 门控块内必须清掉双击追踪（避免关闭面板后残留时间戳误配成双击）+ return。
    final int blockEnd = body.indexOf('}', gateIdx);
    expect(blockEnd, greaterThan(gateIdx), reason: '门控块应正常闭合');
    final String block = body.substring(gateIdx, blockEnd);
    expect(block.contains('_lastVideoPointerUpAt = null'), isTrue,
        reason: '门控应清掉 _lastVideoPointerUpAt');
    expect(block.contains('_lastVideoPointerUpPosition = null'), isTrue,
        reason: '门控应清掉 _lastVideoPointerUpPosition');
    expect(block.contains('return'), isTrue, reason: '门控应早返回');
  });

  test('门控排在 _pokeLockButton 之后、双击/全屏判定之前', () {
    final String body = handlerBody();
    final int pokeIdx = body.indexOf('_pokeLockButton();');
    final int gateIdx = body.indexOf('if (_videoSidePanel.value != null) {');
    // 用真实「比较/调用」形态锚定，避开注释里对符号的提及：
    // 双击判据比较 `> _videoDoubleClickInterval`、全屏调用 `_toggleVideoFullscreen(controlsContext)`。
    final int doubleClickIdx = body.indexOf('> _videoDoubleClickInterval');
    final int fullscreenIdx =
        body.indexOf('_toggleVideoFullscreen(controlsContext)');
    expect(pokeIdx, greaterThanOrEqualTo(0), reason: '需有 _pokeLockButton 调用');
    expect(gateIdx, greaterThan(pokeIdx),
        reason: '门控应在 _pokeLockButton 之后（焦点/锁按钮恢复无害）');
    expect(doubleClickIdx, greaterThan(gateIdx),
        reason: '门控应在双击判定（> _videoDoubleClickInterval）之前');
    expect(fullscreenIdx, greaterThan(gateIdx),
        reason: '门控应在全屏调用 _toggleVideoFullscreen(controlsContext) 之前');
  });
}
