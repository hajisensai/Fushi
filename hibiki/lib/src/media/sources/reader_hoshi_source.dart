import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';

import 'package:hibiki/language.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';

final hoshiBooksProvider =
    FutureProvider.family<List<MediaItem>, Language>((ref, language) {
  return ReaderHoshiSource.instance.getBooksFromDb(
    appModel: ref.watch(appProvider),
  );
});

class ReaderHoshiSource extends ReaderMediaSource {
  ReaderHoshiSource._()
      : super(
          uniqueKey: 'reader_ttu',
          sourceName: t.source_name_bookshelf,
          description: t.source_description_epub,
          icon: Icons.auto_stories_outlined,
          implementsSearch: false,
          implementsHistory: false,
          overridesAutoAudio: true,
        );

  static ReaderHoshiSource get instance => _instance;
  static final ReaderHoshiSource _instance = ReaderHoshiSource._();

  static int get defaultScrollingSpeed => 100;

  // ── Sasayaki sentence audio ─────────────────────────────────────────

  AudioCue? _pendingCue;
  List<File>? _pendingAudioFiles;

  void setPendingSentenceAudio({
    required AudioCue cue,
    required List<File> audioFiles,
  }) {
    _pendingCue = cue;
    _pendingAudioFiles = audioFiles;
  }

  void clearPendingSentenceAudio() {
    _pendingCue = null;
    _pendingAudioFiles = null;
  }

  @override
  Future<File?> generateAudio({
    required AppModel appModel,
    required MediaItem item,
    String? data,
  }) async {
    final AudioCue? cue = _pendingCue;
    final List<File>? audioFiles = _pendingAudioFiles;
    if (cue == null || audioFiles == null) {
      return null;
    }
    if (cue.audioFileIndex >= audioFiles.length) {
      return null;
    }
    final File inputFile = audioFiles[cue.audioFileIndex];
    final String outputPath =
        '${Directory.systemTemp.path}/mine_sentence_audio.m4a';
    final String? result = await TtsChannel.instance.extractAudioSegment(
      inputPath: inputFile.path,
      startMs: cue.startMs,
      endMs: cue.endMs,
      outputPath: outputPath,
    );
    if (result != null) {
      return File(result);
    }
    return null;
  }

  @override
  Future<void> onSourceExit({
    required AppModel appModel,
    required WidgetRef ref,
  }) async {
    ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
  }

  @override
  Future<void> onSearchBarTap({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) async {}

  @override
  BaseSourcePage buildLaunchPage({
    MediaItem? item,
    Bookmark? initialBookmarkJump,
  }) {
    final int bookId = _extractBookId(item?.mediaIdentifier ?? '');
    return ReaderHoshiPage(
      item: item,
      bookId: bookId,
      initialBookmarkJump: initialBookmarkJump,
    );
  }

  static int _extractBookId(String identifier) {
    // hoshi://book/123
    final Uri? uri = Uri.tryParse(identifier);
    if (uri != null && uri.pathSegments.length >= 2) {
      return int.tryParse(uri.pathSegments[1]) ?? 0;
    }
    // Legacy ttu URL: http://localhost:52059/b.html?id=123
    final String? idParam = uri?.queryParameters['id'];
    if (idParam != null) {
      return int.tryParse(idParam) ?? 0;
    }
    return 0;
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [
      buildBookImportButton(
          context: context, ref: ref, appModel: appModel),
      buildTweaksButton(
          context: context, ref: ref, appModel: appModel),
    ];
  }

  Widget buildBookImportButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return FloatingSearchBarAction(
      showIfOpened: true,
      child: JidoujishoIconButton(
        size: Theme.of(context).textTheme.titleLarge?.fontSize,
        tooltip: t.srt_import,
        icon: Icons.library_add_outlined,
        onTap: () async {
          final bool? imported = await showDialog<bool>(
            context: context,
            builder: (_) => BookImportDialog(
              repo: SrtBookRepository(appModel.database),
              audiobookRepo: AudiobookRepository(appModel.database),
              serverPort: portForLanguage(appModel.targetLanguage),
              ttuMediaSourceIdentifier: uniqueKey,
            ),
          );
          if (imported == true) {
            ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
          }
        },
      ),
    );
  }

