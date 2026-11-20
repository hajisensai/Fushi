/// 作品级「NSFW」封面模糊（拍板台 w04vrhUAaX：所有媒体都支持是否 NSFW）。
///
/// 结构：
/// - [mediaNsfwSnapshotProvider]：`media_nsfw_flags` + NSFW 合集成员的只读快照，
///   表变更时自动重载（标 / 取消 NSFW、加入 / 移出合集、互联同步过来的标记都会
///   触发），消费端不用各自 invalidate；
/// - [blurNsfwCoversProvider]：全局「模糊 NSFW 封面」开关；
/// - [MediaNsfwStateHost]：挂在 app 根（`main.dart` MaterialApp.builder，导航器之上），
///   把上面两份状态经 [MediaNsfwState] 广播给所有路由（含对话框 / 菜单）。封面消费端
///   只读这一层、不直接依赖 Riverpod——视频合集详情页这类普通 StatefulWidget 页面
///   （及其不挂 ProviderScope 的测试）也能用；没有这一层（独立的伴屏 / 弹窗 app、
///   纯 UI 测试）时不模糊；
/// - [MediaNsfwCoverScope]：卡壳（知道自己是哪部作品的那一层）挂它，算出「这张卡的
///   封面要不要模糊」后经 [ShelfCoverNsfw] 往下广播；卡内共享封面框
///   `ShelfCoverFrame` 读这一层，把模糊画在**封面图**上（标题 / 进度不模糊）；
/// - [MediaNsfwCover]：不经封面框的封面（继续卡大图、详情页 hero 等）直接包它。
library;

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/nsfw_cover_blur.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:material_ui/material_ui.dart';

/// NSFW 标记快照（按 `media_nsfw_flags` / 合集成员表变更重载）。首份加载完成前
/// 消费端按 [MediaNsfwSnapshot.none] 处理（[watchIsMediaNsfw]）。
final StreamProvider<MediaNsfwSnapshot> mediaNsfwSnapshotProvider =
    StreamProvider<MediaNsfwSnapshot>((Ref ref) {
      final FushiDatabase db = ref.watch(
        appProvider.select((AppModel m) => m.database),
      );
      return watchMediaNsfwSnapshot(db);
    });

/// [mediaNsfwSnapshotProvider] 的流本体：先发一份，之后每次相关表变更重读一份。
Stream<MediaNsfwSnapshot> watchMediaNsfwSnapshot(FushiDatabase db) async* {
  yield await MediaNsfwSnapshot.load(db);
  await for (final Set<TableUpdate> _ in db.tableUpdates(
    TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
      db.mediaNsfwFlags,
      db.mediaCollectionItems,
    ]),
  )) {
    yield await MediaNsfwSnapshot.load(db);
  }
}

/// 全局「模糊 NSFW 封面」开关（偏好 `blur_nsfw_covers`，默认开）。
final Provider<bool> blurNsfwCoversProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel m) => m.prefsRepo.blurNsfwCovers)),
);

/// 一个可标 NSFW 的宿主（[kind] + [entryKey]，与 `media_nsfw_flags` 同一套逻辑外键）。
/// [alsoNsfw] 并入宿主自己表外的成人向信号（游戏的 `GalgameCustomData.nsfw` /
/// 刮削 `metadata.nsfw`）。
@immutable
class MediaNsfwTarget {
  const MediaNsfwTarget(this.kind, this.entryKey, {this.alsoNsfw = false});

  const MediaNsfwTarget.book(String bookKey) : this(TagHostKind.epub, bookKey);

  const MediaNsfwTarget.srtBook(String uid) : this(TagHostKind.srt, uid);

  const MediaNsfwTarget.video(String bookUid)
    : this(TagHostKind.video, bookUid);

  MediaNsfwTarget.collection(int collectionId)
    : this(TagHostKind.collection, collectionTagEntryKey(collectionId));

  const MediaNsfwTarget.game(String gameId, {required bool adult})
    : this(TagHostKind.game, gameId, alsoNsfw: adult);

