import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/reader_settings.dart' show ReaderCustomFontCss;

/// EPUB 图片防剧透遮罩「已揭开」状态的稳定归一化 key（BUG-898）。
///
/// 阅读器 WebView 的 JS `__fushiImageRevealKey` 与图片库 [IllustrationsViewerPage] 的
/// 磁盘 `File`，各自看到「同一张图」的原始标识不同：前者是 `fushi.local` 虚拟域名下的
/// 绝对资源 URL（`https://fushi.local/epub/OEBPS/images/foo%20bar.jpg`，macOS/iOS 为自定义
/// scheme 变体），后者是原生磁盘绝对路径。要让两端共享同一份持久化揭开状态
/// （Drift `revealed_images` 表），必须先把两种原始标识归一到**同一个 key**。
///
/// 统一 key = **extractDir 相对、percent-decode、正斜杠** 的路径
/// （如 `OEBPS/images/foo bar.jpg`），与 `EpubParser` 全程使用的 relPath、以及资源拦截器
/// `/epub/` 之后 decode 的形态完全一致。
class ImageRevealKey {
  const ImageRevealKey._();

  /// 资源虚拟域名（与 [ReaderCustomFontCss.kReaderResourceHost] 一致）。
  static const String host = ReaderCustomFontCss.kReaderResourceHost;

  static const String _epubPrefix = '/epub/';

  /// 把阅读器侧回传的原始 key [raw] 归一到稳定 key。
  ///
  /// - [raw] 是 `fushi.local` 资源绝对 URL（任意 scheme）→ 取 path、剥 `/epub/` 前缀
  ///   （path 已 percent-decode）→ extractDir 相对路径。
  /// - [raw] 已是 extractDir 相对路径（改造后的 JS 常态）→ 仅做正斜杠 / `.` / `..` 归一。
  ///
  /// 空串 / 越界 / 无法识别返回 `null`（调用方跳过，绝不写脏 key）。
  static String? normalize(String raw) {
    if (raw.isEmpty) return null;
    final Uri? uri = Uri.tryParse(raw);
    // fushi.local 绝对 URL：uri.path 是 **未解码** 的（保留 %20 等），剥 `/epub/` 前缀后
    // 必须 decodeComponent 才能与磁盘真实文件名（真实空格）对齐（与 JS 侧 decodeURIComponent
    // 对称）。
    if (uri != null && uri.host == host) {
      final int i = uri.path.indexOf(_epubPrefix);
      if (i < 0) return null;
      final String encoded = uri.path.substring(i + _epubPrefix.length);
      return _sanitizeRel(Uri.decodeComponent(encoded));
    }
    // 已是相对路径（Uri 解析出的 host 为空）。
    return _sanitizeRel(raw);
  }

  /// 图片库磁盘文件路径 [filePath] → 稳定 key（相对 [extractDir]，正斜杠）。
  /// 文件不在 [extractDir] 内（`..` 越界）返回 `null`。
  static String? fromFile(String filePath, String extractDir) =>
      _sanitizeRel(p.relative(filePath, from: extractDir));

  /// 某图当前是否应显示防剧透遮罩：总开关 [blurEnabled] 开 + 有归一 [revealKey] +
  /// 未在已揭集 [revealed]。阅读器与图片库共用同一判据（缩略图 / 全屏都调它）。
  static bool shouldBlur({
    required bool blurEnabled,
    required String? revealKey,
    required Set<String> revealed,
  }) =>
      blurEnabled && revealKey != null && !revealed.contains(revealKey);

  /// 正斜杠归一 + 折叠 `.`/`..`/重复斜杠 + 去前导斜杠；越界 / 空返回 `null`。
  static String? _sanitizeRel(String rel) {
    if (rel.isEmpty) return null;
    String s = p.posix.normalize(rel.replaceAll('\\', '/'));
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    if (s.isEmpty || s == '.' || s == '..' || s.startsWith('../')) return null;
    return s;
  }
}
