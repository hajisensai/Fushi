// 非 Fushi 卡片的原生卡面（SrsHtmlCardView）：Kaishi 1.5k 的真实卡面两面都原生画出——
// 文字 / 注音 / 加粗色 / 发音键（交给宿主播放序列）/ <details> 点开。
//
// 设了 FUSHI_SRS_HTML_SHOTS_OUT 时另出真实像素截图（字体用 Windows 字体目录里的 Noto Sans JP，
// 图片取 FUSHI_SRS_HTML_SHOTS_MEDIA 媒体目录），平时这一组空跑。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_html_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_html_card.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _App extends AppModel {
  _App(this.appearance) : super(testPlatformServices());

  final SrsCardAppearance appearance;

  @override
  SrsCardAppearance get srsCardAppearance => appearance;
}

const String _kaishiCss = '''
.card {
 font-family: "ヒラギノ角ゴ Pro W3", "Hiragino Kaku Gothic Pro", "Noto Sans JP", "Noto Sans CJK JP", Osaka, "メイリオ", Meiryo, "ＭＳ Ｐゴシック", "MS PGothic", "MS UI Gothic", sans-serif;
 font-size: 44px;
 text-align: center;
}
img {
max-width: 300px;
max-height: 250px;
}
.mobile img {
max-width: 50vw;
}
ruby > rt {
	user-select: none;
}
b{color: #5586cd}
''';

const String _kaishiQuestion = '''
<div lang="ja">
間違える
<div style='font-size: 20px;'>やさしい問題を<b>間違えてしまいました</b>。</div>
</div>''';

const String _kaishiAnswer = '''
<div lang="ja">
<ruby><rb>間</rb><rt>ま</rt></ruby><ruby><rb>違</rb><rt>ちが</rt></ruby>える

<!-- This part enables pitch accent. -->

<div style='font-size: 25px; padding-bottom:20px'>搞错，弄错，混淆。</div>
<div style='font-size: 25px;'>やさしい<ruby><rb>問</rb><rt>もん</rt></ruby><ruby><rb>題</rb><rt>だい</rt></ruby>を<b><ruby><rb>間</rb><rt>ま</rt></ruby><ruby><rb>違</rb><rt>ちが</rt></ruby>えてしまいました</b>。</div>
<div style='font-size: 25px; padding-bottom:10px'>我把一个简单的问题做错了。</div>

[sound:200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3]
[sound:36738ea3ce3fb1f753fdff9e8f2bcc780c9fbba3.mp3]
<br>
<img src="36c069fec673d92a00e09c6c166dd8aeaa82f018.webp">

<div style="font-size: 20px; margin-bottom: 20px;">
    <details style="width: fit-content; margin: auto;">
        <summary style="cursor: pointer;">语法详情</summary>
        <div style="text-align: left; padding-top: 5px;">
            词性：动词
            <br>活用：～てしまいました<br>完了动作（遗憾/完成）的礼貌过去时。
        </div>
    </details>
</div>
''';

