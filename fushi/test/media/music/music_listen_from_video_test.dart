// 拍板台 oo_8_5z6Aw：视频库「加入收听」——哪些路径能交给音乐播放器只放声音、
// 路径怎么对回曲库曲目（顺序、去重、缺的交给入库）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/music/music_listen_from_video.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

MusicTrackRow _track(String uid, String path, {int? cueStartMs}) =>
    MusicTrackRow(
      trackUid: uid,
      path: path,
      title: uid,
      cueStartMs: cueStartMs,
      isLossless: false,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );

void main() {
  final String root = p.join(p.rootPrefix(p.current), 'media');
  String at(List<String> parts) => p.joinAll(<String>[root, ...parts]);

  group('musicListenablePaths', () {
    test('keeps local video / audio files in order, drops streams, '
        'manifests, relative paths and duplicates', () {
      final List<String> out = musicListenablePaths(<String>[
        at(<String>['Anime', 'ep01.mkv']),
        'https://example.com/live.m3u8',
        'sftp://nas/anime/ep02.mkv',
        at(<String>['Anime', 'show.strm']),
        at(<String>['Anime', 'ep02.mp4']),
        'relative/ep03.mkv',
        at(<String>['Drama', 'cd.flac']),
        at(<String>['Anime', 'ep01.mkv']),
        at(<String>['Disc', 'BDMV']),
        '',
      ]);
      expect(out, <String>[
        at(<String>['Anime', 'ep01.mkv']),
        at(<String>['Anime', 'ep02.mp4']),
        at(<String>['Drama', 'cd.flac']),
      ]);
      expect(musicListenAvailableFor(<String>['https://x/y.mkv']), isFalse);
      expect(
        musicListenAvailableFor(<String>[
          at(<String>['a.webm']),
        ]),
        isTrue,
      );
    });
  });

  group('musicTracksForPaths', () {
    test('follows the requested order, reports missing paths, expands a '
        'multi-track file by cue start', () {
      final List<MusicTrackRow> library = <MusicTrackRow>[
        _track('ep2', at(<String>['Anime', 'ep02.mkv'])),
        _track('cue-b', at(<String>['Live', 'all.flac']), cueStartMs: 60000),
        _track('ep1', at(<String>['Anime', 'ep01.mkv'])),
        _track('cue-a', at(<String>['Live', 'all.flac']), cueStartMs: 0),
      ];
      final ({List<MusicTrackRow> tracks, List<String> missing}) r =
          musicTracksForPaths(<String>[
            at(<String>['Anime', 'ep01.mkv']),
            at(<String>['Anime', 'ep03.mkv']),
            at(<String>['Live', 'all.flac']),
            at(<String>['Anime', 'ep02.mkv']),
          ], library);
      expect(
        <String>[for (final MusicTrackRow t in r.tracks) t.trackUid],
        <String>['ep1', 'cue-a', 'cue-b', 'ep2'],
      );
      expect(r.missing, <String>[
        at(<String>['Anime', 'ep03.mkv']),
      ]);
    });
  });
}
