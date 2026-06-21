import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// BUG-371 源码守卫：打开字幕跳转列表（push-aside 侧栏）时，左/右控制按钮应**继续可见
/// 可用**，不再被强制隐藏。字幕列表是 `Row[Expanded(video), 面板列]`（TODO-314），把画面
/// 挤窄到左侧、不遮挡叠在画面上的控制层/rail，故打开它时不应压制控制条。
///
/// 用户：「字幕列表只是侧边栏，左边的按钮应该还可以换出（仍可用）」。
///
/// 三处抑制门控不含 _subtitleListVisible 的反向断言在
/// video_side_panel_suppress_controls_guard_test.dart；本文件补 `_toggleSubtitleJumpList`
/// 打开分支不再主动收起控制条（`_markControlsVisible(false)`）的不变量。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  String methodBody(String signature, String endMarker) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '需有 $signature');
    final int end = src.indexOf(endMarker, start + signature.length);
    expect(end, greaterThan(start), reason: '需有 $endMarker 作为 $signature 的段终点');
    return src.substring(start, end);
  }

  test('_toggleSubtitleJumpList 打开分支不再 _markControlsVisible(false)', () {
    final String body = methodBody(
      'void _toggleSubtitleJumpList() {',
      'void _closeSubtitleJumpList() {',
    );
    expect(body.contains('_subtitleListVisible.value = true;'), isTrue,
        reason: '打开分支仍应置 _subtitleListVisible = true（push-aside 入口）');
    expect(body.contains('_markControlsVisible(false);'), isFalse,
        reason: 'BUG-371：打开字幕列表不应主动收起控制条——它是 push-aside 不遮控制条，'
            '左/右按钮应继续可见可用');
  });
}
