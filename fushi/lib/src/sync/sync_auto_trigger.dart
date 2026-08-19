import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/book_exit_sync_scope.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

final _bookKeyPattern = RegExp(r'fushi://book/(.+)');

int _activeSyncs = 0;
final ValueNotifier<bool> syncInProgress = ValueNotifier<bool>(false);

/// App-wide latest sync progress tick, fed by EVERY full-sweep run (manual
/// "立即同步" AND the app-open/background auto-sweep). The settings "立即同步" row
/// reflects this so its inline progress bar shows whenever a sync is in flight —
/// not only for the run that row triggered (BUG-101). null between runs (and for
/// the single-book auto-sync path, which has no phase structure → indeterminate).
final ValueNotifier<SyncProgress?> syncProgress =
    ValueNotifier<SyncProgress?>(null);

/// 在飞的这轮同步的**身份**。null = 没有同步在跑。
///
/// [syncProgress] 只在编排器真进入某个阶段后才有值，而每轮同步在那之前还有一整段
/// 准备期（等互斥锁 → 读开关 → 冷却判断 → 走网络鉴权），合集/单本两条轻量路径更是
/// 从头到尾都没有阶段结构。缺了这一层，界面上「在准备」「在跑轻量同步」「所有通道
/// 都没认证过、正在空转」三种现实完全同形。UI 拿不到阶段 tick 时退化到这一层。
final ValueNotifier<SyncActivity?> syncActivity =
    ValueNotifier<SyncActivity?>(null);

/// 最近结束的那轮同步的**结局**，供设置页非打断式地显示「上次同步」。
///
/// 在此之前，通道全没通过认证（什么也没同步）与正常跑完在 UI 上无从区分：两者都是
/// 进度条转一会儿然后消失。自动路径尤其不能靠 SnackBar 补救（退出书同步必须静默，
/// TODO-132 诉求B），所以结局落成状态而不是提示。
final ValueNotifier<SyncRunOutcome?> lastSyncOutcome =
    ValueNotifier<SyncRunOutcome?>(null);
final Set<String> _syncingIds = {};

/// 登记一轮同步开始：递增在飞计数并公布它的身份。
///
/// 四条同步路径（开机自动 sweep / 手动全量 / 合集轻量 / 单本）**必须**经这一对
/// [_beginSyncActivity]、[_endSyncActivity] 维护全局状态，不得再各自手写 notifier
/// 赋值。之前那份四处重复正是「合集与单本路径的 finally 漏清 [syncProgress]」的
/// 来源：全量 sweep 结束时若还有别的同步在飞就不清，而那两条路径自己也不清，于是
/// 上一轮的阶段文字会残留到下一轮开头闪一下。
void _beginSyncActivity(SyncActivity activity) {
  _activeSyncs++;
  syncActivity.value = activity;
  syncInProgress.value = true;
}

/// 登记一轮同步结束：公布结局，并在最后一个在飞同步退出时清空瞬时状态。
void _endSyncActivity(SyncRunOutcome outcome) {
  _activeSyncs--;
  lastSyncOutcome.value = outcome;
  syncInProgress.value = _activeSyncs > 0;
  if (_activeSyncs == 0) {
    syncProgress.value = null;
    syncActivity.value = null;
  }
}

// HBK-AUDIT-049: cloud backends (GoogleDrive/Dropbox/OneDrive/WebDAV/SMB) are
// process-wide singletons holding mutable shared state (_accessToken,
// _cachedApi, _rootFolderId, _titleToFolderId) with no per-operation lock.
// _syncingIds only dedups identical keys, so two DIFFERENT books — or a
// per-book sync overlapping the '__all__' sweep — used to run concurrently and
// interleave on that shared state. Serialize every auto-sync operation through
// one app-wide mutex so a backend's token/api/cache is only ever touched by a
// single in-flight sync. Dedup (_syncingIds) still short-circuits redundant
// triggers before they queue on the mutex.
final AsyncMutex _autoSyncMutex = AsyncMutex();

/// Run [body] under the same app-wide mutex that serializes every auto/manual
/// sync run, so operations that touch the shared singleton backend from OUTSIDE
/// the sync pipeline — chiefly the local-vs-remote compare / conflict dialog's
/// network fetch and apply — can never run concurrently with an in-flight sync.
///
/// Without this, opening compare (or the conflict prompter auto-popping it
/// mid-sync) re-listed the remote and rewrote the singleton's folder-id cache
/// while a sync was mutating the same state, which interrupted the sync and made
/// the compare load slowly or even time out on the contended connection
/// (BUG-083). Joining the lock makes the later of the two simply wait.
///
/// Non-reentrant (see [AsyncMutex]): [body] must NOT call any sync entry point
/// (or this helper again) that would re-acquire the lock.
Future<T> runExclusiveWithSync<T>(Future<T> Function() body) =>
    _autoSyncMutex.withLock(body);

/// Fired after an auto-sync run produced a [SyncRunReport], carrying the
/// already-resolved+authenticated [SyncBackend] so the caller can drive a
/// conflict-resolution dialog without re-resolving/re-authing. Only invoked when
/// the run actually reached a report (auth ok, sync ran); skipped/aborted runs
/// never call it.
typedef SyncReportCallback = void Function(
  SyncRunReport report,
  SyncBackend backend,
);

/// Fired after a full sync run mutates the local library. The sync layer stays
/// UI-agnostic; AppModel uses this hook to refresh caches and visible shelves.
typedef SyncPostRunCallback = Future<void> Function(SyncRunReport report);

@visibleForTesting
void logSyncReportErrors(SyncRunReport report) {
  if (report.errors.isEmpty) return;
  ErrorLogService.instance.log(
    'SyncRunReport.errors',
    report.errors.join('\n'),
  );
}

