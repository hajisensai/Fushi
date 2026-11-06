import 'package:test/test.dart';

import 'package:fushi/src/srs/srs_html_card.dart';

/// Kaishi 1.5k（Anki 共享牌组，zh-CH 改版）的笔记类型 CSS 与一张卡的两面（引擎渲染结果原样）。
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

/* Prevents the furigana from being selected */
ruby > rt {
	user-select: none;
}

/* This part defines the bold color. */
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

<!-- This part enables pitch accent.

{{#Pitch Accent}}
    <br><div style='font-size: 24px'>{{Pitch Accent}}</div>
{{/Pitch Accent}}

-->

<div style='font-size: 25px; padding-bottom:20px'>搞错，弄错，混淆。</div>
<div style='font-size: 25px;'>やさしい<ruby><rb>問</rb><rt>もん</rt></ruby><ruby><rb>題</rb><rt>だい</rt></ruby>を<b><ruby><rb>間</rb><rt>ま</rt></ruby><ruby><rb>違</rb><rt>ちが</rt></ruby>えてしまいました</b>。</div>
<div style='font-size: 25px; padding-bottom:10px'>我把一个简单的问题做错了。</div>

[sound:200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3]
[sound:36738ea3ce3fb1f753fdff9e8f2bcc780c9fbba3.mp3]
<br>
<img src="36c069fec673d92a00e09c6c166dd8aeaa82f018.webp">

<!-- 新增内容开始：词性与活用（可折叠） -->

<div style="font-size: 20px; margin-bottom: 20px;">
    <details style="width: fit-content; margin: auto;">
        <summary style="cursor: pointer;">语法详情</summary>
        <div style="text-align: left; padding-top: 5px;">
            词性：动词
            <br>活用：～てしまいました<br>完了动作（遗憾/完成）的礼貌过去时。
            [sound:hidden.mp3]
        </div>
    </details>
</div>
''';

/// おにぎり文法：正面用 `<script>` 随机挑一条例句显示——原生不执行脚本，整张卡回退 WebView。
const String _grammarQuestion = '''
<div class="card-container">
    <div class="front-example-section">
        <div id="ex1" class="example-item" style="display: none;">
            <div class="sentence"><span class="sentence-text">天気は悪いです。<b>でも</b>、出かけます。</span>[sound:a.mp3]</div>
        </div>
    </div>
</div>
<script>
(function() { document.getElementById("ex1").style.display = "block"; })();
</script>''';

List<SrsHtmlNode> _flat(SrsHtmlBlock b) => <SrsHtmlNode>[
  b,
  for (final SrsHtmlNode c in b.children)
    if (c is SrsHtmlBlock) ..._flat(c) else c,
];

String _text(SrsHtmlFlow f) => f.inlines
    .map(
      (SrsHtmlInline r) => switch (r) {
        SrsHtmlTextRun(:final String text) => text,
        SrsHtmlRubyRun(:final String base, :final String reading) =>
          '$base($reading)',
        SrsHtmlBreakRun() => '\n',
        SrsHtmlSoundRun(:final String name) => '[$name]',
        SrsHtmlImageRun(:final String src) => '<$src>',
        SrsHtmlBoxRun() => '[box]',
      },
    )
    .join();

void main() {
  test('Kaishi：两面都原生；字号 / 对齐 / 注音 / 加粗色 / 发音 / 图片 / 折叠', () {
    final ({SrsHtmlCard? card, String? reason}) probe = srsHtmlCardProbe(
      question: _kaishiQuestion,
      answer: _kaishiAnswer,
      css: _kaishiCss,
      languageCode: 'ja',
    );
    expect(probe.reason, isNull);
    final SrsHtmlCard card = probe.card!;

    final SrsHtmlBlock front = card.question.layout(
      dark: false,
      foreground: 0xFF000000,
    );
    // body = .card：44px、居中，外壳 16px 内边距。
    expect(front.style.fontSize, 44);
    expect(front.style.textAlign, SrsHtmlTextAlign.center);
    expect(front.style.padding.first.value, 16);
    expect(front.style.fontFamilies.first, 'ヒラギノ角ゴ Pro W3');
    final List<SrsHtmlFlow> frontFlows = _flat(
      front,
    ).whereType<SrsHtmlFlow>().toList();
    expect(frontFlows.map(_text), <String>['間違える', 'やさしい問題を間違えてしまいました。']);
    final SrsHtmlTextRun bold = frontFlows[1].inlines
        .whereType<SrsHtmlTextRun>()
        .firstWhere((SrsHtmlTextRun r) => r.text == '間違えてしまいました');
    expect(bold.style.color, 0xFF5586CD);
    expect(bold.style.fontWeight, 700);
    expect(bold.style.fontSize, 20);

    final SrsHtmlBlock back = card.answer.layout(
      dark: true,
      foreground: 0xFFFFFFFF,
    );
    final List<SrsHtmlNode> nodes = _flat(back);
    final List<String> texts = nodes
        .whereType<SrsHtmlFlow>()
        .map(_text)
        .toList();
    expect(texts.first, '間(ま)違(ちが)える');
    expect(texts, contains('やさしい問(もん)題(だい)を間(ま)違(ちが)えてしまいました。'));
    expect(
      texts,
      contains(
        '[200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3] '
        '[36738ea3ce3fb1f753fdff9e8f2bcc780c9fbba3.mp3]\n'
        '<36c069fec673d92a00e09c6c166dd8aeaa82f018.webp>',
      ),
    );
    final SrsHtmlBlock details = nodes.whereType<SrsHtmlBlock>().firstWhere(
      (SrsHtmlBlock b) => b.isDetails,
    );
    expect(details.detailsOpen, isFalse);
    expect(details.style.fitContent, isTrue);
    expect(details.style.margin[1], isNull, reason: 'margin: auto');
    expect(_text(details.summary!.children.single as SrsHtmlFlow), '语法详情');
    final SrsHtmlImageRun img = nodes
        .whereType<SrsHtmlFlow>()
        .expand((SrsHtmlFlow f) => f.inlines)
        .whereType<SrsHtmlImageRun>()
        .single;
    expect(img.style.maxWidth, const SrsCssLength(300, SrsCssUnit.px));
    expect(img.style.maxHeight, const SrsCssLength(250, SrsCssUnit.px));
    // 收起的 <details> 里的发音不算看得见。
    expect(srsHtmlVisibleSounds(back), <String>[
      '200e62d2f47316e253cd425e69a84f86e4ab33a9.mp3',
      '36738ea3ce3fb1f753fdff9e8f2bcc780c9fbba3.mp3',
    ]);
  });

  test('卡面图片大小设置（宿主 !important 样式）压过模板的 img 限制', () {
    final SrsHtmlCard card = srsHtmlCardOf(
      question: _kaishiQuestion,
      answer: _kaishiAnswer,
      css: _kaishiCss,
    )!;
    final SrsHtmlBlock back = card.answer.layout(
      dark: false,
      foreground: 0xFF000000,
      hostCss:
          '.card img{max-width:100%!important;max-height:none!important;'
          'height:auto!important;}',
    );
    final SrsHtmlImageRun img = _flat(back)
        .whereType<SrsHtmlFlow>()
        .expand((SrsHtmlFlow f) => f.inlines)
        .whereType<SrsHtmlImageRun>()
        .single;
    expect(img.style.maxWidth, const SrsCssLength(100, SrsCssUnit.percent));
    expect(img.style.maxHeight, isNull);
  });

  test('脚本 / 事件属性 / 表格 / 未知属性 / at-rule：整张卡回退', () {
    String? reason(String html, [String css = '']) =>
        srsHtmlCardProbe(question: html, answer: html, css: css).reason;
    expect(reason(_grammarQuestion), contains('<script>'));
    expect(reason('<a href="x" onclick="go()">x</a>'), contains('onclick'));
    expect(reason('<table><tr><td>1</td></tr></table>'), contains('<table>'));
    expect(
      reason('<div style="position:absolute">x</div>'),
      contains('position'),
    );
    expect(
      reason('x', '@media (max-width: 600px) { .card { color: red } }'),
      contains('@media'),
    );
    expect(reason('<img src="https://example.com/a.png">'), contains('remote'));
    expect(reason('<img src="a.svg">'), isNotNull);
    expect(reason('<div style="color: frobnicate">x</div>'), contains('color'));
    expect(reason('<span><div>块</div></span>'), contains('inside inline'));
  });

  test('样式表里画不了的声明只在规则命中元素时才回退', () {
    String? reason(String html, String css) =>
        srsHtmlCardProbe(question: html, answer: html, css: css).reason;
    // 「JLPT N1 真题」牌组：卡面没有表格，却带 table 规则。
    const String css =
        'table { border-collapse: collapse; width: 100%; } .q { color: #333 }';
    expect(reason('<div class="q">問題</div>', css), isNull);
    // 命中了照旧回退，原因不变。
    expect(
      reason('<div class="t">x</div>', '.t { border-collapse: collapse }'),
      contains('border-collapse'),
    );
    expect(
      reason('<div class="q">x</div>', '.q { color: frobnicate }'),
      contains('color'),
    );
    // 行内样式本来就命中自己的元素：仍立即判。
    expect(
      reason('<div style="border-collapse: collapse">x</div>', ''),
      contains('border-collapse'),
    );
  });

  test('属性名混进非法字符（字段手误）：浏览器丢掉，原生同样忽略', () {
    expect(
      srsHtmlCardProbe(
        question: '<div style="”text-align: left; color: red">x</div>',
        answer: '<div style="”text-align: left">x</div>',
        css: '.a { ”margin: 0 }',
      ).reason,
      isNull,
    );
  });

  test('交互伪类 / 渲染提示属性忽略，不影响原生', () {
    expect(
      srsHtmlCardProbe(
        question: '<span class="a">x</span>',
        answer: '<span class="a">x</span>',
        css:
            '.a:hover{color:red} .a{cursor:pointer;transition:all .2s;'
            '-webkit-font-smoothing:antialiased} ::selection{color:red}',
      ).reason,
      isNull,
    );
  });

  test('自定义属性按继承解析；夜间类名切换变量', () {
    const String css = '''
.card { --fg: #111111; color: var(--fg); }
.card.nightMode { --fg: #eeeeee; }
.tag { background-color: var(--accent, #007aff); padding: 3px 9px; border-radius: 12px; }
''';
    final SrsHtmlCard card = srsHtmlCardOf(
      question: '<span class="tag">N5</span>',
      answer: '<span class="tag">N5</span>',
      css: css,
    )!;
    final SrsHtmlBlock light = card.question.layout(
      dark: false,
      foreground: 0xFF000000,
    );
    final SrsHtmlBlock dark = card.question.layout(
      dark: true,
      foreground: 0xFFFFFFFF,
    );
    expect(light.style.color, 0xFF111111);
    expect(dark.style.color, 0xFFEEEEEE);
    final SrsHtmlBlock qa = light.children.single as SrsHtmlBlock;
    final SrsHtmlBoxRun tag =
        (qa.children.single as SrsHtmlFlow).inlines.single as SrsHtmlBoxRun;
    expect(tag.box.style.background, 0xFF007AFF);
    expect(tag.box.style.radius, 12);
    expect(tag.box.style.padding[1].value, 9);
  });

  test('特异度与 !important：id > class > 标签，行内样式最高，important 反转', () {
    const String css = '''
#x { color: #000001; }
.c { color: #000002 !important; }
div { color: #000003; }
''';
    final SrsHtmlCard card = srsHtmlCardOf(
      question:
          '<div id="x" class="c" style="color:#000004">t</div>'
          '<div id="x">u</div>',
      answer: 'a',
      css: css,
    )!;
    final SrsHtmlBlock root = card.question.layout(
      dark: false,
      foreground: 0xFF000000,
    );
    final List<SrsHtmlBlock> divs = _flat(root)
        .whereType<SrsHtmlBlock>()
        .where((SrsHtmlBlock b) => b.tag == 'div')
        .toList();
    // #qa 自己也是 div（Anki reviewer 的 DOM 契约）。
    expect(divs.map((SrsHtmlBlock b) => b.style.color).skip(1), <int>[
      0xFF000002,
      0xFF000001,
    ]);
  });

  test('display:none 里的发音不算；空白折叠与 <br>', () {
    final SrsHtmlCard card = srsHtmlCardOf(
      question:
          '<div style="display:none">[sound:a.mp3]</div>  前\n  后 <br>  下一行 [sound:b.mp3]',
      answer: 'x',
      css: '',
    )!;
    final SrsHtmlBlock root = card.question.layout(
      dark: false,
      foreground: 0xFF000000,
    );
    expect(srsHtmlVisibleSounds(root), <String>['b.mp3']);
    expect(
      _text(_flat(root).whereType<SrsHtmlFlow>().single),
      '前 后\n下一行 [b.mp3]',
    );
  });
}
