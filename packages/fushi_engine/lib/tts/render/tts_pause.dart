/// 制作有声书时句 / 段 / 场景 / 章之间插入的停顿（静音）。
///
/// 引擎自己在句尾留的那点停顿各家不一样，整本听起来节奏发紧或忽快忽慢；这里在
/// 拼接时按句子所处的位置额外插静音。数值是「额外」时长，不是总间隔。
library;

enum TtsPausePreset {
  /// 不额外插停顿（只靠引擎自带的句尾停顿）。
  none(
    sentenceMs: 0,
    paragraphMs: 0,
    sceneMs: 0,
    chapterLeadMs: 0,
    chapterTailMs: 0,
  ),

  /// 通用：段落之间明显换气，场景切换停一拍。
  standard(
    sentenceMs: 150,
    paragraphMs: 600,
    sceneMs: 1500,
    chapterLeadMs: 800,
    chapterTailMs: 2000,
  ),

  /// 文学：停顿更长，适合慢节奏的小说。
  literary(
    sentenceMs: 250,
    paragraphMs: 900,
    sceneMs: 2200,
    chapterLeadMs: 1000,
    chapterTailMs: 3000,
  ),

  /// 紧凑：轻小说 / 对话多的文本。
  brisk(
    sentenceMs: 80,
    paragraphMs: 350,
    sceneMs: 1000,
    chapterLeadMs: 500,
    chapterTailMs: 1500,
  );

  const TtsPausePreset({
    required this.sentenceMs,
    required this.paragraphMs,
    required this.sceneMs,
    required this.chapterLeadMs,
    required this.chapterTailMs,
  });

  /// 同一段落内两句之间。
  final int sentenceMs;

  /// 段落结束后（取代 [sentenceMs]）。
  final int paragraphMs;

  /// 场景分隔（空行 / ◇ ＊ 之类的分隔符）后（取代 [paragraphMs]）。
  final int sceneMs;

  /// 每章开头的静音（ACX 建议 0.5–1 秒）。
  final int chapterLeadMs;

  /// 每章结尾的静音（ACX 建议 1–5 秒）。
  final int chapterTailMs;

  static TtsPausePreset parse(String? raw) {
    for (final TtsPausePreset p in values) {
      if (p.name == raw) return p;
    }
    return TtsPausePreset.standard;
  }

  /// 句子之后应插的停顿：段落 / 场景边界由分句计划标出。
  int afterSentence({
    required bool endsParagraph,
    required bool sceneBreakAfter,
  }) {
    if (sceneBreakAfter) return sceneMs;
    if (endsParagraph) return paragraphMs;
    return sentenceMs;
  }
}
