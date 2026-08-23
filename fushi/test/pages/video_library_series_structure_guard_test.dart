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

  test('系列只渲染 AniDB 已刮削结果，全部视频仍保留原始条目', () {
    final String page = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();

    expect(
      page,
      contains('aniDbScrapedVideoCollectionIds()'),
      reason: '系列资格必须来自 AniDB primary identity，不能用 provisional work 冒充',
    );
    expect(page, contains('aniDbScrapedVideoBookUids()'));
    expect(page, contains('_aniDbScrapedCollectionIds'));
    expect(page, contains('_aniDbScrapedBookUids'));

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
    expect(orderedBlock, contains('VideoLibrarySection.series'));
    expect(
      orderedBlock,
      contains('_isAniDbScrapedSeriesMember(b)'),
      reason: '系列入口要先排除无 AniDB 刮削身份的本地散项',
    );
    final int membershipGuardStart = page.indexOf(
      'bool _isAniDbScrapedSeriesMember(',
    );
    final int membershipGuardEnd = page.indexOf(
      '\n  ///',
      membershipGuardStart,
    );
    expect(membershipGuardStart, greaterThanOrEqualTo(0));
    expect(membershipGuardEnd, greaterThan(membershipGuardStart));
    final String membershipGuard = page.substring(
      membershipGuardStart,
      membershipGuardEnd,
    );
    expect(
      RegExp(
        r'_aniDbScrapedCollectionByBookUid\s*\.containsKey\(',
      ).hasMatch(membershipGuard),
      isTrue,
      reason: '多合集成员须优先按 AniDB 已刮削合集归属判断，不能被普通主合集吞掉',
    );
    expect(membershipGuard, contains('_aniDbScrapedBookUids.contains'));

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
    expect(effectiveCollection, contains('VideoLibrarySection.series'));
    expect(
      effectiveCollection,
      contains('_aniDbScrapedCollectionByBookUid[book.bookUid]'),
      reason: '系列筛选、搜索和分组必须共用 canonical collection，book-owned 返回 null',
    );
    expect(effectiveCollection, contains('_primaryCollectionByEntry['));

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
      contains(
        'final bool seriesOnly = '
        'widget.section == VideoLibrarySection.series;',
      ),
    );
    expect(
      RegExp(
        r'groupedRemoteVideos\s*=\s*seriesOnly\s*\?\s*'
        r'const\s*<RemoteVideoInfo>\[\]\s*:\s*remoteVideos',
      ).hasMatch(seriesBuilder),
      isTrue,
      reason: '远端 placeholder 没有本机 canonical identity 证据，不能进系列',
    );
    expect(
      seriesBuilder,
      contains('for (final RemoteVideoInfo video in groupedRemoteVideos)'),
    );

    final int groupLoopStart = seriesBuilder.indexOf(
      'for (final CollectionGroup<_VideoSlot> group in groups)',
    );
    final int groupLoopEnd = seriesBuilder.indexOf(
      'loose.sort(',
      groupLoopStart,
    );
    expect(groupLoopStart, greaterThanOrEqualTo(0));
    expect(groupLoopEnd, greaterThan(groupLoopStart));
    final String groupLoop = seriesBuilder.substring(
      groupLoopStart,
      groupLoopEnd,
    );
    expect(
      RegExp(
        r'_aniDbScrapedCollectionIds\s*\.contains\(\s*'
        r'group\.collection!\.id\s*,?\s*\)',
      ).hasMatch(seriesBuilder),
      isTrue,
      reason: '系列封面卡本身也必须再做 AniDB 刮削集合门控',
    );
    expect(
      RegExp(
        r'if\s*\(\s*group\.collection\s*==\s*null\s*\)',
      ).hasMatch(groupLoop),
      isTrue,
      reason: 'book-owned primary AniDB 结果必须继续作为 loose 卡显示',
    );
    expect(
      seriesBuilder,
      contains('_effectiveCollectionIdForBook(book)'),
      reason: 'Series 分组必须覆盖普通 primary collection，优先 canonical 合集',
    );
    expect(
      seriesBuilder,
      contains('primaryByEntry.remove(key)'),
      reason: '独立 AniDB 作品须解除普通播放列表折叠并作为 loose 结果显示',
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
