import 'dart:isolate';

import 'package:drift/isolate.dart' show DriftIsolate;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_continue.dart'
    show CollectionMemberProgress;
import 'package:fushi/src/media/collections/collection_episode_slot.dart'
    show remoteEpisodesMirroredLocally;
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart'
    show applyVideoFolderCollectionPolicy;
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_memo.dart'
    show entriesOfKind;
import 'package:fushi/src/media/video/video_library_overview.dart'
    show latestWatchAtByKey;
import 'package:fushi/src/media/video/video_library_scrape_maps.dart'
    show
        buildCollectionScrapeMetaById,
        buildVideoWorksByCollection,
        videoCollectionWorkTitle,
        videoLocalExtraBookUids;
import 'package:fushi/src/sync/remote_video_client.dart' show RemoteVideoSource;
import 'package:fushi_core/fushi_core.dart'
    show
        CollectionScrapeMetaRow,
        FushiDatabase,
        MediaCollectionItemRow,
        MediaCollectionRow,
        MediaKind,
        MediaSourceRow,
        VideoBookRow,
        VideoMetadataExtraRow,
        VideoMetadataWorkRow,
        VideoWatchStatisticRow,
        kActivityMediaVideo;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 视频「继续观看」的唯一选集口径（BUG 见 `video-peek-continue-mismatch`）。
///
/// 视频首页首屏的继续观看（`HomeVideoPage`）与侧栏悬停速览（`home_nav_peek`）
/// 此前各写一套：速览只读本机行、按「最近播放（看完也算）」挑，完全不认互联 host
/// 上的远端占位，于是首页明明有「☁ 下一集 · 第 1 集」，速览却说没有可继续的。
/// 现在两处都只调 [selectVideoContinueCandidates]，选出的是同一份候选、同一顺序；
/// 输入快照（合集归属 / 组内序 / 最近观看时刻 / 片长 / 特典）由 [VideoContinueInputs]
/// 承载，从库里现读一份走 [loadVideoContinueLibrary]。

/// 首页横滚行 / 继续观看的统一成员槽：本地视频行 [local] 或「只在 host 上」的远端
/// 占位 [remote]，二者恰一非空。
class VideoHomeSlot {
  const VideoHomeSlot({this.local, this.remote})
    : assert(local != null || remote != null);

  final VideoBookRow? local;
  final RemoteVideoInfo? remote;

  /// 成员键：本地 bookUid / 远端 host 侧 id（同域，见 `CollectionEpisodeSlot.entryKey`）。
  String get uid => local?.bookUid ?? remote!.id;

  /// 这一集还没开播（没打勾、没进度）：继续观看落到它时文案是「下一集 · 第 N 集」。
  bool get unstarted => local != null
      ? local!.completedAt == null && local!.lastPositionMs <= 0
      : remote!.completedAt == null && remote!.positionMs <= 0;
}

/// 选集要用的库级快照。[collectionIdByUid] / [sortIndexByUid] 按**裸 uid** 键控
/// （复合键表经 [entriesOfKind] 换过来）；[watchAtByUid] / [legacyWatchAtByTitle] 是
/// 本机播放统计的最近观看时刻（[buildVideoWatchRecency]）。
class VideoContinueInputs {
  const VideoContinueInputs({
    required this.collectionIdByUid,
    required this.collectionsById,
    required this.sortIndexByUid,
    required this.watchAtByUid,
    required this.legacyWatchAtByTitle,
    required this.durationMsOf,
    this.excludedUids = const <String>{},
    this.metadataWorkByCollection = const <int, VideoMetadataWorkRow>{},
    this.collectionScrapeMetaById = const <int, CollectionScrapeMetaRow>{},
  });

  final Map<String, int> collectionIdByUid;
  final Map<int, MediaCollectionRow> collectionsById;
  final Map<String, int> sortIndexByUid;
  final Map<String, DateTime> watchAtByUid;
  final Map<String, DateTime> legacyWatchAtByTitle;

