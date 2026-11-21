/// 服务端的复习库（docs/specs/2026-11-05-server-srs-design.md）：服务端当一台复习设备。
///
/// - 提供管理员勾选的几份 profile（一门语言一份常见），每份一个 [SrsDbStore]，共用一个 `<support>/srs.db`；
/// - 每份在本机的互联同步目录（`<sync-data>/fushi-data/fushi-srs/<uid>/`，就是已配对设备写进来的那块）上同步：
///   别的设备的改动收进来，服务端自己的写入（远程复习 / AnkiConnect / 互联制卡）发出去；
/// - 远程复习（`/api/srs/remote/*`）按客户端点名的 profile 走（[remoteStore]）；
/// - 位置开了端到端加密的 profile 在 v1 里不提供（服务端读不了），别的 profile 不受影响。
///
/// 复习库换代（协议 3 `srs.db` → 新代 `srs4.db`，G10-3，交接说明「G10-3」一节）：`<support>` 是**一个**库目录，
/// 所有 profile 共用；迁移以目录为单位（内核 `gen4_migrate_*`），一次把旧库里全部 profile 迁过去。打开前先按
/// `gen4_migrate_status` 判定：要迁移就无头迁移（后台 isolate，进度进日志与 [ServerSrs.generation]）；迁移中与各种
/// 没迁完的状态下，对复习的请求回类型化的「升级中」/「升级受阻」（[ServerSrsUpgradeRefusal]），不 500、不挂起。
/// 失败类状态（对拍不过、只剩封存旧库、新库旁有没迁移的旧库、迁移被拦下）不自动重跑、不删任何文件，等管理员处置
/// （[ServerSrsGeneration.advice]、`ctl srs migration`）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_devices.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_attach.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 已配对设备写进来之后，等这么久没有新写入再跑一轮（一轮客户端同步连写好几个文件，并成一次）。
const Duration kServerSrsWriteDebounce = Duration(seconds: 3);

/// 管理员给 profile 起的名字最长几个字符（[ServerSrsConfig.profileNames]；会发布到同步位置给别的设备看）。
const int kServerSrsProfileNameMax = 100;

/// [name] 能不能当 profile 的显示名发布出去：不超过 [kServerSrsProfileNameMax] 个字符、不含控制字符。管理员起的名字
/// （admin API 写入时拒收）与别的设备在同步位置里报的名字（外来输入，[ServerSrs] 取名时跳过不合格的）同一个口径。
bool serverSrsProfileNameOk(String name) =>
    name.length <= kServerSrsProfileNameMax &&
    !name.runes.any((int c) => c < 0x20 || c == 0x7f);

/// 同一集合里别的设备在说明文件里报的名字（[nameOf]：写入者 → 名字）里挑哪一个当服务端那份 profile 的名字；没有可用的
/// 返回 null。跳过 [own]（服务端自己上次发布的那份）与不合格的（[serverSrsProfileNameOk]，外来输入）；剩下的取说明文件
/// 最近一次改动过的（[nameAtOf]，没有时刻的排最后），一样新时取写入者名按 UTF-16 码元序（[String.compareTo]）最小的。
///
/// 说明文件不只在改名时重写：设备的笔记数、设备名、并入标记一变也重写（app 端 `SrsProfileLinker.publish` 按签名比较）。
/// 所以几台设备报的名字不一样时，取的是最近有活动的那台设备的名字，名字会随设备活动来回切；改名的那台设备在改名时
/// 必然重写说明文件，所以改名后（别的设备再有活动之前）取到的是新名字。规则对给定数据是确定的。
///
/// 规则只看内容，不看 [nameOf] 的键顺序——那是后端的目录列举顺序，本地目录在 Linux / macOS 上是哈希序，按顺序取
/// 第一个时同一份数据在不同机器上会取出不同的名字。
String? serverSrsPickReportedName(
  Map<String, String> nameOf,
  Map<String, int> nameAtOf, {
  required String? own,
}) {
  String? bestWriter;
  int bestAt = -1;
  for (final MapEntry<String, String> e in nameOf.entries) {
    if (e.key == own || !serverSrsProfileNameOk(e.value)) continue;
    final int at = nameAtOf[e.key] ?? -1;
    if (bestWriter == null ||
        at > bestAt ||
        (at == bestAt && e.key.compareTo(bestWriter) < 0)) {
      bestWriter = e.key;
      bestAt = at;
    }
  }
  return bestWriter == null ? null : nameOf[bestWriter];
}

/// 兜底：没有任何触发时也每隔这么久同步一轮。
const Duration kServerSrsSafetyInterval = Duration(minutes: 30);

/// 完整媒体对账的最短间隔（内容没变时）。
const Duration kServerSrsMediaReconcileInterval = Duration(minutes: 30);

/// 一份 profile 此刻的状态（WebUI / admin API / ctl 显示）。
enum ServerSrsProfileState {
  /// 正在打开。
  opening('opening'),

  /// 可用：远程复习 / AnkiConnect / 制卡都走它。
  ready('ready'),

  /// 同步位置开了端到端加密：v1 不支持，这份 profile 不提供（所有者 2026-11-06）。
  encrypted('encrypted'),

  /// 同步数据来自更新版本的 Fushi：先升级服务端。
  needsUpgrade('needs_upgrade'),

  /// 打开失败（见 lastError）。
  failed('failed'),

  /// 复习库正在升级到新代（本进程在迁移 / 别的进程拿着换代锁）：完成前不提供，请求回「升级中」。
  upgrading('upgrading'),

  /// 复习库没升级完、要管理员处理（[ServerSrs.generation] 的状态与处置说明）：不提供，请求回「升级受阻」。
  upgradeBlocked('upgrade_blocked');

  const ServerSrsProfileState(this.wire);

  final String wire;
}

/// 两次迁移进度轮询之间的间隔（`gen4_migrate_status` 只看文件与锁，很快）。
const Duration kServerSrsMigrationPollInterval = Duration(seconds: 1);

/// 「等一会再来」类结论（旧库正被写 / 别的进程拿着换代锁）之后，隔这么久自动再判定一次（[ServerSrs] 单独挂一个一次性
/// 定时器，不等 30 分钟的兜底定时器）。
const Duration kServerSrsMigrationRetryDelay = Duration(minutes: 1);

/// 服务端复习库目录（`<support>`）的代际状态。
enum ServerSrsGenState {
  /// 新代库开着；或复习关着 / 还没判定过。
  ready('ready'),

  /// 本进程正在迁移（无头，后台 isolate）。
  migrating('migrating'),

  /// 别的进程拿着换代锁（同一个数据目录上还开着别的服务端 / app）：兜底定时器下次再看。
  migratingElsewhere('migrating_elsewhere'),

  /// 有协议 3 的旧库要迁移、没在跑：管理员取消了，或这一次的结论不该自动重跑（见 [ServerSrsGeneration.code]）。
  needsMigration('needs_migration'),

  /// 上一次迁移对拍不过（报告在 [ServerSrsGeneration.reportPath]），或只剩迁移临时文件：不自动重跑。
  migrationFailed('migration_failed'),

  /// 只剩封存的旧库、新代库不见了：迁移不了、也不建空库顶上。
  sealedOldOnly('sealed_old_only'),

  /// 新代库旁边有一份没迁移的协议 3 库：两份都没动，新代库也没开。
  legacyBesideNew('legacy_beside_new'),

  /// 迁移没开始，内核拦下（[ServerSrsGeneration.code] 是 migrate.rs `BlockCode` 的线上名）。
  blocked('blocked'),

  /// 卷上空间不够（[ServerSrsGeneration.neededBytes] / [ServerSrsGeneration.freeBytes]）。
  noSpace('no_space'),

  /// 迁移命令报错（内核异常，见 [ServerSrsGeneration.reason]）。
  error('error');

  const ServerSrsGenState(this.wire);

  final String wire;
}

/// 代际原因让复习不可用时，对复习请求的类型化回答（admin API / ctl / 远程复习一致，HTTP 503）。
enum ServerSrsUpgradeRefusal {
  /// 正在升级（迁移中 / 别的进程在迁移 / 等一会会自动再试）：完成后自动恢复。
  upgrading('srs_upgrading', SrsRemoteStoreError.migrating),

  /// 升级没完成、要在服务端上处理（见 `ctl srs migration`）：客户端重试没有用。
  blocked('srs_upgrade_blocked', SrsRemoteStoreError.migrationFailed);

  const ServerSrsUpgradeRefusal(this.reason, this.remoteCode);

  /// admin API / ctl 错误体里的 `reason`。
  final String reason;

  /// 远程复习的错误码（[SrsRemoteStoreError]，客户端按它出文案）。
  final String remoteCode;

  /// HTTP 状态（服务暂不可用；不是 500）。
  int get status => 503;
}

