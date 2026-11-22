import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';
import '../helpers/source_guard.dart';

/// 视频页顶部浮层（OSD + 制卡结果卡）的定位守卫。
///
/// media_kit 跑不了 headless，全屏视频 + OSD 无法在 widget 测试里真实驱动，故把
/// 不变量钉在 `volume_osd.part.dart` 的接线点：
///
/// * TODO-1254：制卡提示锚在左上角，不居中遮挡画面（TODO-971 曾改成居中，用户报
///   「卡片已覆盖到『…』提示挡在屏幕正中」）。
/// * 用户 2026-11-22：上边距此前恒为「顶栏高 + 8」，顶栏收起后照样空着那段。改成随
///   顶栏显隐过渡（`_followTopChrome` → `noticeTopOffset`，与底部 toast 避让 chrome
///   同一个纯函数），顶栏收起时贴到安全区顶端。
/// * 制卡结果不再挤在 OSD 单槽里：经 `_showMineOsd` 进 [MineNoticeController] 队列，
///   由 `FushiMineNoticeStack` 画在 OSD 下方（处理中原地变结果、连续几张叠起来）。
String _section(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '缺 $signature');
  // 方法自身的 2 空格闭合作段终点（`  }) {` 形参收尾不算）。
  final int end = src.indexOf('\n  }\n', start);
  expect(end, greaterThan(start), reason: '$signature 未闭合');
  return src.substring(start, end);
}

void main() {
  late String src;

  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('制卡结果经 _showMineOsd 进制卡队列，先过「制卡提示」开关', () {
    expect(
      compactCode(src).contains(
        compactCode('_showMineOsd(described.message, described.status'),
      ),
      isTrue,
      reason: '制卡结果必须经 _showMineOsd 出（内容 / 触发不得改）',
    );
    final String body = _section(src, 'void _showMineOsd(');
    expect(body.contains('if (!MineNotices.shown(status)) return;'), isTrue);
    expect(body.contains('_mineNotices.show('), isTrue);
  });

  test('OSD 与制卡队列锚定左上角，不居中（TODO-1254）', () {
    final String body = _section(src, 'Widget _buildOsdOverlay(');
    expect(body.contains('alignment: Alignment.topLeft'), isTrue);
    expect(body.contains('Alignment.center'), isFalse);
    expect(body.contains('FushiMineNoticeStack('), isTrue);
    expect(body.contains('anchor: MineNoticeStackAnchor.top'), isTrue);
    expect(
      _section(src, 'Widget _buildOsdCard(').contains('Alignment.center'),
      isFalse,
    );
  });

  test('顶部浮层上边距随顶栏显隐过渡，不再恒避顶栏（用户 2026-11-22）', () {
    final String overlay = _section(src, 'Widget _buildOsdOverlay(');
    expect(overlay.contains('_followTopChrome('), isTrue);
    expect(
      compactCode(src).contains(compactCode('top: _videoButtonBarHeight + 8')),
      isFalse,
      reason: '写死的「顶栏高 + 8」顶栏收起后照样空着，不许回来',
    );
    final String follow = _section(src, 'Widget _followTopChrome(');
    expect(follow.contains('_videoControlsVisible'), isTrue);
    expect(follow.contains('_videoControlsTransitionDuration'), isTrue);
    final String inset = _section(src, 'double _videoTopChromeInset(');
    expect(inset.contains('noticeTopOffset('), isTrue);
    expect(inset.contains('presence: presence'), isTrue);
    // 角标与字幕转文字进度卡同一口径。
    for (final String sig in <String>[
      'Widget _buildLoopCueBadgeOverlay(',
      'Widget _buildMineQueueBadgeOverlay(',
    ]) {
      expect(
        _section(src, sig).contains('_followTopChrome('),
        isTrue,
        reason: sig,
      );
    }
  });
}
