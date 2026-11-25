/// 本地视频旁的外挂音轨（`ep01.jpn.mka`、`Movie.Eng_Audio_5.1.mka`、
/// `Audio 5.1/Movie_Eng_Audio_5.1.mka` …）：起播时交给播放器以 `audio-add … auto`
/// 挂上（与在线源的外挂音轨同一条路，见 `video_external_audio_tracks.dart`），音轨
/// 面板里能选到，不抢原声。
///
/// 原来本机播放器只挂在线源给的音轨 URL，本地外挂音轨从不加载：发布组随片附的
/// 评论音轨 / 配音 / 整片 FLAC 音轨在本机永远选不到。归属判据在引擎
/// （[listSidecarAudioTracks]），这里只做目录 IO。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;
import 'package:path/path.dart' as p;

/// 列 [dir] 的直接条目：文件名清单 + 子目录路径清单。读不了返回 null。
Future<({List<String> files, List<String> dirs})?> _listDir(String dir) async {
  final List<String> files = <String>[];
  final List<String> dirs = <String>[];
  try {
    await for (final FileSystemEntity e in Directory(
      dir,
    ).list(followLinks: false)) {
      if (e is File) {
        files.add(p.basename(e.path));
      } else if (e is Directory) {
        dirs.add(e.path);
      }
    }
  } on FileSystemException {
    return null;
  }
  return (files: files, dirs: dirs);
}

/// 本地视频 [videoPath] 旁的全部外挂音轨（同目录 + 直接子目录，判据见
/// [listSidecarAudioTracks]），按发现顺序给出播放器要挂的音轨（`url` 是本机绝对
/// 路径）。目录读不了 / 没有时返回空表。
Future<List<RemoteVideoExternalAudioTrack>> discoverLocalSidecarAudioTracks(
  String videoPath,
) async {
  final String dir = p.dirname(videoPath);
  final ({List<String> files, List<String> dirs})? top = await _listDir(dir);
  if (top == null) return const <RemoteVideoExternalAudioTrack>[];
  final String stem = p.basenameWithoutExtension(videoPath);
  final String stemLower = stem.toLowerCase();
  // 子目录只为找外挂音轨而读：先看同目录有没有以主干开头的音频才决定读不读是做不到的
  // （子目录里的文件名才要配），但只读一层、只读文件名，代价是几个 readdir。
  final Map<String, List<String>> children = <String, List<String>>{};
  for (final String child in top.dirs) {
    final ({List<String> files, List<String> dirs})? listed = await _listDir(
      child,
    );
    if (listed == null) continue;
    final List<String> hits = <String>[
      for (final String name in listed.files)
        if (name.toLowerCase().startsWith(stemLower)) name,
    ];
    if (hits.isNotEmpty) children[p.basename(child)] = hits;
  }
  return <RemoteVideoExternalAudioTrack>[
    for (final SidecarAudioTrack t in listSidecarAudioTracks(
      stem,
      top.files,
      childDirFiles: children,
    ))
      if (sidecarAudioLabel(t.tag, p.posix.basename(t.relativePath)) case (
        label: final String label,
        language: final String? language,
      ))
        RemoteVideoExternalAudioTrack(
          url: p.normalize(
            p.joinAll(<String>[dir, ...t.relativePath.split('/')]),
          ),
          label: label,
          language: language,
        ),
  ];
}
