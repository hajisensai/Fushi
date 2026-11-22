part of '../reader_fushi_page.dart';

/// 阅读器「整句扫词」的执行体（拍板台 5H922XeDHM，照视频页
/// `video_fushi/word_sweep.part.dart` 的契约）：手柄 / 键盘查词的**无光标**形态。
///
/// * 不进字级光标、不弹模态：只在当前句里移动一个数据词游标（[ReaderWordSweepSession]），
///   每停一词就经 [ReaderWordSweepScripts.lookupInvocation] 走与光标查词逐字相同的
///   `selectFromPosition` → `onTextSelected` → [_ReaderLookup._handleTextSelected]
///   链路弹 / 换同一张弹窗。因为光标不激活（[_caretSurface] 保持 none），弹窗渲染时
///   光标不会被 transfer 进弹窗，焦点按指针查词那条路收回正文，于是方向键、翻页键、
///   弹窗的 X=制卡 / Y=发音全部照常可达。
/// * 当前词的提示是查词本身的行内选区高亮（与点词同一份 `fushi-selection`）。
/// * 句尾循环、跳过整词不可见 / 不可查的词：规则见 [resolveReaderWordSweepStop]。
/// * 正文三种视图（paginated / continuous / vn）与有声书歌词视图共用；句子与可见判据在
///   JS 侧（[ReaderWordSweepScripts]）。
class _ReaderWordSweepState {
  final ReaderWordSweepSession session = ReaderWordSweepSession();

  /// 一次扫词（取句 → 查词两次 JS 往返）在途：再按直接丢弃，与字级光标的 busy 同规则，
  /// 防止连按把两次往返交错成「查到的不是游标停的词」。
  bool busy = false;
}

extension _ReaderWordSweep on _ReaderFushiPageState {
  /// 扫词动作的**唯一派发点**：键盘 / 手柄 / 鼠标（经 [_ReaderCaret._executeShortcutAction]）
  /// 与弹窗回传 token（[_ReaderFushiPageState.onDictionaryPopupInputToken]）都先问它。
  /// [action] 是扫词动作就执行并返回 true（消费），否则返回 false。
  bool _runReaderWordSweepAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.readerLookupNextWord:
        unawaited(_sweepReaderWord(forward: true));
        return true;
      case ShortcutAction.readerLookupPrevWord:
        unawaited(_sweepReaderWord(forward: false));
        return true;
      default:
        return false;
    }
  }

  /// 扫词「下一个词 / 上一个词」的单一执行体（经 [_runReaderWordSweepAction] 派发）。
  ///
  /// 光标激活时让位：光标是模态查词原语，扫词是数据游标查词，两者不并存。
  Future<void> _sweepReaderWord({required bool forward}) async {
    if (_caretActive) return;
    if (_wordSweep.busy) return;
    final InAppWebViewController? surface = _surfaceController;
    if (surface == null || !_readerContentReady) return;
    if (_lyricsMode && !_lyricsPageReady) return;
    _wordSweep.busy = true;
    try {
      final Object? raw = await surface.evaluateJavascript(
        source: ReaderWordSweepScripts.sentenceInvocation(),
      );
      // 往返期间进了光标 / 切了歌词层 / 页面销毁：这一步作废。
      if (!mounted || _caretActive || !identical(surface, _surfaceController)) {
        return;
      }
      final ReaderWordSweepSentence? sentence =
          ReaderWordSweepScripts.parseSentence(raw);
      if (sentence == null) return;
      final ReaderWordSweepStop? stop = _wordSweep.session.advance(
        sentence,
        forward: forward,
      );
      if (stop == null) return;
      await surface.evaluateJavascript(
        source: ReaderWordSweepScripts.lookupInvocation(sentence.id, stop.unit),
      );
    } finally {
      _wordSweep.busy = false;
    }
  }
}