/// [ServerSrs] 目录的代际状态快照（不可变；admin API `generation` 段、`ctl srs migration`）。
final class ServerSrsGeneration {
  const ServerSrsGeneration({
    required this.state,
    this.code,
    this.reason,
    this.step,
    this.done = 0,
    this.total = 0,
    this.reportPath,
    this.neededBytes,
    this.freeBytes,
    this.verdict,
    this.cancelRequested = false,
    this.startedAt,
    this.finishedAt,
  });

  static const ServerSrsGeneration initial = ServerSrsGeneration(
    state: ServerSrsGenState.ready,
  );

  final ServerSrsGenState state;

  /// [ServerSrsGenState.blocked] 等由迁移结论得出的状态：内核 `code`（migrate.rs `BlockCode::wire`）。
  final String? code;

  /// 内核原因原文（给人看）。
  final String? reason;

  /// 迁移中：当前步骤（还没轮询到 = null）。
  final SrsGen4MigrationStep? step;
  final int done;
  final int total;

  /// 对拍不过时的诊断报告路径（只含 ID 与计数）。
  final String? reportPath;
  final int? neededBytes;
  final int? freeBytes;

  /// 本进程最近一次迁移的结论（[SrsGen4MigrationVerdict.wire]；没跑过 = null）。
  final String? verdict;

  /// 已请求取消、还没有结论。
  final bool cancelRequested;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// 下一次判定时可以自动（再）开始迁移：只有「等一会再来」的几类（别的进程在迁移、旧库正被写）与就绪。其余结论
  /// 重跑不会变，或要管理员处理，不自动重跑。
  bool get autoRetry => switch (state) {
    ServerSrsGenState.ready || ServerSrsGenState.migratingElsewhere => true,
    ServerSrsGenState.blocked => code == 'busy',
    _ => false,
  };

  /// 这一刻对复习请求的回答（就绪 = null）。
  ServerSrsUpgradeRefusal? get refusal => switch (state) {
    ServerSrsGenState.ready => null,
    ServerSrsGenState.migrating ||
    ServerSrsGenState.migratingElsewhere => ServerSrsUpgradeRefusal.upgrading,
    _ when autoRetry => ServerSrsUpgradeRefusal.upgrading,
    _ => ServerSrsUpgradeRefusal.blocked,
  };

  /// 给管理员的处置说明（英文，与 admin API 其余错误文本同一种语言）。
  String get advice => switch (state) {
    ServerSrsGenState.ready =>
      'The review library is on the current generation.',
    ServerSrsGenState.migrating =>
      'Upgrading the review library (protocol 3 srs.db -> srs4.db). Review is unavailable until it finishes; '
          'it can be cancelled before the commit step with `ctl srs migration cancel`.',
    ServerSrsGenState.migratingElsewhere =>
      'Another process holds the generation lock of this data directory (another fushi_server or Fushi app '
          'using the same directory is upgrading it). The server checks again on its next pass.',
    ServerSrsGenState.needsMigration =>
      'The protocol 3 review library has not been upgraded yet (the last run was cancelled or stopped). '
          'Start it with `ctl srs migration start`. srs.db is untouched.',
    ServerSrsGenState.migrationFailed =>
      'The last upgrade did not pass the parity check and was rolled back; srs.db is untouched. '
          'It is not retried automatically. Keep the report${reportPath == null ? '' : ' ($reportPath)'} '
          'and the server log for support; `ctl srs migration start` runs it again.',
    ServerSrsGenState.sealedOldOnly =>
      'Only the sealed protocol 3 library is left and srs4.db is missing. Nothing is rebuilt automatically '
          'and no file was deleted: restore srs4.db from a backup of this data directory, or contact '
          'support with the server log. Do not delete srs.db.',
    ServerSrsGenState.legacyBesideNew =>
      'srs4.db exists next to a protocol 3 srs.db that was never migrated. Neither file was changed. '
          'Move one of them out of the data directory after checking which one holds your reviews, or '
          'contact support with the server log.',
    ServerSrsGenState.blocked => switch (code) {
      'busy' =>
        'srs.db is being written by another process; the server tries again on its next pass.',
      'schemaNewer' =>
        'srs.db was written by a newer Fushi version; update fushi_server and restart it.',
      'corrupt' || 'notProtocol3' =>
        'srs.db is damaged or is not a review library. It was left as is; contact support with the server log.',
      'mergeHalfDone' =>
        'A profile merge in srs.db is half done; finish it in the Fushi app version that started it, then '
            'run `ctl srs migration start`.',
      // 交接说明 §9 / §11：前提补完之后核对仍不过 = 这一版升级不了，重跑只会得到同一个结论，不引导重试。
      'precondition' =>
        'This fushi_server version cannot upgrade this review library yet (see the reason). srs.db is untouched. '
            'Running the upgrade again gives the same result: update fushi_server, or contact support with the '
            'reason and the server log.',
      'missingCacheConfig' =>
        'The upgrade needs the settings of a profile that is in srs.db but was not handed to it (see the reason '
            'for the profile). srs.db is untouched. Look in the server log for an error while listing the '
            'profiles of srs.db: if there is one, fix it (disk / permissions) and run `ctl srs migration start`; '
            'if there is none, update fushi_server or contact support with the server log.',
      'noLibrary' =>
        'srs.db was no longer in the data directory when the upgrade started (moved or removed meanwhile). '
            'Nothing was changed. If it was moved by mistake, put it back before the next pass of the server '
            '(otherwise the server starts a new, empty review library and the old file is then reported as '
            'a library that was never upgraded).',
      _ =>
        'The upgrade could not start (${code ?? 'unknown'}) and this server does not know that reason. '
            'srs.db is untouched. Update fushi_server, or contact support with the reason and the server log.',
    },
    ServerSrsGenState.noSpace =>
      'Not enough free disk space to upgrade the review library'
          '${neededBytes == null ? '' : ' (needs $neededBytes bytes, ${freeBytes ?? 0} free)'}. '
          'Free some space, then run `ctl srs migration start`.',
    ServerSrsGenState.error =>
      'The upgrade failed with an error (see reason and the server log). srs.db is untouched before the '
          'commit step; `ctl srs migration start` runs it again.',
  };

  ServerSrsGeneration _progress(SrsGen4MigrationProgress p) =>
      ServerSrsGeneration(
        state: state,
        code: code,
        reason: reason,
        step: p.step,
        done: p.done,
        total: p.total,
        verdict: verdict,
        cancelRequested: cancelRequested,
        startedAt: startedAt,
      );

  ServerSrsGeneration _cancelling() => ServerSrsGeneration(
    state: state,
    step: step,
    done: done,
    total: total,
    verdict: verdict,
    cancelRequested: true,
    startedAt: startedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.wire,
    'code': ?code,
    'reason': ?reason,
    if (step != null) ...<String, Object?>{
      'step': step!.wire,
      'done': done,
      'total': total,
      'cancellable': step!.cancellable && !cancelRequested,
    },
    'reportPath': ?reportPath,
    'needed': ?neededBytes,
    'free': ?freeBytes,
    'verdict': ?verdict,
    if (cancelRequested) 'cancelRequested': true,
    'startedAt': ?startedAt?.toUtc().toIso8601String(),
    'finishedAt': ?finishedAt?.toUtc().toIso8601String(),
    'autoRetry': autoRetry,
    'advice': advice,
  };
}

/// 服务端提供的一份 profile。
class ServerSrsProfile {
  ServerSrsProfile._(this.uid, this._owner);

  final String uid;
  final ServerSrs _owner;

  SrsDbStore? _store;
  SrsMediaStore? _media;

  /// 这份库的 RWKV 排程服务：库一打开就挂上（[ServerSrs._reconcile]），与 app 同一份装配（srs_rwkv_attach.dart）。
  /// RWKV 牌组在服务端与在 app 上同一个出卡口径：按 RWKV 回忆率出，没就绪（权重没下到 / 正在回放 / 出错）就不出
  /// 复习卡，不退回按 FSRS-7 存下的到期日。
  SrsRwkvService? _rwkv;
  bool _rwkvStarted = false;
  ServerSrsProfileState state = ServerSrsProfileState.opening;
  String? lastError;
  DateTime? lastSyncAt;
  DateTime? _mediaReconciledAt;
  String? _mediaReconciledContent;

  /// 这份 profile 的显示名（WebUI、远程复习的选择列表、服务端发布的说明文件）：管理员起的名字，没有时取别的
  /// 设备在同步位置里报的，再没有取服务端自己上次发布的（[ServerSrs._resolveName]）；都没有时空。
  String name = '';

  /// 上次发布的说明文件内容签名（进程内）：没变不重写。
  String? _publishedInfo;

  /// 用户笔记数。库打开前是同步位置里各设备报的最大值（只是个估计，设备报的是它上次发布时的数）；
  /// 库打开后每轮同步成功都按这份库重数（服务端自己写库、设备写入都会触发一轮），WebUI / 远程复习的
  /// 选择列表不会停在打开时的旧数上（BUG-4286）。
  int noteCount = 0;

