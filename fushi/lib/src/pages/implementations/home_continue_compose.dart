/// 首页「继续」的编排（纯函数）：首页 dashboard 的「继续」区与侧栏「首页」悬停速览
/// 共用这一份，两处显示同样的条目、同样的顺序（2026-11-22 用户拍板「每张卡跟它
/// 打开的页面一致」，BUG-5277）。
///
/// 编排 = 来源 + 门控 + 去重 + 折叠 + 排序：
/// - 本地书：与书架「继续阅读」、书 / 漫画速览同一份选书
///   [selectMediaItemContinueCandidates]（合集 Next-Up 一合集一卡，散书只收「在读」，
///   BUG-5278）；
/// - 本地视频：合集 Next-Up 一合集一卡（[homeContinueVideoResumeTarget]），散视频
///   收「有断点且未看完」；
/// - 本地游戏：玩过的，按主合集折叠成一张卡（标题取合集名）；
/// - 互联 host 远端补位（[RemoteContinueCandidate]，首页算好后发布在
///   `RemoteContinueFeed`）：去掉本地已出同名合集卡的（[withoutLocallyCoveredCollections]）；
/// - 用户自配服务器条目（[ServerContinueCandidate]，`ServerContinueFeed`）：按
///   [serverContinueGates] 的两道门过滤，已入库到本机的媒体服务器条目让位给本地卡；
/// - 全部按 [HomeContinueUnit.recentMs] 倒序，关掉的模块先出局，再取前 [limit] 条。
///
/// 本文件不读库、不发网络请求：输入由调用方备齐（dashboard 用它整批载入的状态，
/// 速览按同样的查询现读一份，远端 / 服务器两路只读进程级 feed 的现成结果）。
/// 也不 import 阅读器源 / 媒体服务器库这类读 AppModel 的件：书名、本机媒体服务器
/// 条目键经 [HomeContinueInputs] 的回调注入，本文件留在 import 环外。
library;

import 'package:fushi/src/media/collections/book_continue.dart'
    show BookContinueCandidate, selectMediaItemContinueCandidates;
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/media/sources/book_media_identifier.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart' show moduleOfMediaKind;
import 'package:fushi/src/pages/implementations/home_dashboard_derived.dart'
    show HomeDashboardVideoIndex;
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart'
    show RemoteContinueCandidate, withoutLocallyCoveredCollections;
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate, mergeServerContinue;
import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBookRow;
import 'package:fushi_engine/stats/stat_facts.dart' show StatFact;

/// 首页「继续」最多几张卡。
const int kHomeContinueLimit = 10;

/// 首页「继续」的一张卡（编排结果的一项）。
sealed class HomeContinueUnit {
  const HomeContinueUnit();

  /// 最近活动时刻（epoch 毫秒），混排排序用。
  int get recentMs;

  /// 所属合集名（卡片标题优先显示它，条目名退为副标题）；null = 散卡。
  String? get collectionName;

  /// 条目自己的名字。
  String get title;

  /// 本卡所属功能模块（模块门控判据）。
  ModuleId get module;

  /// 卡片标题：合集成员显示合集名（「非合集上下文显示合集名」规则）。
  String get displayTitle => collectionName ?? title;
}

/// 本地书 / 漫画 / 字幕书。
final class HomeContinueBookUnit extends HomeContinueUnit {
  const HomeContinueBookUnit({
    required this.item,
    required this.title,
    required this.recentMs,
    this.collectionName,
    this.memberOrdinal,
    this.collectionMembers = const <MediaItem>[],
  });

  final MediaItem item;
  @override
  final int recentMs;
  @override
  final String? collectionName;

  /// 合集里的第几本（组内序，1 起）；散书 / 只有一本的合集为 null。
  final int? memberOrdinal;

  /// 合集成员（组内序排好；算「第 N 卷」的卷号用）；散书为空。
  final List<MediaItem> collectionMembers;

  /// 书的真实媒体种类：standalone SRT 书身份是 `hoshi://srtbook/<uid>`，其余 EPUB。
  MediaKind get kind => homeContinueBookKind(item);

  /// 卡片上的书名（[HomeContinueInputs.bookTitleOf]，与书架卡同一 override 通道）。
  @override
  final String title;

