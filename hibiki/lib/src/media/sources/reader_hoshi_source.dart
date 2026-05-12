import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
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

  // ── identifier helpers ────────────────────────────────────────────────

  static const String kHost = 'hoshi.local';

  static String mediaIdentifierFor(int bookId) => 'hoshi://book/$bookId';

  static String bookUidFor(int bookId) => 'reader_ttu/hoshi://book/$bookId';

  static String epubUrl(String href) => 'https://$kHost/epub/$href';

  static String fontUrl(String path) =>
      'https://$kHost/fonts/${Uri.encodeComponent(path)}';

  static int? parseBookId(String identifier) {
    final Uri? uri = Uri.tryParse(identifier);
    if (uri == null) return null;
    if (uri.scheme == 'hoshi' &&
        uri.host == 'book' &&
        uri.pathSegments.isNotEmpty) {
      return int.tryParse(uri.pathSegments[0]);
    }
    final Match? legacy = RegExp(r'[?&]id=(\d+)').firstMatch(identifier);
    if (legacy != null) return int.tryParse(legacy.group(1)!);
    return null;
  }

  @override
  Future<void> prepareResources() async {
    final double? first = getPreference<double?>(
        key: 'ttu_first_dimension_margin', defaultValue: null);
    final double? second = getPreference<double?>(
        key: 'ttu_second_dimension_margin', defaultValue: null);
    if (first != null || second != null) {
      final bool hasNew = getPreference<double?>(
              key: 'ttu_margin_top', defaultValue: null) !=
          null;
      if (!hasNew) {
        final double tb = first ?? 0;
        final double lr = second ?? 0;
        await setPreference<double>(key: 'ttu_margin_top', value: tb);
        await setPreference<double>(key: 'ttu_margin_bottom', value: tb);
        await setPreference<double>(key: 'ttu_margin_left', value: lr);
        await setPreference<double>(key: 'ttu_margin_right', value: lr);
      }
    }
  }

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
        '${Directory.systemTemp.path}/mine_sentence_audio.aac';
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

  static int _extractBookId(String identifier) =>
      parseBookId(identifier) ?? 0;

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
              db: appModel.database,
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
            builder: (context) => const HoshiSettingsDialogPage(),
          );
        },
      ),
    );
  }

  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const ReaderHoshiHistoryPage();
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
        } catch (e, stack) {
          ErrorLogService.instance.log('ReaderHoshiSource.sectionChars', e, stack);
        }
      }
      final int totalChars =
          sectionChars.fold<int>(0, (a, b) => a + b);
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

      String? imageUrl;
      if (book.coverPath != null && book.coverPath!.isNotEmpty) {
        final String absPath = p.join(book.extractDir, book.coverPath);
        if (File(absPath).existsSync()) {
          imageUrl = Uri.file(absPath).toString();
        }
      }
      if (imageUrl == null) {
        final String fallback = p.join(book.extractDir, 'cover.jpg');
        if (File(fallback).existsSync()) {
          imageUrl = Uri.file(fallback).toString();
        }
      }

      items.add(MediaItem(
        mediaIdentifier: mediaIdentifierFor(book.id),
        title: book.title,
        imageUrl: imageUrl,
        mediaTypeIdentifier: mediaType.uniqueKey,
        mediaSourceIdentifier: uniqueKey,
        position: position,
        duration: duration,
        canDelete: false,
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
      final String bookUid = bookUidFor(bookId);

      final audiobookRepo = AudiobookRepository(db);
      final ab = await audiobookRepo.findByBookUid(bookUid);
      if (ab != null) {
        await audiobookRepo.deleteAudiobook(bookUid);
      }

      final srtRepo = SrtBookRepository(db);
      final srt = await srtRepo.findByTtuBookId(bookId);
      if (srt != null) {
        await srtRepo.delete(srt.uid);
      }

      await (db.delete(db.epubBooks)
            ..where((tbl) => tbl.id.equals(bookId)))
          .go();
      await EpubStorage.deleteBook(bookId);
      return true;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshiSource.deleteBook', e, stack);
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

  bool get volumeKeySentenceNavEnabled =>
      getPreference<bool>(
          key: 'volume_key_sentence_nav_enabled', defaultValue: true);

  void toggleVolumeKeySentenceNavEnabled() async {
    await setPreference<bool>(
      key: 'volume_key_sentence_nav_enabled',
      value: !volumeKeySentenceNavEnabled,
    );
  }

  bool get invertSwipeDirection =>
      getPreference<bool>(
          key: 'invert_swipe_direction', defaultValue: true);

  void toggleInvertSwipeDirection() async {
    await setPreference<bool>(
      key: 'invert_swipe_direction',
      value: !invertSwipeDirection,
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

  bool get lyricsMode =>
      getPreference<bool>(key: 'lyrics_mode', defaultValue: false);

  Future<void> setLyricsMode(bool value) async {
    await setPreference<bool>(key: 'lyrics_mode', value: value);
  }

  bool get tapEmptyToHideChrome =>
      getPreference<bool>(key: 'tap_empty_hide_chrome', defaultValue: false);

  void toggleTapEmptyToHideChrome() async {
    await setPreference<bool>(
      key: 'tap_empty_hide_chrome',
      value: !tapEmptyToHideChrome,
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

  double get ttuMarginTop =>
      getPreference<double>(key: 'ttu_margin_top', defaultValue: 0);
  Future<void> setTtuMarginTop(double v) =>
      setPreference<double>(key: 'ttu_margin_top', value: v);

  double get ttuMarginBottom =>
      getPreference<double>(key: 'ttu_margin_bottom', defaultValue: 0);
  Future<void> setTtuMarginBottom(double v) =>
      setPreference<double>(key: 'ttu_margin_bottom', value: v);

  double get ttuMarginLeft =>
      getPreference<double>(key: 'ttu_margin_left', defaultValue: 0);
  Future<void> setTtuMarginLeft(double v) =>
      setPreference<double>(key: 'ttu_margin_left', value: v);

  double get ttuMarginRight =>
      getPreference<double>(key: 'ttu_margin_right', defaultValue: 0);
  Future<void> setTtuMarginRight(double v) =>
      setPreference<double>(key: 'ttu_margin_right', value: v);

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

  List<Map<String, dynamic>> get customFonts {
    final String raw =
        getPreference<String>(key: 'custom_fonts', defaultValue: '[]');
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshiSource.customFonts', e, stack);
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
      } catch (e, stack) {
        ErrorLogService.instance.log('ReaderHoshiSource.deleteFont', e, stack);
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
    return customFontCssForEntries(customFonts);
  }

  static ({String fontFamily, String fontFaces}) customFontCssForEntries(
    Iterable<Map<String, dynamic>> fonts,
  ) {
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
        final String uri = fontUrl(path);
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
    final String lower = mode.toLowerCase();
    switch (lower) {
      case 'show':
      case 'hide':
      case 'partial':
      case 'toggle':
        return lower;
      default:
        return 'show';
    }
  }

  static String furiganaModeToStyle(String mode) {
    switch (normalizeFuriganaMode(mode)) {
      case 'hide':
        return 'Hide';
      case 'partial':
        return 'Partial';
      case 'toggle':
        return 'Toggle';
      default:
        return 'Show';
    }
  }
}