  Timer? _debounce;
  Future<void>? _running;
  bool _again = false;
  bool _closed = false;

  /// 可用时的库；加密 / 失败 / 打开中为 null（各入口据此报不可用）。
  SrsDbStore? get store => state == ServerSrsProfileState.ready ? _store : null;
  SrsMediaStore? get media =>
      state == ServerSrsProfileState.ready ? _media : null;

  /// 这份库的 RWKV 准备状态（WebUI / admin API 显示；库没打开时 null）。
  SrsRwkvStatus? get rwkvStatus => _rwkv?.status;

  /// 库里有 RWKV 牌组就开始准备 RWKV（下载权重 / 恢复快照 / 全量回放），一轮同步成功后调：第一轮之前库是空的，
  /// 不知道有没有 RWKV 牌组。没有 RWKV 牌组时不启动，之后每轮再看一次（客户端可能刚把牌组改成 RWKV）。
  Future<void> _startRwkvIfUsed(SrsDbStore s) async {
    final SrsRwkvService? rwkv = _rwkv;
    if (rwkv == null || _rwkvStarted || _closed) return;
    _rwkvStarted = await srsRwkvStartIfUsed(
      s,
      rwkv,
      onError: (Object e, StackTrace stack) =>
          engineLog.log('ServerSrs.rwkv', e, stack),
    );
  }

  /// 在用的 RWKV 服务换成 [size] 档的（设置文件里的档位与在用的不同：WebUI / admin API / ctl 改了，或手改了
  /// `<support>/srs_rwkv/model_size`）。旧服务先关（存快照、停在途下载），再挂新档位的；库已对外提供就马上开始
  /// 准备（有 RWKV 牌组时）。排在同步轮次之间（[ServerSrs._rounds]）：一轮的中途不换。
  Future<void> _switchRwkv(SrsRwkvModelSize size) async {
    final SrsRwkvService? old = _rwkv;
    final SrsDbStore? s = _store;
    if (old == null || s == null || _closed || old.models.size == size) return;
    await _owner._rounds.run(() async {
      if (_closed || !identical(_rwkv, old)) return;
      try {
        await old.close();
      } catch (e, stack) {
        engineLog.log('ServerSrs.rwkv', e, stack);
      }
      _rwkv = _owner._attachRwkv(s, size);
      _rwkvStarted = false;
      if (state == ServerSrsProfileState.ready) await _startRwkvIfUsed(s);
    });
    _owner._onChanged(uid);
  }

  /// 去抖后跑一轮（已配对设备写了文件 / 服务端自己写了库）。
  void scheduleSync({Duration delay = kServerSrsWriteDebounce}) {
    if (_closed) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(syncNow()));
  }

  /// 立刻跑一轮；在跑时排一轮，跑完再来一次（多次请求合成一次）。
  Future<void> syncNow() {
    if (_closed) return Future<void>.value();
    final Future<void>? running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final Future<void> f = _loop();
    _running = f;
    return f.whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      // 内核的收段会话是一条连接一个（native/fushi_fsrs/src/store/sync2/transport.rs `IngestPhase`）：同一个 srs.db
      // 上另一份 profile 开会话会把这份的顶掉（「no ingest session for this profile」）。各份的轮次排成一队。
      await _owner._rounds.run(_round);
    } while (_again && !_closed);
  }

  Future<void> _round() async {
    final SrsDbStore? s = _store;
    if (s == null || _closed) return;
    final LocalDirectoryAssetStore assets = LocalDirectoryAssetStore(
      _owner.syncRoot,
    );
    final SrsLocationBackend backend = SrsLocationBackend(assets);
    final String key = _owner.directoryKey;
    try {
      final SrsSync2Report r = await srsRunLocationRound(
        backend,
        s,
        key,
        publishDeviceInfo: _owner._publishDeviceInfo,
        beforeUpload: (String? keyHex) => _media == null
            ? Future<void>.value()
            : srsRunLocationMedia(
                backend,
                s,
                _media!.root,
                locationId: key,
                uploadOnly: true,
              ).then((_) {}),
        shouldStop: () => _closed || s.isWindingDown,
      );
      lastSyncAt = DateTime.now();
      final String? error = r.error;
      if (error == kSrsSyncNeedsUpgrade) {
        _setState(ServerSrsProfileState.needsUpgrade, error);
        return;
      }
      if (error != null && kServerSrsCryptoErrors.contains(error)) {
        _setState(
          ServerSrsProfileState.encrypted,
          'sync location is end-to-end encrypted; not supported by fushi_server yet',
        );
        return;
      }
      if (error != null && error != kSrsSync2Stopped) {
        lastError = error;
        engineLog.log('ServerSrs.sync', StateError('profile $uid: $error'));
        return;
      }
      if (error == null) {
        lastError = null;
        noteCount = await s.userNoteCount();
        await _publishInfo(assets, s);
        await _startRwkvIfUsed(s);
        if (state != ServerSrsProfileState.ready) {
          _setState(ServerSrsProfileState.ready, null);
        }
        await _reconcileMedia(backend, s, key, r);
        if (r.uploaded > 0 || r.relayed > 0) _owner._onPublished();
        if (r.changed || r.applied > 0 || r.fork) _owner._onChanged(uid);
      }
    } catch (e, stack) {
      lastError = '$e';
      engineLog.log('ServerSrs.sync', e, stack);
    }
  }

  /// 在这份集合的位置目录里发布服务端自己的 profile 说明文件（`v4/devices/<服务端的新代设备>/profile.json`，
  /// [srsPublishProfileInfo]，与 app 的 `SrsProfileLinker.publish` 同一份写法）：别的设备的关联列表、WebUI 勾选列表
  /// 据此显示名字与笔记数。只有服务端写过的新代集合以前在那些列表里只有目录名（交接「第六波 服务端收尾」）。
  ///
  /// 笔记数是这一轮之后向内核要的（[noteCount]，`entity_count`），Dart 不存镜像；名字见 [ServerSrs._resolveName]。
  /// 失败只记日志，不算这一轮失败（说明文件只是给别的设备看的）。
  Future<void> _publishInfo(
    LocalDirectoryAssetStore assets,
    SrsDbStore s,
  ) async {
    final String? device = s.sync2Device;
    final String? dir = s.sync2Dir;
    if (device == null || dir == null || _closed) return;
    try {
      name = _owner._resolveName(
        this,
        (await _owner._discover(onlyDir: dir))[dir],
        own: srsV2WriterName(device),
      );
      final bool hasNotes = noteCount > 0 || await s.hasUserData();
      final Object? label = (await s.sync2DeviceInfo())['name'];
      final String? deviceLabel = label is String && label.isNotEmpty
          ? label
          : null;
      final String sig =
          '$dir|$device|$name|$noteCount|$hasNotes|${deviceLabel ?? ''}';
      if (_publishedInfo == sig) return;
      await srsPublishProfileInfo(
        assets,
        profileUid: uid,
        dir: dir,
        writerId: device,
        name: name,
        hasNotes: hasNotes,
        device: deviceLabel,
        noteCount: noteCount,
      );
      _publishedInfo = sig;
    } catch (e, stack) {
      engineLog.log('ServerSrs.publishInfo', e, stack);
    }
  }

  Future<void> _reconcileMedia(
    SrsLocationBackend backend,
    SrsDbStore s,
    String key,
    SrsSync2Report r,
  ) async {
    final SrsMediaStore? m = _media;
    if (m == null) return;
    final DateTime? at = _mediaReconciledAt;
    final String content = s.contentFingerprint;
    final bool due =
        r.fork ||
        at == null ||
        _mediaReconciledContent != content ||
        DateTime.now().difference(at) >= kServerSrsMediaReconcileInterval;
    if (!due) return;
    try {
      final SrsMediaSyncReport media = await srsRunLocationMedia(
        backend,
        s,
        m.root,
        locationId: key,
      );
      _mediaReconciledAt = DateTime.now();
      _mediaReconciledContent = content;
      if (media.downloaded > 0) _owner._onChanged(uid);
    } catch (e, stack) {
      engineLog.log('ServerSrs.media', e, stack);
    }
  }

  void _setState(ServerSrsProfileState next, String? error) {
    final bool wasReady = state == ServerSrsProfileState.ready;
    state = next;
    lastError = error;
    if (wasReady != (next == ServerSrsProfileState.ready)) {
      _owner._onChanged(uid);
    }
  }

  Future<void> _close() async {
    _closed = true;
    _debounce?.cancel();
    await _running;
    // 先关 RWKV（存快照、等在途的回放取数结束、关后台 runtime），再退役库：反过来的话它在已关的库上取数。
    // 关了的服务永远「没就绪」，退役完成之前到来的排队不出 RWKV 牌组的复习卡（不会落到 FSRS-7 的到期日上）。
    try {
      await _rwkv?.close();
    } catch (e, stack) {
      engineLog.log('ServerSrs.rwkv', e, stack);
    }
    await _store?.retire<void>(
      () async {},
      reason: 'profile $uid is no longer served by fushi_server',
    );
    _store = null;
    _media = null;
    _rwkv = null;
  }

  Map<String, Object?> toJson({required bool isDefault}) => <String, Object?>{
    'uid': uid,
    'name': name,
    'notes': noteCount,
    'state': state.wire,
    'default': isDefault,
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
    'lastError': lastError,
    // RWKV 排程的准备状态：idle（库里没有 RWKV 牌组 / 还没开始）/ downloading / preparing / ready / failed。
    // 没就绪时 RWKV 牌组不出复习卡（远程复习页显示「准备中」/ 错误与重试）。
    if (_rwkv?.status case final SrsRwkvStatus rwkv) ...<String, Object?>{
      'rwkv': rwkv.phase.name,
      if (rwkv.error != null) 'rwkvError': '${rwkv.error}',
    },
  };
}

