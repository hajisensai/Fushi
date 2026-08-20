import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for the 2026-06-08 video library naming batch (C):
/// ① 多集导入用「系列名」命名播放列表（非某一集文件名）。
/// ② 视频库卡片给播放列表加角标（≥2 集）与单视频区分。
/// ③ 长按菜单加「重命名」。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('① 文件夹/多集导入用 group.series 命名播放列表合集（非集文件名）', () {
    // 不变式没变，标的搬了家：旧的对话框内建合集入口（video_import_dialog 的
    // _importGroup）已随「旧建合集入口移除」删除，唯一还按系列名建 playlist 合集
    // 的生产路径是来源库扫描后的归组协调器。断言随之重指，而不是删掉——不变式
    // 「多集合集名必须是系列名而不是某一集的文件名」依然要守。
    final String src =
        read('lib/src/media/video/video_folder_group_coordinator.dart');
    // 断言标的（跨行，故用正则）：
    //   createMediaCollection(
    //     group.series,
    //     collectionType: 'playlist',
    //   )
    expect(
      RegExp(r"createMediaCollection\(\s*group\.series,\s*"
              r"collectionType: 'playlist',")
          .hasMatch(src),
      isTrue,
      reason: '多集播放列表合集名应是系列名（group.series），不是某一集的文件名；'
          '且自动归组建出来的必须是 playlist 类型合集',
    );
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
