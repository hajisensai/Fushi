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
import 'package:fushi_engine/privacy/media_lock.dart';
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
    ]),
  );
}

/// 当前的显示口径（解锁状态 × 上锁快照）。
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
@immutable
final class MediaVisibility {
  const MediaVisibility._(this._snapshot, {required bool pending})
    : _pending = pending;

  /// 按快照藏上锁的作品（快照为空时等同 [all]）。
  factory MediaVisibility.fromSnapshot(MediaLockSnapshot snapshot) =>
      snapshot.isEmpty ? all : MediaVisibility._(snapshot, pending: false);

  /// 什么都不藏（已解锁 / 没有上锁作品 / 树上没挂 [MediaVisibilityHost]）。
  static const MediaVisibility all = MediaVisibility._(null, pending: false);

  /// 上锁快照还没读完：可上锁的作品一律先藏（fail-closed）。
  static const MediaVisibility pending = MediaVisibility._(null, pending: true);

  final MediaLockSnapshot? _snapshot;
  final bool _pending;

  /// 此刻有没有任何东西被藏（false 时消费端可跳过逐条判定）。
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

  /// 合集成员行（`media_collection_items` 的 mediaType / entryKey）。认不出的种类不藏。
  bool hidesCollectionMember(String mediaType, String entryKey) =>
      switch (MediaKind.tryParse(mediaType)) {
        final MediaKind kind => hides(tagHostKindOfMediaKind(kind), entryKey),
        null => false,
      };

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
