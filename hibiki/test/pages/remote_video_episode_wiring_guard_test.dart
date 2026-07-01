import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-885 守卫：远端视频「剧集列表」四层接线在 UI 层真正落地（源码守卫）。
///
/// 远端播放列表此前全链路只有「单个平铺视频」概念：`_initRemote` 早退、`_isPlaylist`
/// 恒 false、远端卡无集数角标。本守卫断言修复后：
/// 1. `_initRemote` 把 `info.episodes` 映射进 `_episodes`（不再恒空）；
/// 2. 远端切集走 `_loadRemoteEpisode`（按 episodeIndex 向 host 重新建流），
///    `_switchEpisode` 远端分支接通；
/// 3. 远端卡在 `isPlaylist` 时渲染集数角标。
/// 撤任一接线即转红。
void main() {
  final File videoPage =
      File('lib/src/pages/implementations/video_hibiki_page.dart');
  final File episodePart =
      File('lib/src/pages/implementations/video_hibiki/episode.part.dart');
  final File homeVideo =
      File('lib/src/pages/implementations/home_video_page.dart');

  late String pageSrc;
  late String episodeSrc;
  late String homeSrc;

  setUpAll(() {
    expect(videoPage.existsSync(), isTrue);
    expect(episodePart.existsSync(), isTrue);
    expect(homeVideo.existsSync(), isTrue);
    pageSrc = videoPage.readAsStringSync();
    episodeSrc = episodePart.readAsStringSync();
    homeSrc = homeVideo.readAsStringSync();
  });

  test('_initRemote maps info.episodes into _episodes (no longer always empty)',
      () {
    final int start = pageSrc.indexOf('Future<void> _initRemote() async {');
    expect(start, isNonNegative);
    final int end = pageSrc.indexOf('Future<void> _loadRemoteEpisode(', start);
    expect(end, isNonNegative);
    final String initRemote = pageSrc.substring(start, end);
    expect(
      initRemote.contains('for (final RemoteVideoEpisode ep in info.episodes)'),
      isTrue,
      reason: 'remote playlist episodes must be mapped into _episodes',
    );
    expect(
      initRemote.contains('PlaylistEntry(title: ep.title'),
      isTrue,
      reason: 'remote episodes drive the existing _episodes/_isPlaylist path',
    );
  });

  test('remote episode switch streams by episodeIndex (DB-only, not host path)',
      () {
    // _loadRemoteEpisode 向 host 按 episodeIndex 换流式 url（绝不用本地 path）。
    final int loadStart = pageSrc.indexOf('Future<void> _loadRemoteEpisode(');
    expect(loadStart, isNonNegative);
    // TODO-1000：分离流（video-only + 外挂 audio-only）接线把 _loadRemoteEpisode 撑大，
    // getRemoteVideoSubtitle 落到旧 1200 字窗外 → 守卫误报。改切到方法体真实终点（下一
    // Future 成员声明），不变量强度不变：仍断言按 episodeIndex 取流 + 字幕。
    final int loadEnd = pageSrc.indexOf('\n  Future<', loadStart + 10);
    expect(loadEnd, greaterThan(loadStart),
        reason: '缺 _loadRemoteEpisode 方法体终点锚');
    final String loadEp = pageSrc.substring(loadStart, loadEnd);
    expect(
      loadEp.contains('remoteVideoStreamUrls(') &&
          loadEp.contains('episodeIndex: index,'),
      isTrue,
      reason: 'remote episode load must request stream by episodeIndex',
    );
    expect(
      loadEp.contains('getRemoteVideoSubtitle(') &&
          loadEp.contains('episodeIndex: index,'),
      isTrue,
      reason: 'remote episode subtitle must also be fetched by episodeIndex',
    );
    // _switchEpisode 远端分支接通 _loadRemoteEpisode。
    expect(
      episodeSrc.contains('if (_isRemote) {') &&
          episodeSrc.contains('_loadRemoteEpisode(index, startIntent: intent)'),
      isTrue,
      reason: 'episode switch must route remote videos to _loadRemoteEpisode',
    );
  });

  test('remote card renders episode-count badge when isPlaylist', () {
    expect(
      homeSrc.contains('if (video.isPlaylist)') &&
          homeSrc.contains('_buildPlaylistBadge(video.episodes.length)'),
      isTrue,
      reason: 'remote playlist card must show the episode-count badge',
    );
  });
}
