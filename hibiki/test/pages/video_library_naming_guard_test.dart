import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for the 2026-06-08 video library naming batch (C):
/// ① 多集导入用「系列名」命名播放列表（非某一集文件名）。
/// ② 视频库卡片给播放列表加角标（≥2 集）与单视频区分。
/// ③ 长按菜单加「重命名」。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('① 文件夹/多集导入用 group.series 命名播放列表（非集文件名）', () {
    final String src = read('lib/src/media/video/video_import_dialog.dart');
    // 播放列表分组导入分支必须用系列名作 title。
    expect(src.contains('title: Value(group.series)'), isTrue,
        reason: '多集播放列表标题应是系列名（group.series），不是某一集的文件名');
  });

  test('② 视频库卡片用 playlistEpisodeCount 区分播放列表并加角标', () {
    final String src =
        read('lib/src/pages/implementations/home_video_page.dart');
    expect(src.contains('playlistEpisodeCount(book.playlistJson)'), isTrue,
        reason: '卡片需按 playlistEpisodeCount 判定是否播放列表');
    expect(src.contains('_buildPlaylistBadge('), isTrue,
        reason: '播放列表需有角标（_buildPlaylistBadge）与单视频区分');
    expect(src.contains('episodeCount >= 2'), isTrue,
        reason: '≥2 集才算播放列表（单元素列表/单视频不加角标）');
    expect(src.contains('t.video_playlist_episodes('), isTrue,
        reason: '角标用 i18n key video_playlist_episodes 显示集数');
  });

  test('③ 长按菜单含「重命名」项 + 重命名落库刷新', () {
    final String src =
        read('lib/src/pages/implementations/home_video_page.dart');
    expect(src.contains('t.video_rename'), isTrue,
        reason: '长按菜单需有重命名项（i18n key video_rename）');
    expect(src.contains('Future<void> _renameVideo('), isTrue,
        reason: '需有 _renameVideo 重命名对话框');
    expect(src.contains('widget.repo.updateTitle('), isTrue,
        reason: '重命名必须经 repo.updateTitle 落库');
  });
}
