/// 把同一视频已有的 ASS 字幕（通常是别的语言的字幕组字幕）的样式与位置套到 AI
/// 生成的日语字幕上，导出 `<视频名>.<后缀>.ass`。
///
/// ```
/// 参考 ASS ─parseAssStyleReference─▶ 原样保留的头部段（[Script Info] / [V4+ Styles]
///                                      / [Fonts] …）+ 带时间的对白事件
/// 日语 cue ─按时间重叠挑参考事件─▶ 继承它的 Layer / Style / Name / Margin / Effect
///                                  + 白名单内的行首覆盖标签（\an \fad \c \fn …）
/// ```
///
/// - 颜色、字体、描边、默认位置来自参考的 Style 行（整段原样拷贝，不改写）；
///   单行的对齐 / 颜色 / 字体来自参考事件行首的覆盖标签。
/// - 覆盖标签走**白名单**（`_inheritableTag`）：只继承静态的对齐（`\an`）、淡入淡出
///   （`\fad`）、颜色（`\c` `\1c`–`\4c`）、字体 / 字号 / 粗体（`\fn` `\fs` `\b`）、
///   描边 / 阴影 / 模糊（`\bord` `\shad` `\blur` `\be`），且只认**作用于整行**的：行中被
///   同名标签改掉或被 `\r` 复位的行首标签是给开头几个词的强调（`{\i1}That{\i0} song.`），
///   不继承。斜体一律不继承，样式本身是斜体时日语行写 `\i0`：日文排版没有斜体
///   （BUG-4091）。其余一律丢弃：卡拉 OK（`\k`
///   系）、`\t` 动画、`\p` 绘图只对参考原文的字 / 时间有意义；透明度（`\alpha`
///   `\1a`–`\4a`）与裁剪（`\clip` `\iclip`）常是 `\t` 动画的起点
///   （`{\alpha&HFF&\t(0,200,\alpha&H00&)}`），去掉 `\t` 只留起点会让日语行整行不可见
///   或被裁成 0 宽；旋转 / 错切 / 原点 / 移动是给参考原文排版用的。行中的覆盖块同理丢弃。
/// - 带 `\pos` / `\move` / `\clip` / `\iclip` 的事件（招牌、标题等排版）**不参与**挑选：
///   日语对白不会被套上招牌的位置 / 旋转 / 裁剪。
/// - 时间上找不到普通参考事件的日语行用参考里最常用的对白样式、不加覆盖标签。
/// - 参考本身含日语（双语字幕）时优先继承日语那一行的样式。
/// - **歌词行逐字卡拉 OK**：日语行时间上落在参考的歌词事件里（`\k` 系标签、Effect 为
///   `fx` / `karaoke` / `template`、样式名像歌，见 [isAssSongEvent]），或本身就是
///   歌词（[AssStyledCue.lyricsHint]），且带逐字时间（[AssStyledCue.charTimes]，来自
///   日语音频的 ASR 逐 token 时间，**不是**从参考的罗马音 / 英文卡拉 OK 搬过来的）时，
///   正文写成 `{\kfNN}字` 扫光，标点粘在前一个字上。唱歌时有人说话（参考的主对白
///   样式事件覆盖这行 ≥ [kAssKaraokeMaxSpeechRatio]）不算歌词行。改用克隆样式 `<样式名> Kara`：
///   SecondaryColour（未唱部分）= PrimaryColour 加半透明（[kAssKaraokeUnsungAlpha]），
///   不沿用字幕组默认的红色副色。克隆行追加在样式段末尾，原样式行一字不改。
///
/// 纯函数，不碰文件系统；读文件 / 抽内嵌轨见 `subtitle_ass_style_reference_loader.dart`。
library;

/// 参考 ASS 至少要有这么多条可读对白，才当作有效的样式来源。
const int kAssStyleReferenceMinEvents = 10;

