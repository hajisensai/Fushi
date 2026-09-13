import 'package:fushi_audio/fushi_audio.dart';

/// 「选择句子上下文」对话框里可被手改文本的三种槽位。
///
/// 用来在 UI ↔ 宿主 ↔ 草稿之间指明「改的是哪一句」，避免各层用裸字符串
/// （'prev'/'current'/'next'）互相比较。[SentenceContextSlot.current] 的 index 恒为 0
/// （当前句只有一句，且不在草稿列表里，见 [MiningSentenceDraft.currentSentenceEdit]）。
enum SentenceContextSlot { prev, current, next }

/// 单句草稿条目：一次查词时累积的「这一句」+ 可选句子音频区间。
///
/// [sentence] 永远是宿主裁好的整句文本（reader `getSentenceContext`）。
/// [audioRange] 只有有声书/歌词模式才有值，纯阅读时为 null。多句合并制卡时由
/// [MiningSentenceDraft] 把各条 [audioRange] 收敛成首句起→末句止的合并区间；跨章/
/// 跨音频文件无法合并时退化为「只合文本」（[mergeMiningAudioRanges] 返回 null）。
///
/// [editedSentence] 是用户在「选择句子上下文」对话框里手改后的文本（未改为 null）。
/// **只改卡片文本、不改音频身份**——与 galgame hook 制卡的 `sentenceOverride` 同一
/// 纪律：[audioRange] 恒为宿主按原句算出的区间，手改错别字/删旁白不该让试听与写卡
/// 的音频区间跟着漂。
class MiningDraftSentence {
  const MiningDraftSentence({
    required this.sentence,
    this.audioRange,
    this.editedSentence,
  });

  final String sentence;
  final AudioPlaybackRange? audioRange;

  /// 用户手改后的文本；null = 没改过，用 [sentence]。
  final String? editedSentence;

  /// 参与合成/预览的实际文本（改过用改后的，没改用原句）。
  String get effectiveSentence => editedSentence ?? sentence;

  /// 换一份手改文本（保留原句与音频区间）。[edited] 传 null 还原成原句。
  MiningDraftSentence withEditedSentence(String? edited) => MiningDraftSentence(
        sentence: sentence,
        audioRange: audioRange,
        editedSentence: edited,
      );
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

  /// 上下文句的手改文本表：**键是原句（trim 后）**，不是下标。
  ///
  /// 为什么不用下标：[setContext] 是整体替换，宿主按新句数重新解析一遍上下文，
  /// 「前加一句」会把已有的前文句整体后移一位——用下标记编辑，用户改完一句再点
  /// 一次「＋」，改动就贴到了别的句子上。原句文本在加减句数时不变，故用它做键，
  /// 编辑能稳定跟着那一句走。代价：同一段里出现两遍的完全相同的句子会被一起改，
  /// 这在语义上也说得通（同样的原句改成同样的新句），故不额外做去重。
  final Map<String, String> _contextEdits = <String, String>{};

  /// 当前句的手改文本（未改为 null）。当前句不在 [_prev]/[_next] 里——它由宿主在
  /// 制卡瞬间现取（reader 的 `currentSentence.text` / 视频的 `_lastLookupSentence`），
  /// 故必须在草稿里单独收口，不能去改 `MediaSource.currentSentence`（那是全局态，
  /// 会连带污染收藏句、落库快照与音频高亮）。
  String? _currentEdit;

  /// 当前句的手改文本；null = 没改过。
  String? get currentSentenceEdit => _currentEdit;

