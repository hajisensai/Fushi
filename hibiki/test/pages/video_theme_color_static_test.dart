import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 剥掉 `_buildVideoSideActionRail` 方法体（TODO-274 右侧悬浮操作 rail）：浮在视频画面
/// 上的圆形操作按钮按播放器惯例用「半透明黑底 + 白图标」做高对比悬浮 chrome（与
/// allowlist 的 letterbox `fill: Colors.black` 同理是覆盖在画面上的内容层，不是跟随主题
/// 的页面 chrome）。白/黑禁令针对的是字幕 / 控制条颜色应跟随 ColorScheme，不应殃及该
/// 悬浮 rail，否则守卫会误把这枚合法浮层按钮判为「硬编码白色」。
String _withoutVideoSideActionRail(String source) {
  const String start = 'Widget _buildVideoSideActionRail(';
  final int startIdx = source.indexOf(start);
  if (startIdx < 0) return source;
  // rail 方法后紧跟一个 doc-comment + 方法；用下一个方法签名作为终点边界。
  final int endIdx = source.indexOf('/// 把 [video]（media_kit', startIdx);
  if (endIdx <= startIdx) return source;
  return source.substring(0, startIdx) + source.substring(endIdx);
}

void main() {
  test('video subtitles and chrome derive visible colors from ColorScheme', () {
    // TODO-590 batch16: 字幕/chrome 取色断言（_subtitleStyle.resolveTextColor 等）与
    // _buildVideoSideActionRail 都已搬到 video_hibiki/layout.part.dart，故读「主壳 + 全部
    // part」合并语料；strip 锚点（rail 起点 + _videoWithSubtitlePanel doc）在 part 内相邻、
    // 合并语料保持原顺序，剥离范围与原单文件等价。
    final String source = _withoutVideoSideActionRail(readVideoHibikiSource());

    expect(source, contains('_subtitleTextColor(ColorScheme'));
    expect(source, contains('_videoChromeColorScheme'));
    expect(source, contains('_videoControlTitleStyle(ColorScheme'));
    expect(source, contains('_osdSurfaceColor(ColorScheme'));
    expect(source, contains('_osdTextColor(ColorScheme'));
    expect(source, contains('_subtitleStyle.resolveTextColor('));
    expect(source, contains('_subtitleStyle.resolveShadowColor('));
    expect(source, contains('_subtitleStyle.resolveBackgroundColor('));
    expect(source, contains('double get _videoUiScale => appModel.appUiScale'));
    expect(source, contains('_subtitleStyle.resolveFontWeight('));
    expect(source, contains('_subtitleStyle.resolveShadowThickness('));
    expect(source, contains('uiScale: _videoUiScale'));
    expect(source, isNot(contains('HibikiAppUiScale.of(context)')));
    expect(source, isNot(contains('fontWeight: _subtitleStyle.fontWeight')));
    expect(source,
        isNot(contains('shadowThickness: _subtitleStyle.shadowThickness')));
    expect(source, isNot(contains('color: Colors.white')));
    expect(source, isNot(contains('color: Colors.black.withValues')));
  });

  test('video letterbox/pillarbox fill is solid black (TODO-053)', () {
    // TODO-590 batch16: letterbox 的 `fill: Colors.black,` 在 _buildVideoBody 已搬到
    // video_hibiki/layout.part.dart，故读「主壳 + 全部 part」合并语料。
    final String source = readVideoHibikiSource();

    // 播放器画面外围（letterbox/pillarbox）按播放器惯例固定纯黑，不跟随主题 surface。
    expect(source, contains('fill: Colors.black,'));
    expect(
      source,
      isNot(contains('fill: Theme.of(context).colorScheme.surface')),
    );
  });
}