  /// 播放器记下的片长（`video_duration_pref`）；没播过 → null。
  final int? Function(String bookUid) durationMsOf;

  /// 不进继续观看的本地条目（刮削认定的特典）。
  final Set<String> excludedUids;

  /// 作品名回落链的两张表（[videoCollectionWorkTitle]）。
  final Map<int, VideoMetadataWorkRow> metadataWorkByCollection;
  final Map<int, CollectionScrapeMetaRow> collectionScrapeMetaById;

  /// 合集显示的作品名（与视频首页合集卡同一条回落链）。
  String workTitleOf(MediaCollectionRow collection) => videoCollectionWorkTitle(
    collection,
    metadataWorkByCollection: metadataWorkByCollection,
    collectionScrapeMetaById: collectionScrapeMetaById,
  );

  /// 组内序（没有成员行的排最后）。
  int sortIndexOf(VideoHomeSlot slot) => sortIndexByUid[slot.uid] ?? 1 << 30;

  /// 本机播放统计记下的最近观看时刻（缺 uid 行时按标题回落迁移遗留行）。
  DateTime? statsWatchedAt(VideoBookRow book) =>
      watchAtByUid[book.bookUid] ?? legacyWatchAtByTitle[book.title];

  /// 最近观看时刻（epoch 毫秒，0 = 没看过）。本地取统计与行级 lastPlayedAt 的较新者
  /// （BUG-1731）；远端的真相源是 host 下发的 [RemoteVideoInfo.positionUpdatedAtMs]。
  int watchedAtMsOf(VideoHomeSlot slot) {
    final VideoBookRow? local = slot.local;
    if (local != null) {
      return effectiveWatchedAtMs(
        statsWatchedAtMs: statsWatchedAt(local)?.millisecondsSinceEpoch ?? 0,
        lastPlayedAt: local.lastPlayedAt,
      );
    }
    return slot.remote!.positionUpdatedAtMs;
  }

  List<VideoSeriesPlaybackState> playbackStatesOf(List<VideoHomeSlot> slots) =>
      <VideoSeriesPlaybackState>[
        for (final VideoHomeSlot slot in slots)
          VideoSeriesPlaybackState(
            lastWatchedAtMs: watchedAtMsOf(slot),
            positionMs: slot.local?.lastPositionMs ?? slot.remote!.positionMs,
            completed: slot.local != null
                ? slot.local!.completedAt != null
                : slot.remote!.completedAt != null,
            durationMs: slot.local != null
                ? durationMsOf(slot.local!.bookUid)
                : slot.remote!.durationMs,
          ),
      ];
}

/// 继续观看的一个候选；[recentMs] 是排序键（最近观看时刻，epoch 毫秒）。
sealed class VideoContinueCandidate {
  const VideoContinueCandidate({required this.recentMs});

  final int recentMs;
}

/// 合集候选：[members] 是按组内序排好的本地 + 远端成员，[targetIndex] 是 Next-Up
/// 目标集（[continueWatchingSeriesIndex]），[completedCount] 是已看完的成员数。
final class VideoContinueSeriesCandidate extends VideoContinueCandidate {
  const VideoContinueSeriesCandidate({
    required super.recentMs,
    required this.collection,
    required this.title,
    required this.members,
    required this.targetIndex,
    required this.completedCount,
  });

  final MediaCollectionRow collection;

  /// 作品名（[VideoContinueInputs.workTitleOf]，刮削标题优先、回落合集名）。
  final String title;
  final List<VideoHomeSlot> members;
  final int targetIndex;
  final int completedCount;

  VideoHomeSlot get target => members[targetIndex];
}

/// 本地散片候选（不属于任何现存合集）。
final class VideoContinueLocalCandidate extends VideoContinueCandidate {
  const VideoContinueLocalCandidate({
    required super.recentMs,
    required this.book,
  });

  final VideoBookRow book;
}

/// 远端散片候选（只在 host 上、不属于任何现存合集）。
final class VideoContinueRemoteCandidate extends VideoContinueCandidate {
  const VideoContinueRemoteCandidate({
    required super.recentMs,
    required this.video,
  });

