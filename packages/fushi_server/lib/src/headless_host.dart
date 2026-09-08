/// 无头 host：把引擎里的互联服务器、本地库服务、远程 OCR 任务管理器、TLS 身份、
/// 配对回调和 mDNS 广播组装成一个可 start/stop 的进程级对象。
///
/// 与 app 的 `FushiSyncServerController._startOrchestration` 一一对应：
/// 同一份 `FushiSyncServer`、同一份 `LocalLibraryHostService`、同一份
/// `MangaOcrHostJobManager`，区别只在回调的实现（没有 UI：PIN 打到日志与 WebUI、
/// 审批以 PIN 为准）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_engine/asr/asr_host_job_runner.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/override_title_db.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/lan_advertiser.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;

/// 当前待输入的配对 PIN（无头进程的「审批弹窗」：CLI 日志 + WebUI 状态）。
class PendingPairing {
  const PendingPairing({
    required this.pin,
    required this.deviceName,
    required this.remoteAddress,
    required this.createdAt,
  });

  final String pin;
  final String? deviceName;
  final String? remoteAddress;
  final DateTime createdAt;
}

/// 串行化库变动（对应 app 的 `runExclusiveWithSync`）。
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() body) {
    final Completer<void> done = Completer<void>();
    final Future<void> prev = _tail;
    _tail = done.future;
    return prev.then((_) => body()).whenComplete(done.complete);
  }
}

class HeadlessHost {
  HeadlessHost({
    required this.config,
    required this.paths,
    required this.db,
    required this.prefs,
    required this.identity,
  });

  final ServerConfig config;
  final ServerPaths paths;
  final FushiDatabase db;
  final ServerPrefs prefs;
  final ServerIdentity identity;

  FushiSyncServer? _server;
  LanAdvertiser? _advertiser;
  MangaOcrServiceImpl? _ocrService;
  HostJobManager? _jobs;
  ServerDownloadHost? _downloads;
  final _AsyncMutex _mutex = _AsyncMutex();
  PendingPairing? _pendingPairing;
  String? _hostFingerprint;
  SecurityContext? _securityContext;

  /// 给 CLI / WebUI 看的状态。
  PendingPairing? get pendingPairing => _pendingPairing;
  String? get hostFingerprint => _hostFingerprint;

  /// 互联端口用的 TLS 上下文；admin 端口复用同一份自签证书。
  SecurityContext? get securityContext => _securityContext;
  bool get isRunning => _server != null;
  int get port => _server?.port ?? config.port;
  MangaOcrServiceImpl? get ocrService => _ocrService;
  HostJobManager? get jobs => _jobs;
  ServerDownloadHost? get downloads => _downloads;
  HostSubscriptionHost? get subscriptions => _downloads?.subscriptions;

  /// 吊销 peer 后让服务器重读 token 集（否则旧 token 还在缓存里能用到重启）。
  void invalidatePeerTokens() => _server?.invalidatePeerTokenCache();

  /// 配对 PIN 出现/消失时的观察者（WebUI SSE、CLI 打印）。
  final StreamController<PendingPairing?> pairingEvents =
      StreamController<PendingPairing?>.broadcast();

