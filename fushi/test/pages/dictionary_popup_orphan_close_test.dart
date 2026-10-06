import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show HitTestEntry, HitTestResult;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

class _OrphanCloseAppModel extends AppModel {
  _OrphanCloseAppModel(this.directory) : super(testPlatformServices());

  final Directory directory;

  @override
  Directory get appDirectory => directory;
  @override
  Directory get temporaryDirectory => directory;
  @override
  Directory get dictionaryResourceDirectory => directory;

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];
  @override
  List<Dictionary> get dictionaries => <Dictionary>[
    Dictionary(name: 'Test', formatKey: 'test', order: 0),
  ];
  @override
  int get maximumTerms => 10;
  @override
  bool get autoSearchEnabled => false;
  @override
  bool get lowMemoryMode => true;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get defaultDictionaryFontSize => 26;
  @override
  double get dictionaryFontSize => 26;
  @override
  double get appUiScale => 1;
  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async => DictionarySearchResult(
    searchTerm: searchTerm,
    entries: searchTerm == 'main'
        ? <DictionaryEntry>[DictionaryEntry(word: 'main')]
        : <DictionaryEntry>[],
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });
  tearDown(() => DesktopLookupService.instance.debugReset());

  testWidgets('首页查词浮层不得跨普通 push 路由残留；记录是否只剩关闭钮', (WidgetTester tester) async {
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    final PreferencesRepository preferences = PreferencesRepository(database);
    await tester.runAsync(preferences.loadFromDb);
    final Directory directory = Directory.systemTemp.createTempSync(
      'fushi_orphan_close_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final _OrphanCloseAppModel appModel = _OrphanCloseAppModel(directory)
      ..wireLocalAudioForTesting(
        prefsRepo: preferences,
        databaseDirectory: directory,
      )
      ..wireDatabaseForTesting(database);
    final ValueNotifier<bool> tabVisible = ValueNotifier<bool>(true);
    addTearDown(tabVisible.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: tabVisible,
                builder: (BuildContext context, bool visible, Widget? child) =>
                    Offstage(
                      offstage: !visible,
                      child: TickerMode(enabled: visible, child: child!),
                    ),
                child: const HomeDictionaryPage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final State<StatefulWidget> owner = tester.state(
      find.byType(HomeDictionaryPage),
    );
    final HomeDictionarySearchDebug debug = owner as HomeDictionarySearchDebug;
    await tester.runAsync(() => debug.debugSearch('main'));
    await _pumpFrames(tester);
    await tester.runAsync(() => debug.debugOpenPopup('missing'));
    await _pumpFrames(tester);
    final Finder popup = find.byType(DictionaryPopupLayer);
    expect(popup, findsOneWidget);
    expect(debug.debugPopupStackShape.depth, 1);
    expect(find.byType(FushiPlaceholderMessage), findsOneWidget);
    final Rect before = tester.getRect(popup);

    appModel.navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            const Scaffold(body: Center(child: Text('new route'))),
      ),
    );
    await _pumpFrames(tester);
    expect(owner.mounted, isTrue);
    expect(find.text('new route'), findsOneWidget);

    // 诊断必须区分「整张旧卡跨页」与用户截图的「卡外孤立 ×」。
    if (popup.evaluate().isNotEmpty) {
      final Finder close = find.descendant(
        of: popup,
        matching: find.byIcon(Icons.close),
      );
      final Finder empty = find.descendant(
        of: popup,
        matching: find.byType(FushiPlaceholderMessage),
      );
      final Rect after = tester.getRect(popup);
      expect(after, before);
      expect(close, findsOneWidget);
      expect(empty, findsOneWidget);
      expect(after.contains(tester.getCenter(close)), isTrue);
      expect(after.contains(tester.getCenter(empty)), isTrue);
      expect(find.byType(LookupDismissBarrier), findsOneWidget);
      debugPrint(
        'ORPHAN_CLOSE_EVIDENCE: whole popup survives ordinary route '
        'push; rect=$after close=${tester.getRect(close)} '
        'empty=${tester.getRect(empty)}; not a lone close icon.',
      );
    }
    final int survivingPopups = popup.evaluate().length;
    appModel.navigatorKey.currentState!.pop();
    await _pumpFrames(tester);
    expect(popup, findsOneWidget, reason: '退回宿主应恢复同一个查词会话');
    expect(debug.debugPopupStackShape.depth, 1);

    // 浮层自己的非 opaque 菜单路由不能被误判为「宿主离场」。
    final BuildContext popupContext = tester.element(popup);
    final NavigatorState popupNavigator = Navigator.of(popupContext);
    expect(popupNavigator, isNot(same(appModel.navigatorKey.currentState)));
    popupNavigator.push<void>(
      DialogRoute<void>(
        context: popupContext,
        builder: (BuildContext context) =>
            const Center(child: Text('lookup menu')),
      ),
    );
    await _pumpFrames(tester);
    expect(find.text('lookup menu'), findsOneWidget);
    expect(popup, findsOneWidget);
    expect(LookupOverlayNavigator.activeMenuNavigator, same(popupNavigator));
    popupNavigator.pop();
    await _pumpFrames(tester);

    tabVisible.value = false;
    await _pumpFrames(tester);
    final int hiddenTabPopups = popup.evaluate().length;
    tabVisible.value = true;
    await _pumpFrames(tester);
    expect(popup, findsOneWidget, reason: '保活 tab 恢复后查词会话还在');
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(survivingPopups, 0, reason: '根 Overlay 必须服从发起查词的宿主路由可见性');
    expect(hiddenTabPopups, 0, reason: '保活 tab 隐藏时不能留下跨页浮层');
  });

  testWidgets('遮挡裁剪保留关闭钮时，也保留同一片父卡背景', (WidgetTester tester) async {
    const Rect lower = Rect.fromLTWH(100, 100, 400, 280);
    const Rect upper = Rect.fromLTWH(100, 100, 354, 280);
    const ValueKey<String> surfaceKey = ValueKey<String>('lower-surface');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Stack(
          children: <Widget>[
            Positioned.fromRect(
              rect: lower,
              child: PopupOccluderClip(
                layerRect: lower,
                occluders: const <Rect>[upper],
                child: const ColoredBox(
                  key: surfaceKey,
                  color: Colors.black,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.close),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final Finder close = find.byIcon(Icons.close);
    final RenderBox surface = tester.renderObject(find.byKey(surfaceKey));
    final HitTestResult open = tester.hitTestOnBinding(tester.getCenter(close));
    expect(
      open.path.any((HitTestEntry entry) => entry.target == surface),
      isTrue,
    );
    final HitTestResult covered = tester.hitTestOnBinding(
      const Offset(200, 200),
    );
    expect(
      covered.path.any((HitTestEntry entry) => entry.target == surface),
      isFalse,
    );
    expect(
      tester.getRect(find.byKey(surfaceKey)).contains(tester.getCenter(close)),
      isTrue,
    );
  });
}
