import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_specimen.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_browser_page.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import '../../helpers/glass_unwrap.dart';

void main() {
  const List<SystemFontFamily> fonts = <SystemFontFamily>[
    SystemFontFamily(family: 'Arial', supportsJapanese: false),
    SystemFontFamily(family: 'MS Gothic', supportsJapanese: true),
    SystemFontFamily(family: 'Meiryo', supportsJapanese: true),
    SystemFontFamily(family: 'Yu Mincho', supportsJapanese: true),
  ];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SystemFontCatalog.debugLoaderOverride = () async =>
        const SystemFontList(families: fonts, namesReliable: true);
  });
  tearDown(SystemFontCatalog.debugReset);

  test('日文筛选不排除「判不出」的字体', () {
    const List<SystemFontFamily> mixed = <SystemFontFamily>[
      SystemFontFamily(family: 'Arial', supportsJapanese: false),
      SystemFontFamily(family: 'sans-serif'),
      SystemFontFamily(family: 'Meiryo', supportsJapanese: true),
    ];
    expect(
      filterSystemFontFamilies(
        mixed,
        query: '',
        japaneseOnly: true,
      ).map((SystemFontFamily f) => f.family),
      <String>['sans-serif', 'Meiryo'],
    );
    expect(
      filterSystemFontFamilies(
        mixed,
        query: 'mei',
        japaneseOnly: false,
      ).map((SystemFontFamily f) => f.family),
      <String>['Meiryo'],
    );
  });

  Future<void> openBrowser(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1300);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              key: const ValueKey<String>('open'),
              onPressed: () => Navigator.push<List<String>>(
                context,
                MaterialPageRoute<List<String>>(
                  builder: (_) => const SystemFontBrowserPage(
                    alreadyAdded: <String>{},
                    target: FontTarget.body,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
  }

  testWidgets('每行用该字体本身渲染名字与样字，默认只列含日文字形的字体', (WidgetTester tester) async {
    await openBrowser(tester);
    expect(find.text('Arial'), findsNothing, reason: '默认勾着「仅日文」');
    final Text name = tester.widget<Text>(find.text('Meiryo'));
    expect(name.style?.fontFamily, 'Meiryo');
    final Iterable<FontSpecimenLine> lines = tester.widgetList(
      find.byType(FontSpecimenLine),
    );
    expect(
      lines.map((FontSpecimenLine l) => l.family),
      containsAll(<String>['MS Gothic', 'Meiryo', 'Yu Mincho']),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('system-font-japanese-only')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Arial'), findsOneWidget);
  });

  testWidgets('点选即在底部样张试用，多选后一次返回', (WidgetTester tester) async {
    List<String>? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              key: const ValueKey<String>('open'),
              onPressed: () async {
                result = await Navigator.push<List<String>>(
                  context,
                  MaterialPageRoute<List<String>>(
                    builder: (_) => const SystemFontBrowserPage(
                      alreadyAdded: <String>{'meiryo'},
                      target: FontTarget.body,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1300);
    addTearDown(tester.view.reset);
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    // 已在字体库的不可再选（大小写不敏感）。
    await tester.tap(find.text('Meiryo'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(glassUnwrap<FilledButton>(find.byKey(const ValueKey<String>('system-font-add'))),)
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Yu Mincho'));
    await tester.pumpAndSettle();
    // 底部样张换成刚点的字体。
    expect(
      find.textContaining('${t.font_preview_title} · Yu Mincho'),
      findsOneWidget,
    );
    await tester.tap(find.text('MS Gothic'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('system-font-add')));
    await tester.pumpAndSettle();
    expect(result, <String>['Yu Mincho', 'MS Gothic']);
  });

  testWidgets('名字靠文件名推断时提示可能不准', (WidgetTester tester) async {
    SystemFontCatalog.debugLoaderOverride = () async => const SystemFontList(
      families: <SystemFontFamily>[SystemFontFamily(family: 'msgothic')],
      namesReliable: false,
    );
    await openBrowser(tester);
    expect(find.text(t.custom_fonts_system_names_approximate), findsOneWidget);
    // 判不出日文支持时不显示「仅日文」筛选，也不藏任何字体。
    expect(
      find.byKey(const ValueKey<String>('system-font-japanese-only')),
      findsNothing,
    );
    expect(find.text('msgothic'), findsOneWidget);
  });
}
