// 真实模板样本（卡面渲染器对照用，见 srs_card_renderer_parity_dump_test.dart）：
// - Kaishi 1.5k、おにぎり文法、JLPT N1 真题：用户真实牌组渲染后的卡面（与
//   srs_html_card_view_test.dart 里的同一批）；
// - Anki 自带的 Basic / Basic (and reversed card) / Basic (type in the answer) / Cloze 模板原文。
library;

const String kSampleKaishiCss = '''
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

const String kSampleKaishiQuestion = '''
<div lang="ja">
間違える
<div style='font-size: 20px;'>やさしい問題を<b>間違えてしまいました</b>。</div>
</div>''';

const String kSampleKaishiAnswer = '''
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
const String kSampleGrammarCss = '''
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
const String kSampleJlptCss = '''
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

const String kSampleJlptBack = '''
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

const String kSampleGrammarBack = '''
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

/// Anki 自带笔记类型的样式（Basic 系列共用）。
const String kSampleAnkiBasicCss = '''
.card {
    font-family: arial;
    font-size: 20px;
    text-align: center;
    color: black;
    background-color: white;
}
''';

const String kSampleAnkiBasicFront = '{{Front}}';
const String kSampleAnkiBasicBack = '''
{{FrontSide}}

<hr id=answer>

{{Back}}''';

/// Basic (and reversed card) 的第二张卡。
const String kSampleAnkiReversedFront = '{{Back}}';
const String kSampleAnkiReversedBack = '''
{{FrontSide}}

<hr id=answer>

{{Front}}''';

/// Basic (type in the answer)。
const String kSampleAnkiTypeFront = '''
{{Front}}

{{type:Back}}''';
const String kSampleAnkiTypeBack = '''
{{Front}}

<hr id=answer>

{{type:Back}}''';

/// Cloze。
const String kSampleAnkiClozeCss = '''
.card {
    font-family: arial;
    font-size: 20px;
    text-align: center;
    color: black;
    background-color: white;
}
.cloze {
    font-weight: bold;
    color: blue;
}
.nightMode .cloze {
    color: lightblue;
}
''';
const String kSampleAnkiClozeFront = '{{cloze:Text}}';
const String kSampleAnkiClozeBack = '''
{{cloze:Text}}<br>
{{Back Extra}}''';
