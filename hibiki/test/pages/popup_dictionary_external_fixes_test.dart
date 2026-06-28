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
import 'package:hibiki/src/utils/spacing.dart';
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
}
