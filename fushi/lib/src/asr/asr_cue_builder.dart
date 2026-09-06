/// 把 ASR 转录段落变成字幕 cue，并序列化为 SRT。
///
/// 纯函数、无 IO。产物是**单时间轴** SRT（多音频文件按累积时长偏移，与用户从
/// SubPlz 等工具导入的单份 SRT 同一约定），这样整条既有导入链路
/// （`parseCuesForFormat` → Dice 匹配 → `fushi-cue://` 落库 → 阅读器高亮）零改动
/// 即可消费；多文件场景下由 `reindexCuesByFileBoundaries` 还原文件下标。
///
/// 切句与定时规则（对 SubPlz/Whisper 产物「cue 开始太早、切分奇怪」两条抱怨的
/// 直接回应）：
/// - **切句按文本**：在句末标点（。！？!?…）处切，紧随其后的闭合引号/括号并入前句；
///   token 间静默超过 [AsrCueBuilder.gapSplitMs] 也切（VAD 段最长 20 s，段内可能有
///   停顿）。
/// - **边界优先用 VAD 静默边缘**：段首 cue 的起点 = VAD 段起点、段尾 cue 的终点 =
///   VAD 段终点。RNN-T 的 token 发射时间偏晚（模型看到足够上下文才吐字），拿首个
///   token 时间当起点会让高亮比人声慢半拍；静默边缘才是人耳感知的句子边界。
/// - 段内相邻 cue 的分界 = 下一句首 token 时间减 [AsrCueBuilder.leadInMs]（补偿发射
///   延迟），且不早于上一句末 token 时间 + 最小时长。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/asr/asr_types.dart';

/// ASR 产物喂给 Dice 匹配器时建议的相似度阈值。
///
/// 用户自带的 .srt（SubPlz 等）文本就是正文，默认 0.8 合适；ASR 文本有听写差
/// （かな⇄漢字、同音字），bigram Dice 掉得快。2026-09-05 无職転生 01 前 10 分钟真机
/// 对照（`test/asr/realdata/asr_realdata_match_test.dart`）：0.8 → 78.4%，0.7 → 82.7%，
/// 0.6 → 83.8%，0.5 → 84.9%；0.6 以下增益趋平而误配风险上升，取 0.6。
const double kAsrSuggestedSimilarityThreshold = 0.6;

/// 一条待写 SRT 的 cue（全局单时间轴，毫秒）。
@immutable
class AsrCue {
  const AsrCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.audioFileIndex,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// 来源音频文件下标（仅诊断用；SRT 里时间已按累积偏移折成单时间轴）。
  final int audioFileIndex;

  int get durationMs => endMs - startMs;
}

/// 转录段 → cue 的纯函数构造器。
class AsrCueBuilder {
  const AsrCueBuilder({
    this.leadInMs = 150,
    this.gapSplitMs = 1200,
    this.minCueMs = 300,
    this.maxCueMs = 15000,
  });

  /// 段内切句时，下一句起点在其首 token 之前预留的毫秒数（补偿 RNN-T 发射延迟）。
  final int leadInMs;

  /// 相邻 token 之间的静默超过此值就切句（即便没有句末标点）。
  final int gapSplitMs;

  /// cue 最短时长；短于此的 cue 终点后延到该值（不越过下一 cue 起点）。
  final int minCueMs;

  /// 超过此长度且没有任何标点的长句按 token 间最大间隙再切一刀，直到满足。
  final int maxCueMs;

  /// 句末标点：命中即切。
  static const Set<String> sentenceTerminators = <String>{
    '。',
    '！',
    '？',
    '!',
    '?',
    '…',
    '‥',
    '．',
    '.',
  };

  /// 紧随句末标点时并入前句的闭合符号。
  static const Set<String> closingMarks = <String>{
    '」',
    '』',
    '）',
    ')',
    '】',
    '〕',
    '》',
    '〉',
    '"',
    '”',
    '’',
  };

  /// 句点后**不**切句的英文缩写（小写比较）：`Mr. Dursley` 切成两条 cue 只会
  /// 产出一条 200 ms 的「Mr.」碎片并把人名甩到下一句。单个大写字母缩写
  /// （`J. K. Rowling`）由 [_isAbbreviationDot] 按形态识别，不列在这里。
  static const Set<String> dotAbbreviations = <String>{
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'st',
    'mt',
    'no',
    'vs',
    'etc',
  };

  /// 只由这些字符组成的 cue 不产出（纯标点/空白）。
  static final RegExp _punctOnly = RegExp(
    r'^[\s、。！？!?…‥．.,，「」『』（）()【】〔〕《》〈〉"”’・ー〜~\-]*$',
  );