/// 整机备份期间的占位（[ServerSrs.holdForBackup]）：持有时迁移不开始。[release] 只生效一次。
final class ServerSrsBackupHold {
  ServerSrsBackupHold._(this._onRelease);

  final void Function() _onRelease;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

/// 加密握手没过的原因（[srsLocationHandshake]）：v1 一律当「位置加密了，不提供」。
const Set<String> kServerSrsCryptoErrors = <String>{
  kSrsSync2NeedsKey,
  kSrsSync2WrongKey,
  kSrsSync2EncryptionMissing,
  kSrsSync2BadKdf,
};

/// 后台 isolate 里对 [address] 那份 Rust 连接出快照（顶层函数：闭包里不能捎带 [ServerSrs]，它带着不可跨 isolate 的
/// Future）。设备本地表照留。
Future<void> _snapshotSrsCore(int address, String? libraryPath, String path) =>
    Isolate.run<void>(
      () => SrsCore.fromAddress(
        address,
        libraryPath: libraryPath,
      ).snapshotInto(path, stripDeviceLocal: false),
    );

/// 一次只跑一个（各份 profile 的同步轮次与备份快照共用）。
class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() body) {
    final Future<void> next = _tail.then((_) => body());
    _tail = next.catchError((Object _) {});
    return next;
  }
}

class ServerSrs {
  ServerSrs({
    required this.support,
    required Directory syncData,
    required this.deviceId,
    required String hostId,
    required ServerSrsConfig Function() config,
    FsrsEngine? Function()? engine,
    void Function()? onPublished,
    String Function()? deviceName,
    HttpClient Function()? rwkvHttpClient,
    Future<SrsRwkvBackend> Function(File weights)? rwkvBackend,
    SrsGen4MigrationBackend migration = const SrsNativeGen4MigrationBackend(),
    this.migrationPollInterval = kServerSrsMigrationPollInterval,
    this.migrationRetryDelay = kServerSrsMigrationRetryDelay,
  }) : syncRoot = Directory(
         p.join(syncData.path, 'sync-data', kSyncRootFolderName),
       ),
       directoryKey = srsInterconnectDirectoryKey(hostId),
       _config = config,
       _engineFactory = engine ?? FfiFsrsEngine.tryCreate,
       _onPublishedCb = onPublished,
       _deviceName = deviceName,
       _rwkvHttpClient = rwkvHttpClient ?? createAppHttpClient,
       _rwkvBackend = rwkvBackend,
       _migrationBackend = migration;

  /// `<support>`：srs.db、`srs_media/<uid>/`、`srs_styles/<uid>/` 在这里。
  final Directory support;

  /// 本机互联同步目录的根（`<sync-data>/sync-data/fushi-data`）：已配对设备写进来的就是它。
  final Directory syncRoot;

  /// 这块目录在复习同步里的身份：与连进来的客户端看到的一样（`interconnect:<hostId>`）。
  final String directoryKey;
  final String deviceId;
  final ServerSrsConfig Function() _config;
  final FsrsEngine? Function() _engineFactory;
  final void Function()? _onPublishedCb;

  /// 服务端的设备名（`fushi_server.yaml` 的 `device_name`）：交给内核当型号，随 head 发布，别的设备的设备列表与
  /// 说明文件里的设备名就是它。null = 不交。
  final String Function()? _deviceName;

  /// 下载 RWKV 权重用的 HTTP 客户端（缺省走全局代理设置；测试注入一个不碰网络的）。
  final HttpClient Function() _rwkvHttpClient;

  /// 测试接缝：RWKV 的后台 runtime 换成替身。
  final Future<SrsRwkvBackend> Function(File weights)? _rwkvBackend;

  /// 换代迁移的执行端（测试接缝；生产是原生库的全局命令）。
  final SrsGen4MigrationBackend _migrationBackend;

  /// 迁移进度轮询间隔。
  final Duration migrationPollInterval;

  /// 「等一会再来」类结论之后自动重试前至少隔的时间（[kServerSrsMigrationRetryDelay]）。
  final Duration migrationRetryDelay;

  ServerSrsGeneration _generation = ServerSrsGeneration.initial;

  /// 本进程里正在跑的那次迁移（没有 = null）。
  Future<void>? _migration;
  String? _migrationRunId;
  Timer? _migrationPoll;
  SrsGen4MigrationStep? _loggedStep;

  /// 「等一会再来」之后的一次性再判定（[migrationRetryDelay] 后触发）；到点时置 [_retryDue]，那次判定不再看间隔。
  Timer? _migrationRetry;
  bool _retryDue = false;

  /// 库目录的代际状态（admin API `generation` 段、`ctl srs migration`）。
  ServerSrsGeneration get generation => _generation;

  /// 本进程正在迁移（备份等要整目录一致的操作据此避开）。
  bool get migrationRunning => _migration != null;

  /// 持有中的备份占位（[holdForBackup]）个数；大于 0 时不开始迁移。
  int _backupHolds = 0;

  /// 备份占位期间有迁移该开始（自动判定或管理员手动）：放开最后一个占位时重新判定一次。
  bool _migrationDeferred = false;

  /// 整机备份要复习库目录前后一致（`server_backup.dart`：开着的库走连接快照、没开时原样拷 `srs.db`）。迁移在跑时
  /// 库没开、`srs4.db` 还不存在，提交点又会改名出 `srs4.db` 并原位封存 `srs.db`——这时拷出来的包可能只有封存了的旧库、
  /// 没有新库（还原后复习数据读不到），所以拒绝（返回 null，调用方回 409 `srs_migration_running`）；否则给一个占位，
  /// 持有期间迁移不开始（自动判定推迟到放开之后；管理员手动开始回 `srs_backup_running`），用完必须
  /// [ServerSrsBackupHold.release]。
  ServerSrsBackupHold? holdForBackup() {
    if (_migration != null) return null;
    _backupHolds++;
    return ServerSrsBackupHold._(_releaseBackup);
  }

  void _releaseBackup() {
    _backupHolds--;
    if (_backupHolds > 0 || !_migrationDeferred) return;
    _migrationDeferred = false;
    if (!_stopped) unawaited(applyConfig());
  }

  /// 代际原因让复习不可用时对复习请求的回答；库开着（或复习关着）= null。
  ServerSrsUpgradeRefusal? get upgradeRefusal =>
      _storage != null && _migration == null ? null : _generation.refusal;

  /// 给库挂上 [size] 档的 RWKV 排程（与 app 共用 [srsAttachRwkv]）：权重在 `<support>/srs_rwkv/models`（按需下载；
  /// 不能出网的机器可以事先把权重文件放进去，校验通过即用），状态快照在该档的目录（[srsRwkvStateDir]）。
  SrsRwkvService _attachRwkv(SrsDbStore store, SrsRwkvModelSize size) =>
      srsAttachRwkv(
        store,
        support: support,
        models: SrsRwkvModels(
          dir: srsRwkvModelsDir(support),
          size: size,
          createClient: _rwkvHttpClient,
        ),
        openBackend: _rwkvBackend,
        log: (String message) =>
            engineLog.logDiagnostic('ServerSrs.rwkv', message),
      );

  /// 设备的 RWKV 模型档位（`<support>/srs_rwkv/model_size`，与 app 同一个设置文件、同一套读法）。
  SrsRwkvModelSize get rwkvModelSize => readSrsRwkvModelSize(support);

  /// 换 RWKV 模型档位（WebUI / admin API / ctl）：写设置文件，再把各份已打开的库的 RWKV 服务换成新档位的，
  /// 不重启。手改设置文件也会生效：每次对齐配置（含兜底定时器那一次）都按文件里的档位对齐在用的服务。
  Future<void> setRwkvModelSize(SrsRwkvModelSize size) async {
    await writeRwkvModelSize(size);
    await applyConfig();
  }

