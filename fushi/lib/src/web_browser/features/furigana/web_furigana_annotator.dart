/// 整页注音的纯逻辑层（无 Flutter / 无 WebView，可直接单测）。
///
/// 数据流：页内脚本把一批可见文本节点的文字一次 `callHandler` 送上来 →
/// [WebFuriganaAnnotator.annotate] 用**阅读器 / 浏览器扩展同一个分词器**
/// （`JapaneseLanguage.textsToWordsWithReadingsInBackground`：一次 FFI 切完整批，
/// 跑在后台 isolate）切词取读音 → 每段文字回一份紧凑的词序列
/// （[encodeWebFuriganaToken]），页内脚本据此替换文本节点。
///
/// 这里不另造分词：切分规则、读音全部来自词典引擎；本文件只做「读音怎么落到汉字上」
/// （[alignFurigana]）与批处理切分。
library;

/// 注音的一段：[base] 是正文片段，[ruby] 是它上方的读音（空串 = 这段不注音，送假名等）。
typedef WebRubyPart = ({String base, String ruby});

/// 分词器签名：与 `JapaneseLanguage.textsToWordsWithReadingsInBackground` 同形。
typedef WebFuriganaTokenizer =
    Future<List<List<({String text, String reading})>>> Function(
      List<String> texts,
    );

/// 一个注音后的词（编码前的形态）。
typedef WebFuriganaToken = ({String text, List<WebRubyPart>? ruby});

/// 一批里单段文字的上限（码元）。超过的段原样不注音（页内脚本也按同一上限过滤）。
const int kWebFuriganaMaxItemChars = 4000;

/// 一次分词调用的上限：段数 / 总字数，超过就切成几次分词调用（每次仍是一次 FFI）。
const int kWebFuriganaMaxBatchItems = 80;
const int kWebFuriganaMaxBatchChars = 12000;

final RegExp _kanji = RegExp(r'[㐀-䶿一-鿿豈-﫿々〆ヶ]');
final RegExp _kanaOnly = RegExp(r'^[ぁ-ゖァ-ヺー]+$');

/// 是否含汉字（含「々」等汉字类记号）。只有含汉字的词才注音。
bool containsKanji(String s) => _kanji.hasMatch(s);

/// 片假名 → 平假名（其余字符原样）。读音比对一律在平假名上做。
String katakanaToHiragana(String s) {
  final StringBuffer sb = StringBuffer();
  for (final int c in s.runes) {
    if (c >= 0x30a1 && c <= 0x30f6) {
      sb.writeCharCode(c - 0x60);
    } else {
      sb.writeCharCode(c);
    }
  }
  return sb.toString();
}

bool _isKana(int c) =>
    (c >= 0x3041 && c <= 0x3096) || (c >= 0x30a1 && c <= 0x30fa) || c == 0x30fc;

/// 把 [surface] 切成「汉字段 / 假名段」交替的序列（按码点）。
List<({String text, bool kana})> _runs(String surface) {
  final List<({String text, bool kana})> out = <({String text, bool kana})>[];
  final StringBuffer buf = StringBuffer();
  bool? kana;
  for (final int c in surface.runes) {
    final bool k = _isKana(c);
    if (kana != null && k != kana) {
      out.add((text: buf.toString(), kana: kana));
      buf.clear();
    }
    kana = k;
    buf.writeCharCode(c);
  }
  if (kana != null && buf.isNotEmpty) {
    out.add((text: buf.toString(), kana: kana));
  }
  return out;
}

/// 读音落到汉字上：返回逐段的 `(正文, 读音)`；对不上时返回 null（宁可不注音，
/// 也不把读音标错位）。
///
/// - 先整词对齐：假名段按字面、汉字段各吃至少一个读音字，锚定整串
///   （`見送る` / `みおくる` → 見[み]送[おく]る）。
/// - 不行再按「词典形读音 + 活用尾」对齐：分词器给的读音是词典里首条结果的读音，
///   活用形（`食べた` / `たべる`）尾巴对不上。去掉表层末尾的假名段，前面照常对齐，
///   只要求读音在对齐处的下一个字等于那段假名的首字（`食べた` → 食[た]べた）。
///   首字也对不上（`来た` / `くる`、`書いた` / `かく`）就放弃。
List<WebRubyPart>? alignFurigana(String surface, String reading) {
  if (surface.isEmpty || reading.isEmpty || !containsKanji(surface)) {
    return null;
  }
  final String r = katakanaToHiragana(reading);
  final List<({String text, bool kana})> runs = _runs(surface);
  final List<WebRubyPart>? whole = _alignRuns(runs, r, anchoredEnd: true);
  if (whole != null) return whole;
  if (runs.length < 2 || !runs.last.kana) return null;
  final List<({String text, bool kana})> core = runs.sublist(
    0,
    runs.length - 1,
  );
  final String tail = runs.last.text;
  final List<WebRubyPart>? head = _alignRuns(
    core,
    r,
    anchoredEnd: false,
    nextChar: katakanaToHiragana(String.fromCharCode(tail.runes.first)),
  );
  if (head == null) return null;
  return <WebRubyPart>[...head, (base: tail, ruby: '')];
}

