import 'package:hibiki_audio/hibiki_audio.dart';

/// 单句草稿条目：一次查词时累积的「这一句」+ 可选句子音频区间。
///
/// [sentence] 永远是宿主裁好的整句文本（reader `getSentenceContext`）。
/// [audioRange] 只有有声书/歌词模式才有值，纯阅读时为 null。多句合并制卡时由
/// [MiningSentenceDraft] 把各条 [audioRange] 收敛成首句起→末句止的合并区间；跨章/
/// 跨音频文件无法合并时退化为「只合文本」（[mergeMiningAudioRanges] 返回 null）。
class MiningDraftSentence {
  const MiningDraftSentence({
    required this.sentence,
    this.audioRange,
  });

  final String sentence;
  final AudioPlaybackRange? audioRange;
}

/// 会话级「查词窗口多句合一制卡」草稿缓冲（TODO-393 句子上下文再设计）。
///
/// 数据模型语义（TODO-393 取代 TODO-382 的「单按钮逐句追加」；TODO-405 弹窗 UI 改➕➖
/// 递增递减步进器）：草稿不再是一串自由累积的句子，而是围绕「当前正查句」的**有方向上
/// 下文**——[prevSentences]（上 N 句，紧挨当前句之前）与 [nextSentences]（下 N 句，紧挨
/// 当前句之后）。用户在弹窗里点➕➖递增/递减「上 N 句 / 下 N 句」时，宿主一次性把那 N 句
/// 解析出来 [setContext] 设进来（**整体替换**而非追加），故步进器把句数升到 2 会整体覆盖
/// 句数 1，不会越攒越多。制卡时 [composeText] 按「上 → 当前 → 下」顺序合成 sentence 字段，
/// 音频区间按同序合并。
///
/// 为什么要整体替换而非逐句追加：用户原话「+句改成上 1/2/3…句、下 1/2/3…句（点➕➖递增
/// 递减）」——这是一个「选多少句上下文」的标量选择，不是「再加一句」的累加动作。换词查询
/// （新 lookup）时宿主 [clear]，故每次查词的上下文都从零开始，不带上一个词的句子（修缓存
/// 串味）。
///
/// 三表面（书籍/有声书/视频）共用同一套草稿模型。
///
/// 纯状态容器：不持有任何 UI/平台句柄，可单测。
class MiningSentenceDraft {
  List<MiningDraftSentence> _prev = const <MiningDraftSentence>[];
  List<MiningDraftSentence> _next = const <MiningDraftSentence>[];

  /// 当前已选的「上 N 句」（紧挨当前句之前，按阅读顺序：最靠前的句在 [0]）。
  List<MiningDraftSentence> get prevSentences =>
      List<MiningDraftSentence>.unmodifiable(_prev);

  /// 当前已选的「下 N 句」（紧挨当前句之后，按阅读顺序：最靠后的句在末尾）。
  List<MiningDraftSentence> get nextSentences =>
      List<MiningDraftSentence>.unmodifiable(_next);

  /// 草稿是否为空（没有选任何上下文句）。
  bool get isEmpty => _prev.isEmpty && _next.isEmpty;

  /// 已选上下文句总条数（上 N + 下 N）。弹窗角标用它显示「已加 N 句」。
  int get length => _prev.length + _next.length;

  /// 整体设置上下文：[prev]（上 N 句，阅读顺序）与 [next]（下 N 句，阅读顺序）。
  /// 空白/纯空格句被过滤（不污染计数与合并文本）。**整体替换**当前上下文——
  /// 用户改选「上 1 句→上 2 句」时调用方传新一组，不会与上一组叠加。
  void setContext({
    List<MiningDraftSentence> prev = const <MiningDraftSentence>[],
    List<MiningDraftSentence> next = const <MiningDraftSentence>[],
  }) {
    _prev = <MiningDraftSentence>[
      for (final MiningDraftSentence e in prev)
        if (e.sentence.trim().isNotEmpty) e,
    ];
    _next = <MiningDraftSentence>[
      for (final MiningDraftSentence e in next)
        if (e.sentence.trim().isNotEmpty) e,
    ];
  }

  /// 清空草稿（制卡成功、换词查询或关闭弹窗栈后调用）。
  void clear() {
    _prev = const <MiningDraftSentence>[];
    _next = const <MiningDraftSentence>[];
  }

  /// 把「上 N 句 + 当前句 + 下 N 句」按阅读顺序合成最终 sentence 字段文本。
  /// [currentSentence] 是制卡时弹窗里正查的那一句（夹在上下文中间）。
  String composeText(String currentSentence) {
    final List<String> all = <String>[
      for (final MiningDraftSentence entry in _prev) entry.sentence,
      currentSentence,
      for (final MiningDraftSentence entry in _next) entry.sentence,
    ];
    return joinMinedSentences(all);
  }

  /// 把「上 N 句区间 + 当前句区间 + 下 N 句区间」按阅读顺序合并成一个区间。
  /// 跨音频文件无法合并时返回 null（调用方退化为只合文本）。
  AudioPlaybackRange? composeAudioRange(AudioPlaybackRange? currentRange) {
    return mergeMiningAudioRanges(<AudioPlaybackRange?>[
      for (final MiningDraftSentence entry in _prev) entry.audioRange,
      currentRange,
      for (final MiningDraftSentence entry in _next) entry.audioRange,
    ]);
  }
}

/// 把多句合成一段制卡用文本。纯函数（无副作用、可单测）。
///
/// 与视频 `buildSelectedSubtitleCueContext` 的 `join('\n')` 语义一致：逐句 trim、
/// 丢弃空句、用换行连接。单句时等价于原行为（trim 后直接返回）。
String joinMinedSentences(List<String> sentences) {
  return sentences
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .join('\n');
}

/// 把一组（可能含 null 的）句子音频区间合并成「首句起→末句止」的单一区间。
///
/// 合并语义（乙方案·与设计文档一致）：
/// - 过滤掉 null（纯阅读句没有音频区间，不参与）。
/// - 全部为 null → 返回 null（无音频可合）。
/// - 所有非空区间必须落在同一 `audioFileIndex`；一旦跨音频文件（跨章/跨文件）→
///   返回 null，调用方据此退化为「只合文本」，**绝不静默拼接坏音频**。
/// - 同文件内取最小 start、最大 end（首句起→末句止）。
///
/// 纯函数，可单测。
AudioPlaybackRange? mergeMiningAudioRanges(List<AudioPlaybackRange?> ranges) {
  final List<AudioPlaybackRange> present = <AudioPlaybackRange>[
    for (final AudioPlaybackRange? range in ranges)
      if (range != null) range,
  ];
  if (present.isEmpty) return null;

  final int fileIndex = present.first.audioFileIndex;
  int startMs = present.first.startMs;
  int endMs = present.first.endMs;
  for (final AudioPlaybackRange range in present) {
    // 跨音频文件无法合并：退化为只合文本（返回 null）。
    if (range.audioFileIndex != fileIndex) return null;
    if (range.startMs < startMs) startMs = range.startMs;
    if (range.endMs > endMs) endMs = range.endMs;
  }
  return AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}
