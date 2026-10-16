/// Fushi 内置复习（SRS）的 Riverpod 装配。
///
/// - [srsModuleEnabledProvider]：复习模块（[ModuleId.srs]，默认关）此刻是否可见。
///   **模块关着时一切 SRS 状态都不建**：[srsStoreProvider] 直接给 null，不碰数据库。
/// - [srsEngineProvider]：FSRS 原生内核；库缺失时为 null（页面显示「排程内核不可用」，
///   允许浏览 / 编辑，不能复习）。测试里覆写成假引擎。
/// - [srsStoreProvider]：按当前 profile 打开的 [SrsDbStore]；切 profile 时随
///   `activeProfileId` 重建（profile 的全局身份由 `FushiDatabase.profileUidOf` 给出）。
/// - [srsRevisionProvider]：本机写操作后的刷新信号。store 本身不发变更流，页面写完
///   一律 [bumpSrsRevision]，订阅它的列表 / 计数随之重读。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 复习模块此刻是否可见（用户意愿 + 平台判据的唯一合成，见 [ModuleVisibility]）。
final Provider<bool> srsModuleEnabledProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select(
      (AppModel app) => app.moduleVisibility.isEnabled(ModuleId.srs),
    ),
  ),
);

/// FSRS 排程内核。原生库不可用时为 null（不抛）。
final Provider<FsrsEngine?> srsEngineProvider = Provider<FsrsEngine?>((
  Ref ref,
) {
  try {
    return FfiFsrsEngine.tryCreate();
  } catch (e, stack) {
    // tryCreate 约定不抛；真抛了（符号缺失等）同样当「不可用」，并留痕。
    ErrorLogService.instance.log('srsEngineProvider', e, stack);
    return null;
  }
});

/// 当前 profile 的 SRS 副本；模块关着时为 null。
final FutureProvider<SrsDbStore?> srsStoreProvider =
    FutureProvider<SrsDbStore?>((Ref ref) async {
      if (!ref.watch(srsModuleEnabledProvider)) return null;
      final int activeProfileId = ref.watch(
        profileViewModelProvider.select(
          (ProfileUiState s) => s.activeProfileId,
        ),
      );
      final FsrsEngine? engine = ref.watch(srsEngineProvider);
      final AppModel app = ref.read(appProvider);
      final int profileId = activeProfileId > 0
          ? activeProfileId
          : await app.database.resolveActiveProfileId();
      final String profileUid = await app.database.profileUidOf(profileId);
      final String deviceId = await SyncRepository(
        app.database,
      ).getOrCreateDeviceId();
      return SrsDbStore.open(
        db: app.database,
        profileUid: profileUid,
        deviceId: deviceId,
        engine: engine,
        // 复习的「今天」与统计页共用日界（stats_day_reset_hour）；profile 设置里
        // 有同步来的翻日时刻时以它为准（见 SrsDbStore.dayContext）。
        fallbackRolloverHour: () => app.statDayResetHour,
      );
    });

/// SRS 媒体根所在的支持目录（测试覆写成临时目录）。
final Provider<Future<Directory> Function()> srsSupportRootProvider =
    Provider<Future<Directory> Function()>(
      (Ref ref) => AppPaths.supportRootDirectory,
    );

/// 当前 profile 的 SRS 媒体目录（`<support>/srs_media/<profileUid>/`）；模块关着时为 null。
final FutureProvider<SrsMediaStore?> srsMediaStoreProvider =
    FutureProvider<SrsMediaStore?>((Ref ref) async {
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final Directory support = await ref.watch(srsSupportRootProvider)();
      return SrsMediaStore(
        SrsMediaStore.directoryFor(support, store.profileUid),
      );
    });

/// 正在显示的复习页数量（复习页 initState +1 / dispose −1）。自动优化据此判断「在复习」，
/// 进入复习页时取消在跑的优化（见 srs_optimization_scheduler.dart）。
final ValueNotifier<int> srsActiveReviewSessions = ValueNotifier<int>(0);

