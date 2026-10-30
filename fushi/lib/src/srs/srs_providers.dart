/// Fushi 内置复习（SRS）的 Riverpod 装配。
///
/// - [srsModuleEnabledProvider]：复习模块（[ModuleId.srs]，默认关）此刻是否可见。
///   **模块关着时一切 SRS 状态都不建**：[srsStoreProvider] 直接给 null，不碰数据库。
/// - [srsEngineProvider]：FSRS 原生内核；库缺失时为 null（页面显示「排程内核不可用」，
///   允许浏览 / 编辑，不能复习）。测试里覆写成假引擎。
/// - [srsStorageProvider]：进程级 SRS 存储（`srs.db`，[AppModel.srsStorage]）；模块关着时为 null，
///   不打开文件。非主进程在主进程完成首次搬迁之前也为 null（见 `SrsStorageHost`）。
/// - [srsStoreProvider]：按当前 profile 打开的 [SrsDbStore]；切 profile 时随
///   `activeProfileId` 重建（profile 的全局身份由 `FushiDatabase.profileUidOf` 给出）。
/// - [srsRevisionProvider]：本机写操作后的刷新信号。store 本身不发变更流，页面写完
///   一律 [bumpSrsRevision]，订阅它的列表 / 计数随之重读。信号不分种类，由消费方按数据自己
///   判断要不要真重算：整库扫一遍的角标（同步冲突 / 待裁决 / 旧 Lapis 迁移提醒）按
///   [SrsDbStore.contentFingerprint] 复用上次结果（[_srsMemoByContent]），评分只落日志，
///   不重扫它们；牌组收起 / 展开（界面状态）不发信号（见 `srs_deck_list_page.dart`）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, ValueListenable, ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
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

/// 卡面字体链：统一字体库里「复习卡片」用途（`FontTarget.srsCard`）的有序字体列表
/// （`[{name, path, enabled}]`）。按内容比较，字体库没改动时不触发卡面更新。
final Provider<List<Map<String, dynamic>>> srsCardFontsProvider =
    Provider<List<Map<String, dynamic>>>((Ref ref) {
      final String json = ref.watch(
        appProvider.select((AppModel app) => jsonEncode(app.srsCardFonts)),
      );
      return <Map<String, dynamic>>[
        for (final Object? e in jsonDecode(json) as List<Object?>)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    });

/// 字体库「复习卡片」链里已注册进引擎的 family 名（原生渲染 Fushi 卡片用）。
final Provider<List<String>> srsCardFontFamiliesProvider =
    Provider<List<String>>((Ref ref) {
      final String joined = ref.watch(
        appProvider.select(
          (AppModel app) => jsonEncode(app.srsCardFontFamilies),
        ),
      );
      return (jsonDecode(joined) as List<Object?>).whereType<String>().toList();
    });

/// 复习页评分栏是否只留「重来 / 良好」（按 profile 的偏好，对齐 AnkiDroid
/// hideHardAndEasy；键盘 2/4 仍有效）。
final Provider<bool> srsReviewHideHardEasyProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) => app.srsReviewHideHardEasy),
  ),
);

/// 复习页底部操作行一端的重播音频键（按 profile 偏好，默认不放）。
final Provider<SrsReviewReplayButton> srsReviewReplayButtonProvider =
    Provider<SrsReviewReplayButton>(
      (Ref ref) => ref.watch(
        appProvider.select((AppModel app) => app.srsReviewReplayButton),
      ),
    );

/// 复习卡面图片大小（按 profile 偏好，默认原样）。
final Provider<SrsReviewImageSize> srsReviewImageSizeProvider =
    Provider<SrsReviewImageSize>(
      (Ref ref) => ref.watch(
        appProvider.select((AppModel app) => app.srsReviewImageSize),
      ),
    );

/// 评分按钮是否显示下次间隔（按 profile 偏好，默认显示）。
final Provider<bool> srsReviewShowIntervalsProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) => app.srsReviewShowIntervals),
  ),
);