  final RemoteVideoInfo video;
}

/// 「继续观看」候选，按最近观看倒序。纯函数。
///
/// 合集成员本地行 + 远端占位合成一条稳定集序再选集（BUG-3611），选集走
/// [continueWatchingSeriesIndex]（Next-Up：最近那集没看完停它、看完取下一集；整部
/// 看完不进）。散片：没进度、或已看完（打勾 / 进度到片尾区，BUG-3491）不进。
List<VideoContinueCandidate> selectVideoContinueCandidates({
  required List<VideoBookRow> local,
  required List<RemoteVideoInfo> remote,
  required VideoContinueInputs inputs,
}) {
  final Map<int, List<VideoHomeSlot>> grouped = <int, List<VideoHomeSlot>>{};
  final List<VideoBookRow> looseLocal = <VideoBookRow>[];
  final List<RemoteVideoInfo> looseRemote = <RemoteVideoInfo>[];
  for (final VideoBookRow book in local) {
    if (inputs.excludedUids.contains(book.bookUid)) continue;
    final int? cid = inputs.collectionIdByUid[book.bookUid];
    if (cid != null && inputs.collectionsById.containsKey(cid)) {
      grouped
          .putIfAbsent(cid, () => <VideoHomeSlot>[])
          .add(VideoHomeSlot(local: book));
    } else {
      looseLocal.add(book);
    }
  }
  for (final RemoteVideoInfo video in remote) {
    final int? cid = inputs.collectionIdByUid[video.id];
    if (cid != null && inputs.collectionsById.containsKey(cid)) {
      grouped
          .putIfAbsent(cid, () => <VideoHomeSlot>[])
          .add(VideoHomeSlot(remote: video));
    } else {
      looseRemote.add(video);
    }
  }
  final List<VideoContinueCandidate> items = <VideoContinueCandidate>[];
  grouped.forEach((int cid, List<VideoHomeSlot> members) {
    members.sort(
      (VideoHomeSlot a, VideoHomeSlot b) =>
          inputs.sortIndexOf(a).compareTo(inputs.sortIndexOf(b)),
    );
    final List<VideoSeriesPlaybackState> states = inputs.playbackStatesOf(
      members,
    );
    int completed = 0;
    int recentMs = 0;
    for (int i = 0; i < members.length; i++) {
      // 手动标记或进度到片尾区都算看完（BUG-3491）。
      if (states[i].progress.countsAsWatched) completed++;
      final int watched = inputs.watchedAtMsOf(members[i]);
      if (watched > recentMs) recentMs = watched;
    }
    final int? targetIndex = continueWatchingSeriesIndex(states);
    if (targetIndex == null) return;
    final MediaCollectionRow collection = inputs.collectionsById[cid]!;
    items.add(
      VideoContinueSeriesCandidate(
        recentMs: recentMs,
        collection: collection,
        title: inputs.workTitleOf(collection),
        members: members,
        targetIndex: targetIndex,
        completedCount: completed,
      ),
    );
  });
  for (final VideoBookRow book in looseLocal) {
    // 已打勾但重看到一半的单片同样进（BUG-3491）。
    if (book.lastPositionMs <= 0 ||
        CollectionMemberProgress(
          positionMs: book.lastPositionMs,
          completed: book.completedAt != null,
          durationMs: inputs.durationMsOf(book.bookUid),
        ).isFinished) {
      continue;
    }
    items.add(
      VideoContinueLocalCandidate(
        recentMs: inputs.statsWatchedAt(book)?.millisecondsSinceEpoch ?? 0,
        book: book,
      ),
    );
  }
  for (final RemoteVideoInfo video in looseRemote) {
    if (video.positionMs <= 0 ||
        CollectionMemberProgress(
          positionMs: video.positionMs,
          completed: video.completedAt != null,
          durationMs: video.durationMs,
        ).isFinished) {
      continue;
    }
    items.add(
      VideoContinueRemoteCandidate(
        recentMs: video.positionUpdatedAtMs,
        video: video,
      ),
    );
  }
  items.sort(
    (VideoContinueCandidate a, VideoContinueCandidate b) =>
        b.recentMs.compareTo(a.recentMs),
  );
  return items;
}

