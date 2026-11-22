/// 作品「上锁」显示口径的 Riverpod 接线（[MediaVisibility] 本体见
/// `media_visibility.dart`）：从 AppModel 取数据库读上锁快照、合成口径，由 app 根的
/// [MediaVisibilityHost] 广播。只有这一层读 AppModel——口径本体与消费端（书架 / 视频库 /
/// 统计页……）不经它就能用，不会因为判上锁把 AppModel 拖进它们的 import 闭包。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_lock.dart';
import 'package:material_ui/material_ui.dart';

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

/// app 根挂的 [MediaVisibility] 来源：watch 解锁状态与上锁快照，变了整树里读它的
/// 列表重建。也让快照从启动起就开始读，库页第一次打开时通常已经读完。
class MediaVisibilityHost extends ConsumerWidget {
  const MediaVisibilityHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MediaVisibilityScope(
    visibility: ref.watch(mediaVisibilityProvider),
    child: child,
  );
}
