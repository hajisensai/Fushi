/// 歌词模式的阅读单元 = **当前句**（2026-11-10 所有者拍板：歌词模式是独立模式，
/// 有自己的统计逻辑，口径尽量贴近阅读器）。
///
/// 账本仍是 `ReadUnitLedger`（入账额 = 会话翻过的单元并集 ∩ [0, 当前位置)），坐标仍是
/// 全书绝对学习单位偏移——与正文的「页」同一把尺，所以进歌词前在正文翻过的页、歌词里
/// 听过的句子在同一个并集里去重，进出歌词不双计。差别只在单元粒度：正文一页一个
/// 单元（翻页那一刻一次入账一整页），歌词一句一个单元（换句那一刻入账一句），读速
/// 不再是「慢慢掉、翻页猛涨」的锯齿。
///
/// 本函数把一句 cue 的章内学习区间换成全书绝对区间 `[start, end)`：
///  * [chapter] 越界、[offset] 为负、[length] 不为正、章字数表未就绪 → null（不计；
///    与正文「JS 拿不到起止点宁可不计」同律）；
///  * 句子越过章尾的部分夹到章尾（cue 的匹配区间可能跨章，单元只认本章内的那段；
///    夹完为空 → null）。
(int, int)? lyricsCueReadUnit({
  required List<int> chapterCumulativeChars,
  required List<int> chapterCharCounts,
  required int chapter,
  required int offset,
  required int length,
}) {
  if (chapter < 0 ||
      offset < 0 ||
      length <= 0 ||
      chapter >= chapterCumulativeChars.length ||
      chapter >= chapterCharCounts.length) {
    return null;
  }
  final int chapterChars = chapterCharCounts[chapter];
  if (offset >= chapterChars) return null;
  final int endInChapter = offset + length > chapterChars
      ? chapterChars
      : offset + length;
  final int base = chapterCumulativeChars[chapter];
  return (base + offset, base + endInChapter);
}
