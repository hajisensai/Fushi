import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  static String mediaIdentifierFor(String bookKey) => 'hoshi://book/$bookKey';

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

  // BUG-097: decide whether a navigation URL belongs to the OS browser. Internal
  // book content lives on the [kHost] virtual host (https://hoshi.local/...), so
  // an internal link that failed to resolve to a chapter must NEVER be handed to
  // the OS — that opens a blank page for a non-existent host. Only genuine
  // external schemes on a different host are external.
  static bool isExternalUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.host == kHost) return false;
    const Set<String> externalSchemes = {'http', 'https', 'mailto', 'tel'};
    return externalSchemes.contains(uri.scheme);
  }

  /// Parse `hoshi://book/<bookKey>` back to the bookKey. Returns null for an
  /// unparseable identifier. The bookKey is the sanitized title (the EpubBooks
  /// primary key); legacy `hoshi://book/<int>` identifiers were rewritten to
  /// the key form by the v16 migration, so no int branch is needed.
  static String? parseBookKey(String identifier) {
    final Uri? uri = Uri.tryParse(identifier);
    if (uri == null) return null;
    if (uri.scheme == 'hoshi' &&
        uri.host == 'book' &&
        uri.pathSegments.isNotEmpty) {
      // pathSegments are percent-decoded by Uri; rejoin in case a sanitized
      // key itself contained an encoded '/' (it never does — sanitize escapes
      // '/' — but be defensive and keep the full remainder).
      return uri.pathSegments.join('/');
    }
    return null;
  }

  /// BUG-220: EPUB books carry an editable author column, so expose author
  /// editing in the media edit dialog.
  @override
  bool get supportsAuthorEdit => true;

  /// BUG-220: persist the edited author directly to the `epubBooks.author`
  /// column (NOT the primary key, so no re-key is needed — unlike the title,
  /// which is overridden via a preference). A blank author clears the column.
  @override
  Future<void> setAuthorFromMediaItem({
    required MediaItem item,
    required String? author,
  }) async {
    final String? bookKey = parseBookKey(item.mediaIdentifier);
    final HibikiDatabase? db = sharedDatabase;
    if (bookKey == null || db == null) return;
    await db.updateEpubBookAuthor(bookKey, author);
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
  Widget buildLaunchPage({
    MediaItem? item,
    Bookmark? initialBookmarkJump,
  }) {
    final String bookKey = _extractBookKey(item?.mediaIdentifier ?? '');
    return HibikiAppUiScaleNeutralizer(
      child: ReaderHibikiPage(
        item: item,
        bookKey: bookKey,
        initialBookmarkJump: initialBookmarkJump,
      ),
    );
  }

  // HBK-AUDIT-126: parseBookKey returns null for an empty/unknown identifier.
  // We log the failure so the corruption is observable instead of swallowed;
  // an empty-string sentinel remains only because ReaderHibikiPage.bookKey is a
  // non-null String and ReaderHibikiPage already renders an empty/error state
  // for an unknown key.
  static String _extractBookKey(String identifier) {
    final String? bookKey = parseBookKey(identifier);
    if (bookKey == null) {
      ErrorLogService.instance.log(
        'ReaderHibikiSource._extractBookKey',
        'unparseable media identifier: "$identifier"',
        StackTrace.current,
      );
      return '';
    }
    return bookKey;
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [
      buildBookImportButton(context: context, ref: ref, appModel: appModel),
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

    // HBK-AUDIT-128: previously this was a serial for-loop where every book
    // awaited posRepo.findByTtuBookId(book.id) and up to four File.exists()
    // cover probes one after another, so shelf latency scaled linearly with
    // library size. Map each book to a Future and resolve them with
    // Future.wait so the per-book DB query and cover probes overlap; Drift
    // serialises the queries on its own connection, and Future.wait preserves
    // input order so the shelf ordering is unchanged.
    return Future.wait<MediaItem>(
      books.map((EpubBookRow book) => _bookToMediaItem(book, posRepo)),
    );
  }

  /// 按 bookKey 解析出 [MediaItem]（TODO-291：首页「正在听书」迷你条「回到书」用，
  /// 此处没有现成的 MediaItem，需按 key 重建）。书不存在返回 null。
  Future<MediaItem?> mediaItemForBookKey(String bookKey) async {
    final HibikiDatabase? db = sharedDatabase;
    if (db == null) return null;
    final EpubBookRow? book = await db.getEpubBook(bookKey);
    if (book == null) return null;
    return _bookToMediaItem(book, ReaderPositionRepository(db));
  }

  /// Resolve a single [EpubBookRow] into a [MediaItem], reading its reader
  /// position and cover concurrently with sibling books (HBK-AUDIT-128).
  Future<MediaItem> _bookToMediaItem(
    EpubBookRow book,
    ReaderPositionRepository posRepo,
  ) async {
    int position = 0;
    int duration = 1;

    List<int> sectionChars = const <int>[];
    if (book.chaptersJson.isNotEmpty) {
      try {
        final List<dynamic> chapters =
            jsonDecode(book.chaptersJson) as List<dynamic>;
        sectionChars = chapters
            .map((dynamic c) =>
                ((c as Map<String, dynamic>)['characters'] as num?)?.toInt() ??
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

    final pos = await posRepo.findByBookKey(book.bookKey);
    if (pos != null && sectionChars.isNotEmpty) {
      final int clampedSection =
          pos.sectionIndex.clamp(0, sectionChars.length - 1);
      int charsRead = 0;
      for (int i = 0; i < clampedSection; i++) {
        charsRead += sectionChars[i];
      }
      position = charsRead;
    }

    final String? imageUrl = await _resolveCoverUrl(book);

    return MediaItem(
      mediaIdentifier: mediaIdentifierFor(book.bookKey),
      title: book.title,
      // BUG-220: 回填导入时写入 epubBooks.author 的作者，详情弹窗据此显示。
      author: book.author,
      imageUrl: imageUrl,
      mediaTypeIdentifier: mediaType.uniqueKey,
      mediaSourceIdentifier: uniqueKey,
      position: position,
      duration: duration,
      canDelete: false,
      canEdit: true,
      sourceMetadata: totalChars > 0 ? jsonEncode(sectionChars) : null,
    );
  }

  /// Resolve a book's cover image URL, probing the declared cover path and the
  /// conventional fallback names concurrently (HBK-AUDIT-128).
  Future<String?> _resolveCoverUrl(EpubBookRow book) async {
    final List<String> candidates = <String>[];
    if (book.coverPath != null && book.coverPath!.isNotEmpty) {
      String coverRel = book.coverPath!;
      if (coverRel.startsWith('/')) coverRel = coverRel.substring(1);
      candidates.add(p.join(book.extractDir, coverRel));
    }
    for (final String name in const <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
    ]) {
      candidates.add(p.join(book.extractDir, name));
    }

    // Probe all candidate paths concurrently, then keep the first existing one
    // in declared priority order (declared cover path wins over fallbacks).
    final List<bool> existed = await Future.wait<bool>(
      candidates.map((String path) => File(path).exists()),
    );
    for (int i = 0; i < candidates.length; i++) {
      if (existed[i]) {
        return Uri.file(candidates[i]).toString();
      }
    }
    return null;
  }

  /// Delete a book and all of its associated data.
  ///
  /// Pass [appModel] to also clear the override thumbnail file (it is needed to
  /// resolve the thumbnails directory); the override title preference is always
  /// cleared regardless (HBK-AUDIT-040).
  Future<bool> deleteBook({
    required HibikiDatabase db,
    required String bookKey,
    AppModel? appModel,
  }) async {
    try {
      // HBK-AUDIT-041: db.deleteEpubBook removes every associated DB row
      // (readerPositions, bookmarks, srtBooks, audioCues, audiobooks for the
      // same bookKey) inside one transaction. Previously deleteBook ALSO
      // deleted the audiobook/srt rows via the repos, double-deleting the same
      // rows and splitting the deletion across non-atomic layers. We now let
      // the transaction own all row deletes and only run the non-redundant
      // on-disk cleanups (deletePersistDir, extracted dir) afterwards.
      //
      // The book's on-disk extract dir and the srt uid must be resolved BEFORE
      // the transaction, because deleteEpubBook deletes the rows they live on.
      final EpubBookRow? bookRow = await db.getEpubBook(bookKey);
      final SrtBookRepository srtRepo = SrtBookRepository(db);
      final SrtBook? srt = await srtRepo.findByBookKey(bookKey);

      await db.deleteEpubBook(bookKey);

      // On-disk cleanups (not covered by the DB transaction). The audiobook
      // persist dir is keyed by the book's own key now (no legacy uid).
      await AudiobookStorage.deletePersistDir(bookKey);
      if (srt != null) {
        await AudiobookStorage.deletePersistDir(srt.uid);
      }
      // Locate the extracted dir by the stored extract_dir column (the on-disk
      // folder name may still be the legacy int id; the column is the truth).
      if (bookRow != null) {
        await EpubStorage.deleteBookDir(bookRow.extractDir);
      }

      // HBK-AUDIT-040: these books are created with canDelete:false, so the
      // generic AppModel.deleteMediaItem cleanup (clearOverrideValues) never
      // runs for them. Clear the override title preference here, and the
      // override thumbnail file when an AppModel is available, so renamed/
      // recovered books do not leave orphaned override rows/files behind.
      final MediaItem item = MediaItem(
        mediaIdentifier: mediaIdentifierFor(bookKey),
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

      // BUG-276: 上面已删 DB 行 + 解压目录/有声书副本，但 SQLite 删除只把页放回
      // freelist、不归还磁盘；WAL 也会继续增长。删一本书后 VACUUM 回收空间
      // （否则用户「书都删了占用没降」）。VACUUM 必须在事务外，这里已在事务外；
      // 失败不应让删除整体失败（行已删），只记日志。
      try {
        await db.customStatement('VACUUM');
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderHibikiSource.deleteBook.vacuum', e, stack);
        debugPrint('[ReaderHibikiSource] VACUUM after delete failed: $e');
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

  /// Fired on CSS-only setting changes (font size / line height / margins /
  /// indentation / justify / kerning / vpal / furigana / vert-orient). The
  /// reader live-updates the injected stylesheet without a full chapter reload.
  static VoidCallback? onSettingsChangedLive;

  /// Fired on structural layout changes that the CSS injection alone cannot
  /// express (writing mode / view mode / page columns / spread mode / spread
  /// direction / prioritize reader styles). The reader rebuilds the chapter so
  /// the pagination engine re-runs. Kept separate from [onSettingsChangedLive]
  /// so the reload-vs-CSS choice is key-accurate for every surface that mutates
  /// reader settings, not just the in-book sheet.
  static VoidCallback? onLayoutReloadLive;

  /// Fired on pure Flutter chrome layout changes (e.g. reverse reader bottom
  /// bar) that neither touch the injected CSS nor require a chapter reload.
  /// The reader simply rebuilds its chrome layer once to re-read the preference;
  /// kept separate from [onSettingsChangedLive] (which also runs a WebView CSS
  /// re-eval + re-anchor) and [onLayoutReloadLive] (which re-runs pagination).
  static VoidCallback? onChromeReloadLive;

  /// TODO-728: fired when a physical game controller's presence changes (true =
  /// now present, false = gone). The open reader applies/clears its
  /// gamepad-driven immersive mode. Only wired up by the reader page; the
  /// AppModel-side bridge already gates on [AppModel.gamepadAutoImmersive] so
  /// this fires only when the user opted in.
  static void Function(bool present)? onGamepadPresenceChanged;

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

  // TODO-120: 反转键盘方向键翻页方向（仅键盘方向键），默认 false。
  bool get reverseArrowPageTurn =>
      readerSettings?.reverseArrowPageTurn ??
      getPreference<bool>(
        key: 'reverse_arrow_page_turn',
        defaultValue: false,
      );

  void toggleReverseArrowPageTurn() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleReverseArrowPageTurn();
      return;
    }
    await setPreference<bool>(
      key: 'reverse_arrow_page_turn',
      value: !reverseArrowPageTurn,
    );
  }

  // TODO-830: 反转有声书底栏 ⏮⏭ 前进/后退按钮的功能方向（per-reader，分层与
  // invert_swipe_direction / reverse_arrow_page_turn 一致），默认 false。
  bool get invertAudiobookSkipDirection =>
      readerSettings?.invertAudiobookSkipDirection ??
      getPreference<bool>(
        key: 'invert_audiobook_skip_direction',
        defaultValue: false,
      );

  void toggleInvertAudiobookSkipDirection() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleInvertAudiobookSkipDirection();
      return;
    }
    await setPreference<bool>(
      key: 'invert_audiobook_skip_direction',
      value: !invertAudiobookSkipDirection,
    );
  }

  // TODO-080B: read through THIS source's profile-aware preference cache
  // ([_preferences], reloaded by AppModel.refreshPrefCache on every profile
  // switch) instead of the reader-page-owned static [readerSettings] snapshot.
  // The video page (and any DictionaryPageMixin surface) never refreshes
  // [readerSettings], so going through it leaked a stale "last reader profile"
  // value — subtitle lookups auto-read even after the user turned the setting
  // off. The DB row (`src:reader_ttu:auto_read_on_lookup`) is identical for
  // both code paths, so there is a single source of truth and no migration.
  bool get autoReadOnLookup =>
      getPreference<bool>(key: 'auto_read_on_lookup', defaultValue: true);

  // Single source of truth: write through this source's profile-aware cache +
  // DB row. No other reader reads ReaderSettings.autoReadOnLookup directly
  // (every consumer goes through this getter), so there is nothing to keep in
  // sync — the old `if (readerSettings != null)` branch was a redundant second
  // write to the same DB row in a different encoding. See [autoReadOnLookup].
  void toggleAutoReadOnLookup() async {
    await setPreference<bool>(
      key: 'auto_read_on_lookup',
      value: !autoReadOnLookup,
    );
  }

  int get lookupAudioVolume {
    final int raw = readerSettings?.lookupAudioVolume ??
        getPreference<int>(key: 'lookup_audio_volume', defaultValue: 100);
    return ReaderSettings.normalizeLookupAudioVolume(raw);
  }

  double get lookupAudioVolumeGain => lookupAudioVolume / 100.0;

  Future<void> setLookupAudioVolume(num volume) async {
    final int clamped = ReaderSettings.normalizeLookupAudioVolume(volume);
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setLookupAudioVolume(clamped);
      return;
    }
    await setPreference<int>(
      key: 'lookup_audio_volume',
      value: clamped,
    );
  }

  bool get pauseOnLookup =>
      getPreference<bool>(key: 'pause_on_lookup', defaultValue: false);

  Future<void> setPauseOnLookup({required bool value}) async {
    await setPreference<bool>(key: 'pause_on_lookup', value: value);
  }

  /// TODO-756b：是否“鼠标悬停即自动查词”。开启时无需按住 Shift，鼠标悬停在
  /// 字幕/正文字符上即触发查词（与 TODO-756a 的 Shift-悬停同链路）；关闭时退回
  /// 756a 的 Shift+悬停行为。悬停是桌面鼠标行为，移动端无 OS hover、自然不触发
  /// （配置项在设置 UI 走 DesktopLookupService.isDesktop 桌面门控隐藏）。默认
  /// false（保持 756a 既有行为）。视频页与阅读器共享 [instance]，天然通用。
  bool get hoverAutoLookup =>
      getPreference<bool>(key: 'hover_auto_lookup', defaultValue: false);

  Future<void> setHoverAutoLookup({required bool value}) async {
    await setPreference<bool>(key: 'hover_auto_lookup', value: value);
    onSettingsChangedLive?.call();
  }

  /// 0 = skip by sentence (default), 5/10/15/30 = skip by N seconds.
  int get skipActionSeconds =>
      getPreference<int>(key: 'skip_action_seconds', defaultValue: 0);

  Future<void> setSkipActionSeconds(int value) async {
    await setPreference<int>(key: 'skip_action_seconds', value: value);
    onSettingsChangedLive?.call();
  }

  double get dismissSwipeSensitivity => getPreference<double>(
        key: 'dismiss_swipe_sensitivity',
        defaultValue: 0.6,
      );

  Future<void> setDismissSwipeSensitivity(double value) async {
    await setPreference<double>(
      key: 'dismiss_swipe_sensitivity',
      value: value,
    );
  }

  /// TODO-407②：查词弹窗是否允许"水平滑动关闭"。与 [dismissSwipeSensitivity] 同一
  /// 双源模式：优先读 reader profile 快照（[ReaderSettings.enableSwipeToClose]），
  /// 否则落全局偏好。未持久化时回退到 [ReaderSettings.defaultSwipeToClose]（桌面
  /// Windows/Linux 默认 false，触摸平台 true）。
  bool get enableSwipeToClose => getPreference<bool>(
        key: 'enable_swipe_to_close',
        defaultValue: ReaderSettings.defaultSwipeToClose(defaultTargetPlatform),
      );

  Future<void> setEnableSwipeToClose(bool value) async {
    await setPreference<bool>(
      key: 'enable_swipe_to_close',
      value: value,
    );
  }

  /// 鼠标滚轮翻页节流间隔（毫秒），越大翻页越慢。默认 450ms。
  int get wheelPageTurnInterval =>
      readerSettings?.wheelPageTurnInterval ??
      getPreference<int>(
        key: 'wheel_page_turn_interval',
        defaultValue: 450,
      );

  Future<void> setWheelPageTurnInterval(int value) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setWheelPageTurnInterval(value);
      return;
    }
    await setPreference<int>(
      key: 'wheel_page_turn_interval',
      value: value,
    );
  }

  /// 翻页滑动灵敏度系数（TODO-113），缩放 JS `_gestureEnd` 的距离阈值；越大越迟钝。
  double get swipePageTurnSensitivity =>
      readerSettings?.swipePageTurnSensitivity ??
      ReaderSettings.normalizeSwipePageTurnSensitivity(
        getPreference<double>(
          key: 'swipe_page_turn_sensitivity',
          defaultValue: 1.0,
        ),
      );

  Future<void> setSwipePageTurnSensitivity(double value) async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setSwipePageTurnSensitivity(value);
      return;
    }
    await setPreference<double>(
      key: 'swipe_page_turn_sensitivity',
      value: ReaderSettings.normalizeSwipePageTurnSensitivity(value),
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

  bool get showTopProgressBar =>
      readerSettings?.showTopProgressBar ??
      getPreference<bool>(key: 'show_top_progress_bar', defaultValue: true);

  void toggleShowTopProgressBar() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleShowTopProgressBar();
      return;
    }
    await setPreference<bool>(
      key: 'show_top_progress_bar',
      value: !showTopProgressBar,
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

  // TODO-728: bottom-bar current-sentence cue toggle (per-reader; layered like
  // showTopProgressBar / tapEmptyToHideChrome), default true = current behavior.
  bool get showBottomBarCue =>
      readerSettings?.showBottomBarCue ??
      getPreference<bool>(key: 'show_bottom_bar_cue', defaultValue: true);

  void toggleShowBottomBarCue() async {
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.toggleShowBottomBarCue();
      return;
    }
    await setPreference<bool>(
      key: 'show_bottom_bar_cue',
      value: !showBottomBarCue,
    );
  }

  // TODO-728: top reading-progress position (per-reader; layered like the
  // booleans above). 'left' | 'center' | 'right', default 'center'. Normalized
  // through ReaderSettings so a bad stored value degrades to 'center'.
  String get topProgressPosition =>
      readerSettings?.topProgressPosition ??
      ReaderSettings.normalizeTopProgressPosition(
        getPreference<String>(
          key: 'top_progress_position',
          defaultValue: 'center',
        ),
      );

  void setTopProgressPosition(String value) async {
    final String normalized =
        ReaderSettings.normalizeTopProgressPosition(value);
    final ReaderSettings? settings = readerSettings;
    if (settings != null) {
      await settings.setTopProgressPosition(normalized);
      return;
    }
    await setPreference<String>(
      key: 'top_progress_position',
      value: normalized,
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

  /// TODO-368: 歌词字幕文字色（独立于主题色）。ARGB int；`0` = 未设置（跟随主题）。
  int get lyricsTextColor =>
      readerSettings?.lyricsTextColor ??
      getPreference<int>(key: 'lyrics_text_color', defaultValue: 0);
  Future<void> setLyricsTextColor(int v) async {
    await (readerSettings?.setLyricsTextColor(v) ??
        setPreference<int>(key: 'lyrics_text_color', value: v));
    onSettingsChangedLive?.call();
  }

  Future<void> clearLyricsTextColor() async {
    await (readerSettings?.clearLyricsTextColor() ??
        setPreference<int>(key: 'lyrics_text_color', value: 0));
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
      getPreference<double>(
        key: 'ttu_margin_top',
        defaultValue: ReaderSettings.defaultMarginTopPercent,
      );
  Future<void> setTtuMarginTop(double v) async {
    final double normalized = ReaderSettings.normalizeMarginPercent(v);
    await (readerSettings?.setMarginTop(normalized) ??
        setPreference<double>(key: 'ttu_margin_top', value: normalized));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginBottom =>
      readerSettings?.marginBottom ??
      getPreference<double>(
        key: 'ttu_margin_bottom',
        defaultValue: ReaderSettings.defaultMarginBottomPercent,
      );
  Future<void> setTtuMarginBottom(double v) async {
    final double normalized = ReaderSettings.normalizeMarginPercent(v);
    await (readerSettings?.setMarginBottom(normalized) ??
        setPreference<double>(key: 'ttu_margin_bottom', value: normalized));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginLeft =>
      readerSettings?.marginLeft ??
      getPreference<double>(
        key: 'ttu_margin_left',
        defaultValue: ReaderSettings.defaultMarginLeftPercent,
      );
  Future<void> setTtuMarginLeft(double v) async {
    final double normalized = ReaderSettings.normalizeMarginPercent(v);
    await (readerSettings?.setMarginLeft(normalized) ??
        setPreference<double>(key: 'ttu_margin_left', value: normalized));
    onSettingsChangedLive?.call();
  }

  double get ttuMarginRight =>
      readerSettings?.marginRight ??
      getPreference<double>(
        key: 'ttu_margin_right',
        defaultValue: ReaderSettings.defaultMarginRightPercent,
      );
  Future<void> setTtuMarginRight(double v) async {
    final double normalized = ReaderSettings.normalizeMarginPercent(v);
    await (readerSettings?.setMarginRight(normalized) ??
        setPreference<double>(key: 'ttu_margin_right', value: normalized));
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

  // 单一真相在 [ReaderSettings]；这两个同名方法只转调，消除重复 switch
  // （历史上 source 与 settings 各写一份，改一处忘另一处即漂移）。
  static String normalizeFuriganaMode(String mode) =>
      ReaderSettings.normalizeFuriganaMode(mode);

  static String furiganaModeToStyle(String mode) =>
      ReaderSettings.furiganaModeToStyle(mode);
}
