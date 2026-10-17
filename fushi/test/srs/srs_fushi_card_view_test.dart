// Fushi 卡片混合渲染：原生区块 + 释义 WebView（测试里由 srsCardFaceBuilderProvider 换成占位）。
// 钉住：正面不建 WebView、区块顺序跟单一真相源 FushiCardBlock 走、宽窄两种版式、外观开关、
// 内容高度撑开释义区、点击卡 Enter 翻、MD3 / Apple 两套设计系统都不抛。
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiCard;
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _App extends AppModel {
  _App() : super(testPlatformServices());

  SrsCardAppearance value = const SrsCardAppearance();

  @override
  SrsCardAppearance get srsCardAppearance => value;
}

/// 每个区块在原生卡面里的 key（释义区是 WebView 占位）。
const Map<FushiCardBlock, String> _blockKeys = <FushiCardBlock, String>{
  FushiCardBlock.term: 'srs-fushi-term',
  FushiCardBlock.reading: 'srs-fushi-reading-row',
  FushiCardBlock.picture: 'srs-fushi-picture',
  FushiCardBlock.sentence: 'srs-fushi-sentence-block',
  FushiCardBlock.definitions: 'srs-fushi-definitions',
  FushiCardBlock.frequency: 'srs-fushi-frequency',
  FushiCardBlock.source: 'srs-fushi-source',
};

