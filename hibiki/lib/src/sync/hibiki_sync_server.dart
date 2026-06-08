import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  })  : syncDataDir = p.join(syncDataDir, 'sync-data'),
        _requestedPort = port,
        _token = token,
        _allowLan = allowLan,
        _remoteLookupService = remoteLookupService,
        _miningService = miningService,
        _historyService = historyService,
        _libraryService = libraryService;

  final String syncDataDir;
  final int _requestedPort;
  final String _token;
  final bool _allowLan;
  final HibikiRemoteLookupService? _remoteLookupService;
  final HibikiRemoteMiningService? _miningService;
  final HibikiRemoteHistoryService? _historyService;
  final HibikiLibraryHostService? _libraryService;
  final Map<String, _RemoteAudioToken> _remoteAudioTokens =
      <String, _RemoteAudioToken>{};
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
        final auth = request.headers['authorization'];
        if (auth == null || !_validateAuth(auth)) {
          return shelf.Response(401,
              headers: {'WWW-Authenticate': 'Basic realm="Hibiki Sync"'});
        }
        return innerHandler(request);
      };
    };
  }

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
      createdAt: DateTime.now(),
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
    final bool dict = _libraryService != null;
    return _jsonResponse(<String, dynamic>{
      'liveLibrary': <String, dynamic>{
        'dictionaries': dict,
        'books': false,
        'audio': false,
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
      headers: <String, String>{'Content-Type': 'application/json'},
    );
  }

  String _generateAudioToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneAudioTokens() {
    final DateTime cutoff = DateTime.now().subtract(const Duration(minutes: 5));
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
      default:
        return 'application/octet-stream';
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
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
  const _RemoteAudioToken({
    required this.bytes,
    required this.contentType,
    required this.createdAt,
  });

  final Uint8List bytes;
  final String contentType;
  final DateTime createdAt;
}
