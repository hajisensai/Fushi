/// 视频播放页控制（`fushi_cli video volume / audio / subs / sub-* / mine / clip /
/// job …`）的纯函数部分：参数解析、失败映射与 JSON 形状，与路由分开以便单测。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show WebMineQueueRow;

import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart'
    show decodeWebMineFields;

/// 视频页遥控失败 → 控制通道状态码。
CtlFailure ctlVideoRemoteFailure(VideoRemoteFailure failure) =>
    switch (failure.code) {
      'no_video' || 'busy' => CtlFailure.conflict(failure.message),
      'not_found' => CtlFailure.notFound(failure.message),
      'unsupported' => CtlFailure.unsupported(failure.message),
      'bad_request' => CtlFailure.badRequest(failure.message),
      _ => CtlFailure(422, failure.code, failure.message),
    };

/// 音量：0–100 的数字。
double parseCtlVideoVolume(Object? raw) {
  final double? value = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (value == null || value.isNaN || value < 0 || value > 100) {
    throw const CtlFailure.badRequest('volume 必须在 0–100 之间');
  }
  return value;
}

/// 片段区间：毫秒整数，start < end。
({int startMs, int endMs}) parseCtlVideoClipRange(CtlCall call) {
  final int? start = call.optInt('startMs');
  final int? end = call.optInt('endMs');
  if (start == null || end == null) {
    throw const CtlFailure.badRequest('startMs / endMs 缺失');
  }
  if (start < 0 || end <= start) {
    throw CtlFailure.badRequest('区间无效：$start–$end ms');
  }
  return (startMs: start, endMs: end);
}

List<Map<String, Object?>> ctlVideoAudioTracksJson(
  List<VideoRemoteAudioTrack> tracks,
) => <Map<String, Object?>>[
  for (final VideoRemoteAudioTrack track in tracks)
    <String, Object?>{
      'id': track.id,
      'label': track.label,
      'language': track.language,
      'title': track.title,
      'selected': track.selected,
    },
];

Map<String, Object?> ctlVideoSubtitleStateJson(
  VideoRemoteSubtitleState state,
) => <String, Object?>{
  'remote': state.remote,
  'primary': state.primarySource,
  'secondary': state.secondarySource,
  'asrAvailable': state.asrAvailable,
  'alignAvailable': state.alignAvailable,
  'clipAvailable': state.clipAvailable,
  'tracks': <Map<String, Object?>>[
    for (int i = 0; i < state.tracks.length; i++)
      <String, Object?>{
        'index': i + 1,
        'source': state.tracks[i].source,
        'label': state.tracks[i].label,
        'kind': state.tracks[i].kind.name,
        'language': state.tracks[i].language,
        'codec': state.tracks[i].codec,
        'primary': state.tracks[i].primary,
        'secondary': state.tracks[i].secondary,
        'ocr': state.tracks[i].ocrAvailable,
        'selectable': state.tracks[i].selectable,
        'secondarySelectable': state.tracks[i].secondarySelectable,
      },
  ],
};

/// CLI 传来的字幕轨：持久化值原样用；纯数字按 [state] 列表的 1 起序号换成持久化值。
String resolveCtlVideoSubtitleSource(
  String raw,
  VideoRemoteSubtitleState state,
) {
  final String value = raw.trim();
  final int? index = int.tryParse(value);
  if (index != null) {
    if (index < 1 || index > state.tracks.length) {
      throw CtlFailure.notFound(
        '没有第 $index 条字幕轨（共 ${state.tracks.length} 条，video subs 查看）',
      );
    }
    return state.tracks[index - 1].source;
  }
  return value;
}

Map<String, Object?> ctlVideoJobJson(VideoRemoteJob job) => <String, Object?>{
  'id': job.id,
  'kind': job.kind.name,
  'status': job.status.name,
  'phase': job.phase,
  'progress': job.fraction,
  if (job.detail != null) 'detail': job.detail,
  'cancellable': job.cancellable,
  'bookUid': job.bookUid,
  'startedAt': job.startedAt.millisecondsSinceEpoch,
  if (job.finishedAt != null)
    'finishedAt': job.finishedAt!.millisecondsSinceEpoch,
  if (job.errorCode != null) 'errorCode': job.errorCode,
  if (job.error != null) 'error': job.error,
  if (job.result.isNotEmpty) 'result': job.result,
  if (job.messages.isNotEmpty) 'messages': job.messages,
};

/// 视频页播放状态；[snapshot] 为 null = 页面开着但视频还在加载。
Map<String, Object?> ctlVideoPlayerStatusJson(VideoPlaybackSnapshot? snapshot) {
  if (snapshot == null) {
    return <String, Object?>{'active': true, 'ready': false};
  }
  return <String, Object?>{
    'active': true,
    'ready': true,
    'bookUid': snapshot.bookUid,
    'title': snapshot.title,
    'playing': snapshot.playing,
    'positionMs': snapshot.positionMs,
    'durationMs': snapshot.durationMs,
    'speed': snapshot.speed,
    'volume': snapshot.volume,
    'audioTrack': snapshot.audioTrackId,
    'subtitle': snapshot.subtitleSource,
    'secondarySubtitle': snapshot.secondarySubtitleSource,
    'cue': snapshot.cue,
  };
}

Map<String, Object?> ctlVideoMineResultJson(VideoRemoteMineResult result) =>
    <String, Object?>{
      'ok': result.success,
      'queued': result.queued,
      'duplicate': result.duplicate,
      if (result.noteId != null) 'noteId': result.noteId,
      if (result.sentence != null) 'sentence': result.sentence,
    };

/// 暂存制卡队列的一行（字段取冻结的 Anki 字段里的词头）。
Map<String, Object?> ctlVideoMineQueueRowJson(WebMineQueueRow row) {
  final Map<String, String> fields = decodeWebMineFields(row.fieldsJson);
  return <String, Object?>{
    'id': row.id,
    'status': row.status,
    'expression': fields['expression'],
    'sentence': row.sentence,
    'startMs': row.cueStartMs,
    'endMs': row.cueEndMs,
    'createdAt': row.createdAt,
    if (row.error != null) 'error': row.error,
  };
}

/// 网页播放器自动制卡（`video/stream/…`）与暂存队列同表，但写入要靠重放网页补媒体，
/// 不能走「看完再制卡」的写入；CLI 只碰视频页暂存的卡。
bool isCtlVideoMineQueueBook(String bookUid) =>
    bookUid.isNotEmpty && !bookUid.startsWith('video/stream/');
