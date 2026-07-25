/// galgame hook 文本 → 统计字数的**唯一**计数入口。
///
/// 口径对齐 LunaTranslator `count_words_mixed`（2026-04 起的现行口径）与
/// exSTATic `charsInLine`：
/// - 标点、空白、括号、排版符号一律不计；
/// - CJK（汉字/假名/谚文/半角片假名）按 code point 每字计 1（增补面汉字不再
///   因 UTF-16 代理对双计）；
/// - 拉丁/西文/数字的连续串每串计 1（"Hello world" = 2）；
/// - 相邻重复行计 0（引擎重绘/回想/自动模式重发同句不重计）；
/// - 打字机递增行（"あ→ああ→あありがとう"逐次重发）只计相对上一行的增量；
/// - 清洗后超过 [GalgameLineCharCounter.maxCountedChars] 的行视为脚本 dump
///   垃圾，计 0。
///
/// 非相邻重复（回想/二周目重读）照计——与 Luna/exSTATic 社区口径一致：
/// "hook 到即读过"，不做阅读器式高水位。
library;

/// [codePoint] 是否为按"字"计数的 CJK 文字（汉字/假名/谚文；含迭代符 々〆〇、
/// 片假名音标扩展与半角片假名）。标点、全角符号、空白都不在内。
bool _isCjkChar(int codePoint) {
  return (codePoint >= 0x3040 && codePoint <= 0x30FF) || // 平/片假名
      (codePoint >= 0x3005 && codePoint <= 0x3007) || // 々〆〇
      (codePoint >= 0x31F0 && codePoint <= 0x31FF) || // 片假名音标扩展
      (codePoint >= 0xFF66 && codePoint <= 0xFF9D) || // 半角片假名
      (codePoint >= 0x3400 && codePoint <= 0x4DBF) || // 汉字扩展 A
      (codePoint >= 0x4E00 && codePoint <= 0x9FFF) || // 汉字基本区
      (codePoint >= 0xF900 && codePoint <= 0xFAFF) || // 汉字兼容区
      (codePoint >= 0x20000 && codePoint <= 0x2FFFF) || // 汉字扩展 B+（增补面）
      (codePoint >= 0xAC00 && codePoint <= 0xD7AF); // 谚文音节
}

/// [codePoint] 是否为组成"西文词"的字符（ASCII/全角字母数字、拉丁扩展、
/// 希腊、西里尔）。连续一串算 1 个词。
bool _isWordChar(int codePoint) {
  return (codePoint >= 0x30 && codePoint <= 0x39) || // 0-9
      (codePoint >= 0x41 && codePoint <= 0x5A) || // A-Z
      (codePoint >= 0x61 && codePoint <= 0x7A) || // a-z
      (codePoint >= 0x00C0 && codePoint <= 0x024F) || // 拉丁补充/扩展
      (codePoint >= 0x0370 && codePoint <= 0x03FF) || // 希腊
      (codePoint >= 0x0400 && codePoint <= 0x04FF) || // 西里尔
      (codePoint >= 0xFF10 && codePoint <= 0xFF19) || // 全角 0-9
      (codePoint >= 0xFF21 && codePoint <= 0xFF3A) || // 全角 A-Z
      (codePoint >= 0xFF41 && codePoint <= 0xFF5A); // 全角 a-z
}

/// 单行文本的统计字数：CJK 每字 1 + 西文连续串每串 1；其余（标点/空白/符号）
/// 为 0 且充当西文词的分隔符。纯函数，无状态。
int countGalgameChars(String text) {
  int count = 0;
  bool inWord = false;
  for (final int codePoint in text.runes) {
    if (_isCjkChar(codePoint)) {
      if (inWord) {
        count++;
        inWord = false;
      }
      count++;
    } else if (_isWordChar(codePoint)) {
      inWord = true;
    } else {
      if (inWord) {
        count++;
        inWord = false;
      }
    }
  }
  if (inWord) count++;
  return count;
}

/// 有状态的逐行计数器：在 [countGalgameChars] 口径之上叠加**相邻重复去重**与
/// **打字机递增行增量计数**。一个 hook 会话持有一个实例；换游戏/会话结束时
/// [reset]。
///
/// 只保留上一行文本这一份状态——没有 LRU、没有窗口、没有配置项。非相邻重复
/// 照计（见库注释）。
class GalgameLineCharCounter {
  GalgameLineCharCounter({this.maxCountedChars = 500});

  /// 清洗后字数超过此值的行视为脚本 dump/垃圾整块文本，计 0（正常 VN 台词
  /// 清洗后极少超过 200 字；对齐 Luna 的 maxlength 门思路）。
  final int maxCountedChars;

  String? _lastText;
  int _lastCount = 0;

  /// 记一行文本，返回本行应计入统计的字数（>= 0）。
  ///
  /// - 与上一行完全相同 → 0；
  /// - 上一行是本行的前缀（打字机逐字重发）→ 只计增量部分；
  /// - 清洗后字数超 [maxCountedChars] → 0（仍更新"上一行"状态，使后续
  ///   相邻去重继续有效）。
  int countLine(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    final String? last = _lastText;
    if (trimmed == last) return 0;
    final int count = countGalgameChars(trimmed);
    int delta = count;
    if (last != null &&
        trimmed.length > last.length &&
        trimmed.startsWith(last)) {
      delta = count - _lastCount;
      if (delta < 0) delta = 0;
    }
    _lastText = trimmed;
    _lastCount = count;
    if (count > maxCountedChars) return 0;
    return delta;
  }

  /// 会话结束/换游戏时复位，下一段从零开始（跨会话不做前缀/去重比对）。
  void reset() {
    _lastText = null;
    _lastCount = 0;
  }
}
