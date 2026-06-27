import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hibiki/src/media/video/video_subtitle_source.dart'
    show
        EmbeddedSubtitleTrack,
        extractEmbeddedSubtitleTrackFile,
        listEmbeddedSubtitleTracks,
        subtitleExtensionForCodec,
        subtitleFormatForCodec;
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Embedded WebDAV-style server used for device-to-device LAN sync.
///
/// SECURITY (HBK-AUDIT-011): transport is plain HTTP and auth is HTTP Basic,
/// so the bearer token travels in reversible base64 over the wire. This is
/// acceptable only on a trusted LAN, and is gated behind [_allowLan] — when
/// false (the default) the server binds to loopback only and is never exposed
/// to the network. Enabling LAN sync therefore requires an explicit opt-in.
///
/// The proper hardening (TLS with a token-pinned self-signed certificate, or
/// an HMAC challenge-response so the raw token is never transmitted) is a
/// coordinated server+client+discovery protocol change that must be designed
/// and verified on real devices; it is intentionally NOT bolted on here. Until
/// then, treat LAN sync as unencrypted and only use it on a network you trust.

/// A pairing attempt from a peer that POSTed /api/pair. Carries what the host
/// UI needs to identify the requester in its confirmation prompt.
class HibikiPairRequest {
  const HibikiPairRequest({
    required this.deviceName,
    required this.remoteAddress,
  });

  /// Self-reported name from the client (may be null/empty if not sent).
  final String? deviceName;

  /// Source IP of the TCP connection, or null when it can't be resolved.
  final String? remoteAddress;
}

/// Thrown by [HibikiSyncServer.start] when the requested port is already bound
/// by another process. Carries the [port] so the UI can name it.
class SyncServerPortInUseException implements Exception {
  SyncServerPortInUseException(this.port);
  final int port;
  @override
  String toString() => 'SyncServerPortInUseException: port $port is in use';
}

/// True when [e] reports "address already in use": errno 98 (Linux),
/// 10048 (Windows WSAEADDRINUSE) or 48 (macOS), with a message fallback for
/// platforms that omit a numeric code.
bool isAddressInUseError(SocketException e) {
  final int? code = e.osError?.errorCode;
  if (code == 98 || code == 10048 || code == 48) return true;
  // Fall back to the message: cross-process conflicts carry an errno above,
  // but a same-process re-bind raises Dart's "shared flag" guard with no code,
  // and some platforms phrase EADDRINUSE without a numeric code.
  final String message =
      '${e.osError?.message ?? ''} ${e.message}'.toLowerCase();
  return message.contains('address already in use') ||
      message.contains('address in use') ||
      message.contains('only one usage of each socket address') ||
      message.contains('shared flag to bind');
}

class HibikiSyncServer {
  HibikiSyncServer({
    required String syncDataDir,
    required int port,
    required String token,
    bool allowLan = false,
    HibikiRemoteLookupService? remoteLookupService,
    HibikiRemoteMiningService? miningService,
    HibikiRemoteHistoryService? historyService,
    HibikiLibraryHostService? libraryService,
    DateTime Function()? now,
  })  : syncDataDir = p.join(syncDataDir, 'sync-data'),
        _requestedPort = port,
        _token = token,
        _allowLan = allowLan,
        _remoteLookupService = remoteLookupService,
        _miningService = miningService,
        _historyService = historyService,
        _libraryService = libraryService,
        _now = now ?? DateTime.now;

  final String syncDataDir;
  final int _requestedPort;
  final String _token;
  final bool _allowLan;
  final HibikiRemoteLookupService? _remoteLookupService;
  final HibikiRemoteMiningService? _miningService;
  final HibikiRemoteHistoryService? _historyService;
  final HibikiLibraryHostService? _libraryService;
  final DateTime Function() _now;
  final Map<String, _RemoteAudioToken> _remoteAudioTokens =
      <String, _RemoteAudioToken>{};
  final Map<String, _VideoStreamToken> _videoStreamTokens =
      <String, _VideoStreamToken>{};
  HttpServer? _server;