  /// token 是否以句末标点收尾。字符级词表下 token 就是那个标点；BPE 词表下
  /// 标点也可能粘在词尾（`world.`），故按尾字符判。
  static bool endsWithTerminator(String token) {
    final String t = token.trimRight();
    if (t.isEmpty) return false;
    return sentenceTerminators.contains(t.substring(t.length - 1));
  }

  /// token（去掉 BPE 前导空格后）是否是闭合符号。
  static bool isClosingMark(String token) => closingMarks.contains(token.trim());

  /// 本句到目前为止以 `.` 收尾时，这个点是不是缩写点（不该切句）：
  /// 最后一个词是 [dotAbbreviations] 之一，或单个大写字母（人名首字母）。
  static bool _isAbbreviationDot(String sentenceSoFar) {
    final String s = sentenceSoFar.trimRight();
    if (!s.endsWith('.')) return false;
    final String body = s.substring(0, s.length - 1);
    final int cut = body.lastIndexOf(RegExp(r'\s'));
    final String word = (cut < 0 ? body : body.substring(cut + 1)).trim();
    if (word.isEmpty) return false;
    if (word.length == 1 && word.toUpperCase() == word && word != word.toLowerCase()) {
      return true;
    }
    return dotAbbreviations.contains(word.toLowerCase());
  }

  /// 把（同一本书全部文件的）转录段落变成单时间轴 cue。
  ///
  /// [fileOffsetsMs] 下标 = audioFileIndex，值 = 该文件在单时间轴上的起点（前面
  /// 各文件时长之和）；缺省或长度不够时该文件偏移按 0 处理（单文件场景）。
  List<AsrCue> build(
    List<AsrTranscribedSegment> segments, {
    List<int> fileOffsetsMs = const <int>[],
  }) {
    final List<AsrTranscribedSegment> ordered =
        List<AsrTranscribedSegment>.of(segments)
          ..sort((AsrTranscribedSegment a, AsrTranscribedSegment b) {
            final int byFile = a.audioFileIndex.compareTo(b.audioFileIndex);
            return byFile != 0 ? byFile : a.startMs.compareTo(b.startMs);
          });
    final List<AsrCue> out = <AsrCue>[];
    for (final AsrTranscribedSegment seg in ordered) {
      final int offset = seg.audioFileIndex < fileOffsetsMs.length
          ? fileOffsetsMs[seg.audioFileIndex]
          : 0;
      out.addAll(_buildForSegment(seg, offset));
    }
    // 跨段兜底：单时间轴上 cue 严格单调、不重叠。
    for (int i = 1; i < out.length; i++) {
      final AsrCue prev = out[i - 1];
      final AsrCue cur = out[i];
      if (cur.startMs < prev.endMs) {
        out[i - 1] = AsrCue(
          startMs: prev.startMs,
          endMs: cur.startMs > prev.startMs ? cur.startMs : prev.endMs,
          text: prev.text,
          audioFileIndex: prev.audioFileIndex,
        );
      }
    }
    return out;
  }

  List<AsrCue> _buildForSegment(AsrTranscribedSegment seg, int offsetMs) {
    if (seg.tokens.isEmpty) return const <AsrCue>[];
    final List<List<int>> sentences = _splitSentences(seg);
    final List<AsrCue> cues = <AsrCue>[];
    for (int s = 0; s < sentences.length; s++) {
      final List<int> idx = sentences[s];
      final String text = _joinTokens(seg.tokens, idx);
      if (text.isEmpty || _punctOnly.hasMatch(text)) continue;
      final int firstTokenMs = seg.tokenTimesMs[idx.first];
      final int lastTokenMs = seg.tokenTimesMs[idx.last];
      final bool isFirst = s == 0;
      final bool isLast = s == sentences.length - 1;

      int start = isFirst ? seg.startMs : firstTokenMs - leadInMs;
      if (cues.isNotEmpty && start < cues.last.endMs) start = cues.last.endMs;
      if (start < seg.startMs) start = seg.startMs;

      int end;
      if (isLast) {
        end = seg.endMs;
      } else {
        final int nextFirstMs = seg.tokenTimesMs[sentences[s + 1].first];
        end = nextFirstMs - leadInMs;
      }
      final int floor = lastTokenMs + kAsrEncoderFrameMs;
      if (end < floor) end = floor;
      if (end - start < minCueMs) end = start + minCueMs;
      if (end > seg.endMs) end = seg.endMs;
      if (end <= start) end = start + kAsrEncoderFrameMs;

      cues.add(
        AsrCue(
          startMs: start + offsetMs,
          endMs: end + offsetMs,
          text: text,
          audioFileIndex: seg.audioFileIndex,
        ),
      );
    }
    return cues;
  }

