// 浏览页的返回优先级：查词弹窗 → 网页历史 → 离开浏览页。
//
// 查词弹窗栈（SrsCardLookupHost）挂在浏览页路由之内、没有自己的 PopScope。重设计
// 后浏览页是推出来的全屏子页，PopScope 只看「网页能不能后退」时，弹窗开着按
// Android 系统返回 / 桌面 Esc 会把整个浏览页连同弹窗一起关掉。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';

/// 弹窗几何 / 历史读偏好的那几项钉成常量（与 srs_card_lookup_test 同法）。
class _BrowserApp extends AppModel {
  _BrowserApp() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  bool get lowMemoryMode => false;
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}
}

Future<DictionarySearchResult> _fakeSearch(String term, int max) async =>
    DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: term, reading: 'よみ', meaning: 'm'),
      ],
    );

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late FushiDatabase db;
  late _BrowserApp appModel;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tmp = Directory.systemTemp.createTempSync('fushi_web_browser_back_');
    appModel = _BrowserApp()
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
    MangaWebViewEnvironment.override = () async => null;
    FushiWebBrowserPage.debugTabViewBuilder =
        (BuildContext _, WebBrowserTab _) => const ColoredBox(
          key: ValueKey<String>('stub-webview'),
          color: Colors.white,
        );
  });

  tearDown(() async {
    MangaWebViewEnvironment.override = null;
    FushiWebBrowserPage.debugTabViewBuilder = null;
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on Object {
      // Windows 偶发占用：临时目录留给系统清理。
    }
  });

  testWidgets('查词弹窗开着按系统返回：只关弹窗，浏览页留着；再按一次才离开', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          ...popupMiningTargetTestOverrides(),
          srsCardLookupSearchProvider.overrideWithValue(_fakeSearch),
          webBrowserStoreProvider.overrideWithValue(MemoryWebBrowserStore()),
          webAdblockServiceProvider.overrideWith(
            (Ref ref) => WebAdblockService(
              dataDir: () => null,
              fetcher: (Uri url, {String? etag, String? lastModified}) async =>
                  const AdblockFetchResponse(statusCode: 503),
            ),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: nav,
            home: const Scaffold(body: Text('origin')),
          ),
        ),
      ),
    );
    unawaited(
      openFushiWebBrowser(
        nav.currentContext!,
        Uri.parse('https://example.com/'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsOneWidget);

    final SrsCardLookupController lookup = tester
        .widget<SrsCardLookupHost>(find.byType(SrsCardLookupHost))
        .controller;
    lookup.lookup(
      const SrsCardLookupRequest(
        term: '通う',
        anchor: Rect.fromLTWH(40, 200, 20, 20),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 2));
    expect(lookup.isOpen, isTrue);

    // Android 系统返回（桌面 Esc 走同一个 maybePop）。
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(lookup.isOpen, isFalse, reason: '返回先关查词弹窗');
    expect(
      find.byType(FushiWebBrowserPage),
      findsOneWidget,
      reason: '弹窗开着时返回不能把整个浏览页一起关掉',
    );
    await tester.pump(const Duration(seconds: 2));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsNothing);
    expect(find.text('origin'), findsOneWidget);
  });
}
