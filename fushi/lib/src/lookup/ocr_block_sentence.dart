/// BUG-3487：从截屏识字（ML Kit）的一个 text block 里截出包含被点字的整句，作 app 外
/// 查词窗制卡的 `{sentence}`。
///
/// 块全文是原生侧把块内各行按 `\n` 拼起来的（`ScreenOcrLayout.blockLineOffsets`）。
/// 竖排 / 折行的长句被拆成多行，只拿被点那一行做句子会只剩半句；反过来一行里也可能
/// 装着两句话。截取规则：
///
/// - **换行不是句界**：OCR 的行是排版折行，不是作者断句。拼回时 CJK 之间直接相连，
///   两侧都是拉丁字母 / 数字时补一个空格（英文折行处原本就是空格）。
/// - **句末标点**：`。｡！？!?．‼⁇⁈⁉`，以及后面跟空白或块尾的半角 `.`（`3.5` 之类
///   不算）。句末标点后紧跟的闭括号 / 引号（`」』）"”` 等）和连续的句末标点都归前一句。
/// - **闭括号紧接开括号**（`」「`，中间只隔换行 / 空白）也是句界：对白一条一条排，
///   每条不一定带句号。
/// - `…` / `‥` **不算句界**：日文里它多半在句中（「あの……実は」），按它切会切出半句。
/// - 截出的句子超过 [maxLength] 个 UTF-16 码元（多半是整块没有标点的菜单 / 列表），
///   返回 null，让调用方回落为被点的那一行。
library;

const int kOcrBlockSentenceMaxLength = 200;

const Set<String> _terminators = <String>{
  '。',
  '｡',
  '！',
  '？',
  '!',
  '?',
  '．',
  '‼',
  '⁇',
  '⁈',
  '⁉',
};

const Set<String> _closers = <String>{
  '」',
  '』',
  '）',
  ')',
  '】',
  '〕',
  '〉',
  '》',
  '］',
  ']',
  '〟',
  '”',
  '’',
  '"',
  "'",
};

const Set<String> _bracketClosers = <String>{'」', '』'};
const Set<String> _bracketOpeners = <String>{'「', '『'};

bool _isLineBreak(String ch) => ch == '\n' || ch == '\r';

bool _isSpace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '　' || _isLineBreak(ch);

bool _isLatinWordChar(String ch) {
  final int c = ch.codeUnitAt(0);
  return (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xC0 && c <= 0x24F);
}

/// [i] 处的字符结束一句时，返回句子在块里的结束位置（不含），否则 -1。
int _sentenceEndAt(String block, int i) {
  final String ch = block[i];
  final bool asciiPeriod = ch == '.';
  if (!_terminators.contains(ch) && !asciiPeriod) {
    if (_bracketClosers.contains(ch)) {
      int j = i + 1;
      while (j < block.length && _isSpace(block[j])) {
        j++;
      }
      if (j < block.length && _bracketOpeners.contains(block[j])) return i + 1;
    }
    return -1;
  }
  int j = i + 1;
  while (j < block.length &&
      (_terminators.contains(block[j]) ||
          block[j] == '.' ||
          _closers.contains(block[j]))) {
    j++;
  }
  // 半角句点只在后面是空白 / 块尾时才算句末（排除 3.5、e.g 中段、网址）。
  if (asciiPeriod && j < block.length && !_isSpace(block[j])) return -1;
  return j;
}

/// 把块里的 [start, end) 一段拼回一句：去掉 OCR 折行，CJK 直接相连，拉丁词之间补空格。
String _joinLines(String segment) =>
    _joinRange(segment, 0, segment.length).text;

/// [_joinLines] 的带下标版：拼好的文字连同「每段行文在块里 / 在拼好的文字里各从哪
/// 起」的对照表（[OcrBlockSpan]），供块下标与拼好文字下标互换。
OcrBlockSpan _joinRange(String block, int start, int end) {
  final StringBuffer out = StringBuffer();
  final List<_OcrJoinSegment> segments = <_OcrJoinSegment>[];
  int lineStart = start;
  while (lineStart <= end) {
    int lineEnd = lineStart;
    while (lineEnd < end && !_isLineBreak(block[lineEnd])) {
      lineEnd++;
    }
    final String raw = block.substring(lineStart, lineEnd);
    final String line = raw.trim();
    if (line.isNotEmpty) {
      if (out.isNotEmpty) {
        final String before = out.toString();
        final String prev = before[before.length - 1];
        if (_isLatinWordChar(prev) && _isLatinWordChar(line[0])) out.write(' ');
      }
      segments.add(
        _OcrJoinSegment(
          block: lineStart + raw.length - raw.trimLeft().length,
          text: out.length,
          length: line.length,
        ),
      );
      out.write(line);
    }
    lineStart = lineEnd + 1;
  }
  return OcrBlockSpan._(
    out.toString(),
    blockStart: start,
    blockEnd: end,
    segments: segments,
  );
}

/// [OcrBlockSpan] 的一段行文：在块里从 [block] 起、在拼好的文字里从 [text] 起，长
/// [length] 个 UTF-16 码元（两边逐字对应）。
class _OcrJoinSegment {
  const _OcrJoinSegment({
    required this.block,
    required this.text,
    required this.length,
  });

  final int block;
  final int text;
  final int length;
}

/// 块里一段 [blockStart, blockEnd) 拼掉 OCR 折行后的文字 [text]，带块下标 ↔ 文字下标
/// 的换算（反馈 8Su1XoCjtl：app 外查词的源文本条显示跨行拼好的整句，被点字与条上点字
/// 都要在块与条之间换算）。
class OcrBlockSpan {
  const OcrBlockSpan._(
    this.text, {
    required this.blockStart,
    required this.blockEnd,
    required List<_OcrJoinSegment> segments,
  }) : _segments = segments;

