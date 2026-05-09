import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/epub/epub_book.dart';

class ReaderResourceServer {
  ReaderResourceServer({
    required this.extractDir,
    this.chapterHrefs = const <String>[],
  });

  final String extractDir;
  final List<String> chapterHrefs;

  HttpServer? _server;
  int _port = 0;

  int get port => _port;
  bool get isRunning => _server != null;

  String chapterUrl(int index) =>
      'http://localhost:$_port/__chapter__/$index';

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  void _handleRequest(HttpRequest request) {
    final String path = Uri.decodeComponent(request.uri.path);

    if (path.startsWith('/__chapter__/')) {
      _serveChapter(request, path);
      return;
    }

    _serveResource(request, path);
  }

  void _serveChapter(HttpRequest request, String path) {
    final String indexStr = path.substring('/__chapter__/'.length);
    final int? index = int.tryParse(indexStr.split('/').first);
    if (index == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid chapter index')
        ..close();
      return;
    }

    final File chapterFile = _resolveChapterFile(index);
    if (!chapterFile.existsSync()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Chapter $index not found')
        ..close();
      return;
    }

    String html = chapterFile.readAsStringSync();
    final String baseHref = _chapterBaseHref(chapterFile.path);
    html = _injectBaseTag(html, baseHref);

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
      ..headers.set('Cache-Control', 'no-cache')
      ..write(html)
      ..close();
  }

  File _resolveChapterFile(int index) {
    if (index >= 0 && index < chapterHrefs.length) {
      return File(p.join(extractDir, chapterHrefs[index]));
    }
    return File('');
  }

  void _serveResource(HttpRequest request, String path) {
    final String cleanPath = path.startsWith('/') ? path.substring(1) : path;
    final String filePath = p.join(extractDir, cleanPath);
    final File file = File(filePath);

    if (!file.existsSync()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }

    final String mimeType = fallbackMimeType(filePath);
    final List<String> parts = mimeType.split('/');
    final String primaryType = parts.isNotEmpty ? parts[0] : 'application';
    final String subType = parts.length > 1 ? parts[1] : 'octet-stream';

    try {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(primaryType, subType)
        ..headers.set('Cache-Control', 'max-age=3600')
        ..headers.set('Access-Control-Allow-Origin', '*');
      file.openRead().pipe(request.response);
    } catch (e) {
      debugPrint('[ReaderResourceServer] error serving $cleanPath: $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  String _chapterBaseHref(String chapterPath) {
    final String relDir =
        p.relative(p.dirname(chapterPath), from: extractDir).replaceAll('\\', '/');
    if (relDir == '.' || relDir.isEmpty) {
      return 'http://localhost:$_port/';
    }
    return 'http://localhost:$_port/$relDir/';
  }

  static String _injectBaseTag(String html, String baseHref) {
    final String baseTag = '<base href="$baseHref">';

    final RegExp headPattern = RegExp(r'<head[^>]*>', caseSensitive: false);
    final Match? headMatch = headPattern.firstMatch(html);
    if (headMatch != null) {
      return '${html.substring(0, headMatch.end)}\n$baseTag\n${html.substring(headMatch.end)}';
    }

    final RegExp htmlPattern = RegExp(r'<html[^>]*>', caseSensitive: false);
    final Match? htmlMatch = htmlPattern.firstMatch(html);
    if (htmlMatch != null) {
      return '${html.substring(0, htmlMatch.end)}\n<head>\n$baseTag\n</head>\n${html.substring(htmlMatch.end)}';
    }

    return '<head>\n$baseTag\n</head>\n$html';
  }
}
