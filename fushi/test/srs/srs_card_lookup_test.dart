// 复习卡面查词：原生区按字取词 → 查词弹窗（与阅读器同一套弹窗引擎）；弹窗里继续嵌套查；
// 卡面原有点击（点例句显示注音）不被取词吃掉，取词 / 显示注音用掉的点按也不报卡面手势；卡面链接只放行 Fushi 来源跳转。
// 复习页整页（按键不评分、Esc 关弹窗回焦点）见 srs_pages_test.dart 的「卡面查词」组。
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/rendering.dart' show RenderParagraph, TextBox;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show NavigationActionPolicy;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';

/// 弹窗几何 / 历史读偏好的那几项钉成常量（测试里偏好层没初始化）。
class _LookupApp extends AppModel {
  _LookupApp() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  bool get lowMemoryMode => false;
  @override
  SrsCardAppearance get srsCardAppearance => const SrsCardAppearance();
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}
}

Future<DictionarySearchResult> _fakeSearch(String term, int max) async =>
    DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: term, reading: 'よみ', meaning: 'm'),
      ],
    );

Map<String, String> _fields() => <String, String>{
  for (final String f in FushiCardNoteType.fields) f: '',
  ...srsSampleCardFields(),
  // 例句字段自带 Anki 方括号注音（导入的笔记常见）：例句注音的点按显示走这一份。
  'Sentence': '毎日[まいにち]のように 図書館[としょかん]に<b>通[かよ]って</b>いる。',
};

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<SrsCardLookupController> pumpCard(
    WidgetTester tester, {
    required bool answer,
    bool apple = false,
    SrsCardLookupCardSource? Function()? cardSource,
    void Function(SrsCardGestureEvent)? onCardGesture,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SrsCardLookupController lookup = SrsCardLookupController(
      settings: () => (tap: true, hoverAuto: false),
    );
    addTearDown(lookup.dispose);
    final _LookupApp app = _LookupApp();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          ...popupMiningTargetTestOverrides(),
          srsCardLookupSearchProvider.overrideWithValue(_fakeSearch),
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => null as SrsMediaStore?,
          ),
          srsCardFaceBuilderProvider.overrideWithValue(
            (BuildContext context, SrsCardFace face) =>
                const SizedBox(key: ValueKey<String>('defs-webview')),
          ),
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
              // 复习页里卡面是撑满的（Expanded）：正面的 Stack 只有定位子项，松约束下会缩成 0。
              body: SizedBox.expand(
                child: SrsCardLookupHost(
                  controller: lookup,
                  cardSource: cardSource,
                  child: SrsFushiCardView(
                    face: SrsCardFace(
                      cardId: 'c1',
                      showingAnswer: answer,
                      bodyHtml: '',
                      css: FushiCardNoteType.template.css,
                      languageCode: 'ja',
                      onBridgeKey: (_) {},
                      onCardGesture: onCardGesture,
                    ),
                    fields: _fields(),
                    definitionsHtml: '<div class="fc-defs-only">defs</div>',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    return lookup;
  }

  /// [finder] 子树里文字 [chars] 第一个字的屏幕中心（按真实字形盒找，注音段 / 普通段都行）。
  Offset rubyBaseCenter(WidgetTester tester, Finder finder, String chars) {
    for (final Element e
        in find
            .descendant(of: finder, matching: find.byType(RichText))
            .evaluate()) {
      final RenderParagraph p = e.renderObject! as RenderParagraph;
      final String text = p.text.toPlainText(includeSemanticsLabels: false);
      final int i = text.indexOf(chars);
      if (i < 0) continue;
      final List<TextBox> boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: i, extentOffset: i + 1),
      );
      return p.localToGlobal(boxes.first.toRect().center);
    }
    fail('没找到文字 $chars');
  }

  Future<void> settlePopup(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 冷建 WebView 没有 popupRendered：翻可见兜底计时 1.8s。
    await tester.pump(const Duration(seconds: 2));
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 原生区：点词条的字 → 查词弹窗打开，查询串从被点的字起', (
      WidgetTester tester,
    ) async {
      final SrsCardLookupController lookup = await pumpCard(
        tester,
        answer: true,
        apple: apple,
      );
      final Finder term = find.byKey(const ValueKey<String>('srs-fushi-term'));
      expect(term, findsOneWidget);
      // 词条「通[かよ]う」：点注音段的基字「通」→ 查「通う」。
      await tester.tapAt(rubyBaseCenter(tester, term, '通'));
      await settlePopup(tester);
      expect(lookup.isOpen, isTrue);
      expect(lookup.debugQueries, <String>['通う']);
      expect(lookup.debugVisibleDepth, 1);

      // 弹窗释义里点词 → 嵌套第二层。
      await lookup.pushNested('図書館', const Rect.fromLTWH(40, 200, 20, 20));
      await settlePopup(tester);
      expect(lookup.debugVisibleDepth, 2);
      expect(lookup.debugQueries.last, '図書館');

      // Esc（关一层）语义：先关嵌套层，再关整栈。
      expect(lookup.closeTop(), isTrue);
      await tester.pump();
      expect(lookup.debugVisibleDepth, 1);
      lookup.closeAll();
      await tester.pump();
      expect(lookup.isOpen, isFalse);
      await tester.pump(const Duration(seconds: 2));
    });
  }

  group('制卡来源（cardSource）', () {
    Future<List<AnkiMiningContext>> mineBoth(WidgetTester tester) async {
      final Finder host = find.byType(SrsCardLookupHost);
      final DictionaryPageMixin page =
          tester.state(host) as DictionaryPageMixin;
      final FakeAnkiRepository repo =
          ProviderScope.containerOf(
                tester.element(host),
              ).read(ankiRepositoryProvider)
              as FakeAnkiRepository;
      // 假仓库的 mineEntry 记下上下文后抛 UnimplementedError（不落卡）。
      await expectLater(
        page.onMineEntry(<String, String>{'sentence': 's'}),
        throwsUnimplementedError,
      );
      await page.onUpdateEntry(7, <String, String>{'sentence': 's'});
      await tester.pump(const Duration(seconds: 5));
      expect(repo.minedContexts, hasLength(2));
      return repo.minedContexts;
    }

    testWidgets('不传：标题 / 网址都不带（复习卡面行为不变）', (WidgetTester tester) async {
      await pumpCard(tester, answer: true);
      for (final AnkiMiningContext c in await mineBoth(tester)) {
        expect(c.documentTitle, isNull);
        expect(c.sourceUrl, isNull);
        expect(c.sourceLink, isNull);
      }
    });

    testWidgets('传：制卡与覆写都带当前网页标题与网址；返回 null 时不带', (WidgetTester tester) async {
      SrsCardLookupCardSource? current = (
        title: '  ニュース  ',
        url: Uri.parse('https://example.jp/a?b=1'),
      );
      await pumpCard(tester, answer: true, cardSource: () => current);
      for (final AnkiMiningContext c in await mineBoth(tester)) {
        expect(c.documentTitle, 'ニュース');
        expect(c.sourceUrl, 'https://example.jp/a?b=1');
      }
      current = null; // 例如切到无痕标签页
      final Finder host = find.byType(SrsCardLookupHost);
      final FakeAnkiRepository repo =
          ProviderScope.containerOf(
                tester.element(host),
              ).read(ankiRepositoryProvider)
              as FakeAnkiRepository;
      repo.minedContexts.clear();
      final AnkiMiningContext c = (await mineBoth(tester)).last;
      expect(c.documentTitle, isNull);
      expect(c.sourceUrl, isNull);
    });
  });

  testWidgets('原生区：例句注音收起时第一下点按只显示注音（原有操作），之后点字才查词', (
    WidgetTester tester,
  ) async {
    final SrsCardLookupController lookup = await pumpCard(tester, answer: true);
    final Finder sentence = find.byKey(
      const ValueKey<String>('srs-fushi-sentence'),
    );
    expect(sentence, findsOneWidget);
    // 注音收起：基字段落里只有「毎日」，没有「まいにち」。
    expect(
      find.descendant(of: sentence, matching: find.text('まいにち')),
      findsNothing,
    );
    await tester.tapAt(tester.getTopLeft(sentence) + const Offset(6, 12));
    await tester.pump();
    expect(lookup.isOpen, isFalse, reason: '第一下是显示注音，不取词');
    expect(
      find.descendant(of: sentence, matching: find.text('まいにち')),
      findsOneWidget,
    );

    // 注音显示后点基字 → 查词，注音不被收回。
    await tester.tapAt(rubyBaseCenter(tester, sentence, '図書館'));
    await settlePopup(tester);
    expect(lookup.isOpen, isTrue);
    expect(lookup.debugQueries.single, startsWith('図書館に'));
    expect(
      find.descendant(of: sentence, matching: find.text('まいにち')),
      findsOneWidget,
      reason: '这一下被取词用掉了，不再切换注音',
    );
    lookup.closeAll();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('原生区卡面手势：取词 / 显示注音用掉的点按不报单击，空白处照报', (WidgetTester tester) async {
    final List<SrsCardGestureEvent> events = <SrsCardGestureEvent>[];
    final SrsCardLookupController lookup = await pumpCard(
      tester,
      answer: true,
      onCardGesture: events.add,
    );
    final Finder term = find.byKey(const ValueKey<String>('srs-fushi-term'));
    final Finder sentence = find.byKey(
      const ValueKey<String>('srs-fushi-sentence'),
    );

    // 点例句（注音收起）：显示注音，不是单击空白。
    await tester.tapAt(tester.getTopLeft(sentence) + const Offset(6, 12));
    await tester.pump();
    expect(
      find.descendant(of: sentence, matching: find.text('まいにち')),
      findsOneWidget,
    );
    expect(events, isEmpty, reason: '显示注音用掉了这一下');

    // 点词条的字：查词，不是单击空白。
    await tester.tapAt(rubyBaseCenter(tester, term, '通'));
    await settlePopup(tester);
    expect(lookup.isOpen, isTrue);
    expect(events, isEmpty, reason: '取词用掉了这一下');
    lookup.closeAll();
    await tester.pump(const Duration(seconds: 2));

    // 卡面底部右下角的页边空白：报单击（带落点）。
    const Offset blank = Offset(386, 836);
    await tester.tapAt(blank);
    await tester.pump();
    expect(events, <SrsCardGestureEvent>[
      const SrsCardGestureEvent(SrsCardGestureKind.tap, position: blank),
    ]);
    expect(lookup.isOpen, isFalse);
  });

  testWidgets('原生区：正面预热的释义区不登记为取词表面（只有原生词条可查）', (WidgetTester tester) async {
    final SrsCardLookupController lookup = await pumpCard(
      tester,
      answer: false,
    );
    final Finder term = find.byKey(
      const ValueKey<String>('srs-fushi-front-term'),
    );
    final Offset pos = rubyBaseCenter(tester, term, '通');
    await tester.tapAt(pos);
    await settlePopup(tester);
    expect(lookup.debugQueries, <String>['通う']);
    lookup.closeAll();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('注音拼接文字的命中换算：点基字 / 注音 / 普通段都回到整段偏移', (WidgetTester tester) async {
    final GlobalKey root = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: root,
            child: const SrsRubyText(
              segments: <SrsInline>[
                SrsInline('毎日', ruby: 'まいにち'),
                SrsInline('のように'),
                SrsInline('通', ruby: 'かよ'),
                SrsInline('う'),
              ],
              style: TextStyle(fontSize: 20),
              rubyStyle: TextStyle(fontSize: 10),
              lookup: true,
            ),
          ),
        ),
      ),
    );
    final RenderBox box = root.currentContext!.findRenderObject()! as RenderBox;
    String? termAt(String chars) => srsNativeLookupHitAt(
      box,
      rubyBaseCenter(tester, find.byKey(root), chars),
    )?.term;
    expect(termAt('毎'), '毎日のように通う');
    expect(termAt('よ'), 'ように通う');
    expect(termAt('通'), '通う');
    expect(termAt('か'), '通う', reason: '点注音按该段起点取词');
  });

  // 用户 2026-10-21「弹窗位置不对，高了一点」：复习页不在界面缩放中和层之下（实测用户
  // 界面缩放 1.4），取词锚点只平移原点时高宽 / 位置留在 1/缩放，弹窗按偏高的下沿摆、
  // 盖住被查的那一行。锚点必须是字形盒经完整变换后的全局矩形。
  testWidgets('原生区取词锚点随界面缩放：盒子含点按位置、高度 = 字形高 × 缩放', (
    WidgetTester tester,
  ) async {
    const double scale = 1.4;
    final GlobalKey root = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 30, top: 40),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: root,
                child: const SrsRubyText(
                  segments: <SrsInline>[SrsInline('手足を動かして水中を進む')],
                  style: TextStyle(fontSize: 20),
                  rubyStyle: TextStyle(fontSize: 10),
                  lookup: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final RenderBox box = root.currentContext!.findRenderObject()! as RenderBox;
    final Offset tap = rubyBaseCenter(tester, find.byKey(root), '水');
    final SrsNativeLookupHit hit = srsNativeLookupHitAt(box, tap)!;
    expect(hit.term, '水中を進む');
    final RenderParagraph paragraph = hit.paragraph;
    final String text = paragraph.text.toPlainText(
      includeSemanticsLabels: false,
    );
    final int i = text.indexOf('水');
    final Rect glyph = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
          boxHeightStyle: BoxHeightStyle.max,
        )
        .first
        .toRect();
    expect(hit.anchor.contains(tap), isTrue, reason: '${hit.anchor} vs $tap');
    expect(hit.anchor.height, moreOrLessEquals(glyph.height * scale));
    expect(hit.anchor.width, moreOrLessEquals(glyph.width * scale));
    // 下沿 = 字形真实下沿（弹窗贴着它往下摆，不能压进这一行）。
    expect(
      hit.anchor.bottom,
      moreOrLessEquals(paragraph.localToGlobal(glyph.bottomLeft).dy),
    );
  });

  group('卡面链接', () {
    final CardSourceLink link = CardSourceLink(
      kind: CardSourceKind.video,
      uid: 'video-uid',
      sourceId: CardSourceLink.newSourceId(),
      fingerprint: '0123456789abcdef' * 4,
      episodeIndex: 0,
      startMs: 1000,
      endMs: 2000,
    );

    test('Fushi 来源链接交给宿主并取消导航', () {
      final List<CardSourceLink> opened = <CardSourceLink>[];
      final NavigationActionPolicy policy = srsCardNavigationPolicy(
        link.toUri(),
        isForMainFrame: true,
        onSourceLink: opened.add,
      );
      expect(policy, NavigationActionPolicy.CANCEL);
      expect(opened.single.uid, 'video-uid');
      expect(opened.single.startMs, 1000);
    });

    test('其它链接不放行导航；外壳载入与子框架放行', () {
      NavigationActionPolicy of(String url, {bool main = true}) =>
          srsCardNavigationPolicy(Uri.parse(url), isForMainFrame: main);
      expect(of('https://example.com/'), NavigationActionPolicy.CANCEL);
      expect(of('fushi://source?bogus=1'), NavigationActionPolicy.CANCEL);
      expect(of('about:blank'), NavigationActionPolicy.ALLOW);
      expect(
        of('https://www.youtube.com/embed/x', main: false),
        NavigationActionPolicy.ALLOW,
      );
    });

    test('页内链接脚本只把 fushi://source 交回宿主', () {
      expect(kSrsCardLinkScript, contains("closest('a[href]')"));
      expect(kSrsCardLinkScript, contains('e.preventDefault()'));
      expect(kSrsCardLinkScript, contains(kSrsSourceLinkHandler));
    });
  });

  test('弹窗打开时按键闸：翻面 / 评分键吞掉，Esc 关一层；没开时不管', () {
    final SrsCardLookupController lookup = SrsCardLookupController(
      settings: () => (tap: true, hoverAuto: false),
    );
    addTearDown(lookup.dispose);
    expect(lookup.guardBridgeToken('Space'), isFalse);
    expect(srsLookupSwallowedKeys, contains(LogicalKeyboardKey.space));
    expect(srsLookupSwallowedKeys, contains(LogicalKeyboardKey.digit3));
    expect(srsLookupSwallowedKeys, contains(LogicalKeyboardKey.enter));
  });
}