  Widget buildTweaksButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return FloatingSearchBarAction(
      child: JidoujishoIconButton(
        size: Theme.of(context).textTheme.titleLarge?.fontSize,
        tooltip: t.tweaks,
        icon: Icons.tune,
        onTap: () {
          showAppDialog(
            context: context,
            builder: (context) => const TtuSettingsDialogPage(),
          );
        },
      ),
    );
  }

  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const ReaderTtuSourceHistoryPage();
  }

  // ── Book listing from Drift ─────────────────────────────────────────

  Future<List<MediaItem>> getBooksFromDb({
    required AppModel appModel,
  }) async {
    final HibikiDatabase db = appModel.database;
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    final ReaderPositionRepository posRepo = ReaderPositionRepository(db);

    final List<MediaItem> items = <MediaItem>[];
    for (final EpubBookRow book in books) {
      int position = 0;
      int duration = 1;

      List<int> sectionChars = const <int>[];
      if (book.chaptersJson.isNotEmpty) {
        try {
          final List<dynamic> chapters =
              jsonDecode(book.chaptersJson) as List<dynamic>;
          sectionChars = chapters
              .map((dynamic c) =>
                  ((c as Map<String, dynamic>)['characters'] as num?)
                      ?.toInt() ??
                  0)
              .toList();
        } catch (_) {}
      }
      final int totalChars =
          sectionChars.fold<int>(0, (int a, int b) => a + b);
      if (totalChars > 0) {
        duration = totalChars;
      }

      final pos = await posRepo.findByTtuBookId(book.id);
      if (pos != null && sectionChars.isNotEmpty) {
        final int clampedSection =
            pos.sectionIndex.clamp(0, sectionChars.length - 1);
        int charsRead = 0;
        for (int i = 0; i < clampedSection; i++) {
          charsRead += sectionChars[i];
        }
        position = charsRead;
      }

      items.add(MediaItem(
        mediaIdentifier: 'hoshi://book/${book.id}',
        title: book.title,
        base64Image: null,
        mediaTypeIdentifier: mediaType.uniqueKey,
        mediaSourceIdentifier: uniqueKey,
        position: position,
        duration: duration,
        canDelete: true,
        canEdit: true,
        sourceMetadata:
            totalChars > 0 ? jsonEncode(sectionChars) : null,
      ));
    }
    return items;
  }

  Future<bool> deleteBook({
    required HibikiDatabase db,
    required int bookId,
  }) async {
    try {
      await (db.delete(db.epubBooks)
            ..where((tbl) => tbl.id.equals(bookId)))
          .go();
      await EpubStorage.deleteBook(bookId);
      return true;
    } catch (e) {
      debugPrint('[ReaderHoshiSource] deleteBook failed: $e');
      return false;
    }
  }

  // ── Settings (same keys as ReaderTtuSource for seamless migration) ──

  int portForLanguage(Language language) {
    if (language is JapaneseLanguage) {
      return 52059;
    }
    if (language is EnglishLanguage) {
      return 52060;
    }
    throw UnimplementedError();
  }

  bool get volumePageTurningEnabled =>
      getPreference<bool>(
          key: 'volume_page_turning_enabled', defaultValue: true);

  void toggleVolumePageTurningEnabled() async {
    await setPreference<bool>(
      key: 'volume_page_turning_enabled',
      value: !volumePageTurningEnabled,
    );
  }

  bool get volumePageTurningInverted =>
      getPreference<bool>(
          key: 'volume_page_turning_inverted', defaultValue: false);

  void toggleVolumePageTurningInverted() async {
    await setPreference<bool>(
      key: 'volume_page_turning_inverted',
      value: !volumePageTurningInverted,
    );
  }

  bool get adaptTtuTheme =>
      getPreference<bool>(key: 'adapt_ttu_theme', defaultValue: true);

  void toggleAdaptTtuTheme() async {
    await setPreference<bool>(
      key: 'adapt_ttu_theme',
      value: !adaptTtuTheme,
    );
  }

  int get volumePageTurningSpeed =>
      getPreference<int>(
          key: 'volume_page_turning_speed',
          defaultValue: defaultScrollingSpeed);

  void setVolumePageTurningSpeed(int speed) async {
    await setPreference<int>(
      key: 'volume_page_turning_speed',
      value: speed,
    );
  }

  bool get autoReadOnLookup =>
      getPreference<bool>(key: 'auto_read_on_lookup', defaultValue: true);

  void toggleAutoReadOnLookup() async {
    await setPreference<bool>(
      key: 'auto_read_on_lookup',
      value: !autoReadOnLookup,
    );
  }

  double get dismissSwipeSensitivity =>
      getPreference<double>(
          key: 'dismiss_swipe_sensitivity', defaultValue: 0.6);

  Future<void> setDismissSwipeSensitivity(double value) async {
    await setPreference<double>(
      key: 'dismiss_swipe_sensitivity',
      value: value,
    );
  }

  bool get highlightOnTap =>
      getPreference<bool>(key: 'highlight_on_tap', defaultValue: true);

  void toggleHighlightOnTap() async {
    await setPreference<bool>(
      key: 'highlight_on_tap',
      value: !highlightOnTap,
    );
  }

  bool get keepScreenAwake =>
      getPreference<bool>(key: 'keep_screen_awake', defaultValue: true);

  void toggleKeepScreenAwake() async {
    await setPreference<bool>(
      key: 'keep_screen_awake',
      value: !keepScreenAwake,
    );
  }

  // ── ttu 阅读器设置 ─────────────────────────────────────────────────

  double get ttuFontSize =>
      getPreference<double>(key: 'ttu_font_size', defaultValue: 20);
  Future<void> setTtuFontSize(double v) =>
      setPreference<double>(key: 'ttu_font_size', value: v);

  double get ttuLineHeight =>
      getPreference<double>(key: 'ttu_line_height', defaultValue: 1.65);
  Future<void> setTtuLineHeight(double v) =>
      setPreference<double>(key: 'ttu_line_height', value: v);

  String get ttuWritingMode =>
      getPreference<String>(
          key: 'ttu_writing_mode', defaultValue: 'vertical-rl');
  Future<void> setTtuWritingMode(String v) =>
      setPreference<String>(key: 'ttu_writing_mode', value: v);

  String get ttuViewMode =>
      getPreference<String>(
          key: 'ttu_view_mode', defaultValue: 'paginated');
  Future<void> setTtuViewMode(String v) =>
      setPreference<String>(key: 'ttu_view_mode', value: v);

  String get ttuTheme =>
      getPreference<String>(
          key: 'ttu_theme', defaultValue: 'light-theme');
  Future<void> setTtuTheme(String v) =>
      setPreference<String>(key: 'ttu_theme', value: v);

  String get ttuFuriganaMode {
    final dynamic legacy =
        getPreference<bool?>(key: 'ttu_hide_furigana', defaultValue: null);
    if (legacy != null) {
      final String oldStyle = _legacyFuriganaStyle;
      final String mode = (legacy as bool) ? 'hide' : 'show';
      final String merged = normalizeFuriganaMode(
        (legacy && (oldStyle == 'partial' || oldStyle == 'toggle'))
            ? oldStyle
            : mode,
      );
      setPreference<String>(key: 'ttu_furigana_mode', value: merged);
      setPreference<bool?>(key: 'ttu_hide_furigana', value: null);
      return merged;
    }
    return normalizeFuriganaMode(
      getPreference<String>(key: 'ttu_furigana_mode', defaultValue: 'show'),
    );
  }

  Future<void> setTtuFuriganaMode(String v) => setPreference<String>(
      key: 'ttu_furigana_mode', value: normalizeFuriganaMode(v));

  double get ttuTextIndentation =>
      getPreference<double>(key: 'ttu_text_indentation', defaultValue: 0);
  Future<void> setTtuTextIndentation(double v) =>
      setPreference<double>(key: 'ttu_text_indentation', value: v);

  double get ttuFirstDimensionMargin =>
      getPreference<double>(
          key: 'ttu_first_dimension_margin', defaultValue: 0);
  Future<void> setTtuFirstDimensionMargin(double v) =>
      setPreference<double>(key: 'ttu_first_dimension_margin', value: v);

  double get ttuSecondDimensionMargin =>
      getPreference<double>(
          key: 'ttu_second_dimension_margin', defaultValue: 0);
  Future<void> setTtuSecondDimensionMargin(double v) =>
      setPreference<double>(key: 'ttu_second_dimension_margin', value: v);

  double get ttuSecondDimensionMaxValue =>
      getPreference<double>(
          key: 'ttu_second_dimension_max', defaultValue: 0);
  Future<void> setTtuSecondDimensionMaxValue(double v) =>
      setPreference<double>(key: 'ttu_second_dimension_max', value: v);

  int get ttuPageColumns =>
      getPreference<int>(key: 'ttu_page_columns', defaultValue: 0);
  Future<void> setTtuPageColumns(int v) =>
      setPreference<int>(key: 'ttu_page_columns', value: v);

  bool get ttuEnableVerticalFontKerning =>
      getPreference<bool>(key: 'ttu_vert_kerning', defaultValue: false);
  Future<void> setTtuEnableVerticalFontKerning(bool v) =>
      setPreference<bool>(key: 'ttu_vert_kerning', value: v);

  bool get ttuEnableFontVPAL =>
      getPreference<bool>(key: 'ttu_font_vpal', defaultValue: false);
  Future<void> setTtuEnableFontVPAL(bool v) =>
      setPreference<bool>(key: 'ttu_font_vpal', value: v);

  String get ttuVerticalTextOrientation =>
      getPreference<String>(
          key: 'ttu_vert_text_orient', defaultValue: 'mixed');
  Future<void> setTtuVerticalTextOrientation(String v) =>
      setPreference<String>(key: 'ttu_vert_text_orient', value: v);

  bool get ttuEnableTextJustification =>
      getPreference<bool>(key: 'ttu_text_justify', defaultValue: false);
  Future<void> setTtuEnableTextJustification(bool v) =>
      setPreference<bool>(key: 'ttu_text_justify', value: v);

  bool get ttuPrioritizeReaderStyles =>
      getPreference<bool>(key: 'ttu_reader_styles', defaultValue: false);
  Future<void> setTtuPrioritizeReaderStyles(bool v) =>
      setPreference<bool>(key: 'ttu_reader_styles', value: v);

  String get _legacyFuriganaStyle =>
      getPreference<String>(
              key: 'ttu_furigana_style', defaultValue: 'partial')
          .toLowerCase();

  // ── Custom fonts ────────────────────────────────────────────────────

  HttpServer? _fontServer;
  int get fontServerPort => 52061;

  Future<void> ensureFontServer() async {
    if (_fontServer != null) {
      return;
    }
    try {
      _fontServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        fontServerPort,
      );
      _fontServer!.listen((request) async {
        final String fontPath = Uri.decodeComponent(
            request.requestedUri.path.replaceFirst('/', ''));
        final File file = File(fontPath);
        request.response.headers
          ..set('Access-Control-Allow-Origin', '*')
          ..set('Access-Control-Allow-Methods', 'GET')
          ..set('Cache-Control', 'max-age=604800');
        if (request.method == 'OPTIONS') {
          request.response.statusCode = 204;
          await request.response.close();
          return;
        }
        if (await file.exists()) {
          final String ext = fontPath.split('.').last.toLowerCase();
          final String mime = switch (ext) {
            'woff2' => 'font/woff2',
            'woff' => 'font/woff',
            'otf' => 'font/otf',
            _ => 'font/ttf',
          };
          request.response.headers.set('Content-Type', mime);
          await file.openRead().pipe(request.response);
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
      debugPrint('[hibiki] Font server started on port $fontServerPort');
    } catch (e) {
      debugPrint('[hibiki] Font server failed: $e');
    }
  }

  List<Map<String, dynamic>> get customFonts {
    final String raw =
        getPreference<String>(key: 'custom_fonts', defaultValue: '[]');
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> setCustomFonts(List<Map<String, dynamic>> fonts) =>
      setPreference<String>(key: 'custom_fonts', value: jsonEncode(fonts));

  Future<void> addCustomFont({required String name, String? path}) async {
    final List<Map<String, dynamic>> list = customFonts;
    list.add(<String, dynamic>{
      'name': name,
      'path': path,
      'enabled': true,
    });
    await setCustomFonts(list);
  }

  Future<void> removeCustomFont(int index) async {
    final List<Map<String, dynamic>> list = customFonts;
    if (index < 0 || index >= list.length) {
      return;
    }
    final Map<String, dynamic> entry = list.removeAt(index);
    final String? filePath = entry['path'] as String?;
    if (filePath != null) {
      try {
        final File f = File(filePath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (e) {
        debugPrint(
            '[Hibiki] failed to delete custom font file $filePath: $e');
      }
    }
    await setCustomFonts(list);
  }

  Future<void> toggleCustomFont(int index) async {
    final List<Map<String, dynamic>> list = customFonts;
    if (index < 0 || index >= list.length) {
      return;
    }
    list[index]['enabled'] =
        !(list[index]['enabled'] as bool? ?? true);
    await setCustomFonts(list);
  }

  Future<void> reorderCustomFonts(int oldIndex, int newIndex) async {
    final List<Map<String, dynamic>> list = customFonts;
    if (newIndex > oldIndex) {
      newIndex--;
    }
    final Map<String, dynamic> item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setCustomFonts(list);
  }

  ({String fontFamily, String fontFaces}) buildCustomFontCss() {
    return customFontCssForEntries(customFonts,
        fontServerPort: fontServerPort);
  }

  static ({String fontFamily, String fontFaces}) customFontCssForEntries(
    Iterable<Map<String, dynamic>> fonts, {
    required int fontServerPort,
  }) {
    final Iterable<Map<String, dynamic>> enabled =
        fonts.where((e) => e['enabled'] as bool? ?? true);
    final List<String> families = <String>[];
    final List<String> faces = <String>[];
    for (final Map<String, dynamic> e in enabled) {
      final String name = e['name'] as String;
      final String normalizedName = normalizedFontFamilyName(name);
      families.add(cssFontFamilyName(normalizedName));
      final String? path = e['path'] as String?;
      if (path != null) {
        final String uri =
            'http://localhost:$fontServerPort/${Uri.encodeComponent(path)}';
        faces.add(
          '@font-face { font-family: ${cssFontFamilyName(normalizedName)}; '
          'src: url("$uri"); font-display: swap; }',
        );
      }
    }
    return (
      fontFamily: families.join(', '),
      fontFaces: faces.join('\n'),
    );
  }

  static String normalizedFontFamilyName(String name) {
    return name.replaceAll('_', ' ').trim();
  }

  static String cssFontFamilyName(String name) {
    final String normalized = normalizedFontFamilyName(name);
    final String escaped =
        normalized.replaceAll('\\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String cssFontFamilyList(Iterable<String> names) {
    return names.map(cssFontFamilyName).join(', ');
  }

  // ── Furigana helpers ────────────────────────────────────────────────

  static String normalizeFuriganaMode(String mode) {
    switch (mode) {
      case 'show':
      case 'hide':
      case 'partial':
      case 'toggle':
        return mode;
      default:
        return 'show';
    }
  }

  static String furiganaModeToStyle(String mode) {
    switch (normalizeFuriganaMode(mode)) {
      case 'hide':
        return 'Hide';
      case 'partial':
        return 'partial';
      case 'toggle':
        return 'toggle';
      default:
        return 'partial';
    }
  }
}