  /// 漫画盖不住 [MediaKind]（漫画行是 `EpubBooks.format=='manga'` 派生），按
  /// [MediaItem.mediaSourceIdentifier] 认出漫画身份单独门控。
  @override
  ModuleId get module => item.mediaSourceIdentifier == kMangaMediaSourceKey
      ? ModuleId.manga
      : moduleOfMediaKind(kind);
}

/// 本地视频（散卡或合集续播目标）。
final class HomeContinueVideoUnit extends HomeContinueUnit {
  const HomeContinueVideoUnit({
    required this.row,
    required this.recentMs,
    this.collectionName,
    this.collectionId,
    this.collectionEpisode,
    this.collectionEpisodeCount = 0,
  });

  final VideoBookRow row;
  @override
  final int recentMs;
  @override
  final String? collectionName;

  /// 主折叠合集 id；散卡为 null。
  final int? collectionId;

  /// 合集续播目标在组内是第几集（1 起）；单集合集 / 散卡为 null。
  final int? collectionEpisode;
  final int collectionEpisodeCount;

  @override
  String get title => row.title;

  @override
  ModuleId get module => ModuleId.video;
}

/// 本地游戏（散卡或合集里最近玩的那部）。
final class HomeContinueGameUnit extends HomeContinueUnit {
  const HomeContinueGameUnit({required this.game, this.collectionName});

  final GalgameEntry game;
  @override
  final String? collectionName;

  @override
  int get recentMs => game.lastPlayedMs;

  @override
  String get title => game.displayName;

  @override
  ModuleId get module => ModuleId.games;
}

/// 互联 host 上的在读书 / 在看视频（本地没有的远端补位）。
final class HomeContinueRemoteUnit extends HomeContinueUnit {
  const HomeContinueRemoteUnit(this.candidate);

  final RemoteContinueCandidate candidate;

  @override
  int get recentMs => candidate.recentMs;
  @override
  String? get collectionName => candidate.collectionName;
  @override
  String get title => candidate.title;

  /// 远端条目判不出漫画，一律按 [moduleOfMediaKind] 归（host 侧的漫画本就进不了
  /// 远端「继续」，BUG-1638）。
  @override
  ModuleId get module => moduleOfMediaKind(candidate.kind);
}

/// 用户自配服务器（Jellyfin / Emby / Plex、Audiobookshelf）上进行中的条目。
final class HomeContinueServerUnit extends HomeContinueUnit {
  const HomeContinueServerUnit(this.candidate);

  final ServerContinueCandidate candidate;

  @override
  int get recentMs => candidate.recentMs;
  @override
  String? get collectionName => candidate.collectionName;
  @override
  String get title => candidate.title;

  /// ABS 有声书归书模块（ABS 标签页住在书库里）。
  @override
  ModuleId get module => candidate.isVideo ? ModuleId.video : ModuleId.books;
}

/// 合集续播目标：续播的那一集、它在组内的下标、组大小。
typedef HomeContinueVideoTarget = ({VideoBookRow row, int index, int count});

/// [composeHomeContinue] 的全部输入。书 / 视频 / 游戏须已去掉上锁（未解锁）的条目
/// （[homeContinueHidesBook] / [MediaVisibility.hidesVideo] / `hidesGame`）。
class HomeContinueInputs {
  const HomeContinueInputs({
    required this.books,
    required this.lastReadByUid,
    required this.epubUidByKey,
    required this.completedBookKeys,
    required this.bookTitleOf,
    required this.primaryCollectionByEntry,
    required this.memberSortIndex,
    required this.collectionNamesById,
    required this.videoIndex,
    required this.videoWatchAtByUid,
    required this.videoDurationMsOf,
    required this.localMediaServerItemKeyOf,
    required this.games,
    required this.remote,
    required this.server,
    required this.mediaServerGate,
    required this.audiobookshelfGate,
    required this.isModuleEnabled,
    this.videoResumeTargetOf,
    this.limit = kHomeContinueLimit,
  });

  /// 书库条目（`fushiBooksProvider`）。
  final List<MediaItem> books;

  /// 阅读位置最近更新时刻，键是书 uid（`bookLastReadAtProvider`）。
  final Map<String, int> lastReadByUid;

  /// bookKey → uid（查 [lastReadByUid] 前换算；`epubBookUidByKeyProvider`）。
  final Map<String, String> epubUidByKey;