  /// 是否有任何手改（上下文句或当前句）。
  bool get hasEdits => _contextEdits.isNotEmpty || _currentEdit != null;

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
        if (e.sentence.trim().isNotEmpty) _withStoredEdit(e),
    ];
    _next = <MiningDraftSentence>[
      for (final MiningDraftSentence e in next)
        if (e.sentence.trim().isNotEmpty) _withStoredEdit(e),
    ];
  }

  /// 宿主重新解析出来的条目贴回已有的手改文本（见 [_contextEdits] 的键选择说明）。
  /// 调用方传进来的条目若自带 [MiningDraftSentence.editedSentence]，以表里的为准，
  /// 表里没有才保留自带的。
  MiningDraftSentence _withStoredEdit(MiningDraftSentence entry) {
    final String? stored = _contextEdits[entry.sentence.trim()];
    if (stored == null) return entry;
    return entry.withEditedSentence(stored);
  }

  /// 用户在「选择句子上下文」对话框里手改某一句的文本。
  ///
  /// [slot] 指明改的是前文 / 当前句 / 后文；[index] 是该方向列表里的下标
  /// （[SentenceContextSlot.current] 忽略 index）。[text] 与原句相同（trim 后）或为
  /// 空白时**还原**成原句而不是写入空句——空句会被 [joinMinedSentences] 丢掉，等于
  /// 用编辑框当删除键，那是「−」按钮的事。
  ///
  /// 返回是否落地（false = 下标越界，草稿未变）。**只改文本，不动音频区间**。
  bool editSentence({
    required SentenceContextSlot slot,
    required int index,
    required String text,
  }) {
    final String trimmed = text.trim();
    if (slot == SentenceContextSlot.current) {
      _currentEdit = trimmed.isEmpty ? null : trimmed;
      return true;
    }
    final bool prevDir = slot == SentenceContextSlot.prev;
    final List<MiningDraftSentence> list = prevDir ? _prev : _next;
    if (index < 0 || index >= list.length) return false;
    final MiningDraftSentence entry = list[index];
    final String key = entry.sentence.trim();
    final bool restore = trimmed.isEmpty || trimmed == key;
    if (restore) {
      _contextEdits.remove(key);
    } else {
      _contextEdits[key] = trimmed;
    }
    final List<MiningDraftSentence> updated =
        List<MiningDraftSentence>.of(list);
    updated[index] = entry.withEditedSentence(restore ? null : trimmed);
    if (prevDir) {
      _prev = updated;
    } else {
      _next = updated;
    }
    return true;
  }

  /// 清空草稿（制卡成功、换词查询或关闭弹窗栈后调用）。手改文本一并丢弃——
  /// 换了词条/换了句子，上一句的改写没有任何意义。
  void clear() {
    _prev = const <MiningDraftSentence>[];
    _next = const <MiningDraftSentence>[];
    _contextEdits.clear();
    _currentEdit = null;
  }

  /// 把「上 N 句 + 当前句 + 下 N 句」按阅读顺序合成最终 sentence 字段文本。
  /// [currentSentence] 是制卡时弹窗里正查的那一句（夹在上下文中间）。
  String composeText(String currentSentence) {
    final List<String> all = <String>[
      for (final MiningDraftSentence entry in _prev) entry.effectiveSentence,
      _currentEdit ?? currentSentence,
      for (final MiningDraftSentence entry in _next) entry.effectiveSentence,
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

/// 制卡前「上下文预览」纯数据（Niratan「选择句子上下文」模态）：宿主把当前草稿的
/// 真实上下文句（[MiningSentenceDraft.prevSentences] / [nextSentences]，已按阅读顺序）+
/// 当前正查句 [current] + 查到的词在当前句里的字符偏移 [currentOffset] 打包成一个
/// JSON-safe Map 回给弹窗，供其渲染「前文 / 当前句(词高亮) / 后文」三栏预览。
///
/// 返回结构（字段名与 popup.js 的 `sentenceContextPreview` 消费方约定一致）：
/// ```
/// { 'prev': [句...], 'current': '当前句', 'currentOffset': int?, 'next': [句...],
///   'total': prev.length + next.length }
/// ```
/// [currentOffset] 只是给 JS 定位高亮起点用（词的实际表现形由弹窗侧持有），失配时
/// 弹窗回退到首次出现匹配——与卡片渲染 `_sentenceValue` 同一容错策略。纯函数、可单测。
Map<String, Object?> buildSentenceContextPreview({
  required MiningSentenceDraft draft,
  required String current,
  int? currentOffset,
}) {
  final List<String> prev = <String>[
    for (final MiningDraftSentence e in draft.prevSentences) e.effectiveSentence,
  ];
  final List<String> next = <String>[
    for (final MiningDraftSentence e in draft.nextSentences) e.effectiveSentence,
  ];
  // 当前句被手改过就吐改后的文本，并把 offset 置空：偏移是按**原句**算的，套到改后
  // 的文本上会把高亮划在错的位置；置空后消费方回退 indexOf（弹窗侧与卡片渲染
  // `_sentenceValue` 同一容错），命中不了就整句不高亮，比划错强。
  final String? edited = draft.currentSentenceEdit;
  return <String, Object?>{
    'prev': prev,
    'current': edited ?? current,
    'currentOffset': edited == null ? currentOffset : null,
    'next': next,
    'total': prev.length + next.length,
  };
}

/// 把多句合成一段制卡用文本。纯函数（无副作用、可单测）。
///
/// 逐句 trim、丢弃空句、用换行连接。单句时等价于原行为（trim 后直接返回）。
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
