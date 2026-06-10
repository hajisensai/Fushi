import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:hibiki/src/models/font_decoder.dart';
import 'package:hibiki/src/models/woff2_decoder.dart';
import 'package:hibiki/src/reader/reader_settings.dart'
    show ReaderCustomFontCss;
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// Registers a user-imported custom font with the Flutter engine so it can be
/// used for the app-wide UI [TextTheme], not just the reader WebView.
///
/// The reader serves font files to its WebView via CSS `@font-face`; that path
/// never touches the Flutter engine. To make a font file usable by Flutter
/// widgets it must be loaded at runtime through [FontLoader] — there is no
/// pubspec asset declaration for user files. This helper resolves the first
/// enabled entry from the passed font list (TODO-049: the app-wide UI target,
/// `appUiFonts`) and returns the family name to feed into `TextStyle.fontFamily`.
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
  static Future<String?> resolveAndLoad(
    List<Map<String, dynamic>> fonts,
  ) async {
    for (final Map<String, dynamic> font in fonts) {
      final bool enabled = font['enabled'] as bool? ?? true;
      if (!enabled) continue;

      final String? rawName = font['name'] as String?;
      if (rawName == null || rawName.trim().isEmpty) continue;

      // Use the SAME family identifier the reader uses (underscores → spaces)
      // so the App UI and the reader WebView reference one font under one name.
      final String family =
          ReaderCustomFontCss.normalizedFontFamilyName(rawName);
      if (family.isEmpty) continue;

      final String? path = font['path'] as String?;

      // System font (no imported file): the platform resolves it by family
      // name directly, no FontLoader registration is possible or needed.
      if (path == null) {
        return family;
      }

      final String ext = p.extension(path).toLowerCase();
      final bool isWoff = ext == _woffExtension;
      final bool isWoff2 = ext == _woff2Extension;
      if (!_directExtensions.contains(ext) && !isWoff && !isWoff2) continue;

      final File file = File(path);
      if (!file.existsSync()) continue;

      if (!_loadedFamilies.contains(family)) {
        try {
          Uint8List bytes = await file.readAsBytes();
          if (isWoff || isWoff2) {
            // FontLoader only accepts raw sfnt, so unwrap the web-font
            // container (WOFF2 first, then WOFF 1.0).
            final Uint8List? sfnt = isWoff2
                ? Woff2Decoder.toSfnt(bytes)
                : FontDecoder.woffToSfnt(bytes);
            if (sfnt == null) continue;
            bytes = sfnt;
          }
          final FontLoader loader = FontLoader(family)
            ..addFont(Future<ByteData>.value(bytes.buffer
                .asByteData(bytes.offsetInBytes, bytes.lengthInBytes)));
          await loader.load();
          _loadedFamilies.add(family);
        } catch (e, stack) {
          ErrorLogService.instance
              .log('AppFontLoader.resolveAndLoad', e, stack);
          continue;
        }
      }
      return family;
    }
    return null;
  }
}
