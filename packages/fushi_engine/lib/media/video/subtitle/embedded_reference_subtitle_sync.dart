/// 把一份外挂字幕（通常是 Jimaku 下来的日字）按视频自带的文本字幕轨对时间轴。
///
/// 数据流：外挂字幕字节 → 可对齐的开始时刻；视频 → 每条内嵌文本轨的开始时刻 →
/// [decideSubtitleSync]（各轨独立对齐 + 同模板去重 + 投票）→ [retimeSubtitleBytes]。
///
/// **宁可不改，不能改坏**：没有可用参考、证据不足、互相矛盾，一律原样返回，
/// 调用方拿到的字节与现在的行为完全一样。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/subtitle/subtitle_reference_alignment.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_time_rewriter.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';

/// 评论音轨配套的字幕与正片台词时间无关，不当参考。
final RegExp _commentaryTitle = RegExp(
  r'commentary|コメンタリー|解说|解說|評論|评论',
  caseSensitive: false,
);

/// 同步的结局。
enum EmbeddedReferenceSyncStatus {
  /// 视频没有可当参考的文本字幕轨（生肉、只有 PGS、探测失败）。
  noReference,

  /// 外挂字幕里可对齐的 cue 太少（或根本解析不出时间）。
  subtitleUnreadable,

  /// 已判定（看 [EmbeddedReferenceSyncResult.decision]）。
  decided,
}

class EmbeddedReferenceSyncResult {
  const EmbeddedReferenceSyncResult({
    required this.status,
    required this.originalBytes,
    this.decision,
    this.retime,
  });

  final EmbeddedReferenceSyncStatus status;
  final Uint8List originalBytes;
  final SubtitleSyncDecision? decision;

  /// 采用 [decision] 后的字幕；refused 时为 null。
  final SubtitleRetimeOutcome? retime;

  SubtitleSyncDecisionKind get kind =>
      decision?.kind ?? SubtitleSyncDecisionKind.refused;

  /// 结果真的会改动字幕（有非零偏移）。
  bool get changesTiming =>
      (retime?.shiftedCount ?? 0) > 0 || (retime?.droppedCount ?? 0) > 0;

  /// 自动路径该写的字节：只有 autoApply 才用对齐结果，其余原样。
  Uint8List get bytesForAutomaticPath =>
      kind == SubtitleSyncDecisionKind.autoApply && retime != null
      ? retime!.bytes
      : originalBytes;

  /// 一行给日志的摘要。
  String describe() {
    final SubtitleSyncDecision? d = decision;
    if (d == null) return 'reference-sync: ${status.name}';
    final String groups = d.groups
        .map(
          (SubtitleReferenceGroup g) =>
              '[${g.tracks.map((SubtitleReferenceTrack t) => t.label).join(' = ')}] '
              '${g.judgement.strength.name}/${g.judgement.issue.name} '
              '${g.judgement.fit.excess.toStringAsFixed(2)}x '
              '${_describeSegments(g.judgement.fit.segments)}',
        )
        .join('; ');
    return 'reference-sync: ${d.kind.name} agreeing=${d.agreeingGroups} '
        'conflicting=${d.conflicting} shifted=${retime?.shiftedCount ?? 0} '
        'dropped=${retime?.droppedCount ?? 0} :: $groups';
  }
}

String _describeSegments(List<AlignmentSegment> segments) => segments
    .map(
      (AlignmentSegment s) =>
          '${s.offsetSeconds >= 0 ? '+' : ''}${s.offsetSeconds.toStringAsFixed(2)}s'
          '${s.splitSeconds == null ? '' : '@${s.splitSeconds!.toStringAsFixed(0)}'}',
    )
    .join(' / ');

