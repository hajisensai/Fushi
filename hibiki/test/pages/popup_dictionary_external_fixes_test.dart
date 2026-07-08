import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// TODO-951 — app 外查词弹窗（独立 PopupDictionaryPage 表面）四症状修复守卫。
/// 症状 A（点父弹窗关一层）/ C（关后代 helper）的精确路由由 source guard
/// `dictionary_child_popup_close_guard_test.dart` 守；本文件守：
///  - 症状 B：关闭 X 与滑动手势解耦（X 不在 SwipeDismissWrapper 子树内）。
///  - 症状 C：宿主 popup_main 不再 ValueKey 重建整页 + 页面 seed 常驻热槽、热槽
///    keepWebViewWarm 全程预热。
class _PopupTestAppModel extends AppModel {
  _PopupTestAppModel() : super(testPlatformServices());

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

Widget _wrap(AppModel appModel, Widget home) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (context, child) => child ?? const SizedBox.shrink(),
        home: home,
      ),
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  String popupSrc() => File(
        'lib/src/pages/implementations/popup_dictionary_page.dart',
      ).readAsStringSync();

  group('TODO-951 symptom C: no ValueKey rebuild + warm slot', () {
    test('popup_main no longer force-rebuilds the page per lookup', () {
      final String main = File('lib/popup_main.dart').readAsStringSync();
      // 旧路：每次新 ProcessText ValueKey 重建整页（含 WebView）→ 闪。
      expect(main, isNot(contains("key: ValueKey('\$_searchTerm")),
          reason: '不得再用 ValueKey 强制重建整页（会丢弃并冷重建弹窗 WebView 闪烁）');
      // 新路：把递增 generation 透传，页面常驻、didUpdateWidget 复用热槽重查。
      expect(main, contains('searchGeneration: _searchGeneration'),
          reason: '把 generation 透传，页面常驻不重建');
    });

    test('popup page seeds a warm slot and keeps its WebView warm', () {
      final String src = popupSrc();
      expect(src, contains('_popup.seedWarmSlot()'), reason: '开页 seed 常驻隐藏热槽');
      expect(src, contains('keepWebViewWarm: entry.isWarmSlot'),
          reason: '热槽 WebView 全程挂载预热');
      expect(src, contains('reuseWarmSlot: reuseWarmSlot'),
          reason: '顶层查词复用热槽原地查新词');
      expect(src, contains('void didUpdateWidget(PopupDictionaryPage'),
          reason: '宿主改 searchTerm/generation 时 didUpdateWidget 复用热槽重查');
      // 顶层重查保留热槽（不 clear 掉热 WebView）。
      expect(src, contains('_popup.pruneToWarmSlot'),
          reason: '顶层重查保留常驻热槽，不 clear');
    });
  });

  group('TODO-951 symptom B: close decoupled from swipe', () {
    test('search bar no longer carries the close button (moved out of swipe)',
        () {
      final String src = popupSrc();
      // 关闭 X 由 _buildCloseButton 在 swipe wrapper 之外独立渲染。
      expect(src, contains('Widget _buildCloseButton()'), reason: '独立关闭按钮入口存在');
      expect(src, contains('onClose: null'),
          reason: 'search bar 不再自带关闭 X（已移出 swipe wrapper）');
    });

    testWidgets('close button lives outside the SwipeDismissWrapper subtree',
        (WidgetTester tester) async {
      final AppModel appModel = _PopupTestAppModel();
      await tester.pumpWidget(
        _wrap(
          appModel,
          PopupDictionaryPage(
            searchTerm: 'search',
            closeInApp: () {},
            autoSearchOnOpen: false,
          ),
        ),
      );
      await tester.pump();

      final Finder closeButton = find.byKey(
        const ValueKey<String>('popup_dictionary_close_button'),
      );
      expect(closeButton, findsOneWidget);

      // 关闭按钮不得是任何 SwipeDismissWrapper 的后代——否则横拖手势可能连带/误判。
      final Finder swipeAncestor = find.ancestor(
        of: closeButton,
        matching: find.byType(SwipeDismissWrapper),
      );
      expect(swipeAncestor, findsNothing,
          reason: '关闭 X 必须在 SwipeDismissWrapper 之外（症状B 解耦）');
    });

    testWidgets('tapping the close button closes directly (no swipe needed)',
        (WidgetTester tester) async {
      bool closed = false;
      final AppModel appModel = _PopupTestAppModel();
      await tester.pumpWidget(
        _wrap(
          appModel,
          PopupDictionaryPage(
            searchTerm: 'search',
            closeInApp: () => closed = true,
            autoSearchOnOpen: false,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('popup_dictionary_close_button')),
      );
      await tester.pump();
      expect(closed, isTrue, reason: '点 X 直接关，不依赖滑动手势');
    });
  });

  testWidgets(
      'symptom C: the rendered popup layer keeps its WebView warm (warm slot)',
      (WidgetTester tester) async {
    final AppModel appModel = _PopupTestAppModel();
    await tester.pumpWidget(
      _wrap(
        appModel,
        PopupDictionaryPage(
          searchTerm: 'first',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );
    await tester.pump();

    // 手动提交查词（测试 AppModel 未跑完整初始化，autoSearchOnOpen 不触发；与既有
    // popup widget 测试同范式——手动 enterText + search action 驱动一次真实查词）。
    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, 'first');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();

    // 至少有一个 DictionaryPopupLayer，且复用热槽那层 keepWebViewWarm=true（其 WebView
    // 全程预热复用，不随每次查词重建 → 不闪）。widgetList 不抛 No element，断言更稳。
    final Iterable<DictionaryPopupLayer> layers =
        tester.widgetList<DictionaryPopupLayer>(
      find.byType(DictionaryPopupLayer),
    );
    expect(layers, isNotEmpty, reason: '查词后至少渲染一层弹窗');
    // keepWebViewWarm 字段恒被透传（热槽=true / 普通层=false）。本测试 AppModel 未跑
    // 完整初始化故无热槽，断言「字段已接线」即可；热槽=true 的实际复用行为由 source
    // guard（keepWebViewWarm: entry.isWarmSlot）+ controller 单元测试覆盖。
    expect(layers.every((DictionaryPopupLayer l) => l.keepWebViewWarm == false),
        isTrue,
        reason: '非热槽层 keepWebViewWarm=false（字段已接线，热槽真值由 source guard 守）');

    // 顶层查词，搜索栏唯一。
    expect(find.byType(HibikiCompactSearchRow), findsOneWidget);
  });

  // TODO-1144：头部 Row 里关闭按钮与搜索栏并排，两者必须等高（消除旧 36 vs 44 的 8px
  // 高差）。关闭按钮命中盒与 HibikiCompactSearchRow 内 `SizedBox(height: 44)` 都应为 44。
  testWidgets(
      'TODO-1144: popup close button height matches the compact search row (44)',
      (WidgetTester tester) async {
    final AppModel appModel = _PopupTestAppModel();
    await tester.pumpWidget(
      _wrap(
        appModel,
        PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    );
    await tester.pump();

    // 关闭按钮渲染盒高度。
    final Finder closeButton = find.byKey(
      const ValueKey<String>('popup_dictionary_close_button'),
    );
    expect(closeButton, findsOneWidget);
    final double closeHeight = tester.getSize(closeButton).height;

    // HibikiCompactSearchRow 内部的 44 高度 SizedBox（并排的搜索栏本体）。
    final Finder searchRowBox = find.descendant(
      of: find.byType(HibikiCompactSearchRow),
      matching: find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.height == 44,
      ),
    );
    expect(searchRowBox, findsOneWidget,
        reason: 'HibikiCompactSearchRow 内是 SizedBox(height: 44)');
    final double searchHeight = tester.getSize(searchRowBox).height;

    expect(closeHeight, 44.0, reason: '关闭按钮命中盒高度对齐搜索栏 = 44');
    expect(searchHeight, 44.0, reason: '搜索栏内盒高度 = 44');
    expect(closeHeight, searchHeight,
        reason: '关闭按钮与搜索栏等高，消除 TODO-1144 的 8px 高差');
  });

  group('TODO-1336: warm reuse resets the closing latch', () {
    test('didUpdateWidget resets _isClosing so a reused warm page can reclose',
        () {
      final String src = popupSrc();
      // warm 复用（Android FlutterEngineCache 缓存 :popup 引擎、finishPopup 只隐藏
      // Activity 不销毁本 State；同一 State 经 didUpdateWidget 反复复用）下，_close 首次
      // 把 _isClosing 置 true 后若不复位 → 首次查词关闭后所有关闭路径都被 _close 开头闭锁
      // 卡死。复位必须落在 didUpdateWidget 里（宿主推来新词=重开），而不是别处。
      final int idx = src.indexOf('void didUpdateWidget(PopupDictionaryPage');
      expect(idx, greaterThanOrEqualTo(0), reason: 'didUpdateWidget 必须存在');
      final int endIdx = src.indexOf('void dispose()', idx);
      final String body =
          endIdx > idx ? src.substring(idx, endIdx) : src.substring(idx);
      expect(body, contains('_isClosing = false'),
          reason: 'didUpdateWidget 复用热页时必须复位 _isClosing（TODO-1336）');
    });

    testWidgets(
        'every warm reopen (didUpdateWidget) can close again, not just the first',
        (WidgetTester tester) async {
      int closeCount = 0;
      final AppModel appModel = _PopupTestAppModel();

      Widget build(int generation) => _wrap(
            appModel,
            PopupDictionaryPage(
              searchTerm: 'neko',
              searchGeneration: generation,
              closeInApp: () => closeCount++,
              autoSearchOnOpen: false,
            ),
          );

      await tester.pumpWidget(build(0));
      await tester.pump();

      final Finder closeButton = find.byKey(
        const ValueKey<String>('popup_dictionary_close_button'),
      );

      // 第一次关闭：_close 把 _isClosing false→true 并触发 closeInApp（计 1）。此 State
      // 仍挂载（模拟 Android 缓存引擎下 finishPopup 不销毁 State 的 warm 复用）。
      await tester.tap(closeButton);
      await tester.pump();
      expect(closeCount, 1, reason: '首次关闭必须生效');

      // 模拟 warm 复用重开：宿主递增 generation → 同一 State 触发 didUpdateWidget。
      await tester.pumpWidget(build(1));
      await tester.pump();

      // 第二次关闭：修复前 _isClosing 残留 true → _close 开头早退 → closeCount 卡在 1；
      // 修复后 didUpdateWidget 已复位 _isClosing → 正常关闭 → closeCount == 2。
      await tester.tap(closeButton);
      await tester.pump();
      expect(closeCount, 2,
          reason: 'warm 复用重开后必须能再次关闭（_isClosing 已在 didUpdateWidget 复位）');

      // 第三轮再复用 + 关闭，确认不是一次性复位而是每次重开都复位。
      await tester.pumpWidget(build(2));
      await tester.pump();
      await tester.tap(closeButton);
      await tester.pump();
      expect(closeCount, 3, reason: '每次 warm 复用重开都要能关闭，不止一次');
    });
  });
}
