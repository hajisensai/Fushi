import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart'
    show FushiDividerControl;
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-3225 同一 PR 的顶部区域 M3E 化（app 外查词窗 popup_dictionary_page）：
/// - MD3：关闭钮并进搜索栏同一枚 tonal 胶囊（仍在横滑包装之外、点它直接关）、
///   顶栏与源文本条之间不画硬分隔线、源文本条命中高亮走 primaryContainer；
///   移动端整卡是投影托起的浮动表面、不画发丝描边，桌面仍画描边（窗边裁投影）。
/// - Apple 设计系统：维持原布局（独立 × + 搜索胶囊 + 分隔线）。
class _TopBarAppModel extends AppModel {
  _TopBarAppModel() : super(testPlatformServices());

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

ThemeData _theme({
  bool glass = false,
  TargetPlatform platform = TargetPlatform.android,
}) {
  return buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8B6F2F)),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  ).copyWith(platform: platform);
}

Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  VoidCallback? onClose,
}) async {
  final _TopBarAppModel appModel = _TopBarAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: theme,
          navigatorKey: appModel.navigatorKey,
          home: PopupDictionaryPage(
            searchTerm: 'こもってますね',
            closeInApp: onClose ?? () {},
            autoSearchOnOpen: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const ValueKey<String> _toolbarKey = ValueKey<String>(
  'popup_dictionary_search_toolbar',
);
const ValueKey<String> _closeKey = ValueKey<String>(
  'popup_dictionary_close_button',
);

/// 页面整卡（standaloneWindow 的那块 FushiPopupSurface）。
FushiPopupSurface _outerCard(WidgetTester tester) => tester
    .widgetList<FushiPopupSurface>(find.byType(FushiPopupSurface))
    .firstWhere((FushiPopupSurface s) => s.standaloneWindow);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('MD3: close sits inside the search pill and still closes', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    await _pump(tester, theme: _theme(), onClose: () => closed = true);

    expect(find.byKey(_toolbarKey), findsOneWidget);
    final Finder close = find.byKey(_closeKey);
    expect(
      find.descendant(of: find.byKey(_toolbarKey), matching: close),
      findsOneWidget,
      reason: '× 必须与搜索框同处一枚胶囊',
    );
    expect(
      find.ancestor(of: close, matching: find.byType(FushiPressScale)),
      findsOneWidget,
      reason: '关闭钮带按压弹簧',
    );
    // 搜索输入 / 搜索按钮都还在同一胶囊里（输入、粘贴、搜索不退化）。
    expect(
      find.descendant(
        of: find.byKey(_toolbarKey),
        matching: find.byKey(
          const ValueKey<String>('popup_dictionary_search_field'),
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(close);
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('MD3: no hard divider, tonal source highlight, floating card', (
    WidgetTester tester,
  ) async {
    await _pump(tester, theme: _theme());

    expect(
      find.descendant(
        of: find.byType(PopupDictionaryPage),
        matching: find.byType(FushiDividerControl),
      ),
      findsNothing,
      reason: '顶栏与正文之间用间距与层级区分，不画硬分隔线',
    );
    final SourceLookupTextPanel panel = tester.widget(
      find.byType(SourceLookupTextPanel),
    );
    expect(panel.tonalHighlight, isTrue);

    final FushiPopupSurface card = _outerCard(tester);
    expect(card.showBorder, isFalse, reason: '移动端 M3E 浮动表面靠投影托起');
    expect(card.elevation, greaterThan(0));
  });

  testWidgets('MD3 desktop keeps the outline (shadow is clipped at window)', (
    WidgetTester tester,
  ) async {
    await _pump(tester, theme: _theme(platform: TargetPlatform.windows));
    expect(_outerCard(tester).showBorder, isTrue);
    // 顶部区域的 M3E 形态与平台无关。
    expect(find.byKey(_toolbarKey), findsOneWidget);
  });

  testWidgets('Apple design keeps its own header layout', (
    WidgetTester tester,
  ) async {
    await _pump(tester, theme: _theme(glass: true));

    expect(find.byKey(_toolbarKey), findsNothing);
    expect(find.byKey(_closeKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PopupDictionaryPage),
        matching: find.byType(FushiDividerControl),
      ),
      findsOneWidget,
    );
    final SourceLookupTextPanel panel = tester.widget(
      find.byType(SourceLookupTextPanel),
    );
    expect(panel.tonalHighlight, isFalse);
    expect(_outerCard(tester).showBorder, isTrue);
  });

  testWidgets('tonal source highlight paints primaryContainer under '
      'onPrimaryContainer glyphs', (WidgetTester tester) async {
    final ThemeData theme = _theme();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SourceLookupTextPanel(
            text: 'こもる',
            onLookup: (_, __, ___) {},
            tonalHighlight: true,
            highlight: const SourceLookupHighlight(start: 0, length: 2),
          ),
        ),
      ),
    );
    final DecoratedBox box = tester.widget<DecoratedBox>(
      find.ancestor(of: find.text('こ'), matching: find.byType(DecoratedBox)),
    );
    expect(
      (box.decoration as BoxDecoration).color,
      theme.colorScheme.primaryContainer,
    );
    expect(
      tester.widget<Text>(find.text('こ')).style?.color,
      theme.colorScheme.onPrimaryContainer,
    );
    expect(
      tester.widget<Text>(find.text('る')).style?.color,
      theme.colorScheme.onSurface,
      reason: '命中段外的字保持正文色',
    );
  });
}