/// 日语行与参考事件的重叠至少占日语行时长的这个比例，才继承那条事件。
const double kAssStyleMinOverlapRatio = 0.3;

/// 歌词行未唱部分（SecondaryColour）的透明度：主色加这个 alpha（`&H90` ≈ 56% 透明）。
const int kAssKaraokeUnsungAlpha = 0x90;

/// 一个字的唱时段（相对 cue 起点的毫秒）。
typedef AssCharTime = ({int startMs, int endMs});

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
    this.charTimes,
    this.lyricsHint = false,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// [text] 每个码点的唱时段（相对 [startMs]，单调不减）；长度必须等于
  /// `text.runes.length`，不等时当作没有。只有歌词行会用到（输出 `\kf`）。
  final List<AssCharTime>? charTimes;

  /// 这一行本身就是歌词（换成了查到的歌词、或正文以 ♪ 开头）：不看参考事件也按
  /// 歌词行处理。
  final bool lyricsHint;
}

/// 解析参考 ASS 原文。不是 ASS、没有样式段或可读对白不足
/// [kAssStyleReferenceMinEvents] 条时返回 null。
AssStyleReference? parseAssStyleReference(
  String content, {
  required String label,
  int minEvents = kAssStyleReferenceMinEvents,
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

  if (!hasStyles || events.length < minEvents) return null;
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
  final Set<String> italicStyles = _italicStyles(reference.headerSections);
  final _KaraStyles kara = _KaraStyles(reference.headerSections);
  final List<String> dialogue = <String>[];
  for (final AssStyledCue cue in cues) {
    final String text = _escapeAssText(cue.text);
    if (text.isEmpty) continue;
    final AssReferenceEvent? ref = pickAssReferenceEvent(
      startMs: cue.startMs,
      endMs: cue.endMs,
      events: reference.events,
      styleCounts: styleCounts,
    );
    final String baseStyle = ref?.style ?? reference.defaultStyle;
    String style = baseStyle;
    String body = text;
    final List<AssCharTime>? times = cue.charTimes;
    if (times != null &&
        times.length == cue.text.runes.length &&
        (cue.lyricsHint ||
            isAssSongSpan(
              startMs: cue.startMs,
              endMs: cue.endMs,
              events: reference.events,
              dialogueStyle: reference.defaultStyle,
            ))) {
      final String? karaoke = _karaokeText(cue.text, times);
      final String? karaStyle = karaoke == null
          ? null
          : kara.cloneOf(baseStyle);
      if (karaoke != null && karaStyle != null) {
        body = karaoke;
        style = karaStyle;
      }
    }
    final List<String> lineTags = ref == null
        ? const <String>[]
        : <String>[
            for (final String t in lineLevelLeadingTags(ref.text))
              // 卡拉 OK 行的未唱色只认克隆样式的副色，不让参考行的 `\2c` 改回去。
              if (style == baseStyle || !_secondaryColourTag.hasMatch(t)) t,
          ];
    // 样式本身是斜体（字幕组的 Italics / 内心独白样式）：日语行显式关掉（BUG-4091）。
    final String tags =
        '${_inheritableTags(lineTags)}'
        '${italicStyles.contains(baseStyle) ? r'\i0' : ''}';
    dialogue.add(
      'Dialogue: ${ref?.layer ?? '0'},'
      '${formatAssTime(cue.startMs)},${formatAssTime(cue.endMs)},'
      '$style,${ref?.name ?? ''},'
      '${ref?.marginL ?? '0'},${ref?.marginR ?? '0'},${ref?.marginV ?? '0'},'
      '${ref?.effect ?? ''},'
      '${tags.isEmpty ? '' : '{$tags}'}$body',
    );
  }
  final StringBuffer out = StringBuffer();
  for (final String section in kara.sections()) {
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
  dialogue.forEach(out.writeln);
  return out.toString();
}

/// 样式名 / Name / Effect 命中这些就是歌（OP / ED / 插曲 / 卡拉 OK）。
final RegExp assSongStylePattern = RegExp(
  r'(^|[^a-z])(op|ed|song|songs|insert|ins|karaoke|kara|lyric|lyrics|opening|ending|theme)([^a-z]|$)|歌|曲|歌词|歌詞|op[0-9]|ed[0-9]',
  caseSensitive: false,
);

/// 卡拉 OK 计时标签（`\k` `\kf` `\ko` `\K`）。
final RegExp assKaraokeTagPattern = RegExp(r'\\(k|kf|ko|K)\d');

/// kara-templater 的产物 / 模板行的 Effect 列。
final RegExp _karaokeEffect = RegExp(
  r'^(fx|karaoke|template\b.*)$',
  caseSensitive: false,
);

/// 参考事件是不是歌词（卡拉 OK 计时、模板生成的 fx、样式 / Name / Effect 像歌）。
///
/// 不管是否定位：歌词特效行几乎都带 `\pos` / `\move`，这里只用来判定「这段时间在
/// 唱歌」，日语行的样式照旧从普通事件继承（[pickAssReferenceEvent]）。
bool isAssSongEvent(AssReferenceEvent event) =>
    assKaraokeTagPattern.hasMatch(event.text) ||
    _karaokeEffect.hasMatch(event.effect.trim()) ||
    assSongStylePattern.hasMatch(event.style) ||
    assSongStylePattern.hasMatch(event.name) ||
    assSongStylePattern.hasMatch(event.effect);

/// 歌词时段里，参考的主对白样式（[AssStyleReference.defaultStyle]）事件覆盖日语行
/// 达到这个比例，就当这行是**唱歌时的说话**，不加卡拉 OK。
///
/// 实测 BanG Dream! S2E13 7:16–7:50：演唱会场景里观众在歌声上聊天，英文轨把台词
/// 写成 `{\pos(960,990)}` 的 Dialogue 行压在 Poppin' Party 歌词上；只看「这段时间
/// 在唱歌」会把整段聊天扫成卡拉 OK。阈值偏低：错过一句歌词只是少了扫光，把台词
/// 扫成歌词是错的。
const double kAssKaraokeMaxSpeechRatio = 0.15;

/// `[startMs, endMs)` 是不是一句歌词：与歌词事件（[isAssSongEvent]）重叠的并集至少
/// 占这段时长的 [kAssStyleMinOverlapRatio]（逐音节特效每条都很短，单条重叠不够，
/// 按并集算）；且给了 [dialogueStyle] 时，该样式的非歌词事件（含定位的）重叠并集
/// 不到 [kAssKaraokeMaxSpeechRatio]（唱歌时有人说话，那行是台词）。
bool isAssSongSpan({
  required int startMs,
  required int endMs,
  required List<AssReferenceEvent> events,
  String? dialogueStyle,
}) {
  final int duration = endMs - startMs;
  if (duration <= 0) return false;
  final int sung = _coveredMs(startMs, endMs, events, isAssSongEvent);
  if (sung < duration * kAssStyleMinOverlapRatio) return false;
  if (dialogueStyle == null) return true;
  final int spoken = _coveredMs(
    startMs,
    endMs,
    events,
    (AssReferenceEvent e) => e.style == dialogueStyle && !isAssSongEvent(e),
  );
  return spoken < duration * kAssKaraokeMaxSpeechRatio;
}

/// `[startMs, endMs)` 被满足 [test] 的事件覆盖的毫秒数（重叠取并集）。
int _coveredMs(
  int startMs,
  int endMs,
  List<AssReferenceEvent> events,
  bool Function(AssReferenceEvent) test,
) {
  int covered = 0;
  int cursor = startMs;
  // events 按开始时间排序：重叠段起点单调不减，并集只需一个游标。
  for (final AssReferenceEvent e in events) {
    if (e.startMs >= endMs) break;
    if (e.endMs <= cursor || !test(e)) continue;
    final int a = e.startMs > cursor ? e.startMs : cursor;
    final int b = e.endMs < endMs ? e.endMs : endMs;
    if (b > a) {
      covered += b - a;
      cursor = b;
    }
  }
  return covered;
}

/// 给 `[startMs, endMs)` 的日语行挑要继承的参考事件；没有足够重叠的返回 null。
///
/// 排版类事件（[AssReferenceEvent.isPositioned]：招牌、标题）不参与挑选。
/// 得分 = 重叠毫秒 × 权重：正文含假名的事件 ×1.5（双语字幕里日语那一行）；同分取
/// 样式更常用的、再取文件序靠前的。
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
    if (e.isPositioned) continue;
    final int overlap =
        (e.endMs < endMs ? e.endMs : endMs) -
        (e.startMs > startMs ? e.startMs : startMs);
    if (overlap < duration * kAssStyleMinOverlapRatio) continue;
    double score = overlap.toDouble();
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

/// 可继承的行首覆盖标签（白名单，整条标签全匹配）；不在表里的一律丢弃，理由见文件头。
///
/// 不含斜体 `\i`（BUG-4091）：日文排版没有斜体，假名被斜切只会难看；英文字幕组
/// 的斜体（强调词、内心独白、画外音）对日语行没有对应含义。
final RegExp _inheritableTag = RegExp(
  r'^\\(?:'
  r'an[1-9]'
  r'|fad\(\s*\d+\s*,\s*\d+\s*\)'
  r'|[1-4]?c&H[0-9A-Fa-f]{1,8}&?'
  r'|fn[^\\(){}]+'
  r'|fs\d+(?:\.\d+)?'
  r'|b\d+'
  r'|(?:bord|shad|blur|be)\d+(?:\.\d+)?'
  r')$',
);

/// 覆盖标签的名字（`\1c&H…` 与 `\c&H…` 同名 `1c`；`\fnArial` → `fn`）。认不出 → null。
String? _tagName(String tag) {
  final RegExpMatch? m = RegExp(
    r'^\\(bord|shad|blur|be|fad|fn|fs|an|[1-4]c|c|b|i|r)',
  ).firstMatch(tag);
  final String? name = m?.group(1);
  return name == 'c' ? '1c' : name;
}

/// 参考事件里真正作用于整行的行首标签：行中又被同名标签改掉（`{\i1}That{\i0} song.`、
/// `{\c&HFF&}名字{\c}…`）或被 `\r` 复位的，只是给开头几个词的强调 / 着色，不继承
/// （BUG-4091）。
List<String> lineLevelLeadingTags(String text) {
  final List<String> leading = assLeadingOverrideTags(text);
  int i = 0;
  while (i < text.length && text[i] == '{') {
    final int close = text.indexOf('}', i);
    if (close < 0) break;
    i = close + 1;
  }
  final Set<String> laterNames = <String>{
    for (final RegExpMatch m in RegExp(
      r'\{([^}]*)\}',
    ).allMatches(text.substring(i)))
      for (final String t in _splitTags(m.group(1)!)) ?_tagName(t),
  };
  if (laterNames.contains('r')) return const <String>[];
  return <String>[
    for (final String t in leading)
      if (!laterNames.contains(_tagName(t))) t,
  ];
}

/// `[V4+ Styles]` / `[V4 Styles]` 段里 Italic 为真的样式名。
Set<String> _italicStyles(List<String> headerSections) {
  final Set<String> out = <String>{};
  for (final String section in headerSections) {
    final List<String> lines = section.split(RegExp(r'\r?\n'));
    if (lines.isEmpty ||
        !RegExp(
          r'^\s*\[v4\+? styles\]',
          caseSensitive: false,
        ).hasMatch(lines.first)) {
      continue;
    }
    List<String>? format;
    for (final String line in lines.skip(1)) {
      final int colon = line.indexOf(':');
      if (colon < 0) continue;
      final String key = line.substring(0, colon).trim().toLowerCase();
      final List<String> values = line
          .substring(colon + 1)
          .split(',')
          .map((String v) => v.trim())
          .toList();
      if (key == 'format') {
        format = values.map((String v) => v.toLowerCase()).toList();
      } else if (key == 'style' && format != null) {
        final int nameAt = format.indexOf('name');
        final int italicAt = format.indexOf('italic');
        if (nameAt < 0 || italicAt < 0 || italicAt >= values.length) continue;
        final int? italic = int.tryParse(values[italicAt]);
        if (italic != null && italic != 0) out.add(values[nameAt]);
      }
    }
  }
  return out;
}

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
    if (_inheritableTag.hasMatch(t)) t,
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

// ---------------------------------------------------------------------------
// 歌词行逐字卡拉 OK
// ---------------------------------------------------------------------------

final RegExp _secondaryColourTag = RegExp(r'^\\2c');

/// 不单独计时的字（空白、标点、符号）：粘到前一个字上，不单独占一个 `\kf`。
final RegExp _karaokeGlue = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

/// 一个码点写进 ASS 正文：换行 → `\N`，花括号换全角，`\r` 丢掉。
String _escapeAssChar(String ch) => switch (ch) {
  '\n' => r'\N',
  '\r' => '',
  '{' => '｛',
  '}' => '｝',
  _ => ch,
};

/// 一个 `\kf` 音节：计时字 + 后面粘着的标点 / 空白。
typedef _KaraUnit = ({String text, int startMs, int endMs});

/// 把 [text] 按逐字时间 [times]（相对 cue 起点）写成 `{\kfNN}字…`。
///
/// 单位是厘秒，按累计时刻取整（不逐字取整，长行不漂移）；字与字之间没唱的空档
/// 写成空音节 `{\kNN}`，扫光在空档里停住。标点 / 空白粘在前一个字后面（行首的粘
/// 到第一个字前面）。去掉首尾空白后没有可计时的字时返回 null。
String? _karaokeText(String text, List<AssCharTime> times) {
  final List<int> runes = text.runes.toList(growable: false);
  bool space(int r) => String.fromCharCode(r).trim().isEmpty;
  int from = 0;
  int to = runes.length;
  while (from < to && space(runes[from])) {
    from++;
  }
  while (to > from && space(runes[to - 1])) {
    to--;
  }
  final List<_KaraUnit> units = <_KaraUnit>[];
  final StringBuffer lead = StringBuffer();
  for (int i = from; i < to; i++) {
    final String ch = String.fromCharCode(runes[i]);
    final String escaped = _escapeAssChar(ch);
    if (_karaokeGlue.hasMatch(ch)) {
      if (units.isEmpty) {
        lead.write(escaped);
      } else {
        final _KaraUnit last = units.removeLast();
        units.add((
          text: '${last.text}$escaped',
          startMs: last.startMs,
          endMs: last.endMs,
        ));
      }
      continue;
    }
    units.add((
      text: units.isEmpty ? '$lead$escaped' : escaped,
      startMs: times[i].startMs,
      endMs: times[i].endMs,
    ));
  }
  if (units.isEmpty) return null;
  final StringBuffer out = StringBuffer();
  int cursorCs = 0;
  for (final _KaraUnit u in units) {
    final int startCs = (u.startMs / 10).round();
    final int endCs = (u.endMs / 10).round();
    if (startCs > cursorCs) {
      out.write('{\\k${startCs - cursorCs}}');
      cursorCs = startCs;
    }
    final int dur = endCs > cursorCs ? endCs - cursorCs : 0;
    out.write('{\\kf$dur}${u.text}');
    cursorCs += dur;
  }
  return out.toString();
}

final RegExp _stylesHeader = RegExp(
  r'^\s*\[v4\+? styles\]',
  caseSensitive: false,
);

/// 参考样式段 + 按需追加的 `<样式名> Kara` 克隆样式（同一样式只追加一次，原有
/// 样式行一字不改）。
class _KaraStyles {
  _KaraStyles(this._sections);

  final List<String> _sections;

  /// 原样式名 → 克隆样式名（null = 找不到原样式行 / 认不出主色，不克隆）。
  final Map<String, String?> _clones = <String, String?>{};

  /// 克隆出来的样式行，按所在段下标分组、按追加顺序。
  final Map<int, List<String>> _added = <int, List<String>>{};

  /// [style] 的卡拉 OK 克隆样式名；第一次调用时追加克隆行。
  String? cloneOf(String style) {
    if (_clones.containsKey(style)) return _clones[style];
    String? result;
    for (int s = 0; s < _sections.length && result == null; s++) {
      result = _cloneIn(s, style);
    }
    _clones[style] = result;
    return result;
  }

  String? _cloneIn(int section, String style) {
    final List<String> lines = _sections[section].split(RegExp(r'\r?\n'));
    if (lines.isEmpty || !_stylesHeader.hasMatch(lines.first)) return null;
    List<String>? format;
    final Set<String> names = <String>{
      for (final String added in _added[section] ?? const <String>[])
        added.substring(added.indexOf(':') + 1).split(',').first.trim(),
    };
    String? source;
    for (final String line in lines.skip(1)) {
      final int colon = line.indexOf(':');
      if (colon < 0) continue;
      final String key = line.substring(0, colon).trim().toLowerCase();
      final List<String> values = line.substring(colon + 1).split(',');
      if (key == 'format') {
        format = <String>[
          for (final String v in values) v.trim().toLowerCase(),
        ];
      } else if (key == 'style' && format != null) {
        final int nameAt = format.indexOf('name');
        if (nameAt < 0 || nameAt >= values.length) continue;
        final String name = values[nameAt].trim();
        names.add(name);
        if (name == style) source ??= line;
      }
    }
    if (source == null || format == null) return null;
    final List<String> values = source
        .substring(source.indexOf(':') + 1)
        .trimLeft()
        .split(',');
    final int nameAt = format.indexOf('name');
    final int primaryAt = format.indexOf('primarycolour');
    final int secondaryAt = format.indexOf('secondarycolour');
    if (primaryAt < 0 ||
        secondaryAt < 0 ||
        primaryAt >= values.length ||
        secondaryAt >= values.length) {
      return null;
    }
    final String? unsung = _unsungColour(values[primaryAt].trim());
    if (unsung == null) return null;
    String name = '$style Kara';
    for (int n = 2; names.contains(name); n++) {
      name = '$style Kara $n';
    }
    values[nameAt] = name;
    values[secondaryAt] = unsung;
    (_added[section] ??= <String>[]).add('Style: ${values.join(',')}');
    return name;
  }

  /// 输出用的头部各段：克隆行追加在所在样式段末尾。
  List<String> sections() => <String>[
    for (int s = 0; s < _sections.length; s++)
      _added[s] == null
          ? _sections[s]
          : '${_sections[s].trimRight()}\n${_added[s]!.join('\n')}',
  ];
}

/// `&HAABBGGRR` 主色 → 同色、alpha 至少 [kAssKaraokeUnsungAlpha] 的副色。认不出 → null。
String? _unsungColour(String primary) {
  final RegExpMatch? m = RegExp(
    r'^&H([0-9A-Fa-f]{1,8})&?$',
  ).firstMatch(primary);
  if (m == null) return null;
  final int v = int.parse(m.group(1)!, radix: 16);
  final int alpha = (v >> 24) & 0xFF;
  final int a = alpha > kAssKaraokeUnsungAlpha ? alpha : kAssKaraokeUnsungAlpha;
  String hex(int x, int width) =>
      x.toRadixString(16).padLeft(width, '0').toUpperCase();
  return '&H${hex(a, 2)}${hex(v & 0xFFFFFF, 6)}';
}