List<WebRubyPart>? _alignRuns(
  List<({String text, bool kana})> runs,
  String reading, {
  required bool anchoredEnd,
  String? nextChar,
}) {
  final StringBuffer pattern = StringBuffer('^');
  for (final ({String text, bool kana}) run in runs) {
    if (run.kana) {
      pattern.write(RegExp.escape(katakanaToHiragana(run.text)));
    } else {
      pattern.write('(.+?)');
    }
  }
  if (anchoredEnd) {
    pattern.write(r'$');
  } else if (nextChar != null) {
    pattern.write('(?=${RegExp.escape(nextChar)})');
  }
  final RegExpMatch? m = RegExp(pattern.toString()).firstMatch(reading);
  if (m == null) return null;
  final List<WebRubyPart> out = <WebRubyPart>[];
  int group = 1;
  for (final ({String text, bool kana}) run in runs) {
    if (run.kana) {
      out.add((base: run.text, ruby: ''));
    } else {
      final String ruby = m.group(group++) ?? '';
      // 读音与正文同形（「々」后面跟的重复读音之外的退化情况）不画注音。
      if (ruby.isEmpty || ruby == run.text) return null;
      out.add((base: run.text, ruby: ruby));
    }
  }
  return out;
}

/// 把一批段的长度切成若干次分词调用（每组 ≤ [maxItems] 段、≤ [maxChars] 字；单段超过
/// [maxChars] 时独占一组）。返回各组的段下标。
List<List<int>> splitWebFuriganaBatches(
  List<int> lengths, {
  int maxItems = kWebFuriganaMaxBatchItems,
  int maxChars = kWebFuriganaMaxBatchChars,
}) {
  final List<List<int>> out = <List<int>>[];
  List<int> current = <int>[];
  int chars = 0;
  for (int i = 0; i < lengths.length; i++) {
    final int len = lengths[i];
    if (current.isNotEmpty &&
        (current.length >= maxItems || chars + len > maxChars)) {
      out.add(current);
      current = <int>[];
      chars = 0;
    }
    current.add(i);
    chars += len;
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}

/// 编码给页内脚本：`[text]` / `[text, [base, rt, base, rt…]]`。
List<Object> encodeWebFuriganaToken(WebFuriganaToken token) {
  final List<WebRubyPart>? ruby = token.ruby;
  if (ruby == null) return <Object>[token.text];
  return <Object>[
    token.text,
    <String>[
      for (final WebRubyPart p in ruby) ...<String>[p.base, p.ruby],
    ],
  ];
}

/// 整批注音。永不抛给页内脚本：分词失败的段回空列表（脚本见到空列表就不动那个节点）。
class WebFuriganaAnnotator {
  WebFuriganaAnnotator({required this.tokenizer});

  final WebFuriganaTokenizer tokenizer;

  /// [texts] 与返回等长、按序对应；每段是编码好的词序列（见 [encodeWebFuriganaToken]）。
  /// 相邻的不注音的词合并成一段，减少回传与页内建节点的数量。
  Future<List<List<List<Object>>>> annotate(List<String> texts) async {
    final List<List<({String text, String reading})>?> segmented =
        List<List<({String text, String reading})>?>.filled(texts.length, null);
    final List<int> lengths = <int>[
      for (final String s in texts)
        s.length > kWebFuriganaMaxItemChars ? 0 : s.length,
    ];
    for (final List<int> group in splitWebFuriganaBatches(lengths)) {
      final List<int> live = <int>[
        for (final int i in group)
          if (lengths[i] > 0) i,
      ];
      if (live.isEmpty) continue;
      final List<List<({String text, String reading})>> result =
          await tokenizer(<String>[for (final int i in live) texts[i]]);
      for (int k = 0; k < live.length && k < result.length; k++) {
        segmented[live[k]] = result[k];
      }
    }

    return <List<List<Object>>>[
      for (final List<({String text, String reading})>? segs in segmented)
        segs == null ? const <List<Object>>[] : _encodeSegments(segs),
    ];
  }

  static List<List<Object>> _encodeSegments(
    List<({String text, String reading})> segs,
  ) {
    final List<List<Object>> out = <List<Object>>[];
    final StringBuffer plain = StringBuffer();
    void flushPlain() {
      if (plain.isEmpty) return;
      out.add(<Object>[plain.toString()]);
      plain.clear();
    }

    for (final ({String text, String reading}) s in segs) {
      final List<WebRubyPart>? ruby = _kanaOnly.hasMatch(s.text)
          ? null
          : alignFurigana(s.text, s.reading);
      if (ruby == null) {
        plain.write(s.text);
        continue;
      }
      flushPlain();
      out.add(encodeWebFuriganaToken((text: s.text, ruby: ruby)));
    }
    flushPlain();
    return out;
  }
}
