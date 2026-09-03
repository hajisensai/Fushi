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

import 'package:fushi/src/stats/study_char_count.dart';

/// galgame 行文本的字数：直接走全仓唯一口径 [countStudyChars]。
///
/// 这里曾有一份自己的 `_isCjkChar` / `_isWordChar` 手写码点表。它的思路（CJK 按字、
/// 西文连续串按词）是对的，也是全仓三套口径里唯一对西文正确的一套，所以 2026-09 把
/// 它**提升**成了共享原语，而不是再抄一份：EPUB / 漫画 / 视频字幕 / galgame 现在同
/// 口径，`study_segments.chars` 这一列才第一次真正可加。
///
/// 提升带来的行为变化（都是修正，galgame 既有断言全部仍然成立）：泰 / 老挝 / 高棉等
/// 文字从「记 0」变成按码点计；阿拉伯 harakat、天城文 matra 等组合记号从「断词」变成
/// 透明；词内撇号透明，`don't` 从 2 个词变成 1 个。
int countGalgameChars(String text) => countStudyChars(text);

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

  /// 上游已经算好增量时的计数入口：只做 [countGalgameChars] + [maxCountedChars]
  /// 垃圾门，**不碰** [_lastText] / [_lastCount]。
  ///
  /// 为什么不能直接喂 [countLine]：那个方法的相邻去重与打字机前缀拿「整行」当状态，
  /// 喂增量片段会把 `_lastText` 污染成半句话，此后每次判断都是拿增量比增量；两次
  /// 相邻增量恰好相同时还会被静默吞成 0（在上游折叠之上再去重一次）。
  ///
  /// 引擎 hook 路径用它（TexthookerService 的折叠已经是「这一拍新增了什么」的
  /// 权威）；WS / 剪贴板路径仍走 [countLine]——那边没有上游折叠，整行去重与打字机
  /// 增量只有这一份。
  int countDelta(String delta) {
    final String trimmed = delta.trim();
    if (trimmed.isEmpty) return 0;
    // 相邻**完全相同**的一拍仍要去重：上游折叠只吞「同一句越写越长」
    // （`isProgressiveTextUpdate` 对等长文本直接返回 false），引擎把同一句
    // 原样重发一次时折不掉，会作为新行进来、增量就是整句。BUG-1085 钉的就是
    // 这条。它与 [countLine] 的打字机前缀去重不同：这里只比「上一次的增量」，
    // 不维护整行状态，所以不会被增量污染成半句话。
    if (trimmed == _lastDelta) return 0;
    _lastDelta = trimmed;
    final int count = countGalgameChars(trimmed);
    return count > maxCountedChars ? 0 : count;
  }

  String? _lastDelta;

  /// 会话结束/换游戏时复位，下一段从零开始（跨会话不做前缀/去重比对）。
  void reset() {
    _lastText = null;
    _lastDelta = null;
    _lastCount = 0;
  }
}