/// 复习页顶栏是否悬浮（按 profile 偏好，默认悬浮：不占布局、默认收起，点卡面空白 / 右键
/// 唤出，与小说、漫画阅读器一致）。
final Provider<bool> srsReviewChromeFloatingProvider = Provider<bool>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) => app.srsReviewChromeFloating),
  ),
);

/// 复习页正面点卡面空白是否直接显示答案（按 profile 偏好，默认关）。
final Provider<bool> srsReviewTapToRevealProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel app) => app.srsReviewTapToReveal)),
);

/// 复习页页头是否显示剩余卡数（按 profile 偏好，默认显示；对齐 Anki「显示剩余卡片数量」）。
final Provider<bool> srsReviewShowCountsProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel app) => app.srsReviewShowCounts)),
);

/// 复习卡面音频音量（0–1，按 profile 偏好，默认 1）：卡面点播与自动连播都按它播。
final Provider<double> srsReviewVolumeProvider = Provider<double>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel app) => app.srsReviewVolume)),
);

/// 复习页卡面缩放倍率（Ctrl / ⌘ + 滚轮、Ctrl + 加减号 / 0），按 profile 偏好。
final Provider<double> srsReviewZoomProvider = Provider<double>(
  (Ref ref) =>
      ref.watch(appProvider.select((AppModel app) => app.srsReviewZoom)),
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

/// 进程级 SRS 存储；模块关着时为 null（不打开 srs.db）。存储本身归 [AppModel.srsStorage]
/// 管（关主库时一起关），这里不在 dispose 时关它：同一进程里重建 provider 复用同一份连接。
final FutureProvider<SrsStorage?> srsStorageProvider =
    FutureProvider<SrsStorage?>((Ref ref) async {
      if (!ref.watch(srsModuleEnabledProvider)) return null;
      return ref.read(appProvider).srsStorage.acquire();
    });

/// 当前 profile 的 SRS 副本；模块关着时为 null。
final FutureProvider<SrsDbStore?> srsStoreProvider =
    FutureProvider<SrsDbStore?>((Ref ref) async {
      final SrsStorage? storage = await ref.watch(srsStorageProvider.future);
      if (storage == null) return null;
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
        db: storage.db,
        core: storage.core,
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
      // 媒体保留期回收：只被「删除已满 90 天」的笔记引用的本机媒体（srs_purge.dart）。历史本身永久保留。
      srsRunLogged('srsPurgeExpiredTombstones', () async {
        if (disposed) return;
        await srsPurgeExpiredTombstones(
          store,
          mediaRoot: SrsMediaStore.directoryFor(support, profileUid),
        );
      });
      return store;
    });

/// RWKV 权重目录（`<support>/srs_rwkv/models`）：按需下载，走全应用代理。
final FutureProvider<SrsRwkvModels> srsRwkvModelsProvider =
    FutureProvider<SrsRwkvModels>((Ref ref) async {
      final Directory support = await ref.watch(srsSupportRootProvider)();
      return SrsRwkvModels(
        dir: Directory(p.join(support.path, 'srs_rwkv', 'models')),
        createClient: createAppHttpClient,
      );
    });

/// RWKV 排程服务：挂到 store 上（[SrsDbStore.rwkv]）。对象本身很轻；后台 isolate 与全量回放
/// 只在有 RWKV 牌组、且权重已下载时启动（[SrsRwkvService.start]，或第一次给 RWKV 牌组排程时）。
/// 由 `srsAppRuntimeProvider` 保活（模块开着时常驻）。换 profile / 关模块时关掉（存快照）。
final FutureProvider<SrsRwkvService?> srsRwkvServiceProvider =
    FutureProvider<SrsRwkvService?>((Ref ref) async {
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final SrsRwkvModels models = await ref.watch(
        srsRwkvModelsProvider.future,
      );
      final Directory support = await ref.watch(srsSupportRootProvider)();
      final SrsRwkvService service = SrsRwkvService(
        store: store,
        models: models,
        snapshotDir: Directory(p.join(support.path, 'srs_rwkv', 'state')),
        log: (String message) => ErrorLogService.instance.log(
          'SrsRwkvService',
          message,
          StackTrace.current,
        ),
      );
      store.rwkv = service;
      ref.onDispose(() {
        if (identical(store.rwkv, service)) store.rwkv = null;
        unawaited(service.close());
      });
      final SrsDeckTree tree = await store.deckTree();
      if (tree.decks.any(
        (SrsDeckView d) => tree.paramsOwner(d.id).localAlgorithm.usesRwkv,
      )) {
        srsRunLogged('SrsRwkvService.start', service.start);
      }
      return service;
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

/// [srsRevisionProvider] 每一跳的来源：本机写入，还是同步从别的设备拉进来的变更。
///
/// 两种都要让界面重读，但只有本机写入需要再推给别的设备（反馈 I1Bg6uMZ32）：以前同步拉入的变更也
/// 递增同一个修订号，而本机推送（`SrsLocalPush`）监听的正是它——拉进来的数据 5 秒后又触发一轮推送
/// 同步，复习同步横幅再弹一次、库页内容跟着上下挪，且这轮推送什么也不用推（拉入那一轮已经把本机
/// 待发的操作一并发出）。修订号单调递增，记下同步那一跳的值即可在监听处分辨，不需要另一条信号。
class SrsRevisionOrigin {
  int? _pulledRevision;

  /// 同步拉入了变更：递增修订号让界面重读，并记下这一跳来自同步。
  void bumpPulled(StateController<int> revision) {
    final int next = revision.state + 1;
    _pulledRevision = next;
    revision.state = next;
  }

  /// [revision] 这一跳是不是本机写入（不是 [bumpPulled] 递增出来的）。
  bool isLocalWrite(int revision) => revision != _pulledRevision;
}

/// 只在本机写入时调 [onLocalWrite]（同步拉入的变更不算，见 [SrsRevisionOrigin]）。
void listenSrsLocalWrites(
  Ref ref,
  SrsRevisionOrigin origin,
  void Function() onLocalWrite,
) {
  ref.listen<int>(srsRevisionProvider, (int? previous, int next) {
    if (origin.isLocalWrite(next)) onLocalWrite();
  });
}

/// 本机复习数据有变动、但**不要求**列表 / 计数此刻重读的信号（单调递增）：复习页里的评分 /
/// 撤销 / 搁置等。只有互联快速通道订阅它（`srs_app_runtime.dart`，去抖后推一轮）。
///
/// 复习页压在牌组列表 / 首页之上，那些页面此刻看不见；以前每评一张卡都发
/// [srsRevisionProvider]，被盖住的牌组列表随之整库重算一遍计数（[SrsDbStore.deckSummaries]）、
/// 整页重建两三次，正撞在下一张卡上屏与进场动画的那几帧上（BUG：评分后下一张卡掉帧）。
/// 进复习页的三个入口（牌组列表、首页复习条、导航速览）都在复习页返回时发一次
/// [bumpSrsRevision]，列表回到屏上时照样是新的。
final StateProvider<int> srsLocalWriteProvider = StateProvider<int>(
  (Ref ref) => 0,
);

/// 复习页的写操作后调用：只通知互联推送（见 [srsLocalWriteProvider]）。
void bumpSrsLocalWrite(WidgetRef ref) {
  ref.read(srsLocalWriteProvider.notifier).state++;
}

/// 删牌组的执行与进度（BUG-3543 的分块删除）：app 级，不随牌组列表页销毁。
///
/// 以前进度 notifier 与「删完重读」都挂在牌组列表页的 State 上；复习 tab 不常驻，删除途中
/// 切走 tab 页面就被销毁——debug 下往已销毁的 notifier 写进度抛断言、从分块循环里冒出来
/// 把删除停在一半；release 下 `if (mounted)` 把重读跳过，列表缓存里一直留着已删的牌组。
/// 现在删除由本控制器跑完：进度 notifier 归控制器所有，页面只订阅；删完（或失败）一律让
/// 列表重读，与页面在不在无关。
class SrsDeckDeleteController extends ChangeNotifier {
  SrsDeckDeleteController({required void Function() onDataChanged})
    : _onDataChanged = onDataChanged;

  final void Function() _onDataChanged;

  /// 正在删（或已删完、列表还没重读掉它）的牌组 → 进度（0–1；null = 还不知道总数）。
  final Map<String, ValueNotifier<double?>> _deleting =
      <String, ValueNotifier<double?>>{};

  /// 已经删完、等列表重读的牌组。
  final Set<String> _deleted = <String>{};
  bool _disposed = false;

  /// 正在删的牌组及其进度（子牌组随父牌组一起显示删除中，由页面按层级查）。
  Map<String, ValueListenable<double?>> get deleting =>
      Map<String, ValueListenable<double?>>.unmodifiable(_deleting);

  /// 这个牌组是否在删（删完、等重读的也算：行保持删除中，直到列表里没有它）。
  bool isDeleting(String deckId) => _deleting.containsKey(deckId);

  /// 删一个牌组（连同子牌组，见 `SrsDbStore.deleteDeck`；[deleteCards] 为真时连卡片一起删）。
  /// 同一个牌组已经在删时直接返回。
  /// 失败原样抛出（调用方记日志）；成功或失败都让列表重读（失败也可能已提交了前几块）。
  ///
  /// [purgeNow]（只在 [deleteCards] 时有意义）：删完立刻彻底清除这些笔记（v2 `Purge` 操作，各设备一起
  /// 清内容）与不再被引用的媒体（[mediaRoot]），不可恢复（见 srs_purge.dart）。
  Future<void> delete(
    SrsDbStore store,
    String deckId, {
    bool deleteCards = false,
    bool purgeNow = false,
    Directory? mediaRoot,
  }) async {
    if (_disposed || _deleting.containsKey(deckId)) return;
    final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
    _deleting[deckId] = progress;
    _notify();
    try {
      final List<String> deletedNotes = await store.deleteDeck(
        deckId,
        deleteCards: deleteCards,
        onProgress: (int done, int total) {
          if (!_disposed && total > 0) progress.value = done / total;
        },
      );
      if (purgeNow && deletedNotes.isNotEmpty) {
        await srsPurgeNotesNow(store, deletedNotes, mediaRoot: mediaRoot);
      }
      _deleted.add(deckId);
    } catch (_) {
      if (identical(_deleting[deckId], progress)) {
        _deleting.remove(deckId);
        progress.dispose();
      }
      _notify();
      rethrow;
    } finally {
      if (!_disposed) _onDataChanged();
    }
  }

  /// 重读回来的列表里已经没有的、删完的牌组：撤掉删除中状态。不发通知——由正在用这份新
  /// 列表建界面的页面调用，它这一帧本来就按新列表画（列表里没有这些行）。
  void pruneDeleted(Iterable<String> presentDeckIds) {
    if (_deleted.isEmpty) return;
    final Set<String> present = presentDeckIds.toSet();
    for (final String id in _deleted.toList()) {
      if (present.contains(id)) continue;
      _deleted.remove(id);
      // 旧行若还挂着监听，卸载时对已销毁的 notifier 调 removeListener 是允许的。
      _deleting.remove(id)?.dispose();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final ValueNotifier<double?> n in _deleting.values) {
      n.dispose();
    }
    _deleting.clear();
    super.dispose();
  }
}

/// 进程内唯一的删牌组控制器（根容器里常驻，不随页面销毁）。
final Provider<SrsDeckDeleteController> srsDeckDeleteControllerProvider =
    Provider<SrsDeckDeleteController>((Ref ref) {
      final SrsDeckDeleteController c = SrsDeckDeleteController(
        onDataChanged: () => ref.read(srsRevisionProvider.notifier).state++,
      );
      ref.onDispose(c.dispose);
      return c;
    });

/// 牌组列表数据（牌组行）。同步冲突数另见 [srsConflictCountProvider]。
class SrsDeckListData {
  const SrsDeckListData({
    required this.store,
    required this.decks,
    this.revision = 0,
  });

  final SrsDbStore store;
  final List<SrsDeckSummary> decks;

  /// 开始读这份数据时 store 的修订号（[SrsDbStore.revision]）：≥ 某次写入完成时的修订号 = 这份
  /// 数据一定反映了那次写入（牌组列表据此撤掉收起 / 展开的本地覆盖）。
  final int revision;

  int get totalCards => _sumRoots((SrsDeckSummary d) => d.totalCards);

  /// 今日新卡 / 学习中 / 到期：顶层牌组行上的计数之和（顶层行已含全部子牌组，
  /// 与牌组列表显示的数字同一口径；首页复习条读这三个）。
  int get todayNew => _sumRoots((SrsDeckSummary d) => d.newCount);
  int get todayLearn => _sumRoots((SrsDeckSummary d) => d.learnCount);
  int get todayReview => _sumRoots((SrsDeckSummary d) => d.reviewCount);

  /// 今天还有没有可复习的卡（三种计数任一非零）。
  bool get hasWorkToday => todayNew + todayLearn + todayReview > 0;

  /// 「开始复习」落到的牌组：按牌组列表顺序第一个还有待复习卡的顶层牌组；没有时为 null。
  SrsDeckSummary? get firstRootWithWork {
    for (final SrsDeckSummary d in decks) {
      if (d.depth == 0 && d.newCount + d.learnCount + d.reviewCount > 0) {
        return d;
      }
    }
    return null;
  }

  int _sumRoots(int Function(SrsDeckSummary d) pick) => decks.fold<int>(
    0,
    (int sum, SrsDeckSummary d) => d.depth == 0 ? sum + pick(d) : sum,
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
///
/// 只读牌组行：同步冲突数是另一个 provider（[srsConflictCountProvider]）。以前两者合在一个
/// Future 里，新建 / 改名牌组后列表要等冲突扫描（读回并解析全部修改记录）跑完才换成新数据，
/// 新牌组迟迟不出现（BUG-3548）。
final FutureProvider<SrsDeckListData?> srsDeckListProvider =
    FutureProvider<SrsDeckListData?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final int revision = store.revision;
      final List<SrsDeckSummary> decks = srsVisibleDecks(
        await store.deckSummaries(),
        defaultDeckId: store.defaultDeckId,
      );
      return SrsDeckListData(store: store, decks: decks, revision: revision);
    });

/// 偏好：牌组列表顶部是否提醒「还有旧 Lapis 笔记可迁到 Fushi 卡片」（缺省 = 提醒）。
const String kSrsLapisMigrationReminderPrefKey = 'srs_lapis_migration_reminder';

/// 是否显示旧 Lapis 迁移提醒（读写偏好 [kSrsLapisMigrationReminderPrefKey]）。
final StateProvider<bool> srsLapisMigrationReminderProvider =
    StateProvider<bool>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      // 偏好还没装好（启动早期 / 未初始化的测试 AppModel）：按缺省提醒。
      if (!app.isPreferencesReady) return true;
      return app.prefsRepo.getPref(
            kSrsLapisMigrationReminderPrefKey,
            defaultValue: true,
          ) !=
          false;
    });

/// 关掉旧 Lapis 迁移提醒（「不再提醒」）：立即生效并落偏好。
Future<void> dismissSrsLapisMigrationReminder(WidgetRef ref) async {
  ref.read(srsLapisMigrationReminderProvider.notifier).state = false;
  final AppModel app = ref.read(appProvider);
  if (!app.isPreferencesReady) return;
  await app.prefsRepo.setPref(kSrsLapisMigrationReminderPrefKey, false);
}

/// 一个整库计数在某个 store 内容指纹下的结果（[_srsMemoByContent]）。
class _SrsContentMemo {
  const _SrsContentMemo(this.fingerprint, this.value);

  final String fingerprint;
  final Future<int> value;
}

final Expando<_SrsContentMemo> _lapisPendingMemo = Expando<_SrsContentMemo>(
  'srsLegacyLapisPending',
);
final Expando<_SrsContentMemo> _conflictCountMemo = Expando<_SrsContentMemo>(
  'srsConflictCount',
);

/// 按 [SrsDbStore.contentFingerprint] 复用 [compute] 的结果：指纹没变（这期间只落了复习日志 /
/// 界面状态类修改记录）时直接给上次的 Future，不再扫库。以前每评一张卡 [srsRevisionProvider]
/// 递增，被复习页盖住的牌组列表就把同步冲突（对全部修改记录分组）、旧 Lapis 迁移提醒各重扫一遍。
///
/// 指纹在开始算**之前**取：算的途中有写入落库，存下的是旧指纹，下次照样重算。失败不缓存（原样
/// 抛给 provider，下次重试）。
Future<int> _srsMemoByContent(
  Expando<_SrsContentMemo> memo,
  SrsDbStore store,
  Future<int> Function() compute,
) {
  final String fingerprint = store.contentFingerprint;
  final _SrsContentMemo? hit = memo[store];
  if (hit != null && hit.fingerprint == fingerprint) return hit.value;
  final Future<int> value = compute();
  final _SrsContentMemo entry = _SrsContentMemo(fingerprint, value);
  memo[store] = entry;
  value.then<void>(
    (_) {},
    onError: (Object _) {
      if (identical(memo[store], entry)) memo[store] = null;
    },
  );
  return value;
}

/// 还能迁到 Fushi 卡片的旧 Lapis 笔记 + 可补迁遗漏字段的笔记，合计（牌组列表的迁移提醒）。
/// 提醒关着时不算（不为看不见的提示扫库）。内容没变时复用上次结果（[_srsMemoByContent]）。
final FutureProvider<int> srsLegacyLapisPendingProvider = FutureProvider<int>((
  Ref ref,
) async {
  ref.watch(srsRevisionProvider);
  if (!ref.watch(srsLapisMigrationReminderProvider)) return 0;
  final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
  if (store == null) return 0;
  return _srsMemoByContent(_lapisPendingMemo, store, () async {
    final ({int migratable, int backfill}) pending = await store
        .legacyLapisPendingCounts();
    return pending.migratable + pending.backfill;
  });
});

/// 待处理的同步冲突（标志 / 设置类）+ 待裁决笔记，合计（牌组列表顶栏的冲突角标）。
/// 订阅 [srsRevisionProvider]；与牌组列表各自重读，互不等待。模块关着时为 0。内容没变时复用
/// 上次结果（[_srsMemoByContent]）：评分只落日志，冲突数不可能因此变。
final FutureProvider<int> srsConflictCountProvider = FutureProvider<int>((
  Ref ref,
) async {
  ref.watch(srsRevisionProvider);
  final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
  if (store == null) return 0;
  return _srsMemoByContent(_conflictCountMemo, store, () async {
    final int conflicts = (await store.syncConflicts()).length;
    final int held = (await store.sync2Conflicts()).length;
    return conflicts + held + await store.pendingDecisionCount();
  });
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
///
/// 用 `then(onError:)` 而不是 `catchError`：[body] 实际返回的可能是 `Future<bool>` 之类（`Future<void>`
/// 收得下任何 Future），`catchError` 的处理函数返回 null 时 Dart 会再抛一个「error handler must return a
/// value of the future's type」的未处理错误。
void srsRunLogged(String where, Future<void> Function() body) {
  unawaited(
    body().then<void>(
      (_) {},
      onError: (Object e, StackTrace stack) {
        ErrorLogService.instance.log(where, e, stack);
      },
    ),
  );
}
