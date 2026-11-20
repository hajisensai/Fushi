import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/cjk_font_families.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_library_widgets.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_specimen.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_target_preview.dart';
import 'package:fushi/src/reader/reader_settings.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget child) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  group('effectiveFontTargetFamilies', () {
    const List<FontPreviewCandidate> chain = <FontPreviewCandidate>[
      FontPreviewCandidate(family: null, path: '/fonts/broken.ttf'),
      FontPreviewCandidate(family: 'Web Font', path: '/fonts/a.woff2'),
      FontPreviewCandidate(family: 'Klee One', path: '/fonts/klee.ttf'),
      FontPreviewCandidate(family: 'Yu Mincho', path: null),
    ];

    test('界面 / 正文 / 词典用整条链，跳过解析失败的条目', () {
      for (final FontTarget target in <FontTarget>[
        FontTarget.appUi,
        FontTarget.body,
        FontTarget.dictionary,
      ]) {
        expect(effectiveFontTargetFamilies(target, chain), <String>[
          'Web Font',
          'Klee One',
          'Yu Mincho',
        ]);
      }
    });

    test('视频字幕只用第一款可用字体（与 resolveAndLoad 同语义）', () {
      expect(
        effectiveFontTargetFamilies(FontTarget.videoSubtitle, chain),
        <String>['Web Font'],
      );
    });

    test('游戏浮窗跳过 WOFF/WOFF2（native 分层窗吃不下），只取第一款', () {
      expect(
        effectiveFontTargetFamilies(FontTarget.gameLookup, chain),
        <String>['Klee One'],
      );
    });

    test('有声书悬浮字幕与游戏浮窗同一 native 窗：跳过 WOFF/WOFF2，只取第一款', () {
      expect(
        effectiveFontTargetFamilies(FontTarget.floatingLyric, chain),
        <String>['Klee One'],
      );
    });
  });

  for (final FontTarget target in FontTarget.values) {
    testWidgets('${target.name} 样张用该用途生效的字体渲染', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        buildApp(
          const FontTargetPreview(
            target: FontTarget.body,
            families: <String>['Preview Family'],
          ),
        ),
      );
      await tester.pumpWidget(
        buildApp(
          FontTargetPreview(
            target: target,
            families: const <String>['Preview Family'],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(ValueKey<String>('font-target-preview-${target.name}')),
        findsOneWidget,
      );
      final Iterable<Text> texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(
            ValueKey<String>('font-target-preview-${target.name}'),
          ),
          matching: find.byType(Text),
        ),
      );
      expect(
        texts.any((Text text) => text.style?.fontFamily == 'Preview Family'),
        isTrue,
        reason: '样张必须真的用该字体渲染，否则预览等于没有',
      );
    });
  }

  testWidgets('未配字体时说明走系统默认', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        const FontTargetPreview(
          target: FontTarget.dictionary,
          families: <String>[],
        ),
      ),
    );
    expect(find.text(t.font_preview_default_font), findsOneWidget);
  });

  testWidgets('正文样张可切到竖排', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      buildApp(
        const FontTargetPreview(
          target: FontTarget.body,
          families: <String>['Preview Family'],
        ),
      ),
    );
    await tester.tap(find.text(t.font_preview_vertical));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 竖排按字一格：能找到单独成格的「吾」。
    expect(find.text('吾'), findsOneWidget);
  });

  group('样文文种', () {
    final RegExp kana = RegExp(r'[぀-ヿ]');

    String previewText(WidgetTester tester, FontTarget target) => tester
        .widgetList<RichText>(
          find.descendant(
            of: find.byKey(
              ValueKey<String>('font-target-preview-${target.name}'),
            ),
            matching: find.byType(RichText),
          ),
        )
        .map((RichText text) => text.text.toPlainText())
        .join('\n');

    test('中文样张简繁分开：繁体版不含简体字形，反之亦然', () {
      final String hans = fontSampleSentence(
        FontSampleScript.simplifiedChinese,
      );
      final String hant = fontSampleSentence(
        FontSampleScript.traditionalChinese,
      );
      expect(hans, contains('张'));
      expect(hans, isNot(contains('張')));
      expect(hant, contains('張'));
      expect(hant, contains('黃'));
      expect(hant, isNot(contains('张')));
      expect(hant, isNot(contains('黄')));
    });

    for (final FontSampleScript script in <FontSampleScript>[
      FontSampleScript.simplifiedChinese,
      FontSampleScript.traditionalChinese,
      FontSampleScript.latin,
    ]) {
      for (final FontTarget target in FontTarget.values) {
        testWidgets('${script.name} 下 ${target.name} 预览不出现日文假名', (
          WidgetTester tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(420, 900);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            buildApp(
              FontTargetPreview(
                target: target,
                families: const <String>['Preview Family'],
                script: script,
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          final String text = previewText(tester, target);
          expect(text, isNotEmpty);
          expect(
            kana.hasMatch(text),
            isFalse,
            reason: '中文 / 西文字体的预览里出现假名，缺字会显示成空白或别的字体',
          );
        });
      }
    }

    testWidgets('繁体正文样张用繁体字，缺字先回退到繁体中文系统字体', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        buildApp(
          const FontTargetPreview(
            target: FontTarget.body,
            families: <String>['Preview Family'],
            script: FontSampleScript.traditionalChinese,
          ),
        ),
      );
      final String bodyText = fontTargetSampleTexts(
        FontSampleScript.traditionalChinese,
      ).bodyText;
      expect(previewText(tester, FontTarget.body), contains(bodyText));
      final RichText rich = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('font-target-preview-body')),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is RichText && w.text.toPlainText().contains(bodyText),
          ),
        ),
      );
      TextStyle? style;
      rich.text.visitChildren((InlineSpan span) {
        if (span is TextSpan && span.text == bodyText) {
          style = span.style;
          return false;
        }
        return true;
      });
      final String expectedFirstFallback = cjkFontsFor(
        defaultTargetPlatform,
        CjkFontStyle.serif,
      )[CjkScript.traditionalChinese]!.first;
      expect(style?.fontFamily, 'Preview Family');
      expect(style?.fontFamilyFallback?.first, expectedFirstFallback);
    });
  });

  FontLibraryEntryView entry({
    required String name,
    required bool isFile,
    String? family,
    bool missingOnSystem = false,
  }) => FontLibraryEntryView(
    identity: name,
    name: name,
    isFile: isFile,
    path: isFile ? '/fonts/$name.ttf' : null,
    family: family,
    state: FontSpecimenState.ready,
    targets: const <FontTarget>{FontTarget.body},
    missingOnSystem: missingOnSystem,
  );

  testWidgets('字体库样张卡用该字体渲染样例文字', (WidgetTester tester) async {
    const String sample = '吾輩は猫である。名前はまだ無い。';
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: FontSpecimenCard(
              entry: entry(name: 'Klee One', isFile: true, family: 'Klee One'),
              sampleText: sample,
              layout: FontLibraryLayout.list,
              onOpen: () {},
              onContextMenu: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text(sample)).style?.fontFamily,
      'Klee One',
    );
    expect(find.text(t.font_target_body_short), findsOneWidget);
  });

  testWidgets('详情页标出顺位，系统里找不到的系统字体条目给出提示', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: FontLibraryDetailPanel(
              entry: entry(
                name: 'msgothic',
                isFile: false,
                missingOnSystem: true,
              ),
              script: FontSampleScript.japanese,
              customSample: '',
              chainPosition: 2,
              onToggleTarget: (_) {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining(t.custom_fonts_system_not_found),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.font_preview_chain_position(index: 2)),
      findsOneWidget,
    );
  });

  Widget toolbarApp({
    required FontSampleScript script,
    required ValueChanged<FontSampleScript> onChanged,
    required TextEditingController controller,
    FontSampleScript chineseVariant = FontSampleScript.simplifiedChinese,
  }) => buildApp(
    FontSampleToolbar(
      script: script,
      chineseVariant: chineseVariant,
      onScriptChanged: onChanged,
      controller: controller,
      onCustomChanged: () {},
    ),
  );

  testWidgets('简繁开关只在中文档出现，紧贴文种三档；点「繁」切到繁体', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 600);
    addTearDown(tester.view.reset);
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    FontSampleScript? picked;

    await tester.pumpWidget(
      toolbarApp(
        script: FontSampleScript.japanese,
        onChanged: (FontSampleScript s) => picked = s,
        controller: controller,
      ),
    );
    expect(find.text('简'), findsNothing);
    expect(find.text('繁'), findsNothing);

    await tester.pumpWidget(
      toolbarApp(
        script: FontSampleScript.simplifiedChinese,
        onChanged: (FontSampleScript s) => picked = s,
        controller: controller,
      ),
    );
    expect(tester.takeException(), isNull);
    final Rect scripts = tester.getRect(
      find.byKey(const ValueKey<String>('font-sample-script')),
    );
    final Rect variant = tester.getRect(
      find.byKey(const ValueKey<String>('font-chinese-variant')),
    );
    expect(variant.left, greaterThan(scripts.right), reason: '开关在文种三档右侧');
    expect(
      (variant.center.dy - scripts.center.dy).abs(),
      lessThan(2),
      reason: '同一行',
    );
    await tester.tap(find.text('繁'));
    expect(picked, FontSampleScript.traditionalChinese);
  });

  testWidgets('从日文切回中文恢复上次的简繁', (WidgetTester tester) async {
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    FontSampleScript? picked;
    await tester.pumpWidget(
      toolbarApp(
        script: FontSampleScript.japanese,
        chineseVariant: FontSampleScript.traditionalChinese,
        onChanged: (FontSampleScript s) => picked = s,
        controller: controller,
      ),
    );
    await tester.tap(find.text(t.font_library_filter_chinese));
    expect(picked, FontSampleScript.traditionalChinese);
  });

  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    testWidgets('中文档 + 简繁开关在 360 宽手机上不溢出（${locale.languageTag}）', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(locale);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.reset);
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        toolbarApp(
          script: FontSampleScript.traditionalChinese,
          onChanged: (_) {},
          controller: controller,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('繁'), findsOneWidget);
    });
  }
}