  /// 只写档位设置文件、不对齐在用的服务：admin PUT 要先写它（写不进去就整次失败、配置不动），
  /// 再改 config.yaml，最后 [applyConfig] 一次。
  Future<void> writeRwkvModelSize(SrsRwkvModelSize size) =>
      writeSrsRwkvModelSize(support, size);

  SrsStorage? _storage;
  FsrsEngine? _engine;

  /// 备份用（`createServerBackup` 的 `snapshotSrs`）：复习库开着时在它那份连接上 Rust `VACUUM INTO`，排在同步轮次
  /// 之间跑（快照不会落在一轮写入的中途）。设备本地表照留：整机还原回到的是同一台设备。没开（没选 profile）= null，
  /// 备份自己离线打开 srs.db。
  Future<void> Function(String path)? get snapshotFn {
    final SrsStorage? storage = _storage;
    if (storage == null || storage.isClosed) return null;
    final int address = storage.core.address;
    final String? libraryPath = storage.core.libraryPath;
    return (String path) =>
        _rounds.run(() => _snapshotSrsCore(address, libraryPath, path));
  }

  final Map<String, ServerSrsProfile> _profiles = <String, ServerSrsProfile>{};
  final _SerialQueue _rounds = _SerialQueue();
  Timer? _safety;
  Future<void> _ops = Future<void>.value();
  bool _stopped = false;

  /// 某份 profile 的库有变化（WebUI / 统计重读用；测试也听它）。
  final StreamController<String> changes = StreamController<String>.broadcast();

  /// 远程复习（`/api/srs/remote/*`）：没有可用的 profile 时 null（端点 404、能力位不报）。选了 profile、复习库正在
  /// 升级 / 升级受阻时照样给：请求回类型化的 503（[ServerSrsUpgradeRefusal.remoteCode]），客户端显示「主机在升级」
  /// 而不是「主机没开复习」。
  SrsRemoteStoreService? get remoteStore =>
      readyProfiles.isEmpty &&
          (upgradeRefusal == null || _config().profiles.isEmpty)
      ? null
      : _remote;

  /// 远程复习按 [uid]（null = 默认）取库：不可用且是代际原因时抛类型化的 [SrsRemoteStoreError]（点名的 profile 不在
  /// 提供之列时仍回 null = 「profile 变了」）。
  SrsDbStore? _remoteStoreFor(String? uid) {
    final SrsDbStore? store = storeFor(uid);
    if (store != null) return store;
    if (uid != null && !_config().profiles.contains(uid)) return null;
    final ServerSrsUpgradeRefusal? refusal = upgradeRefusal;
    if (refusal != null) {
      throw SrsRemoteStoreError(
        refusal.status,
        refusal.remoteCode,
        _generation.reason ?? _generation.state.wire,
      );
    }
    return null;
  }

  late final SrsRemoteStoreService _remote = SrsRemoteStoreService(
    readStore: () async => _remoteStoreFor(null),
    readProfile: (String uid) async => _remoteStoreFor(uid),
    profiles: () async => <SrsRemoteServedProfile>[
      for (final ServerSrsProfile prof in readyProfiles)
        SrsRemoteServedProfile(
          uid: prof.uid,
          name: prof.name,
          notes: prof.noteCount,
        ),
    ],
    readMedia: _readMedia,
    onWrite: (String uid) => _profiles[uid]?.scheduleSync(),
  );

  /// 提供中的 profile（按配置顺序）。
  List<ServerSrsProfile> get profiles => <ServerSrsProfile>[
    for (final String uid in _config().profiles)
      if (_profiles[uid] != null) _profiles[uid]!,
  ];

  List<ServerSrsProfile> get readyProfiles => <ServerSrsProfile>[
    for (final ServerSrsProfile prof in profiles)
      if (prof.store != null) prof,
  ];

  bool get schedulerAvailable => _engine != null;

  /// 实际的默认 profile：配置的默认可用就是它，否则第一份可用的。
  ServerSrsProfile? get defaultProfile {
    final String? configured = _config().effectiveDefault;
    final ServerSrsProfile? hit = configured == null
        ? null
        : _profiles[configured];
    if (hit?.store != null) return hit;
    final List<ServerSrsProfile> ready = readyProfiles;
    return ready.isEmpty ? null : ready.first;
  }

  /// [uid] 那份可用的库；[uid] 为 null = 默认 profile。没提供 / 不可用 → null。
  SrsDbStore? storeFor(String? uid) =>
      uid == null ? defaultProfile?.store : _profiles[uid]?.store;

  ServerSrsProfile? profile(String uid) => _profiles[uid];

  /// [uid] 那份的制卡器。落到哪个牌组由载荷里的单卡牌组覆盖（全名）决定：配置的 `mining_decks` 与手机选的牌组都
  /// 经它进来（[ServerRemoteMiningService]），没有 = 那份的默认牌组。
  SrsMiner? minerFor(String uid) {
    final ServerSrsProfile? prof = _profiles[uid];
    final SrsDbStore? s = prof?.store;
    final SrsMediaStore? m = prof?.media;
    if (s == null || m == null) return null;
    return SrsMiner(
      store: s,
      media: m,
      destination: const SrsMiningDestination(),
    );
  }

  /// 起：按配置打开各份 profile，各跑一轮，挂兜底定时器。复习关（没选 profile）时什么都不开。
  Future<void> start() => _serial(() async {
    _stopped = false;
    await _reconcile();
    _safety?.cancel();
    _safety = Timer.periodic(kServerSrsSafetyInterval, (_) {
      // 先补开上次没打开的（原生库后装上 / 一时打不开），再各同步一轮。
      unawaited(
        applyConfig().whenComplete(() {
          for (final ServerSrsProfile prof in profiles) {
            unawaited(prof.syncNow());
          }
        }),
      );
    });
  });

  /// 配置变了（WebUI / ctl）：新加的打开、去掉的关掉，不重启。
  Future<void> applyConfig() => _serial(_reconcile);

  Future<void> stop() => _serial(() async {
    _stopped = true;
    _safety?.cancel();
    _safety = null;
    _migrationRetry?.cancel();
    _migrationRetry = null;
    // 迁移在跑：提交点之前叫停并等结论（目录回到迁移前的样子）；过了提交点就等它跑完（改名 / 封存不能被打断）。
    final Future<void>? migration = _migration;
    if (migration != null) {
      cancelMigration();
      await migration;
    }
    for (final ServerSrsProfile prof in _profiles.values.toList()) {
      await prof._close();
    }
    _profiles.clear();
    await _storage?.close();
    _storage = null;
    if (!changes.isClosed) await changes.close();
  });

  /// 起 / 停 / 改配置排成一队。出错只记日志、不往外抛：复习库出问题不能拖垮 serve 的启动与改配置。
  Future<void> _serial(Future<void> Function() body) {
    final Future<void> next = _ops.then((_) => body());
    return _ops = next.catchError((Object e, StackTrace st) {
      engineLog.log('ServerSrs', e, st);
    });
  }

  Future<void> _reconcile() async {
    if (_stopped) return;
    final List<String> wanted = _config().profiles;
    for (final String uid in _profiles.keys.toList()) {
      if (wanted.contains(uid)) continue;
      await _profiles.remove(uid)!._close();
      _onChanged(uid);
    }
    if (wanted.isEmpty) {
      await _storage?.close();
      _storage = null;
      return;
    }
    final SrsStorage? storage = await _openStorage(wanted);
    if (storage == null) return;
    _engine ??= _engineFactory();
    // 档位每次对齐都重读（不是只在挂载时读一次）：WebUI 改了、或有人手改了设置文件，已打开的库在这里换过去。
    final SrsRwkvModelSize rwkvSize = rwkvModelSize;
    final Map<String, SrsRemoteProfile> found = await _discover();
    for (final String uid in wanted) {
      final ServerSrsProfile prof = _profiles[uid] ??= ServerSrsProfile._(
        uid,
        this,
      );
      final SrsRemoteProfile? info = await _infoOf(prof, found);
      final String? device = prof._store?.sync2Device;
      prof.name = _resolveName(
        prof,
        info,
        own: device == null ? null : srsV2WriterName(device),
      );
      // 库开着时数以库为准（每轮同步后重数），设备报的旧数不覆盖它。
      if (info != null && prof._store == null) {
        prof.noteCount = info.noteCount ?? 0;
      }
      if (prof._store != null) {
        await prof._switchRwkv(rwkvSize);
        continue;
      }
      if (prof.state == ServerSrsProfileState.upgrading ||
          prof.state == ServerSrsProfileState.upgradeBlocked) {
        // 库目录升级完了（或本来就好）：回到「正在打开」，第一轮同步跑完才对外提供。
        prof._setState(ServerSrsProfileState.opening, null);
      }
      try {
        prof._store = await SrsDbStore.open(
          core: storage.core,
          profileUid: uid,
          deviceId: deviceId,
          engine: _engine,
          fallbackRolloverHour: () => _config().rolloverHour,
          styles: SrsStyleStore(SrsStyleStore.directoryFor(support, uid)),
        );
        prof._media = SrsMediaStore(SrsMediaStore.directoryFor(support, uid));
        // 库交出去之前就挂上：没挂 RWKV 的库会把 RWKV 牌组按 FSRS-7 的到期日排（见 srs_rwkv_attach.dart 文件头）。
        prof._rwkv = _attachRwkv(prof._store!, rwkvSize);
      } catch (e, stack) {
        prof._setState(ServerSrsProfileState.failed, '$e');
        engineLog.log('ServerSrs.open', e, stack);
        continue;
      }
      // 第一轮跑完才知道位置是不是加密的；跑完之前不对外提供（不拿一份没收过数据的空库应答）。
      unawaited(prof.syncNow());
    }
  }

