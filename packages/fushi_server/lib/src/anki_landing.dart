/// 无头服务端当 Anki 落地设备：手机经互联同步把待发卡写进本机目录，这里收下、
/// 用本机的 Anki 配置渲染、写进本地 collection，再同步到 AnkiWeb / 自建 Anki 同步服务器。
///
/// 协议、落地、渲染、同步全部是 fushi_engine 里与 app 共用的那一份
/// （[AnkiBoxLanding] / [AnkiSyncMiner] / [AnkiSyncSession]），这里只有装配、
/// 设置持久化（服务端偏好表）与定时器。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/anki_sync/anki_box_landing.dart';
import 'package:fushi_engine/anki_sync/anki_sync_miner.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_locator.dart';
import 'package:fushi_engine/anki_sync/pending_mine_store.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;

class ServerAnkiLanding {
  ServerAnkiLanding({
    required this.prefs,
    required FushiDatabase db,
    required Directory support,
    required Directory syncData,
    required this.deviceId,
    required this.deviceName,
    AnkiSyncSession? session,
    bool resolveHelper = true,
    Duration interval = const Duration(seconds: 30),
    int Function()? clock,
  }) : _interval = interval,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       session = session ?? (resolveHelper ? _defaultSession(support) : null),
       store = PendingMineStore.inSupportDir(() => db, () async => support) {
    final AnkiSyncSession? s = this.session;
    _miner = s == null ? null : AnkiSyncMiner(s);
    _landing = AnkiBoxLanding(
      // FushiSyncServer 把 WebDAV 根放在 `<syncData>/sync-data`，客户端的同步根是
      // 其下的 `fushi-data`（kSyncRootFolderName）。
      syncRoot: Directory(p.join(syncData.path, 'sync-data', 'fushi-data')),
      store: store,
      deviceId: deviceId,
      deviceName: deviceName,
      landingClaimedAt: () => landingClaimedAt,
      mine: _mine,
      clock: _clock,
    );
  }

  /// Anki 设置（牌组 / 笔记类型 / 字段映射 / 标签）的偏好键，值是 [AnkiSettings] JSON。
  static const String settingsKey = 'server_anki_settings';

  /// 「本机当落地设备」打开的时刻（毫秒）；0 = 关。与 app 的
  /// `sync_pending_mine_landing_claimed_at` 同义。
  static const String landingKey = 'server_anki_landing_claimed_at';

  final ServerPrefs prefs;
  final String deviceId;
  final String deviceName;

  /// null = 本机没带 `fushi-anki-sync`。
  final AnkiSyncSession? session;
  final PendingMineStore store;
  final Duration _interval;
  final int Function() _clock;
  late final AnkiSyncMiner? _miner;
  late final AnkiBoxLanding _landing;

  Timer? _timer;
  bool _stopped = false;
  AnkiBoxLandingReport? lastReport;
  int? lastRunAt;
  String? lastError;

  bool get available => session != null;

  static AnkiSyncSession? _defaultSession(Directory support) {
    final String? exe = resolveFushiAnkiSyncExecutable();
    if (exe == null) return null;
    return AnkiSyncSession(
      root: () async => Directory(p.join(support.path, 'anki_sync')),
      startClient: () => FushiAnkiSyncClient.start(exe),
    );
  }

  int get landingClaimedAt {
    final Object? v = prefs.getPref(landingKey, defaultValue: 0);
    return v is int ? v : 0;
  }

  bool get landingEnabled => landingClaimedAt > 0;

  AnkiSettings get settings {
    final Object? raw = prefs.getPref(settingsKey, defaultValue: '');
    if (raw is! String || raw.isEmpty) return const AnkiSettings();
    try {
      return AnkiSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on FormatException {
      return const AnkiSettings();
    }
  }

  Future<void> saveSettings(AnkiSettings next) =>
      prefs.setPref(settingsKey, jsonEncode(next.toJson()));

  /// 起定时器（落地开着才真跑）。
  void start() {
    _stopped = false;
    // 上次退出前没同步完的卡还在会话日志里：开机补一次（没登录时在读账号那步就停）。
    session?.scheduleSync();
    _schedule(Duration.zero);
  }

  /// 停机：停定时器，先关会话（立即结束 helper，在跑的同步随之失败、什么都不出日志；
  /// 关闭后的会话不会再拉起 helper），再等在跑的那一轮收尾——不被几 GB 的媒体同步拖住，
  /// 也不会在数据库关闭后还去碰它。
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await session?.close();
    await _landing.idle;
  }

