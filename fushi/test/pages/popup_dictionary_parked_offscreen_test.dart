import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// TODO-1379：app 外查词窗（PopupDictionaryPage）的常驻隐藏热槽是 Android 原生
/// InAppWebView 平台视图——IgnorePointer 只挡 Flutter 命中测试，挡不住原生视图直接
/// 截获触摸（BUG-135 已确立）。此前隐藏层只在卡片局部坐标系挪 `cardWidth + 8`，
/// 窄卡/宽屏时停靠点仍在屏内：停在屏内的隐形原生 WebView 吃掉活动弹窗的滚动与
/// 点击（Flutter 层的横滑关闭手势幸存）——精确对应用户症状「上下滑不动、点击没
/// 反应、只能左右滑动关闭」。修复：隐藏层经共享 [parkedPopupLayer]（BUG-135 停靠
/// 几何单一真相）停到真·屏外 `screen.width + 8`，与 reader/video/首页三宿主同机制。
///
/// 真 widget 几何断言（fake InAppWebViewPlatform 由 flutter_test_config 全局装载）：
/// ① 隐藏热槽层 topLeft.dx ≥ 窗口宽 + 8——真在屏外，屏内任何触点在原生层也打不中它
///   （平台视图触摸行为无 headless 测试，屏外几何是可落地的最强断言）；
/// ② 隐藏态在 Flutter 命中测试层不可命中（hitTestable 找不到）、保持真实尺寸预热、
///   经 Visibility(maintainState) 收口；
/// ③ warm 复用循环不回归：搜索提交后同一热槽（webViewKey 不变）翻可见、回屏内、可命中。
class ParkedPopupTestAppModel extends AppModel {
  ParkedPopupTestAppModel() : super(testPlatformServices());

  /// 放行 _seedWarmPopup 的 isInitialised 门，让开页真的 seed 常驻隐藏热槽。
  @override
  bool get isInitialised => true;

  @override
  bool get lowMemoryMode => false;

  @override
  int get maximumTerms => 10;

  /// 窄卡（300 < 窗口宽 800）：旧实现 `cardWidth + 8` 的停靠点（卡片右缘 ~556px）
  /// 正落在屏内——本测试对旧实现必红，对真·屏外停靠必绿。
  @override
  double get popupMaxWidth => 300;

  @override
  double get appUiScale => 1.0;

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

Widget _buildApp(AppModel appModel) {
  return ProviderScope(
    overrides: [appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('TODO-1379: 隐藏常驻热槽真在屏外（offset 断言）且不可命中', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = ParkedPopupTestAppModel();

    await tester.pumpWidget(_buildApp(appModel));
    // post-frame seed → setState → 下一帧才挂上隐藏热槽。
    await tester.pump();

    final Finder layerFinder = find.byType(DictionaryPopupLayer);
    expect(layerFinder, findsOneWidget,
        reason: '开页只 seed 一个常驻隐藏热槽（TODO-951 症状C）');
    final DictionaryPopupLayer layer = tester.widget(layerFinder);
    expect(layer.keepWebViewWarm, isTrue, reason: 'seed 的层必须是常驻热槽');

    final Size window = tester.view.physicalSize / tester.view.devicePixelRatio;

    // ① 几何：隐藏层左缘 ≥ 窗口宽 + 8 —— 真在屏外。旧实现停在卡片右缘
    //（~556px，屏内），Android 原生 WebView 在那截获触摸。
    final Offset topLeft = tester.getTopLeft(layerFinder);
    expect(topLeft.dx, greaterThanOrEqualTo(window.width + 8),
        reason: '隐藏热槽必须停到真·屏外（BUG-135 停靠几何），'
            '屏内停靠的原生 WebView 会截获活动弹窗的滚动/点击');

    // 屏外仍保持真实尺寸继续预热（不是 0 尺寸假预热）。
    final Size parkedSize = tester.getSize(layerFinder);
    expect(parkedSize.width, greaterThan(0));
    expect(parkedSize.height, greaterThan(0));

    // ② 停靠层在 Flutter 命中测试层也打不中。
    expect(layerFinder.hitTestable(), findsNothing, reason: '隐藏热槽不得参与命中测试');

    // 停靠语义经 Visibility(maintainState/Size) 收口（与另三宿主同机制），
    // WebView 在树里活着、保持预热。
    final Visibility visibility = tester.widget<Visibility>(
      find.ancestor(of: layerFinder, matching: find.byType(Visibility)).first,
    );
    expect(visibility.visible, isFalse);
    expect(visibility.maintainState, isTrue);
    expect(visibility.maintainSize, isTrue);
  });

  testWidgets('TODO-1379: warm 复用循环——搜索后同一热槽翻可见、回屏内、可命中', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = ParkedPopupTestAppModel();

    await tester.pumpWidget(_buildApp(appModel));
    await tester.pump();

    final Finder layerFinder = find.byType(DictionaryPopupLayer);
    expect(layerFinder, findsOneWidget);
    final GlobalKey warmKey =
        tester.widget<DictionaryPopupLayer>(layerFinder).webViewKey;

    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, 'refresh');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    // 复用热槽原地查词：仍只有一层、同一 webViewKey（WebView 未重建 → 不闪）。
    expect(layerFinder, findsOneWidget, reason: '顶层查词必须复用常驻热槽，不得新建层');
    expect(tester.widget<DictionaryPopupLayer>(layerFinder).webViewKey,
        same(warmKey),
        reason: '复用后必须还是同一个 WebView（TODO-951 症状C 不回归）');

    // 可见层回到屏内、可命中（触摸路径畅通）。
    final Size window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Offset topLeft = tester.getTopLeft(layerFinder);
    expect(topLeft.dx, greaterThanOrEqualTo(0));
    expect(topLeft.dx, lessThan(window.width), reason: '可见层必须回到屏内');
    expect(layerFinder.hitTestable(), findsOneWidget,
        reason: '可见层必须可命中（触摸路径畅通）');
  });
}
