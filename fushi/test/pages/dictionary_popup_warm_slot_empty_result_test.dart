import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2588：热槽（`keepWebViewWarm`）的 WebView 在**真实空结果**时也必须留在树上。
///
/// 此前 `_buildBody` 对「查过了、没词条」的结果落到 Flutter 占位、把带 GlobalKey 的
/// 热槽 WebView 整个 unmount——视频页 Shift 悬停换词换到一个没词条的字位时，平台线程
/// 就同步走 WebView2 `Close()` + `DestroyWindow`（上一词的 JS 还在飞、WGC 泵还在
/// Tick），用户报整机卡死；且热槽被拆后下一次查词退化为冷建。修后热槽三态（seed 空 /
/// 搜索中 / 真实空）一致挂 WebView，「未找到」以不透明盖板呈现；非热槽层行为不变。
DictionaryPopupLayer _layer({
  required bool keepWebViewWarm,
  required DictionarySearchResult result,
  bool isSearching = false,
}) {
  return DictionaryPopupLayer(
    result: result,
    isSearching: isSearching,
    keepWebViewWarm: keepWebViewWarm,
    webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
    onDismiss: () {},
    onTextSelected: (String _, Rect __) {},
    onLinkClick: (String _, Rect __) {},
    onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
    onDuplicateCheck: (String _, String __) async => false,
  );
}

/// [DictionaryPopupWebView.build] 读 appProvider 的几组弹窗注入 getter；本 fake 的
/// prefsRepo 未 wire，照 `dictionary_popup_push_dedup_test.dart` 的清单给常量。
class _WarmSlotAppModel extends AppModel {
  _WarmSlotAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  bool get lowMemoryMode => false;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
  @override
  bool get compactGlossaries => false;
  @override
  int get popupDictionaryColumns => 1;
  @override
  int get popupAutoExpandDictionaries => 0;
  @override
  bool get deduplicatePitchAccents => false;
  @override
  bool get harmonicFrequency => false;
  @override
  bool get showExpressionTags => false;
  @override
  bool get collapseDictionaries => false;
  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
  @override
  Map<String, String> get customDictCSS => const <String, String>{};
  @override
  String get globalDictCSS => '';
}

Widget _host(Widget layer) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => _WarmSlotAppModel()),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => child ?? const SizedBox.shrink(),
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, height: 360, child: layer)),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  final DictionarySearchResult realEmpty =
      DictionarySearchResult(searchTerm: '況に 一致しなくもないですね');

  testWidgets('热槽 + 真实空结果：WebView 仍挂载，「未找到」盖板可见', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(_layer(keepWebViewWarm: true, result: realEmpty)),
    );
    await tester.pump();

    expect(find.byType(DictionaryPopupWebView), findsOneWidget,
        reason: '热槽 WebView 不得因空结果被 unmount（那会同步拆 WebView2）');
    expect(find.byType(FushiPlaceholderMessage), findsOneWidget,
        reason: '空结果仍要告诉用户「未找到」，但以盖板而非拆树实现');
  });

  testWidgets('热槽：有结果 → 空结果 → 有结果，同一把 GlobalKey 的 WebView 全程不换 element', (
    WidgetTester tester,
  ) async {
    final GlobalKey<DictionaryPopupWebViewState> key =
        GlobalKey<DictionaryPopupWebViewState>();
    DictionaryPopupLayer layer(DictionarySearchResult result) {
      return DictionaryPopupLayer(
        result: result,
        keepWebViewWarm: true,
        webViewKey: key,
        onDismiss: () {},
        onTextSelected: (String _, Rect __) {},
        onLinkClick: (String _, Rect __) {},
        onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
        onDuplicateCheck: (String _, String __) async => false,
      );
    }

    await tester.pumpWidget(_host(layer(kPopupSearchingPlaceholderResult)));
    await tester.pump();
    final State<DictionaryPopupWebView>? seeded = key.currentState;
    expect(seeded, isNotNull);

    await tester.pumpWidget(_host(layer(realEmpty)));
    await tester.pump();
    expect(identical(key.currentState, seeded), isTrue,
        reason: '换到空结果时热槽 State 必须原样保留（不拆不建）');

    await tester.pumpWidget(_host(layer(kPopupSearchingPlaceholderResult)));
    await tester.pump();
    expect(identical(key.currentState, seeded), isTrue,
        reason: '关栈回 seed 后仍是同一个 State（热槽全程存活）');
  });

  testWidgets('非热槽 + 真实空结果：不挂 WebView，只渲染「未找到」占位（行为不变）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(_layer(keepWebViewWarm: false, result: realEmpty)),
    );
    await tester.pump();

    expect(find.byType(DictionaryPopupWebView), findsNothing);
    expect(find.byType(FushiPlaceholderMessage), findsOneWidget);
  });

  testWidgets('热槽 + 搜索中：仍是进度盖板，不出现「未找到」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(_layer(
        keepWebViewWarm: true,
        result: kPopupSearchingPlaceholderResult,
        isSearching: true,
      )),
    );
    await tester.pump();

    expect(find.byType(DictionaryPopupWebView), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(FushiPlaceholderMessage), findsNothing);
  });
}
