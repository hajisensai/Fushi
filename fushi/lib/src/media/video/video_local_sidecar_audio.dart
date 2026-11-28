/// 本地视频旁的外挂音轨（`ep01.jpn.mka`、`Movie.Eng_Audio_5.1.mka`、
/// `Audio 5.1/Movie_Eng_Audio_5.1.mka` …）：起播时交给播放器以 `audio-add … auto`
/// 挂上（与在线源的外挂音轨同一条路，见 `video_external_audio_tracks.dart`），音轨
/// 面板里能选到，不抢原声。
///
/// 原来本机播放器只挂在线源给的音轨 URL，本地外挂音轨从不加载：发布组随片附的
/// 评论音轨 / 配音 / 整片 FLAC 音轨在本机永远选不到。发现（目录 IO + 归属判据）在
/// 引擎 [discoverSidecarAudioTrackFiles]，互联 host 给远端下发音轨用的也是它；这里
/// 只把结果换成播放器要的音轨形状。
library;

import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;

/// 本地视频 [videoPath] 旁的全部外挂音轨（同目录 + 直接子目录，判据见
/// [listSidecarAudioTracks]），按发现顺序给出播放器要挂的音轨（`url` 是本机绝对
/// 路径）。目录读不了 / 没有时返回空表。
Future<List<RemoteVideoExternalAudioTrack>> discoverLocalSidecarAudioTracks(
  String videoPath,
) async => <RemoteVideoExternalAudioTrack>[
  for (final SidecarAudioTrackFile t in await discoverSidecarAudioTrackFiles(
    videoPath,
  ))
    RemoteVideoExternalAudioTrack(
      url: t.path,
      label: t.label,
      language: t.language,
    ),
];
