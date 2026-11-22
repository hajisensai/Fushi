/// 作品「上锁」的显示口径：**唯一的过滤入口**（拍板台 qiqSbvdxrk）。
///
/// 作品隐私分级：公开 < 私密（不外传）< 上锁（私密 + 未解锁时不显示）。NSFW 是另一条
/// 轴（封面模糊），三样都在作品菜单的同一个「隐私」入口里改（`media_privacy_dialog.dart`）。
///
/// 结构：
/// - [MediaLockSession]：本次会话是否已解锁。**只在内存里**，每次启动都回到隐藏，
///   解锁要过口令或系统验证（`media_lock_auth.dart`）；
/// - [mediaLockSnapshotProvider]：`media_locked_flags` + 上锁合集成员的只读快照，表
///   变更时自动重载；
/// - [mediaVisibilityProvider]：上面两样合成的 [MediaVisibility]——已解锁 = 什么都
///   不藏；快照没读完 = [MediaVisibility.pending]（fail-closed：宁可先藏一瞬，也不让
///   上锁的作品闪出来）；
/// - [MediaVisibilityHost]：挂在 app 根（`main.dart`，与 `MediaNsfwStateHost` 并排），
///   把 [MediaVisibility] 经 InheritedWidget 广播给所有路由。列表消费端（书架 / 视频库 /
///   游戏库 / 音乐库 / 合集 / 首页卡片 / 搜索）在算出条目列表的地方用
///   [MediaVisibility.of] 拿到它、按作品身份问 `hides*`，不自己判上锁；
/// - 异步 loader（导航预览、桌面小组件、伴屏、控制通道列库）没有 BuildContext，用
///   [MediaVisibility.load] 现读一份，口径相同。
library;

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show TrackingMediaType;
import 'package:fushi_engine/privacy/media_lock.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        RemoteActivityEvent,
        RemoteAudiobookInfo,
        RemoteBookInfo,
        RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

/// 本次会话的解锁状态（进程级单例）。冷启动恒为未解锁；[unlock] 只该由通过了
/// 口令 / 系统验证的界面调用。
final class MediaLockSession {
  MediaLockSession._();

  static final MediaLockSession instance = MediaLockSession._();

  final ValueNotifier<bool> _unlocked = ValueNotifier<bool>(false);

  /// 已解锁 = 上锁的作品本次会话照常显示。
  ValueListenable<bool> get unlocked => _unlocked;

  bool get isUnlocked => _unlocked.value;

  /// 验证通过后调用：本次会话显示上锁的作品，直到 [relock] 或进程退出。
  void unlock() => _unlocked.value = true;

  /// 重新藏起上锁的作品（设置页的开关关掉）。
  void relock() => _unlocked.value = false;

  /// 测试复位用。
  @visibleForTesting
  void resetForTest() => _unlocked.value = false;
}

/// [MediaLockSession] 的 Riverpod 桥：解锁 / 重新上锁时重算依赖它的 provider。
final Provider<bool> mediaLockUnlockedProvider = Provider<bool>((Ref ref) {
  final ValueListenable<bool> unlocked = MediaLockSession.instance.unlocked;
  void listener() => ref.invalidateSelf();
  unlocked.addListener(listener);
  ref.onDispose(() => unlocked.removeListener(listener));
  return unlocked.value;
});

/// 上锁标记快照（按 `media_locked_flags` / 合集成员表变更重载）。
final StreamProvider<MediaLockSnapshot> mediaLockSnapshotProvider =
    StreamProvider<MediaLockSnapshot>((Ref ref) {
      final FushiDatabase db = ref.watch(
        appProvider.select((AppModel m) => m.database),
      );
      return watchMediaLockSnapshot(db);
    });

/// [mediaLockSnapshotProvider] 的流本体：先发一份，之后每次相关表变更重读一份，
/// 内容没变的不再发。
Stream<MediaLockSnapshot> watchMediaLockSnapshot(FushiDatabase db) {
  MediaLockSnapshot? last;
  return _lockReloadTriggers(
    db,
  ).asyncMap((_) => MediaLockSnapshot.load(db)).where((MediaLockSnapshot next) {
    final MediaLockSnapshot? prev = last;
    if (prev != null && next.sameAs(prev)) return false;
    last = next;
    return true;
  });
}

Stream<void> _lockReloadTriggers(FushiDatabase db) async* {
  yield null;
  yield* db.tableUpdates(
    TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
      db.mediaLockedFlags,
      db.mediaCollectionItems,
      // 上锁专辑新扫进来的曲目（[MediaVisibility.hidesMusicTrack]）。
      db.musicTracks,
    ]),
  );
}

