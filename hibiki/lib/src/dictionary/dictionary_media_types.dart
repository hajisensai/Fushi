/// dictionary media (gaiji, pitch-accent SVG/PNG, etc.) path + MIME helpers.
///
/// One logic consumed in two places (single source of truth, no drift):
///  - the in-app WebView custom scheme handler (dictionary_webview_media.dart's
///    image:// / dictmedia:// parsing);
///  - the sync server's GET /api/media/dictionary endpoint for the browser
///    extension (a real browser has no image:// handler, so the extension
///    rewrites <img src> to that http endpoint).
library;

/// Normalizes a dictionary media relative path: backslashes -> slashes, and
/// strips leading ./ and /. Matches what HoshiDicts.getMediaFile expects.
String normalizeDictionaryMediaPath(String path) {
  return path.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
}

/// Content-Type by file extension. Unknown extensions fall back to
/// application/octet-stream. Includes image/svg+xml (the main gaiji/accent
/// format).
String dictionaryMediaMimeType(String path) {
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
    case 'css':
      return 'text/css';
    default:
      return 'application/octet-stream';
  }
}
