import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// TODO-049: 词典弹窗字体的 CSS 构造。
///
/// 词典弹窗是一个独立的小 WebView（assets/popup/popup.css 里把 `font-family` 写死成
/// `"Hiragino Sans", ...`），既不走阅读器的 `hoshi.local/fonts/` 拦截器，Windows 端
/// 又用 about:blank 的 `NavigateToString` 加载，无法用相对/虚拟 URL 引用磁盘字体文件。
///
/// 为在 5 平台一致地支持用户配置的词典字体，这里用两条零跨平台差异的注入路径：
///   - 系统字体（`path == null`）：直接产出 CSS `font-family: "Name"`，由各平台字体栈
///     解析，无需任何文件服务。
///   - 导入字体文件（`path != null`）：把字体字节内联成 `data:` URL 的 `@font-face`
///     `src`，WebView 自行解码 ttf/otf/woff/woff2/ttc。`data:` URL 在 about:blank 与
///     所有平台都有效，无需拦截器或自定义 scheme。
///
/// 返回的 [fontFamily] 串可拼到 popup 的 `font-family`（在词典名之前作为首选），
/// [fontFaces] 是若干 `@font-face` 声明。两者均为空时调用方应回退到 popup.css 默认。
class DictionaryFontCss {
  const DictionaryFontCss._();

  /// MIME `format()` hint per font extension, so the WebView picks the right
  /// decoder for the inlined `data:` URL.
  static const Map<String, ({String mime, String format})> _fontTypes =
      <String, ({String mime, String format})>{
    '.ttf': (mime: 'font/ttf', format: 'truetype'),
    '.otf': (mime: 'font/otf', format: 'opentype'),
    '.ttc': (mime: 'font/collection', format: 'collection'),
    '.woff': (mime: 'font/woff', format: 'woff'),
    '.woff2': (mime: 'font/woff2', format: 'woff2'),
  };

  /// Builds the dictionary font CSS for [fonts] (a `[{name,path,enabled}]`
  /// list). [allowedDirectories] gates which file paths may be inlined (same
  /// whitelist model as the reader's font serving). Reads happen synchronously;
  /// any unreadable / oversized / unknown-extension file is skipped, degrading
  /// to the remaining usable fonts (and ultimately the popup.css default).
  static ({String fontFamily, String fontFaces}) build(
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
    int maxFileBytes = _defaultMaxFileBytes,
  }) {
    final Iterable<Map<String, dynamic>> enabled =
        fonts.where((Map<String, dynamic> e) => e['enabled'] as bool? ?? true);
    final List<String> families = <String>[];
    final List<String> faces = <String>[];

    for (final Map<String, dynamic> e in enabled) {
      final String? rawName = e['name'] as String?;
      if (rawName == null || rawName.trim().isEmpty) continue;
      final String cssName = ReaderCustomFontCss.cssFontFamilyName(rawName);

      final String? fontPath = e['path'] as String?;
      if (fontPath == null) {
        // System font: the platform resolves it by family name directly.
        families.add(cssName);
        continue;
      }

      final ({String mime, String format})? type =
          _fontTypes[p.extension(fontPath).toLowerCase()];
      if (type == null) continue;

      final String? safePath = ReaderCustomFontCss.safeFontPath(
        fontPath,
        allowedRoots: allowedDirectories,
      );
      if (safePath == null) continue;

      final String? dataUrl =
          _inlineFontDataUrl(safePath, type.mime, maxFileBytes);
      if (dataUrl == null) continue;

      families.add(cssName);
      faces.add(
        '@font-face { font-family: $cssName; '
        'src: url("$dataUrl") format("${type.format}"); '
        'font-display: swap; }',
      );
    }

    return (
      fontFamily: families.join(', '),
      fontFaces: faces.join('\n'),
    );
  }

  /// Default cap on a single inlined font file (8 MiB). A `data:` URL embeds the
  /// whole file in the injected CSS string, so an unbounded read could bloat the
  /// payload; CJK fonts above this are skipped (system-name fonts are unaffected).
  static const int _defaultMaxFileBytes = 8 * 1024 * 1024;

  static String? _inlineFontDataUrl(String path, String mime, int maxBytes) {
    try {
      final File file = File(path);
      if (!file.existsSync()) return null;
      final int length = file.lengthSync();
      if (length <= 0 || length > maxBytes) return null;
      final List<int> bytes = file.readAsBytesSync();
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryFontCss.inline', e, stack);
      return null;
    }
  }
}
