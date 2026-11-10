// 卡面渲染器选择表：同一批输入在每个站点（复习页 / 浏览预览 / 外观页「我的卡」/ 笔记与模板编辑
// 预览宿主）选中哪套渲染器——Fushi 原生混合（fushi）、原生 HTML 卡面（html）、整面 WebView（web）。
//
// 这张表先在收口前的旧判据上钉死（各站点各写一份时的逻辑原样复刻在 `_site*`，提交 367d74c87ef），
// 收口成单一判据后 `_site*` 换成现在的调用、行与期望表不动，仍须全绿：证明收口不改任何一张卡最终
// 选中的渲染器。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_card_surface.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;

Map<String, String> _fields([Map<String, String> extra = const {}]) =>
    <String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      'Term': '通う',
      'TermReading': 'かよう',
      'Sentence': '学校に<b>通う</b>。',
      'TermAudio': '[sound:w.mp3]',
      'SentenceAudio': '[sound:s.mp3]',
      ...extra,
    };

const String _q = '<div class="front">表</div>';
const String _a =
    '<div class="front">表</div><hr id="answer"><div>裏 [sound:a.mp3]</div>';
const String _css = '.card{font-size:20px;color:#333;}';

SrsRenderedCard _card({
  String question = _q,
  String answer = _a,
  String css = _css,
  Map<String, String>? fields,
  String? defs,
  List<FushiCardItem>? front,
  List<FushiCardItem>? back,
}) => SrsRenderedCard(
  question: question,
  answer: answer,
  css: css,
  isEmpty: false,
  fields: fields ?? _fields(),
  fushiCardDefinitions: defs,
  fushiCardFront: front ?? const <FushiCardItem>[],
  fushiCardBack: back ?? const <FushiCardItem>[],
);

SrsRenderedCard _fushi({
  List<FushiCardItem>? back,
  Map<String, String>? fields,
  String question = _q,
  String answer = _a,
}) => _card(
  question: question,
  answer: answer,
  fields: fields,
  defs: '<div class="fc-defs">to commute</div>',
  front: kFushiCardDefaultFrontItems,
  back: back ?? kFushiCardDefaultBackItems,
);

List<FushiCardItem> _backWith(String html) => <FushiCardItem>[
  ...kFushiCardDefaultBackItems,
  FushiCardHtmlItem(html),
];

/// 一行输入：渲染好的卡（null = 还没读到）、笔记类型是不是内置 Fushi 卡片、默认内容语言。
typedef _Row = ({
  String name,
  SrsRenderedCard? rendered,
  bool fushiType,
  String lang,
});

final List<_Row> _rows = <_Row>[
  (name: '首张卡还没读到', rendered: null, fushiType: false, lang: 'ja'),
  (name: 'Fushi 卡片默认布局', rendered: _fushi(), fushiType: true, lang: 'ja'),
  (name: 'Fushi 卡片默认布局（无语言）', rendered: _fushi(), fushiType: true, lang: ''),
  (
    name: 'Fushi 卡片 + 行内样式 HTML 区块',
    rendered: _fushi(back: _backWith('<p style="color:red">自定义</p>')),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片 + 脚本 HTML 区块',
    rendered: _fushi(back: _backWith('<script>alert(1)</script>')),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片 + 表格 HTML 区块',
    rendered: _fushi(back: _backWith('<table><tr><td>x</td></tr></table>')),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片 + 定位 HTML 区块',
    rendered: _fushi(back: _backWith('<div style="position:absolute">x</div>')),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片 + 字段区块里有表格',
    rendered: _fushi(
      back: <FushiCardItem>[FushiCardFieldItem(field: 'MiscInfo')],
      fields: _fields(<String, String>{
        'MiscInfo': '<table><tr><td>x</td></tr></table>',
      }),
    ),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片 + 标签样式字段区块里有表格（不判）',
    rendered: _fushi(
      back: <FushiCardItem>[
        FushiCardFieldItem(field: 'MiscInfo', style: FushiCardFieldStyle.tag),
      ],
      fields: _fields(<String, String>{
        'MiscInfo': '<table><tr><td>x</td></tr></table>',
      }),
    ),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片模板改过（引擎没给释义区）、两面简单 HTML',
    rendered: _card(),
    fushiType: true,
    lang: 'ja',
  ),
  (
    name: 'Fushi 卡片模板改过、两面带脚本',
    rendered: _card(question: '<script>1</script>x'),
    fushiType: true,
    lang: 'ja',
  ),
  (name: '自建类型两面简单 HTML', rendered: _card(), fushiType: false, lang: 'ja'),
  (name: '自建类型两面简单 HTML（无语言）', rendered: _card(), fushiType: false, lang: ''),
  (
    name: '自建类型带脚本',
    rendered: _card(question: '<script>1</script>x'),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '自建类型带表格',
    rendered: _card(answer: '<table><tr><td>x</td></tr></table>'),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '自建类型带定位样式',
    rendered: _card(css: '.card{position:absolute;}'),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '自建类型带 <link>',
    rendered: _card(question: '<link rel="stylesheet" href="a.css">x'),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '自建类型空白两面',
    rendered: _card(question: '', answer: ''),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '非 Fushi 类型却带释义区（引擎给了就认）',
    rendered: _fushi(),
    fushiType: false,
    lang: 'ja',
  ),
  (
    name: '非 Fushi 类型带释义区、区块画不了、两面简单 HTML',
    rendered: _fushi(back: _backWith('<script>alert(1)</script>')),
    fushiType: false,
    lang: 'ja',
  ),
];

