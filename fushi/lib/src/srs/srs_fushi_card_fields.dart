/// 「Fushi 卡片」原生渲染用的字段解析：只认有限的行内 HTML（b / strong / i / em / u / br /
/// ruby / rt / rp / span / div / p）与 Anki 振假名 `漢字[かな]`，解析不了的内容退回纯文本。
/// **不是**通用 HTML 渲染器：词典释义整块交给 WebView（见 srs_fushi_card_view.dart）。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一段行内文字（可带注音与强调）。`text == '\n'` 表示换行。
@immutable
class SrsInline {
  const SrsInline(
    this.text, {
    this.ruby,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final String text;
  final String? ruby;
  final bool bold;
  final bool italic;
  final bool underline;

  bool get isBreak => text == '\n' && ruby == null;

  /// 去掉注音（基字照常）。
  SrsInline withoutRuby() =>
      SrsInline(text, bold: bold, italic: italic, underline: underline);

  SrsInline copyWith({String? text, String? ruby}) => SrsInline(
    text ?? this.text,
    ruby: ruby ?? this.ruby,
    bold: bold,
    italic: italic,
    underline: underline,
  );

  @override
  bool operator ==(Object other) =>
      other is SrsInline &&
      other.text == text &&
      other.ruby == ruby &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline;

  @override
  int get hashCode => Object.hash(text, ruby, bold, italic, underline);

  @override
  String toString() =>
      '${bold ? '*' : ''}$text${ruby == null ? '' : '[$ruby]'}${bold ? '*' : ''}';
}

const Set<String> _allowedTags = <String>{
  'b',
  'strong',
  'i',
  'em',
  'u',
  'br',
  'ruby',
  'rb',
  'rt',
  'rp',
  'span',
  'div',
  'p',
  'font',
};
const Set<String> _blockTags = <String>{'div', 'p'};

final RegExp _tag = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>');
final RegExp _sound = RegExp(r'\[sound:([^\]]+)\]');
final RegExp _ankiFurigana = RegExp(r' ?([^ >\[\]\n]+?)\[([^\]\[]+?)\]');

/// HTML 实体（常见几个 + 数字实体）。
String srsDecodeEntities(String s) => s
    .replaceAllMapped(
      RegExp(r'&#(x?)([0-9a-fA-F]+);'),
      (Match m) => String.fromCharCode(
        int.parse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16),
      ),
    )
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// 去掉全部标签（`<br>` 与块级标签换成换行）、去掉 `[sound:]`、解实体、收空白。
String srsPlainText(String html) => srsDecodeEntities(
  html
      .replaceAll(_sound, '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(div|p|li)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ''),
).replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{2,}'), '\n').trim();

/// 字段里的 `[sound:x]` 文件名（按出现顺序）。
List<String> srsSoundNames(String field) => <String>[
  for (final Match m in _sound.allMatches(field)) m.group(1)!.trim(),
];

/// 视频片段的扩展名：Picture 字段里的 `[sound:x.mp4]`（MP4 片段，Anki 惯例）按视频算。
const Set<String> kSrsVideoExtensions = <String>{
  'webm',
  'mp4',
  'm4v',
  'mov',
  'mkv',
};

/// [name] 是不是视频文件（按扩展名）。
bool srsIsVideoName(String name) {
  final int dot = name.lastIndexOf('.');
  return dot >= 0 &&
      kSrsVideoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

final RegExp _mediaTagSrc = RegExp(
  r'''<(audio|video)\b[^>]*?\ssrc\s*=\s*(["'])([^"']*)\2''',
  caseSensitive: false,
);

/// 字段里 `[sound:x]` 与 `<audio|video src>` 的文件名，按出现顺序、去重（制卡内嵌的
/// 单词 / 句子音频是 `<audio class="fushi-*-audio" src>`，WebM 片段是 `<video src>`）。
/// [tags] 限定取哪几种标签；`[sound:]` 总是算上。
List<String> _mediaNames(String html, Set<String> tags) {
  final List<(int, String)> found = <(int, String)>[
    for (final Match m in _sound.allMatches(html))
      (m.start, m.group(1)!.trim()),
    for (final Match m in _mediaTagSrc.allMatches(html))
      if (tags.contains(m.group(1)!.toLowerCase()))
        (m.start, srsDecodeEntities(m.group(3)!).trim()),
  ]..sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
  final Set<String> seen = <String>{};
  return <String>[
    for (final (int, String) f in found)
      if (f.$2.isNotEmpty && seen.add(f.$2)) f.$2,
  ];
}

/// 音频字段里能播的文件：`[sound:x]` 与 `<audio src>`，按出现顺序、去重。
List<String> srsAudioSources(String field) =>
    _mediaNames(field, const <String>{'audio'});

/// Picture 字段里的视频片段：`<video src>`（WebM 内嵌）与视频扩展名的 `[sound:]`（MP4）。
List<String> srsVideoSources(String html) => <String>[
  for (final String name in _mediaNames(html, const <String>{'video'}))
    if (srsIsVideoName(name)) name,
];

/// 字段里 `<img src>` 的值（按出现顺序，实体已解）。
List<String> srsImageSources(String html) => <String>[
  for (final Match m in RegExp(
    r'''<img\b[^>]*?\ssrc\s*=\s*(["'])([^"']*)\1''',
    caseSensitive: false,
  ).allMatches(html))
    srsDecodeEntities(m.group(2)!),
];

/// 把一段纯文本里的 Anki 振假名 `漢字[かな]` 拆成带注音的段。
List<SrsInline> _splitAnkiFurigana(SrsInline base) {
  final String text = base.text;
  if (!text.contains('[')) return <SrsInline>[base];
  final List<SrsInline> out = <SrsInline>[];
  int last = 0;
  for (final Match m in _ankiFurigana.allMatches(text)) {
    final String ruby = m.group(2)!;
    if (ruby.startsWith('sound:')) continue;
    if (m.start > last) {
      out.add(base.copyWith(text: text.substring(last, m.start)));
    }
    out.add(base.copyWith(text: m.group(1)!, ruby: ruby));
    last = m.end;
  }
  if (last < text.length) out.add(base.copyWith(text: text.substring(last)));
  return out;
}

/// 解析一段行内 HTML。遇到白名单外的标签（img / a / table / script…）整段退回纯文本
/// （记一条日志），不尝试渲染。[ankiFurigana] 时把文字里的 `漢字[かな]` 拆成注音段。
List<SrsInline> srsParseInline(String html, {bool ankiFurigana = true}) {
  final String src = html.replaceAll(_sound, '').trim();
  if (src.isEmpty) return const <SrsInline>[];
  for (final Match m in _tag.allMatches(src)) {
    final String name = m.group(2)!.toLowerCase();
    if (!_allowedTags.contains(name)) {
      ErrorLogService.instance.log(
        'SrsFushiCard.parseInline',
        'unsupported <$name>, falling back to plain text',
        StackTrace.current,
      );
      final String plain = srsPlainText(src);
      return plain.isEmpty
          ? const <SrsInline>[]
          : _expand(<SrsInline>[SrsInline(plain)], ankiFurigana);
    }
  }
  final List<SrsInline> out = <SrsInline>[];
  int bold = 0, italic = 0, underline = 0;
  bool inRuby = false, inRt = false, inRp = false;
  final StringBuffer rubyBase = StringBuffer();
  final StringBuffer rubyText = StringBuffer();
  int last = 0;

  void emit(String raw) {
    if (raw.isEmpty) return;
    final String text = srsDecodeEntities(
      raw,
    ).replaceAll(RegExp(r'\s*\n\s*'), '');
    if (text.isEmpty) return;
    if (inRp) return;
    if (inRt) {
      rubyText.write(text);
      return;
    }
    if (inRuby) {
      rubyBase.write(text);
      return;
    }
    out.add(
      SrsInline(
        text,
        bold: bold > 0,
        italic: italic > 0,
        underline: underline > 0,
      ),
    );
  }

  void lineBreak() {
    if (out.isNotEmpty && !out.last.isBreak) out.add(const SrsInline('\n'));
  }

  for (final Match m in _tag.allMatches(src)) {
    emit(src.substring(last, m.start));
    last = m.end;
    final bool closing = m.group(1)!.isNotEmpty;
    final String name = m.group(2)!.toLowerCase();
    switch (name) {
      case 'b' || 'strong':
        bold += closing ? -1 : 1;
      case 'i' || 'em':
        italic += closing ? -1 : 1;
      case 'u':
        underline += closing ? -1 : 1;
      case 'br':
        lineBreak();
      case 'ruby':
        if (!closing) {
          inRuby = true;
          rubyBase.clear();
          rubyText.clear();
        } else {
          inRuby = false;
          inRt = false;
          if (rubyBase.isNotEmpty) {
            out.add(
              SrsInline(
                rubyBase.toString(),
                ruby: rubyText.isEmpty ? null : rubyText.toString(),
                bold: bold > 0,
                italic: italic > 0,
                underline: underline > 0,
              ),
            );
          }
        }
      case 'rt':
        inRt = !closing && inRuby;
      case 'rp':
        inRp = !closing;
      default:
        if (_blockTags.contains(name)) lineBreak();
    }
    if (bold < 0) bold = 0;
    if (italic < 0) italic = 0;
    if (underline < 0) underline = 0;
  }
  emit(src.substring(last));
  while (out.isNotEmpty && out.last.isBreak) {
    out.removeLast();
  }
  return _expand(out, ankiFurigana);
}

List<SrsInline> _expand(List<SrsInline> segs, bool ankiFurigana) => ankiFurigana
    ? <SrsInline>[
        for (final SrsInline s in segs)
          if (s.ruby == null && !s.isBreak) ..._splitAnkiFurigana(s) else s,
      ]
    : segs;

/// 段落的纯读音（有注音的取注音、没有的取原文）：Anki `kana:` 过滤器的等价物。
String srsKanaOf(List<SrsInline> segs) =>
    segs.map((SrsInline s) => s.ruby ?? s.text).join();

/// 音调字段（Yomitan 导出的 `<ul><li>[0]</li>…` 或带降调符的假名写法）→ 降调位置列表
/// （去重、保序）。与模板背面脚本 parsePitch 同一套规则。
List<int> srsPitchPositions(String field, String kana) {
  final String text = srsPlainText(field);
  final List<int> out = <int>[];
  for (final Match m in RegExp(r'\d+|[ぁ-ヺー\\＼ꜜ・]+').allMatches(text)) {
    final int? p = _parsePitch(m.group(0)!, kana);
    if (p != null && !out.contains(p)) out.add(p);
  }
  return out;
}

const String _small = 'ァィゥェォャュョヮぁぃぅぇぉゃゅょゎ゙゚°';

/// 读音拆拍（小写假名并入前一拍）。
List<String> srsMorae(String kana) {
  final List<String> out = <String>[];
  final List<String> chars = kana.split('');
  for (int i = 0; i < chars.length; i++) {
    String c = chars[i];
    if (i + 1 < chars.length && _small.contains(chars[i + 1])) {
      c += chars[i + 1];
      i++;
    }
    out.add(c);
  }
  return out;
}

String _toHira(String s) => String.fromCharCodes(
  s.runes.map((int r) => r >= 0x30A1 && r <= 0x30F6 ? r - 0x60 : r),
);

int? _parsePitch(String token, String kana) {
  final int? n = int.tryParse(token);
  if (n != null) return n;
  final String marked = token.replaceAll('・', '');
  final String plain = marked.replaceAll(RegExp(r'[\\＼ꜜ]'), '');
  if (_toHira(plain) != _toHira(kana)) return null;
  final int cut = marked.indexOf(RegExp(r'[\\＼ꜜ]'));
  return cut < 0 ? 0 : srsMorae(marked.substring(0, cut)).length;
}

/// 音调类型（与模板同名：heiban / atamadaka / nakadaka / odaka / kifuku）。
String srsPitchType(int position, int moraCount, String categories) {
  if (position == 0) return 'heiban';
  if (RegExp('kifuku').hasMatch(categories)) return 'kifuku';
  if (position == 1) return 'atamadaka';
  return position >= moraCount ? 'odaka' : 'nakadaka';
}

/// 字段是否「有内容」（Anki 条件段的判据：去掉空白后非空）。
bool srsFieldFilled(String? v) => (v ?? '').trim().isNotEmpty;

/// Anki `kanji:` 过滤器的等价物：去掉振假名 `[かな]` 与标签，只留基字。
String srsKanaFree(String field) => srsPlainText(
  field
      .replaceAll(_sound, '')
      .replaceAllMapped(
        _ankiFurigana,
        (Match m) =>
            m.group(2)!.startsWith('sound:') ? m.group(0)! : m.group(1)!,
      ),
);

/// 听音卡正面：例句里加粗的目标词遮成「［…］」（与模板 `.fc-front-sentence--masked` 同义）。
String srsMaskBold(String field) => srsKanaFree(
  field.replaceAll(
    RegExp(r'<(b|strong)\b[^>]*>.*?</\1>', caseSensitive: false),
    '［…］',
  ),
);

/// 词频字段（制卡写的是「一个值一个 `<li>词典名: 值</li>`」，与 Yomitan / Lapis 同形）→
/// 按词典合并的显示项：同一词典的多个值（普通形 + 假名形等）合成 `词典名: 值1, 值2`，
/// 与查词弹窗「词频聚合」关闭时的分组一致。词典名按**最后一个** `: ` 切（名字里可以带
/// 冒号，值里不会有）；切不出词典名的项原样单列。顺序按词典第一次出现。
List<String> srsFrequencyGroups(String html) {
  final Map<String, List<String>> byDict = <String, List<String>>{};
  final List<String> order = <String>[];
  for (final String item in srsListItems(html)) {
    final int cut = item.lastIndexOf(': ');
    if (cut <= 0 || cut + 2 >= item.length) {
      order.add('\u0000$item');
      continue;
    }
    final String dict = item.substring(0, cut).trim();
    final String value = item.substring(cut + 2).trim();
    final List<String>? values = byDict[dict];
    if (values == null) {
      byDict[dict] = <String>[value];
      order.add(dict);
    } else if (!values.contains(value)) {
      values.add(value);
    }
  }
  return <String>[
    for (final String key in order)
      key.startsWith('\u0000')
          ? key.substring(1)
          : '$key: ${byDict[key]!.join(', ')}',
  ];
}

/// `<li>` 列表 → 各项纯文本（词频字段等）；没有 `<li>` 时按行切。
List<String> srsListItems(String html) {
  final List<String> items = <String>[
    for (final Match m in RegExp(
      r'<li\b[^>]*>([\s\S]*?)</li>',
      caseSensitive: false,
    ).allMatches(html))
      srsPlainText(m.group(1)!),
  ].where((String s) => s.isNotEmpty).toList();
  if (items.isNotEmpty) return items;
  return srsPlainText(html)
      .split('\n')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
}
