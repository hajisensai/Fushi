import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

const List<String> dictionaryMediaCustomSchemes = <String>[
  'image',
  'dictmedia',
];

/// 制卡前把 JS 负载里的词典媒体（gaiji 外字等）字节落盘到 Anki 媒体缓存目录，
/// 供 [BaseAnkiRepository] 的 storeMediaFile 读取嵌进卡片。
///
/// 背景：popup.js 在 `window.embedMedia` 为真时把外字渲染成
/// `<img src="hoshi_dict_N.ext">` 并在负载 `dictionaryMedia`
/// （`[{dictionary, path, filename}]` 的 JSON 串）里登记。两个 Anki repo 从
/// [ankiDictionaryMediaCacheDirPath]/[ankiDictionaryMediaCacheFilename] 读字节再
/// storeMediaFile + 把字段里的 `hoshi_dict_N.ext` 替换成真实媒体引用。**但此前没有
/// 任何地方写这个缓存**（`image://` 服务只把字节喂给页面显示、不落盘），故媒体永远
/// 读不到、外字退化成 alt 文本（明鏡义项序号显示成烂 alt「3分の2」）。本函数补上写缓存
/// 这一环：用 [HoshiDicts.getMediaFile] 取字节、按与 repo 共用的命名写盘。
///
/// 幂等：已存在的缓存文件跳过。HoshiDicts 未初始化 / 字节取不到 / 写盘失败均静默跳过
/// （该条媒体退回 alt 文本，不阻断制卡）。
Future<void> writeDictionaryMediaCache(String dictionaryMediaJson) async {
  if (dictionaryMediaJson.isEmpty || dictionaryMediaJson == '[]') return;
  if (!HoshiDicts.isInitialized) return;
  final List<dynamic> entries;
  try {
    entries = jsonDecode(dictionaryMediaJson) as List<dynamic>;
  } catch (_) {
    return;
  }
  if (entries.isEmpty) return;

  final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (_) {
    return;
  }

  for (final dynamic raw in entries) {
    if (raw is! Map) continue;
    final String dict = raw['dictionary']?.toString() ?? '';
    final String path = raw['path']?.toString() ?? '';
    if (dict.isEmpty || path.isEmpty) continue;
    final File file =
        File('${dir.path}/${ankiDictionaryMediaCacheFilename(path)}');
    if (file.existsSync()) continue; // 幂等：已缓存。
    try {
      final Uint8List? bytes = HoshiDicts.instance.getMediaFile(dict, path);
      if (bytes != null && bytes.isNotEmpty) {
        await file.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      debugPrint('[DictionaryMedia] cache write failed for $dict/$path: $e');
    }
  }
}

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
  if (response == null) return null;

  return CustomSchemeResponse(
    data: response.data,
    contentType: response.contentType,
    contentEncoding: response.contentEncoding ?? 'utf-8',
  );
}

_DictionaryMediaResponse? _dictionaryMediaResponse(Uri url) {
  if (url.scheme == 'image') {
    final String dictName = url.queryParameters['dictionary'] ?? '';
    final String mediaPath = _normalizeMediaPath(
      url.queryParameters['path'] ?? '',
    );
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!HoshiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

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
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!HoshiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

    final Uint8List? data = HoshiDicts.instance.getMediaFile(
      dictName,
      mediaPath,
    );
    if (data == null) return _DictionaryMediaResponse.notFound();

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