  /// 标记读完的书的 bookKey（`completedEpubBookKeysProvider`）。
  final Set<String> completedBookKeys;

  /// 书卡显示的书名（`bookContinueDisplayTitle`：书架卡同一 override 通道）。
  final String Function(MediaItem item) bookTitleOf;

  /// 复合键 → 主折叠合集 id（[splitPrimaryCollectionMembership]）。
  final Map<String, int> primaryCollectionByEntry;

  /// 复合键 → 在主合集里的组内序。
  final Map<String, int> memberSortIndex;
  final Map<int, String> collectionNamesById;

  /// 视频行 + 合集归属索引（视频行已去掉上锁的）。
  final HomeDashboardVideoIndex videoIndex;

  /// 每个视频的最近观看时刻（[homeContinueVideoWatchAtByUid]）。
  final Map<String, int> videoWatchAtByUid;

  /// 播放器记下的片长（BUG-3491，分辨「已打勾的集正在重看」）。
  final int? Function(String bookUid) videoDurationMsOf;

  /// 已入库到本机的媒体服务器视频行 → `mediaServerItemKey`；不是媒体服务器行为
  /// null（`localMediaServerItemKeyOfVideo`）。
  final String? Function(VideoBookRow video) localMediaServerItemKeyOf;

  /// 合集续播目标的覆盖（dashboard 传它的按合集缓存）；null = 按
  /// [homeContinueVideoResumeTarget] 现算。
  final HomeContinueVideoTarget? Function(int collectionId)?
  videoResumeTargetOf;

  final List<GalgameEntry> games;

  /// 互联远端补位（`RemoteContinueFeed.current`；「显示远端条目」关着时传空）。
  final List<RemoteContinueCandidate> remote;

  /// 服务器条目（`ServerContinueFeed.current`）。
  final List<ServerContinueCandidate> server;

  /// [serverContinueGates] 的两道门。
  final bool mediaServerGate;
  final bool audiobookshelfGate;

  /// 模块开关（`ModuleVisibility.isEnabled`）。
  final bool Function(ModuleId module) isModuleEnabled;
  final int limit;
}

/// 首页「继续」的编排（见文件头）。dashboard 的「继续」区与侧栏首页速览共用。
List<HomeContinueUnit> composeHomeContinue(HomeContinueInputs input) {
  final List<HomeContinueUnit> units = <HomeContinueUnit>[];
  units.addAll(_bookUnits(input));
  units.addAll(_videoUnits(input));
  units.addAll(_gameUnits(input));
  // 互联 host 的远端补位：远端合集已在候选层收敛成一合集一卡；本地已出同名合集
  // 卡的再去掉（反馈 GonyeE75Kd：同名卡刷屏）。
  for (final RemoteContinueCandidate c in withoutLocallyCoveredCollections(
    input.remote,
    localVideoCollectionNames: <String>{
      for (final HomeContinueUnit u in units)
        if (u is HomeContinueVideoUnit) ?u.collectionName,
    },
    localBookCollectionNames: <String>{
      for (final HomeContinueUnit u in units)
        if (u is HomeContinueBookUnit) ?u.collectionName,
    },
  )) {
    units.add(HomeContinueRemoteUnit(c));
  }
  // 用户自配服务器条目：按当前门控过滤（开关刚关掉、重取还没回来时也不混排），
  // 已下载 / 入库到本机的媒体服务器条目让位给本地那张卡。
  final List<ServerContinueCandidate> server = <ServerContinueCandidate>[
    for (final ServerContinueCandidate c in input.server)
      if (c.isVideo ? input.mediaServerGate : input.audiobookshelfGate) c,
  ];
  if (server.isNotEmpty) {
    final Set<String> localServerItemKeys = <String>{};
    if (server.any((ServerContinueCandidate c) => c.isVideo)) {
      for (final VideoBookRow v in input.videoIndex.videos) {
        if (input.localMediaServerItemKeyOf(v) case final String key) {
          localServerItemKeys.add(key);
        }
      }
    }
    for (final ServerContinueCandidate c in mergeServerContinue(
      <List<ServerContinueCandidate>>[server],
      localMediaServerItemKeys: localServerItemKeys,
    )) {
      units.add(HomeContinueServerUnit(c));
    }
  }
  units.sort(
    (HomeContinueUnit a, HomeContinueUnit b) =>
        b.recentMs.compareTo(a.recentMs),
  );
  // 模块门控：关掉的模块的条目**先出局再取前 N**——顺序反过来会出现「过滤后不足
  // N 条」（前 N 条恰好全是被关模块的条目时甚至整行空掉）。
  return units
      .where((HomeContinueUnit u) => input.isModuleEnabled(u.module))
      .take(input.limit)
      .toList();
}