  /// 返回每句包含的 token 下标列表（按序、互不重叠、覆盖全部 token）。
  List<List<int>> _splitSentences(AsrTranscribedSegment seg) {
    final List<List<int>> sentences = <List<int>>[];
    List<int> current = <int>[];
    final int n = seg.tokens.length;
    for (int i = 0; i < n; i++) {
      final String tok = seg.tokens[i];
      // 间隙切：与上一 token 距离过大，先封上一句。
      if (current.isNotEmpty &&
          seg.tokenTimesMs[i] - seg.tokenTimesMs[current.last] > gapSplitMs) {
        sentences.add(current);
        current = <int>[];
      }
      current.add(i);
      if (endsWithTerminator(tok) &&
          !_isAbbreviationDot(_joinTokens(seg.tokens, current))) {
        // 吞掉紧随的闭合符号。
        while (i + 1 < n && isClosingMark(seg.tokens[i + 1])) {
          i++;
          current.add(i);
        }
        sentences.add(current);
        current = <int>[];
      }
    }
    if (current.isNotEmpty) sentences.add(current);
    return _splitOverlong(seg, sentences);
  }

  /// 超长无标点句：在 token 间最大间隙处递归对半切，直到时长 ≤ [maxCueMs] 或
  /// 已无处可切（少于 4 个 token 不再切，避免碎成单字）。
  List<List<int>> _splitOverlong(
    AsrTranscribedSegment seg,
    List<List<int>> sentences,
  ) {
    final List<List<int>> out = <List<int>>[];
    for (final List<int> s in sentences) {
      _splitOverlongInto(seg, s, out);
    }
    return out;
  }

  void _splitOverlongInto(
    AsrTranscribedSegment seg,
    List<int> s,
    List<List<int>> out,
  ) {
    final int span = seg.tokenTimesMs[s.last] - seg.tokenTimesMs[s.first];
    if (span <= maxCueMs || s.length < 4) {
      out.add(s);
      return;
    }
    // 只在中段 [25%, 75%) 找最大间隙，避免切出一头一尾的碎片。
    final int lo = s.length ~/ 4;
    final int hi = (s.length * 3) ~/ 4;
    int bestAt = -1;
    int bestGap = -1;
    for (int k = lo; k < hi && k + 1 < s.length; k++) {
      final int gap = seg.tokenTimesMs[s[k + 1]] - seg.tokenTimesMs[s[k]];
      if (gap > bestGap) {
        bestGap = gap;
        bestAt = k;
      }
    }
    if (bestAt < 0) {
      out.add(s);
      return;
    }
    _splitOverlongInto(seg, s.sublist(0, bestAt + 1), out);
    _splitOverlongInto(seg, s.sublist(bestAt + 1), out);
  }

  String _joinTokens(List<String> tokens, List<int> idx) {
    final StringBuffer sb = StringBuffer();
    for (final int i in idx) {
      sb.write(tokens[i]);
    }
    return sb.toString().trim();
  }
}

/// 把 cue 序列化成 SRT 文本（UTF-8 内容由调用方写文件）。
///
/// 时间戳 `HH:MM:SS,mmm`；`index` 从 1 起；每条 cue 之间空行；末尾一个换行。
/// 与 `SrtParser` 的解析契约一致（它容忍 `\n` 与 `\r\n`，此处用 `\n`）。
String serializeAsrCuesToSrt(List<AsrCue> cues) {
  final StringBuffer sb = StringBuffer();
  int index = 1;
  for (final AsrCue cue in cues) {
    if (cue.text.isEmpty) continue;
    sb
      ..write(index)
      ..write('\n')
      ..write(_srtTimestamp(cue.startMs))
      ..write(' --> ')
      ..write(_srtTimestamp(cue.endMs))
      ..write('\n')
      ..write(cue.text.replaceAll('\n', ' '))
      ..write('\n\n');
    index++;
  }
  return sb.toString();
}

String _srtTimestamp(int ms) {
  final int clamped = ms < 0 ? 0 : ms;
  final int h = clamped ~/ 3600000;
  final int m = (clamped % 3600000) ~/ 60000;
  final int s = (clamped % 60000) ~/ 1000;
  final int milli = clamped % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)},${milli.toString().padLeft(3, '0')}';
}

/// 由各文件时长（毫秒，下标 = audioFileIndex）算单时间轴上每个文件的起点偏移。
List<int> asrFileOffsetsFromDurations(List<int> fileDurationsMs) {
  final List<int> offsets = List<int>.filled(fileDurationsMs.length, 0);
  for (int i = 1; i < fileDurationsMs.length; i++) {
    offsets[i] = offsets[i - 1] + fileDurationsMs[i - 1];
  }
  return offsets;
}