  /// Interactive pairing approval. When a client POSTs /api/pair, the server
  /// asks the host UI via this callback (Bluetooth-style "device X wants to
  /// pair — allow?") and only hands out [_token] when it resolves true. While
  /// null (no UI wired), every pairing request is refused, so the raw token is
  /// never handed out without a deliberate human approval on the host device.
  Future<bool> Function(HibikiPairRequest request)? onPairRequest;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _requestedPort;

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> start() async {
    if (_server != null) return;
    // The WebDAV root maps to [syncDataDir]; materialise it up front so a
    // freshly enabled server answers PROPFIND on '/' with a 207 (an empty
    // collection) instead of a 404. The client's reachability probe PROPFINDs
    // the root and gates every other op — including the MKCOL that would
    // otherwise lazily create this dir — so without this a reachable,
    // correctly-authenticating host is reported as "No reachable Hibiki server
    // address", a chicken-and-egg deadlock that never bootstraps (BUG-035).
    // Deliberately outside the bind try/catch below: a read-only/permission
    // failure here should fail-fast and bubble to the caller's error handling
    // (sync_settings_schema._startServer catch-all) rather than masquerade as a
    // port-in-use error — and since it runs before serve(), a failure leaves no
    // half-bound socket to roll back.
    await Directory(syncDataDir).create(recursive: true);
    final handler = const shelf.Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(
        handler,
        _allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        _requestedPort,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) {
        if (request.method == 'OPTIONS') return innerHandler(request);
        // Pairing is the one unauthenticated route: the client has no token
        // yet — that is exactly what it is fetching. Gating is done by the
        // pairing window inside _handlePair, not by Basic auth.
        if (request.url.path == 'api/pair') return innerHandler(request);
        // Video stream paths are exempted from Basic auth to allow media_kit
        // to play via a plain URL. Token validation happens inside the handler.
        // Only the /stream sub-path is exempted; /streamurl, /subtitle, and the
        // video list still require Basic auth.
        if (_isVideoStreamPath(request.url.path)) return innerHandler(request);
        // Remote lookup audio file URLs are handed to platform audio players,
        // which issue a bare GET without Authorization. The lookup endpoint
        // stays authenticated; the file endpoint is guarded by an opaque,
        // short-lived in-memory id in _handleAudioFile.
        if (_isLookupAudioFilePath(request.url.path)) {
          return innerHandler(request);
        }
        final auth = request.headers['authorization'];
        if (auth == null || !_validateAuth(auth)) {
          return shelf.Response(401,
              headers: {'WWW-Authenticate': 'Basic realm="Hibiki Sync"'});
        }
        return innerHandler(request);
      };
    };
  }

  /// 判断 [urlPath]（即 request.url.path，不含前导 `/`）是否为视频流路径
  /// （`api/library/videos/<id>/stream`，id 非空，id 可含 `/`）。
  static bool _isVideoStreamPath(String urlPath) {
    const String prefix = 'api/library/videos/';
    const String suffix = '/stream';
    if (!urlPath.startsWith(prefix)) return false;
    if (!urlPath.endsWith(suffix)) return false;
    final String idPart =
        urlPath.substring(prefix.length, urlPath.length - suffix.length);
    return idPart.isNotEmpty;
  }

  static bool _isLookupAudioFilePath(String urlPath) =>
      urlPath == 'api/lookup/audio/file';

  bool _validateAuth(String header) {
    if (!header.startsWith('Basic ')) return false;
    try {
      final decoded = utf8.decode(base64Decode(header.substring(6)));
      final colonIdx = decoded.indexOf(':');
      if (colonIdx < 0) return false;
      final password = decoded.substring(colonIdx + 1);
      return _constantTimeEquals(
        Uint8List.fromList(utf8.encode(password)),
        Uint8List.fromList(utf8.encode(_token)),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    final len = a.length > b.length ? a.length : b.length;
    var result = a.length ^ b.length;
    for (var i = 0; i < len; i++) {
      result |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
    }
    return result == 0;
  }

  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    final method = request.method.toUpperCase();
    final reqPath = Uri.decodeFull('/${request.url.path}');
    if (reqPath == '/api/pair') {
      return _handlePair(request);
    }
    if (reqPath.startsWith('/api/lookup/')) {
      return _handleLookupApi(request, method, reqPath);
    }
    if (reqPath == '/api/mine') {
      if (method != 'POST') return shelf.Response(405);
      return _handleMine(request);
    }
    if (reqPath == '/api/capabilities') {
      if (method != 'GET') return shelf.Response(405);
      return _handleCapabilities();
    }
    if (reqPath == '/api/library/dictionaries' ||
        reqPath.startsWith('/api/library/dictionaries/')) {
      return _handleLibraryDictionaries(request, method, reqPath);
    }
    if (reqPath == '/api/library/books' ||
        reqPath.startsWith('/api/library/books/')) {
      return _handleLibraryBooks(request, method, reqPath);
    }
    if (reqPath == '/api/library/localaudio' ||
        reqPath.startsWith('/api/library/localaudio/')) {
      return _handleLibraryLocalAudio(request, method, reqPath);
    }
    if (reqPath == '/api/library/audiobooks' ||
        reqPath.startsWith('/api/library/audiobooks/')) {
      return _handleLibraryAudiobooks(request, method, reqPath);
    }
    if (reqPath == '/api/library/videos' ||
        reqPath.startsWith('/api/library/videos/')) {
      return _handleLibraryVideos(request, method, reqPath);
    }

    // 真实读写路径：只做词法规整、**保留原始大小写**。p.canonicalize 在
    // 大小写不敏感平台（Windows）会把整条路径小写化，这会让书文件夹名按宿主平台
    // 大小写折叠——同一本书在 Windows host 落成小写、在 Linux/Android host 保留原
    // 大小写，跨平台同步身份就此错位。故真实文件操作绝不能用 canonicalize 的结果。
    final fsPath = p.normalize(p.join(syncDataDir, reqPath.substring(1)));
    // 路径穿越围栏：canonicalize 的大小写折叠/符号链接解析只用于"是否逃出根目录"
    // 的判定，不参与真实读写，故对身份大小写无影响。
    final canonicalFsPath = p.canonicalize(fsPath);
    final canonicalRoot = p.canonicalize(syncDataDir);
    if (canonicalFsPath != canonicalRoot &&
        !canonicalFsPath.startsWith('$canonicalRoot${p.separator}')) {
      return shelf.Response.forbidden('Path traversal denied');
    }

    switch (method) {
      case 'PROPFIND':
        return _handlePropfind(request, reqPath, fsPath);
      case 'GET':
        return _handleGet(fsPath);
      case 'PUT':
        return _handlePut(request, fsPath);
      case 'MKCOL':
        return _handleMkcol(fsPath);
      case 'DELETE':
        return _handleDelete(fsPath);
      case 'HEAD':
        return _handleHead(fsPath);
      case 'OPTIONS':
        return shelf.Response.ok('', headers: {
          'Allow': 'OPTIONS, GET, POST, PUT, DELETE, MKCOL, PROPFIND, HEAD',
          'DAV': '1',
        });
      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handlePair(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    final Future<bool> Function(HibikiPairRequest)? approve = onPairRequest;
    // No UI wired to approve → never hand out the token unattended. A distinct
    // reason lets the client say "peer not ready" instead of "peer declined".
    if (approve == null) return _pairDenied('unavailable');
    String? name;
    final Map<String, dynamic>? body = await _readJsonObject(request);
    final String? reported = body?['name']?.toString().trim();
    if (reported != null && reported.isNotEmpty) name = reported;
    final bool approved = await approve(HibikiPairRequest(
      deviceName: name,
      remoteAddress: _remoteAddress(request),
    ));
    if (!approved) return _pairDenied('declined');
    return _jsonResponse(<String, dynamic>{'token': _token});
  }

  /// A 403 carrying a machine-readable [reason] ('declined' | 'unavailable') so
  /// the client can distinguish a real refusal from a peer that has no approval
  /// handler wired. Older peers reply with a plain-text body instead, which the
  /// client treats as 'unavailable'.
  shelf.Response _pairDenied(String reason) => shelf.Response(
        403,
        body: jsonEncode(<String, String>{'reason': reason}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// Source IP of the request's TCP connection, or null when shelf_io did not
  /// attach connection info (e.g. some test harnesses).
  static String? _remoteAddress(shelf.Request request) {
    final Object? info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return null;
  }

  Future<shelf.Response> _handleLookupApi(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (reqPath == '/api/lookup/dictionary') {
      if (method != 'POST') return shelf.Response(405);
      return _handleDictionaryLookup(request);
    }
    if (reqPath == '/api/lookup/audio') {
      if (method != 'POST') return shelf.Response(405);
      return _handleAudioLookup(request);
    }
    if (reqPath == '/api/lookup/audio/file') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _handleAudioFile(request, method == 'HEAD');
    }
    return shelf.Response.notFound('Not found');
  }

  Future<shelf.Response> _handleDictionaryLookup(shelf.Request request) async {
    final HibikiRemoteLookupService? service = _remoteLookupService;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');

    final String term = body['term']?.toString() ?? '';
    if (term.trim().isEmpty) {
      return _jsonResponse(<String, dynamic>{
        'type': 'dictionaryResult',
        'result': null,
        'popupJson': null,
      });
    }
    final bool wildcards = body['wildcards'] as bool? ?? false;
    final int maximumTerms = (body['maximumTerms'] as num?)?.toInt() ?? 10;
    final result = await service.searchDictionary(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
    );

    final HibikiRemoteHistoryService? hist = _historyService;
    if (result != null && hist != null && (body['record'] as bool? ?? false)) {
      hist.recordHistory(result);
    }

    return _jsonResponse(<String, dynamic>{
      'type': 'dictionaryResult',
      'result': result == null ? null : jsonDecode(result.toJson()),
      'popupJson': result?.popupJson,
    });
  }

  Future<shelf.Response> _handleAudioLookup(shelf.Request request) async {
    final HibikiRemoteLookupService? service = _remoteLookupService;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');

    final String expression = body['expression']?.toString() ?? '';
    final String reading = body['reading']?.toString() ?? '';
    if (expression.trim().isEmpty) return _audioMissResponse();

    final RemoteAudioLookup? lookup = await service.lookupAudio(
      expression: expression,
      reading: reading,
    );
    if (lookup == null) return _audioMissResponse();

    final String id = _generateAudioToken();
    _remoteAudioTokens[id] = _RemoteAudioToken(
      bytes: lookup.bytes,
      contentType: lookup.contentType,
      createdAt: _now(),
    );
    final Uri url = request.requestedUri.replace(
      path: '/api/lookup/audio/file',
      queryParameters: <String, String>{'id': id},
    );
    return _jsonResponse(<String, dynamic>{
      'type': 'audioResult',
      'url': url.toString(),
      'contentType': lookup.contentType,
    });
  }

  shelf.Response _handleAudioFile(shelf.Request request, bool headOnly) {
    _pruneAudioTokens();
    final String? id = request.url.queryParameters['id'];
    final _RemoteAudioToken? token = id == null ? null : _remoteAudioTokens[id];
    if (token == null) return shelf.Response.notFound('Not found');
    // TODO-766: 命中即续期。重置该 token 的时间戳，使其 5 分钟窗口从「最近一次被
    // 访问」起算，正在使用中的音频不会中途被 [_pruneAudioTokens] 清掉。
    token.createdAt = _now();
    return shelf.Response.ok(
      headOnly ? null : token.bytes,
      headers: <String, String>{
        'Content-Type': token.contentType,
        'Content-Length': '${token.bytes.length}',
      },
    );
  }

  shelf.Response _audioMissResponse() => _jsonResponse(<String, dynamic>{
        'type': 'audioResult',
        'url': null,
        'contentType': null,
      });

  Future<shelf.Response> _handleMine(shelf.Request request) async {
    final HibikiRemoteMiningService? svc = _miningService;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final dynamic rawFields = body['fields'];
    if (rawFields is! Map) return shelf.Response(400, body: 'Missing fields');
    final Map<String, String> fields = rawFields.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v?.toString() ?? ''));
    final String sentence =
        body['sentence']?.toString() ?? fields['sentence'] ?? '';
    final String result =
        await svc.mineEntry(fields: fields, sentence: sentence);
    return _jsonResponse(<String, dynamic>{'result': result});
  }

  shelf.Response _handleCapabilities() {
    final bool lib = _libraryService != null;
    return _jsonResponse(<String, dynamic>{
      'liveLibrary': <String, dynamic>{
        'dictionaries': lib,
        'books': lib,
        'audio': lib,
        'videos': lib,
      },
    });
  }

  Future<shelf.Response> _handleLibraryDictionaries(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/dictionaries') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteDictionaryInfo d in list) d.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    // 原先的 Uri.decodeComponent 调用会对已解码的 CJK 字符再次解析，
    // 导致 "Illegal percent encoding in URI"（Dart 不接受非 ASCII 作为
    // decodeComponent 输入）。直接 substring 即可得到正确的词典名。
    final String name = reqPath.substring('/api/library/dictionaries/'.length);
    if (name.isEmpty) {
      return shelf.Response.notFound('Missing dictionary name');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.  Dictionary names must
    // never contain path separators or dot-dot sequences; if they did they
    // could escape the dictionary resource root on the host (DELETE being the
    // most dangerous).  This single gate covers all three methods below.
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      return shelf.Response.forbidden('Invalid dictionary name');
    }

    switch (method) {
      case 'GET':
        File file;
        try {
          file = await svc.exportDictionary(name);
        } on StateError {
          return shelf.Response.notFound('Dictionary not found');
        }
        final int length = file.lengthSync();
        final Stream<List<int>> body = file.openRead().transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleDone: (EventSink<List<int>> out) {
                  out.close();
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {
                    // best-effort temp cleanup
                  }
                },
                handleError:
                    (Object e, StackTrace st, EventSink<List<int>> out) {
                  out.addError(e, st);
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {/* best-effort */}
                },
              ),
            );
        return shelf.Response.ok(body, headers: <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '$length',
        });

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_dict_in');
        final File tmp = File(p.join(tmpDir.path, '$name.hibikidict'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importDictionary(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteDictionary(name);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handleLibraryBooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/books') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteBookInfo> list = await svc.listBooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteBookInfo b in list)
            _remoteBookJsonForRequest(b, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    const String bookPrefix = '/api/library/books/';
    const String coverSuffix = '/cover';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(coverSuffix)) {
      if (method != 'GET') return shelf.Response(405);
      final String coverBookId = reqPath.substring(
          bookPrefix.length, reqPath.length - coverSuffix.length);
      if (coverBookId.isEmpty) {
        return shelf.Response.notFound('Missing book title');
      }
      if (coverBookId.contains('/') ||
          coverBookId.contains('\\') ||
          coverBookId.contains('..')) {
        return shelf.Response.forbidden('Invalid book title');
      }
      final File? cover = await _resolveBookCover(svc, coverBookId);
      if (cover == null) return shelf.Response.notFound('Book cover not found');
      return serveFileWithRange(cover, request);
    }

    // GET/PUT /api/library/books/<bookKey>/progress — 跨设备阅读进度（TODO-767）。
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    // 与 video /position 分支对称，但落 host 自己的 reader_positions DB（非 prefs）。
    const String progressSuffix = '/progress';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(progressSuffix)) {
      final String progressBookKey = reqPath.substring(
          bookPrefix.length, reqPath.length - progressSuffix.length);
      if (progressBookKey.isEmpty) {
        return shelf.Response.notFound('Missing book key');
      }
      if (progressBookKey.contains('/') ||
          progressBookKey.contains('\\') ||
          progressBookKey.contains('..')) {
        return shelf.Response.forbidden('Invalid book key');
      }
      switch (method) {
        case 'GET':
          final RemoteBookProgress progress =
              await svc.getBookProgress(progressBookKey);
          return shelf.Response.ok(
            jsonEncode(progress.toJson()),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          await svc.putBookProgress(
            progressBookKey,
            RemoteBookProgress.fromJson(json.cast<String, Object?>()),
          );
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    final String bookId = reqPath.substring(bookPrefix.length);
    if (bookId.isEmpty) {
      return shelf.Response.notFound('Missing book title');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.  Book titles must
    // never contain path separators or dot-dot sequences.
    if (bookId.contains('/') ||
        bookId.contains('\\') ||
        bookId.contains('..')) {
      return shelf.Response.forbidden('Invalid book title');
    }

    switch (method) {
      case 'GET':
        File file;
        try {
          file = await svc.exportBook(bookId);
        } on StateError {
          return shelf.Response.notFound('Book not found');
        }
        final int length = file.lengthSync();
        final Stream<List<int>> body = file.openRead().transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleDone: (EventSink<List<int>> out) {
                  out.close();
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {
                    // best-effort temp cleanup
                  }
                },
                handleError:
                    (Object e, StackTrace st, EventSink<List<int>> out) {
                  out.addError(e, st);
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {/* best-effort */}
                },
              ),
            );
        return shelf.Response.ok(body, headers: <String, String>{
          'Content-Type': 'application/epub+zip',
          'Content-Length': '$length',
        });

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_book_in');
        final File tmp = File(p.join(tmpDir.path, '$bookId.epub'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importBook(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteBook(bookId);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Map<String, Object?> _remoteBookJsonForRequest(
    RemoteBookInfo book,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = book.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(book.coverPath) != null) {
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        pathSegments: <String>[
          'api',
          'library',
          'books',
          book.downloadId,
          'cover',
        ],
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<File?> _resolveBookCover(
    HibikiLibraryHostService service,
    String bookId,
  ) async {
    final List<RemoteBookInfo> books = await service.listBooks();
    for (final RemoteBookInfo book in books) {
      if (book.downloadId == bookId || book.title == bookId) {
        return _coverFile(book.coverPath);
      }
    }
    return null;
  }

  Future<shelf.Response> _handleLibraryLocalAudio(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/localaudio') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteLocalAudioInfo> list = await svc.listLocalAudio();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteLocalAudioInfo a in list) a.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    final String displayName =
        reqPath.substring('/api/library/localaudio/'.length);
    if (displayName.isEmpty) {
      return shelf.Response.notFound('Missing displayName');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.
    if (displayName.contains('/') ||
        displayName.contains('\\') ||
        displayName.contains('..')) {
      return shelf.Response.forbidden('Invalid displayName');
    }

    switch (method) {
      case 'GET':
        File file;
        try {
          file = await svc.exportLocalAudio(displayName);
        } on StateError {
          return shelf.Response.notFound('Local audio not found');
        }
        final int length = file.lengthSync();
        final Stream<List<int>> body = file.openRead().transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleDone: (EventSink<List<int>> out) {
                  out.close();
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {
                    // best-effort temp cleanup
                  }
                },
                handleError:
                    (Object e, StackTrace st, EventSink<List<int>> out) {
                  out.addError(e, st);
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {/* best-effort */}
                },
              ),
            );
        return shelf.Response.ok(body, headers: <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '$length',
        });

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_localaudio_in');
        final File tmp = File(p.join(tmpDir.path, '$displayName.localaudio'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importLocalAudio(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteLocalAudio(displayName);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handleLibraryAudiobooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/audiobooks') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteAudiobookInfo ab in list) ab.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    final String bookKey = reqPath.substring('/api/library/audiobooks/'.length);
    if (bookKey.isEmpty) {
      return shelf.Response.notFound('Missing bookKey');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.
    if (bookKey.contains('/') ||
        bookKey.contains('\\') ||
        bookKey.contains('..')) {
      return shelf.Response.forbidden('Invalid bookKey');
    }

    switch (method) {
      case 'GET':
        File file;
        try {
          file = await svc.exportAudiobook(bookKey);
        } on StateError {
          return shelf.Response.notFound('Audiobook not found');
        }
        final int length = file.lengthSync();
        final Stream<List<int>> body = file.openRead().transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleDone: (EventSink<List<int>> out) {
                  out.close();
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {
                    // best-effort temp cleanup
                  }
                },
                handleError:
                    (Object e, StackTrace st, EventSink<List<int>> out) {
                  out.addError(e, st);
                  try {
                    file.parent.deleteSync(recursive: true);
                  } catch (_) {/* best-effort */}
                },
              ),
            );
        return shelf.Response.ok(body, headers: <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '$length',
        });

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_audiobook_in');
        final File tmp = File(p.join(tmpDir.path, '$bookKey.audiobook'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importAudiobook(tmp, bookKeyOverride: bookKey);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteAudiobook(bookKey);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  // ── 视频端点（P4-2）──────────────────────────────────────────────────────────

  /// 从视频子路径提取视频 id。
  ///
  /// [reqPath] 已经过 Uri.decodeFull 解码（含前导 `/`）。
  /// 格式为 `/api/library/videos/<id>/<suffix>`，其中：
  /// - [suffix] 为 `stream`、`streamurl`、`subtitle` 或 `cover`
  /// - id 允许包含 `/`（如 `video/my_film`），但不允许 `..`（路径穿越）
  ///
  /// 解析失败（id 为空或含 `..`）时返回 null。
  /// 解析 `?episode=N` query 成集下标（TODO-885）；缺省 / 非法 / 负数都回退 0
  /// （= 当前集 / 单视频，向后兼容）。
  static int _episodeIndexFromRequest(shelf.Request request) {
    final String? raw = request.url.queryParameters['episode'];
    if (raw == null) return 0;
    final int? n = int.tryParse(raw);
    if (n == null || n < 0) return 0;
    return n;
  }

  static String? _extractVideoId(String reqPath, String suffix) {
    const String prefix = '/api/library/videos/';
    final String fullSuffix = '/$suffix';
    if (!reqPath.startsWith(prefix)) return null;
    if (!reqPath.endsWith(fullSuffix)) return null;
    final String id =
        reqPath.substring(prefix.length, reqPath.length - fullSuffix.length);
    if (id.isEmpty) return null;
    // 只拒 `..`（路径穿越），允许 `/`（bookUid 形如 video/xxx）
    if (id.contains('..') || id.contains('\\')) return null;
    return id;
  }

  Future<shelf.Response> _handleLibraryVideos(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    // GET /api/library/videos — 列表（需 Basic 鉴权，中间件已处理）
    if (reqPath == '/api/library/videos') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteVideoInfo v in list)
            _remoteVideoJsonForRequest(v, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // GET /api/library/videos/<id>/cover — 视频封面（需 Basic 鉴权）
    final String? coverId = _extractVideoId(reqPath, 'cover');
    if (coverId != null) {
      if (method != 'GET') return shelf.Response(405);
      final File? cover = await _resolveVideoCover(svc, coverId);
      if (cover == null) {
        return shelf.Response.notFound('Video cover not found');
      }
      return serveFileWithRange(cover, request);
    }

    // GET /api/library/videos/<id>/streamurl — 签发短时 token（需 Basic 鉴权）
    final String? streamUrlId = _extractVideoId(reqPath, 'streamurl');
    if (streamUrlId != null) {
      if (method != 'GET') return shelf.Response(405);
      // TODO-885: 远端播放列表按集——?episode=N 决定流式哪一集（DB-only 反查）。
      final int episodeIndex = _episodeIndexFromRequest(request);
      final File? file =
          await svc.resolveVideoFile(streamUrlId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      final String tokenValue = _generateVideoToken();
      _videoStreamTokens[tokenValue] = _VideoStreamToken(
        videoId: streamUrlId,
        createdAt: _now(),
        episodeIndex: episodeIndex,
      );
      final String encodedId = Uri.encodeFull(streamUrlId);
      // stream / subtitle URL 都带 episode=N，让 client 取流 / 下字幕命中同一集。
      final Map<String, String> streamQuery = <String, String>{
        'token': tokenValue,
        if (episodeIndex > 0) 'episode': '$episodeIndex',
      };
      final Uri streamUri = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/stream',
        queryParameters: streamQuery,
      );
      // subtitle URL 不含 token（走 Basic 鉴权），但带 episode=N。
      final File? sub = await svc.resolveVideoSubtitle(streamUrlId,
          episodeIndex: episodeIndex);
      final Uri? subtitleUri = sub != null
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            )
          : null;
      final List<RemoteVideoEmbeddedSubtitleTrack> embeddedTracks =
          await _embeddedSubtitleTracksForRequest(
        file,
        request,
        streamUrlId,
        episodeIndex,
      );
      return _jsonResponse(<String, dynamic>{
        'url': streamUri.toString(),
        'subtitleUrl': subtitleUri?.toString(),
        if (sub != null) 'subtitleFileName': p.basename(sub.path),
        if (embeddedTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track in embeddedTracks)
              track.toJson(),
          ],
      });
    }

    // GET /api/library/videos/<id>/stream — 流式传输（豁免 Basic，靠 token 鉴权）
    final String? streamId = _extractVideoId(reqPath, 'stream');
    if (streamId != null) {
      if (method != 'GET') return shelf.Response(405);
      _pruneVideoTokens();
      final String? tokenValue = request.url.queryParameters['token'];
      if (tokenValue == null || tokenValue.isEmpty) {
        return shelf.Response(401,
            body: 'Missing token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
      if (tok == null || tok.videoId != streamId) {
        return shelf.Response(403,
            body: 'Invalid or expired token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      // TODO-885: 用 token 绑定的集下标反查（token 是 streamurl 签发时定的，client 不能
      // 自己改集——?episode 只决定 streamurl 阶段，stream 阶段以 token 为准）。
      final File? file =
          await svc.resolveVideoFile(streamId, episodeIndex: tok.episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      return serveFileWithRange(file, request);
    }

    // GET /api/library/videos/<id>/subtitle — 字幕（需 Basic 鉴权，中间件已处理）
    final String? subtitleId = _extractVideoId(reqPath, 'subtitle');
    if (subtitleId != null) {
      if (method != 'GET') return shelf.Response(405);
      final int episodeIndex = _episodeIndexFromRequest(request);
      final String? embeddedIndexText =
          request.url.queryParameters['embeddedStreamIndex'];
      final File? sub = embeddedIndexText == null
          ? await svc.resolveVideoSubtitle(subtitleId,
              episodeIndex: episodeIndex)
          : await _resolveEmbeddedVideoSubtitle(
              svc,
              subtitleId,
              int.tryParse(embeddedIndexText),
              episodeIndex,
            );
      if (sub == null) return shelf.Response.notFound('Subtitle not found');
      final int length = sub.lengthSync();
      return shelf.Response.ok(
        sub.openRead(),
        headers: <String, String>{
          'Content-Type': _guessContentType(sub.path),
          'Content-Length': '$length',
        },
      );
    }

    // GET/PUT /api/library/videos/<id>/position — 跨设备播放断点（TODO-653）
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    final String? positionId = _extractVideoId(reqPath, 'position');
    if (positionId != null) {
      final int episodeIndex = _episodeIndexFromRequest(request);
      // 先确认该视频 id（含集下标）在 host DB 真实存在，防止任意 id 写脏 prefs。
      final File? file =
          await svc.resolveVideoFile(positionId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p = await svc
              .getVideoPosition(positionId, episodeIndex: episodeIndex);
          return _jsonResponse(<String, dynamic>{
            'positionMs': p.positionMs,
            'positionUpdatedAtMs': p.updatedAtMs,
          });
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int posMs = (json['positionMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0;
          await svc.putVideoPosition(positionId, posMs, updatedAtMs,
              episodeIndex: episodeIndex);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    return shelf.Response.notFound('Not found');
  }

  Map<String, Object?> _remoteVideoJsonForRequest(
    RemoteVideoInfo video,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = video.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(video.coverPath) != null) {
      final String encodedId = Uri.encodeFull(video.id);
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/cover',
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<List<RemoteVideoEmbeddedSubtitleTrack>>
      _embeddedSubtitleTracksForRequest(
    File videoFile,
    shelf.Request request,
    String videoId,
    int episodeIndex,
  ) async {
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    final String encodedId = Uri.encodeFull(videoId);
    final String videoStem = p.basenameWithoutExtension(videoFile.path);
    return <RemoteVideoEmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack track in tracks)
        _remoteEmbeddedSubtitleTrackForRequest(
          track,
          request,
          encodedId,
          videoStem,
          episodeIndex,
        ),
    ];
  }

  RemoteVideoEmbeddedSubtitleTrack _remoteEmbeddedSubtitleTrackForRequest(
    EmbeddedSubtitleTrack track,
    shelf.Request request,
    String encodedId,
    String videoStem,
    int episodeIndex,
  ) {
    final String? extension = subtitleExtensionForCodec(track.codec);
    final bool isText = extension != null;
    return RemoteVideoEmbeddedSubtitleTrack(
      streamIndex: track.streamIndex,
      codec: track.codec,
      language: track.language,
      title: track.title,
      isText: isText,
      url: isText
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                'embeddedStreamIndex': '${track.streamIndex}',
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            ).toString()
          : null,
      fileName: isText
          ? '${_safeDownloadStem(videoStem)}.embedded.${track.streamIndex}$extension'
          : null,
    );
  }

  static String _safeDownloadStem(String value) {
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'video' : safe;
  }

  Future<File?> _resolveEmbeddedVideoSubtitle(
    HibikiLibraryHostService service,
    String id,
    int? streamIndex,
    int episodeIndex,
  ) async {
    if (streamIndex == null || streamIndex < 0) return null;
    final File? videoFile =
        await service.resolveVideoFile(id, episodeIndex: episodeIndex);
    if (videoFile == null) return null;
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    for (final EmbeddedSubtitleTrack track in tracks) {
      if (track.streamIndex != streamIndex) continue;
      if (subtitleFormatForCodec(track.codec) == null) return null;
      return extractEmbeddedSubtitleTrackFile(
        videoPath: videoFile.path,
        streamIndex: track.streamIndex,
        codec: track.codec,
      );
    }
    return null;
  }

  Future<File?> _resolveVideoCover(
    HibikiLibraryHostService service,
    String id,
  ) async {
    final List<RemoteVideoInfo> videos = await service.listVideos();
    for (final RemoteVideoInfo video in videos) {
      if (video.id == id) return _coverFile(video.coverPath);
    }
    return null;
  }

  static File? _coverFile(String? path) {
    if (path == null || path.isEmpty) return null;
    final File file = File(path);
    return file.existsSync() ? file : null;
  }

  String _generateVideoToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneVideoTokens() {
    // 视频播放时间长，token 有效期设为 6 小时
    final DateTime cutoff = _now().subtract(const Duration(hours: 6));
    _videoStreamTokens.removeWhere(
      (String _, _VideoStreamToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  Future<Map<String, dynamic>?> _readJsonObject(shelf.Request request) async {
    try {
      final String body = await request.readAsString();
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  shelf.Response _jsonResponse(Map<String, dynamic> body) {
    return shelf.Response.ok(
      jsonEncode(body),
      // TODO-752a：必须带 charset=utf-8。否则远程查词 client 用 package:http 的
      // `.body` 读取时按 latin1 默认解码，CJK 词典义项/书名直接乱码。
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8'
      },
    );
  }

  String _generateAudioToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneAudioTokens() {
    final DateTime cutoff = _now().subtract(const Duration(minutes: 5));
    _remoteAudioTokens.removeWhere(
      (String _, _RemoteAudioToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  Future<shelf.Response> _handlePropfind(
      shelf.Request request, String davPath, String fsPath) async {
    final depth = request.headers['depth'] ?? '1';
    final entity = FileSystemEntity.typeSync(fsPath);

    if (entity == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }

    final entries = <_DavEntry>[];
    final normPath = davPath.endsWith('/') ? davPath : '$davPath/';

    if (entity == FileSystemEntityType.directory) {
      entries.add(_DavEntry(
        href: normPath,
        isCollection: true,
        displayName: p.basename(fsPath),
        contentLength: 0,
      ));

      if (depth == '1') {
        final dir = Directory(fsPath);
        await for (final child in dir.list()) {
          final childName = p.basename(child.path);
          final isDir = child is Directory;
          final childHref = '$normPath$childName${isDir ? '/' : ''}';
          final length = isDir ? 0 : (child as File).lengthSync();
          entries.add(_DavEntry(
            href: childHref,
            isCollection: isDir,
            displayName: childName,
            contentLength: length,
          ));
        }
      }
    } else {
      final file = File(fsPath);
      entries.add(_DavEntry(
        href: davPath,
        isCollection: false,
        displayName: p.basename(fsPath),
        contentLength: file.lengthSync(),
      ));
    }

    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n')
      ..write('<d:multistatus xmlns:d="DAV:">\n');
    for (final entry in entries) {
      xml
        ..write('<d:response>\n')
        ..write('<d:href>${_xmlEscape(Uri.encodeFull(entry.href))}</d:href>\n')
        ..write('<d:propstat>\n')
        ..write('<d:prop>\n')
        ..write(
            '<d:displayname>${_xmlEscape(entry.displayName)}</d:displayname>\n')
        ..write('<d:resourcetype>')
        ..write(entry.isCollection ? '<d:collection/>' : '')
        ..write('</d:resourcetype>\n');
      if (!entry.isCollection) {
        xml.write(
            '<d:getcontentlength>${entry.contentLength}</d:getcontentlength>\n');
      }
      xml
        ..write('</d:prop>\n')
        ..write('<d:status>HTTP/1.1 200 OK</d:status>\n')
        ..write('</d:propstat>\n')
        ..write('</d:response>\n');
    }
    xml.write('</d:multistatus>');

    return shelf.Response(207,
        body: xml.toString(),
        headers: {'Content-Type': 'application/xml; charset=utf-8'});
  }

  Future<shelf.Response> _handleGet(String fsPath) async {
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': _guessContentType(fsPath),
        'Content-Length': '${file.lengthSync()}',
      },
    );
  }

  Future<shelf.Response> _handlePut(
      shelf.Request request, String fsPath) async {
    final parent = Directory(p.dirname(fsPath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final file = File(fsPath);
    final existed = file.existsSync();
    final sink = file.openWrite();
    try {
      await request.read().forEach(sink.add);
      await sink.close();
    } catch (e) {
      // The request stream errored mid-body. Close the sink and remove the
      // truncated file rather than leaving a corrupt file behind a 201/204
      // response — matching the download paths' cleanup (HBK-AUDIT-029).
      try {
        await sink.close();
      } catch (_) {/* best-effort: failure is non-critical here */}
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {/* best-effort: failure is non-critical here */}
      }
      return shelf.Response(500, body: 'Write failed');
    }
    return shelf.Response(existed ? 204 : 201);
  }

  Future<shelf.Response> _handleMkcol(String fsPath) async {
    final dir = Directory(fsPath);
    if (dir.existsSync()) return shelf.Response(405);
    dir.createSync(recursive: true);
    return shelf.Response(201);
  }

  Future<shelf.Response> _handleDelete(String fsPath) async {
    final type = FileSystemEntity.typeSync(fsPath);
    if (type == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(fsPath).delete(recursive: true);
    } else {
      await File(fsPath).delete();
    }
    return shelf.Response(204);
  }

  Future<shelf.Response> _handleHead(String fsPath) async {
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(null, headers: {
      'Content-Type': _guessContentType(fsPath),
      'Content-Length': '${file.lengthSync()}',
    });
  }

  static String _guessContentType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.json':
        return 'application/json';
      case '.epub':
        return 'application/epub+zip';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.m4b':
        return 'audio/mp4';
      case '.ogg':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      // ── 视频格式（P4-1）──────────────────────────────────────────────────────
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.avi':
        return 'video/x-msvideo';
      case '.mov':
        return 'video/quicktime';
      case '.ts':
      case '.m2ts':
      case '.mts':
        return 'video/mp2t';
      case '.flv':
        return 'video/x-flv';
      case '.wmv':
        return 'video/x-ms-wmv';
      case '.mpg':
      case '.mpeg':
        return 'video/mpeg';
      case '.ogv':
        return 'video/ogg';
      case '.3gp':
        return 'video/3gpp';
      // ── 字幕格式 ──────────────────────────────────────────────────────────────
      case '.srt':
        return 'text/plain; charset=utf-8';
      case '.ass':
      case '.ssa':
        return 'text/plain; charset=utf-8';
      case '.vtt':
        return 'text/vtt; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

// ── Range 流式传输辅助（P4-1）────────────────────────────────────────────────

/// HTTP `Range: bytes=` 解析结果。
///
/// [start] / [end] 均为闭区间（如 `0..99` 表示前 100 字节）。
/// [unsatisfiable] 为 true 时表示范围越界或格式合法但不可满足（应回 416）。
class ByteRange {
  const ByteRange({required this.start, required this.end});

  /// 不可满足的特殊单例（start==-1, end==-1）。
  static const ByteRange unsatisfiable = ByteRange(start: -1, end: -1);

  final int start;
  final int end;

  bool get isUnsatisfiable => start == -1 && end == -1;

  /// 区间字节数（闭区间长度）。
  int get length => isUnsatisfiable ? 0 : end - start + 1;

  @override
  String toString() =>
      isUnsatisfiable ? 'ByteRange.unsatisfiable' : 'ByteRange($start-$end)';
}

/// 纯函数：解析 `Range: bytes=<spec>` 头，返回闭区间 [ByteRange]。
///
/// 支持三种合法格式（RFC 7233）：
/// - `bytes=start-end`：完整范围（两端均含）。
/// - `bytes=start-`：从 [start] 到文件末尾。
/// - `bytes=-suffix`：文件最后 [suffix] 字节。
///
/// 以下情况返回 [ByteRange.unsatisfiable]（调用方回 416）：
/// - [rangeHeader] 为 null/空：**不返回 unsatisfiable，返回 null**（表示无 Range 头，
///   调用方回 200 全量）——通过返回 `null` 区分「无头」与「不可满足」。
/// - 格式不符（非 `bytes=` 前缀、缺 `-`、非数字）：返回 unsatisfiable。
/// - suffix=0：返回 unsatisfiable（RFC 7233 §2.1 suffix-length 为 0 无意义）。
/// - 解析后范围越界（start >= fileLength）：返回 unsatisfiable。
/// - start > end（规范化后）：返回 unsatisfiable。
ByteRange? parseByteRange(String? rangeHeader, int fileLength) {
  if (rangeHeader == null || rangeHeader.isEmpty) return null;
  if (!rangeHeader.startsWith('bytes=')) return ByteRange.unsatisfiable;

  final String spec = rangeHeader.substring(6).trim(); // 去掉 'bytes='
  final int dashIdx = spec.indexOf('-');
  if (dashIdx < 0) return ByteRange.unsatisfiable;

  final String startStr = spec.substring(0, dashIdx).trim();
  final String endStr = spec.substring(dashIdx + 1).trim();

  int start;
  int end;

  if (startStr.isEmpty) {
    // `-suffix` 形式
    final int? suffix = int.tryParse(endStr);
    if (suffix == null || suffix <= 0) return ByteRange.unsatisfiable;
    start = fileLength - suffix;
    if (start < 0) start = 0;
    end = fileLength - 1;
  } else {
    // `start-` 或 `start-end` 形式
    final int? parsedStart = int.tryParse(startStr);
    if (parsedStart == null || parsedStart < 0) {
      return ByteRange.unsatisfiable;
    }
    start = parsedStart;

    if (endStr.isEmpty) {
      // `start-` 形式
      end = fileLength - 1;
    } else {
      final int? parsedEnd = int.tryParse(endStr);
      if (parsedEnd == null || parsedEnd < 0) {
        return ByteRange.unsatisfiable;
      }
      // RFC 7233: end 超出文件末尾时钳制到 fileLength-1（不算越界）
      end = parsedEnd < fileLength ? parsedEnd : fileLength - 1;
    }
  }

  // 越界检查：start 超出文件末尾才是真正不可满足
  if (fileLength == 0 || start >= fileLength) {
    return ByteRange.unsatisfiable;
  }
  if (start > end) return ByteRange.unsatisfiable;

  return ByteRange(start: start, end: end);
}

/// shelf handler helper：对 [file] 提供 Range 感知流式响应。
///
/// - 有合法 `Range` 头 → `206 Partial Content` + `Content-Range` + 字节区间流。
/// - 无 `Range` 头 → `200 OK` + 全量流。
/// - 不可满足的 Range → `416 Range Not Satisfiable` + `Content-Range: bytes */total`。
///
/// 所有路径均加 `Accept-Ranges: bytes`（告知客户端支持 Range）。
/// Content-Type 由 [HibikiSyncServer._guessContentType] 按扩展名确定。
/// 响应体全程流式（`file.openRead(start, end+1)`），不把文件读入内存。
///
/// 函数名无下划线前缀（公开），便于测试文件直接导入使用。
Future<shelf.Response> serveFileWithRange(
  File file,
  shelf.Request request,
) async {
  if (!file.existsSync()) {
    return shelf.Response.notFound('File not found');
  }

  final int fileLength = file.lengthSync();
  final String contentType = HibikiSyncServer._guessContentType(file.path);
  final String? rangeHeader = request.headers['range'];
  final ByteRange? range = parseByteRange(rangeHeader, fileLength);

  // 无 Range 头：200 全量
  if (range == null) {
    return shelf.Response.ok(
      file.openRead(),
      headers: <String, String>{
        'Content-Type': contentType,
        'Content-Length': '$fileLength',
        'Accept-Ranges': 'bytes',
      },
    );
  }

  // Range 不可满足：416
  if (range.isUnsatisfiable) {
    return shelf.Response(
      416,
      headers: <String, String>{
        'Content-Range': 'bytes */$fileLength',
        'Accept-Ranges': 'bytes',
      },
    );
  }

  // 合法 Range：206 Partial Content
  final int rangeLength = range.length;
  return shelf.Response(
    206,
    body: file.openRead(range.start, range.end + 1),
    headers: <String, String>{
      'Content-Type': contentType,
      'Content-Length': '$rangeLength',
      'Content-Range': 'bytes ${range.start}-${range.end}/$fileLength',
      'Accept-Ranges': 'bytes',
    },
  );
}

class _DavEntry {
  const _DavEntry({
    required this.href,
    required this.isCollection,
    required this.displayName,
    required this.contentLength,
  });

  final String href;
  final bool isCollection;
  final String displayName;
  final int contentLength;
}

class _RemoteAudioToken {
  _RemoteAudioToken({
    required this.bytes,
    required this.contentType,
    required this.createdAt,
  });

  final Uint8List bytes;
  final String contentType;

  /// TODO-766: 不是 final——每次被 [_handleAudioFile] 命中都刷新，重置 5 分钟
  /// 过期窗口，使「正在被访问」的音频 token 不会在使用途中过期（惠及播放与制卡）。
  DateTime createdAt;
}

/// 视频流短时 token（P4-2）。
///
/// token 绑定到特定 [videoId]，到期时间由 [_pruneVideoTokens] 管控（6 小时）。
/// 有效期长于音频 token（5 分钟）是因为视频播放时长远超音频片段。
class _VideoStreamToken {
  const _VideoStreamToken({
    required this.videoId,
    required this.createdAt,
    this.episodeIndex = 0,
  });

  /// 绑定的视频 id（即 VideoBooks.bookUid，可含 `/`）。
  final String videoId;
  final DateTime createdAt;

  /// 远端播放列表集下标（TODO-885）；单视频 / 当前集恒 0。
  final int episodeIndex;
}
