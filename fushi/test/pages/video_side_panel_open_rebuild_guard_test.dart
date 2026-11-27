import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// BUG-5590：点开视频字幕侧栏，滑入动画卡住大半秒。
///
/// 根因：面板挂载后的帧回调触发 `_ensureSubtitleMenuSourcesLoaded`，它在枚举
/// 开始 / 结束各调一次整页 `_rebuild`（setState）——侧栏整块面板与 media_kit
/// 控件层（`Video` 拿到新参数 → `VideoViewParameters` 变）各从头重建两遍，压在
/// 滑入动画中间。修法：字幕轨菜单的「源列表 + 加载中」改由 `_subtitleMenu`
/// notifier 承载，只有字幕轨区监听它重建。
///
/// media_kit 无法 headless 运行，整页 widget 测试驱不动真播放器；真 app 行为由
/// `integration_test/video_side_panel_raster_perf_itest.dart` 的脏根探针验证（首开
/// 期间面板祖先链上不再出现 `VideoFushiPage`），这里锁住调用点契约。
void main() {
  final String src = readVideoFushiSource();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('字幕源枚举不整页重建', () {
    final String body = region(
      'Future<void> _ensureSubtitleMenuSourcesLoaded() async {',
      '/// BUG-1329：把刚落盘的外挂字幕档',
    );
    expect(
      body.contains('_rebuild('),
      isFalse,
      reason: '枚举在面板挂载那一刻跑，整页 _rebuild 会卡住侧栏滑入动画（BUG-5590）',
    );
    expect(body.contains('_subtitleMenuLoading = true;'), isTrue);
    expect(body.contains('_subtitleMenu.value = ('), isTrue);
  });

  test('YouTube 字幕轨懒加载的加载条不整页重建', () {
    final String body = region(
      'Future<List<AudioCue>?> _resolveYoutubeTrackCues(',
      'if (cues.isNotEmpty) client.cacheCaptionCues(',
    );
    expect(body.contains('_rebuild('), isFalse);
  });

  test('字幕轨区监听 _subtitleMenu 自己重建', () {
    final String body = region(
      'Widget _buildSubtitleTrackSettingsSection(',
      'Widget _buildSubtitleTrackRows(',
    );
    expect(body.contains('valueListenable: _subtitleMenu,'), isTrue);
  });

  test('字幕轨菜单状态不退回 setState 裸字段', () {
    expect(
      RegExp(r'List<SubtitleSource> _subtitleMenuSources\s*=').hasMatch(src),
      isFalse,
    );
    expect(RegExp(r'bool _subtitleMenuLoading\s*=').hasMatch(src), isFalse);
    expect(src.contains('_subtitleMenu.dispose();'), isTrue);
  });
}
