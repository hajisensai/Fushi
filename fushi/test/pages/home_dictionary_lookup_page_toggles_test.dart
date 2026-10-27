import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// 反馈 3D-JH966Kr / cczhbM7ZOI（设计第 9 项）：查词页两个开关 + 收起键盘按钮。
///
/// - 「结果顶部下拉清空查询」关掉后，结果 WebView 上报的顶部下拉不再清空查询；
/// - 「进入查词页自动聚焦搜索框」关掉后，导航点进查词（clearQuery 请求）只清空、
///   不把焦点送进搜索框（移动端就不弹键盘）；
/// - 移动端软键盘弹着时，搜索栏尾部有一枚「收起键盘」，点了只收键盘。
///
/// 两个开关默认开 = 原行为，默认分支各有一条断言钉住。
class _TogglesAppModel extends AppModel {
  _TogglesAppModel({required this.pullToClear, required this.autoShowKeyboard})
    : super(testPlatformServices());

  final bool pullToClear;
  final bool autoShowKeyboard;

  @override
  bool get lookupPagePullToClear => pullToClear;

  @override
  bool get lookupPageAutoShowKeyboard => autoShowKeyboard;

  @override
  bool get autoSearchEnabled => false;

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
  double get defaultDictionaryFontSize => 26;

  @override
  double get dictionaryFontSize => 26;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  // 查到结果会自动朗读（autoReadOnLookup 默认开）：替身没有偏好仓库，给空音源。
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

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
    return DictionarySearchResult(
      searchTerm: searchTerm,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'Test',
          word: searchTerm,
          reading: searchTerm,
          meaning: '["m"]',
        ),
      ],
    );
  }
}

Widget _wrap(
  _TogglesAppModel appModel, {
  ValueNotifier<DictionaryFocusRequest?>? focusSignal,
}) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(body: HomeDictionaryPage(focusSignal: focusSignal)),
      ),
    ),
  );
}

final Finder _searchField = find.byKey(
  const ValueKey<String>('home_dictionary_search_field'),
);
final Finder _resultEvidence = find.byKey(
  const ValueKey<String>('home_dictionary_result_evidence'),
);
final Finder _hideKeyboardButton = find.byKey(
  const ValueKey<String>('home_dictionary_hide_keyboard_button'),
);

bool _searchFieldFocused(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _searchField, matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

String _searchFieldText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _searchField, matching: find.byType(EditableText)),
    )
    .controller
    .text;

Future<void> _searchFor(WidgetTester tester, String term) async {
  await tester.tap(_searchField);
  await tester.enterText(_searchField, term);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump();
}