/// 合集目标集的副标题：目标集还没开播 →「下一集 · 第 N 集」；有进度时本地集交给
/// [startedLocalText]（首页拼「剩 M 分钟」，速览只要集号），远端集「看到第 N 集」。
String videoContinueSeriesSubtitle(
  VideoContinueSeriesCandidate candidate, {
  String Function(VideoBookRow book, int episodeNumber)? startedLocalText,
}) {
  final VideoHomeSlot target = candidate.target;
  final int n = candidate.targetIndex + 1;
  if (target.unstarted) return t.video_home_next_episode_number(n: n);
  final VideoBookRow? local = target.local;
  if (local != null && startedLocalText != null) {
    return startedLocalText(local, n);
  }
  return t.video_home_continue_episode_number(n: n);
}

/// 视频库的折叠归属与组内序（复合键 `video|<uid>`）。
typedef VideoLibraryMembership = ({
  Map<String, int> primary,
  Map<String, int> memberSortIndex,
});

/// 视频条目的折叠主归属（经 [applyVideoFolderCollectionPolicy] 修正）与组内序。
///
/// 与「[FushiDatabase.getPrimaryCollectionIdByEntry] + 整张成员表 +
/// [buildVideoMemberSortIndex]」在视频键上逐条相同，但只吃两份小得多的输入：
/// [rawPrimary]（[FushiDatabase.getPrimaryCollectionMembershipOfKind]，每条目一行
/// 主合集 + 组内序）与 [libraryVideoItems]（[FushiDatabase.getLibraryVideoMemberRows]，
/// 本机视频自己的成员行）。目录合集策略只改本机视频（`books` 里的）的归属，其余
/// 条目（远端主机的视频）维持原始主归属，组内序就是 [rawPrimary] 里那一行。媒体
/// 服务器镜像的播放列表让成员表达数万行，从前三个入口（视频库页、首页继续观看、
/// 伴屏）每次各把整表连同一遍整表 GROUP BY 搬进 UI isolate。
VideoLibraryMembership resolveVideoLibraryMembership({
  required Map<String, ({int collectionId, int sortIndex})> rawPrimary,
  required List<MediaCollectionItemRow> libraryVideoItems,
  required List<MediaCollectionRow> collections,
  required List<VideoBookRow> books,
  required List<MediaSourceRow> sources,
}) {
  final Map<String, int> primary = applyVideoFolderCollectionPolicy(
    primary: <String, int>{
      for (final MapEntry<String, ({int collectionId, int sortIndex})> e
          in rawPrimary.entries)
        e.key: e.value.collectionId,
    },
    collections: collections,
    items: libraryVideoItems,
    books: books,
    sources: sources,
  );
  final Map<String, int> localSortIndex = <String, int>{
    for (final MediaCollectionItemRow m in libraryVideoItems)
      '${m.mediaType}|${m.entryKey}#${m.collectionId}': m.sortIndex,
  };
  final Map<String, int> memberSortIndex = <String, int>{};
  primary.forEach((String key, int collectionId) {
    final ({int collectionId, int sortIndex})? raw = rawPrimary[key];
    final int? sortIndex = raw != null && raw.collectionId == collectionId
        ? raw.sortIndex
        : localSortIndex['$key#$collectionId'];
    if (sortIndex != null) memberSortIndex[key] = sortIndex;
  });
  return (primary: primary, memberSortIndex: memberSortIndex);
}

/// 测试开关：为真时 [loadVideoLibraryMembership] 在调用方 isolate 里读库（组件测试
/// 跑在 FakeAsync 里，跨 isolate 消息推不动）。生产恒为假。
@visibleForTesting
bool debugVideoMembershipInline = false;

/// 后台 isolate 的调试名（timeline / 栈里认得出）。
const String kVideoMembershipIsolateDebugName = 'fushi-video-membership';