/// option B 双通道：把每轮完整同步要跑的通道后端列出来。云备份通道恒尝试（用户
/// 选定的 [SyncRepository.getBackendType]），互联通道仅当 [SyncRepository
/// .isInterconnectEnabled] 时追加——互联与云备份不再互斥（backendType 曾把互联
/// 当成互斥单选项，现已解耦成独立开关）。两条通道各用自己的后端实例、各自认证成功
/// 才真正跑（未配置的通道在 [_runSyncChannel] 里 no-op）。
///
/// 去重：互联后端 [InterconnectSyncBackend] 是单例；若用户把「备份后端」也选成互联
/// （互联页的「用互联做备份后端」按钮），云通道解析出的就是同一单例，只保留一条，
/// 避免同一通道跑两遍。
/// 一条待跑的同步通道：后端实例 + 它是不是互联通道。isInterconnect 决定分资产开关
/// 读云备份共享值还是互联专属上传开关（[resolveChannelSyncFlags]，BUG-988）。
class SyncChannel {
  const SyncChannel(
    this.backend, {
    required this.type,
    required this.isInterconnect,
  });
  final SyncBackend backend;

  /// 这条通道解析自哪个 [SyncBackendType]。带上它，「本机有没有配置过这条通道」
  /// 之类的问题就能复用同一份通道枚举去问 [SyncRepository.hasStoredBackendConfig]，
  /// 不必在别处重抄一遍「云 + 互联」的枚举逻辑（会漂）。
  final SyncBackendType type;
  final bool isInterconnect;

  /// 本通道的持久化槽位（BUG-1576 / BUG-1578 / BUG-1579 / BUG-1580）。刻意从
  /// [backend] **实例**反查而不是从 [type] 算：真正写这些键的是 SyncManager /
  /// SyncOrchestrator，它们手上只有后端实例，两处必须是同一个推导，否则「按通道
  /// 记账」会记到两把不同的锁上。
  SyncChannelScope get scope => syncChannelScopeOf(backend);
}

/// 一条同步通道抛出的鉴权失败，**带着它是哪条通道**（BUG-1578）。
///
/// 解耦成双通道后，`runManualFullSync` 里任何一条通道的 [SyncAuthError] 都是裸着
/// 冒到 UI 的，UI 只能拿 `getBackendType()` 猜测「大概是云通道吧」——于是局域网
/// 互联对端的一次 401 会把用户的 Google Drive 会话登出并清掉云通道的目录缓存。
/// 副作用要作用在正确的通道上，异常就必须自己带着通道身份。
class SyncChannelAuthError implements Exception {
  const SyncChannelAuthError({
    required this.channel,
    required this.error,
  });

  /// 抛出这条错误的通道（后端实例 / 通道类型 / 是不是互联都在里面）。
  final SyncChannel channel;

  /// 原始鉴权错误（消息、kind、服务端原因一字不变地保留给 UI）。
  final SyncAuthError error;

  @override
  String toString() => 'SyncChannelAuthError(${channel.type.name}): $error';
}

/// BUG-1604 测试缝：注入本轮要跑的通道列表，绕开 [resolveSyncBackend] 返回的真实
/// 单例后端。生产恒为 null（走下面的真实枚举）。
///
/// 为什么必须有这个缝：本文件里「一条通道抛异常，其余通道照跑」是**循环结构**的
/// 不变式，只能用「第一条通道 throw，断言第二条仍被调用」来守。而真实通道来自六个
/// 后端工厂 + 全套编排依赖，单测层拉不起来——BUG-1552 当初修了 sweep 那条循环却
/// 把测试记成欠账（「待补：抽一个可注入的通道列表测试缝」），于是同一个结构缺陷在
/// 另外两条循环里原样存活到 BUG-1604。缝补上，四条循环才都守得住。
@visibleForTesting
Future<List<SyncChannel>> Function(SyncRepository repo)?
    debugSyncChannelsOverride;

/// 不再 `@visibleForTesting`：`hasDeletionPropagationChannel` 是生产消费方——
/// 「本机有没有可用于删除传播的通道」必须复用同一份通道枚举，各处重抄必漂。
Future<List<SyncChannel>> enabledSyncChannelBackends(
  SyncRepository repo,
) async {
  final Future<List<SyncChannel>> Function(SyncRepository repo)? override =
      debugSyncChannelsOverride;
  if (override != null) return override(repo);
  final SyncBackendType cloudType = await repo.getBackendType();
  final SyncBackend cloud = resolveSyncBackend(cloudType);
  // isInterconnect 由后端身份决定，不由「它排在云通道那一格」决定：备份后端被选成
  // 互联时只剩这一条通道，它跑的就是互联链路（SyncOrchestrator 内部同样按
  // `backend is InterconnectSyncBackend` 判断），分资产开关必须跟着读互联专属的
  // 上传开关——否则用户在互联页看到的四个上传开关会被静默忽略、改由云备份开关决定。
  final List<SyncChannel> channels = <SyncChannel>[
    SyncChannel(cloud,
        type: cloudType, isInterconnect: cloud is InterconnectSyncBackend),
  ];
  if (await repo.isInterconnectEnabled()) {
    final SyncBackend interconnect =
        resolveSyncBackend(SyncBackendType.fushiServer);
    if (!identical(interconnect, cloud)) {
      channels.add(SyncChannel(interconnect,
          type: SyncBackendType.fushiServer, isInterconnect: true));
    }
  }
  return channels;
}

/// 一条同步通道要用的分资产开关集（喂给 [SyncOrchestrator]）。
class ChannelSyncFlags {
  const ChannelSyncFlags({
    required this.syncStats,
    required this.syncFavorites,
    required this.syncAudioBookPosition,
    required this.syncContent,
    required this.syncAudioBookFiles,
    required this.syncVideoFiles,
    required this.syncDictionary,
    required this.syncLocalAudio,
  });
  final bool syncStats;

  /// 收藏词 / 收藏句是否参与本通道的聚合同步。云通道恒等于 [syncStats]（云侧
  /// 聚合快照里统计与收藏本来就由同一个开关代管，拆开会改变云备份的既有行为）；
  /// 互联通道读自己的 `interconnect_sync_favorites`。
  final bool syncFavorites;
  final bool syncAudioBookPosition;
  final bool syncContent;
  final bool syncAudioBookFiles;
  final bool syncVideoFiles;
  final bool syncDictionary;
  final bool syncLocalAudio;
}

