import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_bookmarks_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_clear_data_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_downloads_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_history_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_search_engines_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_site_settings_page.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/utils.dart';

class _MapPrefStore implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _FakeCleaner implements WebBrowserSiteDataCleaner {
  int cookies = 0;
  int cache = 0;

  @override
  bool get supportsTimeRange => false;

  @override
  Future<bool> clearCookiesAndSiteData({DateTime? since}) async {
    cookies++;
    return true;
  }

  @override
  Future<bool> clearCache() async {
    cache++;
    return true;
  }
}

Widget _wrap(Widget page) => ProviderScope(
  child: TranslationProvider(child: MaterialApp(home: page)),
);

Future<void> _pickMenu(
  WidgetTester tester,
  String menuKey,
  String label,
) async {
  await tester.tap(find.byKey(ValueKey<String>(menuKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('history groups by day, opens, and deletes one entry', (
    WidgetTester tester,
  ) async {
    final MemoryWebBrowserStore store = MemoryWebBrowserStore();
    final DateTime now = DateTime.now();
    store.seedHistory(
      url: Uri.parse('https://today.example/'),
      title: 'Today page',
      lastVisitedAt: now,
    );
    store.seedHistory(
      url: Uri.parse('https://old.example/'),
      title: 'Old page',
      lastVisitedAt: now.subtract(const Duration(days: 1)),
    );
    final List<Uri> opened = <Uri>[];
    await tester.pumpWidget(
      _wrap(
        WebBrowserHistoryPage(
          store: store,
          onOpen: (Uri url, {bool newTab = false}) => opened.add(url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.home_today), findsOneWidget);
    expect(find.text(t.home_yesterday), findsOneWidget);
    expect(find.text('Today page'), findsOneWidget);

    await tester.tap(find.text('Today page'));
    await tester.pumpAndSettle();
    expect(opened, <Uri>[Uri.parse('https://today.example/')]);

    final int oldId = (await store.history(query: 'Old')).single.id;
    await _pickMenu(
      tester,
      'web_browser_history_menu_$oldId',
      t.options_delete,
    );
    expect(
      (await store.history()).map((WebBrowserHistoryEntry e) => e.title),
      <String>['Today page'],
    );
    expect(find.text('Old page'), findsNothing);
  });

  testWidgets('bookmarks browse folders and create a folder', (
    WidgetTester tester,
  ) async {
    final MemoryWebBrowserStore store = MemoryWebBrowserStore();
    final int folder = await store.addFolder(title: 'Manga');
    await store.addBookmark(
      title: 'MangaDex',
      url: Uri.parse('https://mangadex.org/'),
      parentId: folder,
    );
    await store.addBookmark(
      title: 'Top level',
      url: Uri.parse('https://top.example/'),
    );
    await tester.pumpWidget(_wrap(WebBrowserBookmarksPage(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Top level'), findsOneWidget);
    expect(find.text('MangaDex'), findsNothing);

    await tester.tap(find.text('Manga'));
    await tester.pumpAndSettle();
    expect(find.text('MangaDex'), findsOneWidget);
    expect(find.text('Top level'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('web_browser_bookmarks_new_folder')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'Sub');
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_create));
    await tester.pumpAndSettle();
    final List<WebBrowserBookmark> inside = await store.bookmarks(
      parentId: folder,
    );
    expect(inside.map((WebBrowserBookmark b) => b.title), <String>[
      'MangaDex',
      'Sub',
    ]);
    expect(find.text('Sub'), findsOneWidget);
  });

  testWidgets('downloads show progress and remove a record', (
    WidgetTester tester,
  ) async {
    final MemoryWebBrowserStore store = MemoryWebBrowserStore();
    final int running = await store.addDownload(
      WebBrowserDownload(
        id: 0,
        url: Uri.parse('https://files.example/a.zip'),
        fileName: 'a.zip',
        startedAt: DateTime(2026, 10, 23),
        totalBytes: 2048,
        receivedBytes: 1024,
      ),
    );
    await store.addDownload(
      WebBrowserDownload(
        id: 0,
        url: Uri.parse('https://files.example/b.pdf'),
        fileName: 'b.pdf',
        startedAt: DateTime(2026, 10, 22),
        totalBytes: 10,
        receivedBytes: 10,
        state: WebBrowserDownloadState.completed,
        savedPath: '/tmp/b.pdf',
      ),
    );
    final List<String> openedFiles = <String>[];
    await tester.pumpWidget(
      _wrap(
        WebBrowserDownloadsPage(
          store: store,
          openFile: (String path) async => openedFiles.add(path),
          revealFile: (String path) async => true,
          fileExists: (String path) => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('a.zip'), findsOneWidget);
    expect(find.text('b.pdf'), findsOneWidget);
    expect(find.byType(FushiLinearProgressIndicator), findsOneWidget);

    await tester.tap(find.text('b.pdf'));
    await tester.pumpAndSettle();
    expect(openedFiles, <String>['/tmp/b.pdf']);

    await _pickMenu(
      tester,
      'web_browser_download_menu_$running',
      t.web_browser_download_remove,
    );
    expect(
      (await store.downloads()).map((WebBrowserDownload d) => d.fileName),
      <String>['b.pdf'],
    );
  });

  testWidgets('clear data clears history, cookies and cache', (
    WidgetTester tester,
  ) async {
    final MemoryWebBrowserStore store = MemoryWebBrowserStore();
    await store.recordVisit(url: Uri.parse('https://a.example/'), title: 'A');
    final _FakeCleaner cleaner = _FakeCleaner();
    await tester.pumpWidget(
      _wrap(WebBrowserClearDataPage(store: store, cleaner: cleaner)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('web_browser_clear_data_cookies')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.web_browser_clear_data_all_time_note), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('web_browser_clear_data_action')),
    );
    await tester.pumpAndSettle();
    expect(await store.history(), isEmpty);
    expect(cleaner.cookies, 1);
    expect(cleaner.cache, 1);
    expect(find.text(t.web_browser_clear_data_done), findsOneWidget);
  });

  testWidgets('site settings list, change and reset a site', (
    WidgetTester tester,
  ) async {
    final _MapPrefStore prefs = _MapPrefStore();
    final WebBrowserSiteSettings settings = WebBrowserSiteSettings(prefs);
    await settings.setDecision(
      'https://a.example',
      WebBrowserSitePermission.camera,
      WebBrowserPermissionDecision.allow,
    );
    await tester.pumpWidget(
      _wrap(WebBrowserSiteSettingsPage(settings: settings)),
    );
    await tester.pumpAndSettle();
    expect(find.text('https://a.example'), findsOneWidget);
    // 按行断言：摄像头记住了允许；受保护内容没记住，但生效决定是默认允许。
    for (final String row in <String>['camera', 'protectedContent']) {
      expect(
        find.descendant(
          of: find.byKey(
            ValueKey<String>(
              'web_browser_site_settings_https://a.example_$row',
            ),
          ),
          matching: find.text(t.web_browser_permission_request_allow),
        ),
        findsOneWidget,
      );
    }
    expect(find.text(t.web_browser_permission_request_allow), findsNWidgets(2));

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'web_browser_site_settings_https://a.example_microphone',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.web_browser_permission_request_block).last);
    await tester.pumpAndSettle();
    expect(
      settings.decision(
        'https://a.example',
        WebBrowserSitePermission.microphone,
      ),
      WebBrowserPermissionDecision.block,
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'web_browser_site_settings_clear_https://a.example',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(settings.all(), isEmpty);
    expect(find.text(t.web_browser_site_settings_empty), findsOneWidget);
  });

  testWidgets('search engines select builtin and add a custom one', (
    WidgetTester tester,
  ) async {
    final _MapPrefStore prefs = _MapPrefStore();
    await tester.pumpWidget(_wrap(WebBrowserSearchEnginesPage(prefs: prefs)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bing'));
    await tester.pumpAndSettle();
    expect(prefs.values[kWebBrowserSearchEnginePref], 'bing');

    await tester.tap(
      find.byKey(const ValueKey<String>('web_browser_search_engine_add')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('web_browser_form_field_0')),
        matching: find.byType(EditableText),
      ),
      'Wiki',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('web_browser_form_field_1')),
        matching: find.byType(EditableText),
      ),
      'https://wiki.example/?search=%s',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('web_browser_form_confirm')),
    );
    await tester.pumpAndSettle();

    final List<WebBrowserCustomSearchEngine> customs =
        readWebBrowserCustomSearchEngines(prefs);
    expect(customs.single.name, 'Wiki');
    expect(find.text('Wiki'), findsOneWidget);

    await tester.tap(find.text('Wiki'));
    await tester.pumpAndSettle();
    expect(readWebBrowserSearchProvider(prefs), customs.single);
  });
}
