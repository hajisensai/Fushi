/// 单一「扩展名 → MIME」推断真相源（命名统一轮 G8 + BUG-1122）。
///
/// 此前这段 switch 在 6 处各持一份漂移副本：
/// - `hibiki/lib/src/sync/hibiki_sync_server.dart` `_guessContentType`
///   （WebDAV / 流式 / 字幕端点；**缺 `.webp` → webp 封面按
///   application/octet-stream 下发，即 BUG-1122**）；
/// - `hibiki/lib/src/sync/sync_utils.dart` `guessSyncContentType`（云端上传）；
/// - `hibiki/lib/src/epub/epub_book.dart` `fallbackMimeType`（阅读器 WebView 资源）；
/// - `hibiki/lib/src/dictionary/dictionary_media_types.dart`
///   `dictionaryMediaMimeType`（词典媒体，app 内 + 浏览器扩展端点）；
/// - `hibiki/lib/src/lookup/global_lookup_controller.dart`
///   `_globalLookupImageMime`（桌面查词浮窗）；
/// - `packages/hibiki_anki/lib/src/anki_models.dart` `mimeTypeForPath`
///   （Anki 媒体上传）。
///
/// 本表取 6 份覆盖面的**并集**（6 份之间无互相矛盾的映射）。前 5 份已改为直接查本表；
/// hibiki_anki 是无 hibiki_core 依赖的独立模块，其副本改为本表的**镜像**，由
/// `hibiki/test/sync/mime_types_test.dart` 守卫锁定逐项一致。单词音频语境的
/// `kAudioMimeByExtension`（hibiki `utils/misc/audio_mime.dart`，
/// `.mp4/.aac/.webm → audio/*` 是刻意收窄，`audio_mime_test.dart` 锁定与本表的
/// 分歧集合）与 manga 页 jpeg 兜底的图片服务不属本表，见各自注释。
library;

/// 扩展名（小写、不含点）→ MIME 单一映射表。
const Map<String, String> kMimeTypeByExtension = <String, String>{
  // ── 文档 / 容器 ──
  'json': 'application/json',
  'epub': 'application/epub+zip',
  'css': 'text/css',
  'js': 'application/javascript',
  // BUG-1196：`.htm` / `.xht` 与 `.html` / `.xhtml` 是同一类文档的合法扩展名，缺
  // 这两条时 EPUB 章节按 [kFallbackMimeType]（octet-stream）下发，阅读器拦截器的
  // 「是 HTML 吗」判定（`mime == 'text/html' || mime.contains('xhtml')`）取假 →
  // 既不注入阅读器样式/分页脚本、也不做 XHTML 净化，WebView 更不把它当文档渲染，
  // 整本书翻页全空白。EPUB 3 规范允许这四种扩展名，表必须四条齐全。
  'xhtml': 'text/html',
  'html': 'text/html',
  'htm': 'text/html',
  'xht': 'text/html',
  // ── 图片 ──
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  // ── 字体 ──
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  // ── 音频 ──
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'm4b': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  // ── 视频 ──
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mov': 'video/quicktime',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  'mts': 'video/mp2t',
  'flv': 'video/x-flv',
  'wmv': 'video/x-ms-wmv',
  'mpg': 'video/mpeg',
  'mpeg': 'video/mpeg',
  'ogv': 'video/ogg',
  '3gp': 'video/3gpp',
  // ── 字幕 ──
  'srt': 'text/plain; charset=utf-8',
  'ass': 'text/plain; charset=utf-8',
  'ssa': 'text/plain; charset=utf-8',
  'vtt': 'text/vtt; charset=utf-8',
};

/// 未知扩展名的兜底 MIME。
const String kFallbackMimeType = 'application/octet-stream';

/// 按 [path]（文件路径或裸文件名，`/` 与 `\` 分隔均可）的扩展名推断 MIME；
/// 无扩展名或未知扩展名回退 [fallback]（默认 [kFallbackMimeType]）。
String mimeTypeForFilePath(String path, {String fallback = kFallbackMimeType}) {
  final String ext = _fileExtensionLower(path);
  if (ext.isEmpty) return fallback;
  return kMimeTypeByExtension[ext] ?? fallback;
}

/// 取 [path] 最后一段路径的扩展名（小写、不含点）；无扩展名（含 dotfile、点结尾）
/// 返回空串。
String _fileExtensionLower(String path) {
  int slash = -1;
  for (int i = path.length - 1; i >= 0; i--) {
    final String c = path[i];
    if (c == '/' || c == r'\') {
      slash = i;
      break;
    }
  }
  final String name = path.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}
