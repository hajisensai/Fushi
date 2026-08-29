/// 「一句台词被引擎分多次吐出来」的折叠判据。
///
/// 背景（用户报的 Zato 症状）：一段台词分多次点击逐步显示，引擎每次点击都重绘整条
/// 文本行，于是 hook 依次拿到
///
/// ```text
/// 1. Some would call it a miracle.                                   ← 第一次点击
/// 2. And of course, that's a lovely way to put it...                 ← 第二次点击画的新段
/// 3. Some would call it a miracle. And of course, that's a lovely... ← 同一次点击重绘的整行
/// ```
///
/// 三条都是独立的新行 → 工作台里第二句出现两次，字数被重复统计，浮窗还会连闪三次。
///
/// native 侧已有的两个过滤器都盖不到这一形状：`LunaNormalizedTextLength` 只折
/// 「s1 s1 s2 s2」式的成对重复块，`LunaTextIsArtifact` 只认整串二倍 / 等长游程 /
/// 相邻同字。前缀累积在它们的判据下是两条毫不相干的串。
///
/// 本仓在**浏览器扩展**里早就处理过同一形状（BUG-1029，`content.js` 的
/// `fushiIsProgressiveCueUpdate`：当前文本是上一快照的严格前缀就就地扩写，换句才
/// 新建）。这里把同一条判据搬到 galgame hook 管线，并放宽成**双向**：上面第 3 条
/// 里旧文本是新文本的*后缀*而不是前缀。
library;

/// 折叠比较前的归一化：去掉全部空白。
///
/// 引擎重绘时经常在段之间插换行 / 全角空格，逐字节比较会把「同一句的两次快照」判成
/// 两句不同的话。
String normalizeForFold(String text) {
  return text.replaceAll(RegExp(r'\s+'), '');
}

/// 短于这个长度的行不参与折叠。
///
/// 「はい」「……」这类极短行做包含判断的假阳性率太高（任何长句都可能刚好以它开头或
/// 结尾）。取 4 与游戏内制卡回溯那条模糊匹配（要求 >= 8）同一思路，只是这里只跟
/// **紧邻的上一行**比，链条一旦被无关行打断就重新开始，可以更宽松一点。
const int kMinFoldableLength = 4;

/// [previous] 与 [next] 是否是「同一句的两次快照」。
///
/// 判据（全部要满足）：
/// - 归一化后两者长度**不等** —— 完全相同的两行不折。游戏确实会连着输出两遍同样的
///   「……」，那是既有行为，本函数不改它。
/// - 短的那条是长的那条的**前缀或后缀**（不接受任意中缀：中缀命中的假阳性太高）。
/// - 短的那条归一化后不短于 [kMinFoldableLength]。
bool isProgressiveTextUpdate(String previous, String next) {
  final String a = normalizeForFold(previous);
  final String b = normalizeForFold(next);
  if (a.isEmpty || b.isEmpty) return false;
  if (a.length == b.length) return false;

  final String shorter = a.length < b.length ? a : b;
  final String longer = a.length < b.length ? b : a;
  if (shorter.length < kMinFoldableLength) return false;

  return longer.startsWith(shorter) || longer.endsWith(shorter);
}
