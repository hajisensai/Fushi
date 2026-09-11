/// `/api/admin/*`：WebUI 的 JSON 面。鉴权在 [AdminServer] 的 middleware。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart' show HostSubscriptionRejected;
import 'package:fushi_server/src/admin/admin_context.dart';
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
        return _removeLibrary(Uri.decodeComponent(path.substring('/api/admin/libraries/'.length)));
      case ('POST', '/api/admin/scan'):
        return _scan();
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

  shelf.Response _libraries() => _json(<String, Object?>{
        'libraries': <Object?>[
          for (final LibraryRootConfig lib in ctx.config.libraries)
            <String, Object?>{
              ...lib.toYamlMap(),
              'exists': Directory(lib.path).existsSync(),
            },
        ],
      });

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

  Future<shelf.Response> _removeLibrary(String id) async {
    await ctx.updateConfig(ctx.config.copyWith(
      libraries: ctx.config.libraries.where((LibraryRootConfig l) => l.id != id).toList(),
    ));
    return _libraries();
  }

  shelf.Response _scan() {
    if (ctx.scanning) return _json(const <String, Object?>{'started': false, 'scanning': true});
    // 不 await：扫描可能很久，WebUI 轮询 status 看结果。
    ctx.scanLibraries().catchError((Object e, StackTrace st) {
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
    );
    await ctx.updateConfig(next);
    return _settings();
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
}
