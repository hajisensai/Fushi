import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/utils.dart';

final hibikiBooksProvider =
    FutureProvider.family<List<MediaItem>, Language>((ref, language) {
  return ReaderHibikiSource.instance.getBooksFromDb(
    appModel: ref.watch(appProvider),
  );
});

final srtBooksProvider = FutureProvider<List<SrtBook>>((ref) {
  final db = ref.watch(appProvider).database;
  return SrtBookRepository(db).listAll();
});

class ReaderHibikiSource extends ReaderMediaSource {
  ReaderHibikiSource._()
      : super(
          uniqueKey: 'reader_ttu',
          sourceName: t.source_name_bookshelf,
          description: t.source_description_epub,
          icon: Icons.auto_stories_outlined,
          implementsSearch: false,
          implementsHistory: false,
        );

  static ReaderHibikiSource get instance => _instance;
  static final ReaderHibikiSource _instance = ReaderHibikiSource._();

  static int get defaultScrollingSpeed => 100;

  // ── identifier helpers ────────────────────────────────────────────────

  static const String kHost = 'hoshi.local';

  static String mediaIdentifierFor(int bookId) => 'hoshi://book/$bookId';

  static String bookUidFor(int bookId) => 'reader_ttu/hoshi://book/$bookId';

  // HBK-AUDIT-127: percent-encode the href when building the URL so it is
  // symmetric with the consumer side, which decodes the whole post-'/epub/'
  // path with Uri.decodeComponent (reader_hibiki_page.dart, epub_book.dart).
  // Encoding per path segment (and rejoining with '/') preserves the path
  // structure while escaping spaces and literal '%' (which a raw href would
  // leave to be mis-decoded or to throw on decode). Mirrors fontUrl's encoding.
  static String epubUrl(String href) {
    final String encoded = href.split('/').map(Uri.encodeComponent).join('/');
    return 'https://$kHost/epub/$encoded';
  }

  static String fontUrl(String path) => ReaderCustomFontCss.fontUrl(path);

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
  Future<void> prepareResources() async {}

  // HBK-AUDIT-042 / HBK-AUDIT-124: removed the dead generateAudio override and
  // its _pendingCue/_pendingAudioFiles + setPendingSentenceAudio/
  // clearPendingSentenceAudio machinery. They had zero callers, so the override
  // always returned null; the live sentence-audio mining is done inline in
  // reader_hibiki_page.dart. The misleading overridesAutoAudio:true flag was
  // dropped from the constructor (now defaults to false) for the same reason.

  @override
  Future<void> onSourceExit({
    required AppModel appModel,
    required WidgetRef ref,
  }) async {
    ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
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
    return ReaderHibikiPage(
      item: item,
      bookId: bookId,
      initialBookmarkJump: initialBookmarkJump,
    );
  }

  // HBK-AUDIT-126: parseBookId returns null for an empty/unknown identifier.
  // Previously this silently coerced null to the 0 sentinel, launching the
  // reader against bookUidFor(0) (a nonexistent book) and hiding genuine
  // identifier corruption behind an empty/error reader screen. We now log the
  // failure so the corruption is observable instead of swallowed; the 0
  // sentinel remains only because ReaderHibikiPage.bookId is a non-null int and
  // ReaderHibikiPage already renders an empty/error state for an unknown id.
  static int _extractBookId(String identifier) {
    final int? bookId = parseBookId(identifier);
    if (bookId == null) {
      ErrorLogService.instance.log(
        'ReaderHibikiSource._extractBookId',
        'unparseable media identifier: "$identifier"',
        StackTrace.current,
      );
      return 0;
    }
    return bookId;
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [
      buildBookImportButton(context: context, ref: ref, appModel: appModel),
      buildTweaksButton(context: context, ref: ref, appModel: appModel),
    ];
  }

