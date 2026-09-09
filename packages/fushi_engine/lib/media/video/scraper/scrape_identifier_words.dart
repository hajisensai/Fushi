/// 视频刮削「识别词」：用户自定义的标题预处理词表（对标 MoviePilot 的
/// `app/core/meta/words.py` WordsMatcher）。
///
/// 词表一行一条，`#` 开头是注释，空行忽略。四种语法：
///
/// * `屏蔽词` —— 单独一行的正则，从标题里删除。
/// * `A => B` —— 正则替换。
/// * `前 <> 后 >> EP+N` —— 集偏移：`前`与`后`之间的第一串数字做 `+N` / `-N`。
/// * `A => B && 前 <> 后 >> EP+N` —— 先替换，替换命中才做偏移。
///
/// 与上游的两点有意差异：
///
/// 1. 偏移表达式**不做 eval**，只接受 `EP` 后跟 `+`/`-` 与十进制整数；上游那种
///    把用户串丢进 `eval()` 的写法在客户端等于给词表开了任意代码执行口子。
/// 2. 中文数字（上游经 `cn2an`）不支持，只处理阿拉伯数字。
///
/// 非法行不静默吞：解析结果同时带回 [ScrapeIdentifierWordParseResult.errors]，
/// 由设置页展示给用户；其余行照常工作。
library;

/// 一条识别词的语法种类。
enum ScrapeIdentifierWordKind { block, replace, offset, replaceAndOffset }

/// 集号与偏移量的上限。超出这个范围的结果一律视为规则写错，不偏移。
const int _kMaxEpisodeNumber = 9999;

/// 单条已编译的识别词。
class ScrapeIdentifierWord {
  const ScrapeIdentifierWord({
    required this.kind,
    required this.raw,
    this.pattern,
    this.replacement,
    this.front,
    this.back,
    this.episodeOffset = 0,
  });

  /// 语法种类。
  final ScrapeIdentifierWordKind kind;

  /// 词表里的原始行（去首尾空白），用于诊断与 UI 回显。
  final String raw;

  /// 屏蔽/替换的匹配正则；[ScrapeIdentifierWordKind.offset] 为 null。
  final RegExp? pattern;

  /// 替换目标；屏蔽词恒为 `''`；[ScrapeIdentifierWordKind.offset] 为 null。
  final String? replacement;

  /// 集号定位的前界正则；null = 从标题开头算起。
  final RegExp? front;

  /// 集号定位的后界正则；null = 到标题结尾。
  final RegExp? back;

  /// 集号偏移量（可正可负）；非偏移类恒为 0。
  final int episodeOffset;
}

/// 一次词表解析的结果：可用的词 + 逐行错误说明。
class ScrapeIdentifierWordParseResult {
  const ScrapeIdentifierWordParseResult({
    required this.words,
    required this.errors,
    this.source = '',
  });

  final List<ScrapeIdentifierWord> words;

  /// 非法行的说明（每条已带行号）。UI 至少要能显示条数。
  final List<String> errors;

  /// 原始词表文本。
  final String source;

  /// 直接可用于 [ScrapeIdentifierWords.apply] 的词表视图。
  ScrapeIdentifierWords get identifierWords =>
      ScrapeIdentifierWords(words: words, source: source);
}

/// 已编译的识别词表。[source] 保留原始文本，供配置指纹比较。
class ScrapeIdentifierWords {
  const ScrapeIdentifierWords({
    this.words = const <ScrapeIdentifierWord>[],
    this.source = '',
  });

  static const ScrapeIdentifierWords empty = ScrapeIdentifierWords();

  final List<ScrapeIdentifierWord> words;

  /// 原始词表文本。
  final String source;

  bool get isEmpty => words.isEmpty;
  bool get isNotEmpty => words.isNotEmpty;

  /// 逐行解析词表。非法行进 [ScrapeIdentifierWordParseResult.errors]，不抛异常。
  static ScrapeIdentifierWordParseResult parse(String text) {
    final List<ScrapeIdentifierWord> words = <ScrapeIdentifierWord>[];
    final List<String> errors = <String>[];
    final List<String> lines = text.split(RegExp(r'\r\n|\r|\n'));
    for (int index = 0; index < lines.length; index++) {
      final String line = lines[index].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final Object result = _parseLine(line);
      if (result is ScrapeIdentifierWord) {
        words.add(result);
      } else {
        errors.add('第 ${index + 1} 行：$result');
      }
    }
    return ScrapeIdentifierWordParseResult(
      words: words,
      errors: errors,
      source: text,
    );
  }

  /// 把整张词表按顺序应用到一个标题候选。
  ///
  /// 每条规则在一次调用里最多参与一次（不做定点迭代），返回处理后的标题与
  /// 累计集偏移量（没有任何偏移命中则为 0）。
  ({String title, int episodeOffset}) apply(String title) {
    String current = title;
    int offset = 0;
    for (final ScrapeIdentifierWord word in words) {
      final bool replaces = word.kind == ScrapeIdentifierWordKind.block ||
          word.kind == ScrapeIdentifierWordKind.replace ||
          word.kind == ScrapeIdentifierWordKind.replaceAndOffset;
      if (replaces) {
        final RegExp pattern = word.pattern!;
        // 「替换成功才偏移」：复合规则的替换没命中就整条跳过。
        if (word.kind == ScrapeIdentifierWordKind.replaceAndOffset &&
            !pattern.hasMatch(current)) {
          continue;
        }
        current = current.replaceAll(pattern, word.replacement!);
      }
      if (word.kind == ScrapeIdentifierWordKind.offset ||
          word.kind == ScrapeIdentifierWordKind.replaceAndOffset) {
        final ({String title, int applied})? shifted =
            _applyOffset(current, word);
        if (shifted == null) continue;
        current = shifted.title;
        offset += shifted.applied;
      }
    }
    return (title: current, episodeOffset: offset);
  }