/// 书：与书架「继续阅读」、书 / 漫画速览同一份选书
/// [selectMediaItemContinueCandidates]（合集按 Next-Up 一合集一卡、单元时刻取组内
/// 最大值；散书只收「在读」；合集行已删的孤儿归属按散书）。
List<HomeContinueBookUnit> _bookUnits(HomeContinueInputs input) =>
    <HomeContinueBookUnit>[
      for (final BookContinueCandidate<MediaItem> c
          in selectMediaItemContinueCandidates(
            books: input.books,
            lastReadAtByUid: input.lastReadByUid,
            epubUidByKey: input.epubUidByKey,
            completedBookKeys: input.completedBookKeys,
            primaryCollectionIdByEntry: input.primaryCollectionByEntry,
            collectionIds: input.collectionNamesById.keys.toSet(),
            memberSortIndex: input.memberSortIndex,
          ))
        HomeContinueBookUnit(
          item: c.item,
          title: input.bookTitleOf(c.item),
          recentMs: c.recentMs,
          collectionName: c.isSeries
              ? input.collectionNamesById[c.collectionId]
              : null,
          memberOrdinal: c.memberOrdinal,
          collectionMembers: c.members,
        ),
    ];

/// 视频合集感知 Next-Up：每个合集最多一张卡（视频页 hero 同口径）；散卡收「有断点
/// 且未看完」。
List<HomeContinueVideoUnit> _videoUnits(HomeContinueInputs input) {
  final HomeDashboardVideoIndex index = input.videoIndex;
  final List<HomeContinueVideoUnit> out = <HomeContinueVideoUnit>[];
  for (final VideoBookRow v in index.standalone) {
    if (v.lastPositionMs > 0 && v.completedAt == null) {
      out.add(
        HomeContinueVideoUnit(
          row: v,
          recentMs: input.videoWatchAtByUid[v.bookUid] ?? v.importedAt ?? 0,
        ),
      );
    }
  }
  for (final int collectionId in index.collectionIds) {
    final HomeContinueVideoTarget? target =
        input.videoResumeTargetOf?.call(collectionId) ??
        (input.videoResumeTargetOf == null
            ? homeContinueVideoResumeTarget(
                index.sortedMembersOf(collectionId),
                durationMsOf: input.videoDurationMsOf,
              )
            : null);
    if (target == null) continue;
    // 单元活跃时刻 = 成员观看时刻最大值（含已完成集——Next-Up 卡按「刚看完上一集」
    // 的时间参与混排），无统计行回退续播目标导入时间。
    int recent = 0;
    for (final VideoBookRow m in index.membersOf(collectionId)) {
      final int at = input.videoWatchAtByUid[m.bookUid] ?? 0;
      if (at > recent) recent = at;
    }
    if (recent == 0) recent = target.row.importedAt ?? 0;
    out.add(
      HomeContinueVideoUnit(
        row: target.row,
        recentMs: recent,
        collectionName: input.collectionNamesById[collectionId],
        collectionId: collectionId,
        // 合集里的第几集（组内 sortIndex 序，1 起）；只有一集的合集不标集数。
        collectionEpisode: target.count >= 2 ? target.index + 1 : null,
        collectionEpisodeCount: target.count,
      ),
    );
  }
  return out;
}