/// 按通道解析分资产同步开关（BUG-988）。[isInterconnect]==true（互联通道）时「重内容」
/// 四类——书籍/内容、词典、有声书文件、视频文件——读互联专属上传开关（默认 false，让
/// 用户独立控制是否上传给互联对端，不被「启用互联连接」裹挟）；false（云备份通道）读
/// 原共享 sync_*_enabled。统计与收藏也已分通道（互联侧读 `interconnect_sync_stats` /
/// `interconnect_sync_favorites`，默认 true = 拆开关前的行为）。位置/本地音频仍不区分
/// 通道（轻量进度，跨设备续读是互联本意）。
///
/// 不再 `@visibleForTesting`：`AppModel._propagateDictionaryDeleteToRemote` 是生产
/// 消费方——「这条通道该不该同步词典」必须复用同一份分通道门控，各处重抄必漂
/// （BUG-1566：删词典原来只读云备份的 `isSyncDictionaryEnabled` 一刀切）。
Future<ChannelSyncFlags> resolveChannelSyncFlags(
  SyncRepository repo, {
  required bool isInterconnect,
}) async {
  return ChannelSyncFlags(
    // 统计与收藏在互联通道上各有自己的开关（默认 true = 拆开关前的既有行为）；
    // 云通道仍由 sync_stats_enabled 一把管两族，逐字节不变。
    syncStats: isInterconnect
        ? await repo.isInterconnectSyncStatsEnabled()
        : await repo.isSyncStatsEnabled(),
    syncFavorites: isInterconnect
        ? await repo.isInterconnectSyncFavoritesEnabled()
        : await repo.isSyncStatsEnabled(),
    syncAudioBookPosition: await repo.isSyncAudioBookEnabled(),
    syncContent: isInterconnect
        ? await repo.isInterconnectSyncContentEnabled()
        : await repo.isSyncContentEnabled(),
    syncAudioBookFiles: isInterconnect
        ? await repo.isInterconnectSyncAudioBookFilesEnabled()
        : await repo.isSyncAudioBookFilesEnabled(),
    syncVideoFiles: isInterconnect
        ? await repo.isInterconnectSyncVideoFilesEnabled()
        : await repo.isSyncVideoFilesEnabled(),
    syncDictionary: isInterconnect
        ? await repo.isInterconnectSyncDictionaryEnabled()
        : await repo.isSyncDictionaryEnabled(),
    syncLocalAudio: await repo.isSyncLocalAudioEnabled(),
  );
}

/// 为单个 [backend] 通道构建并运行一轮完整同步编排。认证失败（未配置该通道）返回
/// null，调用方视为该通道 no-op 跳过。云备份通道与互联通道各调一次（见
/// [enabledSyncChannelBackends]），互不排斥（option B 双通道）。
Future<SyncRunReport?> _runSyncChannel({
  required FushiDatabase db,
  required SyncRepository repo,
  required SyncChannel channel,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  required void Function(SyncProgress) onProgress,
}) async {
  try {
    return await _runSyncChannelInner(
      db: db,
      repo: repo,
      channel: channel,
      dictionaryResourceRoot: dictionaryResourceRoot,
      audioDatabaseRoot: audioDatabaseRoot,
      tempDir: tempDir,
      localAudioEntries: localAudioEntries,
      onLocalAudioImported: onLocalAudioImported,
      onProgress: onProgress,
    );
  } on SyncAuthError catch (e) {
    // BUG-1578：给这条错误钉上通道身份再放它出去。上层（手动同步 UI）据此把登出
    // 这类破坏性副作用**只**作用在出错的那条通道上，而不是靠 `getBackendType()`
    // 猜一个通常猜错的对象。
    throw SyncChannelAuthError(channel: channel, error: e);
  }
}

Future<SyncRunReport?> _runSyncChannelInner({
  required FushiDatabase db,
  required SyncRepository repo,
  required SyncChannel channel,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  required void Function(SyncProgress) onProgress,
}) async {
  final SyncBackend backend = channel.backend;
  await backend.restoreAuth(repo);
  if (!await backend.isAuthenticated) return null;
  // BUG-988：互联通道读互联专属上传开关，云备份通道读原共享开关（两通道互不牵连）。
  final ChannelSyncFlags flags = await resolveChannelSyncFlags(repo,
      isInterconnect: channel.isInterconnect);
  final SyncOrchestrator orchestrator = SyncOrchestrator(
    db: db,
    backend: backend,
    dictionaryResourceRoot: dictionaryResourceRoot,
    audioDatabaseRoot: audioDatabaseRoot,
    tempDir: tempDir,
    deviceId: await repo.getOrCreateDeviceId(),
    syncStats: flags.syncStats,
    syncFavorites: flags.syncFavorites,
    syncAudioBookPosition: flags.syncAudioBookPosition,
    syncContent: flags.syncContent,
    syncAudioBookFiles: flags.syncAudioBookFiles,
    syncVideoFiles: flags.syncVideoFiles,
    syncDictionary: flags.syncDictionary,
    syncLocalAudio: flags.syncLocalAudio,
    localAudioEntries: localAudioEntries,
    onLocalAudioImported: onLocalAudioImported,
    onProgress: onProgress,
  );
  return orchestrator.run();
}

void triggerAutoSyncAfterClose({
  required FushiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState messenger,
  SyncReportCallback? onReport,
}) {
  // TODO-132 诉求B：退出书同步是 fire-and-forget（不 await，不阻塞 onWillPop /
  // 退出 UI）。但把这个游离 Future 登记进 app-scope [BookExitSyncScope]，使页面
  // 销毁后它照样跑完，且进程退出路径能有界等它落定——避免「退出书后立刻杀应用」
  // 时关书 export 被打成半截（与 132A/BUG-201 的 baseline 原子化互补）。
  // messenger 仍传入（保留签名 + 留给冲突对话框的祖先上下文经 onReport 走
  // navigatorKey，不依赖它），但**不再**用它弹打断式「同步成功」SnackBar。
  BookExitSyncScope.instance.register(
    _runAutoSync(
      db: db,
      mediaIdentifier: mediaIdentifier,
      messenger: messenger,
      onReport: onReport,
    ),
  );
}

