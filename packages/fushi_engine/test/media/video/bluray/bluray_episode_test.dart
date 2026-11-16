// 只有「全部播放」的蓝光剧集盘按 PlayItem 切成各集：切集判据、虚拟分集路径、以及
// 播放 / 规格 / 互联远端 / 存在性判据经分集路径拿到的是不是这一集。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_episode.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart';
import 'package:fushi_engine/media/video/bluray/bluray_remote_title.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bluray_episode_fixture.dart';
import 'bluray_fixture.dart';

/// 各段时长（秒）依次为 [seconds] 的播放列表，每段开头一个章节点。
BlurayPlaylist _playlist(List<int> seconds) => parseBlurayPlaylist(
  buildMplsFixture(
    playItems: <FixturePlayItem>[
      for (int i = 0; i < seconds.length; i++)
        wholeClipItem((i + 1).toString().padLeft(5, '0'), seconds[i]),
    ],
    marks: <FixtureMark>[
      for (int i = 0; i < seconds.length; i++)
        FixtureMark(playItemIndex: i, timestampTicks: kFixtureClipStartTicks),
    ],
  ),
  id: '00001',
)!;

List<(int, int, int)> _spans(List<int> seconds) => <(int, int, int)>[
  for (final BlurayEpisodeSpan span in splitBlurayPlaylistEpisodes(
    _playlist(seconds),
  ))
    (span.firstItem, span.lastItem, span.playItemNumber),
];

