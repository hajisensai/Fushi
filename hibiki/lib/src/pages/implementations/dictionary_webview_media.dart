import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';

const List<String> dictionaryMediaCustomSchemes = <String>[
  'image',
  'dictmedia',
];

WebResourceResponse? dictionaryMediaWebResourceResponse(Uri url) {
  final _DictionaryMediaResponse? response = _dictionaryMediaResponse(url);
  if (response == null) return null;

  return WebResourceResponse(
    contentType: response.contentType,
    contentEncoding: response.contentEncoding,
    statusCode: response.statusCode,
    reasonPhrase: response.reasonPhrase,
    data: response.data,
  );
}

CustomSchemeResponse? dictionaryMediaCustomSchemeResponse(Uri url) {
  final _DictionaryMediaResponse? response = _dictionaryMediaResponse(url);
  if (response == null || response.statusCode != 200) return null;

  return CustomSchemeResponse(
    data: response.data,
    contentType: response.contentType,
    contentEncoding: response.contentEncoding ?? 'utf-8',
  );
}

_DictionaryMediaResponse? _dictionaryMediaResponse(Uri url) {
  if (!HoshiDicts.isInitialized) return null;

  if (url.scheme == 'image') {
    final String dictName = url.queryParameters['dictionary'] ?? '';
    final String mediaPath = _normalizeMediaPath(
      url.queryParameters['path'] ?? '',
    );
    if (dictName.isEmpty || mediaPath.isEmpty) return null;

    try {
      final Uint8List? data = HoshiDicts.instance.getMediaFile(
        dictName,
        mediaPath,
      );
      if (data != null) {
        final String mime = _mimeTypeForPath(mediaPath);
        return _DictionaryMediaResponse.ok(
          data: data,
          contentType: mime,
          contentEncoding: mime.startsWith('text/') ? 'utf-8' : null,
        );
      }
    } catch (e) {
      debugPrint('[DictionaryMedia] image error: $e');
    }

    return _DictionaryMediaResponse.notFound();
  }

  if (url.scheme == 'dictmedia') {
    final String dictName = url.queryParameters['dictionary'] ?? '';
    final String mediaPath = _normalizeMediaPath(Uri.decodeComponent(url.host));
    if (dictName.isEmpty || mediaPath.isEmpty) return null;

    final Uint8List? data = HoshiDicts.instance.getMediaFile(
      dictName,
      mediaPath,
    );
    if (data == null) return null;

    return _DictionaryMediaResponse.ok(
      data: data,
      contentType: 'text/css',
      contentEncoding: 'utf-8',
    );
  }

  return null;
}

String _normalizeMediaPath(String path) {
  return path.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
}

String _mimeTypeForPath(String path) {
  final String ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

class _DictionaryMediaResponse {
  const _DictionaryMediaResponse({
    required this.data,
    required this.contentType,
    required this.statusCode,
    required this.reasonPhrase,
    this.contentEncoding,
  });

  factory _DictionaryMediaResponse.ok({
    required Uint8List data,
    required String contentType,
    String? contentEncoding,
  }) {
    return _DictionaryMediaResponse(
      data: data,
      contentType: contentType,
      contentEncoding: contentEncoding,
      statusCode: 200,
      reasonPhrase: 'OK',
    );
  }

  factory _DictionaryMediaResponse.notFound() {
    return _DictionaryMediaResponse(
      data: Uint8List(0),
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
    );
  }

  final Uint8List data;
  final String contentType;
  final String? contentEncoding;
  final int statusCode;
  final String reasonPhrase;
}
