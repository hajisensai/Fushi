import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:fushi/src/media/video/ass_font_metrics.dart';
import 'package:fushi/src/models/font_decoder.dart';
import 'package:fushi/src/models/woff2_decoder.dart';
import 'package:fushi/src/reader/reader_settings.dart'
    show ReaderCustomFontCss;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// Registers a user-imported custom font with the Flutter engine so it can be
/// used for the app-wide UI [TextTheme], not just the reader WebView.
///
/// The reader serves font files to its WebView via CSS `@font-face`; that path
/// never touches the Flutter engine. To make a font file usable by Flutter
/// widgets it must be loaded at runtime through [FontLoader] — there is no
/// pubspec asset declaration for user files. This helper resolves entries from
/// the passed font list (TODO-049: the app-wide UI target, `appUiFonts`) and
/// returns the family name(s) to feed into `TextStyle.fontFamily` /
/// `fontFamilyFallback`: [resolveAndLoadAll] for targets that consume the whole
/// ordered list as a fallback chain, [resolveAndLoad] for single-family targets.
class AppFontLoader {
  AppFontLoader._();

  /// Raw sfnt the Flutter engine loads as-is.
  static const Set<String> _directExtensions = <String>{'.ttf', '.otf', '.ttc'};

  /// Web-font containers decoded to sfnt before loading: WOFF 1.0 via
  /// [FontDecoder] (zlib) and WOFF2 via [Woff2Decoder] (Brotli + glyf/loca
  /// transform). An entry that fails to decode is skipped, falling through to
  /// the next usable candidate.
  static const String _woffExtension = '.woff';
  static const String _woff2Extension = '.woff2';

  /// Family names already registered this process. [FontLoader] cannot unload a
  /// family, so re-registering the same one is wasteful and pointless.
  static final Set<String> _loadedFamilies = <String>{};

  /// Resolves the app-wide custom font from [fonts] (the `customFonts` list,
  /// each entry `{name, path, enabled}`), registering its file with the engine
  /// when needed. Returns the family name to use, or `null` when no usable
  /// custom font is set — the caller then falls back to the language default.
  ///
  /// Stops at the first usable entry: targets that render with a single family
  /// (video subtitles, which carry their own CJK fallback chain) must not pay
  /// for registering fonts they will never reference. Targets that DO consume
  /// the whole ordered list use [resolveAndLoadAll].
  static Future<String?> resolveAndLoad(
    List<Map<String, dynamic>> fonts,
  ) async {
    for (final Map<String, dynamic> font in fonts) {
      final String? family = await _resolveEntry(font);
      if (family != null) return family;
    }
    return null;
  }

  /// Resolves **every** usable entry of [fonts], in the user's order, and
  /// registers each one with the engine.
  ///
  /// The font library is an ordered list, and for the app-UI target that order
  /// IS the fallback chain (`TextStyle.fontFamily` + `fontFamilyFallback`, see
  /// `app_ui_font_chain.dart`). [resolveAndLoad] returning only the first entry
  /// silently dropped every later one — a user whose primary font lacks a glyph
  /// never reached their own second choice, the engine's default fallback took
  /// over instead. A family that is never registered here is a dead name in a
  /// Flutter fallback chain, so registration must cover the whole list.
  ///
  /// Unusable entries (disabled / unnamed / unreadable / undecodable) are
  /// skipped, never throwing; the result keeps the surviving entries' order.
  static Future<List<String>> resolveAndLoadAll(
    List<Map<String, dynamic>> fonts,
  ) async {
    final List<String> families = <String>[];
    for (final Map<String, dynamic> font in fonts) {
      final String? family = await _resolveEntry(font);
      // 同名条目只保留一次：重复家族名在回退链里没有意义（引擎按名解析），
      // 只会让「第几个生效」变得无法推理。
      if (family != null && !families.contains(family)) families.add(family);
    }
    return families;
  }

  /// Resolves one `{name, path, enabled}` entry to a registered family name, or
  /// null when the entry is unusable. Registration is idempotent per family.
  static Future<String?> _resolveEntry(Map<String, dynamic> font) async {
    final bool enabled = font['enabled'] as bool? ?? true;
    if (!enabled) return null;

    final String? rawName = font['name'] as String?;
    if (rawName == null || rawName.trim().isEmpty) return null;

    // Use the SAME family identifier the reader uses (underscores → spaces)
    // so the App UI and the reader WebView reference one font under one name.
    final String family = ReaderCustomFontCss.normalizedFontFamilyName(rawName);
    if (family.isEmpty) return null;

    final String? path = font['path'] as String?;

    // System font (no imported file): the platform resolves it by family
    // name directly, no FontLoader registration is possible or needed.
    if (path == null) {
      return family;
    }

    final String ext = p.extension(path).toLowerCase();
    final bool isWoff = ext == _woffExtension;
    final bool isWoff2 = ext == _woff2Extension;
    if (!_directExtensions.contains(ext) && !isWoff && !isWoff2) return null;

    final File file = File(path);
    if (!file.existsSync()) return null;

    if (_loadedFamilies.contains(family)) return family;

    try {
      Uint8List bytes = await file.readAsBytes();
      if (isWoff || isWoff2) {
        // FontLoader only accepts raw sfnt, so unwrap the web-font
        // container (WOFF2 first, then WOFF 1.0).
        final Uint8List? sfnt = isWoff2
            ? Woff2Decoder.toSfnt(bytes)
            : FontDecoder.woffToSfnt(bytes);
        if (sfnt == null) return null;
        bytes = sfnt;
      }
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(
            bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes)));
      await loader.load();
      _loadedFamilies.add(family);
      // BUG-897：自定义字体不在系统字体目录（扫描不到），把字节同步喂进 ASS 字号
      // 换算索引（OS/2 win cell 语义），别名=本处注册的家族名——视频字幕用自定义
      // 字体时字号也与 mpv/libass 同源。
      AssFontCellIndex.instance
          .registerFontBytes(bytes, aliases: <String>[family]);
    } catch (e, stack) {
      ErrorLogService.instance.log('AppFontLoader.resolveAndLoad', e, stack);
      return null;
    }
    return family;
  }
}
