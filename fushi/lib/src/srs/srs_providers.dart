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
import 'package:path/path.dart' as p;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
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

/// 制卡此刻是否发往 Fushi 复习（复习模块开着 **且** 挖词目标 = Fushi 复习）。
///
/// 制卡装饰链（`ankiRepositoryProvider`）与制卡设置页的 Anki 专属项显隐共用这一个
/// 判据：为 true 时制卡不经过 Anki，只作用于 Anki 发送链路的设置一律不显示。
final Provider<bool> srsMiningToReviewProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(srsModuleEnabledProvider) &&
      ref.watch(appProvider.select((AppModel app) => app.srsMiningTarget)) ==
          SrsMiningTarget.srs,
);

/// 制卡设置里「Fushi 复习」分组的数据：可选牌组 / 笔记类型 + 当前偏好解析后的落地
/// 位置（含被删回落）。
class SrsMiningChoices {
  const SrsMiningChoices({
    required this.decks,
    required this.noteTypes,
    required this.resolved,
    required this.lapisNoteTypeId,
  });

  /// (牌组 id, 「父::子」全名)，按全名排。
  final List<(String, String)> decks;
  final List<SrsNoteTypeView> noteTypes;
  final SrsResolvedMiningDestination resolved;
  final String lapisNoteTypeId;
}

/// 复习卡面外观（按 profile 的偏好；改动即时生效，卡面经 `__fushiSrsSetTheme` 原地换）。
final Provider<SrsCardAppearance> srsCardAppearanceProvider =
    Provider<SrsCardAppearance>(
      (Ref ref) => ref.watch(
        appProvider.select((AppModel app) => app.srsCardAppearance),
      ),
    );

/// 卡面可供给的导入字体目录（app 字体库目录；测试覆写）。null = 不供给导入字体。
final Provider<String?> srsCardFontRootProvider = Provider<String?>((Ref ref) {
  try {
    // 与字体库页 customFontsDirectory 同一个目录（`<appDirectory>/custom_fonts`）。
    return p.join(ref.read(appProvider).appDirectory.path, 'custom_fonts');
  } catch (_) {
    return null;
  }
});

/// 订阅 [srsRevisionProvider] 与制卡去向偏好；store 不可用时为 null。
final FutureProvider<SrsMiningChoices?> srsMiningChoicesProvider =
    FutureProvider<SrsMiningChoices?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsMiningDestination destination = ref.watch(
        appProvider.select((AppModel app) => app.srsMiningDestination),
      );
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final SrsDeckTree tree = await store.deckTree();
      final List<(String, String)> decks = <(String, String)>[
        for (final SrsDeckView d in tree.decks) (d.id, tree.fullName(d.id)),
      ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));
      return SrsMiningChoices(
        decks: decks,
        noteTypes: await store.noteTypes(),
        resolved: await resolveSrsMiningDestination(store, destination),
        lapisNoteTypeId: store.lapisNoteTypeId,
      );
    });

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
      final Directory support = await ref.watch(srsSupportRootProvider)();
      final SrsDbStore store = await SrsDbStore.open(
        db: app.database,
        profileUid: profileUid,
        deviceId: deviceId,
        engine: engine,
        // 复习的「今天」与统计页共用日界（stats_day_reset_hour）；profile 设置里
        // 有同步来的翻日时刻时以它为准（见 SrsDbStore.dayContext）。
        fallbackRolloverHour: () => app.statDayResetHour,
        // 释义样式去重：共享样式文件与卡片媒体同目录（随媒体同步 / 备份走）。
        styles: SrsStyleStore(SrsStyleStore.directoryFor(support, profileUid)),
      );
      // 存量去重在后台分批跑，不挡打开；store 换掉（切 profile / 关模块）时停下，下次从断点续。
      bool disposed = false;
      ref.onDispose(() => disposed = true);
      srsRunLogged('srsCompactStoredStyles', () async {
        await store.compactStoredStyles(shouldStop: () => disposed);
      });
      return store;
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

/// 牌组列表（订阅 [srsRevisionProvider]，写操作后自动重读）。模块关着时为 null。
final FutureProvider<SrsDeckListData?> srsDeckListProvider =
    FutureProvider<SrsDeckListData?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final List<SrsDeckSummary> decks = await store.deckSummaries();
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
