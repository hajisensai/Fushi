// Fushi 卡片混合渲染：原生区块 + 释义 WebView（测试里由 srsCardFaceBuilderProvider 换成占位）。
// 钉住：正面不建 WebView、区块顺序跟单一真相源 FushiCardBlock 走、宽窄两种版式、外观开关、
// 内容高度撑开释义区、点击卡 Enter 翻、MD3 / Apple 两套设计系统都不抛。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/pages/implementations/srs/srs_defs_scroll_window.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_card_video_channel.dart'
    show SrsCardSentenceCompanion;
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

/// 10×30 的竖长灰图（宽高比 1:3，铺满会过高）。
const String _tallPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAeCAIAAACaFxhnAAAAFUlEQVR4nGNowAsYRqVHpUelB1IaAJWBwhBdiRX8AAAAAElFTkSuQmCC';

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
    double topInset = 0,
    SrsMediaStore? store,
    List<FushiCardBlock> blocks = FushiCardBlock.values,
    List<FushiCardItem>? back,
    List<FushiCardItem>? front,
    bool defsScroll = false,
    bool thenFront = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _App app = _App()..value = appearance;
    final List<SrsCardFace> faces = <SrsCardFace>[];
    Widget host(bool showingAnswer) => ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsMediaStoreProvider.overrideWith((Ref ref) async => store),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          faces.add(face);
          final Widget text = Text('defs:${face.layout.name}');
          return SizedBox(
            key: const ValueKey<String>('defs-webview'),
            // 真实释义 WebView 自带语义节点；这里用可滚动（滚动语义节点）模拟。
            child: defsScroll ? SingleChildScrollView(child: text) : text,
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
              back:
                  back ??
                  <FushiCardItem>[
                    for (final FushiCardBlock b in blocks)
                      FushiCardBlockItem(b),
                  ],
              front: front,
              topInset: topInset,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(answer));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
    if (thenFront) {
      await tester.pumpWidget(host(false));
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
    }
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

  testWidgets('背面 → 正面：释义子树挪回预热位，语义树不炸、读屏读不到预热中的释义', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pump(tester, answer: true, defsScroll: true, thenFront: true);
    expect(find.byKey(const ValueKey<String>('srs-fushi-front')), findsOne);
    // 释义子树保活（同一个元素挪过来），但不在屏上、也不在语义树里。
    expect(
      find.byKey(const ValueKey<String>('defs-webview'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('defs-webview')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^defs:')), findsNothing);
    semantics.dispose();
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
        // 窄屏图片 / 视频不再是标题右侧的缩略图：单独一块通栏，排在词条区下面。
        expect(y, greaterThanOrEqualTo(previous), reason: b.name);
        previous = y;
      }
    });

    for (final Size size in <Size>[
      const Size(390, 844),
      const Size(1200, 800),
    ]) {
      final String layout = size.width < 700 ? '窄屏' : '宽屏';
      testWidgets('[$ds] $layout 背面按区块布局排：调序、删区块、词条与读音拆开', (
        WidgetTester tester,
      ) async {
        const List<FushiCardBlock> blocks = <FushiCardBlock>[
          FushiCardBlock.sentence,
          FushiCardBlock.reading,
          FushiCardBlock.definitions,
          FushiCardBlock.term,
          FushiCardBlock.picture,
          FushiCardBlock.frequency,
        ];
        final Map<String, String> fields = _fields(<String, String>{
          'Source': 'Book',
        });
        await pump(
          tester,
          answer: true,
          apple: apple,
          size: size,
          fields: fields,
          blocks: blocks,
        );
        // 删掉的来源区块不画（字段有内容也不画）。
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-source')),
          findsNothing,
        );
        // 词条与读音不相邻：各自成块，发音键跟读音走。
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-header')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-header-term')),
          findsOne,
        );
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-header-reading')),
          findsOne,
        );
        final bool wide = size.width >= 700;
        double previous = -1;
        for (final FushiCardBlock b in blocks) {
          if (!srsFushiBlockVisible(b, fields, const SrsCardAppearance())) {
            continue;
          }
          // 宽屏释义独占右栏，左栏按其余区块的顺序。
          if (wide && b == FushiCardBlock.definitions) continue;
          final Finder f = find.byKey(ValueKey<String>(_blockKeys[b]!));
          expect(f, findsOneWidget, reason: b.name);
          final double y = tester.getTopLeft(f).dy;
          expect(y, greaterThan(previous), reason: b.name);
          previous = y;
        }
      });
    }

    for (final Size size in <Size>[
      const Size(390, 844),
      const Size(1200, 800),
    ]) {
      final String layout = size.width < 700 ? '窄屏' : '宽屏';
      testWidgets('[$ds] $layout 区块选项与自定义区块：按选项画、字段 / HTML 区块原生画在布局位置', (
        WidgetTester tester,
      ) async {
        final Map<String, String> fields = _fields(<String, String>{
          'TermAudio': '[sound:w.mp3]',
          'SentenceAudio': '[sound:s.mp3]',
          'Frequency': '<ul><li>JPDB: 1840</li></ul>',
          'MiscInfo': '<b>备注内容</b>',
        });
        await pump(
          tester,
          answer: true,
          apple: apple,
          size: size,
          fields: fields,
          appearance: const SrsCardAppearance(aggregateFrequency: false),
          back: <FushiCardItem>[
            FushiCardBlockItem(FushiCardBlock.term),
            FushiCardBlockItem(
              FushiCardBlock.reading,
              options: <String, String>{kFushiOptAudio: '0'},
            ),
            FushiCardFieldItem(
              field: 'MiscInfo',
              style: FushiCardFieldStyle.quote,
              title: '我的备注',
            ),
            FushiCardBlockItem(
              FushiCardBlock.sentence,
              options: <String, String>{
                kFushiOptTranslation: '0',
                kFushiOptAudio: '0',
              },
            ),
            FushiCardBlockItem(FushiCardBlock.definitions),
            const FushiCardHtmlItem('<p>自定义 <i>HTML</i> 区块</p>'),
            FushiCardBlockItem(
              FushiCardBlock.frequency,
              options: <String, String>{kFushiOptLabel: '频度'},
            ),
          ],
        );
        // 读音区块关了发音键、例句区块关了翻译与发音键。
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-word-audio')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-sentence-audio')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('srs-fushi-translation')),
          findsNothing,
        );
        // 词频标签改过文字。
        expect(find.text('频度'), findsOneWidget);
        // 字段区块：标题 + 原生画的字段内容；HTML 区块原生画。
        final Finder field = find.byKey(
          const ValueKey<String>('srs-fushi-back-item-2'),
        );
        final Finder html = find.byKey(
          const ValueKey<String>('srs-fushi-back-item-5'),
        );
        expect(field, findsOneWidget);
        expect(html, findsOneWidget);
        expect(
          find.descendant(of: field, matching: find.text('我的备注')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: field,
            matching: find.textContaining('备注内容', findRichText: true),
          ),
          findsWidgets,
        );
        expect(
          find.descendant(
            of: html,
            matching: find.textContaining('自定义', findRichText: true),
          ),
          findsWidgets,
        );
        // 布局顺序：字段区块在读音之后、例句之前；HTML 区块在释义之后（窄屏）/ 左栏例句之后。
        final double reading = tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('srs-fushi-reading-row')),
            )
            .dy;
        final double fieldY = tester.getTopLeft(field).dy;
        final double sentence = tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
            )
            .dy;
        final double htmlY = tester.getTopLeft(html).dy;
        final double freq = tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('srs-fushi-frequency')),
            )
            .dy;
        expect(fieldY, greaterThan(reading));
        expect(sentence, greaterThan(fieldY));
        expect(htmlY, greaterThan(sentence));
        expect(freq, greaterThan(htmlY));
      });
    }

    testWidgets('[$ds] 正面区块布局：调序、题面关音调、加 HTML 区块', (WidgetTester tester) async {
      await pump(
        tester,
        answer: false,
        apple: apple,
        fields: _fields(<String, String>{'Hint': '想想看'}),
        appearance: const SrsCardAppearance(frontReading: true),
        front: <FushiCardItem>[
          FushiCardBlockItem(FushiCardFrontBlock.hint),
          const FushiCardHtmlItem('<p>反向提示</p>'),
          FushiCardBlockItem(
            FushiCardFrontBlock.prompt,
            options: <String, String>{kFushiOptPitch: '0'},
          ),
        ],
      );
      final Finder term = find.byKey(
        const ValueKey<String>('srs-fushi-front-term'),
      );
      expect(term, findsOneWidget);
      // 题面关了音调：正面不画音调图（外观开着「正面显示读音」也不画）。
      expect(
        find.descendant(of: term, matching: find.byType(SrsPitchGraph)),
        findsNothing,
      );
      final double hint = tester.getTopLeft(find.text('想想看')).dy;
      final Finder html = find.byKey(
        const ValueKey<String>('srs-fushi-front-item-1'),
      );
      expect(html, findsOneWidget);
      final double htmlY = tester.getTopLeft(html).dy;
      expect(htmlY, greaterThan(hint));
      expect(tester.getTopLeft(term).dy, greaterThan(htmlY));
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

  for (final Size size in const <Size>[Size(390, 844), Size(1280, 800)]) {
    testWidgets('${size.width.toInt()} 宽：左栏对齐网格——两个发音键同一竖线、文字同一起点', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        answer: true,
        size: size,
        // 词频明细区（srs-fushi-frequency）只在不聚合时出现。
        appearance: const SrsCardAppearance(aggregateFrequency: false),
        fields: _fields(<String, String>{
          'TermAudio': '[sound:word.mp3]',
          'SentenceAudio': '[sound:sentence.mp3]',
        }),
      );
      Rect rect(String key) =>
          tester.getRect(find.byKey(ValueKey<String>(key)));
      final Rect term = rect('srs-fushi-term');
      final Rect reading = rect('srs-fushi-reading-row');
      final Rect wordAudio = rect('srs-fushi-word-audio');
      final Rect sentence = rect('srs-fushi-sentence');
      final Rect block = rect('srs-fushi-sentence-block');
      final Rect sentenceAudio = rect('srs-fushi-sentence-audio');
      // 词条发音在词条区最前面、与「词条 + 读音」整块垂直居中，不在读音行里。
      expect(wordAudio.right, lessThanOrEqualTo(term.left));
      expect(
        (wordAudio.center.dy - (term.top + reading.bottom) / 2).abs(),
        lessThan(1),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-fushi-reading-row')),
          matching: find.byKey(const ValueKey<String>('srs-fushi-word-audio')),
        ),
        findsNothing,
      );
      // 例句发音在句首、在例句卡里垂直居中。
      expect(sentenceAudio.right, lessThanOrEqualTo(sentence.left));
      expect((sentenceAudio.center.dy - block.center.dy).abs(), lessThan(1));
      // 两个发音键同一条竖线，后面的文字从同一个 x 起头。
      expect(
        wordAudio.left,
        moreOrLessEquals(sentenceAudio.left, epsilon: 0.5),
      );
      expect(term.left, moreOrLessEquals(sentence.left, epsilon: 0.5));
      // 词频 / 来源与发音键同缩进（卡片内容那条线）。
      final Rect freqLabel = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('srs-fushi-frequency')),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(freqLabel.left, moreOrLessEquals(wordAudio.left, epsilon: 0.5));
      // 样例卡有「词频」区：读音行不再重复 FreqSort。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-fushi-reading-row')),
          matching: find.text('1840'),
        ),
        findsNothing,
      );
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
    expect(faces.last.pageWindow?.top, isNull);
  });

  // BUG-4038（反馈 1b5vbu96Ts）：释义超过纹理上限后旧实现把平台视图改成一屏高、指望页内
  // 滚动，可平台视图不认领纵向拖，触屏上页内永远停在顶部——主词典余文和下面的词典全看不到。
  // 现在释义区仍按内容高度占位、只由外层滚动；平台视图是一段窗口，跟着外层滚动换位置，
  // 页内滚动位置由宿主钉成同一个值。
  testWidgets('释义超过纹理上限：外层一路滚到最后一本词典与来源页脚，窗口跟着换位置', (
    WidgetTester tester,
  ) async {
    final List<SrsCardFace> faces = await pump(tester, answer: true);
    final SrsCardFace defs = faces.last;
    // 单一滚动所有者：窄版式释义不认领纵向拖（外层滚）。
    expect(defs.onContentHeight, isNotNull);
    final SrsPageWindowLink link = defs.pageWindow!;
    const double content = 9000;
    const double lastDict = 300; // 最后一本词典占内容末尾 300px。
    defs.onContentHeight!(content);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final Finder box = find.byType(SrsDefsScrollWindow);
    final Finder frame = find.byKey(
      const ValueKey<String>('srs-fushi-definitions'),
    );
    expect(tester.getSize(box).height, content);
    expect(tester.getSize(frame).height, kSrsDefsMaxInlineHeight);
    // 进入窗口态时页面就被钉住（窗口从内容顶开始）。
    expect(link.top, 0);

    final ScrollController scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey<String>('srs-fushi-back-narrow')),
        )
        .controller!;
    // 原始失败路径：把释义末尾（最后一本词典）滚进视口。
    scroll.jumpTo(scroll.offset + tester.getRect(box).bottom - 844);
    await tester.pump();
    await tester.pump();
    final Rect content0 = tester.getRect(box);
    final Rect shown = tester.getRect(frame);
    final Rect last = Rect.fromLTRB(
      content0.left,
      content0.bottom - lastDict,
      content0.right,
      content0.bottom,
    );
    expect(last.top, greaterThanOrEqualTo(0));
    expect(last.bottom, lessThanOrEqualTo(844));
    // 最后一本词典落在平台视图里……
    expect(shown.top, lessThanOrEqualTo(last.top));
    expect(shown.bottom, greaterThanOrEqualTo(last.bottom));
    // ……且页面被钉在平台视图所在的那段内容上（页内偏移 = 平台视图在内容里的偏移）。
    expect(link.top, moreOrLessEquals(shown.top - content0.top, epsilon: 0.5));
    expect(link.top! + kSrsDefsMaxInlineHeight, greaterThanOrEqualTo(content));

    // 外层继续滚到底：来源页脚露出来，没有滚动死区。
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    final Rect source = tester.getRect(
      find.byKey(const ValueKey<String>('srs-fushi-source')),
    );
    expect(source.top, lessThan(844));
    expect(source.bottom, greaterThan(0));

    // 滚回顶部：窗口跟回内容顶。
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(link.top, 0);
    expect(tester.getRect(frame).top, tester.getRect(box).top);

    // 内容收回上限以内：退出窗口态，平台视图重新跟内容等高。
    defs.onContentHeight!(1234);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getSize(frame).height, 1234);
    expect(link.top, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('片段卡原生显示：Picture 是片段播放器，内嵌单词音频出按钮', (WidgetTester tester) async {
    // 制卡链路真实写出的字段（anki_note_composer.dart）。
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{
        'Media': coverMediaRef('clip.webm'),
        'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
        'TermAudio': inlineVideoWordAudioHtml('word.mp3'),
      }),
    );
    final Finder clip = find.byKey(const ValueKey<String>('srs-fushi-picture'));
    expect(clip, findsOne);
    expect(tester.widget(clip), isA<SrsCardVideoClip>());
    expect(tester.widget<SrsCardVideoClip>(clip).name, 'clip.webm');
    expect(
      find.byKey(const ValueKey<String>('srs-fushi-word-audio')),
      findsOne,
      reason: '内嵌 <audio> 的单词音频照样有播放按钮',
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

  testWidgets('翻译模糊：默认模糊，点按显示，点字外空白再模糊', (WidgetTester tester) async {
    final Finder toggle = find.byKey(
      const ValueKey<String>('srs-fushi-translation-toggle'),
    );
    final Finder blur = find.descendant(
      of: toggle,
      matching: find.byType(ImageFiltered),
    );
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{'SentenceTranslation': 'It is fine.'}),
      appearance: const SrsCardAppearance(blurTranslation: true),
    );
    await tester.pumpAndSettle();
    expect(blur, findsOne, reason: '默认模糊');

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-fushi-translation')),
    );
    await tester.pumpAndSettle();
    expect(blur, findsNothing, reason: '点按后显示');

    final Rect r = tester.getRect(toggle);
    await tester.tapAt(Offset(r.right - 4, r.center.dy));
    await tester.pumpAndSettle();
    expect(blur, findsOne, reason: '再点一下重新模糊');
  });

  testWidgets('翻译模糊开但翻译关：整行不画，模糊开关被忽略', (WidgetTester tester) async {
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{'SentenceTranslation': 'It is fine.'}),
      appearance: const SrsCardAppearance(
        showTranslation: false,
        blurTranslation: true,
      ),
    );
    for (final String k in <String>[
      'srs-fushi-translation',
      'srs-fushi-translation-toggle',
    ]) {
      expect(find.byKey(ValueKey<String>(k)), findsNothing, reason: k);
    }
  });

  testWidgets('翻译模糊关：行为不变，不包点按层也不模糊', (WidgetTester tester) async {
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{'SentenceTranslation': 'It is fine.'}),
    );
    expect(
      find.byKey(const ValueKey<String>('srs-fushi-translation')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-fushi-translation-toggle')),
      findsNothing,
    );
  });

  testWidgets('多个声调：每个声调各画一张声调图，不只画第一个', (WidgetTester tester) async {
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{
        'TermFurigana': '',
        'TermReading': 'かよう',
        'PitchPosition': '0, 2',
        'PitchCategories': '',
      }),
    );
    final Finder graphs = find.byType(SrsPitchGraph);
    expect(graphs, findsNWidgets(2));
    expect(
      tester
          .widgetList<SrsPitchGraph>(graphs)
          .map((SrsPitchGraph g) => g.position),
      <int?>[0, 2],
    );
    expect(find.byKey(const ValueKey<String>('srs-fushi-pitch')), findsOne);
    expect(find.byKey(const ValueKey<String>('srs-fushi-pitch-1')), findsOne);
  });

  testWidgets('三个声调 + 长假名、窄屏：每个声调各一张图、不溢出，声调核序号是图右上角的角标', (
    WidgetTester tester,
  ) async {
    const String kana = 'ちょうしゅうせきにんしゃ';
    await pump(
      tester,
      answer: true,
      size: const Size(320, 700),
      fields: _fields(<String, String>{
        'TermFurigana': '',
        'TermReading': kana,
        'PitchPosition': '0, 3, 5',
        'PitchCategories': '',
        // 读音行里不再出词频聚合标签以外的标签：声调序号不是 _Chip。
        'FrequencyRank': '',
      }),
    );
    // pump 内已断言没有布局溢出异常（RenderFlex overflow 会作为 takeException 抛出）。
    final Finder graphs = find.byType(SrsPitchGraph);
    expect(graphs, findsNWidgets(3));
    expect(
      tester
          .widgetList<SrsPitchGraph>(graphs)
          .map((SrsPitchGraph g) => g.position),
      <int?>[0, 3, 5],
    );
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('srs-fushi-reading-row')),
    );
    expect(row.right, lessThanOrEqualTo(320));
    for (final Element e in graphs.evaluate()) {
      final Rect r = tester.getRect(find.byWidget(e.widget));
      expect(r.left, greaterThanOrEqualTo(row.left - 0.5));
      expect(r.right, lessThanOrEqualTo(row.right + 0.5), reason: '$r vs $row');
    }
    // 每张图一个角标，数字取自字段（不推断），角标在最后一拍假名的右侧、顶端对齐。
    final Finder badges = find.byKey(
      const ValueKey<String>('srs-fushi-pitch-position'),
    );
    expect(badges, findsNWidgets(3));
    for (final (int i, String n) in <(int, String)>[
      (0, '0'),
      (1, '3'),
      (2, '5'),
    ]) {
      final Finder badge = find.descendant(
        of: find.byKey(
          ValueKey<String>(i == 0 ? 'srs-fushi-pitch' : 'srs-fushi-pitch-$i'),
        ),
        matching: badges,
      );
      expect(find.descendant(of: badge, matching: find.text(n)), findsOne);
      final Rect b = tester.getRect(badge);
      final Rect g = tester.getRect(
        find.byKey(
          ValueKey<String>(i == 0 ? 'srs-fushi-pitch' : 'srs-fushi-pitch-$i'),
        ),
      );
      expect(b.top, closeTo(g.top, 0.5));
      expect(b.height, lessThan(g.height));
    }
  });

  testWidgets('正面不出声调角标（只画图，与原来一致）', (WidgetTester tester) async {
    await pump(
      tester,
      answer: false,
      appearance: const SrsCardAppearance(frontReading: true),
      fields: _fields(<String, String>{
        'TermFurigana': '',
        'TermReading': 'かよう',
        'PitchPosition': '0, 2',
      }),
    );
    expect(find.byType(SrsPitchGraph), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey<String>('srs-fushi-pitch-position')),
      findsNothing,
    );
  });

  testWidgets('例句对齐 / 首行缩进：居中占满栏宽、缩进在段首占位（不进取词文字）', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      answer: true,
      appearance: const SrsCardAppearance(
        sentenceAlign: SrsCardTextAlign.center,
        sentenceIndent: 2,
      ),
    );
    final SrsRubyText sentence = tester.widget<SrsRubyText>(
      find.byKey(const ValueKey<String>('srs-fushi-sentence')),
    );
    expect(sentence.textAlign, TextAlign.center);
    expect(sentence.indent, 2 * sentence.style.fontSize!);
    final Text translation = tester.widget<Text>(
      find.byKey(const ValueKey<String>('srs-fushi-translation')),
    );
    expect(translation.textAlign, TextAlign.center);
    // 默认外观：背面例句左对齐、不缩进（旧外观不变）。
    await tester.pumpWidget(const SizedBox());
    await pump(tester, answer: true);
    final SrsRubyText plain = tester.widget<SrsRubyText>(
      find.byKey(const ValueKey<String>('srs-fushi-sentence')),
    );
    expect(plain.textAlign, TextAlign.start);
    expect(plain.indent, 0);
  });

  group('正面例句目标词强调（与模板 .fc-front-sentence b 一致，BUG VbJo0Y7S0A）', () {
    List<SrsInline> boldOf(WidgetTester tester, String key) => tester
        .widget<SrsRubyText>(find.byKey(ValueKey<String>(key)))
        .segments
        .where((SrsInline x) => x.bold)
        .toList();

    Map<String, String> card(String flag, Map<String, String> extra) =>
        _fields(<String, String>{
          'IsSentenceCard': '',
          'IsWordAndSentenceCard': '',
          flag: 'x',
          'MainDefinition': '',
          'Glossary': '',
          'LookupSelection': '',
          'DefinitionMedia': '',
          ...extra,
        });

    testWidgets('例句卡：字段里的 <b> 加粗并上目标色，注音去掉', (WidgetTester tester) async {
      await pump(
        tester,
        answer: false,
        fields: card('IsSentenceCard', <String, String>{
          'Term': 'キャッチ',
          'Sentence': '空中[くうちゅう]でアタシが<b>キャッチ</b>。',
        }),
      );
      const String key = 'srs-fushi-front-sentence';
      final SrsRubyText text = tester.widget<SrsRubyText>(
        find.byKey(const ValueKey<String>(key)),
      );
      expect(text.emphasis, isNotNull);
      expect(boldOf(tester, key).map((SrsInline x) => x.text).join(), 'キャッチ');
      expect(text.segments.every((SrsInline x) => x.ruby == null), isTrue);
      expect(text.segments.map((SrsInline x) => x.text).join(), '空中でアタシがキャッチ。');
    });

    testWidgets('单词 + 例句卡：例句没 <b> 时按词条重新定位并强调', (WidgetTester tester) async {
      await pump(
        tester,
        answer: false,
        fields: card('IsWordAndSentenceCard', <String, String>{
          'Term': 'キャッチ',
          'Sentence': '飛んだらアタシがキャッチ。',
        }),
      );
      expect(
        boldOf(
          tester,
          'srs-fushi-front-sentence',
        ).map((SrsInline x) => x.text).join(),
        'キャッチ',
      );
    });

    testWidgets('听音卡：目标词照旧挖空，不露出', (WidgetTester tester) async {
      await pump(
        tester,
        answer: false,
        fields: card('IsAudioCard', <String, String>{
          'Term': 'キャッチ',
          'Sentence': 'アタシが<b>キャッチ</b>。',
        }),
      );
      final SrsRubyText text = tester.widget<SrsRubyText>(
        find.byKey(const ValueKey<String>('srs-fushi-front-masked')),
      );
      final String shown = text.segments.map((SrsInline x) => x.text).join();
      expect(shown, isNot(contains('キャッチ')));
      expect(shown, contains('［…］'));
    });
  });

  testWidgets('正面例句：默认居中；选左对齐后左对齐并占满栏宽', (WidgetTester tester) async {
    final Map<String, String> sentenceCard = _fields(<String, String>{
      'IsSentenceCard': 'x',
      'IsWordAndSentenceCard': '',
      // 没有释义 = 正面不叠预热释义的 Stack，测试宿主的松约束下也能量到正面宽度。
      'MainDefinition': '',
      'Glossary': '',
      'LookupSelection': '',
      'DefinitionMedia': '',
    });
    await pump(tester, answer: false, fields: sentenceCard);
    const ValueKey<String> key = ValueKey<String>('srs-fushi-front-sentence');
    expect(
      tester.widget<SrsRubyText>(find.byKey(key)).textAlign,
      TextAlign.center,
    );
    await tester.pumpWidget(const SizedBox());
    await pump(
      tester,
      answer: false,
      fields: sentenceCard,
      appearance: const SrsCardAppearance(
        sentenceAlign: SrsCardTextAlign.start,
      ),
    );
    expect(
      tester.widget<SrsRubyText>(find.byKey(key)).textAlign,
      TextAlign.start,
    );
    // ignore: avoid_print
    expect(tester.getRect(find.byKey(key)).width, greaterThan(300));
  });

  testWidgets('正反面字号分开：正面词条按正面倍率，背面不受影响', (WidgetTester tester) async {
    double frontTermSize() => tester
        .widget<SrsRubyText>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('srs-fushi-front-term')),
            matching: find.byType(SrsRubyText),
          ),
        )
        .style
        .fontSize!;
    double backTermSize() => tester
        .widget<SrsRubyText>(
          find.byKey(const ValueKey<String>('srs-fushi-term')),
        )
        .style
        .fontSize!;
    final Map<String, String> wordCard = _fields(<String, String>{
      'IsWordAndSentenceCard': '',
    });
    await pump(tester, answer: false, fields: wordCard);
    final double shared = frontTermSize();
    await tester.pumpWidget(const SizedBox());
    await pump(tester, answer: true, fields: wordCard);
    final double sharedBack = backTermSize();
    const SrsCardAppearance separate = SrsCardAppearance(
      separateFrontSize: true,
      frontTermScale: 1.3,
    );
    await tester.pumpWidget(const SizedBox());
    await pump(tester, answer: false, fields: wordCard, appearance: separate);
    expect(frontTermSize(), closeTo(shared * 1.3, 0.01));
    await tester.pumpWidget(const SizedBox());
    await pump(tester, answer: true, fields: wordCard, appearance: separate);
    expect(backTermSize(), closeTo(sharedBack, 0.01));
  });

  group('声调图逐拍画法与模板一致（反馈 kP5GJ0pahv）', () {
    const SrsPitchMoraMark low = SrsPitchMoraMark(high: false, drop: false);
    const SrsPitchMoraMark high = SrsPitchMoraMark(high: true, drop: false);
    const SrsPitchMoraMark highDrop = SrsPitchMoraMark(high: true, drop: true);

    test('平板 [0]：首拍低、其余高，没有降调符', () {
      expect(srsPitchMoraMarks(0, 4), <SrsPitchMoraMark>[
        low,
        high,
        high,
        high,
      ]);
    });

    test('中高 [3]：か低 すれ高、れ后降、る低', () {
      expect(srsPitchMoraMarks(3, 4), <SrsPitchMoraMark>[
        low,
        high,
        highDrop,
        low,
      ]);
    });

    test('头高 [1]：首拍高并降', () {
      expect(srsPitchMoraMarks(1, 3), <SrsPitchMoraMark>[highDrop, low, low]);
    });

    test('尾高 [2]（2 拍）：末拍降 + 尾拍', () {
      expect(srsPitchMoraMarks(2, 2), <SrsPitchMoraMark>[
        low,
        highDrop,
        const SrsPitchMoraMark(high: false, drop: false, tail: true),
      ]);
    });
  });

  testWidgets('没有可解析的声调：只画一份读音', (WidgetTester tester) async {
    await pump(
      tester,
      answer: true,
      fields: _fields(<String, String>{
        'TermFurigana': '',
        'TermReading': 'かよう',
        'PitchPosition': '',
      }),
    );
    final Finder graphs = find.byType(SrsPitchGraph);
    expect(graphs, findsOne);
    expect(tester.widget<SrsPitchGraph>(graphs).position, isNull);
  });

  group('词频聚合', () {
    final Map<String, String> freq = <String, String>{
      'FrequencyRank': '1840',
      'Frequency':
          '<ul><li>JPDB: 100</li><li>JPDB: 2000</li><li>BCCWJ: 5</li></ul>',
    };
    const ValueKey<String> detail = ValueKey<String>('srs-fushi-frequency');
    const ValueKey<String> aggregate = ValueKey<String>(
      'srs-fushi-frequency-aggregate',
    );

    testWidgets('聚合且 FreqSort 有值：只有读音行平均值，没有明细区', (WidgetTester tester) async {
      await pump(
        tester,
        answer: true,
        fields: _fields(freq),
        appearance: const SrsCardAppearance(aggregateFrequency: true),
      );
      expect(find.byKey(aggregate), findsOne);
      expect(find.byKey(detail), findsNothing);
    });

    testWidgets('不聚合：只有明细区，同词典两个值合成一个 chip', (WidgetTester tester) async {
      await pump(
        tester,
        answer: true,
        fields: _fields(freq),
        appearance: const SrsCardAppearance(aggregateFrequency: false),
      );
      expect(find.byKey(detail), findsOne);
      expect(find.byKey(aggregate), findsNothing);
      final Finder texts = find.descendant(
        of: find.byKey(detail),
        matching: find.byType(Text),
      );
      final List<String> all = tester
          .widgetList<Text>(texts)
          .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .toList();
      expect(all.where((String s) => s.contains('JPDB')), hasLength(1));
      expect(all.singleWhere((String s) => s.contains('JPDB')), contains(', '));
    });

    testWidgets('关了「显示词频」：两者都没有', (WidgetTester tester) async {
      for (final bool agg in <bool>[true, false]) {
        await pump(
          tester,
          answer: true,
          fields: _fields(freq),
          appearance: SrsCardAppearance(
            showFrequency: false,
            aggregateFrequency: agg,
          ),
        );
        expect(find.byKey(aggregate), findsNothing, reason: 'agg=$agg');
        expect(find.byKey(detail), findsNothing, reason: 'agg=$agg');
      }
    });
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

  testWidgets('铺到浮动页头底下：页头高度只作滚动内边距，往下翻内容滚进页头底下', (WidgetTester tester) async {
    const double inset = 120;
    await pump(tester, answer: true, topInset: inset);
    final Finder term = find.byKey(const ValueKey<String>('srs-fushi-term'));
    final double top = tester.getTopLeft(term).dy;
    // 开头的内容从页头下沿开始，不被盖住。
    expect(top, greaterThanOrEqualTo(inset));
    final Finder scroll = find.byKey(
      const ValueKey<String>('srs-fushi-back-narrow'),
    );
    expect(
      (tester.widget<SingleChildScrollView>(scroll).padding! as EdgeInsets).top,
      inset,
    );
    // 卡面本身从顶端画起（没有固定让位），内容能滚到让位区里。
    expect(tester.getTopLeft(scroll).dy, 0);
    await tester.drag(scroll, const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(term).dy, lessThan(inset));
  });

  testWidgets('窄屏（手机）：图片通栏与例句卡等宽、按原比例；词条独占整行不被挤折行', (
    WidgetTester tester,
  ) async {
    await pump(tester, answer: true);
    final Finder pic = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-fushi-picture')),
      matching: find.byType(Image),
    );
    await tester.runAsync(
      () => precacheImage(tester.widget<Image>(pic).image, tester.element(pic)),
    );
    // 尺寸监听在 runAsync 里回调、setState 后再 pump 一帧才换成铺满。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final Rect rect = tester.getRect(pic);
    final Rect block = tester.getRect(
      find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
    );
    // 样例图 320×200（1.6）：铺满栏宽，左右边与例句卡对齐，按原比例定高——不再是
    // 标题右侧 126×118 的缩略图。
    expect(rect.left, moreOrLessEquals(block.left, epsilon: 0.5));
    expect(rect.right, moreOrLessEquals(block.right, epsilon: 0.5));
    expect(rect.width / rect.height, closeTo(1.6, 0.02));
    // 图片在词条区下面、例句上面。
    final Rect header = tester.getRect(
      find.byKey(const ValueKey<String>('srs-fushi-header')),
    );
    expect(rect.top, greaterThanOrEqualTo(header.bottom));
    expect(rect.bottom, lessThanOrEqualTo(block.top));
    // 词条区占满整行宽（没有并排的缩略图分走宽度）。
    expect(header.width, moreOrLessEquals(block.width, epsilon: 0.5));
  });

  testWidgets('宽屏左栏：常见比例的图与例句卡等宽；竖长封面照旧限高', (WidgetTester tester) async {
    Future<Rect> pictureRect() async {
      final Finder pic = find.descendant(
        of: find.byKey(const ValueKey<String>('srs-fushi-picture')),
        matching: find.byType(Image),
      );
      await tester.runAsync(
        () =>
            precacheImage(tester.widget<Image>(pic).image, tester.element(pic)),
      );
      // 尺寸监听在 runAsync 里回调、setState 后再 pump 一帧才换成铺满。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return tester.getRect(pic);
    }

    await pump(tester, answer: true, size: const Size(1280, 800));
    final Rect block = tester.getRect(
      find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
    );
    // 样例图 320×200（1.6）：铺满栏宽，左右边与例句卡对齐，按原比例定高。
    final Rect wide = await pictureRect();
    expect(wide.left, moreOrLessEquals(block.left, epsilon: 0.5));
    expect(wide.width, moreOrLessEquals(block.width, epsilon: 0.5));
    expect(wide.width / wide.height, closeTo(1.6, 0.02));

    // 视口矮（600）：原比例高 300 超过视口 40%（240）→ 整张等比缩小到高 240（不裁切），
    // 比例不变、靠左对齐卡片边缘。
    await pump(tester, answer: true, size: const Size(1280, 600));
    final Rect capped = await pictureRect();
    expect(capped.height, moreOrLessEquals(600 * 0.4, epsilon: 0.5));
    expect(capped.width / capped.height, closeTo(1.6, 0.02));
    expect(capped.left, moreOrLessEquals(block.left, epsilon: 0.5));

    // 竖长封面（1×3）不铺满：限高 220、按原比例完整显示。
    await pump(
      tester,
      answer: true,
      size: const Size(1280, 800),
      fields: _fields(<String, String>{'Media': '<img src="$_tallPng">'}),
    );
    final Rect tall = await pictureRect();
    expect(tall.height, lessThanOrEqualTo(220.5));
    expect(tall.width, lessThan(block.width / 2));
  });

  testWidgets('动图随例句重播：新实例出首帧前，旧画面那一层原样留着（不重建、不闪空）', (
    WidgetTester tester,
  ) async {
    // 同步 IO：testWidgets 的假时钟里 await 真异步 IO 会挂住。
    final Directory dir = Directory.systemTemp.createTempSync(
      'srs_card_gif_restart_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    // 1×1 GIF。
    File('${dir.path}/clip.gif').writeAsBytesSync(
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
    );
    await pump(
      tester,
      answer: true,
      store: SrsMediaStore(dir),
      fields: _fields(<String, String>{'Media': '<img src="clip.gif">'}),
    );
    final Finder images = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-fushi-picture')),
      matching: find.byType(Image),
    );
    expect(images, findsOneWidget);
    final State<StatefulWidget> before = tester.state(images);

    final SrsCardSentenceCompanion media =
        tester.state(
              find.byWidgetPredicate(
                (Widget w) => w.runtimeType.toString() == '_MediaImage',
              ),
            )
            as SrsCardSentenceCompanion;
    media.sentenceStarted('sentence.mp3');
    await tester.pump();

    // 旧层与新层并排：旧层必须就是原来那个实例（换父节点会把它连同已解出的画面一起丢掉，
    // 垫底的就成了又一个从零解码的新实例，替换瞬间照样空一下）。
    expect(images, findsNWidgets(2));
    expect(before.mounted, isTrue, reason: '旧画面那一层必须是原实例');
    expect(identical(tester.state(images.first), before), isTrue);

    // 新层解出首帧后撤掉垫底层：留下的就是新层那个实例（不再重建一次从头播）。
    final State<StatefulWidget> fresh = tester.state(images.last);
    // 文件读取与解码是真实 IO，但新层的 completer 是 Image 在假时钟 zone 里 resolve
    // 出来的：每一步（读字节 → 建 buffer → 解码 → 取帧）完成后的续体排进假 zone 的
    // 微任务队列，只有 pump 才冲刷——所以既不能在 runAsync 里直接 await 它（会挂死），也
    // 只能「让出真实时间 + pump」交替推进。以前固定 20 轮 × 50 ms：整批并发跑、机器忙时
    // 1 秒内走不完这几步，垫底层还没撤就断言，成了看机器负载的伪红。改成按真实时间截止
    // （与断言无关，只放宽等真实 IO 的预算），解出来就立即停。
    final Stopwatch waited = Stopwatch()..start();
    while (images.evaluate().length > 1 &&
        waited.elapsed < const Duration(seconds: 15)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(images, findsOneWidget);
    expect(identical(tester.state(images), fresh), isTrue);
  });

  group('卡上引用了媒体、本机文件缺失（还没同步过来）', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('srs_card_missing_media_');
    });
    tearDown(() => dir.delete(recursive: true));

    testWidgets('图片：画「图片未同步」占位（宽版式铺满栏宽、16:9），不再是零尺寸空盒', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        answer: true,
        size: const Size(1280, 800),
        store: SrsMediaStore(dir),
        fields: _fields(<String, String>{
          'Media': '<img src="never_synced.png">',
        }),
      );
      // 文件读取失败在真实 IO 里回调，setState 后再 pump 一帧。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final Finder placeholder = find.byKey(
        const ValueKey<String>('srs-fushi-picture-missing'),
      );
      expect(placeholder, findsOne);
      expect(find.text(t.srs_card_media_missing_image), findsOne);
      final Rect block = tester.getRect(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
      );
      final Rect rect = tester.getRect(placeholder);
      expect(rect.width, moreOrLessEquals(block.width, epsilon: 0.5));
      expect(rect.width / rect.height, closeTo(16 / 9, 0.01));
    });

    testWidgets('视频片段：画「视频未同步」占位，宽版式与图片同规则铺满栏宽', (WidgetTester tester) async {
      await pump(
        tester,
        answer: true,
        size: const Size(1280, 800),
        store: SrsMediaStore(dir),
        fields: _fields(<String, String>{
          'Media': coverMediaRef('never_synced.webm'),
        }),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final Finder placeholder = find.byKey(
        const ValueKey<String>('srs-card-video-missing'),
      );
      expect(placeholder, findsOne);
      expect(find.text(t.srs_card_media_missing_video), findsOne);
      final Rect block = tester.getRect(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
      );
      final Rect rect = tester.getRect(placeholder);
      expect(rect.left, moreOrLessEquals(block.left, epsilon: 0.5));
      expect(rect.width, moreOrLessEquals(block.width, epsilon: 0.5));
      expect(rect.height, lessThanOrEqualTo(800 * 0.4 + 0.5));
    });
  });

  test('图片来源：光栅 data URI → 内存；SVG / 远程 / 无媒体库 → 不画', () {
    final String sample = srsImageSources(
      srsSampleCardFields()['Media']!,
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