/// 读出视频的折叠归属与组内序（[resolveVideoLibraryMembership]），读库与套策略都在
/// 一次性后台 isolate 里（经 [FushiDatabase.backgroundConnection] 接同一个库），结果经
/// `Isolate.exit` 交回、不逐对象拷贝。
///
/// 远端主机的视频也要归属，主归属查询收不窄：媒体服务器镜像的播放列表让它达数万行，
/// 从前在 UI isolate 上解码这批行是首次打开视频页时最大的一段掉帧（BUG-5589）。
/// [books] 是调用方口径的本机视频（目录合集策略只改这些键的归属）。
Future<VideoLibraryMembership> loadVideoLibraryMembership(
  FushiDatabase db, {
  required List<VideoBookRow> books,
}) async {
  if (debugVideoMembershipInline) {
    return _loadVideoLibraryMembershipHere(db, books);
  }
  return _loadVideoLibraryMembershipInBackground(
    await db.backgroundConnection(),
    books,
  );
}

/// 闭包只捕获本函数的两个参数（都可发送），不碰调用方的库对象。
Future<VideoLibraryMembership> _loadVideoLibraryMembershipInBackground(
  DriftIsolate connection,
  List<VideoBookRow> books,
) => Isolate.run<VideoLibraryMembership>(() async {
  final FushiDatabase db = FushiDatabase.shared(await connection.connect());
  try {
    return await _loadVideoLibraryMembershipHere(db, books);
  } finally {
    await db.close();
  }
}, debugName: kVideoMembershipIsolateDebugName);

Future<VideoLibraryMembership> _loadVideoLibraryMembershipHere(
  FushiDatabase db,
  List<VideoBookRow> books,
) async {
  final Future<Map<String, ({int collectionId, int sortIndex})>> rawF = db
      .getPrimaryCollectionMembershipOfKind(MediaKind.video);
  final Future<List<MediaCollectionItemRow>> itemsF = db
      .getLibraryVideoMemberRows();
  final Future<List<MediaCollectionRow>> collectionsF = db
      .getAllMediaCollections();
  final Future<List<MediaSourceRow>> sourcesF = db.getMediaSourcesByKind(
    'video',
  );
  await Future.wait<Object?>(<Future<Object?>>[
    rawF,
    itemsF,
    collectionsF,
    sourcesF,
  ]);
  return resolveVideoLibraryMembership(
    rawPrimary: await rawF,
    libraryVideoItems: await itemsF,
    collections: await collectionsF,
    books: books,
    sources: await sourcesF,
  );
}

/// 层次 C：条目在其主折叠合集里的组内序（复合键 → sortIndex）。只记归属合集的
/// 行——一条目属多合集时组内序跟随折叠归属。
Map<String, int> buildVideoMemberSortIndex({
  required Map<String, int> primaryCollectionByEntry,
  required List<MediaCollectionItemRow> items,
}) {
  final Map<String, int> out = <String, int>{};
  for (final MediaCollectionItemRow m in items) {
    final String key = '${m.mediaType}|${m.entryKey}';
    if (primaryCollectionByEntry[key] == m.collectionId) {
      out[key] = m.sortIndex;
    }
  }
  return out;
}

/// 「最近观看」两份映射（按 uid / 迁移遗留 NULL-uid 行按标题）。
typedef VideoWatchRecency = ({
  Map<String, DateTime> byUid,
  Map<String, DateTime> legacyByTitle,
});