  Widget buildBookImportButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return HibikiIconButton(
      size: Theme.of(context).textTheme.titleLarge?.fontSize,
      tooltip: t.srt_import,
      icon: Icons.library_add_outlined,
      onTap: () async {
        final bool? imported = await showAppDialog<bool>(
          context: context,
          builder: (_) => BookImportDialog(
            repo: SrtBookRepository(appModel.database),
            audiobookRepo: AudiobookRepository(appModel.database),
            db: appModel.database,
          ),
        );
        if (imported == true) {
          ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
          ref.invalidate(srtBooksProvider);
        }
      },
    );
  }

  Widget buildTweaksButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return HibikiIconButton(
      size: Theme.of(context).textTheme.titleLarge?.fontSize,
      tooltip: t.tweaks,
      icon: Icons.tune_outlined,
      onTap: () {
        showAppDialog(
          context: context,
          builder: (context) => const HibikiSettingsDialogPage(),
        );
      },
    );
  }

  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const ReaderHibikiHistoryPage();
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
          ErrorLogService.instance
              .log('ReaderHibikiSource.sectionChars', e, stack);
        }
      }
      final int totalChars = sectionChars.fold<int>(0, (a, b) => a + b);
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
        String coverRel = book.coverPath!;
        if (coverRel.startsWith('/')) coverRel = coverRel.substring(1);
        final String absPath = p.join(book.extractDir, coverRel);
        if (await File(absPath).exists()) {
          imageUrl = Uri.file(absPath).toString();
        }
      }
      if (imageUrl == null) {
        for (final String name in const [
          'cover.jpg',
          'cover.jpeg',
          'cover.png',
        ]) {
          final String fallback = p.join(book.extractDir, name);
          if (await File(fallback).exists()) {
            imageUrl = Uri.file(fallback).toString();
            break;
          }
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
        sourceMetadata: totalChars > 0 ? jsonEncode(sectionChars) : null,
      ));
    }
    return items;
  }

  /// Delete a book and all of its associated data.
  ///
  /// Pass [appModel] to also clear the override thumbnail file (it is needed to
  /// resolve the thumbnails directory); the override title preference is always
  /// cleared regardless (HBK-AUDIT-040).
  Future<bool> deleteBook({
    required HibikiDatabase db,
    required int bookId,
    AppModel? appModel,
  }) async {
    try {
      final String bookUid = bookUidFor(bookId);

      // HBK-AUDIT-041: db.deleteEpubBook removes every associated DB row
      // (readerPositions, bookmarks, srtBooks, audioCues, audiobooks for the
      // same bookUid) inside one transaction. Previously deleteBook ALSO
      // deleted the audiobook/srt rows via the repos, double-deleting the same
      // rows and splitting the deletion across non-atomic layers. We now let
      // the transaction own all row deletes and only run the non-redundant
      // on-disk cleanups (deletePersistDir, extracted dir) afterwards.
      //
      // The srt uid must be resolved BEFORE the transaction, because
      // deleteEpubBook deletes the srtBooks row it lives on.
      final SrtBookRepository srtRepo = SrtBookRepository(db);
      final SrtBook? srt = await srtRepo.findByTtuBookId(bookId);

      await db.deleteEpubBook(bookId);

      // On-disk cleanups (not covered by the DB transaction).
      await AudiobookStorage.deletePersistDir(bookUid);
      if (srt != null) {
        await AudiobookStorage.deletePersistDir(srt.uid);
      }
      await EpubStorage.deleteBook(bookId);

      // HBK-AUDIT-040: these books are created with canDelete:false, so the
      // generic AppModel.deleteMediaItem cleanup (clearOverrideValues) never
      // runs for them. Clear the override title preference here, and the
      // override thumbnail file when an AppModel is available, so renamed/
      // recovered books do not leave orphaned override rows/files behind.
      final MediaItem item = MediaItem(
        mediaIdentifier: mediaIdentifierFor(bookId),
        title: '',
        mediaTypeIdentifier: mediaType.uniqueKey,
        mediaSourceIdentifier: uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
      if (appModel != null) {
        await clearOverrideValues(appModel: appModel, item: item);
      } else {
        await deletePreference(key: getOverrideTitleKey(item));
      }
      return true;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibikiSource.deleteBook', e, stack);
      debugPrint('[ReaderHibikiSource] deleteBook failed: $e');
      return false;
    }
  }

  // ── Settings (same keys as ReaderTtuSource for seamless migration) ──

  static ReaderSettings? readerSettings;

  static VoidCallback? onSettingsChangedLive;

  // HBK-AUDIT-124: removed the dead instance portForLanguage. It had zero call
  // sites and duplicated the live TtuMigrationServer.portForLanguage; for any
  // third language it would have thrown UnimplementedError.

  bool get volumePageTurningEnabled => getPreference<bool>(
      key: 'volume_page_turning_enabled', defaultValue: true);

  void toggleVolumePageTurningEnabled() async {
    await setPreference<bool>(
      key: 'volume_page_turning_enabled',
      value: !volumePageTurningEnabled,
    );
  }

  bool get volumePageTurningInverted => getPreference<bool>(
      key: 'volume_page_turning_inverted', defaultValue: false);

  void toggleVolumePageTurningInverted() async {
    await setPreference<bool>(
      key: 'volume_page_turning_inverted',
      value: !volumePageTurningInverted,
    );
  }

  int get volumePageTurningSpeed =>
      readerSettings?.volumePageTurningSpeed ??
      getPreference<int>(
        key: 'volume_page_turning_speed',
        defaultValue: defaultScrollingSpeed,
      );

  void setVolumePageTurningSpeed(int speed) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setVolumePageTurningSpeed(speed);
      return;
    }
    await setPreference<int>(
      key: 'volume_page_turning_speed',
      value: speed,
    );
  }

  bool get volumeKeySentenceNavEnabled => getPreference<bool>(
      key: 'volume_key_sentence_nav_enabled', defaultValue: true);

  void toggleVolumeKeySentenceNavEnabled() async {
    await setPreference<bool>(
      key: 'volume_key_sentence_nav_enabled',
      value: !volumeKeySentenceNavEnabled,
    );
  }

  bool get invertSwipeDirection =>
      readerSettings?.invertSwipeDirection ??
      getPreference<bool>(
        key: 'invert_swipe_direction',
        defaultValue: true,
      );

  void toggleInvertSwipeDirection() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleInvertSwipeDirection();
      return;
    }
    await setPreference<bool>(
      key: 'invert_swipe_direction',
      value: !invertSwipeDirection,
    );
  }

  bool get autoReadOnLookup =>
      readerSettings?.autoReadOnLookup ??
      getPreference<bool>(key: 'auto_read_on_lookup', defaultValue: true);

  void toggleAutoReadOnLookup() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleAutoReadOnLookup();
      return;
    }
    await setPreference<bool>(
      key: 'auto_read_on_lookup',
      value: !autoReadOnLookup,
    );
  }

  bool get pauseOnLookup =>
      getPreference<bool>(key: 'pause_on_lookup', defaultValue: false);

  Future<void> setPauseOnLookup({required bool value}) async {
    await setPreference<bool>(key: 'pause_on_lookup', value: value);
  }

  /// 0 = skip by sentence (default), 5/10/15/30 = skip by N seconds.
  int get skipActionSeconds =>
      getPreference<int>(key: 'skip_action_seconds', defaultValue: 0);

  Future<void> setSkipActionSeconds(int value) async {
    await setPreference<int>(key: 'skip_action_seconds', value: value);
    onSettingsChangedLive?.call();
  }

  double get dismissSwipeSensitivity =>
      readerSettings?.dismissSwipeSensitivity ??
      getPreference<double>(
        key: 'dismiss_swipe_sensitivity',
        defaultValue: 0.6,
      );

  Future<void> setDismissSwipeSensitivity(double value) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setDismissSwipeSensitivity(value);
      return;
    }
    await setPreference<double>(
      key: 'dismiss_swipe_sensitivity',
      value: value,
    );
  }

  bool get highlightOnTap =>
      readerSettings?.highlightOnTap ??
      getPreference<bool>(key: 'highlight_on_tap', defaultValue: true);

  void toggleHighlightOnTap() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleHighlightOnTap();
      return;
    }
    await setPreference<bool>(
      key: 'highlight_on_tap',
      value: !highlightOnTap,
    );
  }

  bool get keepScreenAwake =>
      readerSettings?.keepScreenAwake ??
      getPreference<bool>(key: 'keep_screen_awake', defaultValue: true);

  void toggleKeepScreenAwake() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleKeepScreenAwake();
      return;
    }
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
      readerSettings?.tapEmptyToHideChrome ??
      getPreference<bool>(key: 'tap_empty_hide_chrome', defaultValue: false);

  void toggleTapEmptyToHideChrome() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleTapEmptyToHideChrome();
      return;
    }
    await setPreference<bool>(
      key: 'tap_empty_hide_chrome',
      value: !tapEmptyToHideChrome,
    );
  }

  // ── ttu 阅读器设置 ─────────────────────────────────────────────────

  double get ttuFontSize =>
      readerSettings?.fontSize ??
      getPreference<double>(key: 'ttu_font_size', defaultValue: 20);
  Future<void> setTtuFontSize(double v) async {
    await (readerSettings?.setFontSize(v) ??
        setPreference<double>(key: 'ttu_font_size', value: v));
    onSettingsChangedLive?.call();
  }

  double get lyricsFontSize =>
      readerSettings?.lyricsFontSize ??
      getPreference<double>(key: 'lyrics_font_size', defaultValue: 24);
  Future<void> setLyricsFontSize(double v) async {
    await (readerSettings?.setLyricsFontSize(v) ??
        setPreference<double>(key: 'lyrics_font_size', value: v));
    onSettingsChangedLive?.call();
  }

  double get lyricsMarginTop =>
      readerSettings?.lyricsMarginTop ??
      getPreference<double>(key: 'lyrics_margin_top', defaultValue: 0);
  Future<void> setLyricsMarginTop(double v) async {
    await (readerSettings?.setLyricsMarginTop(v) ??
        setPreference<double>(key: 'lyrics_margin_top', value: v));
    onSettingsChangedLive?.call();
  }

  double get lyricsMarginBottom =>
      readerSettings?.lyricsMarginBottom ??
      getPreference<double>(key: 'lyrics_margin_bottom', defaultValue: 0);
  Future<void> setLyricsMarginBottom(double v) async {
    await (readerSettings?.setLyricsMarginBottom(v) ??
        setPreference<double>(key: 'lyrics_margin_bottom', value: v));
    onSettingsChangedLive?.call();
  }

  double get lyricsMarginLeft =>
      readerSettings?.lyricsMarginLeft ??
      getPreference<double>(key: 'lyrics_margin_left', defaultValue: 0);
  Future<void> setLyricsMarginLeft(double v) async {
    await (readerSettings?.setLyricsMarginLeft(v) ??
        setPreference<double>(key: 'lyrics_margin_left', value: v));
    onSettingsChangedLive?.call();
  }

  double get lyricsMarginRight =>
      readerSettings?.lyricsMarginRight ??
      getPreference<double>(key: 'lyrics_margin_right', defaultValue: 0);
  Future<void> setLyricsMarginRight(double v) async {
    await (readerSettings?.setLyricsMarginRight(v) ??
        setPreference<double>(key: 'lyrics_margin_right', value: v));
    onSettingsChangedLive?.call();
  }

  double get ttuLineHeight =>
      readerSettings?.lineHeight ??
      getPreference<double>(key: 'ttu_line_height', defaultValue: 1.65);
  Future<void> setTtuLineHeight(double v) async {
    await (readerSettings?.setLineHeight(v) ??
        setPreference<double>(key: 'ttu_line_height', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuWritingMode =>
      readerSettings?.writingMode ??
      getPreference<String>(
        key: 'ttu_writing_mode',
        defaultValue: 'vertical-rl',
      );
  Future<void> setTtuWritingMode(String v) async {
    await (readerSettings?.setWritingMode(v) ??
        setPreference<String>(key: 'ttu_writing_mode', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuViewMode =>
      readerSettings?.viewMode ??
      getPreference<String>(
        key: 'ttu_view_mode',
        defaultValue: 'paginated',
      );
  Future<void> setTtuViewMode(String v) async {
    await (readerSettings?.setViewMode(v) ??
        setPreference<String>(key: 'ttu_view_mode', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuTheme =>
      readerSettings?.theme ??
      getPreference<String>(
        key: 'ttu_theme',
        defaultValue: 'light-theme',
      );
  Future<void> setTtuTheme(String v) async {
    await (readerSettings?.setTheme(v) ??
        setPreference<String>(key: 'ttu_theme', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuFuriganaMode {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      return settings.furiganaMode;
    }
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
      // HBK-AUDIT-125: remove the legacy key via deletePreference. The old
      // setPreference<bool?>(value: null) could not represent null through
      // PrefCodec.encode and persisted the literal string 's:null', leaving a
      // junk row that was re-decoded as the String 'null' on every read.
      deletePreference(key: 'ttu_hide_furigana');
      return merged;
    }
    return normalizeFuriganaMode(
      getPreference<String>(key: 'ttu_furigana_mode', defaultValue: 'show'),
    );
  }

  Future<void> setTtuFuriganaMode(String v) async {
    await (readerSettings?.setFuriganaMode(v) ??
        setPreference<String>(
          key: 'ttu_furigana_mode',
          value: normalizeFuriganaMode(v),
        ));
    onSettingsChangedLive?.call();
  }

  double get ttuTextIndentation =>
      readerSettings?.textIndentation ??
      getPreference<double>(key: 'ttu_text_indentation', defaultValue: 0);
  Future<void> setTtuTextIndentation(double v) async {
    await (readerSettings?.setTextIndentation(v) ??
        setPreference<double>(key: 'ttu_text_indentation', value: v));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginTop =>
      readerSettings?.marginTop ??
      getPreference<double>(key: 'ttu_margin_top', defaultValue: 0);
  Future<void> setTtuMarginTop(double v) async {
    await (readerSettings?.setMarginTop(v) ??
        setPreference<double>(key: 'ttu_margin_top', value: v));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginBottom =>
      readerSettings?.marginBottom ??
      getPreference<double>(key: 'ttu_margin_bottom', defaultValue: 0);
  Future<void> setTtuMarginBottom(double v) async {
    await (readerSettings?.setMarginBottom(v) ??
        setPreference<double>(key: 'ttu_margin_bottom', value: v));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginLeft =>
      readerSettings?.marginLeft ??
      getPreference<double>(key: 'ttu_margin_left', defaultValue: 0);
  Future<void> setTtuMarginLeft(double v) async {
    await (readerSettings?.setMarginLeft(v) ??
        setPreference<double>(key: 'ttu_margin_left', value: v));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginRight =>
      readerSettings?.marginRight ??
      getPreference<double>(key: 'ttu_margin_right', defaultValue: 0);
  Future<void> setTtuMarginRight(double v) async {
    await (readerSettings?.setMarginRight(v) ??
        setPreference<double>(key: 'ttu_margin_right', value: v));
    onSettingsChangedLive?.call();
  }

  int get ttuPageColumns =>
      readerSettings?.pageColumns ??
      getPreference<int>(key: 'ttu_page_columns', defaultValue: 0);
  Future<void> setTtuPageColumns(int v) async {
    await (readerSettings?.setPageColumns(v) ??
        setPreference<int>(key: 'ttu_page_columns', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuSpreadMode =>
      readerSettings?.spreadMode ??
      getPreference<String>(key: 'ttu_spread_mode', defaultValue: 'auto');
  Future<void> setTtuSpreadMode(String v) async {
    await (readerSettings?.setSpreadMode(v) ??
        setPreference<String>(key: 'ttu_spread_mode', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuSpreadDirection =>
      readerSettings?.spreadDirection ??
      getPreference<String>(key: 'ttu_spread_direction', defaultValue: 'rtl');
  Future<void> setTtuSpreadDirection(String v) async {
    await (readerSettings?.setSpreadDirection(v) ??
        setPreference<String>(key: 'ttu_spread_direction', value: v));
    onSettingsChangedLive?.call();
  }

  bool get ttuEnableVerticalFontKerning =>
      readerSettings?.enableVerticalFontKerning ??
      getPreference<bool>(key: 'ttu_vert_kerning', defaultValue: false);
  Future<void> setTtuEnableVerticalFontKerning(bool v) async {
    await (readerSettings?.setEnableVerticalFontKerning(v) ??
        setPreference<bool>(key: 'ttu_vert_kerning', value: v));
    onSettingsChangedLive?.call();
  }

  bool get ttuEnableFontVPAL =>
      readerSettings?.enableFontVPAL ??
      getPreference<bool>(key: 'ttu_font_vpal', defaultValue: false);
  Future<void> setTtuEnableFontVPAL(bool v) async {
    await (readerSettings?.setEnableFontVPAL(v) ??
        setPreference<bool>(key: 'ttu_font_vpal', value: v));
    onSettingsChangedLive?.call();
  }

  String get ttuVerticalTextOrientation =>
      readerSettings?.verticalTextOrientation ??
      getPreference<String>(
        key: 'ttu_vert_text_orient',
        defaultValue: 'mixed',
      );
  Future<void> setTtuVerticalTextOrientation(String v) async {
    await (readerSettings?.setVerticalTextOrientation(v) ??
        setPreference<String>(key: 'ttu_vert_text_orient', value: v));
    onSettingsChangedLive?.call();
  }

  bool get ttuEnableTextJustification =>
      readerSettings?.enableTextJustification ??
      getPreference<bool>(key: 'ttu_text_justify', defaultValue: false);
  Future<void> setTtuEnableTextJustification(bool v) async {
    await (readerSettings?.setEnableTextJustification(v) ??
        setPreference<bool>(key: 'ttu_text_justify', value: v));
    onSettingsChangedLive?.call();
  }

  bool get ttuPrioritizeReaderStyles =>
      readerSettings?.prioritizeReaderStyles ??
      getPreference<bool>(key: 'ttu_reader_styles', defaultValue: false);
  Future<void> setTtuPrioritizeReaderStyles(bool v) async {
    await (readerSettings?.setPrioritizeReaderStyles(v) ??
        setPreference<bool>(key: 'ttu_reader_styles', value: v));
    onSettingsChangedLive?.call();
  }

  String get _legacyFuriganaStyle =>
      getPreference<String>(key: 'ttu_furigana_style', defaultValue: 'partial')
          .toLowerCase();

  // ── Custom fonts ────────────────────────────────────────────────────

  List<Map<String, dynamic>> get customFonts {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      return settings.customFonts;
    }
    final String raw =
        getPreference<String>(key: 'custom_fonts', defaultValue: '[]');
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibikiSource.customFonts', e, stack);
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> setCustomFonts(List<Map<String, dynamic>> fonts) async {
    await (readerSettings?.setCustomFonts(fonts) ??
        setPreference<String>(key: 'custom_fonts', value: jsonEncode(fonts)));
    onSettingsChangedLive?.call();
  }

  Future<void> addCustomFont({required String name, String? path}) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.addCustomFont(name: name, path: path);
      onSettingsChangedLive?.call();
      return;
    }
    final List<Map<String, dynamic>> list = customFonts;
    list.add(<String, dynamic>{
      'name': name,
      'path': path,
      'enabled': true,
    });
    await setCustomFonts(list);
  }

  Future<void> removeCustomFont(int index) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      final List<Map<String, dynamic>> list = settings.customFonts;
      if (index < 0 || index >= list.length) {
        return;
      }
      final String? filePath = list[index]['path'] as String?;
      if (filePath != null) {
        try {
          final File f = File(filePath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibikiSource.deleteFont', e, stack);
          debugPrint(
              '[Hibiki] failed to delete custom font file $filePath: $e');
        }
      }
      await settings.removeCustomFont(index);
      onSettingsChangedLive?.call();
      return;
    }
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
        ErrorLogService.instance.log('ReaderHibikiSource.deleteFont', e, stack);
        debugPrint('[Hibiki] failed to delete custom font file $filePath: $e');
      }
    }
    await setCustomFonts(list);
  }

  Future<void> toggleCustomFont(int index) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleCustomFont(index);
      onSettingsChangedLive?.call();
      return;
    }
    final List<Map<String, dynamic>> list = customFonts;
    if (index < 0 || index >= list.length) {
      return;
    }
    list[index]['enabled'] = !(list[index]['enabled'] as bool? ?? true);
    await setCustomFonts(list);
  }

  Future<void> reorderCustomFonts(int oldIndex, int newIndex) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.reorderCustomFonts(oldIndex, newIndex);
      onSettingsChangedLive?.call();
      return;
    }
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
    Iterable<Map<String, dynamic>> fonts, {
    Iterable<String> allowedDirectories = const <String>[],
  }) =>
      ReaderSettings.customFontCssForEntries(
        fonts,
        allowedDirectories: allowedDirectories,
      );

  static String normalizedFontFamilyName(String name) {
    return ReaderCustomFontCss.normalizedFontFamilyName(name);
  }

  static String cssFontFamilyName(String name) {
    return ReaderCustomFontCss.cssFontFamilyName(name);
  }

  static String cssFontFamilyList(Iterable<String> names) {
    return names.map(cssFontFamilyName).join(', ');
  }

  static String? safeCustomFontPath(
    String fontPath, {
    Iterable<String> allowedRoots = const <String>[],
  }) =>
      ReaderCustomFontCss.safeFontPath(
        fontPath,
        allowedRoots: allowedRoots,
      );

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
