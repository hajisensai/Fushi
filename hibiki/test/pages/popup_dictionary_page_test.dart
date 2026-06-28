import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/utils/spacing.dart';

import '../helpers/test_platform_services.dart';

class PopupTestAppModel extends AppModel {
  PopupTestAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 400;

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
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Widget buildTestApp({
  required AppModel appModel,
  required Widget home,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: home,
      ),
    ),
  );
}

void main() {
  final List<String> launchedUrls = <String>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async {
        if (call.method == 'launch') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          launchedUrls.add(args['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  testWidgets('renders an in-app close button when requested', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    final AppModel appModel = AppModel(testPlatformServices());

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () => closed = true,
          autoSearchOnOpen: false,
        ),
      ),
    );

    await tester.pump();

    final Finder closeButton = find.byKey(
      const ValueKey<String>('popup_dictionary_close_button'),
    );

    expect(closeButton, findsOneWidget);

    await tester.tap(closeButton);
    await tester.pump();

    expect(closed, isTrue);
  });

  testWidgets('desktop lookup opens in-app instead of launching hibiki url', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = AppModel(testPlatformServices());

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    unawaited(appModel.openPopupDictionaryLookup(searchTerm: 'search'));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('popup_dictionary_close_button')),
      findsOneWidget,
    );
    expect(launchedUrls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('popup_dictionary_close_button')),
    );
    await tester.pump();
  });

  testWidgets('desktop popup dialog renders inside a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);
    final AppModel appModel = AppModel(testPlatformServices());

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    unawaited(appModel.openPopupDictionaryLookup(searchTerm: 'search'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);

    final Rect dialogRect = tester.getRect(find.byType(Dialog));

    expect(dialogRect.left, greaterThanOrEqualTo(0));
    expect(dialogRect.top, greaterThanOrEqualTo(0));
    expect(dialogRect.right, lessThanOrEqualTo(320));
    expect(dialogRect.bottom, lessThanOrEqualTo(240));
  });

  testWidgets('exposes stable popup search targets for desktop drive', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = AppModel(testPlatformServices());

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('popup_dictionary_search_field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('popup_dictionary_search_button')),
      findsOneWidget,
    );
    expect(find.byType(HibikiOverlayScaffold), findsOneWidget);
  });

  testWidgets('popup search bar submits trimmed query from button', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = AppModel(testPlatformServices());
    final TextEditingController controller =
        TextEditingController(text: '  日本語  ');
    final FocusNode focusNode = FocusNode();
    final List<String> submitted = <String>[];
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: Scaffold(
          body: PopupDictionarySearchBar(
            controller: controller,
            focusNode: focusNode,
            onClose: null,
            onSubmit: submitted.add,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('popup_dictionary_search_button')),
    );
    await tester.pump();

    expect(submitted, <String>['日本語']);
  });

  testWidgets('popup search bar submits trimmed query from keyboard action', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = AppModel(testPlatformServices());
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode();
    final List<String> submitted = <String>[];
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: Scaffold(
          body: PopupDictionarySearchBar(
            controller: controller,
            focusNode: focusNode,
            onClose: null,
            onSubmit: submitted.add,
          ),
        ),
      ),
    );

    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, '  keyboard  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(submitted, <String>['keyboard']);
  });

  testWidgets('base popup layer wires tap outside for in-app popup', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = PopupTestAppModel();

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );

    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, 'search');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final DictionaryPopupLayer layer = tester.widget(
      find.byType(DictionaryPopupLayer),
    );

    expect(layer.onTapOutside, isNotNull);
  });

  testWidgets('base popup layer disables swipe dismiss inside popup host', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = PopupTestAppModel();

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );

    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, 'search');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final DictionaryPopupLayer layer = tester.widget(
      find.byType(DictionaryPopupLayer),
    );

    expect(layer.swipeDismissible, isFalse);
  });

  testWidgets('renders a generic source text panel outside the WebView stack', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = PopupTestAppModel();

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'abcdef',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );

    expect(find.byType(SourceLookupTextPanel), findsOneWidget);
    expect(find.textContaining('Clipboard'), findsNothing);
    expect(find.textContaining('剪贴板'), findsNothing);

    await tester.tap(find.text('c'));
    await tester.pump();

    final PopupDictionarySearchBar searchBar = tester.widget(
      find.byType(PopupDictionarySearchBar),
    );
    expect(searchBar.controller.text, 'cdef');
  });

  test('source guard: popup dictionary consumes layer visibility and logs perf',
      () {
    final String popup =
        File('lib/src/pages/implementations/popup_dictionary_page.dart')
            .readAsStringSync();
    final String model =
        File('lib/src/models/app_model.dart').readAsStringSync();

    expect(popup, contains('SourceLookupTextPanel'),
        reason: 'non-clipboard popup queries need the same clickable source '
            'text panel outside the WebView.');
    // TODO-951 症状C：可见层满卡渲染、隐藏层（常驻热槽/挂起冷层）停到卡外继续预热
    // （IgnorePointer 兜住触摸）。可见性闸门由 `if (entry.visible)` 分流，不再是裸
    // Visibility(visible: entry.visible)。
    expect(popup, contains('if (entry.visible) {'),
        reason: 'external popup layers must honor controller visibility before '
            'any hidden/preload state can be safe.');
    expect(popup, contains('keepWebViewWarm: entry.isWarmSlot'),
        reason: 'external popup must keep the warm slot WebView pre-warmed to '
            'kill the per-lookup flash (TODO-951 symptom C).');
    expect(popup, contains('[popup-perf]'),
        reason: 'Windows popup first lookup needs startup/search/render timing '
            'breadcrumbs.');
    expect(model, contains('MediaSource.setDatabase(_database)'),
        reason: 'popup init must attach MediaSource prefs to the popup DB.');
    expect(model, contains('ReaderHibikiSource.instance.initialise()'),
        reason: 'popup init must hydrate ReaderHibikiSource preferences.');
  });
}
