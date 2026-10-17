/// dictionary media (gaiji, pitch-accent SVG/PNG, etc.) path + MIME helpers.
///
/// One logic consumed in two places (single source of truth, no drift):
///  - the in-app WebView custom scheme handler (dictionary_webview_media.dart's
///    image:// / dictmedia:// parsing);
///  - the sync server's GET /api/media/dictionary endpoint for the browser
///    extension (a real browser has no image:// handler, so the extension
///    rewrites <img src> to that http endpoint).
library;

import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;

/// Normalizes a dictionary media relative path: backslashes -> slashes, and
/// strips leading ./ and /. Matches what FushiDicts.getMediaFile expects.
String normalizeDictionaryMediaPath(String path) {
  return path.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
}

/// Content-Type by file extension. Unknown extensions fall back to
/// application/octet-stream. Includes image/svg+xml (the main gaiji/accent
/// format).
///
/// 命名统一轮 G8：查 fushi_core 单一 MIME 映射表 [mimeTypeForFilePath]（旧本地
/// switch 副本之一）。保留旧名薄 shim 供两处消费端（app 内 scheme handler 与
/// sync server 的 /api/media/dictionary 端点）。
String dictionaryMediaMimeType(String path) => mimeTypeForFilePath(path);

/// 远端词典媒体（`POST /api/lookup/dictionary/media`）单个文件的大小上限。外字 /
/// 音调图 / 词典自带脚本都在几十 KB 以内；上限挡住的是把整卷 MDD 当一个「文件」
/// 拖过来的请求。
const int kRemoteDictionaryMediaMaxBytes = 8 * 1024 * 1024;

/// 把客户端给的词典媒体相对路径收成**一定落在该词典资源根之内**的规范形式；落不进
/// 去（`..` 越级、绝对路径 / 盘符、NUL、空串）一律返回 null。
///
/// 词典媒体按「词典名 + 相对路径」在引擎的媒体索引里取，本来就不碰文件系统；但这条
/// 端点对配对设备开放，判据必须是**结构上**挡死越级，而不是指望下游恰好取不到。
/// 规范化后与 [normalizeDictionaryMediaPath] 同形（正斜杠、无前导 `/`），可直接交给
/// 引擎查询。
String? safeDictionaryMediaPath(String raw) {
  if (raw.contains('\u0000')) return null;
  final String normalized = normalizeDictionaryMediaPath(raw);
  if (normalized.isEmpty) return null;
  // `C:/…`、`//host/…` 之类：规范化只剥前导斜杠，盘符留着，必须单独拒。
  if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
  final List<String> kept = <String>[];
  for (final String segment in normalized.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    kept.add(segment);
  }
  if (kept.isEmpty) return null;
  return kept.join('/');
}
