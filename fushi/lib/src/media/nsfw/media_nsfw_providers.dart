/// 作品级「NSFW」封面模糊的 Riverpod 接线（本体见 `media_nsfw_cover.dart`）：从
/// AppModel 取数据库与「模糊 NSFW 封面」开关，由 app 根的 [MediaNsfwStateHost] 经
/// [MediaNsfwState] 广播。只有这一层读 AppModel——封面消费端只读 [MediaNsfwState]，
/// 不会因为画封面把 AppModel 拖进它们的 import 闭包。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/models/app_model.dart';
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

/// 全局「模糊 NSFW 封面」开关（偏好 `blur_nsfw_covers`，默认开）。
final Provider<bool> blurNsfwCoversProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel m) => m.prefsRepo.blurNsfwCovers)),
);

/// [target] 当前是否 NSFW（watch 快照）。供卡壳之外需要判定的消费端（制卡等）用。
bool watchIsMediaNsfw(WidgetRef ref, MediaNsfwTarget target) => target.resolve(
  ref.watch(mediaNsfwSnapshotProvider).valueOrNull ?? MediaNsfwSnapshot.none,
);

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