//// 当前的显示口径（解锁状态 × 上锁快照）。
final Provider<MediaVisibility> mediaVisibilityProvider =
    Provider<MediaVisibility>((Ref ref) {
      if (ref.watch(mediaLockUnlockedProvider)) return MediaVisibility.all;
      final MediaLockSnapshot? snapshot = ref
          .watch(mediaLockSnapshotProvider)
          .valueOrNull;
      if (snapshot == null) return MediaVisibility.pending;
      return MediaVisibility.fromSnapshot(snapshot);
    });

/// 一份显示口径：哪些作品此刻要从列表里拿掉。
///
/// 三种基本状态：[all]（本次会话已解锁 / 树上没挂 host）什么都不藏；[pending]（快照
/// 没读完）可上锁的一律先藏；其余按快照藏。「本机没有上锁作品」与「已解锁」不同：
/// 前者仍要藏对端标了上锁的远端条目（[hidesRemoteEntry]）。
@immutable
final class MediaVisibility {
  const MediaVisibility._(
    this._snapshot, {
    required bool pending,
    required bool unlocked,
  }) : _pending = pending,
       _unlocked = unlocked;

  /// 按快照藏上锁的作品（快照为空时只藏对端标了上锁的远端条目）。
  factory MediaVisibility.fromSnapshot(MediaLockSnapshot snapshot) =>
      snapshot.isEmpty
      ? nothingLocked
      : MediaVisibility._(snapshot, pending: false, unlocked: false);

  /// 什么都不藏（本次会话已解锁 / 树上没挂 [MediaVisibilityHost]）。
  static const MediaVisibility all = MediaVisibility._(
    null,
    pending: false,
    unlocked: true,
  );

  /// 未解锁、但本机没有上锁的作品：本地条目都不藏，对端标了上锁的远端条目仍藏。
  static const MediaVisibility nothingLocked = MediaVisibility._(
    null,
    pending: false,
    unlocked: false,
  );

  /// 上锁快照还没读完：可上锁的作品一律先藏（fail-closed）。
  static const MediaVisibility pending = MediaVisibility._(
    null,
    pending: true,
    unlocked: false,
  );

  final MediaLockSnapshot? _snapshot;
  final bool _pending;
  final bool _unlocked;

  /// 此刻有没有任何本机条目被藏（false 时消费端可跳过逐条判定）。
  bool get hidesAnything => _pending || _snapshot != null;

  /// 按标签宿主种类问。
  bool hides(TagHostKind kind, String entryKey) =>
      _pending || (_snapshot?.isLocked(kind, entryKey) ?? false);

  /// 书 / 漫画 / 在线漫画 / 在线小说（bookKey 或 `epub_books.uid` 都认）。
  bool hidesBook(String bookKey) => hides(TagHostKind.epub, bookKey);

  /// 字幕书 / 有声书（`srt_books.uid`）。
  bool hidesSrtBook(String uid) => hides(TagHostKind.srt, uid);

  /// 视频文件（`video_books.book_uid`）。
  bool hidesVideo(String bookUid) => hides(TagHostKind.video, bookUid);

  /// 游戏（`galgames.id`）。
  bool hidesGame(String gameId) => hides(TagHostKind.game, gameId);

  /// 合集（`media_collections.id`）。
  bool hidesCollection(int collectionId) =>
      hides(TagHostKind.collection, collectionTagEntryKey(collectionId));

  /// 音乐专辑（`music_albums.album_uid`）；专辑下的曲目跟着专辑藏。
  bool hidesMusicAlbum(String albumUid) =>
      hides(TagHostKind.musicAlbum, albumUid);

  /// 曲目（`music_tracks.track_uid`）：所在专辑上锁就藏。歌单 / 最近播放 / 队列
  /// 这些只拿着 trackUid 的地方用它。
  bool hidesMusicTrack(String trackUid) =>
      _pending || (_snapshot?.isMusicTrackLocked(trackUid) ?? false);

  /// 合集成员行（`media_collection_items` 的 mediaType / entryKey）。认不出的种类不藏。
  bool hidesCollectionMember(String mediaType, String entryKey) =>
      switch (MediaKind.tryParse(mediaType)) {
        final MediaKind kind => hides(tagHostKindOfMediaKind(kind), entryKey),
        null => false,
      };