  /// [prof] 的显示名：管理员起的（[ServerSrsConfig.profileNames]）优先；否则别的设备在说明文件里报的（[info] 里
  /// 写入者不是 [own] 的，几份时按 [serverSrsPickReportedName] 的确定规则挑）；再否则服务端自己上次发布的（[own] 那份，让设备都离开之后名字还在）。[own] = 服务端在这个
  /// 集合里的写入者名（库没开时不知道，null：所有写入者一视同仁）。不先取自己上次发布的：设备改了名，服务端要跟着改，
  /// 不能一直拿自己那份旧名字当来源。[info] 为 null（这一轮没读到）时不动现有的名字。
  ///
  /// 设备报的名字来自同步位置（外来输入），与管理员起的名字同一个口径过滤（[serverSrsProfileNameOk]）：不合格的跳过，
  /// 不写进服务端自己发布的说明文件。
  String _resolveName(
    ServerSrsProfile prof,
    SrsRemoteProfile? info, {
    required String? own,
  }) {
    final String? configured = _config().profileNames[prof.uid];
    if (configured != null &&
        configured.isNotEmpty &&
        serverSrsProfileNameOk(configured)) {
      return configured;
    }
    if (info == null) return prof.name;
    final String? reported = serverSrsPickReportedName(
      info.nameOf,
      info.nameAtOf,
      own: own,
    );
    if (reported != null) return reported;
    final String? mine = own == null ? null : info.nameOf[own];
    return mine != null && serverSrsProfileNameOk(mine) ? mine : '';
  }

  /// 本机型号（= 服务端设备名）与平台交给内核，随下一次写 head 发布（与 app 的 `srsPublishDeviceInfo` 同一条命令；
  /// 没变时内核不进写锁）。失败只记日志，不挡同步。
  Future<void> _publishDeviceInfo(SrsDbStore s) async {
    final String? model = _deviceName?.call().trim();
    try {
      await s.sync2DeviceInfo(
        model: model == null || model.isEmpty ? null : model,
        platform: Platform.operatingSystem,
      );
    } catch (e, stack) {
      engineLog.log('ServerSrs.deviceInfo', e, stack);
    }
  }

  /// [prof] 在同步目录里的说明（名字、笔记数估计）：库开着时按它**绑定**的位置目录取（内核 `identity` 的 `dir`；并入 /
  /// 认领之后不等于 uid）；库还没开时按配置里的 uid 取——D32：管理员勾选的就是同步目录名，第一次打开（`identity`）
  /// 绑定的目录也正是它。读不到绑定只记日志、不填（名字只是显示用）。
  Future<SrsRemoteProfile?> _infoOf(
    ServerSrsProfile prof,
    Map<String, SrsRemoteProfile> found,
  ) async {
    final SrsDbStore? s = prof._store;
    if (s == null) return found[prof.uid];
    try {
      return found[await srsLocationDir(s)];
    } catch (e, stack) {
      engineLog.log('ServerSrs.hostDir', e, stack);
      return null;
    }
  }

  /// 开 `<support>` 的新代库；开不出来（要迁移 / 迁移中 / 各种没迁完的状态 / 原生库缺）时标好各份 profile 的状态、
  /// 返回 null。先按 `gen4_migrate_status` 判定：要迁移就不去开库，直接（自动）迁移。
  Future<SrsStorage?> _openStorage(List<String> wanted) async {
    final SrsStorage? open = _storage;
    if (open != null) return open;
    if (_migration != null) {
      _markProfiles(wanted);
      return null;
    }
    final String dir = support.path;
    SrsGenState? state;
    try {
      state = _migrationBackend.status(dir).state;
    } catch (e, stack) {
      // 读不了状态（原生库缺 / 目录坏）：交给下面开库，报同一个错、标成出错。
      engineLog.log('ServerSrs.generation', e, stack);
    }
    if (state != null && state != SrsGenState.ready) {
      _onGenState(state, wanted);
      return null;
    }
    try {
      final SrsStorage storage = await SrsStorage.open(directory: dir);
      _storage = storage;
      if (_generation.state != ServerSrsGenState.ready) {
        _setGeneration(
          ServerSrsGeneration(
            state: ServerSrsGenState.ready,
            verdict: _generation.verdict,
            finishedAt: _generation.finishedAt,
          ),
        );
      }
      return storage;
    } on SrsStoreOpenBlocked catch (e) {
      switch (e) {
        case SrsStoreNotMigrated(state: final SrsGenState s)
            when s != SrsGenState.ready:
          _onGenState(s, wanted);
        case SrsStoreMigrating():
          _onGenState(SrsGenState.migratingElsewhere, wanted);
        case SrsStoreLegacyUnmigrated():
          _setGeneration(
            ServerSrsGeneration(
              state: ServerSrsGenState.legacyBesideNew,
              code: 'legacyBesideNew',
              reason: e.message,
            ),
          );
          _markProfiles(wanted);
        case SrsStoreNotMigrated():
          // Primary 打开不会回「ready 却没建库」（只有辅助进程会）：当一般错误报。
          _openFailed(wanted, e);
      }
      return null;
    } catch (e, stack) {
      // 原生库 libfushi_fsrs 不在 / srs.db 打不开：各份标成出错，服务照常起（其余功能不受影响），兜底定时器再试。
      engineLog.log('ServerSrs.storage', e, stack);
      _openFailed(wanted, e);
      return null;
    }
  }

  void _openFailed(List<String> wanted, Object e) {
    for (final String uid in wanted) {
      (_profiles[uid] ??= ServerSrsProfile._(uid, this))._setState(
        ServerSrsProfileState.failed,
        'srs.db could not be opened: $e',
      );
    }
  }

  /// 打开时库目录处在 [state]（不是 ready）：要迁移就自动开始（上一次的结论允许时），其余记成管理员可见的状态。
  void _onGenState(SrsGenState state, List<String> wanted) {
    switch (state) {
      case SrsGenState.needsMigration:
        // 可以自动（再）开始：没跑过（启动 / 重启后续做——迁移本身可重入，被杀留下的临时文件内核取锁后先清），或上次
        // 是「等一会再来」且已过了重试间隔（刚跑完紧接着的这次判定不重试，等兜底定时器的下一轮）。其余保留上一次
        // 结论（被拦下的 code / 空间 / 取消 / 报错），不自动重跑。
        final DateTime? finished = _generation.finishedAt;
        if (_generation.autoRetry &&
            (finished == null ||
                _retryDue ||
                DateTime.now().difference(finished) >= migrationRetryDelay)) {
          _beginMigration();
        } else {
          _armMigrationRetry();
        }
      case SrsGenState.migratingElsewhere:
        _setGeneration(
          const ServerSrsGeneration(
            state: ServerSrsGenState.migratingElsewhere,
          ),
        );
        // 别的进程迁完（或放弃）了要接着开库 / 迁移：隔一会再看，不等兜底定时器。
        _armMigrationRetry();
      case SrsGenState.migrationFailed:
        // 本进程刚跑出的失败带着报告路径，别用状态命令的（不带路径）盖掉。
        if (_generation.state != ServerSrsGenState.migrationFailed) {
          _setGeneration(
            const ServerSrsGeneration(state: ServerSrsGenState.migrationFailed),
          );
        }
      case SrsGenState.sealedOldOnly:
        if (_generation.state != ServerSrsGenState.sealedOldOnly) {
          _setGeneration(
            const ServerSrsGeneration(state: ServerSrsGenState.sealedOldOnly),
          );
        }
      case SrsGenState.ready:
        break;
    }
    _markProfiles(wanted);
  }

  void _setGeneration(ServerSrsGeneration next) {
    final ServerSrsGenState before = _generation.state;
    _generation = next;
    if (before != next.state) {
      engineLog.logDiagnostic(
        'ServerSrs.generation',
        '${before.wire} -> ${next.state.wire}'
            '${next.code == null ? '' : ' (${next.code})'}'
            '${next.reason == null ? '' : ': ${next.reason}'}',
      );
    }
  }

