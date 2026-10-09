part of '../video_fushi_page.dart';

/// 暂停句「整句扫词」的页面态与执行体（手柄查词的无光标形态，2026-10-09）。
///
/// 与 [videoEnterCaret] 的字级光标**互不依赖**，这是本功能存在的全部理由：
///
/// * 光标是**模态**——`_handleCaretGamepadButton` 在注册表解析之前接管，除
///   dpad/A/B/LT/RT 外**一律吞掉**（见 `video_fushi/subtitle_caret.part.dart`），
///   而 `CaretAction` 的动作表里根本没有「制卡」，于是光标激活后手柄 X 制卡永远
///   不可达（用户报的「进光标后再也制不了卡」）。
/// * 扫词**不进任何模态**：只移动一个数据词游标，每停一词就经
///   [_handleSubtitleLookupTap] → `_lookupAt` 复用点击查词的同一条链路弹/换浮层。
///   浮层可见时 `tryDictionaryPopupGamepadButton` 照常被调用，故 A=翻词条 /
///   X=制卡 / Y=发音全部重回可达。
///
/// 纯逻辑（分词 + grapheme 折算 + 循环推进 + 落点）在 [SubtitleSweepToken] /
/// [buildSubtitleSweepTokens] / [advanceSubtitleSweepIndex] /
/// [resolveSubtitleSweepStop]，可直接单测；本文件只做
/// 「取页面态 → 调纯函数 → 驱动既有查词链路 → OSD」。

/// 扫词会话状态（仅内存，不持久化）：当前句、它的词序列、以及词游标。
///
/// 句变即重建（见 [_VideoWordSweep._sweepSubtitleWord]），故换句 / 换集后不会把旧句的
/// 下标用到新句上；同句重按则继续上一次的位置。放在独立的可变小对象里，是为了让主
/// 页面壳只多一个字段、不把三份互相关联的状态摊进 [VideoFushiPage] 的字段区。
class _WordSweepState {
  /// 当前正在扫的句子（与字幕 overlay 的 `SubtitleCharHit.sentence` 同源）。
  String? sentence;

  /// 该句的扫词单元（首字 grapheme 下标 + 词）。
  List<SubtitleSweepToken> tokens = const <SubtitleSweepToken>[];

  /// 当前词在 [tokens] 里的下标；-1 = 尚未开始（由
  /// [advanceSubtitleSweepIndex] 决定首次落点：前向=0、后向=末词）。
  int index = -1;

  void reset() {
    sentence = null;
    tokens = const <SubtitleSweepToken>[];
    index = -1;
  }
}

extension _VideoWordSweep on _VideoFushiPageState {
  /// 扫词动作的**唯一派发点**：键盘 / 手柄 / 鼠标 / 浮层回传 token 四条输入通道
  /// 解析出动作后都先问它。[action] 是扫词动作就执行并返回 true（消费），否则返回
  /// false 交回各通道的后续分支——各通道不再各自写一份 `if (action == …)`。
  bool _runWordSweepAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.videoLookupNextWord:
        _sweepSubtitleWord(forward: true);
        return true;
      case ShortcutAction.videoLookupPrevWord:
        _sweepSubtitleWord(forward: false);
        return true;
      default:
        return false;
    }
  }

  /// 扫词「下一词 / 上一词」的单一执行体（经 [_runWordSweepAction] 派发）。
  ///
  /// 契约：
  /// * **不进 caret**：光标激活时直接返回（正常路径下光标已在更前面吞掉这些键，这里是
  ///   双保险），扫词绝不与光标同时活动。
  /// * **过沉浸锁门**：沉浸锁定态不允许查词，给一条 OSD 说明而不是静默无反应。
  /// * **只复用既有链路**：定位到词的 `charRect` / `cue` 后交给
  ///   [_handleSubtitleLookupTap]（它再走 `_lookupAt` 的 `replaceStack` + `reuseWarmSlot`
  ///   热槽复用，连扫不闪、不叠栈）。
  /// * **句尾循环**：由 [advanceSubtitleSweepIndex] 保证（用户拍板）。
  /// * **跳过查不到的词**：落点由 [resolveSubtitleSweepStop] 决定（词内第一个已登记字；
  ///   整词无已登记字则跳过，最多一圈，整句都没有就无反馈地停下）。
  ///
  /// [forward] true = 下一个词，false = 上一个词。
  void _sweepSubtitleWord({required bool forward}) {
    // 与字级光标互斥：光标是模态查词原语，扫词是数据游标查词，二者不并存。
    if (_videoCaretActive) return;
    // 沉浸锁定态禁查词（与 [_handleSubtitleLookupTap] 同一道门），给 OSD 而不是静默。
    if (!_immersiveAllowsLookup) {
      _showOsd(t.video_immersive_locked);
      return;
    }

    // 锚点 = 当前可见字幕里第一个**可选**字符（与进光标用同一个真相源）。没有可选字幕
    // （无字幕 / 全模糊 / 尚未渲染）时无事可做。
    final int anchorEntry = _subtitleHitTester.caretAnchorEntry();
    if (anchorEntry < 0) return;
    final SubtitleCharHit? anchor = _subtitleHitTester.caretHitAt(anchorEntry);
    if (anchor == null || anchor.sentence.isEmpty) return;

    // 句变即重建（换句 / 换集 / 切曲后旧下标不可用）；同句继续上次位置。
    if (_wordSweep.sentence != anchor.sentence || _wordSweep.tokens.isEmpty) {
      _wordSweep.sentence = anchor.sentence;
      _wordSweep.tokens = buildSubtitleSweepTokens(anchor.sentence);
      _wordSweep.index = -1;
    }
    if (_wordSweep.tokens.isEmpty) return;

    // 词首字的屏幕矩形 + 该字所属 cue：两者都从 overlay 的字符登记表取（与点击查词
    // 同源），制卡的句子音频因此锚在用户正在看的那句上。
    final Map<int, SubtitleCharHit> hits = _sweepHitsForSentence(
      anchor.sentence,
    );
    final SubtitleSweepStop? stop = resolveSubtitleSweepStop(
      tokens: _wordSweep.tokens,
      index: _wordSweep.index,
      forward: forward,
      selectableGraphemes: hits.keys.toSet(),
    );
    if (stop == null) return;
    _wordSweep.index = stop.tokenIndex;
    final SubtitleCharHit hit = hits[stop.graphemeIndex]!;

    _handleSubtitleLookupTap(
      hit.sentence,
      hit.graphemeIndex,
      hit.charRect,
      hit.cue,
    );
    // OSD 提示被查的词：字幕可能被浮层盖住，OSD 是「现在扫到哪个词」的可靠反馈。
    _showOsd(_wordSweep.tokens[stop.tokenIndex].word);
  }

  /// 当前可见字幕里属于 [sentence] 的已登记字符命中项，按 grapheme 下标索引（同一
  /// 下标登记多次时取第一项）。没登记的字（空白 / 被模糊遮住）不在表里——
  /// [resolveSubtitleSweepStop] 正是靠这一点跳过查不到的词。
  Map<int, SubtitleCharHit> _sweepHitsForSentence(String sentence) {
    final int count = _subtitleHitTester.caretEntryCount();
    final Map<int, SubtitleCharHit> hits = <int, SubtitleCharHit>{};
    for (int i = 0; i < count; i++) {
      final SubtitleCharHit? hit = _subtitleHitTester.caretHitAt(i);
      if (hit == null || hit.sentence != sentence) continue;
      hits.putIfAbsent(hit.graphemeIndex, () => hit);
    }
    return hits;
  }
}