/// 结果 WebView 里的 JS 识别到顶部下拉后经 `topPullReleased` 桥回调的就是这个
/// 回调——直接调它等价于真实手势落地（JS 本身由别的守卫钉住）。
void _releaseTopPull(WidgetTester tester) {
  final DictionaryPopupWebView webView = tester.widget<DictionaryPopupWebView>(
    find.byType(DictionaryPopupWebView).first,
  );
  webView.onTopPullReleased!.call();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  tearDown(DesktopLookupService.instance.debugReset);

  group('结果顶部下拉清空查询', () {
    testWidgets('默认开：顶部下拉清空查询（原行为）', (WidgetTester tester) async {
      final _TogglesAppModel appModel = _TogglesAppModel(
        pullToClear: true,
        autoShowKeyboard: true,
      );
      await tester.pumpWidget(_wrap(appModel));
      await tester.pump();
      await _searchFor(tester, 'word');
      expect(_resultEvidence, findsOneWidget);

      _releaseTopPull(tester);
      await tester.pump();

      expect(_resultEvidence, findsNothing);
      expect(_searchFieldText(tester), isEmpty);
    });

    testWidgets('关掉后：顶部下拉不清空，结果原样留着', (WidgetTester tester) async {
      final _TogglesAppModel appModel = _TogglesAppModel(
        pullToClear: false,
        autoShowKeyboard: true,
      );
      await tester.pumpWidget(_wrap(appModel));
      await tester.pump();
      await _searchFor(tester, 'word');
      expect(_resultEvidence, findsOneWidget);

      _releaseTopPull(tester);
      await tester.pump();

      expect(_resultEvidence, findsOneWidget);
      expect(_searchFieldText(tester), 'word');
    });
  });

  group('进入查词页自动聚焦搜索框', () {
    Future<void> enterFromNav(
      WidgetTester tester,
      _TogglesAppModel appModel,
    ) async {
      final ValueNotifier<DictionaryFocusRequest?> signal =
          ValueNotifier<DictionaryFocusRequest?>(null);
      addTearDown(signal.dispose);
      await tester.pumpWidget(_wrap(appModel, focusSignal: signal));
      await tester.pump();
      await _searchFor(tester, 'word');
      // 用户已经离开搜索框（例如点过结果、或系统收了键盘并交出焦点）。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(_searchFieldFocused(tester), isFalse);

      // 底栏 / rail 再点「查词」= HomePage._selectTabFromNav 发的 clearQuery 请求。
      signal.value = const DictionaryFocusRequest(
        DictionaryFocusIntent.clearQuery,
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('默认开：点进查词清空查询并聚焦搜索框（BUG-2687 原行为）', (
      WidgetTester tester,
    ) async {
      await enterFromNav(
        tester,
        _TogglesAppModel(pullToClear: true, autoShowKeyboard: true),
      );
      expect(_searchFieldText(tester), isEmpty);
      expect(_searchFieldFocused(tester), isTrue);
    });

    testWidgets('关掉后：点进查词只清空，不把焦点送进搜索框（不弹键盘）', (WidgetTester tester) async {
      await enterFromNav(
        tester,
        _TogglesAppModel(pullToClear: true, autoShowKeyboard: false),
      );
      expect(_searchFieldText(tester), isEmpty);
      expect(_searchFieldFocused(tester), isFalse);
    });

    testWidgets('关掉后：显式「聚焦搜索框」热键（keepQuery）照常聚焦', (WidgetTester tester) async {
      final ValueNotifier<DictionaryFocusRequest?> signal =
          ValueNotifier<DictionaryFocusRequest?>(null);
      addTearDown(signal.dispose);
      await tester.pumpWidget(
        _wrap(
          _TogglesAppModel(pullToClear: true, autoShowKeyboard: false),
          focusSignal: signal,
        ),
      );
      await tester.pump();
      expect(_searchFieldFocused(tester), isFalse);

      signal.value = const DictionaryFocusRequest(
        DictionaryFocusIntent.keepQuery,
      );
      await tester.pump();
      await tester.pump();
      expect(_searchFieldFocused(tester), isTrue);
    });
  });

  group('收起键盘按钮', () {
    testWidgets('移动端键盘弹着时出现，点了只收键盘、焦点留在框里', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          _wrap(_TogglesAppModel(pullToClear: true, autoShowKeyboard: true)),
        );
        await tester.pump();
        expect(_hideKeyboardButton, findsNothing);

        await tester.tap(_searchField);
        await tester.pump();
        // 焦点在、键盘没弹（viewInsets 为 0）：不出按钮。
        expect(_hideKeyboardButton, findsNothing);

        // 软键盘弹起 = 窗口底部 viewInsets > 0（didChangeMetrics）。
        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        await tester.pump();
        expect(_hideKeyboardButton, findsOneWidget);

        tester.testTextInput.log.clear();
        await tester.tap(_hideKeyboardButton);
        await tester.pump();
        expect(
          tester.testTextInput.log.map((MethodCall call) => call.method),
          contains('TextInput.hide'),
        );
        expect(_searchFieldFocused(tester), isTrue);

        // 键盘收下去（viewInsets 回 0）按钮随之消失。
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        expect(_hideKeyboardButton, findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('桌面没有软键盘：不出按钮', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          _wrap(_TogglesAppModel(pullToClear: true, autoShowKeyboard: true)),
        );
        await tester.pump();
        await tester.tap(_searchField);
        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        await tester.pump();
        expect(_hideKeyboardButton, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