  void _schedule(Duration delay) {
    if (_stopped) return;
    _timer?.cancel();
    _timer = Timer(delay, () async {
      if (_stopped) return;
      if (landingEnabled) await runNow();
      _schedule(_interval);
    });
  }

  /// 立刻跑一轮落地（收卡 → 写进 Anki → 写回执），之后排一次同步。
  Future<AnkiBoxLandingReport?> runNow() async {
    if (_stopped || !landingEnabled) return null;
    try {
      final AnkiBoxLandingReport r = await _landing.runOnce();
      lastReport = r;
      lastRunAt = _clock();
      lastError = r.errors.isEmpty ? null : r.errors.join('\n');
      if (r.delivered > 0 || r.received > 0) {
        engineLog.logDiagnostic(
          'AnkiLanding',
          'received ${r.received}, delivered ${r.delivered}, '
              'failed ${r.failed}, waiting ${r.waiting}',
        );
      }
      return r;
    } catch (e, stack) {
      lastError = '$e';
      engineLog.log('AnkiLanding.runNow', e, stack);
      return null;
    }
  }

  /// 打开 / 关闭「本机当落地设备」。关的时候立刻撤认领，别的设备不再往这里传。
  Future<void> setLandingEnabled(bool enabled) async {
    await prefs.setPref(landingKey, enabled ? _clock() : 0);
    if (enabled) {
      unawaited(runNow());
    } else {
      await _landing.revokeClaim();
    }
  }

  /// 用本地库里的牌组 / 笔记类型刷新设置（登录后调一次）。
  Future<bool> refreshMeta() async {
    final AnkiSyncSession? s = session;
    final AnkiSyncMiner? miner = _miner;
    if (s == null || miner == null) return false;
    final AnkiSettings? next = miner.applyMeta(settings, await s.meta());
    if (next == null) return false;
    await saveSettings(next);
    return true;
  }

  /// 失败的卡改回待发，下一轮再落。
  Future<int> retryFailed() async {
    int n = 0;
    for (final PendingMineRow row in await store.all()) {
      if (row.status == PendingMineStatus.failed) {
        await store.retry(row.id);
        n++;
      }
    }
    if (n > 0) unawaited(runNow());
    return n;
  }

  /// 本机的同步客户端制卡器（null = 没带 `fushi-anki-sync`）。互联制卡的查重读它。
  AnkiSyncMiner? get miner => _miner;

  /// 直接落一张卡（互联对端经 `/api/mine*` 发来的制卡请求）：与落地队列同一条渲染 /
  /// 查重 / 写库链路、同一份服务端 Anki 设置，只是不经待发队列。
  Future<MineOutcome> mineCard(String rawPayloadJson, AnkiMiningContext context) =>
      _mine(rawPayloadJson, context);

  Future<MineOutcome> _mine(String raw, AnkiMiningContext context) async {
    final AnkiSyncMiner? miner = _miner;
    if (miner == null) {
      return MineOutcome.failure(
        'fushi-anki-sync is not bundled with this server.',
        errorCode: AnkiErrorCode.syncClientUnavailable,
      );
    }
    final AnkiSettings current = settings;
    // 所选笔记类型的字段一个都没映射（刚登录、或刚换了笔记类型而旧映射的字段名对不上）：
    // 卡一张都渲染不出来。算「没配置」（留着等配置），不算失败。
    final AnkiNoteType? noteType = miner.selectedNoteType(current);
    if (noteType == null ||
        noteType.fields.every(
          (String f) => (current.fieldMappings[f] ?? '').trim().isEmpty,
        )) {
      return const MineOutcome.notConfigured();
    }
    final MineOutcome outcome = await miner.mine(
      settings: current,
      rawPayloadJson: raw,
      context: context,
    );
    // 停机把 helper 关了：这张卡没落下去不是它的错，退回待发、下次开机再落。
    return _stopped && outcome.result == MineResult.error
        ? const MineOutcome.queued()
        : outcome;
  }
}
