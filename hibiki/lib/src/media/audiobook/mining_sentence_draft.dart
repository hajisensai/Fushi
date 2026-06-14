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

/// 会话级「查词窗口多句合一制卡」草稿缓冲（乙方案）。
///
/// 查词时点弹窗「+句」追加当前句到本缓冲，连续查多句累积；制卡时把缓冲 + 当前句
/// 用 [joinMinedSentences] 合成一段文本写入卡片 sentence 字段，制卡后清空。三表面
/// （书籍/有声书/视频）共用同一套草稿模型 —— reader 车道先接线，视频 E 后续复用。
///
/// 纯状态容器：不持有任何 UI/平台句柄，可单测。
class MiningSentenceDraft {
  final List<MiningDraftSentence> _sentences = <MiningDraftSentence>[];

  /// 已累积的草稿句子（只读快照）。
  List<MiningDraftSentence> get sentences =>
      List<MiningDraftSentence>.unmodifiable(_sentences);

  /// 草稿是否为空（没有任何累积句）。
  bool get isEmpty => _sentences.isEmpty;

  /// 已累积的句子条数。
  int get length => _sentences.length;

  /// 追加一句到草稿。空白/纯空格句直接忽略（不污染计数与合并文本）。
  /// 返回 true 表示真的入队（追加了一条），false 表示被忽略。
  bool append(MiningDraftSentence entry) {
    if (entry.sentence.trim().isEmpty) return false;
    _sentences.add(entry);
    return true;
  }

  /// 清空草稿（制卡成功或关闭弹窗栈后调用）。
  void clear() {
    _sentences.clear();
  }

  /// 把「草稿全部句 + 当前句」合成最终 sentence 字段文本。
  /// [currentSentence] 是制卡时弹窗里正查的那一句（草稿尾部还没追加它）。
  String composeText(String currentSentence) {
    final List<String> all = <String>[
      for (final MiningDraftSentence entry in _sentences) entry.sentence,
      currentSentence,
    ];
    return joinMinedSentences(all);
  }

  /// 把「草稿全部句的音频区间 + 当前句区间」合并成一个区间。
  /// 跨音频文件无法合并时返回 null（调用方退化为只合文本）。
  AudioPlaybackRange? composeAudioRange(AudioPlaybackRange? currentRange) {
    return mergeMiningAudioRanges(<AudioPlaybackRange?>[
      for (final MiningDraftSentence entry in _sentences) entry.audioRange,
      currentRange,
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