void triggerAutoSyncOnBackground({
  required FushiDatabase db,
  required String mediaIdentifier,
}) {
  // Background (app→paused) intentionally has NO onReport: the user can't see a
  // dialog, so conflicts stay silent until a later visible sync surfaces them.
  _runAutoSync(db: db, mediaIdentifier: mediaIdentifier, messenger: null);
}

/// Full bidirectional sweep on app open: imports remote-only books, syncs all
/// book progress/content, and union-syncs dictionaries + audiobook packages.
/// The asset directories come from [AppModel] (the sync layer must not depend
/// on it) — [audioDatabaseRoot] is where pulled audiobook packages land.
void triggerAutoSyncOnAppOpen({
  required FushiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncReportCallback? onReport,
  SyncPostRunCallback? onPostRun,
}) {
  _runAutoSyncAll(
    db: db,
    dictionaryResourceRoot: dictionaryResourceRoot,
    audioDatabaseRoot: audioDatabaseRoot,
    tempDir: tempDir,
    localAudioEntries: localAudioEntries,
    onLocalAudioImported: onLocalAudioImported,
    onReport: onReport,
    onPostRun: onPostRun,
  );
}

/// BUG-1569① 测试入口：以可 await 的方式跑一轮自动全量 sweep（生产入口
/// [triggerAutoSyncOnAppOpen] 是 fire-and-forget 的 void，测试无从等它落定）。
@visibleForTesting
Future<void> runAutoSyncAllForTest({
  required FushiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
  Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
}) =>
    _runAutoSyncAll(
      db: db,
      dictionaryResourceRoot: dictionaryResourceRoot,
      audioDatabaseRoot: audioDatabaseRoot,
      tempDir: tempDir,
      localAudioEntries: localAudioEntries,
      onLocalAudioImported:
          onLocalAudioImported ?? (LocalAudioPackageContents _) async {},
    );

/// BUG-1604 测试入口：以可 await 的方式跑一次退出书 per-book 同步（生产入口
/// [triggerAutoSyncOnMediaClosed] 把它注册进 [BookExitSyncScope] 且不回传 future）。
@visibleForTesting
Future<void> runAutoSyncForBookForTest({
  required FushiDatabase db,
  required String mediaIdentifier,
  SyncReportCallback? onReport,
}) =>
    _runAutoSync(
      db: db,
      mediaIdentifier: mediaIdentifier,
      messenger: null,
      onReport: onReport,
    );

const _syncCooldownMs = 5 * 60 * 1000;

/// BUG-1569①：整轮自动 sweep 以「失败」结局收场后的退避截止时刻（内存态，不落盘）。
///
/// 根因：成功冷却戳 `lastSyncMs` 由 [SyncOrchestrator.run] 在整轮**完整跑完**后才写
/// （TODO-1332 有意如此，半截 sweep 不得压制下次重试）；而通道异常（典型：只配互联
/// 且对端离线，`findOrCreateRootFolder` 的全候选探测超时抛错）发生在写戳之前——冷却
/// 闸于是永远不推进，首页的每分钟定时 tick（`_periodicSyncInterval`）每次都重新跑一遍
/// 全候选串行探测（2s × 候选数 × 每分钟），零退避。
///
/// 语义（固定退避）：
/// - 任一自动 sweep 以 [SyncOutcomeReason.failed] 收场 → 记「now + [_syncCooldownMs]」
///   为退避截止；截止前的自动 sweep 直接判 [SyncOutcomeReason.cooledDown] 跳过。
/// - 成功（completed）→ 清零退避（对端活了，恢复正常节奏）；手动同步成功同样清零。
/// - autoDisabled / cooledDown / noChannels 不触碰退避戳。
/// - **不写** `lastSyncMs`（那是「完整跑成」的语义，键结构不动，与并行的按后端拆冷却
///   戳工作正交）；**不落盘**：app 重启后戳归零，「启动即同步」不受上一进程失败影响，
///   保持 TODO-1332 的跨启动重试语义。手动「立即同步」不经此闸（显式意图恒放行）。
int? _autoSweepFailureBackoffUntilMs;

/// BUG-1569① 测试观察点/复位（模块级状态在测试间必须可复位）。
@visibleForTesting
int? get autoSweepFailureBackoffUntilMsForTest =>
    _autoSweepFailureBackoffUntilMs;

@visibleForTesting
void resetAutoSweepFailureBackoffForTest() =>
    _autoSweepFailureBackoffUntilMs = null;

/// BUG-1569①：自动 sweep 是否处于失败退避窗内（生产与测试共用同一判据）。
@visibleForTesting
bool isAutoSweepBackedOff({required int nowMs}) {
  final int? until = _autoSweepFailureBackoffUntilMs;
  return until != null && nowMs < until;
}

/// BUG-1569①：按本轮结局推进/清除失败退避戳（生产与测试共用同一状态机）。
@visibleForTesting
void noteAutoSweepOutcomeForBackoff(
  SyncOutcomeReason reason, {
  required int nowMs,
}) {
  if (reason == SyncOutcomeReason.failed) {
    _autoSweepFailureBackoffUntilMs = nowMs + _syncCooldownMs;
  } else if (reason == SyncOutcomeReason.completed) {
    _autoSweepFailureBackoffUntilMs = null;
  }
}

/// BUG-1569③：整轮 sweep 进行中到达的 per-book 退出书同步请求记账（按
/// mediaIdentifier 去重，后到覆盖先到）。此前 [_runAutoSync] 撞上 `__all__` 直接
/// `return` 丢弃——sweep 那几十秒里退出书的进度就悄悄不同步，下一个触发点才补上。
/// 现在 sweep 收尾统一补跑（见 [_drainPendingBookSyncsAfterSweep]）。
final Map<String, ({FushiDatabase db, SyncReportCallback? onReport})>
    _pendingBookSyncsDuringSweep =
    <String, ({FushiDatabase db, SyncReportCallback? onReport})>{};

@visibleForTesting
int get pendingBookSyncCountForTest => _pendingBookSyncsDuringSweep.length;

