/// 作品级「NSFW」封面模糊（拍板台 w04vrhUAaX：所有媒体都支持是否 NSFW）。
///
/// 结构：
/// - [mediaNsfwSnapshotProvider]：`media_nsfw_flags` + NSFW 合集成员的只读快照，
///   表变更时自动重载（标 / 取消 NSFW、加入 / 移出合集、互联同步过来的标记都会
///   触发），消费端不用各自 invalidate；
/// - [blurNsfwCoversProvider]：全局「模糊 NSFW 封面」开关；
/// - [MediaNsfwCoverScope]：卡壳（知道自己是哪部作品的那一层）挂它，算出「这张卡的
///   封面要不要模糊」后经 [ShelfCoverNsfw] 往下广播；卡内共享封面框
///   `ShelfCoverFrame` 读这一层，把模糊画在**封面图**上（标题 / 进度不模糊）；
/// - [NsfwCoverBlur]：不经封面框的封面（继续卡大图、详情页 hero 等）直接包它。
library;

import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:material_ui/material_ui.dart';

/// NSFW 标记快照（按 `media_nsfw_flags` / 合集成员表变更重载）。加载前 / 失败时
/// 消费端按 [MediaNsfwSnapshot.none] 处理（一闪而过的未模糊总比整页报错好；
/// 读失败会在下一次表变更时重试）。
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

/// 「这张卡的封面要模糊」的广播层（[MediaNsfwCoverScope] 写，`ShelfCoverFrame` 读）。
class ShelfCoverNsfw extends InheritedWidget {
  const ShelfCoverNsfw({required this.blur, required super.child, super.key});

  final bool blur;

  /// 子树没有这一层时为 false（不模糊）。
  static bool blurOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfCoverNsfw>()?.blur ??
      false;

  @override
  bool updateShouldNotify(ShelfCoverNsfw oldWidget) => oldWidget.blur != blur;
}

/// 卡壳挂的 NSFW 作用域：[target] 为 null（远端条目等不可标的宿主）时不模糊。
class MediaNsfwCoverScope extends ConsumerWidget {
  const MediaNsfwCoverScope({
    required this.target,
    required this.child,
    super.key,
  });

  final MediaNsfwTarget? target;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MediaNsfwTarget? t = target;
    final bool blur =
        t != null && ref.watch(blurNsfwCoversProvider) && watchIsMediaNsfw(ref, t);
    return ShelfCoverNsfw(blur: blur, child: child);
  }
}

/// 封面模糊的高斯 sigma（逻辑像素）。够大到认不出画面，又保留主色调让书架不突兀。
const double kNsfwCoverBlurSigma = 18;

/// 把 [child]（一张封面）按 [blur] 打模糊，中间压一枚「已隐藏」图标。模糊强度随
/// 开关做一段短过渡（MD3 / Apple 共用 [FushiMotion] 时长；减弱动态时直接跳）。
/// 树结构恒定（不按 blur 增删层），开关切换不重建封面图。
class NsfwCoverBlur extends StatelessWidget {
  const NsfwCoverBlur({
    required this.blur,
    required this.child,
    this.showIcon = true,
    super.key,
  });

  final bool blur;
  final Widget child;

  /// 小缩略图（列表行 40 宽那种）不压图标，避免喧宾夺主。
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: blur ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: child,
      builder: (BuildContext context, double t, Widget? cover) {
        final double sigma = kNsfwCoverBlurSigma * t;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            ClipRect(
              child: ImageFiltered(
                key: const ValueKey<String>('nsfw-cover-blur'),
                enabled: sigma > 0.01,
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: sigma,
                  sigmaY: sigma,
                  tileMode: TileMode.decal,
                ),
                child: cover,
              ),
            ),
            if (showIcon)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: t,
                    child: Center(
                      child: FushiIcon(
                        FushiIcons.visibilityOff,
                        size: 28,
                        color: Colors.white.withValues(alpha: 0.9),
                        shadows: const <Shadow>[
                          Shadow(color: Colors.black54, blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 不经卡壳作用域的封面（继续卡、详情页 hero 等）：按 [target] 自己判定后包
/// [NsfwCoverBlur]。[target] 为 null 时原样返回 [child]。
class MediaNsfwCover extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final MediaNsfwTarget? t = target;
    final bool blur =
        t != null && ref.watch(blurNsfwCoversProvider) && watchIsMediaNsfw(ref, t);
    return NsfwCoverBlur(blur: blur, showIcon: showIcon, child: child);
  }
}