/// おにぎり文法的背面（正面带 <script>，整张卡在复习页回退 WebView；这里只看 CSS 引擎
/// 对一份重度样式的还原程度，@font-face 去掉）。
const String _grammarCss = '''
:root {
    --font-jp-title: "YuKyokasho Yoko", "Source Han Serif JP", serif;
    --font-jp-body: "Hiragino Sans", "Yu Gothic", "Meiryo", sans-serif;
    --font-zh: "PingFang SC", "Microsoft YaHei", sans-serif;
}
.card {
    --bg-color: #f7f8fa; --card-bg-color: #ffffff; --text-color: #2c3e50;
    --text-color-subtle: #7f8c8d; --primary-color: #007aff; --primary-color-b: #007aff;
    --border-color: #e5e7eb; --shadow-color: rgba(44, 62, 80, 0.08);
}
.card.nightMode {
    --bg-color: #212121; --card-bg-color: #2a2a2a; --text-color: #f1f1f1;
    --text-color-subtle: #a0a0a0; --primary-color: #58a6ff; --primary-color-b: #80bfff;
    --border-color: #3a3a3a; --shadow-color: rgba(0, 0, 0, 0.4);
}
.card { font-family: var(--font-jp-body); font-size: 17px; text-align: left;
    color: var(--text-color); background-color: var(--bg-color); -webkit-font-smoothing: antialiased; }
.cn-font { font-family: var(--font-zh); }
.card-container { padding: 20px 25px; border: 1px solid var(--border-color); border-radius: 12px;
    background-color: var(--card-bg-color); box-shadow: 0 4px 15px var(--shadow-color);
    max-width: 95%; margin: 0 auto; }
hr { border: none; border-top: 1px solid var(--border-color); margin: 16px 0; }
.card-header { text-align: center; margin-bottom: 15px; }
.grammar-title { font-family: var(--font-jp-title); font-size: 30px; font-weight: 700; margin: 0 0 15px 0; }
.tag-container { display: flex; gap: 6px; justify-content: center; align-items: center; flex-wrap: wrap; }
.tag { font-family: var(--font-zh); font-size: 12px; font-weight: 500; padding: 3px 9px;
    border-radius: 12px; text-decoration: none; }
.tag-level { background-color: var(--primary-color); color: white; }
.tag-class, .tag-freq { background-color: var(--border-color); color: var(--text-color-subtle); }
.main-content { margin-top: 20px; }
.section { margin-bottom: 18px; }
.section:last-of-type { margin-bottom: 5px; }
.section-title { font-family: var(--font-zh); font-size: 20px; font-weight: 600; margin: 0 0 10px 0;
    padding-left: 10px; border-left: 3px solid var(--primary-color); color: var(--text-color); }
.usage-content, .description-jp { font-size: 16px; line-height: 1.65; }
.sentence { display: flex; justify-content: space-between; align-items: center; gap: 15px; }
.sentence-text { font-family: var(--font-jp-title); flex-grow: 1; font-size: 20px; line-height: 1.55; letter-spacing: 0.02em; }
.translation, .description-cn { font-size: 14px; color: var(--text-color-subtle); line-height: 1.6; }
.description-cn { margin-top: 8px; }
#back-examples-container .example { padding: 10px 0; border-bottom: 1px solid var(--border-color); }
#back-examples-container .example:first-of-type { padding-top: 0; }
#back-examples-container .example:last-of-type { border-bottom: none; }
b { color: var(--primary-color-b); font-weight: 600; }
''';

/// 「JLPT N1 真题」牌组（用户真实牌组）的样式：带一条卡面用不上的 `table` 规则
/// （`border-collapse` 原生不画）——不命中元素就不该让整张卡回退。
const String _jlptCss = '''
.card { font-size: 18px; line-height: 1.65; color: #202124; background: #fafafa; }
.meta { color: #666; font-size: 13px; margin-bottom: 8px; }
.prompt { color: #333; border-left: 4px solid #6b8afd; padding-left: 10px; margin: 8px 0 12px; }
.question { font-weight: 600; margin: 12px 0; }
.answers { margin-top: 8px; }
.answer { background: #fff; border: 1px solid #d8d8d8; color: #202124; border-radius: 6px; padding: 7px 9px; margin: 6px 0; }
.answer-no { color: #555; font-weight: 700; }
.answer-box { background: #eef7ee; border-left: 4px solid #35a853; color: #202124; padding: 10px 12px; margin: 12px 0; }
.answer-title { font-weight: 700; }
.correct-text { margin-top: 4px; }
table { border-collapse: collapse; width: 100%; font-size: 0.92em; }
th, td { border: 1px solid #ccc; padding: 4px 6px; vertical-align: top; }
.card.nightMode, .nightMode .card { color: #f1f3f4; background: #242424; }
.card.nightMode .meta, .nightMode .card .meta { color: #bdc1c6; }
.card.nightMode .prompt, .nightMode .card .prompt { color: #e8eaed; border-left-color: #7aa2ff; }
.card.nightMode .answer, .nightMode .card .answer { background: #333538; border-color: #55585d; color: #f1f3f4; }
.card.nightMode .answer-no, .nightMode .card .answer-no { color: #d1d5db; }
.card.nightMode .answer-box, .nightMode .card .answer-box { background: #173421; border-left-color: #3fb950; color: #e6f4ea; }
''';

const String _jlptBack = '''
<div class="meta">202012 · 近义替换 · 問題3</div>
<div class="prompt">問題3___の言葉に意味が最も近いものを、1・2・3・4 から一つ選びなさい。</div>
<div class="question">15. 兄は手にした新聞の記事を<u>凝視した</u>。</div>
<div class="answers"><div class="answer"><span class="answer-no">1)</span> ざっと見た</div>
<div class="answer correct"><span class="answer-no">2)</span> じっと見た</div>
<div class="answer"><span class="answer-no">3)</span> ちらっと見た</div>
<div class="answer"><span class="answer-no">4)</span> ぼうっと見た</div></div>
<hr id="answer">
<div class="answer-box">
  <div class="answer-title" style="”text-align: left">正确答案：2</div>
  <div class="correct-text">じっと見た</div>
</div>
''';