/// BUG-1569③ 测试缝：模拟「整轮 sweep 进行中」。active=true 占住 `__all__`，
/// false 释放。仅测试可用——生产的 `__all__` 归 sweep 两条路径自己管。
@visibleForTesting
bool debugMarkSweepInProgress(bool active) =>
    active ? _syncingIds.add('__all__') : _syncingIds.remove('__all__');

/// BUG-1569③：sweep 收尾补跑期间记账的 per-book 同步（fire-and-forget，与
/// [triggerAutoSyncOnBackground] 同语义：messenger 为 null，冲突经 onReport 上浮）。
/// 快照后清账：补跑本身若又撞上新 sweep 会重新记账，不丢也不死循环。
@visibleForTesting
void drainPendingBookSyncsAfterSweep() {
  if (_pendingBookSyncsDuringSweep.isEmpty) return;
  final Map<String, ({FushiDatabase db, SyncReportCallback? onReport})>
      pending =
      Map<String, ({FushiDatabase db, SyncReportCallback? onReport})>.of(
          _pendingBookSyncsDuringSweep);
  _pendingBookSyncsDuringSweep.clear();
  for (final MapEntry<String,
          ({FushiDatabase db, SyncReportCallback? onReport})> entry
      in pending.entries) {
    unawaited(_runAutoSync(
      db: entry.value.db,
      mediaIdentifier: entry.key,
      messenger: null,
      onReport: entry.value.onReport,
    ));
  }
}

Future<void> _runAutoSyncAll({
  required FushiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncReportCallback? onReport,
  SyncPostRunCallback? onPostRun,
}) async {
  if (!_syncingIds.add('__all__')) return;

  _beginSyncActivity(const SyncActivity(SyncActivityKind.fullSweep));
  // 默认 failed：只有走到判定点才会被改写，异常路径原样留下「失败了」这个事实。
  SyncOutcomeReason reason = SyncOutcomeReason.failed;
  int channelsRun = 0;

  try {
    // HBK-AUDIT-049: serialize the actual sync work so it never overlaps a
    // per-book sync mutating the same singleton backend state.
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) {
        reason = SyncOutcomeReason.autoDisabled;
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      // BUG-1569①：成功冷却戳只在整轮跑成后写（TODO-1332），失败轮不推进它——
      // 只配互联且对端离线时，每分钟 tick 都会全额重付候选串行探测。失败退避戳
      // 补上「失败也要有节奏」这一半：退避窗内直接跳过，语义见戳的文档。
      // （成功冷却已按通道拆维度、移进下方通道循环内逐通道判，BUG-1580。）
      if (isAutoSweepBackedOff(nowMs: now)) {
        reason = SyncOutcomeReason.cooledDown;
        return;
      }

      // option B 双通道：依次跑云备份通道 + 互联通道（若启用），互不排斥。每条通道
      // 各自认证成功才实际跑；未配置的通道 no-op（_runSyncChannel 返回 null）。
      // BUG-1552：**逐通道**隔离异常。这个 for 原来整体裸奔——云通道（恒排第一，
      // 见 enabledSyncChannelBackends）令牌失效 / WebDAV 不可达时异常直接冒出循环，
      // 局域网互联通道这一轮**根本不执行**。UI 承诺的「互联与云备份并存、互不干扰」
      // 就此不成立：云盘一坏，互联跟着一起哑。一条通道炸了只该记它自己的账。
      bool anyChannelFailed = false;
      int cooledChannels = 0;
      for (final SyncChannel channel
          in await enabledSyncChannelBackends(repo)) {
        // BUG-1580：冷却窗**按通道**判。这个判断原本在循环外，读的是一份全局
        // lastSyncMs，而两条通道各自在自己整轮结束时都会写它——于是云通道刚跑完
        // 就把局域网互联通道一起压住 5 分钟；反过来，一条通道失败后想重试，也会被
        // 另一条通道的成功戳压死。冷却是「这条通道刚同步过」，不是设备的属性。
        final int? lastSync = await repo.getLastSyncMs(channel.scope);
        if (lastSync != null && (now - lastSync) < _syncCooldownMs) {
          cooledChannels++;
          continue;
        }
        try {
          final SyncRunReport? report = await _runSyncChannel(
            db: db,
            repo: repo,
            channel: channel,
            dictionaryResourceRoot: dictionaryResourceRoot,
            audioDatabaseRoot: audioDatabaseRoot,
            tempDir: tempDir,
            localAudioEntries: localAudioEntries,
            onLocalAudioImported: onLocalAudioImported,
            // Publish progress globally so a settings "立即同步" row visible
            // during the app-open sweep shows the live bar instead of a bare
            // toast.
            onProgress: (SyncProgress p) => syncProgress.value = p,
          );
          if (report == null) continue;
          channelsRun++;
          logSyncReportErrors(report);
          await onPostRun?.call(report);
          onReport?.call(report, channel.backend);
        } catch (e, stack) {
          // 记账不吞事实：这条通道失败了，其余通道继续跑，最终 reason 也据此如实
          // 报「失败」而不是伪装成 completed。
          anyChannelFailed = true;
          developer.log(
            'Sync channel failed (interconnect=${channel.isInterconnect})',
            error: e,
            stackTrace: stack,
            name: 'SyncAutoTrigger',
          );
        }
      }
      // 一条通道都没跑起来 = 本轮什么也没同步。以前这里静默收尾，界面上与「正常
      // 跑完」完全同形（进度条转一会儿消失），用户无从判断到底同没同步。
      if (anyChannelFailed) {
        reason = SyncOutcomeReason.failed;
      } else if (channelsRun > 0) {
        reason = SyncOutcomeReason.completed;
      } else {
        // 一条也没跑：区分「都还在冷却窗里」和「一条通道都没配置/没认证过」——
        // 前者是正常节流，后者是「什么也没同步」，UI 上必须能分开说。
        reason = cooledChannels > 0
            ? SyncOutcomeReason.cooledDown
            : SyncOutcomeReason.noChannels;
      }
    });
  } catch (e) {
    developer.log(
      'Auto-sync on app open failed',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove('__all__');
    final int finishedAt = DateTime.now().millisecondsSinceEpoch;
    // BUG-1569①：失败 → 推进退避戳；成功 → 清零。cooledDown/noChannels 不触碰。
    noteAutoSweepOutcomeForBackoff(reason, nowMs: finishedAt);
    _endSyncActivity(SyncRunOutcome(
      kind: SyncActivityKind.fullSweep,
      reason: reason,
      channelsRun: channelsRun,
      finishedAt: finishedAt,
    ));
    // BUG-1569③：sweep 期间被挡下的退出书同步在此补跑（去重后逐本）。
    drainPendingBookSyncsAfterSweep();
  }
}

