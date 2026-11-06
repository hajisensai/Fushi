/// 有声书对齐后的「正文覆盖情况」：命中 cue 数与正文字符覆盖率。
///
/// 口径（与匹配器同一坐标系，见 `CueMatch` 的归一化偏移）：
///
/// - 坐标：各章正文经 [AudioTextNormalizer.normalize] 归一化（白名单：假名 / 汉字 /
///   字母数字，标点空白全剥）后首尾相接成全书串；`CueMatch.normCharStart/End` 是
///   **章内**偏移，加上该章在全书串里的起点换成全书偏移。
/// - 分子：所有命中 cue 的归一化区间 `[start, end)` 的**并集**长度（重叠只算一次，
///   重切 / 回填产生的相邻 cue 首尾相叠不会把覆盖率算过 100%）。
/// - 分母「正文有效区间」：全书串上**第一处命中的起点到最后一处命中的终点**。
///   封面、目录、版权页、后记这些朗读不到的前后附属内容落在区间外、不计入；
///   夹在中间却整章没命中的（真漏了的正文）照样计入分母，覆盖率会如实变低。
///   一处命中都没有时分母为 0，字符覆盖率不可用（null）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// 覆盖率分档：≥98% 优、96%~98% 尚可、<96% 偏低（阈值取自 YuiMoe 的同名分档）。
enum AudiobookCoverageTier { excellent, acceptable, poor }

/// [AudiobookCoverageTier.excellent] 的下限。
const double kAudiobookCoverageExcellentRate = 0.98;

/// [AudiobookCoverageTier.acceptable] 的下限。
const double kAudiobookCoverageAcceptableRate = 0.96;

/// [rate]（0..1）落在哪一档。
AudiobookCoverageTier audiobookCoverageTierOf(double rate) {
  if (rate >= kAudiobookCoverageExcellentRate) {
    return AudiobookCoverageTier.excellent;
  }
  if (rate >= kAudiobookCoverageAcceptableRate) {
    return AudiobookCoverageTier.acceptable;
  }
  return AudiobookCoverageTier.poor;
}

/// 一次对齐的覆盖情况（纯数据，可 JSON 往返）。
@immutable
class AudiobookTextCoverage {
  const AudiobookTextCoverage({
    required this.matchedCues,
    required this.totalCues,
    required this.coveredChars,
    required this.spanChars,
  });

  factory AudiobookTextCoverage.fromJson(Map<String, Object?> json) =>
      AudiobookTextCoverage(
        matchedCues: (json['matchedCues']! as num).toInt(),
        totalCues: (json['totalCues']! as num).toInt(),
        coveredChars: (json['coveredChars']! as num).toInt(),
        spanChars: (json['spanChars']! as num).toInt(),
      );

  /// 命中正文的 cue 数 / cue 总数。
  final int matchedCues;
  final int totalCues;

  /// 命中区间并集的归一化字符数。
  final int coveredChars;

  /// 正文有效区间（首处命中起点 → 末处命中终点）的归一化字符数。
  final int spanChars;

  /// cue 命中率 0..1（没有 cue 时 0）。
  double get cueRate => totalCues == 0 ? 0 : matchedCues / totalCues;

  /// 正文字符覆盖率 0..1；没有任何命中时 null。
  double? get charRate => spanChars <= 0 ? null : coveredChars / spanChars;

  /// 着色用的那个率：有字符覆盖率用它，否则退回 cue 命中率。
  double get headlineRate => charRate ?? cueRate;

  AudiobookCoverageTier get tier => audiobookCoverageTierOf(headlineRate);

  Map<String, Object?> toJson() => <String, Object?>{
    'matchedCues': matchedCues,
    'totalCues': totalCues,
    'coveredChars': coveredChars,
    'spanChars': spanChars,
  };

  @override
  bool operator ==(Object other) =>
      other is AudiobookTextCoverage &&
      other.matchedCues == matchedCues &&
      other.totalCues == totalCues &&
      other.coveredChars == coveredChars &&
      other.spanChars == spanChars;