  /// 只知道来源键、不知道宿主种类的行（收藏句 / 收藏词 / 制卡历史 / 统计事实 /
  /// 活动流）。[key] 为空（legacy 无身份行）时按 [title] 回退。
  bool hidesWork({String? key, String title = ''}) {
    if (_pending) return true;
    final MediaLockSnapshot? snapshot = _snapshot;
    if (snapshot == null) return false;
    if (key != null && key.isNotEmpty) return snapshot.isSourceKeyLocked(key);
    return snapshot.isTitleLocked(title);
  }

  /// 进度追踪（Bangumi / AniList …）的本地作品键（`TrackingMediaType.value` +
  /// mediaKey）：书 / 书的章、视频、视频合集 / 书系合集（合集 id）、游戏。媒体
  /// 服务器上的远端条目不是本机作品，不藏。
  bool hidesTrackedMedia(String mediaType, String mediaKey) {
    if (!hidesAnything) return false;
    final TrackingMediaType? type = TrackingMediaType.values
        .where((TrackingMediaType t) => t.value == mediaType)
        .firstOrNull;
    return switch (type) {
      TrackingMediaType.book ||
      TrackingMediaType.bookChapter => hidesBook(mediaKey),
      TrackingMediaType.video => hidesVideo(mediaKey),
      TrackingMediaType.videoCollection ||
      TrackingMediaType.bookCollection => switch (int.tryParse(mediaKey)) {
        final int id => hidesCollection(id),
        null => _pending,
      },
      TrackingMediaType.game => hidesGame(mediaKey),
      TrackingMediaType.remoteVideo ||
      TrackingMediaType.remoteSeries ||
      null => false,
    };
  }

  /// 互联对端清单里的条目（远端占位卡 / 远端「继续」）：对端标了上锁
  /// （wire 字段 `locked`）且本机本次会话没解锁就藏。本机快照里有的同键条目照
  /// [hidesWork] 判。
  bool hidesRemoteEntry({required bool lockedOnHost, String? key}) =>
      (lockedOnHost && !_unlocked) || hidesWork(key: key);

  /// 互联对端的书（远端占位卡 / 远端「继续」）。
  bool hidesRemoteBook(RemoteBookInfo book) =>
      hidesRemoteEntry(lockedOnHost: book.locked, key: book.bookKey);

  /// 互联对端的视频。
  bool hidesRemoteVideo(RemoteVideoInfo video) =>
      hidesRemoteEntry(lockedOnHost: video.locked, key: video.id);

  /// 互联对端的字幕书 / 有声书。
  bool hidesRemoteAudiobook(RemoteAudiobookInfo book) =>
      hidesRemoteEntry(lockedOnHost: book.locked, key: book.identity);

  /// 互联对端的活动行（标题就在行里）。
  bool hidesRemoteActivity(RemoteActivityEvent event) =>
      hidesRemoteEntry(lockedOnHost: event.locked, key: event.mediaKey);

  /// 视频刮削作品单元（控制通道 `video works`）：所属合集上锁或任一成员上锁就藏。
  bool hidesVideoScrapeWork(VideoSourceScrapeWork work) {
    if (_pending) return true;
    final MediaCollectionRow? collection = work.collection;
    if (collection != null && hidesCollection(collection.id)) return true;
    return work.members.any((VideoBookRow m) => hidesVideo(m.bookUid));
  }

  /// 统计事实（日面 / 小时面）是否属于上锁作品。复习事实不属于任何作品。
  bool hidesStatFact(StatFact fact) =>
      !fact.isReview && hidesWork(key: fact.mediaKey, title: fact.title);