/// 手动「立即同步」的结果。
enum ManualSyncOutcome { completed, notConfigured, busy }

/// 单条同步通道（云备份 or 互联）的报告 + 它自己的后端实例。手动同步冲突对话框按
/// 通道逐条呈现，用**各自的** backend 去 apply——否则合并报告的冲突可能来自互联
/// 通道却被云后端错误地 apply（option B 双通道）。
class ManualSyncChannelReport {
  const ManualSyncChannelReport(this.backend, this.report);
  final SyncBackend backend;
  final SyncRunReport report;
}

class ManualSyncResult {
  const ManualSyncResult(
    this.outcome, [
    this.report,
    this.channelReports = const <ManualSyncChannelReport>[],
  ]);
  final ManualSyncOutcome outcome;

  /// 合并所有通道后的汇总报告（用于「立即同步」结果 SnackBar 的计数摘要）。
  final SyncRunReport? report;

  /// 逐通道报告（用于把每条通道的冲突用其自身后端呈现/解决）。
  final List<ManualSyncChannelReport> channelReports;
}

/// 用户手点"立即同步"：跑完整双向全量同步（同 [triggerAutoSyncOnAppOpen]），
/// 但绕过自动同步开关与 5 分钟冷却（手动是显式意图）。仍尊重各资产 gate 与后端
/// 认证；与后台同步共用 [_autoSyncMutex]，避免并发改 singleton backend 状态。
Future<ManualSyncResult> runManualFullSync({
  required FushiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncPostRunCallback? onPostRun,
  SyncProgressCallback? onProgress,
}) async {
  if (!_syncingIds.add('__all__')) {
    return const ManualSyncResult(ManualSyncOutcome.busy);
  }
  _beginSyncActivity(const SyncActivity(SyncActivityKind.fullSweep));
  SyncOutcomeReason reason = SyncOutcomeReason.failed;
  int channelsRun = 0;
  try {
    return await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      // option B 双通道：云备份通道 + 互联通道（若启用），互不排斥。合并两条通道的
      // 报告成单一汇总返回；任一通道认证成功即算 completed，两条都未配置才是
      // notConfigured。
      final SyncRunReport merged = SyncRunReport();
      final List<ManualSyncChannelReport> channelReports =
          <ManualSyncChannelReport>[];
      // BUG-1573：手动路径也**逐通道**隔离。BUG-1552 只修了自动 sweep 那个循环；
      // 这里原来整体裸奔——云通道恒排第一（见 enabledSyncChannelBackends），它令牌
      // 失效 / WebDAV 不可达时异常直接冒出 runManualFullSync，于是 **已经跑完的通道**
      // 的 channelReports 连同它们的冲突/删除弹窗被整体丢弃，用户只看到一句「同步
      // 失败」。一条通道炸了只该记它自己的账。
      Object? firstError;
      StackTrace? firstStack;
      for (final SyncChannel channel
          in await enabledSyncChannelBackends(repo)) {
        try {
          final SyncRunReport? report = await _runSyncChannel(
            db: db,
            repo: repo,
            channel: channel,
            dictionaryResourceRoot: dictionaryResourceRoot,
            audioDatabaseRoot: audioDatabaseRoot,
            tempDir: tempDir,
            localAudioEntries: localAudioEntries,
            onLocalAudioImported: onLocalAudioImported,
            // Publish to the app-wide notifier in addition to the caller's
            // callback, so any other visible "立即同步" surface reflects the bar.
            onProgress: (SyncProgress p) {
              syncProgress.value = p;
              onProgress?.call(p);
            },
          );
          if (report == null) continue;
          channelsRun++;
          logSyncReportErrors(report);
          await onPostRun?.call(report);
          merged.mergeFrom(report);
          channelReports.add(ManualSyncChannelReport(channel.backend, report));
        } catch (e, stack) {
          // 不吞事实：这条通道的失败照样进汇总报告的 errors（鉴权类还会带类型进
          // authFailures，见 SyncRunReport.noteError），「立即同步」的结果提示因此
          // 仍会说「N 项失败」+ 可操作的鉴权原因。
          firstError ??= e;
          firstStack ??= stack;
          merged.noteError(
            'sync channel (interconnect=${channel.isInterconnect})',
            e,
          );
          developer.log(
            'Manual sync channel failed '
            '(interconnect=${channel.isInterconnect})',
            error: e,
            stackTrace: stack,
            name: 'SyncAutoTrigger',
          );
        }
      }
      if (channelReports.isEmpty) {
        // 一条都没跑成：把第一个异常原样抛回去，让 UI 层既有的
        // `on SyncAuthError` 分支照旧登出 + 提示重新登录（TODO-836 / BUG-1323）。
        // 这条路径上没有任何「已完成通道的结果」会因此丢失——本就一个都没有。
        if (firstError != null) {
          reason = SyncOutcomeReason.failed;
          Error.throwWithStackTrace(
              firstError, firstStack ?? StackTrace.current);
        }
        reason = SyncOutcomeReason.noChannels;
        return const ManualSyncResult(ManualSyncOutcome.notConfigured);
      }
      reason = firstError == null
          ? SyncOutcomeReason.completed
          : SyncOutcomeReason.failed;
      return ManualSyncResult(
        ManualSyncOutcome.completed,
        merged,
        channelReports,
      );
    });
  } finally {
    _syncingIds.remove('__all__');
    final int finishedAt = DateTime.now().millisecondsSinceEpoch;
    // BUG-1569①：手动同步不受退避闸约束（显式意图恒放行），但结局同样喂给退避
    // 状态机——跑成清零（对端被证实活着），失败推进（避免手动失败后紧跟的定时
    // tick 又立刻全额探测一遍）。
    noteAutoSweepOutcomeForBackoff(reason, nowMs: finishedAt);
    _endSyncActivity(SyncRunOutcome(
      kind: SyncActivityKind.fullSweep,
      reason: reason,
      channelsRun: channelsRun,
      finishedAt: finishedAt,
    ));
    // BUG-1569③：手动全量 sweep 期间被挡下的退出书同步同样在此补跑。
    drainPendingBookSyncsAfterSweep();
  }
}

