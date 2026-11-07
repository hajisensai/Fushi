/// 服务端的复习库（docs/specs/2026-11-05-server-srs-design.md）：服务端当一台复习设备。
///
/// - 提供管理员勾选的几份 profile（一门语言一份常见），每份一个 [SrsDbStore]，共用一个 `<support>/srs.db`；
/// - 每份在本机的互联同步目录（`<sync-data>/fushi-data/fushi-srs/<uid>/`，就是已配对设备写进来的那块）上同步：
///   别的设备的改动收进来，服务端自己的写入（远程复习 / AnkiConnect / 互联制卡）发出去；
/// - 远程复习（`/api/srs/remote/*`）按客户端点名的 profile 走（[remoteStore]）；
/// - 位置开了端到端加密的 profile 在 v1 里不提供（服务端读不了），别的 profile 不受影响。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 已配对设备写进来之后，等这么久没有新写入再跑一轮（一轮客户端同步连写好几个文件，并成一次）。
const Duration kServerSrsWriteDebounce = Duration(seconds: 3);

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
  failed('failed');

  const ServerSrsProfileState(this.wire);

  final String wire;
}

/// 服务端提供的一份 profile。
class ServerSrsProfile {
  ServerSrsProfile._(this.uid, this._owner);

  final String uid;
  final ServerSrs _owner;

  SrsDbStore? _store;
  SrsMediaStore? _media;
  ServerSrsProfileState state = ServerSrsProfileState.opening;
  String? lastError;
  DateTime? lastSyncAt;
  DateTime? _mediaReconciledAt;
  String? _mediaReconciledContent;

  /// 同步位置里各设备报的名字（WebUI 与远程复习的选择列表显示）；没有时空。
  String name = '';

  /// 各设备报的用户笔记数里最大的那个。
  int noteCount = 0;

  Timer? _debounce;
  Future<void>? _running;
  bool _again = false;
  bool _closed = false;

  /// 可用时的库；加密 / 失败 / 打开中为 null（各入口据此报不可用）。
  SrsDbStore? get store => state == ServerSrsProfileState.ready ? _store : null;
  SrsMediaStore? get media =>
      state == ServerSrsProfileState.ready ? _media : null;

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
    final SrsLocationBackend backend = SrsLocationBackend(
      LocalDirectoryAssetStore(_owner.syncRoot),
    );
    final String key = _owner.directoryKey;
    try {
      final SrsSync2Report r = await srsRunLocationRound(
        backend,
        s,
        key,
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
    await _store?.retire<void>(
      () async {},
      reason: 'profile $uid is no longer served by fushi_server',
    );
    _store = null;
    _media = null;
  }

  Map<String, Object?> toJson({required bool isDefault}) => <String, Object?>{
    'uid': uid,
    'name': name,
    'notes': noteCount,
    'state': state.wire,
    'default': isDefault,
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
    'lastError': lastError,
  };
}

/// 加密握手没过的原因（[srsLocationHandshake]）：v1 一律当「位置加密了，不提供」。
const Set<String> kServerSrsCryptoErrors = <String>{
  kSrsSync2NeedsKey,
  kSrsSync2WrongKey,
  kSrsSync2EncryptionMissing,
  kSrsSync2BadKdf,
};

/// 同一条连接上几份 profile 的副本：独占区（跨多个 await 的事务）彼此不能交错，共用一把进程内锁。
class _SharedExclusive implements SrsExclusiveOuter {
  Future<void> _tail = Future<void>.value();
  static final Object _zoneKey = Object();