/// 复习页是否自动播放卡面音频（按 profile 的偏好，默认关）。
final Provider<bool> srsReviewAutoplayAudioProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) => app.srsReviewAutoplayAudio),
  ),
);

/// 答案面上手动重播时是否先播问题面音频（默认开，同 Anki）。
final Provider<bool> srsReviewReplayQuestionAudioProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) => app.srsReviewReplayQuestionAudio),
  ),
);

/// 本机写操作后的刷新信号（单调递增）。
final StateProvider<int> srsRevisionProvider = StateProvider<int>(
  (Ref ref) => 0,
);

/// 写完数据后调用：订阅 [srsRevisionProvider] 的列表与计数重读。
void bumpSrsRevision(WidgetRef ref) {
  ref.read(srsRevisionProvider.notifier).state++;
}

/// 牌组列表数据（牌组行 + 待处理的同步冲突数 + 待裁决笔记数）。
class SrsDeckListData {
  const SrsDeckListData({
    required this.store,
    required this.decks,
    required this.conflictCount,
  });

  final SrsDbStore store;
  final List<SrsDeckSummary> decks;

  /// 同步冲突（标志 / 设置类）+ 待裁决笔记，合计。
  final int conflictCount;

  int get totalCards => decks.fold<int>(
    0,
    (int sum, SrsDeckSummary d) => d.depth == 0 ? sum + d.totalCards : sum,
  );
}

/// 牌组列表实际显示哪些牌组：照 Anki 的惯例把**空的默认牌组**藏起来。
///
/// 默认牌组不能删（制卡 / 导入 / 删牌组时卡片都以它为兜底落点，见
/// `SrsDbStore.deleteDeck`），但它常年空着摆在列表顶上又删不掉。Anki 的做法
/// （rslib `decks/tree.rs` 的 `hide_default_deck`）：默认牌组里没有卡、也没有
/// 子牌组时不显示；唯一的顶层牌组就是它时照常显示（不然列表是空的，也没处加卡）。
/// 只影响牌组列表页；选牌组的对话框、移卡、制卡目标照常能选到它。
List<SrsDeckSummary> srsVisibleDecks(
  List<SrsDeckSummary> decks, {
  required String defaultDeckId,
}) {
  final SrsDeckSummary? def = decks
      .where((SrsDeckSummary d) => d.deck.id == defaultDeckId)
      .firstOrNull;
  if (def == null || def.totalCards > 0) return decks;
  final String childPrefix = '${def.fullName}::';
  final bool hasChildren = decks.any(
    (SrsDeckSummary d) => d.fullName.startsWith(childPrefix),
  );
  if (hasChildren) return decks;
  final bool onlyTopLevel =
      def.depth == 0 &&
      !decks.any((SrsDeckSummary d) => d.depth == 0 && d != def);
  if (onlyTopLevel) return decks;
  return <SrsDeckSummary>[
    for (final SrsDeckSummary d in decks)
      if (d != def) d,
  ];
}

/// 牌组列表（订阅 [srsRevisionProvider]，写操作后自动重读）。模块关着时为 null。
final FutureProvider<SrsDeckListData?> srsDeckListProvider =
    FutureProvider<SrsDeckListData?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final List<SrsDeckSummary> decks = srsVisibleDecks(
        await store.deckSummaries(),
        defaultDeckId: store.defaultDeckId,
      );
      final int conflicts = (await store.syncConflicts()).length;
      final int pending = (await store.notesPendingDecision()).length;
      return SrsDeckListData(
        store: store,
        decks: decks,
        conflictCount: conflicts + pending,
      );
    });

/// 等 store 就绪（页面动作里用）。模块关着 / 打开失败时返回 null。
Future<SrsDbStore?> readSrsStore(WidgetRef ref) async {
  try {
    return await ref.read(srsStoreProvider.future);
  } catch (e, stack) {
    ErrorLogService.instance.log('readSrsStore', e, stack);
    return null;
  }
}

/// 把一个 Future 交给后台跑并记录失败（按钮回调里用）。
void srsRunLogged(String where, Future<void> Function() body) {
  unawaited(
    body().catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log(where, e, stack);
    }),
  );
}