/// watch-stats 全量行 + `study_segments` 最近时刻 → [VideoWatchRecency]。
///
/// v39 新行按 bookUid 键控；迁移遗留 NULL-uid 行按 title 建回退映射。v92 起
/// `video_watch_statistics` 冻结为 legacy 只读，新的观看只写 `study_segments`：两处
/// 的 (uid, 时刻) 一起喂 [latestWatchAtByKey]，同 uid 取最大。无身份判定 NULL 与 ''
/// 都算（'' 行进不了任何 uid 匹配，落标题回退才不会从「最近观看」消失）。首页的全量
/// 与窄刷新、速览的现读都走这里，映射逐字节一致。
VideoWatchRecency buildVideoWatchRecency(
  List<VideoWatchStatisticRow> watchRows,
  Map<String, int> segmentEndAtByUid,
) => (
  byUid: latestWatchAtByKey(<(String, int)>[
    for (final VideoWatchStatisticRow r in watchRows)
      if (r.bookUid case final String uid when uid.isNotEmpty)
        (uid, r.lastModified),
    for (final MapEntry<String, int> e in segmentEndAtByUid.entries)
      if (e.key.isNotEmpty) (e.key, e.value),
  ]),
  legacyByTitle: latestWatchAtByKey(<(String, int)>[
    for (final VideoWatchStatisticRow r in watchRows)
      if (r.bookUid == null || r.bookUid!.isEmpty) (r.title, r.lastModified),
  ]),
);

/// 首页可见的远端占位（不过任何筛选）：「显示远端条目」开着、清单没失败、对端没
/// 上锁（或本次会话已解锁），且本机同一合集里没有同一集（BUG-2978）。首页与速览
/// 同一判据。
List<RemoteVideoInfo> visibleHomeRemoteVideos({
  required List<RemoteVideoInfo> remote,
  required List<VideoBookRow> local,
  required Map<String, int> primaryCollectionByEntry,
  required MediaVisibility visibility,
  required bool showRemoteEntries,
}) {
  if (!showRemoteEntries || remote.isEmpty) return const <RemoteVideoInfo>[];
  final Set<String> mirrored = remoteEpisodesMirroredLocally(
    local: local,
    remote: remote,
    collectionOfEntry: (String entryKey) =>
        primaryCollectionByEntry[MediaKind.video.compositeKey(entryKey)],
  );
  return <RemoteVideoInfo>[
    for (final RemoteVideoInfo v in remote)
      if (!visibility.hidesRemoteVideo(v) && !mirrored.contains(v.id)) v,
  ];
}

/// 从库里现读的一份继续观看快照（没开过视频页时速览用）。
class VideoContinueLibrary {
  const VideoContinueLibrary({
    required this.books,
    required this.primaryCollectionByEntry,
    required this.collectionsById,
    required this.memberSortIndex,
    required this.recency,
    required this.localExtraBookUids,
    required this.metadataWorkByCollection,
    required this.collectionScrapeMetaById,
  });

  final List<VideoBookRow> books;

  /// 复合键 → 主折叠合集（已过 [applyVideoFolderCollectionPolicy]）。
  final Map<String, int> primaryCollectionByEntry;
  final Map<int, MediaCollectionRow> collectionsById;

  /// 复合键 → 组内序（[buildVideoMemberSortIndex]）。
  final Map<String, int> memberSortIndex;
  final VideoWatchRecency recency;
  final Set<String> localExtraBookUids;
  final Map<int, VideoMetadataWorkRow> metadataWorkByCollection;
  final Map<int, CollectionScrapeMetaRow> collectionScrapeMetaById;

  VideoContinueInputs inputs({
    required int? Function(String bookUid) durationMsOf,
  }) => VideoContinueInputs(
    collectionIdByUid: entriesOfKind<int>(
      primaryCollectionByEntry,
      MediaKind.video,
    ),
    collectionsById: collectionsById,
    sortIndexByUid: entriesOfKind<int>(memberSortIndex, MediaKind.video),
    watchAtByUid: recency.byUid,
    legacyWatchAtByTitle: recency.legacyByTitle,
    durationMsOf: durationMsOf,
    excludedUids: localExtraBookUids,
    metadataWorkByCollection: metadataWorkByCollection,
    collectionScrapeMetaById: collectionScrapeMetaById,
  );
}

