/// 「原曲」与「其它版本」（音乐方案 §8.2）：录音 → `performance of` 作品 → 该作品的全部
/// 录音。原曲 = 不带 cover / live / karaoke / instrumental 等属性的**最早发行**录音；
/// 其余（含翻唱 / 歌ってみた / Live / 混音）都是「其它版本」。MV（视频录音）不算版本，
/// 由 MV 匹配另行处理。
library;

import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_text.dart';

/// 不能当「原曲」的关系属性。
const Set<String> kNonOriginalPerformanceAttributes = <String>{
  'cover',
  'live',
  'karaoke',
  'instrumental',
  'partial',
  'medley',
};

class MusicVersions {
  const MusicVersions({
    required this.work,
    required this.original,
    required this.selfIsOriginal,
    required this.others,
  });

  final MusicWork work;

  /// 判定出的原曲；作品里没有可判的录音时为 null。
  final MusicWorkRecording? original;

  /// 当前这首就是原曲。
  final bool selfIsOriginal;

  /// 其它版本（不含自己、不含原曲、不含视频录音），按首发日期升序。
  final List<MusicWorkRecording> others;
}

int _byDate(MusicWorkRecording a, MusicWorkRecording b) {
  final int c = musicDateSortKey(
    a.firstReleaseDate,
  ).compareTo(musicDateSortKey(b.firstReleaseDate));
  return c != 0 ? c : a.mbRecordingId.compareTo(b.mbRecordingId);
}

MusicVersions resolveMusicVersions(MusicWork work, String selfRecordingId) {
  final List<MusicWorkRecording> audio = <MusicWorkRecording>[
    for (final MusicWorkRecording r in work.recordings)
      if (!r.isVideo) r,
  ]..sort(_byDate);
  final List<MusicWorkRecording> originals = <MusicWorkRecording>[
    for (final MusicWorkRecording r in audio)
      if (!r.attributes.any(kNonOriginalPerformanceAttributes.contains)) r,
  ];
  final MusicWorkRecording? original = originals.firstOrNull;
  return MusicVersions(
    work: work,
    original: original,
    selfIsOriginal: original?.mbRecordingId == selfRecordingId,
    others: <MusicWorkRecording>[
      for (final MusicWorkRecording r in audio)
        if (r.mbRecordingId != selfRecordingId &&
            r.mbRecordingId != original?.mbRecordingId)
          r,
    ],
  );
}
