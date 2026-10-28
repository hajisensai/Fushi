/// 给 AI 字幕找样式参考：同一视频旁的外挂 `.ass` / `.ssa`，以及视频自带的 ASS 轨。
///
/// 挑可读对白最多的那一份（字幕组的「全字幕」轨通常比「仅招牌」轨多得多）。管线
/// 自己写出的字幕由 [isOwnOutput] 排除，不能拿上一次的产物当参考。
///
/// 任何读不到 / 解析不了的候选都静默跳过：找不到参考只是不出 ASS，SRT 照常导出。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_audio/fushi_audio_core.dart' show readTextWithEncoding;
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart'
    show isCandidateReferenceTrack, isNetworkMediaPath, referenceTrackLabel;
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles;
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

/// 管线的样式参考注入点：给视频路径与「这是不是管线自己写的文件」，返回参考或 null。
typedef SubtitleStyleReferenceLoader =
    Future<AssStyleReference?> Function(
      String videoPath, {
      required bool Function(String path) isOwnOutput,
    });

/// 生产实现：外挂 ASS 与内嵌 ASS 轨里挑可读对白最多的一份。
Future<AssStyleReference?> loadSubtitleStyleReference(
  String videoPath, {
  required bool Function(String path) isOwnOutput,
}) async {
  final List<AssStyleReference> found = <AssStyleReference>[];
  for (final String path in await _sidecarAssFiles(videoPath)) {
    if (isOwnOutput(path)) continue;
    final AssStyleReference? ref = await _parseFile(
      File(path),
      p.basename(path),
    );
    if (ref != null) found.add(ref);
  }
  // 内嵌轨要整片 demux 一遍：只对本机文件做，网络盘上不拉整部视频。先判网络路径
  // 再做（异步的）存在性检查：断线的 UNC / 映射盘上同步 stat 会卡住 isolate 几十秒
  // （BUG-3756 同类）。
  if (!isNetworkMediaPath(videoPath) && await hasLocalMediaFile(videoPath)) {
    try {
      final EmbeddedSubtitleTrackProbeResult probe =
          await probeEmbeddedSubtitleTracks(videoPath);
      for (final EmbeddedSubtitleTrack track in probe.tracks) {
        final String codec = track.codec.toLowerCase();
        if (codec != 'ass' && codec != 'ssa') continue;
        if (!isCandidateReferenceTrack(track)) continue;
        final File? file = await extractEmbeddedSubtitleTrackFile(
          videoPath: videoPath,
          streamIndex: track.streamIndex,
          codec: track.codec,
        );
        if (file == null) continue;
        final AssStyleReference? ref = await _parseFile(
          file,
          referenceTrackLabel(track),
        );
        if (ref != null) found.add(ref);
      }
    } catch (e) {
      fushiDebugPrint('[AssStyleReference] embedded probe failed: $e');
    }
  }
  if (found.isEmpty) return null;
  found.sort(
    (AssStyleReference a, AssStyleReference b) =>
        b.events.length.compareTo(a.events.length),
  );
  return found.first;
}

Future<List<String>> _sidecarAssFiles(String videoPath) async {
  final String dir = p.dirname(videoPath);
  final List<String> names = <String>[];
  try {
    await for (final FileSystemEntity e in Directory(
      dir,
    ).list(followLinks: false)) {
      if (e is File) names.add(p.basename(e.path));
    }
  } on FileSystemException {
    return const <String>[];
  }
  return <String>[
    for (final String name in listSidecarSubtitles(
      p.basenameWithoutExtension(videoPath),
      names,
    ))
      if (RegExp(r'\.(ass|ssa)$', caseSensitive: false).hasMatch(name))
        p.join(dir, name),
  ];
}

Future<AssStyleReference?> _parseFile(File file, String label) async {
  try {
    final String content = await readTextWithEncoding(file);
    // 大 ASS（特效字幕几万行）的逐行解析放后台 isolate。
    return await Isolate.run(
      () => parseAssStyleReference(content, label: label),
    );
  } catch (e) {
    fushiDebugPrint('[AssStyleReference] skip "$label": $e');
    return null;
  }
}
