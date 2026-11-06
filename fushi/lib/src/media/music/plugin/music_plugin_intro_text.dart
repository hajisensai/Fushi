/// 在线音乐插件给的简介文本（艺人简介 / 分段介绍、专辑 / 歌单简介）→ 可排版的块。
///
/// 插件原样转交平台文本，里面常夹着平台自己的轻量标记：网易云的外文艺人简介整段是从
/// 百科搬来的，段落标题写成 `<h>History </h>`，偶尔还有 `<br>`、`<p>`、`&amp;` 之类。
/// 页面不渲染 HTML，过去把这些标记原样画了出来。这里只认「标题」与「换行」两种结构，
/// 其余标签一律剥掉（插件文本是不可信数据，不当 HTML 执行或渲染）。
library;

/// 一块简介：小标题或一段正文。
sealed class MusicIntroBlock {
  const MusicIntroBlock(this.text);

  final String text;
}

/// 段落小标题（`<h>…</h>` / `<h1>…</h1>` …）。
final class MusicIntroHeading extends MusicIntroBlock {
  const MusicIntroHeading(super.text);
}

/// 一段正文（段内的单换行保留：百科信息框那种「键 / 值」逐行排的内容靠它分行）。
final class MusicIntroParagraph extends MusicIntroBlock {
  const MusicIntroParagraph(super.text);
}

final RegExp _heading = RegExp(
  r'<h[1-6]?\b[^>]*>(.*?)</h[1-6]?\s*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _lineBreak = RegExp(
  r'<br\s*/?>|</p\s*>|</div\s*>|</li\s*>',
  caseSensitive: false,
);
final RegExp _anyTag = RegExp(r'</?[a-zA-Z][^>]*>');
final RegExp _blankLines = RegExp(r'\n[ \t　]*\n+');
final RegExp _spaces = RegExp(r'[ \t ]+');

const Map<String, String> _entities = <String, String>{
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&nbsp;': ' ',
};

/// 去掉标签、解码常见实体、规整空白，保留换行。
String _plain(String s) {
  String out = s.replaceAll(_lineBreak, '\n').replaceAll(_anyTag, '');
  _entities.forEach((String k, String v) => out = out.replaceAll(k, v));
  return out
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((String line) => line.replaceAll(_spaces, ' ').trim())
      .join('\n');
}

/// 把 [paragraphText] 按空行切成正文块（空块丢掉）。
Iterable<MusicIntroParagraph> _paragraphs(String paragraphText) sync* {
  for (final String p in _plain(paragraphText).split(_blankLines)) {
    final String text = p.trim();
    if (text.isNotEmpty) yield MusicIntroParagraph(text);
  }
}

/// 解析一段插件简介。没有任何标记的纯文本就是一个或几个正文块。
List<MusicIntroBlock> parseMusicIntro(String raw) {
  final List<MusicIntroBlock> out = <MusicIntroBlock>[];
  int at = 0;
  for (final RegExpMatch m in _heading.allMatches(raw)) {
    out.addAll(_paragraphs(raw.substring(at, m.start)));
    final String title = _plain(m.group(1) ?? '').replaceAll('\n', ' ').trim();
    if (title.isNotEmpty) out.add(MusicIntroHeading(title));
    at = m.end;
  }
  out.addAll(_paragraphs(raw.substring(at)));
  return out;
}

/// 头部摘要至少要有这么长的一行才算「正文」（字符数，中日文同样计）。
const int kMusicIntroSummaryMinLine = 40;

/// 头部三行摘要：取第一段里第一行像样的正文。
///
/// 百科式简介开头是一张信息框（「Origin / Plano, Texas, US / Genres / …」逐行排），
/// 截前三行只会露出这些键名。所以跳过短行，取第一条不短于
/// [kMusicIntroSummaryMinLine] 的行；整段都没有长行时退回第一段原文。没有正文回 null。
String? musicIntroSummary(String raw) {
  final List<String> paragraphs = <String>[
    for (final MusicIntroBlock b in parseMusicIntro(raw))
      if (b is MusicIntroParagraph) b.text,
  ];
  if (paragraphs.isEmpty) return null;
  for (final String p in paragraphs) {
    for (final String line in p.split('\n')) {
      if (line.runes.length >= kMusicIntroSummaryMinLine) return line;
    }
  }
  return paragraphs.first;
}