/// 玩过的游戏（游戏没有完成度，判据只是「玩过」）。一个合集最多一张卡：卡标题取
/// 合集名，不收敛的话同合集 N 个游戏会排出 N 张同名卡；续玩目标取组内最近玩的
/// 一部（与该单元的 recentMs 同源）。
List<HomeContinueGameUnit> _gameUnits(HomeContinueInputs input) {
  final List<HomeContinueGameUnit> out = <HomeContinueGameUnit>[];
  final Map<int, GalgameEntry> byCollection = <int, GalgameEntry>{};
  for (final GalgameEntry g in input.games) {
    if (g.lastPlayedMs <= 0) continue;
    final int? cid =
        input.primaryCollectionByEntry[MediaKind.game.compositeKey(g.id)];
    if (cid == null) {
      out.add(HomeContinueGameUnit(game: g));
      continue;
    }
    final GalgameEntry? best = byCollection[cid];
    if (best == null || g.lastPlayedMs > best.lastPlayedMs) {
      byCollection[cid] = g;
    }
  }
  for (final MapEntry<int, GalgameEntry> ge in byCollection.entries) {
    out.add(
      HomeContinueGameUnit(
        game: ge.value,
        // 合集名缺失（名字表没这行）→ null，与散卡同渲染，安全降级。
        collectionName: input.collectionNamesById[ge.key],
      ),
    );
  }
  return out;
}

/// 合集单元的续播目标（**视频页 hero 同口径**，BUG-848）：[sorted] 已按组内
/// sortIndex 排好，跑 [continueMemberIndex]（最靠后有痕迹一集；它已完成则推进下一
/// 集）。整组无痕迹（没看过，不劝人从头开始）或目标仍是已完成集（整季看完）→ null。
HomeContinueVideoTarget? homeContinueVideoResumeTarget(
  List<VideoBookRow> sorted, {
  required int? Function(String bookUid) durationMsOf,
}) {
  final bool anyTrace = sorted.any(
    (VideoBookRow m) => m.completedAt != null || m.lastPositionMs > 0,
  );
  if (!anyTrace) return null;
  final List<CollectionMemberProgress> progress = <CollectionMemberProgress>[
    for (final VideoBookRow m in sorted)
      CollectionMemberProgress(
        positionMs: m.lastPositionMs,
        completed: m.completedAt != null,
        lastPlayedAt: m.lastPlayedAt,
        // BUG-3491：片长用来分辨「已打勾的集正在重看」。
        durationMs: durationMsOf(m.bookUid),
      ),
  ];
  final int idx = continueMemberIndex(progress);
  if (progress[idx].isFinished) return null;
  return (row: sorted[idx], index: idx, count: sorted.length);
}

/// 书 [MediaItem] 的真实媒体种类：standalone SRT 书身份是
/// `hoshi://srtbook/<uid>`（BUG-1018 A3），其余按 EPUB。
MediaKind homeContinueBookKind(MediaItem item) =>
    parseSrtBookUidOfMediaIdentifier(item.mediaIdentifier) != null
    ? MediaKind.srt
    : MediaKind.epub;

/// 书卡（EPUB / 字幕书）是不是上锁（未解锁）的作品。
bool homeContinueHidesBook(MediaVisibility visibility, MediaItem item) {
  if (parseSrtBookUidOfMediaIdentifier(item.mediaIdentifier)
      case final String srtUid) {
    return visibility.hidesSrtBook(srtUid);
  }
  final String? bookKey = parseBookKeyOfMediaIdentifier(item.mediaIdentifier);
  return bookKey != null && visibility.hidesBook(bookKey);
}

/// 折叠归属主合集查询（`getLocalPrimaryCollectionMembership`）拆成两张表：复合键
/// → 主合集 id、复合键 → 组内序。
({Map<String, int> primaryByEntry, Map<String, int> sortIndex})
splitPrimaryCollectionMembership(
  Map<String, ({int collectionId, int sortIndex})> membership,
) => (
  primaryByEntry: <String, int>{
    for (final MapEntry<String, ({int collectionId, int sortIndex})> e
        in membership.entries)
      e.key: e.value.collectionId,
  },
  sortIndex: <String, int>{
    for (final MapEntry<String, ({int collectionId, int sortIndex})> e
        in membership.entries)
      e.key: e.value.sortIndex,
  },
);

/// 每个视频的最近观看时刻：观看域日面事实按 bookUid 取 lastActiveMs 最大值
/// （legacy 无身份行 mediaKey '' 跳过）。
Map<String, int> homeContinueVideoWatchAtByUid(Iterable<StatFact> watch) {
  final Map<String, int> watchAt = <String, int>{};
  for (final StatFact w in watch) {
    final String uid = w.mediaKey;
    if (uid.isEmpty) continue;
    if (w.lastActiveMs > (watchAt[uid] ?? 0)) watchAt[uid] = w.lastActiveMs;
  }
  return watchAt;
}
