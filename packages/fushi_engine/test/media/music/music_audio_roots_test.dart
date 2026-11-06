// 反馈 QAondMh4M5：视频来源里的纯音频交给音乐库时登记哪些音乐来源。
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final p.Context ctx = p.posix;

  MusicAudioRootPlan plan({
    String root = '/v',
    required List<String> audio,
    List<String> videoDirs = const <String>[],
    List<MusicSourceRoot> music = const <MusicSourceRoot>[],
  }) => planMusicRootsForVideoSourceAudio(
    videoRoot: root,
    audioPaths: audio,
    videoMediaDirs: videoDirs,
    musicSources: music,
    context: ctx,
  );

  test('BD pack: all album folders under CDs/ collapse into one source', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>[
        '/v/Show/CDs/[2021] OST1/01.flac',
        '/v/Show/CDs/[2021] OST1/02.flac',
        '/v/Show/CDs/[2022] Drama CD/01.mp3',
      ],
      videoDirs: <String>['/v/Show', '/v/Show/SPs'],
    );
    expect(r.roots, <PlannedMusicRoot>[
      (rootPath: '/v/Show/CDs', recursive: true),
    ]);
    expect(r.coveredAudioPaths, isEmpty);
    expect(r.besideVideoAudioPaths, isEmpty);
  });

  test('a video source with no video at all becomes one music source', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/a/01.flac', '/v/b/c/02.flac'],
    );
    expect(r.roots, <PlannedMusicRoot>[(rootPath: '/v', recursive: true)]);
  });

  test('audio next to a video is a sidecar track, not taken', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/Show/ep01.flac'],
      videoDirs: <String>['/v/Show'],
    );
    expect(r.roots, isEmpty);
    expect(r.besideVideoAudioPaths, <String>['/v/Show/ep01.flac']);
  });

  test('audio in a folder whose subfolders hold videos: non-recursive', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/Show/op.flac'],
      videoDirs: <String>['/v/Show/S1'],
    );
    expect(r.roots, <PlannedMusicRoot>[
      (rootPath: '/v/Show', recursive: false),
    ]);
  });

  test('already covered by a music source: nothing new registered', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/Show/CDs/OST/01.flac', '/v/Other/02.flac'],
      videoDirs: <String>['/v/Show'],
      music: <MusicSourceRoot>[
        (rootPath: '/v/Show/CDs', recursive: true),
        (rootPath: '/v/Other', recursive: false),
      ],
    );
    expect(r.roots, isEmpty);
    expect(r.coveredAudioPaths, <String>[
      '/v/Show/CDs/OST/01.flac',
      '/v/Other/02.flac',
    ]);
  });

  test('a music source that encloses the video root covers everything', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/x/01.flac'],
      music: <MusicSourceRoot>[(rootPath: '/', recursive: true)],
    );
    expect(r.roots, isEmpty);
    expect(r.coveredAudioPaths, hasLength(1));
  });

  test('non-recursive music source only covers its own folder', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/m/sub/01.flac'],
      music: <MusicSourceRoot>[(rootPath: '/v/m', recursive: false)],
    );
    // 往上爬停在已有来源之下：新来源不包住已有来源。
    expect(r.roots, <PlannedMusicRoot>[
      (rootPath: '/v/m/sub', recursive: true),
    ]);
  });

  test('climbing never grows a new source around an existing one', () {
    final MusicAudioRootPlan r = plan(
      audio: <String>['/v/a/x/01.flac'],
      music: <MusicSourceRoot>[(rootPath: '/v/a/y', recursive: true)],
    );
    expect(r.roots, <PlannedMusicRoot>[(rootPath: '/v/a/x', recursive: true)]);
  });

  test('Windows paths compare case-insensitively', () {
    final MusicAudioRootPlan r = planMusicRootsForVideoSourceAudio(
      videoRoot: r'D:\Anime',
      audioPaths: <String>[r'D:\Anime\Show\CDs\OST\01.flac'],
      videoMediaDirs: <String>[r'd:\anime\show'],
      musicSources: const <MusicSourceRoot>[],
      context: p.windows,
    );
    expect(r.roots, <PlannedMusicRoot>[
      (rootPath: r'D:\Anime\Show\CDs', recursive: true),
    ]);
  });
}
