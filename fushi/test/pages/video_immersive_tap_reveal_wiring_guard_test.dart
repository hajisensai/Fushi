import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：沉浸锁定态「点画面显示字幕」的页面接线（设计案
/// `docs/specs/2026-10-25-video-immersive-one-hand.md` §3.1）。判据与 overlay 句柄的行为
/// 由 `test/media/video/video_immersive_tap_reveal_test.dart` 覆盖；播放页依赖真
/// media_kit controller 跑不了 headless，这里钉住「点画面那条路径真的调到了句柄」。
String _section(String src, String startToken, String endToken) {
  final int start = src.indexOf(startToken);
  expect(start, greaterThanOrEqualTo(0), reason: '缺少 $startToken');
  final int end = src.indexOf(endToken, start);
  expect(end, greaterThan(start), reason: '$startToken 后缺少 $endToken');
  return src.substring(start, end);
}

void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('点画面抬起：过了按钮 / 面板早返回之后、双击判定之前调显形', () {
    final String up = _section(
      src,
      'void _handleVideoPointerUp(PointerUpEvent event) {',
      'void _handleVideoWheelSignal(',
    );
    final int chromeGate = up.indexOf('chromePointer) {');
    final int reveal = up.indexOf(
      '_maybeToggleImmersiveSubtitleReveal(event.position);',
    );
    final int doubleTap = up.indexOf('final DateTime now = DateTime.now();');
    expect(chromeGate, greaterThanOrEqualTo(0), reason: '按钮 / chrome 早返回仍在');
    expect(reveal, greaterThan(chromeGate), reason: '点在按钮上不得显形字幕（按钮早返回必须在前）');
    expect(doubleTap, greaterThan(reveal), reason: '单击立即显形，不等双击窗口');
  });

  test('显形判据走纯函数 + 读三项偏好，并跳过点在字幕字符上的查词点击', () {
    final String body = _section(
      src,
      'void _maybeToggleImmersiveSubtitleReveal(Offset globalPosition) {',
      'void _handleVideoWheelSignal(',
    );
    final String flat = compactCode(body);
    expect(flat, contains(compactCode('videoImmersiveTapRevealsSubtitle(')));
    for (final String arg in <String>[
      'immersiveLocked: _immersiveLocked.value',
      'tapRevealEnabled: appModel.videoImmersiveTapReveal',
      'obscureMode: appModel.videoSubtitleObscureMode',
      'revealOnInteraction: appModel.videoSubtitleObscureReveal',
    ]) {
      expect(flat, contains(compactCode(arg)), reason: arg);
    }
    expect(
      flat,
      contains(
        compactCode(
          '_subtitleHitTester.hitTest(globalPosition, exactOnly: true) != null',
        ),
      ),
      reason: '点在已显形的字上是查词，不得顺手把这句遮回去',
    );
    expect(
      flat,
      contains(compactCode('_subtitleRevealHandle.toggleMainReveal()')),
    );
  });

  test('字幕 overlay 挂上了显形句柄', () {
    expect(
      compactCode(src),
      contains(compactCode('revealHandle: _subtitleRevealHandle,')),
    );
  });
}