  /// 拼好的文字（首尾无空白）。
  final String text;

  /// 这段在块里的起止（UTF-16，止不含）。
  final int blockStart;
  final int blockEnd;

  final List<_OcrJoinSegment> _segments;

  /// 块下标 [blockIndex] 那个字在 [text] 里的 UTF-16 下标；落在被拼掉的折行 / 行首尾
  /// 空白上时取后面最近的字，段外钳到首 / 末字。[text] 为空时返回 -1。
  int textIndexOf(int blockIndex) {
    if (_segments.isEmpty) return -1;
    for (final _OcrJoinSegment s in _segments) {
      if (blockIndex < s.block) return s.text;
      if (blockIndex < s.block + s.length) return s.text + blockIndex - s.block;
    }
    return text.length - 1;
  }

  /// [text] 里 UTF-16 下标 [textIndex] 那个字在块里的下标；落在拼接时补的空格上时取
  /// 后一行的行首，越界钳到首 / 末字。[text] 为空时返回 -1。
  int blockIndexOf(int textIndex) {
    if (_segments.isEmpty) return -1;
    for (final _OcrJoinSegment s in _segments) {
      if (textIndex < s.text) return s.block;
      if (textIndex < s.text + s.length) return s.block + textIndex - s.text;
    }
    final _OcrJoinSegment last = _segments.last;
    return last.block + last.length - 1;
  }
}

/// 块里包含 UTF-16 下标 [index] 那个字的那一句在块里的起止（未拼折行；止不含）。
({int start, int end}) _sentenceRangeAt(String block, int index) {
  int start = 0;
  int end = block.length;
  int i = 0;
  while (i < block.length) {
    final int sentenceEnd = _sentenceEndAt(block, i);
    if (sentenceEnd < 0) {
      i++;
      continue;
    }
    if (sentenceEnd > index) {
      end = sentenceEnd;
      break;
    }
    start = sentenceEnd;
    i = sentenceEnd;
  }
  return (start: start, end: end);
}

/// 块全文 [block] 里包含 UTF-16 下标 [index] 那个字的整句（已拼掉 OCR 折行、去首尾
/// 空白）。下标越界、截出空串或长于 [maxLength] 时返回 null。
String? ocrBlockSentenceAt(
  String block,
  int index, {
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  if (block.isEmpty || index < 0 || index >= block.length) return null;
  final ({int start, int end}) range = _sentenceRangeAt(block, index);
  final String sentence = _joinLines(block.substring(range.start, range.end));
  if (sentence.isEmpty || sentence.length > maxLength) return null;
  return sentence;
}

/// 反馈 8Su1XoCjtl：块里 [lineStart, lineEnd) 是被点的那一行时，源文本条该显示的那段——
/// 从行首字所在句的句首到行末字所在句的句尾，拼掉 OCR 折行。整行都在里面（一行装着
/// 几句时条上几句都能点），被折到上一行 / 下一行的半句也补全了。某一端那句截不出
/// （长于 [maxLength]，多半是无标点的菜单 / 列表）时那一端停在行边上。行为空或越界
/// 时返回 null。
OcrBlockSpan? ocrBlockSpanAroundLine(
  String block, {
  required int lineStart,
  required int lineEnd,
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  if (lineStart < 0 || lineEnd > block.length || lineEnd <= lineStart) {
    return null;
  }
  bool fits(({int start, int end}) range) =>
      _joinLines(block.substring(range.start, range.end)).length <= maxLength;
  final ({int start, int end}) first = _sentenceRangeAt(block, lineStart);
  final ({int start, int end}) last = _sentenceRangeAt(block, lineEnd - 1);
  final OcrBlockSpan span = _joinRange(
    block,
    fits(first) ? first.start : lineStart,
    fits(last) ? last.end : lineEnd,
  );
  return span.text.isEmpty ? null : span;
}

/// BUG-4707：块全文 [block] 里被点那一行止于 UTF-16 下标 [lineEnd]（不含）时，接在
/// 这行后面、按同一套折行拼接规则拼好的块内后续文字（去掉 OCR 折行；行尾与下一行
/// 开头都是拉丁字母 / 数字时以一个空格开头）。
///
/// 查词串 = 被点行从被点字起的后缀 + 这段续文：OCR 的行是排版折行，词会被折到下一行，
/// 只扫到行尾就把词截断了。续文最多 [maxLength] 个 UTF-16 码元（一个词跨行用不了
/// 这么长，免得整块菜单 / 列表都塞进查询串）。没有后续行或下标越界时返回空串。
String ocrBlockContinuationAfterLine(
  String block, {
  required int lineEnd,
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  if (lineEnd <= 0 || lineEnd >= block.length) return '';
  String rest = _joinLines(block.substring(lineEnd));
  if (rest.isEmpty) return '';
  if (rest.length > maxLength) {
    int cut = maxLength;
    // 不把代理对劈成两半。
    final int last = rest.codeUnitAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) cut--;
    rest = rest.substring(0, cut);
  }
  final String lineLast = block[lineEnd - 1];
  if (!_isSpace(lineLast) &&
      _isLatinWordChar(lineLast) &&
      _isLatinWordChar(rest[0])) {
    return ' $rest';
  }
  return rest;
}

/// 没有所属块、只有被点那一行 [line] 时（拍照查词 / iOS 截屏识字的系统 OCR 只给行）
/// 的制卡句子：行里包含 UTF-16 下标 [index] 那个字的那一句，截不出时回落为整行
/// （BUG-2900 口径）。
String ocrSentenceInLine(String line, int index) =>
    ocrBlockSentenceAt(line, index) ?? line.trim();