/// 期望表：行名 → 复习页 / 浏览预览 / 外观页「我的卡」/ 编辑预览宿主 各自选中的渲染器。
/// 外观页只预览 Fushi 卡片（「我的卡」取自 Fushi 卡片笔记类型），非 Fushi 行它不会遇到，记 `-`。
const Map<String, List<String>> _expected = <String, List<String>>{
  '首张卡还没读到': <String>['web', 'web', '-', 'web'],
  'Fushi 卡片默认布局': <String>['fushi', 'fushi', 'fushi', 'fushi'],
  'Fushi 卡片默认布局（无语言）': <String>['fushi', 'fushi', 'fushi', 'fushi'],
  'Fushi 卡片 + 行内样式 HTML 区块': <String>['fushi', 'fushi', 'fushi', 'fushi'],
  'Fushi 卡片 + 脚本 HTML 区块': <String>['web', 'web', 'web', 'web'],
  'Fushi 卡片 + 表格 HTML 区块': <String>['web', 'web', 'web', 'web'],
  'Fushi 卡片 + 定位 HTML 区块': <String>['web', 'web', 'web', 'web'],
  'Fushi 卡片 + 字段区块里有表格': <String>['web', 'web', 'web', 'web'],
  'Fushi 卡片 + 标签样式字段区块里有表格（不判）': <String>['fushi', 'fushi', 'fushi', 'fushi'],
  'Fushi 卡片模板改过（引擎没给释义区）、两面简单 HTML': <String>['web', 'web', 'web', 'web'],
  'Fushi 卡片模板改过、两面带脚本': <String>['web', 'web', 'web', 'web'],
  '自建类型两面简单 HTML': <String>['html', 'html', '-', 'html'],
  '自建类型两面简单 HTML（无语言）': <String>['html', 'html', '-', 'html'],
  '自建类型带脚本': <String>['web', 'web', '-', 'web'],
  '自建类型带表格': <String>['web', 'web', '-', 'web'],
  '自建类型带定位样式': <String>['web', 'web', '-', 'web'],
  '自建类型带 <link>': <String>['web', 'web', '-', 'web'],
  '自建类型空白两面': <String>['html', 'html', '-', 'html'],
  '非 Fushi 类型却带释义区（引擎给了就认）': <String>['fushi', 'fushi', '-', 'fushi'],
  '非 Fushi 类型带释义区、区块画不了、两面简单 HTML': <String>['html', 'html', '-', 'html'],
};

// ---- 各站点经唯一判据（srsCardSurfaceOf）选渲染器，输入与生产代码同形 ----
//
// 收口前这里是四个站点各自的旧判据原样复刻（提交 367d74c87ef，在旧代码上 21/21 绿）；收口后换成
// 各站点现在的调用方式，上面的行与期望表一字未改。

String _label(SrsCardSurface s) => switch (s.kind) {
  SrsCardSurfaceKind.fushiHybrid => 'fushi',
  SrsCardSurfaceKind.htmlNative => 'html',
  SrsCardSurfaceKind.webView => 'web',
};

/// 复习页 `_surfaceOf`：默认内容语言原样交进去（'' 由判据视同 null）。
String _siteReview(_Row r) => _label(
  srsCardSurfaceOfRendered(
    r.rendered,
    fushiCardType: r.fushiType,
    languageCode: r.lang,
  ),
);

/// 浏览预览：卡面语言（'' → null）。
String _siteBrowse(_Row r) => _label(
  srsCardSurfaceOfRendered(
    r.rendered,
    fushiCardType: r.fushiType,
    languageCode: r.lang.isEmpty ? null : r.lang,
  ),
);

/// 外观页 `_faceView`（「我的卡」）：卡面 `fushiCard: true`，原生 HTML 也落 WebView。
String _siteAppearanceMine(_Row r) {
  final SrsRenderedCard? rendered = r.rendered;
  if (rendered == null || !r.fushiType) return '-';
  final SrsCardSurface s = srsCardSurfaceOfRendered(
    rendered,
    fushiCardType: true,
    languageCode: r.lang.isEmpty ? null : r.lang,
  );
  return s is SrsFushiHybridSurface ? 'fushi' : 'web';
}

/// 笔记 / 模板编辑预览：候选（`srsFushiCardLayoutOfTemplate`，区块探测不带语言）交给
/// `SrsStablePreviewFace`，它按卡面语言判原生 HTML。
String _siteStablePreview(_Row r) {
  final SrsRenderedCard? rendered = r.rendered;
  if (rendered == null) return 'web';
  final SrsFushiCardLayout? candidate = SrsFushiCardLayout.ofRendered(rendered);
  return _label(
    srsCardSurfaceOf(
      fushiCardType: r.fushiType,
      fushiLayout: candidate,
      sides: (
        question: rendered.question,
        answer: rendered.answer,
        css: rendered.css,
      ),
      languageCode: r.lang.isEmpty ? null : r.lang,
    ),
  );
}

void main() {
  test('期望表覆盖每一行输入', () {
    expect(
      _expected.keys.toSet(),
      _rows.map((_Row r) => r.name).toSet(),
      reason: '行名与期望表一一对应',
    );
    expect(_rows.length, _expected.length);
  });

  for (final _Row row in _rows) {
    test('选择表：${row.name}', () {
      expect(<String>[
        _siteReview(row),
        _siteBrowse(row),
        _siteAppearanceMine(row),
        _siteStablePreview(row),
      ], _expected[row.name]);
    });
  }
}
