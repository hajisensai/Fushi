import '../audiobook/audiobook_model.dart';
import 'epub_srt_matcher.dart';

/// 把正文**句内**的短碎片并回相邻 cue（设备端转录产物专用，换正文 + 能量吸附之后跑）。
///
/// 重切器只在正文句末加切点，但 ASR 原有的 cue 边界只要落在标点 / 空白间隙上就
/// 原样保留——朗读者在「、」「──」后换气，VAD 就在那里切开。结果是一句话被切成
/// 「何か、」「おかしい。」两条，前一条只亮 0.5 s 就换掉：七魔剑 II 整卷 8143 条里
/// 754 条不足 0.8 s，其中以「、」结尾 259 条、以「──」结尾 76 条（对照 YuiMoe 一句
/// 一条，159 条）。
///
/// 规则：相邻两条都是命中 cue、同一章、正文区间首尾相接、同一音频文件，前一条在
/// 正文里**不是句末**（见 [isSentenceEnd]），且任一侧短于 [shortMs]——合并后不超过
/// [maxChars] 字、[maxDurationMs] 毫秒、中间停顿不超过 [maxGapMs]，就并成一条
/// （起点取前条、终点取后条，文本与 token 时间首尾相接）。可连锁并多段。
///
/// 只并不拆，正文区间并集不变——覆盖率与阅读器定位不受影响；跨句、跨章、未命中
/// 的 cue 一律不碰。
class CueFragmentMerger {
  const CueFragmentMerger({
    this.shortMs = 1200,
    this.maxChars = 40,
    this.maxDurationMs = 10000,
    this.maxGapMs = 1500,
  });

  /// 任一侧短于此值才并（两侧都够长的句内停顿保持分开，长句照常分屏）。
  final int shortMs;

  /// 合并后的正文字数上限（含标点）。
  final int maxChars;

  /// 合并后的时长上限。
  final int maxDurationMs;

  /// 两条之间的停顿上限：再长就是朗读者真的停住了，分开显示更贴声音。
  final int maxGapMs;

  /// 句末字符：句号类、闭引号 / 闭括号。省略号与破折号不算（「だが──」常接下文）。
  static const String _terminators = '。！？!?」』）)】〕〉》';

  /// 正文里 `text` 是否以句末结束。`．` / `.` 紧跟拉丁字母时是缩写（`Ｍｓ．`），不算。
  static bool isSentenceEnd(String text) {
    final String t = text.trimRight();
    if (t.isEmpty) return true;
    final String last = t[t.length - 1];
    if (_terminators.contains(last)) return true;
    if (last == '．' || last == '.') {
      if (t.length < 2) return true;
      return !_isLatinLetter(t.codeUnitAt(t.length - 2));
    }
    return false;
  }

  static bool _isLatinLetter(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xFF21 && c <= 0xFF3A) ||
      (c >= 0xFF41 && c <= 0xFF5A);

  /// 返回合并后的 cue 与对应匹配（一一对应）；没有可并的就原样返回同一对象。
  ({List<AudioCue> cues, MatchResult result, int merged}) merge({
    required List<AudioCue> cues,
    required MatchResult result,
  }) {
    final List<CueMatch> matches = result.matches;
    if (matches.length != cues.length || cues.length < 2) {
      return (cues: cues, result: result, merged: 0);
    }
    final List<AudioCue> outCues = <AudioCue>[];
    final List<CueMatch> outMatches = <CueMatch>[];
    int merged = 0;
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final CueMatch m = matches[i];
      if (outCues.isNotEmpty &&
          _canJoin(outCues.last, outMatches.last, cue, m)) {
        final AudioCue prev = outCues.last;
        final CueMatch pm = outMatches.last;
        outCues[outCues.length - 1] = _join(prev, cue);
        outMatches[outMatches.length - 1] = CueMatch(
          cueSentenceIndex: pm.cueSentenceIndex,
          sectionIndex: pm.sectionIndex,
          normCharStart: pm.normCharStart,
          normCharEnd: m.normCharEnd,
          score: pm.score < m.score ? pm.score : m.score,
        );
        merged++;
        continue;
      }
      outCues.add(cue);
      outMatches.add(m);
    }
    if (merged == 0) return (cues: cues, result: result, merged: 0);
    return (
      cues: outCues,
      result: MatchResult(
        matches: outMatches,
        totalCues: outCues.length,
        matchedCues: outMatches.where((CueMatch x) => x.matched).length,
        gapFill: result.gapFill,
      ),
      merged: merged,
    );
  }

  bool _canJoin(AudioCue a, CueMatch am, AudioCue b, CueMatch bm) {
    if (!am.matched || !bm.matched) return false;
    if (am.sectionIndex != bm.sectionIndex) return false;
    if (am.normCharEnd != bm.normCharStart) return false;
    if (a.audioFileIndex != b.audioFileIndex) return false;
    if (isSentenceEnd(a.text)) return false;
    final int gap = b.startMs - a.endMs;
    if (gap < 0 || gap > maxGapMs) return false;
    if (a.endMs - a.startMs >= shortMs && b.endMs - b.startMs >= shortMs) {
      return false;
    }
    if (b.endMs - a.startMs > maxDurationMs) return false;
    return a.text.length + b.text.length <= maxChars;
  }

  static AudioCue _join(AudioCue a, AudioCue b) {
    final CueTokenTiming? ta = a.tokenTiming;
    final CueTokenTiming? tb = b.tokenTiming;
    CueTokenTiming? timing;
    if (ta != null && tb != null) {
      final int shift = b.startMs - a.startMs;
      timing = CueTokenTiming(
        tokens: List<String>.unmodifiable(<String>[...ta.tokens, ...tb.tokens]),
        offsetsMs: List<int>.unmodifiable(<int>[
          ...ta.offsetsMs,
          for (final int o in tb.offsetsMs) o + shift,
        ]),
      );
    }
    return AudioCue()
      ..bookKey = a.bookKey
      ..chapterHref = a.chapterHref
      ..sentenceIndex = a.sentenceIndex
      ..textFragmentId = a.textFragmentId
      ..text = a.text + b.text
      ..startMs = a.startMs
      ..endMs = b.endMs
      ..audioFileIndex = a.audioFileIndex
      ..tokenTiming = timing;
  }
}
