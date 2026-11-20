/// 漫画阅读器「查词时暂停」：查词出现时把正在播的朗读 / 漫画有声按住，所有查词都
/// 关掉后恢复；查词前本来就停着的不动。
///
/// 查词有两个来源（[MangaLookupSource]）：页内弹窗（BUG-4907）与第二块屏的伴侣查词
/// （BUG-4908，副屏开着时主屏点字的查词也显示在那边）。两边可能同时开着，所以这里记
/// 「哪些来源还开着」，全部关掉才放手——不让一边关掉就把另一边还在看的查词底下的播放
/// 恢复起来。
///
/// 恢复时可「从被查那句的句首重播」（BUG-4909，与小说阅读器共用
/// `ReaderFushiSource.restartSentenceAfterLookup`）：主屏点 OCR 字查词时阅读器先
/// [noteSentence] 记下被查的句子（页 + OCR 块），这次查词按住的播放恢复时带上它；副屏
/// 面板上自己发起的查词没有被查句，恢复时由音源退到当前句句首。
///
/// 开关与小说阅读器共用「查词时暂停」（`ReaderFushiSource.pauseOnLookup`）。两种音源
/// （成品音频驱动 / 现场合成控制器）由阅读器适配成 [MangaLookupPausable] 交进来。
library;

/// 查词的来源。
enum MangaLookupSource {
  /// 阅读器自己的查词弹窗栈。
  page,

  /// 第二块屏的伴侣查词。
  companion,
}

/// 被查的句子：第 [pageIndex] 页的 OCR 块 [blocks]。
typedef MangaLookupSentence = ({int pageIndex, List<int> blocks});

/// 能被查词按住的播放。
abstract interface class MangaLookupPausable {
  /// 此刻在出声（或正在为出声做准备：合成 / 等页文字）。
  bool get isRunning;

  void pause();

  /// 恢复被按住的播放；用户这期间自己已经恢复或停掉时由实现自行跳过。
  ///
  /// [restartSentence] 为 true 时从句首重播：[sentence] 非空就是被查的那句（对不上
  /// 任何句子时退到当前句），为空就是当前句；为 false 时原地续播。
  void resume({required bool restartSentence, MangaLookupSentence? sentence});
}

class MangaLookupPause {
  bool _held = false;
  final Set<MangaLookupSource> _open = <MangaLookupSource>{};

  /// 主屏刚选中、还没被哪次查词认领的句子（[noteSentence]）。
  MangaLookupSentence? _pending;

  /// 按住期间最近一次带句子的查词所查的句子。
  MangaLookupSentence? _sentence;

  /// 查词正按住播放。
  bool get held => _held;

  /// 还开着的查词来源。
  Set<MangaLookupSource> get openSources =>
      Set<MangaLookupSource>.unmodifiable(_open);

  /// 主屏点 OCR 字要查词了（弹窗或副屏随后打开）：记下被查的句子，由接下来那次
  /// [lookupOpened] 认领。
  void noteSentence(MangaLookupSentence? sentence) => _pending = sentence;

  /// [source] 的查词出现（每层弹窗 / 每个新查词都会来，幂等）。在播且 [enabled] 时
  /// 暂停并按住；已按住的不重复按。
  void lookupOpened(
    MangaLookupSource source,
    MangaLookupPausable? playback, {
    required bool enabled,
  }) {
    _open.add(source);
    final MangaLookupSentence? noted = _pending;
    _pending = null;
    if (noted != null) _sentence = noted;
    if (_held) return;
    if (!enabled || playback == null || !playback.isRunning) return;
    playback.pause();
    _held = true;
  }

  /// [source] 的查词关闭。[resume]：用户关的（false = 副屏带着开着的查词走了，只放手
  /// 不起播）。其它来源还开着就继续按住；全部关掉才放手，[restartSentence] 决定从
  /// 句首重播还是原地续播。
  void lookupClosed(
    MangaLookupSource source,
    MangaLookupPausable? playback, {
    required bool resume,
    required bool restartSentence,
  }) {
    _open.remove(source);
    if (_open.isNotEmpty) return;
    final MangaLookupSentence? sentence = _sentence;
    _sentence = null;
    if (!_held) return;
    _held = false;
    if (!resume) return;
    playback?.resume(restartSentence: restartSentence, sentence: sentence);
  }

  /// 用户停掉 / 换了音源：撤掉按住，之后关查词不再恢复。
  void drop() {
    _held = false;
    _sentence = null;
  }
}