Timer? _collectionsSyncDebounce;
StreamSubscription<void>? _collectionsWatchSub;
Duration _collectionsSyncDebounceDuration = const Duration(seconds: 8);

/// 装载「合集变更 → 防抖轻量同步」观察者（AppModel 初始化时调用一次；幂等，
/// 重复调用先撤旧订阅）。
///
/// 根因修复：合集维度只搭载在低频的全量 sweep 上（app 冷启动 + 5 分钟冷却，或
/// 手动「立即同步」），而用户高频触发的关书/切后台同步走单本路径、从不同步合集
/// ——增删合集/成员后长时间不推送，即「合集经常没同步」。现在任何合集表写入
/// （合集行/成员/墓碑，无论来自哪个页面）都会在 [debounce] 后跑一轮只含合集
/// 维度的轻量同步（[SyncOrchestrator.runCollectionsOnly]，云 + 互联双通道）。
///
/// 不成环：同步自身 apply 的写入会再触发一轮，但清单 canonicalJson 相等即不
/// 回写、目标态调和无 diff 即不写库——第二轮收敛为纯读 no-op 后不再有表事件。
void installCollectionsSyncWatcher({
  required FushiDatabase db,
  Duration debounce = const Duration(seconds: 8),
}) {
  uninstallCollectionsSyncWatcher();
  _collectionsSyncDebounceDuration = debounce;
  _collectionsWatchSub = db
      .tableUpdates(TableUpdateQuery.onAllTables([
        db.mediaCollections,
        db.mediaCollectionItems,
        db.collectionMemberTombstones,
      ]))
      .listen((_) => _scheduleCollectionsSync(db));
}

/// 撤销 [installCollectionsSyncWatcher] 的订阅与未决防抖定时器（测试 teardown /
/// DB 关闭前用；无观察者时 no-op）。
void uninstallCollectionsSyncWatcher() {
  _collectionsWatchSub?.cancel();
  _collectionsWatchSub = null;
  _collectionsSyncDebounce?.cancel();
  _collectionsSyncDebounce = null;
}

/// 测试观察点：观察者累计排定的防抖次数（仅测试断言「合集写入确实触发调度」用）。
@visibleForTesting
int collectionsSyncScheduledForTest = 0;

void _scheduleCollectionsSync(FushiDatabase db) {
  collectionsSyncScheduledForTest++;
  _collectionsSyncDebounce?.cancel();
  _collectionsSyncDebounce = Timer(_collectionsSyncDebounceDuration, () {
    _collectionsSyncDebounce = null;
    unawaited(_runCollectionsSync(db: db));
  });
}

/// 跑一轮只含合集维度的轻量同步（云备份 + 互联双通道，各自认证成功才跑）。
/// 全量 sweep 进行中则重排到下个防抖窗——sweep 本就带合集维度，且它 apply 的
/// 表写入还会再触发一次本观察者，最终收敛。
@visibleForTesting
Future<void> runCollectionsSyncNow({required FushiDatabase db}) =>
    _runCollectionsSync(db: db);

