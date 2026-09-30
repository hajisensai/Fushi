/// `/api/admin/*`：WebUI 的 JSON 面。鉴权在 [AdminServer] 的 middleware。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/anki_sync/anki_box_landing.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_library_prune.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart' show HostSubscriptionRejected;
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/admin/upload_store.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json; charset=utf-8'},
    );

shelf.Response _err(int status, String message) =>
    _json(<String, Object?>{'error': message}, status: status);

Future<Map<String, dynamic>> _body(shelf.Request request) async {
  final String text = await request.readAsString();
  if (text.isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('JSON object body required');
  return Map<String, dynamic>.from(decoded);
}

class AdminApi {
  AdminApi(this.ctx)
      : uploads = UploadStore(
          ledgerFile: File(p.join(ctx.paths.support.path, 'upload_ledger.json')),
          quotaBytes: ctx.config.uploadQuotaBytes,
        );

  final AdminContext ctx;
  final UploadStore uploads;

  Future<shelf.Response> handle(shelf.Request request) async {
    final String method = request.method.toUpperCase();
    final String path = '/${request.url.path}';
    try {
      // `return await`：async 函数里 `return future` 的错误不归外层 try 管。
      return await _route(method, path, request);
    } on FormatException catch (e) {
      return _err(400, e.message);
    } on UploadRejected catch (e) {
      return _err(e.status, e.message);
    } on VideoDownloadPipelineActionRequired catch (e) {
      return _err(409, e.message);
    } on HostSubscriptionRejected catch (e) {
      return _json(<String, Object?>{'error': e.message, 'reason': e.reason}, status: e.status);
    } catch (e, stack) {
      ctx.log.log('AdminApi $method $path', e, stack);
      return _err(500, '$e');
    }
  }

  Future<shelf.Response> _route(String method, String path, shelf.Request request) async {
    switch ((method, path)) {
      case ('GET', '/api/admin/status'):
        return _status();
      case ('GET', '/api/admin/logs'):
        return _json(<String, Object?>{'lines': ctx.log.recent});
      case ('GET', '/api/admin/pairing'):
        return _pairing();
      case ('DELETE', _) when path.startsWith('/api/admin/pairing/peers/'):
        return _revokePeer(Uri.decodeComponent(path.substring('/api/admin/pairing/peers/'.length)));
      case ('GET', '/api/admin/libraries'):
        return _libraries();
      case ('POST', '/api/admin/libraries'):
        return _addLibrary(await _body(request));
      case ('DELETE', _) when path.startsWith('/api/admin/libraries/'):
        return _removeLibrary(
          Uri.decodeComponent(path.substring('/api/admin/libraries/'.length)),
          purge: request.url.queryParameters['purge'] == 'true',
        );
      case ('POST', '/api/admin/scan'):
        return _scan(await _body(request));
      case ('GET', '/api/admin/jobs'):
        return _jobs();
      case ('DELETE', _) when path.startsWith('/api/admin/jobs/'):
        await ctx.host.jobs?.delete(path.substring('/api/admin/jobs/'.length));
        return _json(const <String, Object?>{'ok': true});
      case ('GET', '/api/admin/downloads'):
        return _downloads();
      case ('POST', '/api/admin/downloads'):
        return _addDownload(await _body(request));
      case ('POST', _) when path.startsWith('/api/admin/downloads/') && path.endsWith('/cancel'):
        await _downloadsHost().cancelJob(_segment(path, '/api/admin/downloads/', '/cancel'));
        return _json(const <String, Object?>{'ok': true});
      case ('POST', _) when path.startsWith('/api/admin/downloads/') && path.endsWith('/retry'):
        await _downloadsHost().retryJob(_segment(path, '/api/admin/downloads/', '/retry'));
        return _json(const <String, Object?>{'ok': true});
      case ('DELETE', _) when path.startsWith('/api/admin/downloads/'):
        await _downloadsHost().deleteJob(path.substring('/api/admin/downloads/'.length));
        return _json(const <String, Object?>{'ok': true});
      case ('GET', '/api/admin/subscriptions'):
        return _subscriptions();
      case ('POST', '/api/admin/subscriptions'):
        return _createSubscription(await _body(request));
      case ('POST', '/api/admin/subscriptions/check'):
        await _subscriptionsHost().checkNow(null);
        return _json(const <String, Object?>{'ok': true});
      case ('POST', _) when path.startsWith('/api/admin/subscriptions/') && path.endsWith('/enable'):
        final Map<String, dynamic> body = await _body(request);
        await _subscriptionsHost().setEnabled(
          _segment(path, '/api/admin/subscriptions/', '/enable'),
          body['enabled'] == true,
        );
        return _json(const <String, Object?>{'ok': true});
      case ('POST', _) when path.startsWith('/api/admin/subscriptions/') && path.endsWith('/check'):
        await _subscriptionsHost().checkNow(_segment(path, '/api/admin/subscriptions/', '/check'));
        return _json(const <String, Object?>{'ok': true});
      case ('DELETE', _) when path.startsWith('/api/admin/subscriptions/'):
        await _subscriptionsHost().delete(Uri.decodeComponent(path.substring('/api/admin/subscriptions/'.length)));
        return _json(const <String, Object?>{'ok': true});
      case ('GET', '/api/admin/models'):
        return _models();
      case ('POST', '/api/admin/models/pull'):
        return _pullModel(await _body(request));
      case ('GET', '/api/admin/settings'):
        return _settings();
      case ('PUT', '/api/admin/settings'):
        return _putSettings(await _body(request));
      case ('GET', '/api/admin/anki'):
        return _anki();
      case ('POST', '/api/admin/anki/login'):
        return _ankiLogin(await _body(request));
      case ('POST', '/api/admin/anki/logout'):
        final Map<String, dynamic> body = await _body(request);
        try {
          await _ankiSession().signOut(discardUnsynced: body['discardUnsynced'] == true);
        } on AnkiSyncHasUnsyncedNotes catch (e) {
          return _err(409, 'unsynced:${e.count}');
        }
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/sync'):
        final AnkiSyncState synced = await _ankiSession().syncNow();
        return _json(<String, Object?>{'phase': synced.phase.name});
      case ('POST', '/api/admin/anki/refresh'):
        return _json(<String, Object?>{'ok': await _ankiLanding().refreshMeta()});
      case ('PUT', '/api/admin/anki/settings'):
        return _putAnkiSettings(await _body(request));
      case ('POST', '/api/admin/anki/landing'):
        final Map<String, dynamic> body = await _body(request);
        await _ankiLanding().setLandingEnabled(body['enabled'] == true);
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/run'):
        await _ankiLanding().runNow();
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/retry'):
        return _json(<String, Object?>{'retried': await _ankiLanding().retryFailed()});
      case ('GET', '/api/admin/p2p'):
        return _json(ctx.host.p2pStatus());
      case ('GET', '/api/admin/upload'):
        return _uploadStatus(request);
      case ('PUT', '/api/admin/upload'):
        return _upload(request);
    }
    return _err(404, 'unknown admin route $method $path');
  }

  String _segment(String path, String prefix, String suffix) =>
      Uri.decodeComponent(path.substring(prefix.length, path.length - suffix.length));

  HostDownloadHost _downloadsHost() {
    final HostDownloadHost? d = ctx.host.downloads;
    if (d == null) throw const FormatException('downloads not available');
    return d;
  }

  // ── 状态 ─────────────────────────────────────────────────────────────

  Future<shelf.Response> _status() async {
    final List<FushiPairedPeerRow> peers = await ctx.db.getPairedPeers();
    final int videos = (await ctx.db.allVideoBooks()).length;
    final int books = (await ctx.db.getAllEpubBooks()).length;
    final MangaOcrModelStatus? ocr = await ctx.host.ocrService?.modelStatus();
    return _json(<String, Object?>{
      'deviceName': ctx.config.deviceName,
      'deviceId': ctx.identity.deviceId,
      'listen': '${ctx.config.bind}:${ctx.host.port}',
      'tls': ctx.config.tls,
      'fingerprint': ctx.host.hostFingerprint,
      'startedAt': ctx.startedAt.toIso8601String(),
      'uptimeSeconds': DateTime.now().difference(ctx.startedAt).inSeconds,
      'dataDir': ctx.config.dataDir,
      'videos': videos,
      'books': books,
      'peers': peers.length,
      'libraries': ctx.config.libraries.length,
      'scanning': ctx.scanning,
      'lastScan': ctx.lastScan?.toString(),
      'lastScanNotes': ctx.lastScan?.pruneNotes ?? const <String>[],
      'lastScanAt': ctx.lastScanAt?.toIso8601String(),
      'downloads': await ctx.host.downloads?.capability(),
      'subscriptions': await ctx.host.subscriptions?.capability(),
      'subscriptionCount': (await ctx.host.subscriptions?.list())?.length,
      'ocr': ocr == null
          ? null
          : <String, Object?>{
              'ready': ocr.allReady,
              'diskBytes': ocr.diskBytes,
              'totalBytes': ocr.totalBytes,
            },
      'uploadUsedBytes': await uploads.used(),
      'uploadQuotaBytes': ctx.config.uploadQuotaBytes,
      'p2p': ctx.host.p2pStatus(),
    });
  }

  // ── 配对 ─────────────────────────────────────────────────────────────

  Future<shelf.Response> _pairing() async {
    final PendingPairing? pending = ctx.host.pendingPairing;
    final List<FushiPairedPeerRow> peers = await ctx.db.getPairedPeers();
    return _json(<String, Object?>{
      'pending': pending == null
          ? null
          : <String, Object?>{
              'pin': pending.pin,
              'deviceName': pending.deviceName,
              'remoteAddress': pending.remoteAddress,
              'createdAt': pending.createdAt.toIso8601String(),
            },
      'peers': <Object?>[
        for (final FushiPairedPeerRow peer in peers)
          <String, Object?>{
            'peerId': peer.peerId,
            'deviceName': peer.deviceName,
            'lastSeenIp': peer.lastSeenIp,
            'pairedAtMs': peer.pairedAtMs,
          },
      ],
    });
  }

  Future<shelf.Response> _revokePeer(String peerId) async {
    final int n = await ctx.db.revokePairedPeer(peerId);
    ctx.host.invalidatePeerTokens();
    return _json(<String, Object?>{'ok': n > 0});
  }

  // ── 库 ─────────────────────────────────────────────────────────────

  shelf.Response _libraries() => _json(_librariesJson());

  Map<String, Object?> _librariesJson() => <String, Object?>{
        'libraries': <Object?>[
          for (final LibraryRootConfig lib in ctx.config.libraries)
            <String, Object?>{
              ...lib.toYamlMap(),
              'exists': Directory(lib.path).existsSync(),
            },
        ],
      };

  Future<shelf.Response> _addLibrary(Map<String, dynamic> body) async {
    final String path = (body['path'] ?? '').toString().trim();
    if (path.isEmpty) throw const FormatException('path required');
    final String kind = (body['kind'] ?? 'video').toString();
    if (kind != 'video' && kind != 'book') throw const FormatException('kind must be video or book');
    final String id = (body['id'] ?? '').toString().trim().isEmpty
        ? 'lib${DateTime.now().millisecondsSinceEpoch}'
        : body['id'].toString().trim();
    if (ctx.config.libraries.any((LibraryRootConfig l) => l.id == id)) {
      throw FormatException('library id "$id" already exists');
    }
    await Directory(path).create(recursive: true);
    await ctx.updateConfig(ctx.config.copyWith(libraries: <LibraryRootConfig>[
      ...ctx.config.libraries,
      LibraryRootConfig(id: id, path: p.normalize(p.absolute(path)), kind: kind),
    ]));
    return _libraries();
  }

  /// 移除一个库根。
  ///
  /// [purge] 为真时，**在移除配置前**对该根跑一次扫描对账（`pruneMissingVideoRows`），
  /// 回收「行还在、文件已消失」的条目及其刮削资料。不删任何文件；护栏与扫描对账
  /// 同一套（库根不存在 / 失效占比过高则拒绝，如实回报原因）。
  ///
  /// 只有 `video` 根支持：书 / 漫画根的行不记源文件路径，判不出失效。
  Future<shelf.Response> _removeLibrary(String id, {bool purge = false}) async {
    final LibraryRootConfig? library = ctx.config.libraries
        .cast<LibraryRootConfig?>()
        .firstWhere((LibraryRootConfig? l) => l!.id == id, orElse: () => null);
    if (library == null) return _err(404, 'unknown library $id');
    Map<String, Object?>? purgeResult;
    if (purge) {
      if (library.kind != 'video') {
        throw FormatException(
          'library "$id" is kind=${library.kind}; only video roots can be purged',
        );
      }
      final VideoPruneReport report = await pruneMissingVideoRows(
        repository: VideoBookRepository(ctx.db),
        root: Directory(library.path),
      );
      purgeResult = <String, Object?>{
        'considered': report.considered,
        'missing': report.missing,
        'deleted': report.deleted,
        'skipped': report.skipped,
        if (report.skipReason != null) 'reason': report.skipReason,
      };
    }
    await ctx.updateConfig(ctx.config.copyWith(
      libraries: ctx.config.libraries.where((LibraryRootConfig l) => l.id != id).toList(),
    ));
    return _json(<String, Object?>{
      ..._librariesJson(),
      if (purgeResult != null) 'purge': purgeResult,
    });
  }

  shelf.Response _scan(Map<String, dynamic> body) {
    final Object? raw = body['prune'];
    if (raw != null && raw is! bool) {
      throw const FormatException('prune must be a boolean');
    }
    if (ctx.scanning) return _json(const <String, Object?>{'started': false, 'scanning': true});
    // 不 await：扫描可能很久，WebUI 轮询 status 看结果。
    ctx.scanLibraries(prune: raw as bool?).catchError((Object e, StackTrace st) {
      ctx.log.log('AdminApi.scan', e, st);
      return ScanSummary();
    });
    return _json(const <String, Object?>{'started': true, 'scanning': true});
  }

  // ── 任务 / 下载 ─────────────────────────────────────────────────────

  shelf.Response _jobs() => _json(<String, Object?>{
        'jobs': ctx.host.jobs?.list().map((HostJobRecord r) => r.toWireJson()).toList() ?? const <Object?>[],
      });

  Future<shelf.Response> _downloads() async {
    final HostDownloadHost? d = ctx.host.downloads;
    if (d == null) return _json(const <String, Object?>{'supported': false, 'jobs': <Object?>[]});
    final Map<String, Object?> cap = await d.capability();
    return _json(<String, Object?>{
      ...cap,
      'jobs': (await d.listJobs()).map(videoDownloadJobToWire).toList(),
    });
  }

  Future<shelf.Response> _addDownload(Map<String, dynamic> body) async {
    final String magnet = (body['magnet'] ?? '').toString().trim();
    final String title = (body['title'] ?? '').toString().trim();
    if (magnet.isEmpty || title.isEmpty) throw const FormatException('magnet and title required');
    final String jobId = await _downloadsHost().addMagnet(
      magnetUri: magnet,
      title: title,
      mediaKind: (body['mediaKind'] ?? 'movie').toString() == 'tv' ? 'tv' : 'movie',
    );
    return _json(<String, Object?>{'jobId': jobId});
  }

  // ── 订阅 ─────────────────────────────────────────────────────────────

  HostSubscriptionHost _subscriptionsHost() {
    final HostSubscriptionHost? host = ctx.host.subscriptions;
    if (host == null) throw const FormatException('subscriptions not available');
    return host;
  }

  Future<shelf.Response> _subscriptions() async {
    final HostSubscriptionHost? host = ctx.host.subscriptions;
    if (host == null) return _json(const <String, Object?>{'supported': false, 'subscriptions': <Object?>[]});
    final Map<String, Object?> cap = await host.capability();
    final Map<String, Map<String, int>> counts = await host.itemCounts();
    return _json(<String, Object?>{
      ...cap,
      'subscriptions': <Object?>[
        for (final VideoDownloadSubscriptionRow r in await host.list())
          videoDownloadSubscriptionToWire(r, itemCounts: counts[r.subscriptionId]),
      ],
    });
  }

  Future<shelf.Response> _createSubscription(Map<String, dynamic> body) async {
    final VideoDownloadSubscriptionRow row =
        await _subscriptionsHost().create(HostSubscriptionCreateRequest.fromJson(body));
    return _json(<String, Object?>{'subscription': videoDownloadSubscriptionToWire(row)});
  }

  // ── 模型 ─────────────────────────────────────────────────────────────

  Map<String, Object?>? _modelsCache;
  DateTime _modelsCacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<shelf.Response> _models() async {
    // plan() 每种语言都要探一次 ORT provider；WebUI 2.5s 轮询下别每次都探。
    final bool fresh = DateTime.now().difference(_modelsCacheAt) < const Duration(seconds: 5);
    if (_modelsCache != null && fresh && _pulling.isEmpty) return _json(_modelsCache!);
    final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
    final List<Object?> asrModels = <Object?>[];
    for (final asr.AsrLanguage language in asr.AsrLanguage.registered) {
      try {
        final asr.AsrTranscribePlan plan =
            await service.plan(language: language, preference: asr.AsrAccelerationPreference.auto);
        asrModels.add(<String, Object?>{
          'tag': language.tag,
          'name': language.nativeName,
          'ready': plan.modelReady,
          'variant': plan.variant.name,
          'provider': plan.expectedProvider.name,
          'obtainedBytes': plan.modelStatus.obtainedBytes,
          'totalBytes': plan.modelStatus.totalBytes,
          'pulling': _pulling.contains(language.tag),
        });
      } catch (e) {
        asrModels.add(<String, Object?>{'tag': language.tag, 'name': language.nativeName, 'error': '$e'});
      }
    }
    final MangaOcrModelStatus? ocr = await ctx.host.ocrService?.modelStatus();
    _modelsCacheAt = DateTime.now();
    return _json(_modelsCache = <String, Object?>{
      'asr': asrModels,
      'ocr': ocr == null
          ? null
          : <String, Object?>{
              'ready': ocr.allReady,
              'obtainedBytes': ocr.obtainedBytes,
              'diskBytes': ocr.diskBytes,
              'totalBytes': ocr.totalBytes,
              'pulling': _pulling.contains('ocr'),
            },
    });
  }

  final Set<String> _pulling = <String>{};

  Future<shelf.Response> _pullModel(Map<String, dynamic> body) async {
    final String which = (body['model'] ?? '').toString();
    if (which.isEmpty) throw const FormatException('model required (asr language tag or "ocr")');
    if (_pulling.contains(which)) return _json(const <String, Object?>{'started': false, 'pulling': true});
    _pulling.add(which);
    Future<void> run() async {
      try {
        if (which == 'ocr') {
          final MangaOcrService? ocr = ctx.host.ocrService;
          if (ocr == null) throw StateError('ocr service unavailable');
          await for (final MangaOcrDownloadEvent _ in ocr.downloadModels()) {}
        } else {
          final asr.AsrLanguage? language = asr.AsrLanguage.fromTag(which);
          if (language == null) throw FormatException('unknown language $which');
          final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
          final asr.AsrTranscribePlan plan =
              await service.plan(language: language, preference: asr.AsrAccelerationPreference.auto);
          await for (final asr.ModelDownloadEvent _
              in service.downloadModel(language: language, variant: plan.variant)) {}
        }
        ctx.log.info('model pull done: $which');
      } catch (e, st) {
        ctx.log.log('AdminApi.pullModel($which)', e, st);
      } finally {
        _pulling.remove(which);
      }
    }

    // 后台跑，WebUI 轮询 /models 看 obtainedBytes。
    run();
    return _json(const <String, Object?>{'started': true, 'pulling': true});
  }

  // ── 设置 ─────────────────────────────────────────────────────────────

  shelf.Response _settings() => _json(<String, Object?>{
        'deviceName': ctx.config.deviceName,
        'port': ctx.config.port,
        'bind': ctx.config.bind,
        'tls': ctx.config.tls,
        'lanRequiresPin': ctx.config.lanRequiresPin,
        'subtitleLanguage': ctx.config.subtitleLanguage,
        'metadataLocale': ctx.config.metadataLocale,
        'ffmpeg': ctx.config.ffmpegPath,
        'ffprobe': ctx.config.ffprobePath,
        'onnxruntimeLibrary': ctx.config.ortLibraryPath,
        'uploadQuotaBytes': ctx.config.uploadQuotaBytes,
        'adminPort': ctx.config.adminPort,
        'qbittorrent': <String, Object?>{
          'url': ctx.config.qbittorrentUrl,
          'username': ctx.config.qbittorrentUsername,
          'passwordSet': (ctx.config.qbittorrentPassword ?? '').isNotEmpty,
        },
        'torrent': <String, Object?>{
          'engine': ctx.config.torrentEngine,
          'library': ctx.config.torrentLibraryPath,
          'listen': ctx.config.torrentListen,
          'embeddedLibraryFound': locateBundledLibrary(torrentLibraryName()),
        },
        // 远程可达三项：保存即生效，不在 restartRequiredKeys 里。
        'publicUrls': ctx.config.publicUrls,
        'p2p': ctx.config.p2p,
        'p2pRelays': ctx.config.p2pRelays,
        'p2pStatus': ctx.host.p2pStatus(),
        'restartRequiredKeys': const <String>['port', 'bind', 'tls', 'adminPort', 'qbittorrent', 'torrent', 'onnxruntimeLibrary', 'ffmpeg', 'ffprobe'],
      });

  Future<shelf.Response> _putSettings(Map<String, dynamic> body) async {
    final Map<String, dynamic>? qb = body['qbittorrent'] is Map ? Map<String, dynamic>.from(body['qbittorrent'] as Map) : null;
    final Map<String, dynamic>? torrent = body['torrent'] is Map ? Map<String, dynamic>.from(body['torrent'] as Map) : null;
    final String? engine = torrent?['engine']?.toString();
    if (engine != null &&
        engine != ServerConfig.torrentEngineAuto &&
        engine != ServerConfig.torrentEngineEmbedded &&
        engine != ServerConfig.torrentEngineQbittorrent) {
      throw FormatException('torrent.engine must be auto / embedded / qbittorrent, got "$engine"');
    }
    final List<String>? publicUrls = _remoteUrls(body, 'publicUrls');
    final List<String>? p2pRelays = _remoteUrls(body, 'p2pRelays');
    final Object? p2pRaw = body['p2p'];
    if (p2pRaw != null && p2pRaw is! bool) throw const FormatException('p2p must be a boolean');
    final bool? p2p = p2pRaw as bool?;
    // 只拦「从关到开」：原本就开着（手写 yaml）时照常能保存别的项、也能关掉。
    if (p2p == true && !ctx.config.p2p && !ctx.host.p2pAvailable) {
      return _json(<String, Object?>{
        'error': 'P2P 隧道不可用：没找到 libfushi_p2p（放在 bin/../lib/ 或设 FUSHI_P2P_LIB）',
        'reason': 'p2p_unavailable',
      }, status: 409);
    }
    final ServerConfig next = ctx.config.copyWith(
      deviceName: body['deviceName']?.toString(),
      port: body['port'] is num ? (body['port'] as num).toInt() : null,
      bind: body['bind']?.toString(),
      tls: body['tls'] is bool ? body['tls'] as bool : null,
      lanRequiresPin: body['lanRequiresPin'] is bool ? body['lanRequiresPin'] as bool : null,
      subtitleLanguage: body['subtitleLanguage']?.toString(),
      metadataLocale: body['metadataLocale']?.toString(),
      ffmpegPath: body['ffmpeg']?.toString(),
      ffprobePath: body['ffprobe']?.toString(),
      ortLibraryPath: body['onnxruntimeLibrary']?.toString(),
      uploadQuotaBytes: body['uploadQuotaBytes'] is num ? (body['uploadQuotaBytes'] as num).toInt() : null,
      adminPort: body['adminPort'] is num ? (body['adminPort'] as num).toInt() : null,
      qbittorrentUrl: qb?['url']?.toString(),
      qbittorrentUsername: qb?['username']?.toString(),
      qbittorrentPassword: (qb?['password'] ?? '').toString().isEmpty ? null : qb!['password'].toString(),
      torrentEngine: engine,
      torrentLibraryPath: torrent?['library']?.toString(),
      torrentListen: (torrent?['listen'] ?? '').toString().isEmpty ? null : torrent!['listen'].toString(),
      publicUrls: publicUrls,
      p2p: p2p,
      p2pRelays: p2pRelays,
    );
    await ctx.updateConfig(next);
    return _settings();
  }

  /// `publicUrls` / `p2pRelays`：缺省 = 不改；否则必须是字符串数组，逐条去空白、
  /// 去空行、去重，任一条不合法整个请求 400（不落半截）。
  static List<String>? _remoteUrls(Map<String, dynamic> body, String key) {
    final Object? raw = body[key];
    if (raw == null) return null;
    if (raw is! List) throw FormatException('$key must be an array of URLs');
    final List<String> urls = <String>[];
    for (final Object? item in raw) {
      if (item is! String) throw FormatException('$key must be an array of URLs');
      final String url = item.trim();
      if (url.isEmpty || urls.contains(url)) continue;
      final String? problem = ServerConfig.remoteUrlProblem(url);
      if (problem != null) throw FormatException('$key: "$url" $problem');
      urls.add(url);
    }
    return urls;
  }

  // ── 上传 ─────────────────────────────────────────────────────────────

  LibraryRootConfig _libraryFor(shelf.Request request) {
    final String? id = request.url.queryParameters['library'];
    final LibraryRootConfig? lib = ctx.config.libraries
        .cast<LibraryRootConfig?>()
        .firstWhere((LibraryRootConfig? l) => l!.id == id, orElse: () => null);
    if (lib == null) throw const UploadRejected(404, 'unknown library');
    return lib;
  }

  Future<shelf.Response> _uploadStatus(shelf.Request request) async {
    final LibraryRootConfig lib = _libraryFor(request);
    final String target = UploadStore.resolveTarget(lib, request.url.queryParameters['path'] ?? '');
    return _json(<String, Object?>{'received': await uploads.received(target)});
  }

  Future<shelf.Response> _upload(shelf.Request request) async {
    final LibraryRootConfig lib = _libraryFor(request);
    final String target = UploadStore.resolveTarget(lib, request.url.queryParameters['path'] ?? '');
    final ({int start, int? total})? range = parseContentRange(request.headers['content-range']);
    final ({int received, bool complete}) r = await uploads.putChunk(
      target: target,
      body: request.read(),
      rangeStart: range?.start,
      total: range?.total,
      declaredLength: request.contentLength ?? 0,
    );
    if (r.complete) ctx.log.info('upload complete: $target');
    return _json(<String, Object?>{'received': r.received, 'complete': r.complete});
  }

  // ── Anki 落地 ─────────────────────────────────────────────────────

  ServerAnkiLanding _ankiLanding() {
    final ServerAnkiLanding? anki = ctx.host.anki;
    if (anki == null) throw const FormatException('the interconnect host is not running');
    return anki;
  }

  AnkiSyncSession _ankiSession() {
    final AnkiSyncSession? session = _ankiLanding().session;
    if (session == null) {
      throw const FormatException('fushi-anki-sync is not bundled with this server');
    }
    return session;
  }

  Future<shelf.Response> _anki() async {
    final ServerAnkiLanding anki = _ankiLanding();
    final AnkiSyncSession? session = anki.session;
    final AnkiSyncAccount? account = await session?.account();
    final AnkiSyncState? state = session == null ? null : await session.refresh();
    final AnkiSettings s = anki.settings;
    final AnkiNoteType? noteType = s.availableNoteTypes
        .where((AnkiNoteType t) => t.name == s.selectedNoteTypeName)
        .firstOrNull;
    int pending = 0;
    int failed = 0;
    for (final PendingMineRow row in await anki.store.all()) {
      if (row.status == PendingMineStatus.failed) {
        failed++;
      } else {
        pending++;
      }
    }
    final AnkiBoxLandingReport? r = anki.lastReport;
    return _json(<String, Object?>{
      'available': anki.available,
      'account': account == null
          ? null
          : <String, Object?>{
              'server': account.server,
              'endpoint': account.endpoint,
              'username': account.username,
            },
      'sync': state == null
          ? null
          : <String, Object?>{
              'phase': state.phase.name,
              'unsynced': state.unsynced,
              'failing': state.failing,
              'lastError': state.lastError,
              'lastSyncAt': state.lastSyncAt,
              'message': state.message,
            },
      'landing': <String, Object?>{
        'enabled': anki.landingEnabled,
        'pending': pending,
        'failed': failed,
        'lastRunAt': anki.lastRunAt,
        'lastError': anki.lastError,
        'lastReport': r == null
            ? null
            : <String, Object?>{
                'received': r.received,
                'delivered': r.delivered,
                'failed': r.failed,
                'waiting': r.waiting,
              },
      },
      'settings': <String, Object?>{
        'decks': <String>[for (final AnkiDeck d in s.availableDecks) d.name],
        'noteTypes': <String>[for (final AnkiNoteType t in s.availableNoteTypes) t.name],
        'deck': s.selectedDeckName,
        'noteType': s.selectedNoteTypeName,
        'fields': noteType?.fields ?? const <String>[],
        'fieldMappings': s.fieldMappings,
        'tags': s.tags,
      },
      'placeholders': AnkiHandlebarOptions.coreOptions,
    });
  }

  Future<shelf.Response> _ankiLogin(Map<String, dynamic> body) async {
    final String server = (body['endpoint'] as String? ?? '').trim();
    final String username = (body['username'] as String? ?? '').trim();
    final String password = body['password'] as String? ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const FormatException('username and password are required');
    }
    // AnkiWeb 的条款只允许官方客户端；WebUI 先让用户确认风险再带上这一位。
    if (server.isEmpty && body['acceptAnkiWeb'] != true) {
      throw const FormatException('confirm the AnkiWeb risk first');
    }
    try {
      await _ankiSession().signIn(
        endpoint: server.isEmpty ? null : server,
        username: username,
        password: password,
      );
    } on AnkiSyncHasUnsyncedNotes catch (e) {
      return _err(409, '${e.count} card(s) have not synced yet; sync them before switching account');
    }
    await _ankiLanding().refreshMeta();
    return _json(const <String, Object?>{'ok': true});
  }

  Future<shelf.Response> _putAnkiSettings(Map<String, dynamic> body) async {
    final ServerAnkiLanding anki = _ankiLanding();
    final AnkiSettings current = anki.settings;
    AnkiSettings next = current;
    final Object? deck = body['deck'];
    if (deck is String) {
      final AnkiDeck? d = current.availableDecks.where((AnkiDeck x) => x.name == deck).firstOrNull;
      if (d == null) throw FormatException('unknown deck $deck');
      next = next.copyWith(selectedDeckId: d.id, selectedDeckName: d.name);
    }
    final Object? noteType = body['noteType'];
    if (noteType is String) {
      final AnkiNoteType? t =
          current.availableNoteTypes.where((AnkiNoteType x) => x.name == noteType).firstOrNull;
      if (t == null) throw FormatException('unknown note type $noteType');
      next = next.copyWith(
        selectedNoteTypeId: t.id,
        selectedNoteTypeName: t.name,
        // 换了笔记类型：只保留新类型里还有的字段的映射，旧字段名不带过去。
        fieldMappings: <String, String>{
          for (final MapEntry<String, String> e in next.fieldMappings.entries)
            if (t.fields.contains(e.key)) e.key: e.value,
        },
      );
    }
    final Object? mappings = body['fieldMappings'];
    if (mappings is Map) {
      next = next.copyWith(
        fieldMappings: <String, String>{
          for (final MapEntry<Object?, Object?> e in mappings.entries)
            if (e.key is String && e.value is String) e.key! as String: e.value! as String,
        },
      );
    }
    final Object? tags = body['tags'];
    if (tags is String) next = next.copyWith(tags: tags);
    await anki.saveSettings(next);
    // 刚配好：等着的卡立刻落一轮。
    unawaited(anki.runNow());
    return _json(const <String, Object?>{'ok': true});
  }
}