const String _grammarBack = '''
<div class="card-container">
    <div class="card-header">
        <h1 class="grammar-title">でも</h1>
        <div class="tag-container">
            <span class="tag tag-level">N5</span>
            <span class="tag tag-class">对立</span>
            <span class="tag tag-freq">★★★</span>
        </div>
    </div>
    <hr>
    <div class="main-content">
        <div class="section">
            <h2 class="section-title">说明</h2>
            <div class="section-content">
                <div class="description-jp">「でも」は、前の文と後の文の内容が対立している場合に使用される接続詞です。</div>
                <div class="description-cn cn-font">「でも」是一个用于表达转折关系的连接词。</div>
            </div>
        </div>
        <div class="section">
            <h2 class="section-title">例句</h2>
            <div id="back-examples-container" class="section-content">
                <div class="example">
                    <div class="sentence"><span class="sentence-text">天気は悪いです。<b>でも</b>、出かけます。</span>[sound:be1ecdfa0f463724dea83155f637dfda5c2de407.mp3]</div>
                    <div class="translation cn-font">天气不好。不过我还是要出去。</div>
                </div>
                <div class="example">
                    <div class="sentence"><span class="sentence-text">彼は親切です。<b>でも</b>、時々厳しいです。</span>[sound:2f1da9a2e7647d1be2d3a9b459f4cb8a7bb44602.mp3]</div>
                    <div class="translation cn-font">他和蔼可亲，但也有严厉的时候。</div>
                </div>
            </div>
    </div>
</div>
''';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final FontLoader loader = FontLoader(family);
    for (final String path in paths) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      loader.addFont(
        Future<ByteData>.value(ByteData.sublistView(await f.readAsBytes())),
      );
    }
    await loader.load();
  }

  final String fonts =
      Platform.environment['FUSHI_SRS_SHOT_FONT_DIR'] ?? r'C:\Windows\Fonts';
  final String sep = Platform.pathSeparator;
  for (final String family in <String>['Roboto', '.SF Pro Text', 'Noto']) {
    await load(family, <String>[
      '$fonts${sep}NotoSansJP-Regular.otf',
      '$fonts${sep}NotoSansJP-Bold.otf',
      '$fonts${sep}NotoSansJP-VF.ttf',
    ]);
  }
  for (final String family in <String>['FushiSymbols', 'FushiSymbolsFilled']) {
    await load(family, <String>[
      'assets/icon_fonts/${family == 'FushiSymbols' ? 'FushiSymbolsRounded' : 'FushiSymbolsRoundedFilled'}.ttf',
    ]);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required SrsHtmlCardFace source,
  required bool answer,
  Size size = const Size(412, 915),
  bool dark = false,
  bool designSkin = true,
  SrsMediaStore? store,
  void Function(List<String>)? onPlayAudio,
  GlobalKey? boundary,
}) async {
  const double dpr = 2;
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF386A58),
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith(
          (Ref ref) => _App(SrsCardAppearance(designSkin: designSkin)),
        ),
        srsMediaStoreProvider.overrideWith((Ref ref) async => store),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildFushiThemeData(
            scheme: scheme,
            textTheme: dark
                ? Typography.material2021().white
                : Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: SafeArea(
                child: SrsHtmlCardView(
                  face: SrsCardFace(
                    cardId: 'c1',
                    showingAnswer: answer,
                    bodyHtml: '',
                    css: '',
                    languageCode: 'ja',
                    onBridgeKey: (_) {},
                    onPlayAudio: onPlayAudio,
                  ),
                  source: source,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
}

bool _hasText(String s) => find
    .byWidgetPredicate(
      (Widget w) =>
          w is RichText &&
          w.text.toPlainText(includeSemanticsLabels: false).contains(s),
    )
    .evaluate()
    .isNotEmpty;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  final SrsHtmlCard kaishi = srsHtmlCardOf(
    question: _kaishiQuestion,
    answer: _kaishiAnswer,
    css: _kaishiCss,
    languageCode: 'ja',
  )!;

  testWidgets('Kaishi 正面：词与例句原生画出', (WidgetTester tester) async {
    await _pump(tester, source: kaishi.question, answer: false);
    expect(tester.takeException(), isNull);
    expect(_hasText('間違える'), isTrue);
    expect(_hasText('間違えてしまいました'), isTrue);
  });

  testWidgets('Kaishi 背面：注音 / 发音键交给宿主 / <details> 点开', (
    WidgetTester tester,
  ) async {
    final List<List<String>> played = <List<String>>[];
    await _pump(
      tester,
      source: kaishi.answer,
      answer: true,
      onPlayAudio: played.add,
    );
    expect(tester.takeException(), isNull);
    // 注音段：基字与 <rt> 读音各是一段文字。
    expect(find.text('違'), findsWidgets);
    expect(find.text('ちが'), findsWidgets);
    expect(_hasText('搞错，弄错，混淆。'), isTrue);
    // 收起时看不到折叠内容。
    expect(_hasText('词性：动词'), isFalse);
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'srs-html-sound-200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3',
        ),
      ),
    );
    await tester.pump();
    expect(played, <List<String>>[
      <String>['200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3'],
    ]);
    await tester.ensureVisible(find.text('语法详情'));
    await tester.tap(find.text('语法详情'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_hasText('词性：动词'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色 + 关掉设计系统覆盖：模板加粗色原样', (WidgetTester tester) async {
    await _pump(
      tester,
      source: kaishi.question,
      answer: false,
      dark: true,
      designSkin: false,
    );
    expect(tester.takeException(), isNull);
    final RichText rt = tester.widget<RichText>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is RichText && w.text.toPlainText().contains('間違えてしまいました'),
      ),
    );
    Color? boldColor;
    rt.text.visitChildren((InlineSpan span) {
      if (span is TextSpan && span.text == '間違えてしまいました') {
        boldColor = span.style?.color;
        return false;
      }
      return true;
    });
    expect(boldColor, const Color(0xFF5586CD));
  });

  group('shots', () {
    final String? out = Platform.environment['FUSHI_SRS_HTML_SHOTS_OUT'];
    final String? media = Platform.environment['FUSHI_SRS_HTML_SHOTS_MEDIA'];
    if (out == null || out.isEmpty) {
      test('html card shots (only with FUSHI_SRS_HTML_SHOTS_OUT)', () {});
      return;
    }
    final SrsHtmlCardFace grammar = SrsHtmlCardFace.parse(
      _grammarBack,
      _grammarCss,
      languageCode: 'ja',
    );
    final SrsHtmlCardFace jlpt = srsHtmlCardOf(
      question: _jlptBack,
      answer: _jlptBack,
      css: _jlptCss,
      languageCode: 'ja',
    )!.answer;
    for (final (
          String name,
          SrsHtmlCardFace src,
          bool answer,
          bool dark,
          bool skin,
        )
        in <(String, SrsHtmlCardFace, bool, bool, bool)>[
          ('kaishi-front-light', kaishi.question, false, false, true),
          ('kaishi-back-light', kaishi.answer, true, false, true),
          ('kaishi-back-dark', kaishi.answer, true, true, true),
          ('kaishi-back-noskin', kaishi.answer, true, false, false),
          ('grammar-back-light', grammar, true, false, true),
          ('grammar-back-noskin', grammar, true, false, false),
          ('grammar-back-dark-noskin', grammar, true, true, false),
          ('jlpt-back-noskin', jlpt, true, false, false),
          ('jlpt-back-dark-noskin', jlpt, true, true, false),
          ('jlpt-back-light', jlpt, true, false, true),
        ]) {
      testWidgets('shot $name', (WidgetTester tester) async {
        await tester.runAsync(_loadFonts);
        final GlobalKey boundary = GlobalKey();
        await _pump(
          tester,
          source: src,
          answer: answer,
          dark: dark,
          designSkin: skin,
          store: media == null ? null : SrsMediaStore(Directory(media)),
          boundary: boundary,
        );
        // 图片解码要真异步（FakeAsync 里 FileImage 永远读不完）：先在真时钟里解好。
        for (int i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pump();
        }
        if (name == 'kaishi-back-light') {
          await tester.ensureVisible(find.text('语法详情'));
          await tester.tap(find.text('语法详情'));
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pumpAndSettle();
          final ScrollableState s = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          s.position.jumpTo(0);
          await tester.pump();
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final RenderRepaintBoundary rb =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final ui.Image image = await rb.toImage(pixelRatio: 2);
          final ByteData? png = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          Directory(out).createSync(recursive: true);
          File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  });
}
