import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
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

  testWidgets('详情页标出顺位，系统里找不到的系统字体条目给出提示', (
    WidgetTester tester,
  ) async {
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
}
