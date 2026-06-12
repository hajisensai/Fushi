import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（#2）：远端视频的字幕源菜单不能再被 [_currentVideoPath]==null 卡死。
///
/// 用源码扫描而非整页 widget pump：远端字幕菜单需要 media_kit 真实加载播放器
/// （headless 不可用），但「修复的不变式」可在源码层稳定守住——
/// [_showSubtitleSourceMenu] 在 `_isRemote` 时分流到独立的远端菜单，远端菜单提供
/// 关闭/host 字幕/本地导入，且远端应用路径不依赖同目录枚举与本地 DB 持久化。
String _readVideoPage() {
  final File f = File('lib/src/pages/implementations/video_hibiki_page.dart');
  if (!f.existsSync()) {
    throw StateError(
        'missing video_hibiki_page.dart (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

void main() {
  late String src;
  setUpAll(() {
    src = _readVideoPage();
  });

  test('远端模式从字幕菜单分流到独立远端菜单（不走 videoPath==null 早返回）', () {
    // _showSubtitleSourceMenu 顶部存在 _isRemote 分支，调用 _showRemoteSubtitleMenu。
    final int menuIdx = src.indexOf('Future<void> _showSubtitleSourceMenu(');
    expect(menuIdx, greaterThanOrEqualTo(0));
    final int nullGuardIdx = src.indexOf('if (videoPath == null) {', menuIdx);
    final int remoteBranchIdx = src.indexOf('if (_isRemote) {', menuIdx);
    expect(remoteBranchIdx, greaterThanOrEqualTo(0));
    // 远端分支必须在 videoPath==null 早返回之前（否则远端永远先被早返回卡死）。
    expect(remoteBranchIdx, lessThan(nullGuardIdx));
    expect(src.contains('_showRemoteSubtitleMenu('), isTrue);
  });

  test('远端字幕菜单提供 关闭 / host 字幕 / 本地导入 三项', () {
    expect(src.contains('Future<void> _showRemoteSubtitleMenu('), isTrue);
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

  test('远端/外挂字幕解析统一按扩展名路由 parser', () {
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
    expect(detectBody.contains('parseSubtitleContent('), isTrue);
    expect(detectBody.contains("endsWith('.ass')"), isFalse);

    final int loadStart =
        src.indexOf('Future<List<AudioCue>> _loadExternalSubtitleCues(');
    expect(loadStart, greaterThanOrEqualTo(0));
    final int loadEnd = src.indexOf('Future<void> _applyLoad({', loadStart);
    expect(loadEnd, greaterThan(loadStart));
    final String loadBody = src.substring(loadStart, loadEnd);
    expect(loadBody.contains('subtitleFormatForPath(path)'), isTrue);
    expect(loadBody.contains('parseSubtitleContent('), isTrue);
    expect(loadBody.contains("endsWith('.ass')"), isFalse);
  });
}