  /// 统计事实面去掉上锁作品的全部行（日面 / 小时面 / 段 / 活动 / 游玩会话 / 按书
  /// 计数 / 收藏词），统计页、首页、活动时间线、伴屏都只吃这一份。没有要藏的时
  /// 原样返回。总量随之不含上锁作品——解锁前它们在这台设备上就像不存在。
  StatFacts visibleStatFacts(StatFacts facts) {
    if (!hidesAnything) return facts;
    final StatCounterFacts counters = facts.counters;
    return StatFacts(
      daily: <StatFact>[
        for (final StatFact f in facts.daily)
          if (!hidesStatFact(f)) f,
      ],
      hourly: <StatFact>[
        for (final StatFact f in facts.hourly)
          if (!hidesStatFact(f)) f,
      ],
      segments: <StudySegmentRow>[
        for (final StudySegmentRow s in facts.segments)
          if (!hidesWork(key: s.mediaKey, title: s.title)) s,
      ],
      legacyActivity: visibleActivityRows(facts.legacyActivity),
      epubRows: <EpubBookMeta>[
        for (final EpubBookMeta r in facts.epubRows)
          if (!hidesBook(r.bookKey)) r,
      ],
      recentGameSessions: <GalgameSessionRow>[
        for (final GalgameSessionRow g in facts.recentGameSessions)
          if (!hidesGame(g.gameId)) g,
      ],
      gameNamesById: <String, String>{
        for (final MapEntry<String, String> e in facts.gameNamesById.entries)
          if (!hidesGame(e.key)) e.key: e.value,
      },
      counters: StatCounterFacts(
        mining: counters.mining,
        lookupCounters: <LookupMiningCounterRow>[
          for (final LookupMiningCounterRow c in counters.lookupCounters)
            if (!hidesWork(key: c.bookKey, title: c.title)) c,
        ],
        favoriteWords: <FavoriteWordRow>[
          for (final FavoriteWordRow w in counters.favoriteWords)
            if (!hidesWork(key: w.bookKey, title: w.title)) w,
        ],
        favoriteSentences: counters.favoriteSentences,
      ),
      activityLimit: facts.activityLimit,
    );
  }

  /// 活动流行（legacy `activity_events` / 合成行）去掉上锁作品的。
  List<ActivityEventRow> visibleActivityRows(List<ActivityEventRow> rows) =>
      !hidesAnything
      ? rows
      : <ActivityEventRow>[
          for (final ActivityEventRow r in rows)
            if (!hidesWork(key: r.mediaKey, title: r.title)) r,
        ];

  /// 现读一份口径（没有 BuildContext 的异步 loader 用）：已解锁 = [all]。
  static Future<MediaVisibility> load(FushiDatabase db) async {
    if (MediaLockSession.instance.isUnlocked) return all;
    final MediaVisibility loaded = MediaVisibility.fromSnapshot(
      await MediaLockSnapshot.load(db),
    );
    // 读快照期间用户解了锁：以解锁为准。
    return MediaLockSession.instance.isUnlocked ? all : loaded;
  }

  /// [context] 下的显示口径；树上没有 [MediaVisibilityHost]（独立的伴屏 / 弹窗
  /// app、纯 UI 测试）时什么都不藏。
  static MediaVisibility of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaVisibilityScope>()
          ?.visibility ??
      all;
}

/// 在异步 loader 里算列表、存进 State 的页面（统计页 / 收藏 / 歌单）用：
/// [mediaVisibility] 是此刻的口径（依赖 [MediaVisibilityHost]），口径一变（解锁 /
/// 重新上锁 / 上锁标记改了）就调 [onMediaVisibilityChanged] 让页面重读。
mixin MediaVisibilityDependent<T extends StatefulWidget> on State<T> {
  MediaVisibility? _mediaVisibility;

  /// 此刻的显示口径；第一次 [didChangeDependencies] 之前是 [MediaVisibility.pending]。
  MediaVisibility get mediaVisibility =>
      _mediaVisibility ?? MediaVisibility.pending;

  /// 口径变了（不含第一次拿到）。
  void onMediaVisibilityChanged();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MediaVisibility next = MediaVisibility.of(context);
    final MediaVisibility? previous = _mediaVisibility;
    _mediaVisibility = next;
    if (previous != null && !identical(previous, next)) {
      onMediaVisibilityChanged();
    }
  }
}

class _MediaVisibilityScope extends InheritedWidget {
  const _MediaVisibilityScope({required this.visibility, required super.child});

  final MediaVisibility visibility;

  @override
  bool updateShouldNotify(_MediaVisibilityScope oldWidget) =>
      !identical(oldWidget.visibility, visibility);
}

/// app 根挂的 [MediaVisibility] 来源：watch 解锁状态与上锁快照，变了整树里读它的
/// 列表重建。也让快照从启动起就开始读，库页第一次打开时通常已经读完。
class MediaVisibilityHost extends ConsumerWidget {
  const MediaVisibilityHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _MediaVisibilityScope(
    visibility: ref.watch(mediaVisibilityProvider),
    child: child,
  );
}

/// 测试 / 独立子树里直接给定口径。
@visibleForTesting
Widget mediaVisibilityScopeForTest({
  required MediaVisibility visibility,
  required Widget child,
}) => _MediaVisibilityScope(visibility: visibility, child: child);
