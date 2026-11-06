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
    List<String> videos = const <String>[],
    List<MusicSourceRoot> music = const <MusicSourceRoot>[],
  }) => planMusicRootsForVideoSourceAudio(
    videoRoot: root,
    audioPaths: audio,
    videoMediaDirs: <String>[...videoDirs, ...videos.map(ctx.dirname)],
    videoFilePaths: videos,
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

  test('dub / commentary tracks in an Audio/ subfolder are not music', () {
    // 字幕组常见的外挂音轨布局：`ep01.mkv` 旁的 `Audio/ep01.<语言或用途>.mka`。
    final MusicAudioRootPlan r = plan(
      audio: <String>[
        '/v/Show/Audio/[Grp] Show - 01.jpn.mka',
        '/v/Show/Audio/[Grp] Show - 02.Commentary.MKA',
        '/v/Show/Audio/[grp] show - 03.mka',
      ],
      videos: <String>[
        '/v/Show/[Grp] Show - 01.mkv',
        '/v/Show/[Grp] Show - 02.mkv',
        '/v/Show/[Grp] Show - 03.mkv',
      ],
    );
    expect(r.roots, isEmpty);
    expect(r.videoTrackAudioPaths, hasLength(3));
  });

  test('album tracks numbered like episodes are still music', () {
    // 纯数字主干不参与外挂音轨匹配；两层以下（CDs/<专辑>/）也不看。
    final MusicAudioRootPlan r = plan(
      audio: <String>[
        '/v/Show/CDs/01.flac',
        '/v/Show/CDs/OST/[Grp] Show - 01.flac',
        '/v/Show/CDs/02 Title.flac',
      ],
      videos: <String>['/v/Show/01.mkv', '/v/Show/[Grp] Show - 01.mkv'],
    );
    expect(r.videoTrackAudioPaths, isEmpty);
    expect(r.roots, <PlannedMusicRoot>[
      (rootPath: '/v/Show/CDs', recursive: true),
    ]);
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

  group('ownedMusicRootsToRetire', () {
    for (final ({p.Context ctx, String root, String Function(String) at}) c
        in <({p.Context ctx, String root, String Function(String) at})>[
          (ctx: p.posix, root: '/v', at: (String s) => '/v/$s'),
          (
            ctx: p.windows,
            root: 'D:/Anime',
            // 来源根按正斜杠归一，视频目录是平台反斜杠：两种写法要认成同一个。
            at: (String s) => 'D:\\Anime\\${s.replaceAll('/', '\\')}',
          ),
        ]) {
      test('${c.ctx.style}: positive evidence only', () {
        String src(String s) => '${c.root}/$s';
        final Map<int, OwnedMusicRootRetireReason> r = ownedMusicRootsToRetire(
          videoRoot: c.root,
          owned: <OwnedMusicRoot>[
            (id: 1, rootPath: src('Gone'), recursive: true),
            (id: 2, rootPath: src('Show'), recursive: false),
            (id: 3, rootPath: src('Drama'), recursive: true),
            (id: 4, rootPath: src('Box'), recursive: true),
            (id: 5, rootPath: src('Kept'), recursive: true),
            (id: 6, rootPath: '/elsewhere/x', recursive: true),
            (id: 7, rootPath: src('Box/Inner'), recursive: true),
            (id: 8, rootPath: src('Flat'), recursive: false),
          ],
          others: <MusicSourceRoot>[(rootPath: src('Drama'), recursive: true)],
          videoMediaDirs: <String>[
            c.at('Show'),
            c.at('Box/Disc/BDMV'),
            c.at('Flat/S1'),
          ],
          dirExists: (String d) => !d.contains('Gone'),
          context: c.ctx,
        );
        expect(r, <int, OwnedMusicRootRetireReason>{
          1: OwnedMusicRootRetireReason.missing,
          2: OwnedMusicRootRetireReason.besideVideo,
          3: OwnedMusicRootRetireReason.covered,
          4: OwnedMusicRootRetireReason.videoInSubtree,
          6: OwnedMusicRootRetireReason.outsideVideoRoot,
        });
        expect(r.containsKey(5), isFalse, reason: '只是这次没列到，目录还在');
        expect(r.containsKey(7), isFalse, reason: 'Box 要撤，不能再拿它当 Inner 的覆盖');
        expect(r.containsKey(8), isFalse, reason: '不递归来源只收自己这一层');
      });
    }
  });
}
