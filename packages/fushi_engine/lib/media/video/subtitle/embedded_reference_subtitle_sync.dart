/// 把一份外挂字幕（通常是 Jimaku 下来的日字）按视频自带的文本字幕轨对时间轴。
///
/// 数据流：外挂字幕字节 → 可对齐的开始时刻；视频 → 每条内嵌文本轨的开始时刻 →
/// [decideSubtitleSync]（各轨独立对齐 + 同模板去重 + 投票）→ [retimeSubtitleBytes]。
///
/// **宁可不改，不能改坏**：没有可用参考、证据不足、互相矛盾，一律原样返回，
/// 调用方拿到的字节与现在的行为完全一样。
///
/// 算法（对齐判定与保字节改写）住在上游 `fushi_asr_subtitles`
/// （hajisensai/fushi-subtitles）；本文件只是装配：ffmpeg 抽参考轨、isolate 调度、
/// 原稿备份。改算法去上游改。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/subtitle/subtitle_alignment_backup.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
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

/// 给界面看的偏移：`+1.23s`；有 CM 断点时按段列出 `0.00s / -9.72s`。
String formatAlignmentOffsets(List<AlignmentSegment> segments) => segments
    .map(
      (AlignmentSegment s) =>
          '${s.offsetSeconds > 0 ? '+' : ''}${s.offsetSeconds.toStringAsFixed(2)}s',
    )
    .join(' / ');

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
    final Uint8List trackBytes = await file.readAsBytes();
    out.add(
      SubtitleReferenceTrack(
        label: referenceTrackLabel(track),
        // 整轨扫描是纯 CPU（大 ASS 几万行），放后台 isolate，别卡调用方的 UI 帧。
        starts: await Isolate.run(
          () => uniqueCueStarts(alignableCueStartSeconds(trackBytes)),
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
    final List<SubtitleReferenceTrack> references = await loadReferences(
      videoPath,
    );
    final double? durationSeconds = videoDurationMs == null
        ? null
        : videoDurationMs / 1000.0;
    // 判定（逐轨相关 + 断点搜索）与改写都是纯 CPU：手动入口从播放页调，放后台
    // isolate，别让播放页掉帧。
    final EmbeddedReferenceSyncResult computed = await Isolate.run(
      () => syncSubtitleBytesToReferences(
        subtitleBytes: subtitleBytes,
        references: references,
        durationSeconds: durationSeconds,
      ),
    );
    // 跨 isolate 回来的原稿是副本：换回调用方手上那一份，「原样」才仍是同一个
    // 对象（[alignSubtitleForAutomaticPath] 靠 identical 判断没改）。
    final EmbeddedReferenceSyncResult result = EmbeddedReferenceSyncResult(
      status: computed.status,
      originalBytes: subtitleBytes,
      decision: computed.decision,
      retime: computed.retime,
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

/// 给 [aligner] 套上开关：**每次调用现读** [enabled]，关着就原样返回、不碰视频。
/// 持有钩子的下载服务生命周期跟 app 一样长，开关却随时能改，不能在装配时读一次。
AutomaticSubtitleAligner gatedAutomaticSubtitleAligner(
  bool Function() enabled, {
  AutomaticSubtitleAligner aligner = alignSubtitleForAutomaticPath,
}) {
  return (Uint8List subtitleBytes, String videoPath) async =>
      enabled() ? aligner(subtitleBytes, videoPath) : subtitleBytes;
}

Future<int?> _probeDurationMs(String videoPath) =>
    probeVideoDurationMs(videoPath);

/// 自动下载路径统一用的钩子：刚下到手的字幕字节 + 它要配的本地视频 → 该写盘的字节。
///
/// 调用方持有的钩子为 null（没装配对齐）就原样写盘；用户关了「按内嵌字幕自动对齐」
/// 由 [gatedAutomaticSubtitleAligner] 在钩子内部现读开关、原样返回。
typedef AutomaticSubtitleAligner =
    Future<Uint8List> Function(Uint8List subtitleBytes, String videoPath);

/// [AutomaticSubtitleAligner] 的标准实现：只有证据足够（autoApply）才改，其余原样。
/// 远端流 / 文件不存在直接原样返回，不探测。改了就把原稿备份（见
/// subtitle_alignment_backup.dart），备份失败则放弃对齐、写原稿——不能留下
/// 一份找不回原样的字幕。
Future<Uint8List> alignSubtitleForAutomaticPath(
  Uint8List subtitleBytes,
  String videoPath, {
  SubtitleReferenceTrackLoader loadReferences = loadEmbeddedReferenceTracks,
  Future<int?> Function(String videoPath) probeDurationMs = _probeDurationMs,
}) async {
  if (!File(videoPath).existsSync()) return subtitleBytes;
  final EmbeddedReferenceSyncResult result =
      await syncSubtitleToEmbeddedReferences(
        subtitleBytes: subtitleBytes,
        videoPath: videoPath,
        videoDurationMs: await probeDurationMs(videoPath),
        loadReferences: loadReferences,
      );
  final Uint8List out = result.bytesForAutomaticPath;
  // 零偏移的「对齐结果」内容与原稿相同（判定在后台 isolate 里做，回来的是副本，
  // 不再 identical）：不能当对齐产物登记，否则播放页会按对齐产物把调轴归零。
  if (identical(out, subtitleBytes) || !result.changesTiming) {
    return subtitleBytes;
  }
  try {
    await saveSubtitleAlignmentOriginal(original: subtitleBytes, aligned: out);
  } catch (e) {
    fushiDebugPrint('[ReferenceSync] backup failed, keeping original: $e');
    return subtitleBytes;
  }
  return out;
}

/// 形如 `smb://` / `nfs://` 的 URI 前缀（scheme 至少两字符，排除 `C:` 盘符）。
final RegExp _networkUriScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]+://');

/// [path] 是否明显落在网络上：UNC（`\\host\share`、`//host/share`、`\\?\UNC\`）或
/// 带 scheme 的 URI（`smb://` / `nfs://` / `afp://` / `http://` …）。
///
/// 后台自动路径（刮削后补字幕、合集批量）遇到它就不抽内嵌轨：抽轨是整片 demux，
/// 走网络等于把整部视频拉一遍。映射成盘符的网络盘（`Z:`）与 POSIX 挂载点从路径上
/// 认不出，按本地处理。纯函数。
bool isNetworkMediaPath(String path) {
  final String trimmed = path.trim();
  if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) return true;
  return _networkUriScheme.hasMatch(trimmed);
}