  Future<void> start() async {
    if (_server != null) return;
    await paths.ensureLayout();

    SecurityContext? securityContext;
    if (config.tls) {
      final FushiTlsIdentity tlsIdentity =
          await FushiTlsIdentityStore(dataDir: paths.syncData.path)
              .loadOrCreate();
      securityContext = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(tlsIdentity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(tlsIdentity.privateKeyPem));
      _hostFingerprint = tlsIdentity.fingerprintSha256;
    }
    _securityContext = securityContext;

    final MangaOcrServiceImpl ocrService = MangaOcrServiceImpl();
    _ocrService = ocrService;
    final MangaOcrHostJobManager ocrJobs = MangaOcrHostJobManager(
      service: ocrService,
      jobRoot: paths.mangaOcrJobs,
    );

    // 通用任务（第 1 期：ASR）。任务目录持久化，重启可续。
    final HostJobManager jobs = HostJobManager(
      jobRoot: paths.hostJobs,
      runners: <HostJobRunner>[
        AsrHostJobRunner(
          serviceFactory: createServerAsrTranscriptionService,
          resolveVideoPath: _resolveVideoPath,
        ),
      ],
    );
    await jobs.load();
    _jobs = jobs;

    // 代下载（第 2 期）：qBittorrent 配了才起管线；没配也挂接口，能力位如实报 supported=false。
    final ServerDownloadHost downloads = ServerDownloadHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
    );
    await downloads.start();
    _downloads = downloads;

    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: paths.syncData.path,
      port: config.port,
      token: identity.hostToken,
      allowLan: config.bind != '127.0.0.1' && config.bind != 'localhost',
      libraryService: _buildLibraryService(),
      mangaOcrJobs: ocrJobs,
      hostJobs: jobs,
      downloads: downloads,
      subscriptions: downloads.subscriptions,
      securityContext: securityContext,
      hostFingerprint: _hostFingerprint,
      deviceName: config.deviceName,
    )
      ..onPairRequest = _approvePairing
      ..onPairPinGenerated = _generatePin
      ..onPairSessionResolved = _clearPendingPairing
      ..lanRequiresPinProvider = (() async => config.lanRequiresPin)
      ..onPeerPaired = _persistPairedPeer
      ..pairedPeerTokensProvider = _loadPairedPeerTokens;
    await server.start();
    _server = server;

    _advertiser = LanAdvertiser(
      deviceName: config.deviceName,
      deviceId: identity.deviceId,
      port: server.port,
      tlsEnabled: securityContext != null,
    );
    await _advertiser!.start();
    engineLog.logDiagnostic(
      'HeadlessHost',
      'listening on ${config.bind}:${server.port} '
          '(${securityContext != null ? 'https' : 'http'}, device=${config.deviceName})',
    );
  }

  Future<void> stop() async {
    final LanAdvertiser? adv = _advertiser;
    _advertiser = null;
    await adv?.stop();
    final FushiSyncServer? server = _server;
    _server = null;
    await server?.stop();
    final ServerDownloadHost? downloads = _downloads;
    _downloads = null;
    await downloads?.stop();
    await pairingEvents.close();
  }

  // ── 配对回调 ──────────────────────────────────────────────────────────

  /// 无头进程没有「允许/拒绝」按钮：要 PIN 的会话，PIN 本身就是人因（谁能读到
  /// 服务端日志/WebUI 上的 PIN 谁才配得上）；免 PIN 会话只在配置显式关掉
  /// `lan_requires_pin` 时放行。
  Future<bool> _approvePairing(FushiPairRequest request) async {
    if (request.pinRequired) return true;
    return !config.lanRequiresPin;
  }

  String _generatePin(FushiPairSession session) {
    final String pin = FushiPairingProtocol.generatePin();
    final PendingPairing pending = PendingPairing(
      pin: pin,
      deviceName: session.deviceName,
      remoteAddress: session.remoteAddress,
      createdAt: DateTime.now(),
    );
    _pendingPairing = pending;
    // PIN 是敏感值，但它的存在意义就是给操作服务端的人读：打到 stdout（日志文件
    // 也记，与 app 在屏幕上显示同级）。
    stdout.writeln(
      '[pair] ${session.deviceName ?? 'unknown device'} '
      '(${session.remoteAddress ?? '?'}) requests pairing — PIN: $pin',
    );
    pairingEvents.add(pending);
    return pin;
  }

  void _clearPendingPairing() {
    _pendingPairing = null;
    if (!pairingEvents.isClosed) pairingEvents.add(null);
  }

  Future<void> _persistPairedPeer(
      FushiPairedPeerRegistration registration) async {
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: registration.peerId,
      token: registration.token,
      pairedAtMs: DateTime.now().millisecondsSinceEpoch,
      deviceName: Value<String?>(registration.deviceName),
      lastSeenIp: Value<String?>(registration.remoteAddress),
    ));
    _server?.invalidatePeerTokenCache();
    engineLog.logDiagnostic(
      'HeadlessHost',
      'paired: ${registration.deviceName ?? registration.peerId}',
    );
  }

  Future<Set<String>> _loadPairedPeerTokens() async {
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    return peers.map((FushiPairedPeerRow r) => r.token).toSet();
  }

  /// `asr` 任务的 `videoId` → host 库里的视频文件（分集 0）。
  Future<String?> _resolveVideoPath(String videoId) async {
    final VideoBookRow? row = await VideoBookRepository(db).getByBookUid(videoId);
    if (row == null) return null;
    final File f = File(row.videoPath);
    return await f.exists() ? f.path : null;
  }

  // ── 库服务 ────────────────────────────────────────────────────────────

  LocalLibraryHostService _buildLibraryService() => LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: paths.dictionaryResources,
        packages: SyncAssetPackageService(db: db),
        // 第 0 期服务端不装词典 FFI 引擎，导入/删除词典只改 DB 与目录。
        refreshDictionaryCache: () async {},
        runExclusive: _mutex.run,
        importBookFromFile: (File bookFile) async {
          if (await isMangaPackage(bookFile)) {
            return importMangaPackageFile(
              db: db,
              file: bookFile,
              title: p.basenameWithoutExtension(bookFile.path),
            );
          }
          return EpubImporter.importFromPath(
            db: db,
            filePath: bookFile.path,
            fileName: p.basename(bookFile.path),
          );
        },
        localAudioStagingDir: paths.temp,
        audioDatabaseRoot: Directory(p.join(paths.documents.path, 'audiobooks')),
        videoSubtitleLangCode: config.subtitleLanguage,
        uploadedVideoRoot: Directory(p.join(paths.documents.path, 'remote_videos')),
        extractVideoCover: (
                {required String videoPath, required String bookUid}) =>
            extractVideoCover(videoPath: videoPath, bookUid: bookUid),
        // 书名覆盖：服务端没有 MediaSource 内存缓存，只写 DB（LWW 判据同 app）。
        adoptOverrideTitle: ({
          required String bookKey,
          required String title,
          required int updatedAt,
        }) =>
            adoptOverrideTitleInDb(
              db,
              bookKey: bookKey,
              title: title,
              updatedAt: updatedAt,
            ),
      );
}