  /// 库目录没开（升级中 / 升级受阻）时把 [wanted] 各份标成对应状态；名字与笔记数照常从同步目录估。
  void _markProfiles(List<String> wanted) {
    final ServerSrsUpgradeRefusal? refusal = _generation.refusal;
    if (refusal == null) return;
    final ServerSrsProfileState state =
        refusal == ServerSrsUpgradeRefusal.upgrading
        ? ServerSrsProfileState.upgrading
        : ServerSrsProfileState.upgradeBlocked;
    for (final String uid in wanted) {
      final ServerSrsProfile prof = _profiles[uid] ??= ServerSrsProfile._(
        uid,
        this,
      );
      if (prof.state != state || prof.lastError != _generation.advice) {
        prof._setState(state, _generation.advice);
      }
    }
  }

  /// 上一次结论是「等一会再来」（[ServerSrsGeneration.autoRetry]）且还没就绪时，[migrationRetryDelay] 之后再判定一次
  /// （重新套用配置）。已挂着就不重挂；不该自动重跑的结论什么都不挂。
  void _armMigrationRetry() {
    if (_stopped || _migrationRetry != null) return;
    if (!_generation.autoRetry ||
        _generation.state == ServerSrsGenState.ready) {
      return;
    }
    _migrationRetry = Timer(migrationRetryDelay, () {
      _migrationRetry = null;
      if (_stopped) return;
      _retryDue = true;
      unawaited(applyConfig());
    });
  }

  /// 后台开始一次迁移（已在跑时无操作）。结论落在 [generation]；跑完重新套用配置（提交了就开库、各份同步）。
  void _beginMigration() {
    if (_migration != null) return;
    if (_backupHolds > 0) {
      // 备份在拷库目录：放开占位之后重新判定（[_releaseBackup]），不在备份中途改名出新库、封存旧库。
      _migrationDeferred = true;
      return;
    }
    _retryDue = false;
    _migrationRetry?.cancel();
    _migrationRetry = null;
    final DateTime started = DateTime.now();
    final String runId = 'fushi-server-gen4-${started.microsecondsSinceEpoch}';
    _migrationRunId = runId;
    _loggedStep = null;
    _setGeneration(
      ServerSrsGeneration(
        state: ServerSrsGenState.migrating,
        verdict: _generation.verdict,
        startedAt: started,
      ),
    );
    engineLog.logDiagnostic(
      'ServerSrs.migrate',
      'start: upgrading the protocol 3 review library in ${support.path}',
    );
    _migrationPoll = Timer.periodic(
      migrationPollInterval,
      (_) => _pollMigration(),
    );
    final Future<void> run = _runMigration(runId);
    _migration = run;
    unawaited(
      run.whenComplete(() {
        _migration = null;
        _migrationRunId = null;
        // 提交了：开库、各份打开并同步；没提交：按结论标好各份（不自动重跑，见 [ServerSrsGeneration.autoRetry]）。
        if (!_stopped) unawaited(applyConfig());
      }),
    );
  }

  Future<void> _runMigration(String runId) async {
    final String dir = support.path;
    ServerSrsGeneration result;
    final DateTime? started = _generation.startedAt;
    try {
      final Map<String, Map<String, Object?>> caches = await _migrationCaches(
        dir,
      );
      final SrsGen4MigrationOutcome o = await _migrationBackend.run(
        dir,
        caches: caches,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        runId: runId,
      );
      result = _generationOf(o, started);
    } catch (e, stack) {
      engineLog.log('ServerSrs.migrate', e, stack);
      result = ServerSrsGeneration(
        state: ServerSrsGenState.error,
        reason: '$e',
        startedAt: started,
        finishedAt: DateTime.now(),
      );
    } finally {
      _migrationPoll?.cancel();
      _migrationPoll = null;
    }
    engineLog.logDiagnostic(
      'ServerSrs.migrate',
      'finished: ${result.verdict ?? result.state.wire}'
          '${result.code == null ? '' : ' (${result.code})'}'
          '${result.reason == null ? '' : ': ${result.reason}'}'
          '${result.reportPath == null ? '' : ', report ${result.reportPath}'}',
    );
    _setGeneration(result);
  }

  /// 迁移要的缓存配置：旧库里全部有数据的 profile（内核列，含孤儿 uid）∪ 配置里提供的 ∪ 同步目录里看得到的，每个按
  /// [srsCacheConfigFor] 交一份（只取决于 uid；多给的内核不用）。列表读不到只记日志：真缺了哪个，内核拦下并点名
  /// （`missingCacheConfig`），旧库不动。
  Future<Map<String, Map<String, Object?>>> _migrationCaches(String dir) async {
    final Set<String> uids = <String>{..._config().profiles};
    try {
      uids.addAll(await _migrationBackend.legacyProfiles(dir));
    } catch (e, stack) {
      engineLog.log('ServerSrs.migrate.profiles', e, stack);
    }
    uids.addAll((await _discover()).keys);
    return <String, Map<String, Object?>>{
      for (final String uid in uids) uid: srsCacheConfigFor(uid),
    };
  }

  static ServerSrsGeneration _generationOf(
    SrsGen4MigrationOutcome o,
    DateTime? started,
  ) {
    final DateTime finished = DateTime.now();
    final String verdict = o.verdict.wire;
    ServerSrsGeneration of(
      ServerSrsGenState state, {
      String? code,
      String? reason,
    }) => ServerSrsGeneration(
      state: state,
      code: code,
      reason: reason,
      reportPath: o.reportPath,
      neededBytes: o.neededBytes,
      freeBytes: o.freeBytes,
      verdict: verdict,
      startedAt: started,
      finishedAt: finished,
    );
    return switch (o.verdict) {
      SrsGen4MigrationVerdict.committed => of(ServerSrsGenState.ready),
      SrsGen4MigrationVerdict.aborted => of(ServerSrsGenState.migrationFailed),
      SrsGen4MigrationVerdict.noSpace => of(ServerSrsGenState.noSpace),
      SrsGen4MigrationVerdict.cancelled => of(ServerSrsGenState.needsMigration),
      SrsGen4MigrationVerdict.blocked => switch (o.code) {
        'migrating' => of(
          ServerSrsGenState.migratingElsewhere,
          code: o.code,
          reason: o.reason,
        ),
        'sealedWithoutNew' => of(
          ServerSrsGenState.sealedOldOnly,
          code: o.code,
          reason: o.reason,
        ),
        'legacyBesideNew' => of(
          ServerSrsGenState.legacyBesideNew,
          code: o.code,
          reason: o.reason,
        ),
        _ => of(ServerSrsGenState.blocked, code: o.code, reason: o.reason),
      },
    };
  }

  void _pollMigration() {
    if (_migration == null) return;
    final SrsGen4MigrationProgress? p;
    try {
      p = _migrationBackend.status(support.path).running;
    } catch (e, stack) {
      // 进度只是显示：读不到就保留上一次的，结论以 run 的返回为准。
      engineLog.log('ServerSrs.migrate.status', e, stack);
      return;
    }
    if (p == null || _generation.state != ServerSrsGenState.migrating) return;
    if (p.step != _generation.step ||
        p.done != _generation.done ||
        p.total != _generation.total) {
      _generation = _generation._progress(p);
    }
    if (p.step != _loggedStep) {
      _loggedStep = p.step;
      engineLog.logDiagnostic(
        'ServerSrs.migrate',
        'step ${p.step.index + 1}/${SrsGen4MigrationStep.values.length} '
            '${p.step.wire} (${p.done}/${p.total})',
      );
    }
  }

  /// 管理员开始（或在失败 / 取消之后重新开始）迁移。返回拒绝原因（null = 已在后台开始，进度看 [generation]）：
  /// `srs_stopped` / `srs_migration_running` / `srs_migrating_elsewhere` / `srs_migration_not_needed` /
  /// `srs_backup_running`（整机备份持有占位，[holdForBackup]）。
  Future<String?> startMigration() {
    final Completer<String?> answer = Completer<String?>();
    unawaited(
      _serial(() async {
        try {
          answer.complete(_tryStartMigration());
        } catch (e, stack) {
          answer.completeError(e, stack);
        }
      }),
    );
    return answer.future;
  }

  String? _tryStartMigration() {
    if (_stopped) return 'srs_stopped';
    if (_migration != null) return 'srs_migration_running';
    if (_storage != null) return 'srs_migration_not_needed';
    if (_backupHolds > 0) return 'srs_backup_running';
    final SrsGenState state;
    try {
      state = _migrationBackend.status(support.path).state;
    } catch (e, stack) {
      engineLog.log('ServerSrs.generation', e, stack);
      return 'srs_unavailable';
    }
    if (state == SrsGenState.migratingElsewhere) {
      return 'srs_migrating_elsewhere';
    }
    // 状态命令在新代库在时报 ready：旁边还有没迁移的旧库（开库回 -6）时照样让内核再看一次（是迁移来源就补封，
    // 不是就再拦下），别的 ready 没东西可迁。
    if (state == SrsGenState.ready &&
        _generation.state != ServerSrsGenState.legacyBesideNew) {
      return 'srs_migration_not_needed';
    }
    _beginMigration();
    _markProfiles(_config().profiles);
    return null;
  }

