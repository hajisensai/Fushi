import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
class HibikiSyncServer {
  HibikiSyncServer({
    required String syncDataDir,
    required int port,
    required String token,
    bool allowLan = false,
  })  : syncDataDir = p.join(syncDataDir, 'sync-data'),
        _requestedPort = port,
        _token = token,
        _allowLan = allowLan;

  final String syncDataDir;
  final int _requestedPort;
  final String _token;
  final bool _allowLan;
  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _requestedPort;

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> start() async {
    if (_server != null) return;
    final handler = const shelf.Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    _server = await shelf_io.serve(
      handler,
      _allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      _requestedPort,
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) {
        if (request.method == 'OPTIONS') return innerHandler(request);
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
    final fsPath = p.canonicalize(p.join(syncDataDir, reqPath.substring(1)));
    final canonicalRoot = p.canonicalize(syncDataDir);
    if (fsPath != canonicalRoot &&
        !fsPath.startsWith('$canonicalRoot${p.separator}')) {
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
          'Allow': 'OPTIONS, GET, PUT, DELETE, MKCOL, PROPFIND, HEAD',
          'DAV': '1',
        });
      default:
        return shelf.Response(405);
    }
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
      } catch (_) {}
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
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