  @override
  Future<T> run<T>(Future<T> Function() body) {
    if (identical(Zone.current[_zoneKey], this)) return body();
    final Completer<void> done = Completer<void>();
    final Future<void> prev = _tail;
    _tail = done.future;
    return prev
        .then(
          (_) => runZoned(body, zoneValues: <Object, Object>{_zoneKey: this}),
        )
        .whenComplete(done.complete);
  }
}

/// 一次只跑一个（各份 profile 的同步轮次共用）。
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
  }) : syncRoot = Directory(
         p.join(syncData.path, 'sync-data', kSyncRootFolderName),
       ),
       directoryKey = srsInterconnectDirectoryKey(hostId),
       _config = config,
       _engineFactory = engine ?? FfiFsrsEngine.tryCreate,
       _onPublishedCb = onPublished;

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

  SrsStorage? _storage;
  FsrsEngine? _engine;
  final Map<String, ServerSrsProfile> _profiles = <String, ServerSrsProfile>{};
  final _SharedExclusive _exclusive = _SharedExclusive();
  final _SerialQueue _rounds = _SerialQueue();
  Timer? _safety;
  Future<void> _ops = Future<void>.value();
  bool _stopped = false;

  /// 某份 profile 的库有变化（WebUI / 统计重读用；测试也听它）。
  final StreamController<String> changes = StreamController<String>.broadcast();

  /// 远程复习（`/api/srs/remote/*`）：没有可用的 profile 时 null（端点 404、能力位不报）。
  SrsRemoteStoreService? get remoteStore =>
      readyProfiles.isEmpty ? null : _remote;

  late final SrsRemoteStoreService _remote = SrsRemoteStoreService(
    readStore: () async => storeFor(null),
    readProfile: (String uid) async => storeFor(uid),
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

  /// [uid] 那份的制卡器（[deckId] 空 = 配置里那份的制卡牌组，再空 = 内置默认牌组）。
  SrsMiner? minerFor(String uid, {String? deckId}) {
    final ServerSrsProfile? prof = _profiles[uid];
    final SrsDbStore? s = prof?.store;
    final SrsMediaStore? m = prof?.media;
    if (s == null || m == null) return null;
    final String deck = (deckId ?? '').isNotEmpty
        ? deckId!
        : (_config().miningDecks[uid] ?? '');
    return SrsMiner(
      store: s,
      media: m,
      destination: SrsMiningDestination(deckId: deck),
    );
  }

  /// 起：按配置打开各份 profile，各跑一轮，挂兜底定时器。复习关（没选 profile）时什么都不开。
  Future<void> start() => _serial(() async {
    _stopped = false;
    await _reconcile();
    _safety?.cancel();
    _safety = Timer.periodic(kServerSrsSafetyInterval, (_) {
      for (final ServerSrsProfile prof in profiles) {
        unawaited(prof.syncNow());
      }
    });
  });

  /// 配置变了（WebUI / ctl）：新加的打开、去掉的关掉，不重启。
  Future<void> applyConfig() => _serial(_reconcile);

  Future<void> stop() => _serial(() async {
    _stopped = true;
    _safety?.cancel();
    _safety = null;
    for (final ServerSrsProfile prof in _profiles.values.toList()) {
      await prof._close();
    }
    _profiles.clear();
    await _storage?.close();
    _storage = null;
    if (!changes.isClosed) await changes.close();
  });

  Future<void> _serial(Future<void> Function() body) {
    final Future<void> next = _ops.then((_) => body());
    _ops = next.catchError((Object e, StackTrace st) {
      engineLog.log('ServerSrs', e, st);
    });
    return next;
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
    final SrsStorage storage = _storage ??= await SrsStorage.open(
      path: SrsStorage.pathIn(support.path),
    );
    _engine ??= _engineFactory();
    final Map<String, SrsRemoteProfile> found = await _discover();
    for (final String uid in wanted) {
      final ServerSrsProfile prof = _profiles[uid] ??= ServerSrsProfile._(
        uid,
        this,
      );
      final SrsRemoteProfile? info = found[uid];
      if (info != null) {
        prof.name = info.names.isEmpty ? '' : info.names.first;
        prof.noteCount = info.noteCount ?? 0;
      }
      if (prof._store != null) continue;
      try {
        prof._store = await SrsDbStore.open(
          db: storage.db,
          core: storage.core,
          profileUid: uid,
          deviceId: deviceId,
          engine: _engine,
          fallbackRolloverHour: () => _config().rolloverHour,
          styles: SrsStyleStore(SrsStyleStore.directoryFor(support, uid)),
          exclusiveOuter: _exclusive,
        );
        prof._media = SrsMediaStore(SrsMediaStore.directoryFor(support, uid));
      } catch (e, stack) {
        prof._setState(ServerSrsProfileState.failed, '$e');
        engineLog.log('ServerSrs.open', e, stack);
        continue;
      }
      // 第一轮跑完才知道位置是不是加密的；跑完之前不对外提供（不拿一份没收过数据的空库应答）。
      unawaited(prof.syncNow());
    }
  }

  /// 本机同步目录里有哪些 profile（WebUI 的勾选列表）。
  Future<List<SrsRemoteProfile>> discoverProfiles() async =>
      (await _discover()).values.toList();

  Future<Map<String, SrsRemoteProfile>> _discover() async {
    if (!syncRoot.existsSync()) return const <String, SrsRemoteProfile>{};
    try {
      final List<SrsRemoteProfile> list = await srsListRemoteProfiles(
        LocalDirectoryAssetStore(syncRoot),
      );
      return <String, SrsRemoteProfile>{
        for (final SrsRemoteProfile r in list) r.uid: r,
      };
    } catch (e, stack) {
      engineLog.log('ServerSrs.discover', e, stack);
      return const <String, SrsRemoteProfile>{};
    }
  }

  /// 已配对设备往本机同步目录写了文件（`FushiSyncServer.onClientWrite`）：是某份提供中的 profile 的复习数据就
  /// 去抖后同步那一份。
  void onClientWrite(String relativePath) {
    final String? uid = srsHostPathProfile(relativePath);
    if (uid == null) return;
    _profiles[uid]?.scheduleSync();
  }

  /// 已配对设备直接写了某台设备自己的段：用对端名给它补名字（老版本没有自报名字时同步页显示它）。
  final Map<String, String> _hinted = <String, String>{};

  Future<void> onClientUpload(String relativePath, String? peerName) async {
    if (peerName == null || peerName.isEmpty) return;
    final String? device = srsHostUploadedSegmentDevice(relativePath);
    final String? uid = srsHostPathProfile(relativePath);
    if (device == null || uid == null) return;
    final String key = '$uid/$device';
    if (_hinted[key] == peerName) return;
    _hinted[key] = peerName;
    try {
      await _profiles[uid]?._store?.sync2DeviceHint(device, peerName);
    } catch (e, stack) {
      _hinted.remove(key);
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
      'profiles': <Map<String, Object?>>[
        for (final ServerSrsProfile prof in profiles)
          prof.toJson(isDefault: prof.uid == def),
      ],
    };
  }
}