  /// 合集成员行（`media_collection_items` 的 mediaType / entryKey；EPUB 成员键是
  /// uid，快照两种键都认）。认不出的 mediaType 为 null（不模糊）。游戏的成人向标记
  /// 不在成员行里，需要的调用方自己用 [MediaNsfwTarget.game]。
  static MediaNsfwTarget? collectionMember(String mediaType, String entryKey) =>
      switch (MediaKind.tryParse(mediaType)) {
        final MediaKind kind => MediaNsfwTarget(
          tagHostKindOfMediaKind(kind),
          entryKey,
        ),
        null => null,
      };

  final TagHostKind kind;
  final String entryKey;
  final bool alsoNsfw;

  /// 按快照判定是否 NSFW（含合集继承与 [alsoNsfw]）。
  bool resolve(MediaNsfwSnapshot snapshot) =>
      alsoNsfw || snapshot.isNsfw(kind, entryKey);

  @override
  bool operator ==(Object other) =>
      other is MediaNsfwTarget &&
      other.kind == kind &&
      other.entryKey == entryKey &&
      other.alsoNsfw == alsoNsfw;

  @override
  int get hashCode => Object.hash(kind, entryKey, alsoNsfw);
}

/// [target] 当前是否 NSFW（watch 快照）。供卡壳之外需要判定的消费端（制卡等）用。
bool watchIsMediaNsfw(WidgetRef ref, MediaNsfwTarget target) => target.resolve(
  ref.watch(mediaNsfwSnapshotProvider).valueOrNull ?? MediaNsfwSnapshot.none,
);

/// 全应用的 NSFW 显示状态（[MediaNsfwStateHost] 写，封面消费端经
/// [mediaNsfwBlurOf] 读）。
class MediaNsfwState extends InheritedWidget {
  const MediaNsfwState({
    required this.blurCovers,
    required this.snapshot,
    required super.child,
    super.key,
  });

  /// 「模糊 NSFW 封面」开关。
  final bool blurCovers;

  /// 当前 NSFW 标记快照（首份加载完成前是 [MediaNsfwSnapshot.none]）。
  final MediaNsfwSnapshot snapshot;

  static MediaNsfwState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaNsfwState>();

  @override
  bool updateShouldNotify(MediaNsfwState oldWidget) =>
      oldWidget.blurCovers != blurCovers ||
      !identical(oldWidget.snapshot, snapshot);
}

/// app 根挂的 [MediaNsfwState] 来源：watch 快照与开关，变了整树里读它的封面重建。
class MediaNsfwStateHost extends ConsumerWidget {
  const MediaNsfwStateHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MediaNsfwState(
    blurCovers: ref.watch(blurNsfwCoversProvider),
    snapshot:
        ref.watch(mediaNsfwSnapshotProvider).valueOrNull ??
        MediaNsfwSnapshot.none,
    child: child,
  );
}

/// [target] 的封面在 [context] 下要不要模糊：开关开着且 [target] 是 NSFW。
/// [target] 为 null 或树上没有 [MediaNsfwState] 时为 false。
bool mediaNsfwBlurOf(BuildContext context, MediaNsfwTarget? target) {
  if (target == null) return false;
  final MediaNsfwState? state = MediaNsfwState.maybeOf(context);
  return state != null && state.blurCovers && target.resolve(state.snapshot);
}

/// 卡壳挂的 NSFW 作用域：[target] 为 null（远端条目等不可标的宿主）时不模糊。
class MediaNsfwCoverScope extends StatelessWidget {
  const MediaNsfwCoverScope({
    required this.target,
    required this.child,
    super.key,
  });

  final MediaNsfwTarget? target;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ShelfCoverNsfw(blur: mediaNsfwBlurOf(context, target), child: child);
}

/// 不经卡壳作用域的封面（继续卡、详情页 hero、合集卡里逐张判定的成员封面等）：
/// 按 [target] 自己判定后包 [NsfwCoverBlur]。[target] 为 null 时不模糊。
///
/// 祖先 [MediaNsfwCoverScope] 已判定要模糊（卡内封面框会整张打模糊）时这里不再
/// 叠一层，免得模糊两遍、压两枚图标。
class MediaNsfwCover extends StatelessWidget {
  const MediaNsfwCover({
    required this.target,
    required this.child,
    this.showIcon = true,
    super.key,
  });

  final MediaNsfwTarget? target;
  final Widget child;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final bool blur =
        !ShelfCoverNsfw.blurOf(context) && mediaNsfwBlurOf(context, target);
    return NsfwCoverBlur(blur: blur, showIcon: showIcon, child: child);
  }
}
