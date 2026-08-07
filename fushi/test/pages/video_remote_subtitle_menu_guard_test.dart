import 'package:flutter_test/flutter_test.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（#2）：远端视频的字幕源菜单不能再被 [_currentVideoPath]==null 卡死。
///
/// 用源码扫描而非整页 widget pump：远端字幕菜单需要 media_kit 真实加载播放器
/// （headless 不可用），但「修复的不变式」可在源码层稳定守住——
/// [_showSubtitleSourceMenu] 在 `_isRemote` 时分流到独立的远端菜单，远端菜单提供
/// 关闭/host 字幕/本地导入，且远端应用路径不依赖同目录枚举与本地 DB 持久化。
String _readVideoPage() => readVideoFushiSource();

void main() {
  late String src;
  setUpAll(() {
    src = _readVideoPage();
  });

  test('远端模式在字幕菜单不被 videoPath==null 早返回卡死，直接开设置面板「字幕」分类', () {
    // TODO-274：独立 _showRemoteSubtitleMenu 已并入 _showSubtitleSourceMenu。
    // TODO-1351：远端与本地都改为把设置面板开在「字幕」分类（字幕轨切换区按 _isRemote
    // 渲染远端/本地条目）。
    // BUG-939：_showSubtitleSourceMenu 不再自行枚举字幕源（消除每次打开重跑 ffprobe +
    // 闪烁）。远端与本地合并到同一守卫分支 `if (_isRemote || _currentVideoPath == null)`，
    // 该分支只清空可能残留的枚举缓存、**不早返回**，随后无条件
    // `_showPlayerSettings(initialCategory: 'subtitle')`。不变式仍是：远端不能被
    // videoPath==null 早返回卡死——本测试断言方法体内 _isRemote 被考虑、无条件开设置面板
    // 「字幕」分类、且不再自行枚举。
    final int menuIdx = src.indexOf('Future<void> _showSubtitleSourceMenu(');
    expect(menuIdx, greaterThanOrEqualTo(0));
    final int bodyEnd =
        src.indexOf('Future<void> _ensureSubtitleMenuSourcesLoaded(', menuIdx);
    expect(bodyEnd, greaterThan(menuIdx));
    final String body = src.substring(menuIdx, bodyEnd);
    // 远端被考虑（与本地 videoPath==null 合并处理，不再各自早返回）。
    expect(body.contains('_isRemote'), isTrue,
        reason: '_showSubtitleSourceMenu 必须仍考虑 _isRemote（远端不被卡死）');
    // 无条件把设置面板开在「字幕」分类（远端也能到达，不被 videoPath==null 卡死）。
    expect(
        RegExp(r"_showPlayerSettings\([^)]*initialCategory: 'subtitle'")
            .hasMatch(body),
        isTrue,
        reason: '字幕源（含远端）菜单改为把设置面板开在「字幕」分类');
    // BUG-939：控制条「字幕轨」按钮不再自行枚举字幕源（枚举唯一真相源是
    // _ensureSubtitleMenuSourcesLoaded）。
    expect(body.contains('_subtitleSourcesForMenu('), isFalse,
        reason: 'BUG-939：_showSubtitleSourceMenu 不应再自行枚举字幕源');
  });

  test('字幕轨切换区远端分支提供 关闭 / host 字幕 / 本地导入', () {
    // 远端三项接线（清除 / host 字幕 / 本地导入）仍在，TODO-1351 从独立浮动侧栏挪进设置
    // 面板「字幕」分类的字幕轨切换区构建器 _buildSubtitleTrackRows 的 _isRemote 分支。
    expect(src.contains('Widget _buildSubtitleTrackRows('), isTrue,
        reason: '字幕轨切换区内容构建器存在');
    expect(src.contains('_clearRemoteSubtitle('), isTrue);
    expect(src.contains('_pickAndImportRemoteSubtitle('), isTrue);
    expect(src.contains('t.video_subtitle_remote_host'), isTrue);
    expect(src.contains('_remoteSubtitlePath'), isTrue);
  });

  test(
      'remote menu enumerates embedded text tracks from streamurl and downloads by stream index',
      () {
    expect(src.contains('_remoteEmbeddedSubtitleTracks'), isTrue);
    expect(src.contains('urls.embeddedSubtitleTracks'), isTrue);
    expect(src.contains('_applyRemoteEmbeddedSubtitle('), isTrue);
    expect(src.contains('embeddedStreamIndex:'), isTrue);
    expect(src.contains('track.isText'), isTrue,
        reason:
            'graphic tracks must be filtered or disabled, never faked as text');
  });

  test('远端字幕应用路径仅内存（不写本地 VideoBookRepository 持久化）', () {
    // 截取 _applyRemoteSubtitle 函数体，断言其内不调用 repo 持久化方法。
    final int start = src.indexOf('Future<void> _applyRemoteSubtitle(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('Future<void> _clearRemoteSubtitle(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('widget.repo.saveSubtitleSelection'), isFalse);
    expect(body.contains('widget.repo.updateSubtitleSource'), isFalse);
  });

  test('sidecar 和外挂字幕加载按扩展名路由到 async parser', () {
    final int detectStart = src.indexOf(
      'Future<({String path, List<AudioCue> cues})?> _detectSidecar(',
    );
    expect(detectStart, greaterThanOrEqualTo(0));
    final int detectEnd = src.indexOf(
      'Future<List<AudioCue>> _loadExternalSubtitleCues(',
      detectStart,
    );
    expect(detectEnd, greaterThan(detectStart));
    final String detectBody = src.substring(detectStart, detectEnd);
    expect(detectBody.contains('subtitleFormatForPath(sidecarPath)'), isTrue);
    expect(detectBody.contains('await parseSubtitleContentAsync('), isTrue);
    expect(detectBody.contains('parseSubtitleContent('), isFalse,
        reason: 'sidecar auto-detect must not synchronously parse large files');
    expect(detectBody.contains("endsWith('.ass')"), isFalse);

    final int loadStart =
        src.indexOf('Future<List<AudioCue>> _loadExternalSubtitleCues(');
    expect(loadStart, greaterThanOrEqualTo(0));
    final int loadEnd = src.indexOf('Future<void> _applyLoad({', loadStart);
    expect(loadEnd, greaterThan(loadStart));
    final String loadBody = src.substring(loadStart, loadEnd);
    expect(loadBody.contains('subtitleFormatForPath(path)'), isTrue);
    expect(loadBody.contains('await parseSubtitleContentAsync('), isTrue);
    expect(loadBody.contains('parseSubtitleContent('), isFalse,
        reason:
            'external subtitle load must not synchronously parse large files');
    expect(loadBody.contains("endsWith('.ass')"), isFalse);
  });
}
