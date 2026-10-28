/// 把同一视频已有的 ASS 字幕（通常是别的语言的字幕组字幕）的样式与位置套到 AI
/// 生成的日语字幕上，导出 `<视频名>.<后缀>.ass`。
///
/// ```
/// 参考 ASS ─parseAssStyleReference─▶ 原样保留的头部段（[Script Info] / [V4+ Styles]
///                                      / [Fonts] …）+ 带时间的对白事件
/// 日语 cue ─按时间重叠挑参考事件─▶ 继承它的 Layer / Style / Name / Margin / Effect
///                                  + 行首覆盖标签（\an \pos \c \fad …）
/// ```
///
/// - 颜色、字体、描边、默认位置来自参考的 Style 行（整段原样拷贝，不改写）；
///   单行的位置 / 颜色来自参考事件行首的覆盖标签。
/// - 卡拉 OK（`\k` 系）、`\t` 动画、`\p` 绘图只对参考原文的字 / 时间有意义，换成
///   日语正文就错位，一律不继承；行中的覆盖块同理丢弃。
/// - 时间上找不到参考事件的日语行用参考里最常用的对白样式、不加覆盖标签。
/// - 选参考事件时，带 `\pos` / `\move` / `\clip` 的事件（多半是招牌、标题等排版）
///   降权：只有没有普通对白与它重叠时才继承它的位置。参考本身含日语（双语字幕）
///   时优先继承日语那一行的样式。
///
/// 纯函数，不碰文件系统；读文件 / 抽内嵌轨见 `subtitle_ass_style_reference_loader.dart`。
library;

/// 参考 ASS 至少要有这么多条可读对白，才当作有效的样式来源。
const int kAssStyleReferenceMinEvents = 10;

/// 日语行与参考事件的重叠至少占日语行时长的这个比例，才继承那条事件。
const double kAssStyleMinOverlapRatio = 0.3;

/// 一条参考对白事件（`Dialogue:` 行）。
class AssReferenceEvent {
  const AssReferenceEvent({
    required this.layer,
    required this.startMs,
    required this.endMs,
    required this.style,
    required this.name,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    required this.effect,
    required this.text,
  });

  final String layer;
  final int startMs;
  final int endMs;
  final String style;
  final String name;
  final String marginL;
  final String marginR;
  final String marginV;
  final String effect;

  /// Text 列原文（含覆盖标签）。
  final String text;

  /// 去掉覆盖标签与软换行后的正文。
  String get plainText => assPlainText(text);

  /// 是否是 `\p` 矢量绘图（招牌底板等，没有可读正文）。
  bool get isDrawing => _drawingTag.hasMatch(_overrideBlocks(text));

  /// 行首覆盖标签里是否带绝对定位 / 裁剪（排版类事件的特征）。
  bool get isPositioned =>
      _positionTag.hasMatch(assLeadingOverrideTags(text).join());
}

/// 解析好的参考 ASS。
class AssStyleReference {
  const AssStyleReference({
    required this.label,
    required this.headerSections,
    required this.events,
    required this.defaultStyle,
  });

  /// 给界面 / 日志看的来源（文件名或内嵌轨标签）。
  final String label;

  /// `[Events]` 以外的各段原文（含段标题行），按原文件顺序；`[Script Info]` 在首。
  final List<String> headerSections;

  /// 可读的对白事件（不含绘图、空行、`Comment:`），按开始时间稳定排序。
  final List<AssReferenceEvent> events;

  /// 没有可继承事件时用的样式：参考里对白事件最多的那个样式。
  final String defaultStyle;
}

/// 要导出的一条日语字幕。
class AssStyledCue {
  const AssStyledCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

/// 解析参考 ASS 原文。不是 ASS、没有样式段或可读对白不足
/// [kAssStyleReferenceMinEvents] 条时返回 null。
AssStyleReference? parseAssStyleReference(
  String content, {
  required String label,
}) {
  final List<String> lines = content
      .replaceFirst('\uFEFF', '')
      .split(RegExp(r'\r?\n'));
  final List<String> sections = <String>[];
  final List<AssReferenceEvent> events = <AssReferenceEvent>[];
  StringBuffer? current;
  bool inEvents = false;
  bool hasStyles = false;
  bool hasScriptInfo = false;
  List<String>? format;

  void flush() {
    final StringBuffer? buf = current;
    if (buf != null) sections.add(buf.toString().trimRight());
    current = null;
  }

  for (final String raw in lines) {
    final String line = raw.trimRight();
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      flush();
      final String header = trimmed.toLowerCase();
      inEvents = header == '[events]';
      if (inEvents) continue;
      if (header == '[v4+ styles]' || header == '[v4 styles]') {
        hasStyles = true;
      }
      if (header == '[script info]') hasScriptInfo = true;
      current = StringBuffer()..writeln(trimmed);
      continue;
    }
    if (inEvents) {
      final int colon = trimmed.indexOf(':');
      if (colon < 0) continue;
      final String key = trimmed.substring(0, colon).trim().toLowerCase();
      final String value = trimmed.substring(colon + 1).trimLeft();
      if (key == 'format') {
        format = <String>[
          for (final String f in value.split(',')) f.trim().toLowerCase(),
        ];
      } else if (key == 'dialogue' && format != null) {
        final AssReferenceEvent? e = _parseDialogue(value, format);
        if (e != null &&
            e.endMs > e.startMs &&
            !e.isDrawing &&
            e.plainText.isNotEmpty) {
          events.add(e);
        }
      }
      continue;
    }
    current?.writeln(line);
  }
  flush();

