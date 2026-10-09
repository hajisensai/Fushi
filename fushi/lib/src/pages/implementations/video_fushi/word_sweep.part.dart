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
/// 纯逻辑（分词 + grapheme 折算 + 循环推进）在 [SubtitleSweepToken] /
/// [buildSubtitleSweepTokens] / [advanceSubtitleSweepIndex]，可直接单测；本文件只做
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
  /// 扫词「下一词 / 上一词」的单一执行体：键盘与手柄两条通道都调它。
  ///
  /// 契约：
  /// * **不进 caret**：光标激活时直接返回（正常路径下光标已在更前面吞掉这些键，这里是
  ///   双保险），扫词绝不与光标同时活动。
  /// * **过沉浸锁门**：沉浸锁定态不允许查词，给一条 OSD 说明而不是静默无反应。
  /// * **只复用既有链路**：定位到词的 `charRect` / `cue` 后交给
  ///   [_handleSubtitleLookupTap]（它再走 `_lookupAt` 的 `replaceStack` + `reuseWarmSlot`
  ///   热槽复用，连扫不闪、不叠栈）。
  /// * **句尾循环**：由 [advanceSubtitleSweepIndex] 保证（用户拍板）。
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
    final int length = _wordSweep.tokens.length;
    if (length == 0) return;

    _wordSweep.index = advanceSubtitleSweepIndex(
      _wordSweep.index,
      length,
      forward: forward,
    );
    final SubtitleSweepToken token = _wordSweep.tokens[_wordSweep.index];

    // 词首字的屏幕矩形 + 该字所属 cue：两者都从 overlay 的字符登记表取（与点击查词
    // 同源），制卡的句子音频因此锚在用户正在看的那句上。
    final SubtitleCharHit? hit = _sweepHitForGrapheme(token.graphemeStart);
    if (hit == null) return;

    _handleSubtitleLookupTap(
      hit.sentence,
      hit.graphemeIndex,
      hit.charRect,
      hit.cue,
    );
    // OSD 提示被查的词：字幕可能被浮层盖住，OSD 是「现在扫到哪个词」的可靠反馈。
    _showOsd(token.word);
  }

  /// 取当前句里 grapheme 下标 [target] 处的字符命中项。
  ///
  /// 精确命中优先；找不到时退到**同句里下标最大的、仍 >= target 的**那一项——分词单元
  /// 可能落在 overlay 未登记的字上（空白 / 模糊字符），此时就近取下一个已登记字，仍能
  /// 查到该位置的词，而不是整格静默跳过。
  SubtitleCharHit? _sweepHitForGrapheme(int target) {
    final int count = _subtitleHitTester.caretEntryCount();
    SubtitleCharHit? nearestAfter;
    for (int i = 0; i < count; i++) {
      final SubtitleCharHit? hit = _subtitleHitTester.caretHitAt(i);
      if (hit == null || hit.sentence != _wordSweep.sentence) continue;
      if (hit.graphemeIndex == target) return hit;
      if (hit.graphemeIndex > target &&
          (nearestAfter == null ||
              hit.graphemeIndex < nearestAfter.graphemeIndex)) {
        nearestAfter = hit;
      }
    }
    return nearestAfter;
  }
}