void main() {
  group('切集判据', () {
    test('《魔女の旅々》上巻的实测结构：6 段各约 24 分钟 → 6 集', () {
      expect(
        _spans(<int>[1442, 1422, 1422, 1442, 1422, 1422]),
        <(int, int, int)>[
          (0, 0, 1),
          (1, 1, 2),
          (2, 2, 3),
          (3, 3, 4),
          (4, 4, 5),
          (5, 5, 6),
        ],
      );
    });

    test('厂标并入第一集，各集后面的次回预告并入这一集；身份按正片那一段编号', () {
      expect(_spans(<int>[15, 1440, 30, 1440, 30, 1440, 30]), <(int, int, int)>[
        (0, 2, 2),
        (3, 4, 4),
        (5, 6, 6),
      ]);
    });

    test('每卷两集的 TV 盘照切', () {
      expect(_spans(<int>[1440, 1440]), hasLength(2));
    });

    test('A/B 两半各 11～12 分钟的单集 OVA 不切', () {
      expect(_spans(<int>[690, 720]), isEmpty);
    });

    test('切成两段的电影（各 50 分钟以上）不切', () {
      expect(_spans(<int>[3300, 3600]), isEmpty);
    });

    test('三段以上的一小时剧集照切', () {
      expect(_spans(<int>[3300, 3400, 3350]), hasLength(3));
    });

    test('电影（一段正片 + 短段）不切', () {
      expect(_spans(<int>[20, 7200, 60]), isEmpty);
    });

    test('被切成三段等长的电影不切：段的接缝处没有章节点', () {
      final BlurayPlaylist movie = parseBlurayPlaylist(
        buildMplsFixture(
          playItems: <FixturePlayItem>[
            for (int i = 1; i <= 3; i++) wholeClipItem('0000$i', 2400),
          ],
          marks: <FixtureMark>[
            for (int i = 0; i < 12; i++)
              FixtureMark(
                playItemIndex: 0,
                timestampTicks: kFixtureClipStartTicks + 45000 * 60 * i,
              ),
          ],
        ),
        id: '00001',
      )!;
      expect(blurayPlaylistLooksEpisodic(movie), isTrue);
      expect(splitBlurayPlaylistEpisodes(movie), isEmpty);
    });

    test('每集前一段片头（OP 集 OP 集）的归属说不清，不切', () {
      expect(_spans(<int>[90, 1350, 90, 1350, 90, 1350]), isEmpty);
    });

    test('各集另有逐集播放列表、或同片段换顺序的诱饵：正片段被别的播放列表引用', () {
      final BlurayPlaylist playAll = _playlist(<int>[1440, 1440, 1440, 90]);
      final BlurayPlaylist episode = parseBlurayPlaylist(
        buildMplsFixture(
          playItems: <FixturePlayItem>[wholeClipItem('00002', 1440)],
        ),
        id: '00012',
      )!;
      final BlurayPlaylist extra = parseBlurayPlaylist(
        buildMplsFixture(
          playItems: <FixturePlayItem>[wholeClipItem('00004', 90)],
        ),
        id: '00020',
      )!;
      expect(
        blurayPlaylistSharesAnchorClips(playAll, <BlurayPlaylist>[
          playAll,
          episode,
        ]),
        isTrue,
      );
      expect(
        blurayPlaylistSharesAnchorClips(playAll, <BlurayPlaylist>[
          playAll,
          extra,
        ]),
        isFalse,
        reason: '只共用短段（NCOP）不算',
      );
    });
  });

  test('派生播放列表：片段取区间，章节平移到本集零点，id 就是分集文件名', () {
    final BlurayPlaylist playlist = _playlist(<int>[15, 1440, 30, 1440, 30]);
    final List<BlurayPlaylist> episodes = blurayEpisodePlaylists(playlist);
    expect(episodes.map((BlurayPlaylist e) => e.id), <String>[
      '00001.p02',
      '00001.p04',
    ]);
    expect(episodes.first.clipIds, <String>['00001', '00002', '00003']);
    expect(episodes.last.clipIds, <String>['00004', '00005']);
    expect(
      episodes.first.chapters.map((BlurayChapter c) => c.start.inSeconds),
      <int>[0, 15, 1455],
    );
    expect(episodes.last.chapters.first.startTicks, 0);
    expect(episodes.last.chapters.first.playItemIndex, 0);
    expect(episodes.last.chapters, hasLength(2));
    expect(episodes.last.duration, const Duration(seconds: 1470));
    expect(blurayEpisodeForPlayItem(playlist, 4)!.id, '00001.p04');
    expect(
      blurayEpisodeForPlayItem(playlist, 3),
      isNull,
      reason: '第 3 段是预告，不是哪一集的锚点',
    );
  });

  test('分集路径：仍是蓝光成员路径，能反推盘根与背后的 .mpls', () {
    const String path = r'D:\bd\Disc 1\BDMV\PLAYLIST\00001.p03.mpls';
    expect(isBlurayPlaylistPath(path), isTrue);
    expect(isBlurayEpisodePath(path), isTrue);
    final BlurayEpisodeRef ref = parseBlurayEpisodePath(path)!;
    expect(ref.playlistPath, r'D:\bd\Disc 1\BDMV\PLAYLIST\00001.mpls');
    expect(ref.playItemNumber, 3);
    expect(
      parseBlurayEpisodePath(
        '/mnt/bd/BDMV/PLAYLIST/00001.p12.mpls',
      )!.playlistPath,
      '/mnt/bd/BDMV/PLAYLIST/00001.mpls',
    );
    for (final String real in <String>[
      r'D:\bd\BDMV\PLAYLIST\00001.mpls',
      r'D:\bd\BDMV\PLAYLIST\00001.p00.mpls',
      r'D:\video\Show.p03.mkv',
    ]) {
      expect(isBlurayEpisodePath(real), isFalse, reason: real);
    }
    expect(
      blurayEpisodeBackingPlaylistPath(r'D:\bd\BDMV\PLAYLIST\00002.mpls'),
      r'D:\bd\BDMV\PLAYLIST\00002.mpls',
    );
  });

  group('磁盘上的剧集盘', () {
    late Directory temp;
    late String root;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('fushi_bd_episode_');
      root = p.join(temp.path, 'Show [BDMV]', 'Disc 1');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发句柄占用；临时目录留给系统清。
      }
    });

    test('读盘：一条全部播放展开成各集，菜单循环与整条播放列表都不是标题 / 特典', () async {
      writeEpisodicDisc(root, episodes: 6, discName: 'ショー　上巻');
      final BlurayDisc disc = (await readBlurayDisc(root))!;
      expect(disc.titles.map((BlurayTitle t) => t.playlistPath), <String>[
        for (int i = 1; i <= 6; i++) episodePath(root, i),
      ]);
      expect(disc.titles.map((BlurayTitle t) => t.name), <String>[
        for (int i = 1; i <= 6; i++) 'ショー　上巻 - 0$i',
      ]);
      expect(disc.titles.every((BlurayTitle t) => t.isEpisode), isTrue);
      expect(disc.titles.first.sourcePlaylistId, '00001');
      expect(disc.extras.map((BlurayTitle t) => t.playlist.id), <String>[
        '00002',
      ]);
    });

    test('播放源：整段用满一个 m2ts 的一集直接给这段码流的真实路径', () async {
      writeEpisodicDisc(root, episodes: 6);
      final BluraySource source = (await resolveBluraySource(
        episodePath(root, 3),
      ))!;
      expect(source.isPlainFile, isTrue);
      expect(source.uri, p.join(root, 'BDMV', 'STREAM', '00005.m2ts'));
      expect(source.primaryStreamPath, source.uri);
      expect(source.duration, const Duration(seconds: 1442));
      expect(source.chapters, const <Duration>[
        Duration.zero,
        Duration(seconds: 90),
      ]);
    });

    test('播放源：带次回预告的一集是只含本集各段的 edl', () async {
      writeFixturePlaylist(root, '00001', const <(String, int)>[
        ('00003', 1440),
        ('00004', 30),
        ('00005', 1440),
        ('00006', 30),
        ('00007', 1440),
        ('00008', 30),
      ]);
      final BluraySource source = (await resolveBluraySource(
        episodePath(root, 3),
      ))!;
      expect(source.isPlainFile, isFalse);
      expect(decodeEdlSources(source.uri), <String>[
        p.join(root, 'BDMV', 'STREAM', '00005.m2ts'),
        p.join(root, 'BDMV', 'STREAM', '00006.m2ts'),
      ]);
      expect(source.duration, const Duration(seconds: 1470));
    });

    test('规格与互联远端段表只算这一集', () async {
      writeEpisodicDisc(root, episodes: 6);
      final VideoProbeFacts facts = await probeBlurayPlaylistFacts(
        episodePath(root, 2),
      );
      expect(facts.durationMs, 1422 * 1000);
      final BlurayTitleStreams streams = (await readBlurayTitleStreams(
        episodePath(root, 2),
      ))!;
      expect(streams.streamPaths, <String>[
        p.join(root, 'BDMV', 'STREAM', '00004.m2ts'),
      ]);
    });

    test('存在性：背后的 .mpls 在就算在，但它本身不是一个文件', () async {
      writeEpisodicDisc(root, episodes: 6);
      final String path = episodePath(root, 4);
      expect(
        discMemberBackingFilePath(path),
        p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
      );
      expect(discRootForMemberPath(path), root);
      expect(await videoMemberExists(path), isTrue);
      expect(videoMemberExistsSync(path), isTrue);
      expect(await hasLocalMediaFile(path), isTrue);
      expect(await videoPathFileExists(path), isFalse);
      // 能经 ffmpeg 读到 ≠ 路径本身装着媒体字节：按字节读的消费方（上传、弹幕指纹、
      // 任务目录身份）问的是后者，分集与整卷 .mpls 都必须答「否」。
      final String whole = p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls');
      for (final String member in <String>[path, whole]) {
        expect(await hasLocalSingleMediaFile(member), isFalse, reason: member);
        expect(hasLocalSingleMediaFileSync(member), isFalse, reason: member);
        expect(videoPathLacksSingleMediaFile(member), isTrue, reason: member);
      }
      final String clip = p.join(root, 'BDMV', 'STREAM', '00006.m2ts');
      expect(await hasLocalSingleMediaFile(clip), isTrue);
      expect(hasLocalSingleMediaFileSync(clip), isTrue);
      expect(await File(clip).length(), greaterThan(0));
      File(p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls')).deleteSync();
      expect(await videoMemberExists(path), isFalse);
      expect(await resolveBluraySource(path), isNull);
    });

    test('对不上的分集路径读不出播放列表', () async {
      writeEpisodicDisc(root, episodes: 6);
      expect(await readBlurayMemberPlaylist(episodePath(root, 9)), isNull);
      // 这条播放列表不再切集（换成了电影盘）：旧的分集路径一律作废。
      File(p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls')).writeAsBytesSync(
        Uint8List.fromList(
          buildMplsFixture(
            playItems: <FixturePlayItem>[wholeClipItem('00003', 7200)],
          ),
        ),
      );
      expect(await readBlurayMemberPlaylist(episodePath(root, 1)), isNull);
      expect(
        (await readBlurayMemberPlaylist(
          p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
        ))!.id,
        '00001',
      );
    });
  });
}
