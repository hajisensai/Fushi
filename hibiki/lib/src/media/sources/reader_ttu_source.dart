import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_logs/flutter_logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/utils.dart';

/// A global [Provider] for serving a local ッツ Ebook Reader.
final ttuServerProvider =
    FutureProvider.family<LocalAssetsServer, Language>((ref, language) {
  return ReaderTtuSource.instance.serveLocalAssets(language);
});

/// A global [Provider] for getting ッツ Ebook Reader books from IndexedDB.
final ttuBooksProvider =
    FutureProvider.family<List<MediaItem>, Language>((ref, language) {
  return ReaderTtuSource.instance.getBooksHistory(
    appModel: ref.watch(appProvider),
    language: language,
  );
});

/// A media source that allows the user to read from ッツ Ebook Reader.
class ReaderTtuSource extends ReaderMediaSource {
  /// Define this media source.
  ReaderTtuSource._privateConstructor()
      : super(
          uniqueKey: 'reader_ttu',
          sourceName: t.source_name_bookshelf,
          description: t.source_description_epub,
          icon: Icons.auto_stories_outlined,
          implementsSearch: false,
          implementsHistory: false,
        );

  @override
  Future<void> onSearchBarTap({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) async {}

  /// Get the singleton instance of this media type.
  static ReaderTtuSource get instance => _instance;

  static final ReaderTtuSource _instance =
      ReaderTtuSource._privateConstructor();

  /// Default scrolling speed when in continuous page turning mode.
  static int get defaultScrollingSpeed => 100;

  @override
  Future<void> onSourceExit({
    required AppModel appModel,
    required WidgetRef ref,
  }) async {
    ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
    // await exportBackup(appModel: appModel);
  }

  /// Import persisted backup data back to IndexedDB if it exists.
  Future<void> importBackup({
    required InAppWebViewController controller,
    required Language language,
    required String data,
  }) async {
    FlutterLogs.logInfo(
      mediaType.uniqueKey,
      uniqueKey,
      'Restored IndexedDB.',
    );
  }

  /// Get the IndexedDB backup key for a language
  String getIndexedDBKey(Language language) {
    return 'idb_${getPortForLanguage(language)}';
  }

  /// Get the port for the current language. This port should ideally not conflict but should remain the same for
  /// caching purposes.
  int getPortForLanguage(Language language) {
    /// Language Customizable
    if (language is JapaneseLanguage) {
      return 52059;
    } else if (language is EnglishLanguage) {
      return 52060;
    }

    throw UnimplementedError();
  }

  /// Used to delay the serve if the server failed to launch last time. Makes
  /// retry look better for port conflicts.
  bool _lastServeFailed = false;

  HttpServer? _fontServer;

  int get fontServerPort => 52061;

  Future<void> _ensureFontServer() async {
    if (_fontServer != null) return;
    try {
      _fontServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        fontServerPort,
      );
      _fontServer!.listen((request) async {
        final fontPath = Uri.decodeComponent(
            request.requestedUri.path.replaceFirst('/', ''));
        final file = File(fontPath);
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
          final ext = fontPath.split('.').last.toLowerCase();
          final mime = switch (ext) {
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

  /// For serving the reader assets locally.
  Future<LocalAssetsServer> serveLocalAssets(Language language) async {
    int port = getPortForLanguage(language);

    if (_lastServeFailed) {
      await Future.delayed(const Duration(seconds: 1));
    }

    unawaited(_ensureFontServer());

    try {
      _lastServeFailed = false;
      final server = LocalAssetsServer(
        address: InternetAddress.loopbackIPv4,
        port: port,
        assetsBasePath: 'assets/ttu-ebook-reader',
        logger: const DebugLogger(),
      );

      await server.serve().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Local assets server failed to start within 15 seconds',
        ),
      );

      return server;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderTtuSource.serve', e, stack);
      _lastServeFailed = true;
      rethrow;
    }
  }

  @override
  BaseSourcePage buildLaunchPage({
    MediaItem? item,
  }) {
    return ReaderTtuSourcePage(item: item);
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [
      buildBookImportButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
      buildTweaksButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
    ];
  }

  /// Opens [BookImportDialog] to import an EPUB (optionally together with a
  /// subtitle file + audio, which routes through the subtitle-book flow).
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
              serverPort: ReaderTtuSource.instance
                  .getPortForLanguage(appModel.targetLanguage),
              ttuMediaSourceIdentifier:
                  ReaderTtuSource.instance.uniqueKey,
            ),
          );
          if (imported == true) {
            ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
          }
        },
      ),
    );
  }

  /// Tweaks bar action.
  Widget buildTweaksButton(
      {required BuildContext context,
      required WidgetRef ref,
      required AppModel appModel}) {
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

  /// Shows when the clear button is pressed.
  void showClearPrompt(
      {required BuildContext context,
      required WidgetRef ref,
      required AppModel appModel}) async {}

  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const ReaderTtuSourceHistoryPage();
  }

  /// Fetch JSON for all books in IndexedDB.
  Future<List<MediaItem>> getBooksHistory({
    required AppModel appModel,
    required Language language,
    bool recursive = false,
  }) async {
    int port = getPortForLanguage(appModel.targetLanguage);

    List<MediaItem>? items;

    bool jsInjected = false;
    HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$port/_hibiki_idb.html'),
      ),
      onLoadStart: (controller, url) {
        debugPrint('[hibiki-books] headless onLoadStart: $url');
      },
      onLoadStop: (controller, url) async {
        debugPrint('[hibiki-books] headless onLoadStop: $url');
        if (!jsInjected) {
          jsInjected = true;
          controller.evaluateJavascript(source: getHistoryJs);
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[hibiki-books] headless onReceivedError: '
            '${error.type} ${error.description} url=${request.url}');
        items ??= [];
      },
      onConsoleMessage: (controller, message) async {
        try {
          Map<String, dynamic> messageJson = jsonDecode(message.message);

          if (messageJson['messageType'] != null) {
            switch (messageJson['messageType']) {
              case 'history':
                try {
                  items = getItemsFromJson(messageJson, port);
                } catch (error, stack) {
                  items = [];
                  ErrorLogService.instance.log('ReaderTtuSource.parseHistory', error, stack);
                  debugPrint('$error');
                  debugPrint('$stack');
                }
                break;
              case 'empty':
                if (!appModel.targetLanguage.preferVerticalReading) {
                  await controller.evaluateJavascript(
                      source:
                          'javascript:window.localStorage.setItem("writingMode", "horizontal-tb")');
                  await controller.evaluateJavascript(
                      source:
                          'javascript:window.localStorage.setItem("fontSize", 16)');
                } else {
                  await controller.evaluateJavascript(
                      source:
                          'javascript:window.localStorage.setItem("fontSize", 24)');
                }

                items = [];
                break;
              case 'error':
                items = [];
                break;
            }
          }
        } on FormatException catch (e) {
          debugPrint('[hibiki-books] non-JSON console: ${message.message.length > 200 ? message.message.substring(0, 200) : message.message}');
        }
      },
    );

    final completer = Completer<List<MediaItem>>();

    try {
      await webView.run();

      // Poll until items is set or we time out (20 s).
      Future(() async {
        const timeout = Duration(seconds: 20);
        final deadline = DateTime.now().add(timeout);
        while (items == null) {
          if (DateTime.now().isAfter(deadline)) {
            if (!completer.isCompleted) {
              completer.completeError(
                TimeoutException(
                  'Timed out waiting for book list from WebView after 20 s',
                ),
              );
            }
            return;
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (!completer.isCompleted) {
          completer.complete(items!);
        }
      });

      return await completer.future;
    } finally {
      await webView.dispose();
    }
  }

  /// Delete a book and its bookmark/lastItem entries from ttu IndexedDB.
  /// Returns true on success.
  Future<bool> deleteBookFromIdb({
    required Language language,
    required int bookId,
  }) async {
    final int port = getPortForLanguage(language);
    final completer = Completer<bool>();

    bool jsInjected = false;
    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$port/_hibiki_idb.html'),
      ),
      onLoadStop: (controller, url) async {
        if (!jsInjected) {
          jsInjected = true;
          await controller.evaluateJavascript(source: _buildDeleteBookJs(bookId));
        }
      },
      onConsoleMessage: (controller, message) async {
        try {
          final Map<String, dynamic> json = jsonDecode(message.message);
          switch (json['messageType']) {
            case 'deleted':
              if (!completer.isCompleted) {
                completer.complete(true);
              }
              break;
            case 'delete_error':
              if (!completer.isCompleted) {
                completer.complete(false);
              }
              break;
          }
        } on FormatException catch (_) {}
      },
    );

    try {
      await webView.run();
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    } finally {
      await webView.dispose();
    }
  }

  String _buildDeleteBookJs(int bookId) {
    return '''
new Promise(function(resolve) {
  var dbRequest = indexedDB.open('books');
  dbRequest.onerror = function() {
    console.log(JSON.stringify({messageType: 'delete_error'}));
    resolve(false);
  };
  dbRequest.onsuccess = function(event) {
    var db = event.target.result;
    try {
      var tx = db.transaction(['data', 'bookmark', 'lastItem'], 'readwrite');
      tx.objectStore('data').delete($bookId);
      tx.objectStore('bookmark').delete($bookId);
      var lastItemStore = tx.objectStore('lastItem');
      var liReq = lastItemStore.get(0);
      liReq.onsuccess = function() {
        if (liReq.result && liReq.result.dataId === $bookId) {
          lastItemStore.delete(0);
        }
      };
      tx.oncomplete = function() {
        console.log(JSON.stringify({messageType: 'deleted'}));
        resolve(true);
      };
      tx.onerror = function() {
        console.log(JSON.stringify({messageType: 'delete_error'}));
        resolve(false);
      };
    } catch (e) {
      console.log(JSON.stringify({messageType: 'delete_error'}));
      resolve(false);
    }
  };
});
''';
  }

  /// Fetch the list of history items given JSON from IndexedDB.
  List<MediaItem> getItemsFromJson(Map<String, dynamic> json, int port) {
    List<Map<String, dynamic>> bookmarks =
        List<Map<String, dynamic>>.from(jsonDecode(json['bookmark']));
    List<Map<String, dynamic>> datas =
        List<Map<String, dynamic>>.from(jsonDecode(json['data']));
    Map<int, Map<String, dynamic>> bookmarksById =
        Map<int, Map<String, dynamic>>.fromEntries(
            bookmarks.map((e) => MapEntry(e['dataId'] as int, e)));

    List<MapEntry<int, MediaItem>> itemsById = datas.mapIndexed((index, data) {
      int position = 0;
      int duration = 1;

      Map<String, dynamic>? bookmark = bookmarksById[data['id']];

      if (bookmark != null) {
        position = bookmark['exploredCharCount'] as int;
        double progress = double.parse(bookmark['progress'].toString());
        if (progress == 0) {
          duration = 1;
        } else {
          duration = position ~/ progress;
        }
      }

      String id = data['id'].toString();
      String title = data['title'] as String? ?? ' ';
      String? base64Image;
      try {
        Uri.parse(data['coverImage']);
        base64Image = data['coverImage'];
      } catch (e) {
        base64Image = null;
      }

      return MapEntry(
        index,
        MediaItem(
          mediaIdentifier: 'http://localhost:$port/b.html?id=$id&?title=$title',
          title: title,
          base64Image: base64Image,
          mediaTypeIdentifier: ReaderTtuSource.instance.mediaType.uniqueKey,
          mediaSourceIdentifier: ReaderTtuSource.instance.uniqueKey,
          position: position,
          duration: duration,
          canDelete: false,
          canEdit: true,
        ),
      );
    }).toList();

    List<int> lastOpens = datas.mapIndexed((index, data) {
      return data['lastBookOpen'] as int? ?? 0;
    }).toList();

    itemsById.sort((a, b) => lastOpens[b.key].compareTo(lastOpens[a.key]));
    List<MediaItem> itemsByLastOpened = itemsById.map((e) => e.value).toList();

    return itemsByLastOpened;
  }

  /// Whether or not using the volume buttons in the Reader should turn the
  /// page.
  bool get volumePageTurningEnabled {
    return getPreference<bool>(
        key: 'volume_page_turning_enabled', defaultValue: true);
  }

  /// Toggles the volume page turning option.
  void toggleVolumePageTurningEnabled() async {
    await setPreference<bool>(
      key: 'volume_page_turning_enabled',
      value: !volumePageTurningEnabled,
    );
  }

  /// Controls which direction is up or down for volume button page turning.
  bool get volumePageTurningInverted {
    return getPreference<bool>(
        key: 'volume_page_turning_inverted', defaultValue: false);
  }

  /// Inverts the current volume button page turning direction preference.
  void toggleVolumePageTurningInverted() async {
    await setPreference<bool>(
      key: 'volume_page_turning_inverted',
      value: !volumePageTurningInverted,
    );
  }

  /// Whether or not to add to extend the webpage beyond the navigation bar.
  /// This may be helpful for devices that don't have difficulty accessing the
  /// top bar (i.e. don't have a teardrop notch).
  bool get extendPageBeyondNavigationBar {
    return getPreference<bool>(
        key: 'extend_page_beyond_navbar', defaultValue: false);
  }

  /// Toggles the extend navbar option.
  void toggleExtendPageBeyondNavigationBar() async {
    await setPreference<bool>(
      key: 'extend_page_beyond_navbar',
      value: !extendPageBeyondNavigationBar,
    );
  }

  /// Whether or not the dictionary popup should adapt to the reader's theme.
  bool get adaptTtuTheme {
    return getPreference<bool>(key: 'adapt_ttu_theme', defaultValue: true);
  }

  /// Toggles whether dictionary popup should adapt to the reader's theme.
  void toggleAdaptTtuTheme() async {
    await setPreference<bool>(
      key: 'adapt_ttu_theme',
      value: !adaptTtuTheme,
    );
  }

  /// Controls the speed for volume button page turning.
  int get volumePageTurningSpeed {
    return getPreference<int>(
        key: 'volume_page_turning_speed', defaultValue: defaultScrollingSpeed);
  }

  /// Sets the speed for volume button page turning.
  void setVolumePageTurningSpeed(int speed) async {
    await setPreference<int>(
      key: 'volume_page_turning_speed',
      value: speed,
    );
  }

  /// Whether to auto-read the looked-up word via TTS.
  bool get autoReadOnLookup {
    return getPreference<bool>(
      key: 'auto_read_on_lookup',
      defaultValue: true,
    );
  }

  /// Toggles the auto-read on lookup preference.
  void toggleAutoReadOnLookup() async {
    await setPreference<bool>(
      key: 'auto_read_on_lookup',
      value: !autoReadOnLookup,
    );
  }

  /// Swipe dismiss sensitivity for the dictionary popup (0.1 ~ 1.0).
  /// Higher = easier to dismiss, lower = harder.
  double get dismissSwipeSensitivity {
    return getPreference<double>(
      key: 'dismiss_swipe_sensitivity',
      defaultValue: 0.6,
    );
  }

  /// Sets the swipe dismiss sensitivity.
  Future<void> setDismissSwipeSensitivity(double value) async {
    await setPreference<double>(
      key: 'dismiss_swipe_sensitivity',
      value: value,
    );
  }

  /// Whether the reader will highlight words on tap.
  bool get highlightOnTap {
    return getPreference<bool>(
      key: 'highlight_on_tap',
      defaultValue: true,
    );
  }

  /// Toggles whether the reader will highlight words on tap.
  void toggleHighlightOnTap() async {
    await setPreference<bool>(
      key: 'highlight_on_tap',
      value: !highlightOnTap,
    );
  }

  /// Whether the screen should stay awake while the reader is open.
  bool get keepScreenAwake {
    return getPreference<bool>(
      key: 'keep_screen_awake',
      defaultValue: true,
    );
  }

  /// Toggles the keep-screen-awake preference.
  void toggleKeepScreenAwake() async {
    await setPreference<bool>(
      key: 'keep_screen_awake',
      value: !keepScreenAwake,
    );
  }

  // ── ttu 阅读器设置（Hive 持久化，打开书时写入 ttu localStorage） ──

  double get ttuFontSize =>
      getPreference<double>(key: 'ttu_font_size', defaultValue: 20);
  Future<void> setTtuFontSize(double v) =>
      setPreference<double>(key: 'ttu_font_size', value: v);

  double get ttuLineHeight =>
      getPreference<double>(key: 'ttu_line_height', defaultValue: 1.65);
  Future<void> setTtuLineHeight(double v) =>
      setPreference<double>(key: 'ttu_line_height', value: v);

  String get ttuWritingMode =>
      getPreference<String>(key: 'ttu_writing_mode', defaultValue: 'vertical-rl');
  Future<void> setTtuWritingMode(String v) =>
      setPreference<String>(key: 'ttu_writing_mode', value: v);

  String get ttuViewMode =>
      getPreference<String>(key: 'ttu_view_mode', defaultValue: 'paginated');
  Future<void> setTtuViewMode(String v) =>
      setPreference<String>(key: 'ttu_view_mode', value: v);

  String get ttuTheme =>
      getPreference<String>(key: 'ttu_theme', defaultValue: 'light-theme');
  Future<void> setTtuTheme(String v) =>
      setPreference<String>(key: 'ttu_theme', value: v);

  bool get ttuHideFurigana =>
      getPreference<bool>(key: 'ttu_hide_furigana', defaultValue: false);
  Future<void> setTtuHideFurigana(bool v) =>
      setPreference<bool>(key: 'ttu_hide_furigana', value: v);

  double get ttuTextIndentation =>
      getPreference<double>(key: 'ttu_text_indentation', defaultValue: 0);
  Future<void> setTtuTextIndentation(double v) =>
      setPreference<double>(key: 'ttu_text_indentation', value: v);

  double get ttuFirstDimensionMargin =>
      getPreference<double>(key: 'ttu_first_dimension_margin', defaultValue: 0);
  Future<void> setTtuFirstDimensionMargin(double v) =>
      setPreference<double>(key: 'ttu_first_dimension_margin', value: v);

  double get ttuSecondDimensionMaxValue =>
      getPreference<double>(key: 'ttu_second_dimension_max', defaultValue: 0);
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
      getPreference<String>(key: 'ttu_vert_text_orient', defaultValue: 'mixed');
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

  String get ttuFuriganaStyle =>
      getPreference<String>(key: 'ttu_furigana_style', defaultValue: 'Partial');
  Future<void> setTtuFuriganaStyle(String v) =>
      setPreference<String>(key: 'ttu_furigana_style', value: v);

  // ── 自定义字体列表 ────────────────────────────────────────────────────
  // 每条记录: { "name": "...", "path": "..." (null=系统字体), "enabled": true }
  // path 为 null 表示系统字体（仅凭名称加入 font-family）。
  // 列表顺序即 font-family fallback 优先级。

  List<Map<String, dynamic>> get customFonts {
    final raw = getPreference<String>(key: 'custom_fonts', defaultValue: '[]');
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> setCustomFonts(List<Map<String, dynamic>> fonts) =>
      setPreference<String>(key: 'custom_fonts', value: jsonEncode(fonts));

  Future<void> addCustomFont({
    required String name,
    String? path,
  }) async {
    final list = customFonts;
    list.add({'name': name, 'path': path, 'enabled': true});
    await setCustomFonts(list);
  }

  Future<void> removeCustomFont(int index) async {
    final list = customFonts;
    if (index < 0 || index >= list.length) return;
    final entry = list.removeAt(index);
    final filePath = entry['path'] as String?;
    if (filePath != null) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await setCustomFonts(list);
  }

  Future<void> toggleCustomFont(int index) async {
    final list = customFonts;
    if (index < 0 || index >= list.length) return;
    list[index]['enabled'] = !(list[index]['enabled'] as bool? ?? true);
    await setCustomFonts(list);
  }

  Future<void> reorderCustomFonts(int oldIndex, int newIndex) async {
    final list = customFonts;
    if (newIndex > oldIndex) newIndex--;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setCustomFonts(list);
  }

  /// 生成自定义字体的 CSS font-family 值（仅启用的）和 @font-face 声明。
  ({String fontFamily, String fontFaces}) buildCustomFontCss() {
    final enabled = customFonts.where(
        (e) => e['enabled'] as bool? ?? true);
    final families = <String>[];
    final faces = <String>[];
    for (final e in enabled) {
      final name = e['name'] as String;
      families.add(name);
      final path = e['path'] as String?;
      if (path != null) {
        final uri =
            'http://localhost:$fontServerPort/${Uri.encodeComponent(path)}';
        faces.add(
          '@font-face { font-family: "$name"; src: url("$uri"); '
          'font-display: swap; }',
        );
      }
    }
    return (
      fontFamily: families.join(', '),
      fontFaces: faces.join('\n'),
    );
  }

  /// 在 WebView 加载后将 Hive 偏好写入 ttu localStorage。
  Future<void> applyReaderSettings(
    InAppWebViewController controller, {
    required String appThemeKey,
  }) async {
    final fontCss = buildCustomFontCss();
    final hasCustomFonts = fontCss.fontFamily.isNotEmpty;
    final fontFamilyOne = hasCustomFonts
        ? '${fontCss.fontFamily}, Noto Serif JP, Noto Serif CJK JP, serif'
        : 'Noto Serif JP, Noto Serif CJK JP, serif';
    final fontFamilyTwo = hasCustomFonts
        ? '${fontCss.fontFamily}, Noto Sans JP, Noto Sans CJK JP, sans-serif'
        : 'Noto Sans JP, Noto Sans CJK JP, sans-serif';
    final List<String> cmds = [
      'window.localStorage.setItem("fontSize",${ttuFontSize})',
      'window.localStorage.setItem("lineHeight",${ttuLineHeight})',
      'window.localStorage.setItem("writingMode","$ttuWritingMode")',
      'window.localStorage.setItem("viewMode","$ttuViewMode")',
      'window.localStorage.setItem("theme","$appThemeKey")',
      'window.localStorage.setItem("hideFurigana","${ttuHideFurigana ? 1 : 0}")',
      'window.localStorage.setItem("textIndentation",${ttuTextIndentation})',
      'window.localStorage.setItem("firstDimensionMargin",${ttuFirstDimensionMargin})',
      'window.localStorage.setItem("secondDimensionMaxValue",${ttuSecondDimensionMaxValue})',
      'window.localStorage.setItem("pageColumns",${ttuPageColumns})',
      'window.localStorage.setItem("enableVerticalFontKerning","${ttuEnableVerticalFontKerning ? 1 : 0}")',
      'window.localStorage.setItem("enableFontVPAL","${ttuEnableFontVPAL ? 1 : 0}")',
      'window.localStorage.setItem("verticalTextOrientation","$ttuVerticalTextOrientation")',
      'window.localStorage.setItem("enableTextJustification","${ttuEnableTextJustification ? 1 : 0}")',
      'window.localStorage.setItem("prioritizeReaderStyles","${ttuPrioritizeReaderStyles ? 1 : 0}")',
      'window.localStorage.setItem("furiganaStyle","$ttuFuriganaStyle")',
      'window.localStorage.setItem("statisticsEnabled","1")',
      'window.localStorage.setItem("fontFamilyGroupOne","$fontFamilyOne")',
      'window.localStorage.setItem("fontFamilyGroupTwo","$fontFamilyTwo")',
    ];
    if (hasCustomFonts) {
      final escapedFaces = fontCss.fontFaces
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', ' ');
      cmds.add(
        '(function(){'
        'var s=document.getElementById("hibiki-custom-fonts");'
        'if(!s){s=document.createElement("style");s.id="hibiki-custom-fonts";'
        'document.head.appendChild(s)}'
        "s.textContent='$escapedFaces'"
        '})()',
      );
    }
    await controller.evaluateJavascript(source: cmds.join(';'));
  }

  /// Used to fetch JSON for all books in IndexedDB.
  static const String getHistoryJs = '''
indexedDB.databases().then(async (databases) => {
  if (databases.length > 0) {
    // Schema health check: if the database exists but is missing required
    // object stores (e.g. after WebStorage.deleteAllData corrupted it),
    // delete it so the ttu app can recreate it from scratch.
    var schemaOk = await new Promise(function(resolve) {
      var chk = indexedDB.open("books");
      chk.onupgradeneeded = function(e) {
        // Database didn't exist or version changed — close and delete.
        e.target.transaction.abort();
        resolve(false);
      };
      chk.onsuccess = function(e) {
        var db = e.target.result;
        var names = db.objectStoreNames;
        var ok = names.contains("data") && names.contains("bookmark") && names.contains("lastItem");
        db.close();
        resolve(ok);
      };
      chk.onerror = function() { resolve(false); };
    });
    if (!schemaOk) {
      await new Promise(function(resolve) {
        var del = indexedDB.deleteDatabase("books");
        del.onsuccess = function() { resolve(); };
        del.onerror = function() { resolve(); };
        del.onblocked = function() { resolve(); };
      });
      console.log(JSON.stringify({messageType: "empty"}));
      return;
    }

    var bookmarkJson = JSON.stringify([]);
    var dataJson = JSON.stringify([]);
    var lastItemJson = JSON.stringify([]);

    var blobToBase64 = function(blob) {
      return new Promise(resolve => {
        let reader = new FileReader();
        reader.onload = function() {
          let dataUrl = reader.result;
          resolve(dataUrl);
        };
        reader.readAsDataURL(blob);
      });
    }

    function getAllFromIDBStore(storeName) {
      return new Promise(
        function(resolve, reject) {
          var dbRequest = indexedDB.open("books");

          dbRequest.onerror = function(event) {
            reject(Error("Error opening DB"));
          };

          dbRequest.onupgradeneeded = function(event) {
            reject(Error('Not found'));
          };

          dbRequest.onsuccess = function(event) {
            var database = event.target.result;

            try {
              var transaction = database.transaction([storeName], 'readonly');
              var objectStore;
              try {
                objectStore = transaction.objectStore(storeName);
              } catch (e) {
                reject(Error('Error getting objects'));
              }

              var objectRequest = objectStore.getAll();

              objectRequest.onerror = function(event) {
                reject(Error('Error getting objects'));
              };

              objectRequest.onsuccess = function(event) {
                if (objectRequest.result) resolve(objectRequest.result);
                else reject(Error('Objects not found'));
              };
            } catch (e) {
              console.log(JSON.stringify({messageType: "error", error: e.name}));
              reject(Error('Error getting objects'));
            }
          };
        }
      );
    }

    try {
      var items = await getAllFromIDBStore("data");
      await Promise.all(items.map(async (item) => {
        try {
          item["coverImage"] = await blobToBase64(item["coverImage"]);
        } catch (e) {}
      }));
      dataJson = JSON.stringify(items);
    } catch (e) {
      dataJson = JSON.stringify([]);
    }

    try {
      bookmarkJson = JSON.stringify(await getAllFromIDBStore("bookmark"));
    } catch (e) {
      bookmarkJson = JSON.stringify([]);
    }

    try {
      lastItemJson = JSON.stringify(await getAllFromIDBStore("lastItem"));
    } catch (e) {
      lastItemJson = JSON.stringify([]);
    }

    console.log(JSON.stringify({messageType: "history", lastItem: lastItemJson, bookmark: bookmarkJson, data: dataJson}));
  } else {

    console.log(JSON.stringify({messageType: "empty"}));

  }
});
''';

  /// Used to fetch JSON for all books in IndexedDB.
  static const String get = '''
indexedDB.databases().then(async (databases) => {
  if (databases.length > 0) {
    var bookmarkJson = JSON.stringify([]);
    var dataJson = JSON.stringify([]);
    var lastItemJson = JSON.stringify([]);

    var blobToBase64 = function(blob) {
      return new Promise(resolve => {
        let reader = new FileReader();
        reader.onload = function() {
          let dataUrl = reader.result;
          resolve(dataUrl);
        };
        reader.readAsDataURL(blob);
      });
    }

    function getAllFromIDBStore(storeName) {
      return new Promise(
        function(resolve, reject) {
          var dbRequest = indexedDB.open("books");

          dbRequest.onerror = function(event) {
            reject(Error("Error opening DB"));
          };

          dbRequest.onupgradeneeded = function(event) {
            reject(Error('Not found'));
          };

          dbRequest.onsuccess = function(event) {
            var database = event.target.result;

            try {
              var transaction = database.transaction([storeName], 'readonly');
              var objectStore;
              try {
                objectStore = transaction.objectStore(storeName);
              } catch (e) {
                reject(Error('Error getting objects'));
              }

              var objectRequest = objectStore.getAll();

              objectRequest.onerror = function(event) {
                reject(Error('Error getting objects'));
              };

              objectRequest.onsuccess = function(event) {
                if (objectRequest.result) resolve(objectRequest.result);
                else reject(Error('Objects not found'));
              };
            } catch (e) {
              console.log(JSON.stringify({messageType: "error", error: e.name}));
              reject(Error('Error getting objects'));
            }
          };
        }
      );
    }

    try {
      var items = await getAllFromIDBStore("data");
      await Promise.all(items.map(async (item) => {
        try {
          item["coverImage"] = await blobToBase64(item["coverImage"]);
        } catch (e) {}
      }));
      dataJson = JSON.stringify(items);
    } catch (e) {
      dataJson = JSON.stringify([]);
    }

    try {
      bookmarkJson = JSON.stringify(await getAllFromIDBStore("bookmark"));
    } catch (e) {
      bookmarkJson = JSON.stringify([]);
    }

    try {
      lastItemJson = JSON.stringify(await getAllFromIDBStore("lastItem"));
    } catch (e) {
      lastItemJson = JSON.stringify([]);
    }

    console.log(JSON.stringify({messageType: "history", lastItem: lastItemJson, bookmark: bookmarkJson, data: dataJson}));
  } else {

    console.log(JSON.stringify({messageType: "empty"}));

  }
});
''';

  /// This ensures that the internal version included with the app always uses
  /// the cache and is consistent. If this version changes and the current stored
  /// last version mismatches, a load from network is forced. The app will then
  /// update its new last version, and all new loads will be from the cache
  /// unless there is a new app version loaded with a different internal version.
  static const ttuInternalVersion = 2;

  /// Used to check for the current version.
  int? get currentTtuInternalVersion {
    return getPreference<int?>(key: 'ttu_internal_version', defaultValue: null);
  }

  /// Sets the new version.
  void setTtuInternalVersion() async {
    await setPreference<int?>(
      key: 'ttu_internal_version',
      value: ttuInternalVersion,
    );
  }
}
