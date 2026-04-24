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

  /// For serving the reader assets locally.
  Future<LocalAssetsServer> serveLocalAssets(Language language) async {
    int port = getPortForLanguage(language);

    if (_lastServeFailed) {
      await Future.delayed(const Duration(seconds: 1));
    }

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
          showDialog(
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
      defaultValue: 0.3,
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

  /// 在 WebView 加载后将 Hive 偏好写入 ttu localStorage。
  Future<void> applyReaderSettings(
    InAppWebViewController controller, {
    required String appThemeKey,
  }) async {
    final List<String> cmds = [
      'window.localStorage.setItem("fontSize",${ttuFontSize})',
      'window.localStorage.setItem("lineHeight",${ttuLineHeight})',
      'window.localStorage.setItem("writingMode","$ttuWritingMode")',
      'window.localStorage.setItem("viewMode","$ttuViewMode")',
      'window.localStorage.setItem("theme","$appThemeKey")',
      'window.localStorage.setItem("hideFurigana","$ttuHideFurigana")',
    ];
    await controller.evaluateJavascript(source: cmds.join(';'));
  }

  /// Used to fetch JSON for all books in IndexedDB.
  static const String getHistoryJs = '''
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
              var transaction = database.transaction([storeName], 'readwrite');
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
              var transaction = database.transaction([storeName], 'readwrite');
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