Map<String, String> _fields([Map<String, String> extra = const {}]) =>
    <String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      ...srsSampleCardFields(),
      ...extra,
    };

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<List<SrsCardFace>> pump(
    WidgetTester tester, {
    required bool answer,
    Size size = const Size(390, 844),
    Map<String, String>? fields,
    SrsCardAppearance appearance = const SrsCardAppearance(),
    bool apple = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _App app = _App()..value = appearance;
    final List<SrsCardFace> faces = <SrsCardFace>[];
    Widget host(bool showingAnswer) => ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          faces.add(face);
          return SizedBox(
            key: const ValueKey<String>('defs-webview'),
            child: Text('defs:${face.layout.name}'),
          );
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(
            body: SrsFushiCardView(
              face: SrsCardFace(
                cardId: 'c1',
                showingAnswer: showingAnswer,
                bodyHtml: '',
                css: FushiCardNoteType.template.css,
                languageCode: 'ja',
                onBridgeKey: (_) {},
              ),
              fields: fields ?? _fields(),
              definitionsHtml: '<div class="fc-defs-only">defs</div>',
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(answer));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
    return faces;
  }

  testWidgets('正面原生显示；释义 WebView 在 Offstage 预建（翻面不现起 WebView）', (
    WidgetTester tester,
  ) async {
    final List<SrsCardFace> faces = await pump(tester, answer: false);
    // 预建的是背面释义（showingAnswer=true），但挂在 Offstage 下、正面看不见。
    expect(faces, isNotEmpty);
    expect(faces.last.showingAnswer, isTrue);
    expect(find.byKey(const ValueKey<String>('defs-webview')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('defs-webview'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('srs-fushi-front')), findsOne);
    expect(
      find.byKey(const ValueKey<String>('srs-fushi-front-term')),
      findsOne,
    );
  });

  testWidgets('Windows：日文内容走日文字体链（不交给引擎回落到微软雅黑）', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pump(tester, answer: true);
      for (final String key in <String>[
        'srs-fushi-term',
        'srs-fushi-sentence',
      ]) {
        final TextStyle style = tester
            .widget<SrsRubyText>(find.byKey(ValueKey<String>(key)))
            .style;
        expect(style.fontFamily, 'Yu Gothic UI', reason: key);
        final List<String> fallback = style.fontFamilyFallback!;
        // 日文链完整排在任何中文字体之前：混进来的中文才落到受控的中文 face。
        expect(
          fallback.indexOf('Meiryo'),
          lessThan(fallback.indexOf('Microsoft YaHei UI')),
          reason: key,
        );
        expect(style.locale, const Locale('ja'), reason: key);
        // 系统游ゴシック Regular 在自绘下过细：正文提到 Medium 与 WebView 视觉对齐。
        if (key == 'srs-fushi-sentence') {
          expect(style.fontWeight, FontWeight.w500, reason: key);
        }
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';
    testWidgets('[$ds] 窄屏背面：区块自上而下的顺序 = FushiCardBlock 顺序', (
      WidgetTester tester,
    ) async {
      final List<SrsCardFace> faces = await pump(
        tester,
        answer: true,
        apple: apple,
      );
      expect(faces.last.layout, SrsCardLayout.narrow);
      expect(faces.last.onContentHeight, isNotNull);
      expect(faces.last.fushiCard, isTrue);
      expect(faces.last.bodyHtml, contains('fc-defs-only'));
      // 释义 WebView 跟内容等高：收起高度按外层视口（844 × 0.52）给像素值。
      expect(faces.last.hostCss, contains('--fushi-srs-clamp:439px;'));
      double previous = -1;
      for (final FushiCardBlock b in kFushiCardBackBlocks) {
        if (!srsFushiBlockVisible(b, _fields(), const SrsCardAppearance())) {
          continue;
        }
        final Finder f = find.byKey(ValueKey<String>(_blockKeys[b]!));
        expect(f, findsOneWidget, reason: b.name);
        final double y = tester.getTopLeft(f).dy;
        if (b == FushiCardBlock.picture) {
          // 窄屏图片是标题行右上角的缩略图：与词条同一行，排在词条右侧。
          final Finder term = find.byKey(
            const ValueKey<String>('srs-fushi-term'),
          );
          expect(y, closeTo(tester.getTopLeft(term).dy, 24));
          expect(
            tester.getTopLeft(f).dx,
            greaterThan(tester.getTopRight(term).dx),
          );
          continue;
        }
        expect(y, greaterThanOrEqualTo(previous), reason: b.name);
        previous = y;
      }
    });

    testWidgets('[$ds] 卡面原生样式取自当前设计系统的卡面令牌', (WidgetTester tester) async {
      await pump(tester, answer: true, apple: apple);
      final Finder block = find.byKey(
        const ValueKey<String>('srs-fushi-sentence-block'),
      );
      final BuildContext ctx = tester.element(block);
      final SrsCardTokens tokens = SrsCardTokens.of(ctx);
      expect(tokens.apple, apple);
      // 例句卡底 = 设计系统表面一档（MD3 surfaceContainer / Apple 分组背景）。
      expect(
        tester.widget<FushiCard>(block).color,
        tokens.surface1(Theme.of(ctx).colorScheme),
      );
      // 例句字号 = 字阶角色（倍率 1）；词条不小于 display-small 角色。
      expect(
        tester
            .widget<SrsRubyText>(
              find.byKey(const ValueKey<String>('srs-fushi-sentence')),
            )
            .style
            .fontSize,
        tokens.emphasisLine.fontSize,
      );
      expect(
        tester
            .widget<SrsRubyText>(
              find.byKey(const ValueKey<String>('srs-fushi-term')),
            )
            .style
            .fontSize,
        greaterThanOrEqualTo(tokens.termMin.fontSize!),
      );
      // 内层块圆角 / 间距同一份令牌。
      expect(tokens.radiusSmall, apple ? 10 : FushiM3eShape.small);
    });

    testWidgets('[$ds] 宽屏背面：左栏原生、右栏释义（宽版式）', (WidgetTester tester) async {
      final List<SrsCardFace> faces = await pump(
        tester,
        answer: true,
        size: const Size(1280, 800),
        apple: apple,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-back-wide')),
        findsOne,
      );
      expect(faces.last.layout, SrsCardLayout.wide);
      expect(faces.last.onContentHeight, isNull);
      final double termX = tester
          .getTopLeft(find.byKey(const ValueKey<String>('srs-fushi-term')))
          .dx;
      final double defsX = tester
          .getTopLeft(find.byKey(const ValueKey<String>('defs-webview')))
          .dx;
      expect(defsX, greaterThan(termX + 200));
    });
  }

  testWidgets('页面上报的内容高度撑开释义区', (WidgetTester tester) async {
    final List<SrsCardFace> faces = await pump(tester, answer: true);
    faces.last.onContentHeight!(1234);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('srs-fushi-definitions')))
          .height,
      1234,
    );
    // 超过上限：改为一屏高、WebView 内部滚动。
    faces.last.onContentHeight!(kSrsDefsMaxInlineHeight + 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('srs-fushi-definitions')))
          .height,
      844,
    );
  });

  testWidgets('外观开关原生生效：隐藏图片 / 词频 / 来源 / 翻译', (WidgetTester tester) async {
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{'SentenceTranslation': 'It is fine.'}),
      appearance: const SrsCardAppearance(
        showPicture: false,
        showFrequency: false,
        showSource: false,
        showTranslation: false,
      ),
    );
    for (final String k in <String>[
      'srs-fushi-picture',
      'srs-fushi-frequency',
      'srs-fushi-source',
      'srs-fushi-translation',
    ]) {
      expect(find.byKey(ValueKey<String>(k)), findsNothing, reason: k);
    }
    expect(find.byKey(const ValueKey<String>('srs-fushi-term')), findsOne);
  });

  testWidgets('点击卡：Enter（焦点确认）在词条与例句之间切换', (WidgetTester tester) async {
    await pump(
      tester,
      answer: false,
      fields: _fields(<String, String>{
        'IsWordAndSentenceCard': '',
        'IsClickCard': 'x',
      }),
    );
    final Finder click = find.byKey(
      const ValueKey<String>('srs-fushi-front-click'),
    );
    expect(click, findsOne);
    final AnimatedCrossFade fade = tester.widget(
      find.descendant(of: click, matching: find.byType(AnimatedCrossFade)),
    );
    expect(fade.crossFadeState, CrossFadeState.showFirst);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 400));
    final AnimatedCrossFade after = tester.widget(
      find.descendant(of: click, matching: find.byType(AnimatedCrossFade)),
    );
    expect(after.crossFadeState, CrossFadeState.showSecond);
  });

  test('图片来源：光栅 data URI → 内存；SVG / 远程 / 无媒体库 → 不画', () {
    final String sample = srsImageSources(
      srsSampleCardFields()['Picture']!,
    ).single;
    expect(srsCardImageProvider(sample, null), isA<MemoryImage>());
    expect(
      srsCardImageProvider('data:image/svg+xml;utf8,%3Csvg%3E', null),
      isNull,
    );
    expect(srsCardImageProvider('https://example.com/a.png', null), isNull);
    expect(srsCardImageProvider('fushi_frame_1.webp', null), isNull);
  });
}
