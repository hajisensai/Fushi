import 'dart:io';

import 'package:fushi/src/media/video/video_subtitle_attach.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

/// 「从服务端重新拉取字幕」的一个可选项：服务端默认（外挂）字幕，或服务端视频容器
/// 里的一条**文本**字幕轨（服务端抽出成文件再下发）。
///
/// 群里反馈「互联字幕不一致，可以多个选项重新拉字幕」：下载时只拉了服务端默认那一份，
/// 服务端上换了字幕、或者默认那份本来就选错了轨，本机都没有办法换。这里把服务端
/// 当前能给的文本字幕全部列出来，让用户挑一份重拉。
class RemoteSubtitleRefetchOption {
  const RemoteSubtitleRefetchOption.serverDefault({this.fileName})
    : track = null;

  RemoteSubtitleRefetchOption.track(RemoteVideoEmbeddedSubtitleTrack this.track)
    : fileName = track.fileName;

  /// null = 服务端默认字幕（`getRemoteVideoSubtitle` 不带 `embeddedStreamIndex`）。
  final RemoteVideoEmbeddedSubtitleTrack? track;

  /// 服务端报的文件名（决定扩展名 → 解析器）；没有时按 srt 处理，与首次下载同口径。
  final String? fileName;

  /// 下载落地名：`<视频 id>.<扩展名>`（默认字幕，与首次下载同名 → 原位覆盖）或
  /// `<视频 id>.s<流号>.<扩展名>`（内封轨，各轨互不覆盖）。
  String localFileName(String videoId) {
    final String safeId = safeWindowsFileName(videoId);
    final String ext = _extensionOf(fileName);
    final RemoteVideoEmbeddedSubtitleTrack? t = track;
    return t == null ? '$safeId.$ext' : '$safeId.s${t.streamIndex}.$ext';
  }

  static String _extensionOf(String? name) {
    if (name == null || name.isEmpty) return 'srt';
    final String ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty ? 'srt' : ext;
  }
}

/// 服务端对 [video] 当前能给出的全部文本字幕选项（纯函数）：有默认外挂字幕时排第一，
/// 其后是容器里的文本轨（图形轨 PGS / VobSub 解不出 cue，不列）。空列表 = 服务端
/// 没有任何可拉的文本字幕。
List<RemoteSubtitleRefetchOption> remoteSubtitleRefetchOptions(
  RemoteVideoInfo video,
) => <RemoteSubtitleRefetchOption>[
  if (video.hasSubtitle)
    RemoteSubtitleRefetchOption.serverDefault(fileName: video.subtitleFileName),
  for (final RemoteVideoEmbeddedSubtitleTrack track
      in video.embeddedSubtitleTracks)
    if (track.isText) RemoteSubtitleRefetchOption.track(track),
];

/// 从服务端重新拉取 [option] 指向的字幕，原子替换本机视频书 [book] 的字幕源与 cue。
///
/// 先下到 [tempDir] 并**先解析一遍**：解析失败 / 0 条 cue 时直接返回失败、本机现有
/// 字幕文件和 cue 一个字节都不动（不能拿一份坏字幕把能用的那份覆盖掉）。解析通过
/// 才交给 [attachSubtitleToVideoBook]——拷进 `video_subtitles/`（同名即原位覆盖）
/// 并经 `saveSubtitleSelection` 把字幕源指针与 cue 一个事务换新。观看进度、调轴、
/// 统计等都在别的列 / 表里，不受影响。
///
/// 网络失败（对端离线、404）照常抛给调用方提示；解析 / 落库失败进返回值。
/// [destDirOverride] 仅供测试注入持久目录。
Future<SubtitleAttachResult> refetchRemoteVideoSubtitle({
  required RemoteVideoClient client,
  required RemoteVideoInfo video,
  required RemoteSubtitleRefetchOption option,
  required VideoBookRepository repo,
  required VideoBookRow book,
  required Directory tempDir,
  String? destDirOverride,
}) async {
  await tempDir.create(recursive: true);
  final File tmp = File(p.join(tempDir.path, option.localFileName(video.id)));
  try {
    await client.getRemoteVideoSubtitle(
      video.id,
      tmp,
      embeddedStreamIndex: option.track?.streamIndex,
    );
    final SubtitleCueLoadResult preview = await loadExternalSubtitleCueResult(
      tmp.path,
      book.bookUid,
    );
    if (preview.isFailure) {
      return SubtitleAttachResult(
        outcome: SubtitleAttachOutcome.cueLoadFailed,
        cueFailure: preview.failure,
        label: p.basename(tmp.path),
      );
    }
    return await attachSubtitleToVideoBook(
      repo: repo,
      book: book,
      subtitlePath: tmp.path,
      destDirOverride: destDirOverride,
    );
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}