/// **纯函数**：已拿到参考轨时的整套判定 + 改写。
EmbeddedReferenceSyncResult syncSubtitleBytesToReferences({
  required Uint8List subtitleBytes,
  required List<SubtitleReferenceTrack> references,
  double? durationSeconds,
}) {
  final List<double> starts = alignableCueStartSeconds(subtitleBytes);
  if (uniqueCueStarts(starts).length < kAlignMinAlignableCues) {
    return EmbeddedReferenceSyncResult(
      status: EmbeddedReferenceSyncStatus.subtitleUnreadable,
      originalBytes: subtitleBytes,
    );
  }
  if (references.every(
    (SubtitleReferenceTrack r) => r.starts.length < kMinReferenceCues,
  )) {
    return EmbeddedReferenceSyncResult(
      status: EmbeddedReferenceSyncStatus.noReference,
      originalBytes: subtitleBytes,
    );
  }
  final SubtitleSyncDecision decision = decideSubtitleSync(
    subtitleStarts: starts,
    references: references,
    durationSeconds: durationSeconds,
  );
  return EmbeddedReferenceSyncResult(
    status: EmbeddedReferenceSyncStatus.decided,
    originalBytes: subtitleBytes,
    decision: decision,
    retime: decision.chosen == null
        ? null
        : retimeSubtitleBytes(subtitleBytes, decision.segments),
  );
}

/// 一条内嵌轨能不能当参考（不看 cue 数，那要抽出来才知道）。
bool isCandidateReferenceTrack(EmbeddedSubtitleTrack track) {
  if (subtitleFormatForCodec(track.codec) == null) return false;
  final String? title = track.title;
  return title == null || !_commentaryTitle.hasMatch(title);
}

String referenceTrackLabel(EmbeddedSubtitleTrack track) {
  final String lang = track.language == null ? '' : ' ${track.language}';
  final String title = track.title == null ? '' : ' "${track.title}"';
  return '#${track.streamIndex}$lang$title';
}

/// 读出视频每条可当参考的内嵌文本轨的开始时刻。抽取走现有的整片一次 demux + 缓存。
Future<List<SubtitleReferenceTrack>> loadEmbeddedReferenceTracks(
  String videoPath,
) async {
  final List<SubtitleReferenceTrack> out = <SubtitleReferenceTrack>[];
  final EmbeddedSubtitleTrackProbeResult probe =
      await probeEmbeddedSubtitleTracks(videoPath);
  for (final EmbeddedSubtitleTrack track in probe.tracks) {
    if (!isCandidateReferenceTrack(track)) continue;
    final File? file = await extractEmbeddedSubtitleTrackFile(
      videoPath: videoPath,
      streamIndex: track.streamIndex,
      codec: track.codec,
    );
    if (file == null) continue;
    out.add(
      SubtitleReferenceTrack(
        label: referenceTrackLabel(track),
        starts: uniqueCueStarts(
          alignableCueStartSeconds(await file.readAsBytes()),
        ),
      ),
    );
  }
  return out;
}

/// 读出参考轨的函数（测试注入用）。
typedef SubtitleReferenceTrackLoader =
    Future<List<SubtitleReferenceTrack>> Function(String videoPath);

/// 按 [videoPath] 自带的文本字幕轨给 [subtitleBytes] 对时间轴。**不写盘**，
/// 调用方决定写什么（自动路径用 [EmbeddedReferenceSyncResult.bytesForAutomaticPath]）。
///
/// 任何异常都降级为「原样」：这一步只能让字幕更好，不能让下载失败。
Future<EmbeddedReferenceSyncResult> syncSubtitleToEmbeddedReferences({
  required Uint8List subtitleBytes,
  required String videoPath,
  int? videoDurationMs,
  SubtitleReferenceTrackLoader loadReferences = loadEmbeddedReferenceTracks,
}) async {
  try {
    final EmbeddedReferenceSyncResult result = syncSubtitleBytesToReferences(
      subtitleBytes: subtitleBytes,
      references: await loadReferences(videoPath),
      durationSeconds: videoDurationMs == null
          ? null
          : videoDurationMs / 1000.0,
    );
    fushiDebugPrint('[ReferenceSync] "$videoPath" ${result.describe()}');
    return result;
  } catch (e, stack) {
    fushiDebugPrint('[ReferenceSync] failed for "$videoPath": $e\n$stack');
    return EmbeddedReferenceSyncResult(
      status: EmbeddedReferenceSyncStatus.noReference,
      originalBytes: subtitleBytes,
    );
  }
}
