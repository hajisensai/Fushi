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
String _joinLines(String segment) {
  final List<String> lines = segment
      .split(RegExp(r'\r?\n|\r'))
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  final StringBuffer out = StringBuffer();
  for (final String line in lines) {
    if (out.isNotEmpty) {
      final String before = out.toString();
      final String prev = before[before.length - 1];
      if (_isLatinWordChar(prev) && _isLatinWordChar(line[0])) out.write(' ');
    }
    out.write(line);
  }
  return out.toString();
}

/// 块全文 [block] 里包含 UTF-16 下标 [index] 那个字的整句（已拼掉 OCR 折行、去首尾
/// 空白）。下标越界、截出空串或长于 [maxLength] 时返回 null。
String? ocrBlockSentenceAt(
  String block,
  int index, {
  int maxLength = kOcrBlockSentenceMaxLength,
}) {
  if (block.isEmpty || index < 0 || index >= block.length) return null;
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
  final String sentence = _joinLines(block.substring(start, end));
  if (sentence.isEmpty || sentence.length > maxLength) return null;
  return sentence;
}

/// 没有所属块、只有被点那一行 [line] 时（拍照查词 / iOS 截屏识字的系统 OCR 只给行）
/// 的制卡句子：行里包含 UTF-16 下标 [index] 那个字的那一句，截不出时回落为整行
/// （BUG-2900 口径）。
String ocrSentenceInLine(String line, int index) =>
    ocrBlockSentenceAt(line, index) ?? line.trim();