/// 读出 [VideoContinueLibrary]：与视频页 `_loadLibraryMapsInner` 同一批表、同一套
/// 纯函数（文件夹合集策略 / 组内序 / 最近观看 / 特典 / 作品名回落链）。
Future<VideoContinueLibrary> loadVideoContinueLibrary(
  FushiDatabase db, {
  required Future<List<VideoBookRow>> Function() listBooks,
}) async {
  final Future<List<MediaCollectionRow>> collectionsF = db
      .getAllMediaCollections();
  final Future<List<VideoBookRow>> booksF = listBooks();
  final Future<VideoLibraryMembership> membershipF = booksF.then(
    (List<VideoBookRow> books) => loadVideoLibraryMembership(db, books: books),
  );
  final Future<List<VideoWatchStatisticRow>> watchRowsF = db
      .getAllVideoWatchStatistics();
  final Future<Map<String, int>> segmentsF = db.getLatestStudyEndAtByMedia(
    kActivityMediaVideo,
  );
  final Future<List<VideoMetadataExtraRow>> extrasF = db
      .getAllVideoMetadataExtras();
  final Future<List<VideoMetadataWorkRow>> worksF = db
      .getAllVideoMetadataWorks();
  final Future<List<CollectionScrapeMetaRow>> collectionScrapeMetaF = db
      .getAllCollectionScrapeMeta();
  await Future.wait<Object?>(<Future<Object?>>[
    worksF,
    collectionScrapeMetaF,
    collectionsF,
    booksF,
    membershipF,
    watchRowsF,
    segmentsF,
    extrasF,
  ]);
  final List<MediaCollectionRow> collections = await collectionsF;
  final List<VideoBookRow> books = await booksF;
  final VideoLibraryMembership membership = await membershipF;
  return VideoContinueLibrary(
    books: books,
    primaryCollectionByEntry: membership.primary,
    collectionsById: <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in collections) c.id: c,
    },
    memberSortIndex: membership.memberSortIndex,
    recency: buildVideoWatchRecency(await watchRowsF, await segmentsF),
    localExtraBookUids: videoLocalExtraBookUids(await extrasF),
    metadataWorkByCollection: buildVideoWorksByCollection(await worksF),
    collectionScrapeMetaById: buildCollectionScrapeMetaById(
      await collectionScrapeMetaF,
    ),
  );
}

/// 视频页最近一次取到的远端清单，供页外（侧栏速览）复用。
///
/// 远端清单只由视频页取（取数、收养、去重、断点合并都在页里），这里只是把页里
/// 已经到手的那份递出去：速览悬停一次不额外打任何网络。字段是普通可变字段、
/// 不发通知——写入发生在页面 build 里，读方只在速览加载时读一次。
///
/// 只共享**输入**、不共享页面算好的候选：候选由速览按现读的库快照 + 此刻的上锁
/// 口径用同一个 [selectVideoContinueCandidates] 现算。页面只在「首页」分区且库
/// 非空时才算候选，切到别的分区、库清空、上锁把条目全藏掉时页面不再重算，若共享
/// 候选就会把旧结果（含刚上锁的条目）留在速览里。
class VideoContinueShare {
  /// 视频页最近一次取到的远端清单（已与本机去重、合过断点；尚未过显示开关 /
  /// 上锁 / 同集归并，见 [visibleHomeRemoteVideos]）。null = 没有可用清单。
  List<RemoteVideoInfo>? remoteVideos;

  /// 产出 [remoteVideos] 的来源（流播 / 封面要用同一个 client）。
  RemoteVideoSource? remoteSource;

  /// 发布者身份：页面 dispose 时只清自己写的那份。
  Object? remoteOwner;

  void publishRemote(
    Object owner,
    List<RemoteVideoInfo>? videos,
    RemoteVideoSource? source,
  ) {
    remoteOwner = owner;
    remoteVideos = videos;
    remoteSource = source;
  }

  void clearOwner(Object owner) {
    if (identical(remoteOwner, owner)) {
      remoteOwner = null;
      remoteVideos = null;
      remoteSource = null;
    }
  }
}

/// app 级单例（测试可 override）。
final Provider<VideoContinueShare> videoContinueShareProvider =
    Provider<VideoContinueShare>((Ref ref) => VideoContinueShare());