  @override
  int get hashCode =>
      Object.hash(matchedCues, totalCues, coveredChars, spanChars);

  @override
  String toString() =>
      'AudiobookTextCoverage($matchedCues/$totalCues cues, '
      '$coveredChars/$spanChars chars)';
}

/// 纯函数本体：[sectionNormLengths] 是各章归一化后的长度（下标 = `sectionIndex`）。
/// 越界 / 空区间的命中忽略（只可能来自与章节列表不配套的结果）。
AudiobookTextCoverage computeTextCoverageFromLengths({
  required List<int> sectionNormLengths,
  required MatchResult result,
}) {
  final List<int> sectionStarts = List<int>.filled(
    sectionNormLengths.length,
    0,
  );
  int acc = 0;
  for (int i = 0; i < sectionNormLengths.length; i++) {
    sectionStarts[i] = acc;
    acc += sectionNormLengths[i];
  }
  final List<(int, int)> spans = <(int, int)>[];
  for (final CueMatch m in result.matches) {
    if (!m.matched || m.sectionIndex >= sectionNormLengths.length) continue;
    final int len = sectionNormLengths[m.sectionIndex];
    final int start = m.normCharStart.clamp(0, len);
    final int end = m.normCharEnd.clamp(0, len);
    if (end <= start) continue;
    final int base = sectionStarts[m.sectionIndex];
    spans.add((base + start, base + end));
  }
  int covered = 0;
  int span = 0;
  if (spans.isNotEmpty) {
    spans.sort(((int, int) a, (int, int) b) => a.$1.compareTo(b.$1));
    int curStart = spans.first.$1;
    int curEnd = spans.first.$2;
    int maxEnd = curEnd;
    for (final (int, int) s in spans.skip(1)) {
      if (s.$1 <= curEnd) {
        if (s.$2 > curEnd) curEnd = s.$2;
      } else {
        covered += curEnd - curStart;
        curStart = s.$1;
        curEnd = s.$2;
      }
      if (s.$2 > maxEnd) maxEnd = s.$2;
    }
    covered += curEnd - curStart;
    span = maxEnd - spans.first.$1;
  }
  return AudiobookTextCoverage(
    matchedCues: result.matchedCues,
    totalCues: result.totalCues,
    coveredChars: covered,
    spanChars: span,
  );
}

/// 按章节正文算覆盖情况（整批一次归一化 FFI，几十万字是毫秒级）。
AudiobookTextCoverage computeAudiobookTextCoverage({
  required List<EpubSection> sections,
  required MatchResult result,
}) {
  final List<String> normalized = AudioTextNormalizer.normalizeBatch(<String>[
    for (final EpubSection s in sections) s.text,
  ]);
  return computeTextCoverageFromLengths(
    sectionNormLengths: <int>[for (final String s in normalized) s.length],
    result: result,
  );
}

/// 转录产物旁的覆盖情况 sidecar：「使用字幕」跑完正文匹配后写下，转录弹层再打开
/// 时据此显示上次匹配的覆盖率。
const String kAsrCoverageFileName = 'transcript.coverage.json';

/// [srtPath] 旁边 sidecar 的路径（不检查存在）。
String asrCoveragePathFor(String srtPath) =>
    p.join(p.dirname(srtPath), kAsrCoverageFileName);

Future<void> writeAsrCoverageSidecar(
  String srtPath,
  AudiobookTextCoverage coverage,
) => File(
  asrCoveragePathFor(srtPath),
).writeAsString(jsonEncode(coverage.toJson()), flush: true);

/// 读 sidecar；不存在 / 读不动 / 格式不对一律 null（它只是展示用的旁证）。
/// 同步读：几十字节的小文件，弹层规划时顺手读，不值得多一个异步等待点。
AudiobookTextCoverage? readAsrCoverageSidecarSync(String srtPath) {
  try {
    final File file = File(asrCoveragePathFor(srtPath));
    if (!file.existsSync()) return null;
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    return AudiobookTextCoverage.fromJson(Map<String, Object?>.from(decoded));
  } catch (_) {
    return null;
  }
}