Future<void> _runCollectionsSync({required FushiDatabase db}) async {
  if (_syncingIds.contains('__all__')) {
    _scheduleCollectionsSync(db);
    return;
  }
  if (!_syncingIds.add('__collections__')) return;
  _beginSyncActivity(const SyncActivity(SyncActivityKind.collections));
  SyncOutcomeReason reason = SyncOutcomeReason.failed;
  int channelsRun = 0;
  try {
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) {
        reason = SyncOutcomeReason.autoDisabled;
        return;
      }
      // BUG-1604：**逐通道**隔离异常，与 app-open sweep 同一范式。这个 for 原来
      // 整体裸奔，只有外层一个 `catch (e) { developer.log(...) }`——云通道恒排第一
      // （见 enabledSyncChannelBackends），它的 `restoreAuth` 探测不到 WebDAV/FTP、
      // 或 `runCollectionsOnly` 抛裸 SocketException，异常直接终止整个 for，互联
      // 通道的合集同步这一轮**根本不执行**。合集是双端都在改的维度，漏跑一轮就是
      // 「我在手机上建的合集，桌面上一直不出现」。
      bool anyChannelFailed = false;
      for (final SyncChannel channel
          in await enabledSyncChannelBackends(repo)) {
        try {
          final SyncBackend backend = channel.backend;
          await backend.restoreAuth(repo);
          if (!await backend.isAuthenticated) continue;
          final SyncOrchestrator orchestrator = SyncOrchestrator(
            db: db,
            backend: backend,
            // 合集维度不触碰词典/音频/临时目录；systemTemp 仅为满足构造器形参，
            // runCollectionsOnly 保证不落任何文件。
            dictionaryResourceRoot: Directory.systemTemp,
            audioDatabaseRoot: Directory.systemTemp,
            tempDir: Directory.systemTemp,
            deviceId: await repo.getOrCreateDeviceId(),
            syncStats: false,
            syncFavorites: false,
            syncAudioBookPosition: false,
            syncContent: false,
            syncAudioBookFiles: false,
            syncVideoFiles: false,
            syncDictionary: false,
            syncLocalAudio: false,
            localAudioEntries: const <LocalAudioDbEntry>[],
            onLocalAudioImported: (LocalAudioPackageContents _) async {},
          );
          final SyncRunReport report = await orchestrator.runCollectionsOnly();
          channelsRun++;
          logSyncReportErrors(report);
        } catch (e, stack) {
          anyChannelFailed = true;
          developer.log(
            'Collections sync channel failed '
            '(interconnect=${channel.isInterconnect})',
            error: e,
            stackTrace: stack,
            name: 'SyncAutoTrigger',
          );
        }
      }
      // 部分失败如实报 failed，不伪装成 completed（与 sweep 同一记账口径）。
      if (anyChannelFailed) {
        reason = SyncOutcomeReason.failed;
      } else {
        reason = channelsRun > 0
            ? SyncOutcomeReason.completed
            : SyncOutcomeReason.noChannels;
      }
    });
  } catch (e) {
    developer.log(
      'Collections auto-sync failed',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove('__collections__');
    _endSyncActivity(SyncRunOutcome(
      kind: SyncActivityKind.collections,
      reason: reason,
      channelsRun: channelsRun,
      finishedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }
}

Future<void> _runAutoSync({
  required FushiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState? messenger,
  SyncReportCallback? onReport,
}) async {
  final String? bookKey = ReaderFushiSource.parseBookKey(mediaIdentifier);
  if (bookKey == null || !_bookKeyPattern.hasMatch(mediaIdentifier)) return;
  if (_syncingIds.contains('__all__')) {
    // BUG-1569③：整轮 sweep 进行中不再静默丢弃——记账，sweep 收尾统一补跑
    // （见 [drainPendingBookSyncsAfterSweep]）。此前直接 return，sweep 那几十秒里
    // 退出的书进度就悄悄不同步，且用户无从感知。
    _pendingBookSyncsDuringSweep[mediaIdentifier] =
        (db: db, onReport: onReport);
    return;
  }
  if (!_syncingIds.add(mediaIdentifier)) return;

  _beginSyncActivity(const SyncActivity(SyncActivityKind.singleBook));
  SyncOutcomeReason reason = SyncOutcomeReason.failed;
  int channelsRun = 0;

  try {
    // HBK-AUDIT-049: serialize against any other in-flight auto-sync (other
    // books or the '__all__' sweep) so the shared singleton backend's
    // token/api/folder cache is never mutated concurrently.
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) {
        reason = SyncOutcomeReason.autoDisabled;
        return;
      }

      final book = await db.getEpubBook(bookKey);
      if (book == null) {
        // 书没了（导入记录被删/清库）——本轮无对象可同步，与「跑完了」不是一回事。
        reason = SyncOutcomeReason.nothingToSync;
        return;
      }
      // 拿到书才有书名可显示；入口时只有 mediaIdentifier。
      syncActivity.value =
          const SyncActivity(SyncActivityKind.singleBook).withTitle(book.title);

      final syncStats = await repo.isSyncStatsEnabled();
      final syncAudioBook = await repo.isSyncAudioBookEnabled();
      final syncContent = await repo.isSyncContentEnabled();
      // BUG-988：互联通道的书内容上传读互联专属开关（默认关），云通道读共享开关——
      // 否则退出书时书内容仍会无视互联上传开关自动推给对端。
      final interconnectSyncContent =
          await repo.isInterconnectSyncContentEnabled();

      // option B 双通道：退出书时对每条启用的通道（云备份 + 互联）各跑一次 per-book
      // 同步，互不排斥。每条通道各自认证成功才跑；未配置的通道 continue 跳过。
      //
      // BUG-1604：**逐通道**隔离异常，与 app-open sweep 同一范式。这个 for 原来也是
      // 整体裸奔（只有外层一个 catch）——云通道的 `restoreAuth` / `syncBook` 一抛，
      // 互联通道的书进度与内容推送整轮被跳过。退出书是「读到哪」最主要的写入时机，
      // 漏跑一轮就是对端续读位置停在旧处，而失败原因指向云盘，用户不会想到互联被连累。
      bool anyChannelFailed = false;
      for (final SyncChannel channel
          in await enabledSyncChannelBackends(repo)) {
        final SyncBackend backend = channel.backend;
        try {
          await backend.restoreAuth(repo);
          if (!await backend.isAuthenticated) continue;

          final manager = SyncManager(db: db, backend: backend);
          final result = await manager.syncBook(
            book: book,
            syncStats: syncStats,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: syncAudioBook,
            syncContent:
                channel.isInterconnect ? interconnectSyncContent : syncContent,
          );
          // 计数放在 syncBook **之后**：抛异常的通道不算「跑过」，否则
          // channelsRun>0 会把一条都没成功的轮次记成 completed（与 sweep 一致）。
          channelsRun++;

          // TODO-132 诉求B：退出书同步静默——不再弹 imported/exported「同步成功」
          // SnackBar（打断用户、让用户误以为「必须等同步成功条才能离开」=卡手）。
          // 同步是 fire-and-forget 后台动作，成功无需打断式提示；真正需要用户介入的
          // **冲突**仍经下方 onReport → presentAutoConflicts 弹对话框（不是 SnackBar）。
          // messenger 参数保留（签名兼容，背景/app-open 路径本就传 null）。

          // Surface a genuine fork to the caller as a one-conflict report so the
          // book-exit flow can prompt resolution. The single-book path runs
          // SyncManager.syncBook (not the orchestrator), so build the report here
          // from the conflict fields SyncManager fills on SyncResult.conflict.
          if (onReport != null) {
            final SyncRunReport report = SyncRunReport();
            if (result.direction == SyncResult.conflict) {
              report.conflicts.add(SyncConflict(
                assetKey: result.conflictAssetKey!,
                dimension: result.conflictDimension!,
                title: result.title,
                localVersion: result.conflictLocalVersion,
                remoteVersion: result.conflictRemoteVersion,
              ));
            }
            onReport(report, backend);
          }
        } catch (e, stack) {
          anyChannelFailed = true;
          developer.log(
            'Book-exit sync channel failed '
            '(interconnect=${channel.isInterconnect})',
            error: e,
            stackTrace: stack,
            name: 'SyncAutoTrigger',
          );
        }
      }
      if (anyChannelFailed) {
        reason = SyncOutcomeReason.failed;
      } else {
        reason = channelsRun > 0
            ? SyncOutcomeReason.completed
            : SyncOutcomeReason.noChannels;
      }
    });
  } catch (e) {
    developer.log(
      'Auto-sync failed for $mediaIdentifier',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove(mediaIdentifier);
    _endSyncActivity(SyncRunOutcome(
      kind: SyncActivityKind.singleBook,
      reason: reason,
      channelsRun: channelsRun,
      finishedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }
}