  if (!hasStyles || events.length < kAssStyleReferenceMinEvents) return null;
  if (!hasScriptInfo) {
    sections.insert(0, '[Script Info]\nScriptType: v4.00+');
  } else {
    // [Script Info] 必须在最前（libass 按它读 PlayResX/Y 再解析样式）。
    final int i = sections.indexWhere(
      (String s) => s.toLowerCase().startsWith('[script info]'),
    );
    if (i > 0) sections.insert(0, sections.removeAt(i));
  }
  // 稳定排序：同开始时间保持文件序（= libass 同层 z 序）。
  final List<(int, AssReferenceEvent)> indexed =
      <(int, AssReferenceEvent)>[
        for (int i = 0; i < events.length; i++) (i, events[i]),
      ]..sort(((int, AssReferenceEvent) a, (int, AssReferenceEvent) b) {
        final int c = a.$2.startMs.compareTo(b.$2.startMs);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
  return AssStyleReference(
    label: label,
    headerSections: sections,
    events: <AssReferenceEvent>[
      for (final (int, AssReferenceEvent) e in indexed) e.$2,
    ],
    defaultStyle: _dominantStyle(events),
  );
}

/// 按 [reference] 的样式把 [cues] 渲染成完整的 ASS 文本。
String renderAssWithReferenceStyle({
  required List<AssStyledCue> cues,
  required AssStyleReference reference,
}) {
  final Map<String, int> styleCounts = _styleCounts(reference.events);
  final StringBuffer out = StringBuffer();
  for (final String section in reference.headerSections) {
    out
      ..writeln(section)
      ..writeln();
  }
  out
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    );
  for (final AssStyledCue cue in cues) {
    final String text = _escapeAssText(cue.text);
    if (text.isEmpty) continue;
    final AssReferenceEvent? ref = pickAssReferenceEvent(
      startMs: cue.startMs,
      endMs: cue.endMs,
      events: reference.events,
      styleCounts: styleCounts,
    );
    final String tags = ref == null
        ? ''
        : _inheritableTags(assLeadingOverrideTags(ref.text));
    out.writeln(
      'Dialogue: ${ref?.layer ?? '0'},'
      '${formatAssTime(cue.startMs)},${formatAssTime(cue.endMs)},'
      '${ref?.style ?? reference.defaultStyle},${ref?.name ?? ''},'
      '${ref?.marginL ?? '0'},${ref?.marginR ?? '0'},${ref?.marginV ?? '0'},'
      '${ref?.effect ?? ''},'
      '${tags.isEmpty ? '' : '{$tags}'}$text',
    );
  }
  return out.toString();
}

/// 给 `[startMs, endMs)` 的日语行挑要继承的参考事件；没有足够重叠的返回 null。
///
/// 得分 = 重叠毫秒 × 权重：排版类事件（[AssReferenceEvent.isPositioned]）×0.25，
/// 正文含假名的事件 ×1.5（双语字幕里日语那一行）；同分取样式更常用的、再取文件序靠前的。
AssReferenceEvent? pickAssReferenceEvent({
  required int startMs,
  required int endMs,
  required List<AssReferenceEvent> events,
  Map<String, int>? styleCounts,
}) {
  final int duration = endMs - startMs;
  if (duration <= 0) return null;
  final Map<String, int> counts = styleCounts ?? _styleCounts(events);
  AssReferenceEvent? best;
  double bestScore = 0;
  for (final AssReferenceEvent e in events) {
    if (e.startMs >= endMs) break;
    if (e.endMs <= startMs) continue;
    final int overlap =
        (e.endMs < endMs ? e.endMs : endMs) -
        (e.startMs > startMs ? e.startMs : startMs);
    if (overlap < duration * kAssStyleMinOverlapRatio) continue;
    double score = overlap.toDouble();
    if (e.isPositioned) score *= 0.25;
    if (_kana.hasMatch(e.plainText)) score *= 1.5;
    if (best == null ||
        score > bestScore ||
        (score == bestScore &&
            (counts[e.style] ?? 0) > (counts[best.style] ?? 0))) {
      best = e;
      bestScore = score;
    }
  }
  return best;
}

/// 行首连续覆盖块里的标签（`{\an8\pos(1,2)}{\fad(1,2)}` → `[\an8, \pos(1,2), \fad(1,2)]`）。
List<String> assLeadingOverrideTags(String text) {
  final List<String> tags = <String>[];
  int i = 0;
  while (i < text.length && text[i] == '{') {
    final int close = text.indexOf('}', i);
    if (close < 0) break;
    tags.addAll(_splitTags(text.substring(i + 1, close)));
    i = close + 1;
  }
  return tags;
}

/// 去掉覆盖标签、软换行转空格后的正文。
String assPlainText(String text) => text
    .replaceAll(RegExp(r'\{[^}]*\}'), '')
    .replaceAll(RegExp(r'\\[Nnh]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// `H:MM:SS.cc`（厘秒）。
String formatAssTime(int ms) {
  final int cs = (ms < 0 ? 0 : ms) ~/ 10;
  final int h = cs ~/ 360000;
  final int m = cs ~/ 6000 % 60;
  final int s = cs ~/ 100 % 60;
  final int c = cs % 100;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}.${two(c)}';
}

/// 解析 `H:MM:SS.xx`（小数位 1~3 位）；格式不对返回 null。
int? parseAssTime(String value) {
  final RegExpMatch? m = RegExp(
    r'^(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$',
  ).firstMatch(value.trim());
  if (m == null) return null;
  final String frac = (m.group(4) ?? '0').padRight(3, '0');
  return int.parse(m.group(1)!) * 3600000 +
      int.parse(m.group(2)!) * 60000 +
      int.parse(m.group(3)!) * 1000 +
      int.parse(frac);
}

// ---------------------------------------------------------------------------

final RegExp _kana = RegExp(r'[\u3040-\u30FF]');
final RegExp _drawingTag = RegExp(r'\\p[1-9]');
final RegExp _positionTag = RegExp(r'\\(pos|move|i?clip)\(');

/// 不继承的标签：卡拉 OK、`\t` 动画、`\p` 绘图 / 基线偏移。
final RegExp _droppedTag = RegExp(r'^\\(k[fo]?\d|K\d|t\(|p\d|pbo)');

String _overrideBlocks(String text) => RegExp(
  r'\{[^}]*\}',
).allMatches(text).map((RegExpMatch m) => m.group(0)!).join();

/// 覆盖块内部按 `\` 切标签；括号里的 `\`（`\t(...\fscx120)`、`\clip(...)`）不切。
List<String> _splitTags(String block) {
  final List<String> tags = <String>[];
  final StringBuffer cur = StringBuffer();
  int depth = 0;
  for (int i = 0; i < block.length; i++) {
    final String ch = block[i];
    if (ch == r'\' && depth == 0 && cur.isNotEmpty) {
      tags.add(cur.toString());
      cur.clear();
    }
    if (ch == '(') depth++;
    if (ch == ')' && depth > 0) depth--;
    cur.write(ch);
  }
  if (cur.isNotEmpty) tags.add(cur.toString());
  return <String>[
    for (final String t in tags)
      if (t.startsWith(r'\') && t.trim().length > 1) t.trim(),
  ];
}

String _inheritableTags(List<String> tags) => <String>[
  for (final String t in tags)
    if (!_droppedTag.hasMatch(t)) t,
].join();

/// 日语正文写进 ASS：换行 → `\N`，花括号换全角（不然会被当成覆盖块吞掉）。
String _escapeAssText(String text) => text
    .trim()
    .replaceAll('{', '｛')
    .replaceAll('}', '｝')
    .replaceAll(RegExp(r'\r?\n'), r'\N');

AssReferenceEvent? _parseDialogue(String value, List<String> format) {
  // Text 是最后一列，正文里的逗号要拼回去。
  final List<String> parts = value.split(',');
  if (parts.length < format.length) return null;
  final List<String> cols = <String>[
    ...parts.take(format.length - 1),
    parts.skip(format.length - 1).join(','),
  ];
  String col(String name, [String fallback = '']) {
    final int i = format.indexOf(name);
    return i < 0 ? fallback : cols[i].trim();
  }

  final int? start = parseAssTime(col('start'));
  final int? end = parseAssTime(col('end'));
  if (start == null || end == null) return null;
  final int textIndex = format.indexOf('text');
  if (textIndex < 0) return null;
  return AssReferenceEvent(
    layer: col('layer', '0').isEmpty ? '0' : col('layer', '0'),
    startMs: start,
    endMs: end,
    style: col('style', 'Default'),
    name: col('name'),
    marginL: col('marginl', '0'),
    marginR: col('marginr', '0'),
    marginV: col('marginv', '0'),
    effect: col('effect'),
    text: cols[textIndex],
  );
}

Map<String, int> _styleCounts(List<AssReferenceEvent> events) {
  final Map<String, int> counts = <String, int>{};
  for (final AssReferenceEvent e in events) {
    if (e.isPositioned) continue;
    counts[e.style] = (counts[e.style] ?? 0) + 1;
  }
  return counts;
}

String _dominantStyle(List<AssReferenceEvent> events) {
  final Map<String, int> counts = _styleCounts(events);
  String best = events.first.style;
  int bestCount = -1;
  for (final AssReferenceEvent e in events) {
    final int c = counts[e.style] ?? 0;
    if (c > bestCount) {
      best = e.style;
      bestCount = c;
    }
  }
  return best;
}
