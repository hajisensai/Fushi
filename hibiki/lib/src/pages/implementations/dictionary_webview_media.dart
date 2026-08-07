import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/dictionary/dictionary_media_types.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
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
/// 幂等：已存在的缓存文件跳过。HoshiDicts 未初始化 / 字节取不到 / 写盘失败均跳过
/// （该条媒体退回 alt 文本，不阻断制卡）。
///
/// BUG-1265：跳过**必须留痕**。这三条跳过路径以前只有一句不含原因的 debugPrint
/// （甚至直接 `return`），于是「缓存里没有这个文件」在日志里毫无前因；下游 repo 报
/// 「Dictionary media file is missing」时无从判断是词典取不到字节、还是根本没走到
/// 写入方。现在每条跳过都带原因进 [ErrorLogService]（用户上传的报错日志里能看到），
/// 一条媒体一行，只在真出问题时才产生。
Future<void> writeDictionaryMediaCache(String dictionaryMediaJson) async {
  if (dictionaryMediaJson.isEmpty || dictionaryMediaJson == '[]') return;
  final List<dynamic> entries;
  try {
    entries = jsonDecode(dictionaryMediaJson) as List<dynamic>;
  } catch (e, stack) {
    _logDictionaryMediaSkip('payload JSON 解析失败: $e', stack);
    return;
  }
  if (entries.isEmpty) return;

  // 未初始化的判断放在「确实有媒体要写」之后：无媒体时不该产生噪音日志。
  if (!FushiDicts.isInitialized) {
    _logDictionaryMediaSkip(
      'FushiDicts 未初始化，${entries.length} 条词典媒体未落盘（卡片将缺外字）',
    );
    return;
  }

  final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (e, stack) {
    _logDictionaryMediaSkip('缓存目录 ${dir.path} 创建失败: $e', stack);
    return;
  }

  for (final dynamic raw in entries) {
    if (raw is! Map) continue;
    final String dict = raw['dictionary']?.toString() ?? '';
    final String path = raw['path']?.toString() ?? '';
    if (dict.isEmpty || path.isEmpty) {
      _logDictionaryMediaSkip('媒体条目缺 dictionary/path，无法定位字节: $raw');
      continue;
    }
    final File file =
        File('${dir.path}/${ankiDictionaryMediaCacheFilename(dict, path)}');
    if (file.existsSync()) continue; // 幂等：已缓存。
    try {
      final Uint8List? bytes = FushiDicts.instance.getMediaFile(dict, path);
      if (bytes == null || bytes.isEmpty) {
        // 最常见的一条：词典里取不到这个资源（分卷 MDD 未挂载、资源名对不上、
        // 词典已删除重导）。以前这里连 debugPrint 都没有。
        _logDictionaryMediaSkip('词典「$dict」取不到媒体字节: $path');
        continue;
      }
      await file.writeAsBytes(bytes, flush: true);
    } catch (e, stack) {
      _logDictionaryMediaSkip('写盘失败 $dict/$path: $e', stack);
    }
  }
}

/// 词典媒体落盘跳过的统一留痕口：debugPrint（开发期）+ [ErrorLogService]（随用户
/// 上传的报错日志一起回来）。跳过只降级这一条媒体，不抛、不阻断制卡。
void _logDictionaryMediaSkip(String reason, [StackTrace? stack]) {
  debugPrint('[DictionaryMedia] $reason');
  ErrorLogService.instance.log('DictionaryMedia.cache', reason, stack);
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
    final String mediaPath = normalizeDictionaryMediaPath(
      url.queryParameters['path'] ?? '',
    );
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!FushiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

    try {
      final Uint8List? data = FushiDicts.instance.getMediaFile(
        dictName,
        mediaPath,
      );
      if (data != null) {
        final String mime = dictionaryMediaMimeType(mediaPath);
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
    final String mediaPath =
        normalizeDictionaryMediaPath(Uri.decodeComponent(url.host));
    if (dictName.isEmpty || mediaPath.isEmpty) {
      return _DictionaryMediaResponse.notFound();
    }
    if (!FushiDicts.isInitialized) return _DictionaryMediaResponse.notFound();

    final Uint8List? data = FushiDicts.instance.getMediaFile(
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
