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
    // 2026-08-13 入库入口统一：来源分段改名「导入」（library_view_import）。
    expect(shell, contains('t.library_view_import'));
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
      reason: '系列墙必须使用竖版刮削封面，不能再被分集截图探测成横卡',
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

  test('系列不按刮削 provider 门控：合集与散卡照常入墙，全部视频仍保留原始条目', () {
    final String page = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();

    // BUG-1839：曾经的判据是「必须有 AniDB primary identity」。用户真实库里 anidb
    // 身份 0 条（AniDB HTTP 身份要求注册 client，没配就写不出来），primary 全是
    // tmdb —— 整个系列页恒空。用户拍板「没刮削也应该进，合集就应该在系列里面」。
    // 系列与「全部视频」的区别是**折叠方式**，不是刮削资格。
    for (final String forbidden in <String>[
      '_isAniDbScrapedSeriesMember',
      '_aniDbScrapedCollectionIds',
      '_aniDbScrapedBookUids',
      '_aniDbScrapedCollectionByBookUid',
      'aniDbScrapedVideoCollectionIds()',
      'aniDbScrapedVideoBookUids()',
    ]) {
      expect(
        page,
        isNot(contains(forbidden)),
        reason: '系列准入不得再按刮削 provider 门控（BUG-1839 回归形态）：$forbidden',
      );
    }

    final int orderedStart = page.indexOf(
      'final List<VideoBookRow> ordered = <VideoBookRow>[',
    );
    final int orderedEnd = page.indexOf(
      '_visibleVideos = ordered;',
      orderedStart,
    );
    expect(orderedStart, greaterThanOrEqualTo(0));
    expect(orderedEnd, greaterThan(orderedStart));
    final String orderedBlock = page.substring(orderedStart, orderedEnd);
    expect(
      orderedBlock,
      contains('_localExtraBookUids.contains(b.bookUid)'),
      reason: '放宽准入不等于放行花絮：父作品的短篇/花絮仍须排除',
    );

    // 归属单一口径：标签过滤 / 标题搜索 / 最终分组共用 _effectiveCollectionIdForBook，
    // 且它自身不得再按分区分叉（分叉正是合集在系列页折不出来的根因）。
    final int effectiveCollectionStart = page.indexOf(
      'int? _effectiveCollectionIdForBook(',
    );
    final int effectiveCollectionEnd = page.indexOf(
      '\n  ///',
      effectiveCollectionStart,
    );
    expect(effectiveCollectionStart, greaterThanOrEqualTo(0));
    expect(effectiveCollectionEnd, greaterThan(effectiveCollectionStart));
    final String effectiveCollection = page.substring(
      effectiveCollectionStart,
      effectiveCollectionEnd,
    );
    expect(effectiveCollection, contains('_primaryCollectionByEntry['));
    expect(
      effectiveCollection,
      isNot(contains('VideoLibrarySection.series')),
      reason: '归属解析不得按分区分叉，否则三处口径又会各走各的',
    );

    final int libraryBodyStart = page.indexOf(
      'Widget _buildVideoLibraryBody()',
    );
    expect(libraryBodyStart, greaterThanOrEqualTo(0));
    final String libraryBody = page.substring(
      libraryBodyStart,
      effectiveCollectionStart,
    );
    expect(
      RegExp(r'_effectiveCollectionIdForBook\(b\)').allMatches(libraryBody).length,
      2,
      reason: '合集标签过滤和作品标题搜索必须与 Series 最终分组使用同一归属',
    );

    final int seriesBuilderStart = page.indexOf(
      'List<Widget> _buildLocalVideoSlivers(',
    );
    final int allVideosBuilderStart = page.indexOf(
      'List<Widget> _buildAllVideoSlivers(',
    );
    expect(seriesBuilderStart, greaterThanOrEqualTo(0));
    expect(allVideosBuilderStart, greaterThan(seriesBuilderStart));
    final String seriesBuilder = page.substring(
      seriesBuilderStart,
      allVideosBuilderStart,
    );
    expect(
      seriesBuilder,
      contains('final List<RemoteVideoInfo> groupedRemoteVideos = remoteVideos;'),
      reason: '远端占位卡也不再被整体挡在系列外（同一条准入放宽）',
    );
    expect(
      seriesBuilder,
      contains('for (final RemoteVideoInfo video in groupedRemoteVideos)'),
    );
    expect(
      seriesBuilder,
      contains('child: _buildFilteredEmpty()'),
      reason: '筛选后无结果不能误报整个媒体库为空并引导重新导入',
    );

    final int allVideosBuilderEnd = page.indexOf(
      'Widget _buildAllVideoListRow(',
      allVideosBuilderStart,
    );
    expect(allVideosBuilderEnd, greaterThan(allVideosBuilderStart));
    final String allVideosBuilder = page.substring(
      allVideosBuilderStart,
      allVideosBuilderEnd,
    );
    for (final String token in <String>[
      '_buildAllVideoListRow(book)',
      '_buildAllVideoRemoteListRow(video)',
      '_buildCard(book, orientation: orientation)',
      '_buildRemoteVideoCard(video, orientation: orientation)',
    ]) {
      expect(
        allVideosBuilder,
        contains(token),
        reason: '全部视频必须继续保留原始本地与远端条目路径：$token',
      );
    }
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
