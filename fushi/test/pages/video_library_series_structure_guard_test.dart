import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频库固定为主页、系列、全部视频、来源四个保活分区', () {
    final String section = File(
      'lib/src/media/video/video_library_section.dart',
    ).readAsStringSync();
    final String shell = File(
      'lib/src/pages/implementations/video_library_shell.dart',
    ).readAsStringSync();

    for (final String value in <String>[
      'home',
      'series',
      'allVideos',
      'sources',
    ]) {
      expect(section, contains(value));
    }
    expect(shell, contains('t.nav_home'));
    expect(shell, contains('t.series'));
    expect(shell, contains('t.video_library_all_videos'));
    expect(shell, contains('t.library_view_sources'));
    expect(shell, contains('Offstage('));
    expect(shell, contains('HomeVideoPage('));
    expect(shell, contains('MediaSourcesPage('));
  });

  test('主页只组装继续观看、下一集和最近添加，系列与原始视频分流', () {
    final String page = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();

    expect(page, contains('_buildContinueRow('));
    expect(page, contains('_buildNextEpisodeRow('));
    expect(page, contains('_buildRecentlyAddedRow('));
    expect(page, contains('_buildLocalVideoSlivers('));
    expect(page, contains('_buildAllVideoSlivers('));
    expect(page, contains('VideoLibrarySection.home'));
    expect(page, contains('VideoLibrarySection.series'));
    expect(page, contains('VideoLibrarySection.allVideos'));
    expect(page, contains('video_source_scrape_tasks_open'));
    expect(page, contains('_AllVideosLayout.grid'));
    expect(page, contains('_AllVideosLayout.list'));
    expect(page, contains('_buildAllVideoListRow('));
    expect(page, contains('video-all-videos-layout-toggle'));
    expect(page, contains('_canonicalCollectionPosterProvider'));
    expect(page, contains('_canonicalBookPosterProvider'));
    expect(
      page,
      contains('forcedOrientation: VideoCardOrientation.portrait'),
      reason: '系列墙必须使用竖版刮削海报，不能再被分集截图探测成横卡',
    );
    expect(page, contains('video_home_continue_episode_number'));
    expect(page, contains('video_home_remaining_minutes'));
    expect(page, contains('_videoRowCardTextBlock'));
    expect(page, contains('getAllVideoMetadataExtras()'));
    expect(
      page,
      contains('_localExtraBookUids.contains(b.bookUid)'),
      reason: '父作品的短篇/花絮必须从系列墙排除，不能再次拆成独立系列卡',
    );
  });

  test('作品详情同时覆盖合集和独立电影，并包含资料、人物及附件区域', () {
    final String route = File(
      'lib/src/pages/implementations/video_work_detail_page.dart',
    ).readAsStringSync();
    final String collection = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();

    expect(route, contains('VideoWorkRef.collection'));
    expect(route, contains('VideoWorkRef.book'));
    expect(route, contains('MediaCollectionDetailPage('));
    expect(route, contains('_StandaloneVideoWorkDetail'));
    for (final String token in <String>[
      'video_work_details',
      'video_work_voice_roles',
      'video_work_cast_crew',
      'video_work_trailers',
      'video_work_extras',
    ]) {
      expect('$route\n$collection', contains(token));
    }
    expect(collection, contains('buildOnlineVideoExtraLaunch'));
    expect(collection, contains('getVideoMetadataExtras(canonicalWork.id)'));
    expect(collection, contains('localExtraUids'));
    expect(collection, contains('_buildExtraRail(t.video_work_extras'));
    expect(collection, contains('VideoFushiPage.neutralized('));
    expect(
      collection,
      contains('useLegacyHeroDetails'),
      reason: '规范作品简介/标签/人物只在 hero 下方完整展示，不能上下重复',
    );
    expect(
      collection,
      isNot(contains('BoxConstraints(maxWidth: 1680)')),
      reason: 'hero 下方的作品资料、人物、附件与选集同样使用全宽内容区',
    );
  });
}
