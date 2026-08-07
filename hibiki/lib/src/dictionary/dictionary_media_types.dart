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
/// strips leading ./ and /. Matches what HoshiDicts.getMediaFile expects.
String normalizeDictionaryMediaPath(String path) {
  return path.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
}

/// Content-Type by file extension. Unknown extensions fall back to
/// application/octet-stream. Includes image/svg+xml (the main gaiji/accent
/// format).
///
/// 命名统一轮 G8：查 hibiki_core 单一 MIME 映射表 [mimeTypeForFilePath]（旧本地
/// switch 副本之一）。保留旧名薄 shim 供两处消费端（app 内 scheme handler 与
/// sync server 的 /api/media/dictionary 端点）。
String dictionaryMediaMimeType(String path) => mimeTypeForFilePath(path);
