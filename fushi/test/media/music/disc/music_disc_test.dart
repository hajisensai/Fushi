// 演唱会 / MV 合集 DVD·BD「章节导入为曲目」（音乐方案 §9.2）：章节表、播放源、导入落库、
// MusicBrainz 对号套用。盘全部用字节级合成的 IFO / MPLS（`dvd_fixture.dart` /
// `bluray_fixture.dart`），不碰商业盘。

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_engine/media/music/disc/music_disc_media.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:path/path.dart' as p;

import '../../video/bluray_fixture.dart';
import '../../video/dvd_fixture.dart';

/// 一张演唱会 DVD：title 1 是正片（PGC 1，三个 cell = 三首，program map 写明），title 2 是
/// 片尾的 8 秒厂标。
void _writeConcertDvd(String root) {
  writeDvdFixture(
    root,
    titles: const <FixtureDvdTitle>[
      FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 3),
      FixtureDvdTitle(titleSet: 1, vtsTitle: 2, chapters: 1),
    ],
    titleSets: const <FixtureDvdTitleSet>[
      FixtureDvdTitleSet(
        pgcs: <FixtureDvdPgc>[
          FixtureDvdPgc(
            <FixtureDvdCell>[
              FixtureDvdCell(240, 0, 99),
              FixtureDvdCell(300, 100, 199),
              FixtureDvdCell(260, 200, 299),
            ],
            programMap: <int>[1, 2, 3],
          ),
          FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(8, 300, 309)]),
        ],
        titles: <FixtureDvdVtsTitle>[
          FixtureDvdVtsTitle(<int>[1, 1, 1]),
          FixtureDvdVtsTitle(<int>[2]),
        ],
      ),
    ],
  );
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('music_disc_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄占用；临时目录留给系统清。
    }
  });

  group('章节表', () {
    test('起点表 → 起止；首个章节点不在 0 时前段并进第一章', () {
      expect(
        musicDiscChaptersOf(
          starts: const <Duration>[
            Duration(seconds: 2),
            Duration(seconds: 60),
            Duration(seconds: 120),
          ],
          duration: const Duration(seconds: 200),
        ),
        const <MusicDiscChapter>[
          MusicDiscChapter(
            number: 1,
            start: Duration.zero,
            end: Duration(seconds: 60),
          ),
          MusicDiscChapter(
            number: 2,
            start: Duration(seconds: 60),
            end: Duration(seconds: 120),
          ),
          MusicDiscChapter(
            number: 3,
            start: Duration(seconds: 120),
            end: Duration(seconds: 200),
          ),
        ],
      );
    });

    test('过短章节并进前一章；重复 / 越界起点丢掉；没有章节点 = 整条一首', () {
      final List<MusicDiscChapter> chapters = musicDiscChaptersOf(
        starts: const <Duration>[
          Duration.zero,
          Duration(seconds: 90),
          Duration(seconds: 90),
          Duration(milliseconds: 179600),
          Duration(seconds: 500),
        ],
        duration: const Duration(seconds: 180),
      );
      expect(
        chapters.map((MusicDiscChapter c) => (c.number, c.start, c.end)),
        <(int, Duration, Duration)>[
          (1, Duration.zero, const Duration(seconds: 90)),
          (2, const Duration(seconds: 90), const Duration(seconds: 180)),
        ],
      );
      expect(
        musicDiscChaptersOf(
          starts: const <Duration>[],
          duration: const Duration(seconds: 30),
        ).single.duration,
        const Duration(seconds: 30),
      );
    });
  });

  group('DVD 章节起点（program map）', () {
    test('program map → 各章节在 title 时间轴上的起点', () async {
      final String root = p.join(tmp.path, 'Concert');
      _writeConcertDvd(root);
      final DvdDisc disc = (await readDvdDisc(root))!;
      final DvdTitleCandidate main = disc.candidates.firstWhere(
        (DvdTitleCandidate c) => c.entry.titleNumber == 1,
      );
      expect(main.chapterStarts, const <Duration>[
        Duration.zero,
        Duration(seconds: 240),
        Duration(seconds: 540),
      ]);
    });

    test('角度块里非首个角度的 cell 不计入章节起点', () async {
      final String root = p.join(tmp.path, 'Angles');
      writeDvdFixture(
        root,
        titles: const <FixtureDvdTitle>[
          FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 3),
        ],
        titleSets: const <FixtureDvdTitleSet>[
          FixtureDvdTitleSet(
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(
                <FixtureDvdCell>[
                  FixtureDvdCell(60, 0, 99),
                  // 角度块：块首（0x50）、块中（0x90）、块尾（0xD0），同一段 30 s。
                  FixtureDvdCell(30, 100, 199, category: 0x50),
                  FixtureDvdCell(30, 200, 299, category: 0x90),
                  FixtureDvdCell(30, 300, 399, category: 0xD0),
                  FixtureDvdCell(40, 400, 499),
                ],
                headerSeconds: 130,
                programMap: <int>[1, 2, 5],
              ),
            ],
            titles: <FixtureDvdVtsTitle>[
              FixtureDvdVtsTitle(<int>[1, 1, 1]),
            ],
          ),
        ],
      );
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.candidates.single.chapterStarts, const <Duration>[
        Duration.zero,
        Duration(seconds: 60),
        Duration(seconds: 90),
      ]);
    });

    test('program map 缺失且 program 数 ≠ cell 数：章节起点不可知（不猜）', () async {
      final String root = p.join(tmp.path, 'NoMap');
      writeDvdFixture(
        root,
        titles: const <FixtureDvdTitle>[
          FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 2),
        ],
        titleSets: const <FixtureDvdTitleSet>[
          FixtureDvdTitleSet(
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(600, 0, 99)]),
            ],
            titles: <FixtureDvdVtsTitle>[
              // 两个章节都指 PGC 1，但 PGC 1 只有一个 cell、没写 program map。
              FixtureDvdVtsTitle(<int>[1, 1]),
            ],
          ),
        ],
      );
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.candidates.single.chapterStarts, isEmpty);
      // 音乐侧：章节不可知的 title 整条当一首（MusicDiscInfo 里只有一章）。
      final MusicDiscInfo info = (await readMusicDiscInfo(root))!;
      expect(info.titles.single.chapters, isEmpty);
    });
  });

  group('读盘', () {
    test('DVD：title + 章节、盘身份、正片', () async {
      final String root = p.join(tmp.path, 'Live Tour 2020');
      _writeConcertDvd(root);
      final MusicDiscInfo info = (await readMusicDiscInfo(root))!;
      expect(info.kind, MusicDiscKind.dvd);
      expect(info.name, 'Live Tour 2020');
      expect(info.discId, hasLength(32));
      final MusicDiscTitle main = info.titles.firstWhere(
        (MusicDiscTitle t) => t.number == 1,
      );
      expect(main.isMainFeature, isTrue);
      expect(main.titlePath, dvdTitlePath(root, 1));
      expect(main.chapters.map((MusicDiscChapter c) => c.end.inSeconds), <int>[
        240,
        540,
        800,
      ]);
      expect(info.identityFilePath, p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO'));
    });

    test('BD：播放列表的章节标记 → 章节；尾部几帧的收尾章节点并进最后一首', () async {
      final String root = p.join(tmp.path, 'BD Live');
      for (final String dir in <String>['PLAYLIST', 'STREAM', 'CLIPINF']) {
        Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
      }
      const int t0 = 45000 * 4;
      File(p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls')).writeAsBytesSync(
        buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00010',
              inTimeTicks: t0,
              outTimeTicks: t0 + 45000 * 300,
            ),
            FixturePlayItem(
              clipId: '00011',
              inTimeTicks: t0,
              outTimeTicks: t0 + 45000 * 200,
            ),
          ],
          marks: const <FixtureMark>[
            FixtureMark(playItemIndex: 0, timestampTicks: t0),
            FixtureMark(playItemIndex: 0, timestampTicks: t0 + 45000 * 180),
            FixtureMark(playItemIndex: 1, timestampTicks: t0 + 45000 * 60),
            // 收尾标记：离结尾 0.2 s。
            FixtureMark(
              playItemIndex: 1,
              timestampTicks: t0 + 45000 * 200 - 9000,
            ),
          ],
          streams: const <FixtureStream>[
            FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
            FixtureStream.audio(codingType: 0x80, language: 'jpn'),
          ],
        ),
      );
      for (final String clip in <String>['00010', '00011']) {
        File(
          p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
        ).writeAsBytesSync(Uint8List(16));
      }
      final MusicDiscInfo info = (await readMusicDiscInfo(root))!;
      expect(info.kind, MusicDiscKind.bluray);
      final MusicDiscTitle title = info.titles.single;
      expect(
        title.chapters.map(
          (MusicDiscChapter c) => (c.start.inSeconds, c.end.inSeconds),
        ),
        <(int, int)>[(0, 180), (180, 360), (360, 500)],
      );

      // 第 2 首（180–360 s）跨两段：第一段 00010 的 180–300 s，第二段 00011 的 0–60 s；
      // EDL 起点是 MPLS 原始 PTS（含 t0），不减零点。
      final MusicDiscMediaSource src = (await musicBlurayMediaSource(
        title.titlePath,
        startMs: 180000,
        endMs: 360000,
      ))!;
      final String s00010 = p.join(root, 'BDMV', 'STREAM', '00010.m2ts');
      final String s00011 = p.join(root, 'BDMV', 'STREAM', '00011.m2ts');
      expect(
        src.uri,
        'edl://%${s00010.length}%$s00010,184.000000,120.000000;'
        '%${s00011.length}%$s00011,4.000000,60.000000;',
      );
      expect(src.fileLocalOptions, kMusicDiscAudioOnlyOptions);
    });
  });

  group('播放源', () {
    test('DVD 章节：dvdvideo 整条 title 读出 + EDL 按章节时间裁', () {
      final String title = dvdTitlePath('/discs/Live', 3);
      final MusicDiscMediaSource src = musicDvdMediaSource(
        title,
        startMs: 240000,
        endMs: 540000,
      )!;
      final String source = p.join(p.normalize('/discs/Live'), 'VIDEO_TS');
      expect(
        src.uri,
        'edl://%${source.length}%$source,start=240.000000,length=300.000001',
      );
      expect(src.fileLocalOptions['demuxer-lavf-format'], 'dvdvideo');
      expect(src.fileLocalOptions['demuxer-lavf-o'], 'title=3');
      expect(src.fileLocalOptions['vid'], 'no');
      // 镜像形态：源是 .iso 本身。
      expect(
        musicDvdMediaSource(
          dvdTitlePath('/discs/Live.iso', 1),
          startMs: 0,
        )!.uri,
        startsWith(
          'edl://%15%${p.normalize('/discs/Live.iso')},'
          'start=0.000000,length=86400',
        ),
      );
    });

    test('后端解析：光盘曲目带逐文件选项，普通文件不带', () async {
      final MusicResolvedMedia dvd = await resolveMusicMedia(
        MusicPlayItem(
          trackUid: 'a',
          path: dvdTitlePath('/discs/Live', 1),
          title: 'x',
          startMs: 0,
          endMs: 1000,
        ),
      );
      expect(dvd.media.uri, startsWith('edl://'));
      expect(dvd.fileLocal['demuxer-lavf-o'], 'title=1');
      final MusicResolvedMedia flac = await resolveMusicMedia(
        const MusicPlayItem(trackUid: 'b', path: '/m/a.flac', title: 'y'),
      );
      expect(flac.media.uri, '/m/a.flac');
      expect(flac.fileLocal, isEmpty);
    });
  });

  group('导入落库', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('登记 → 导入 → 改名 → 重新导入不冲掉名字 → 少选的软删 → 移除', () async {
      final String root = p.join(tmp.path, 'Live');
      _writeConcertDvd(root);
      int clock = 1000;
      final MusicDiscImportService service = MusicDiscImportService(
        db,
        now: () => clock++,
      );

      final String albumUid = await service.registerDisc(root);
      // 还没导入章节：专辑已在曲库里（入口就在它上面）。
      final List<MusicAlbumRow> albums = await db.listMusicAlbums();
      expect(albums.single.albumUid, albumUid);
      expect(albums.single.discUid, isNotNull);
      expect(await db.listMusicTracks(), isEmpty);

      final MusicDiscInfo info = await service.readDisc(root);
      final int count = await service.importChapters(
        info,
        titleNumbers: <int>{1, 2},
        chapterTitle: (MusicDiscTitle t, MusicDiscChapter c) =>
            'T${t.number}C${c.number}',
      );
      expect(count, 4);
      final List<MusicTrackRow> tracks = await db.listMusicTracks(
        albumUid: albumUid,
      );
      expect(tracks.map((MusicTrackRow t) => t.title), <String>[
        'T1C1',
        'T1C2',
        'T1C3',
        'T2C1',
      ]);
      expect(tracks.map((MusicTrackRow t) => t.trackNo), <int?>[1, 2, 3, 4]);
      expect(tracks[1].path, dvdTitlePath(root, 1));
      expect(tracks[1].cueStartMs, 240000);
      expect(tracks[1].cueEndMs, 540000);
      // 每个 title 的最后一章播到 title 结尾。
      expect(tracks[2].cueEndMs, isNull);
      expect(tracks[2].durationMs, 260000);
      expect(tracks.every((MusicTrackRow t) => t.sourceId == null), isTrue);
      final MusicDiscSourceRow disc = (await db.listMusicDiscSources()).single;
      expect(disc.kind, 'dvd');
      expect(disc.path, root);
      expect(
        decodeMusicDiscTitleMap(
          disc.titleMapJson,
        ).map((MusicDiscTrackRef r) => (r.titleNumber, r.chapterNumber)),
        <(int, int)>[(1, 1), (1, 2), (1, 3), (2, 1)],
      );

      // MusicBrainz 对号：只拿正片 3 首对一张 3 曲的发行。
      final MusicReleaseTracklist release = MusicReleaseTracklist(
        mbReleaseId: '11111111-2222-3333-4444-555555555555',
        title: 'LIVE TOUR 2020',
        artistCredit: 'Band',
        date: '2020-12-24',
        media: const <MusicReleaseMedium>[
          MusicReleaseMedium(
            position: 1,
            format: 'DVD-Video',
            tracks: <MusicReleaseTrack>[
              MusicReleaseTrack(
                position: 1,
                title: 'Opening',
                durationMs: 239000,
              ),
              MusicReleaseTrack(
                position: 2,
                title: 'Song A',
                durationMs: 301000,
              ),
              MusicReleaseTrack(
                position: 3,
                title: 'Song B',
                durationMs: 259000,
              ),
            ],
          ),
        ],
      );
      final List<MusicTrackRow> mainTracks = tracks.sublist(0, 3);
      final MusicDiscReleaseMatch match = matchMusicDiscChapters(<int>[
        for (final MusicTrackRow t in mainTracks) t.durationMs!,
      ], release)!;
      expect(match.isConfident, isTrue);
      expect(
        await service.applyRelease(
          albumUid: albumUid,
          match: match,
          tracks: tracks,
        ),
        isFalse,
        reason: '曲数对不上不半截套用',
      );
      expect(
        await service.applyRelease(
          albumUid: albumUid,
          match: match,
          tracks: mainTracks,
        ),
        isTrue,
      );
      final MusicAlbumRow album = (await db.getMusicAlbum(albumUid))!;
      expect(album.title, 'LIVE TOUR 2020');
      expect(album.mbReleaseId, release.mbReleaseId);

      // 重新导入只选正片：MusicBrainz 名字保留，厂标那首软删。
      await service.importChapters(
        info,
        titleNumbers: <int>{1},
        chapterTitle: (MusicDiscTitle t, MusicDiscChapter c) => 'again',
      );
      final List<MusicTrackRow> after = await db.listMusicTracks(
        albumUid: albumUid,
      );
      expect(after.map((MusicTrackRow t) => t.title), <String>[
        'Opening',
        'Song A',
        'Song B',
      ]);
      expect((await db.getMusicAlbum(albumUid))!.title, 'LIVE TOUR 2020');

      await db.removeMusicDisc(discUid: disc.discUid, deletedAt: 9);
      expect(await db.listMusicAlbums(), isEmpty);
      expect(await db.listMusicTracks(), isEmpty);
      expect(await db.listMusicDiscSources(), isEmpty);
    });

    test('同一张盘挪了目录：仍是同一张专辑、同一批曲目 uid', () async {
      final String a = p.join(tmp.path, 'A', 'Live');
      final String b = p.join(tmp.path, 'B', 'Live (copy)');
      _writeConcertDvd(a);
      _writeConcertDvd(b);
      final MusicDiscInfo ia = (await readMusicDiscInfo(a))!;
      final MusicDiscInfo ib = (await readMusicDiscInfo(b))!;
      expect(ia.discId, ib.discId);
      expect(
        musicDiscAlbumUid(ia.kind, ia.discId),
        musicDiscAlbumUid(ib.kind, ib.discId),
      );
    });

    test('目录树里认盘：DVD / BD 目录与 .iso；盘内部不往下走', () {
      _writeConcertDvd(p.join(tmp.path, 'music', 'Live'));
      Directory(
        p.join(tmp.path, 'music', 'BD', 'BDMV', 'PLAYLIST'),
      ).createSync(recursive: true);
      File(p.join(tmp.path, 'music', 'x', 'disc.iso'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(4));
      File(
        p.join(tmp.path, 'music', 'album', '01.flac'),
      ).createSync(recursive: true);
      expect(findMusicDiscRoots(p.join(tmp.path, 'music')), <String>[
        p.join(tmp.path, 'music', 'BD'),
        p.join(tmp.path, 'music', 'Live'),
        p.join(tmp.path, 'music', 'x', 'disc.iso'),
      ]);
    });
  });
}