  /// 在 `前 <> 后` 之间找第一串数字并偏移；不适用时返回 null（标题不动）。
  static ({String title, int applied})? _applyOffset(
    String title,
    ScrapeIdentifierWord word,
  ) {
    int start = 0;
    final RegExp? front = word.front;
    if (front != null) {
      final RegExpMatch? match = front.firstMatch(title);
      if (match == null) return null;
      start = match.end;
    }
    int end = title.length;
    final RegExp? back = word.back;
    if (back != null) {
      final RegExpMatch? match = back.firstMatch(title.substring(start));
      if (match == null) return null;
      end = start + match.start;
    }
    if (end <= start) return null;
    final String region = title.substring(start, end);
    final RegExpMatch? digits = RegExp(r'\d+').firstMatch(region);
    if (digits == null) return null;
    final String original = digits.group(0)!;
    final int? value = int.tryParse(original);
    if (value == null) return null;
    final int shifted = value + word.episodeOffset;
    if (shifted <= 0 || shifted > _kMaxEpisodeNumber) return null;
    final String replacement = shifted.toString().padLeft(original.length, '0');
    return (
      title: title.substring(0, start + digits.start) +
          replacement +
          title.substring(start + digits.end),
      applied: word.episodeOffset,
    );
  }

  /// 解析成功返回 [ScrapeIdentifierWord]，失败返回错误说明字符串。
  static Object _parseLine(String line) {
    final int complexAt = line.indexOf('&&');
    if (complexAt >= 0) {
      final Object replace = _parseReplace(line.substring(0, complexAt).trim());
      if (replace is! ScrapeIdentifierWord) return replace;
      final Object offset = _parseOffset(line.substring(complexAt + 2).trim());
      if (offset is! ScrapeIdentifierWord) return offset;
      return ScrapeIdentifierWord(
        kind: ScrapeIdentifierWordKind.replaceAndOffset,
        raw: line,
        pattern: replace.pattern,
        replacement: replace.replacement,
        front: offset.front,
        back: offset.back,
        episodeOffset: offset.episodeOffset,
      );
    }
    if (line.contains('=>')) return _parseReplace(line);
    if (line.contains('<>') || line.contains('>>')) return _parseOffset(line);
    final RegExp? pattern = _compile(line);
    if (pattern == null) return '屏蔽词不是合法正则';
    return ScrapeIdentifierWord(
      kind: ScrapeIdentifierWordKind.block,
      raw: line,
      pattern: pattern,
      replacement: '',
    );
  }

  static Object _parseReplace(String segment) {
    final int at = segment.indexOf('=>');
    if (at < 0) return '缺少 `=>` 替换分隔符';
    final String source = segment.substring(0, at).trim();
    if (source.isEmpty) return '替换规则的匹配式为空';
    final RegExp? pattern = _compile(source);
    if (pattern == null) return '替换规则的匹配式不是合法正则';
    return ScrapeIdentifierWord(
      kind: ScrapeIdentifierWordKind.replace,
      raw: segment,
      pattern: pattern,
      replacement: segment.substring(at + 2).trim(),
    );
  }

  static Object _parseOffset(String segment) {
    final int at = segment.indexOf('>>');
    if (at < 0) return '集偏移缺少 `>>` 分隔符';
    final String bounds = segment.substring(0, at);
    final int boundAt = bounds.indexOf('<>');
    if (boundAt < 0) return '集偏移缺少 `<>` 前后界分隔符';
    final String frontText = bounds.substring(0, boundAt).trim();
    final String backText = bounds.substring(boundAt + 2).trim();
    final RegExp? front = frontText.isEmpty ? null : _compile(frontText);
    if (frontText.isNotEmpty && front == null) return '集偏移的前界不是合法正则';
    final RegExp? back = backText.isEmpty ? null : _compile(backText);
    if (backText.isNotEmpty && back == null) return '集偏移的后界不是合法正则';
    final int? offset = parseEpisodeOffsetExpression(segment.substring(at + 2));
    if (offset == null) return '集偏移量只支持 `EP+N` / `EP-N` 形式的十进制整数';
    return ScrapeIdentifierWord(
      kind: ScrapeIdentifierWordKind.offset,
      raw: segment,
      front: front,
      back: back,
      episodeOffset: offset,
    );
  }

  static RegExp? _compile(String pattern) {
    try {
      return RegExp(pattern);
    } on FormatException {
      return null;
    }
  }
}

/// 解析 `EP+12` / `EP-1` 形式的偏移表达式；非法返回 null。
///
/// 故意不支持任何算术表达式：上游用 `eval()`，那是客户端上的任意代码执行口子。
int? parseEpisodeOffsetExpression(String expression) {
  final RegExpMatch? match = RegExp(r'^EP\s*([+-])\s*(\d+)$')
      .firstMatch(expression.replaceAll(RegExp(r'\s+'), ' ').trim());
  if (match == null) return null;
  final int? magnitude = int.tryParse(match.group(2)!);
  if (magnitude == null || magnitude > _kMaxEpisodeNumber) return null;
  return match.group(1) == '-' ? -magnitude : magnitude;
}