  /// 管理员叫停正在跑的迁移（提交点之前有效）。返回拒绝原因（null = 已请求叫停，结论稍后落在 [generation]）：
  /// `srs_migration_not_running` / `srs_migration_past_commit`。
  ///
  /// 判断用这一刻现取的进度（不用最多滞后一个轮询间隔的 [generation]）。现取与叫停之间迁移仍可能刚好跨过提交点：内核
  /// 在提交点之后不受理叫停、迁移照常提交——所以「已请求」不等于「会停下」，以最终结论（[ServerSrsGeneration.verdict]）
  /// 为准。
  String? cancelMigration() {
    if (_migration == null) return 'srs_migration_not_running';
    SrsGen4MigrationStep? step = _generation.step;
    try {
      final SrsGen4MigrationProgress? p = _migrationBackend
          .status(support.path)
          .running;
      if (p != null) {
        step = p.step;
        if (_generation.state == ServerSrsGenState.migrating) {
          _generation = _generation._progress(p);
        }
      }
    } catch (e, stack) {
      // 现取不到：退回轮询到的那份（内核在提交点之后照样不受理，结论兜底）。
      engineLog.log('ServerSrs.migrate.status', e, stack);
    }
    if (step != null && !step.cancellable) return 'srs_migration_past_commit';
    final bool signalled = _migrationBackend.cancel(
      support.path,
      runId: _migrationRunId,
    );
    if (!_generation.cancelRequested) _generation = _generation._cancelling();
    engineLog.logDiagnostic(
      'ServerSrs.migrate',
      signalled
          ? 'cancel requested (the verdict tells whether it stopped before the commit step)'
          : 'cancel registered for the run that has not reached the kernel yet',
    );
    return null;
  }

  /// 本机同步目录里有哪些 profile（WebUI 的勾选列表）。
  Future<List<SrsRemoteProfile>> discoverProfiles() async =>
      (await _discover()).values.toList();

  /// [onlyDir] 给了只读那一个位置目录（每轮发布说明文件时只要自己绑定的目录）。
  Future<Map<String, SrsRemoteProfile>> _discover({String? onlyDir}) async {
    if (!syncRoot.existsSync()) return const <String, SrsRemoteProfile>{};
    try {
      final List<SrsRemoteProfile> list = await srsListRemoteProfiles(
        LocalDirectoryAssetStore(syncRoot),
        onlyDirs: onlyDir == null ? null : <String>{onlyDir},
      );
      return <String, SrsRemoteProfile>{
        for (final SrsRemoteProfile r in list) r.uid: r,
      };
    } catch (e, stack) {
      engineLog.log('ServerSrs.discover', e, stack);
      return const <String, SrsRemoteProfile>{};
    }
  }

  /// 已配对设备往本机同步目录写了文件（`FushiSyncServer.onClientWrite`）：落在某份提供中的 profile **绑定**的位置
  /// 目录里就去抖后同步那一份。返回排了同步的 profile（测试用；调用方不必等）。
  ///
  /// 目录名不是 uid（D32 只规定「配置里的 uid 取自同步目录名」，并入 / 认领后绑定的目录会变，设计 §5.1）：一律经内核
  /// 按绑定反查（[srsHostProfilesOfDir]）。
  Future<List<String>> onClientWrite(String relativePath) async {
    final String? dir = srsHostPathDir(relativePath);
    if (dir == null) return const <String>[];
    final List<String> served = await _servedProfilesOfDir(dir);
    for (final String uid in served) {
      _profiles[uid]?.scheduleSync();
    }
    return served;
  }

  /// 绑定在位置目录 [dir] 上、而且在提供中的 profile（库目录开着才查得到）。[dir] 来自对端写入的路径：内核拒绝坏
  /// 目录名时记诊断日志、当作不属于任何 profile（不抛给写入方——那次写入本身已经成功落盘）。
  Future<List<String>> _servedProfilesOfDir(String dir) async {
    final SrsStorage? storage = _storage;
    if (storage == null || storage.isClosed) return const <String>[];
    final List<String> bound;
    try {
      bound = await srsHostProfilesOfDir(storage.core, dir);
    } on SrsCoreException catch (e) {
      engineLog.logDiagnostic('ServerSrs.hostDir', 'refused $dir: $e');
      return const <String>[];
    } catch (e, stack) {
      // 库目录正被关 / 后台 isolate 起不来：这次写入只是没叫醒同步，兜底定时器那一轮照样会同步；记日志带原栈。
      engineLog.log('ServerSrs.hostDir', e, stack);
      return const <String>[];
    }
    return <String>[
      for (final String uid in bound)
        if (_profiles.containsKey(uid)) uid,
    ];
  }

  /// 已配对设备直接写了某台设备自己的段：用对端名给它补名字（老版本没有自报名字时同步页显示它）。补充名按设备记、
  /// 不分集合（内核 `device_hint`），键只按设备；只给落在提供中的 profile 绑定目录里的段补，别的目录不碰库。
  final Map<String, String> _hinted = <String, String>{};

  Future<void> onClientUpload(String relativePath, String? peerName) async {
    if (peerName == null || peerName.isEmpty) return;
    final String? device = srsHostUploadedSegmentDevice(relativePath);
    final String? dir = srsHostPathDir(relativePath);
    if (device == null || dir == null) return;
    if (_hinted[device] == peerName) return;
    final List<String> served = await _servedProfilesOfDir(dir);
    final SrsDbStore? store = served.isEmpty
        ? null
        : _profiles[served.first]?._store;
    if (store == null) return;
    _hinted[device] = peerName;
    try {
      await store.sync2DeviceHint(device, peerName);
    } catch (e, stack) {
      _hinted.remove(device);
      engineLog.log('ServerSrs.deviceHint', e, stack);
    }
  }

  /// 立刻同步：[uid] 为 null = 全部。
  Future<void> syncNow([String? uid]) async {
    final List<ServerSrsProfile> targets = uid == null
        ? profiles
        : <ServerSrsProfile>[?_profiles[uid]];
    await Future.wait(<Future<void>>[
      for (final ServerSrsProfile prof in targets) prof.syncNow(),
    ]);
  }

  /// [uid] 那份里还没信任的设备（待确认在前）：服务端第一轮同步之后才第一次出现的设备，它的删除与彻底清除在服务端
  /// 的库里扣着（native/fushi_fsrs/src/store/sync2/trust.rs），要管理员确认。那份不可用时 null。
  Future<List<SrsDeviceView>?> untrustedDevices(String uid) async {
    final SrsDbStore? s = _profiles[uid]?.store;
    if (s == null) return null;
    return srsUntrustedDevices(await srsLoadDevices(s));
  }

  /// 信任 / 拒绝 [uid] 那份里的一台设备（与 app 冲突中心的「待确认的设备」同一条 engine 路径）。信任 = 扣着的删除与
  /// 彻底清除立即生效，库有变化，通知远程复习等重读。那份不可用时抛 [StateError]；设备不对抛
  /// [SrsDeviceTrustException]。
  Future<SrsDeviceView> setDeviceTrust(
    String uid,
    String device, {
    required bool trust,
  }) async {
    final SrsDbStore? s = _profiles[uid]?.store;
    if (s == null) throw StateError('profile $uid is not available');
    final SrsDeviceView view = await srsSetDeviceTrust(s, device, trust: trust);
    if (trust) _onChanged(uid);
    return view;
  }

  /// 服务端自己写了 [uid] 的库（AnkiConnect / 互联制卡）：去抖后发出去。
  void notifyWrite(String uid) => _profiles[uid]?.scheduleSync();

  Future<Uint8List?> _readMedia(String name) async {
    // 媒体名是内容哈希：同名即同内容，哪份 profile 有就给哪份的。
    for (final ServerSrsProfile prof in readyProfiles) {
      final Uint8List? bytes = await prof.media?.load(name);
      if (bytes != null) return bytes;
    }
    return null;
  }

  void _onPublished() => _onPublishedCb?.call();

  void _onChanged(String uid) {
    if (!changes.isClosed) changes.add(uid);
  }

  /// WebUI / admin API / ctl 的状态。
  Map<String, Object?> status() {
    final ServerSrsConfig cfg = _config();
    final String? def = defaultProfile?.uid ?? cfg.effectiveDefault;
    return <String, Object?>{
      'enabled': cfg.enabled,
      'scheduler': _engine != null,
      'defaultProfile': def,
      'miningTarget': cfg.miningTarget.wire,
      // 库目录的代际状态（换代迁移，G10-3）：状态、迁移进度、上次结论与处置说明。
      'generation': _generation.toJson(),
      'profiles': <Map<String, Object?>>[
        for (final ServerSrsProfile prof in profiles)
          prof.toJson(isDefault: prof.uid == def),
      ],
    };
  }
}
