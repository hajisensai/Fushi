// 音频 CD（音乐方案 §9.2）：读盘结果 → 曲库行（名字优先级 MusicBrainz → CD-TEXT → 轨号）、
// 落库、播放源；设了 FUSHI_TEST_CD_DRIVE 时读本机光驱里的真盘并查 MusicBrainz。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/disc/music_audio_cd.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_music/fushi_music.dart';

/// 三轨盘：轨 1 从 LBA 0、轨 2 从 13.333 s（1000 帧）、轨 3 从 30 s。CD-TEXT 只有轨 1 的标题。
const AudioCdInfo _info = AudioCdInfo(
  firstTrack: 1,
  lastTrack: 3,
  leadoutLba: 4500,
  discId: 'wQ8ygYRJ6TxS9evQ5yIRDW8yJLo-',
  tocQuery: '1 3 4650 150 1150 2400',
  tracks: <AudioCdTrack>[
    AudioCdTrack(number: 1, isData: false, lba: 0, lengthFrames: 1000),
    AudioCdTrack(number: 2, isData: false, lba: 1000, lengthFrames: 1250),
    AudioCdTrack(number: 3, isData: false, lba: 2250, lengthFrames: 2250),
  ],
  cdText: <AudioCdTextEntry>[
    AudioCdTextEntry(
      track: 0,
      field: AudioCdTextField.title,
      value: 'CD-TEXT Album',
    ),
    AudioCdTextEntry(track: 1, field: AudioCdTextField.title, value: 'Intro'),
  ],
);

void main() {
  test('没有 MusicBrainz：CD-TEXT → 轨号；起止按帧换算；末轨播到盘尾', () {
    final MusicAudioCdRows rows = musicAudioCdRows(
      _info,
      device: 'E:',
      fallbackTitle: (int n) => 'Track $n',
      fallbackAlbumTitle: 'Audio CD',
      now: 1,
    );
    expect(rows.album.title.value, 'CD-TEXT Album');
    expect(rows.disc.kind.value, 'cdda');
    expect(rows.disc.path.value, 'E:');
    expect(rows.tracks.map((MusicTracksCompanion t) => t.title.value), <String>[
      'Intro',
      'Track 2',
      'Track 3',
    ]);
    expect(rows.tracks[1].path.value, 'cdda://E:');
    expect(rows.tracks[1].cueStartMs.value, 13333);
    expect(rows.tracks[1].cueEndMs.value, 13333 + 16667);
    expect(rows.tracks[2].cueEndMs.value, isNull);
    expect(rows.tracks[2].durationMs.value, 30000);
    expect(rows.tracks.first.isLossless.value, isTrue);
  });

  test('MusicBrainz 发行优先，轨数对得上的 medium 才用', () {
    const MusicReleaseTracklist release = MusicReleaseTracklist(
      mbReleaseId: '11111111-2222-3333-4444-555555555555',
      title: '特典CD',
      artistCredit: 'Various',
      media: <MusicReleaseMedium>[
        MusicReleaseMedium(
          position: 2,
          format: 'CD',
          tracks: <MusicReleaseTrack>[
            MusicReleaseTrack(position: 1, title: 'A'),
            MusicReleaseTrack(position: 2, title: 'B', artistCredit: 'Solo'),
            MusicReleaseTrack(position: 3, title: 'C'),
          ],
        ),
      ],
    );
    final MusicAudioCdRows rows = musicAudioCdRows(
      _info,
      device: 'E:',
      fallbackTitle: (int n) => 'Track $n',
      fallbackAlbumTitle: 'Audio CD',
      now: 1,
      release: release,
    );
    expect(rows.album.title.value, '特典CD');
    expect(rows.album.mbReleaseId.value, release.mbReleaseId);
    expect(rows.tracks.map((MusicTracksCompanion t) => t.title.value), <String>[
      'A',
      'B',
      'C',
    ]);
    expect(rows.tracks[1].artistCredit.value, 'Solo');
    expect(rows.tracks[0].artistCredit.value, 'Various');
    expect(rows.tracks[0].discNo.value, 2);
  });

  test('落库 → 再读一次覆盖名字；播放源是 cdda + 逐文件 start / end', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final MusicAudioCdService service = MusicAudioCdService(
      db,
      listDrives: () async => <String>['E:'],
      read: (String device) async => _info,
    );
    expect(await service.listDrives(), <String>['E:']);
    final AudioCdInfo info = await service.read('E:');
    final String albumUid = await service.import(
      info,
      device: 'E:',
      fallbackTitle: (int n) => 'Track $n',
      fallbackAlbumTitle: 'Audio CD',
    );
    final MusicAlbumRow album = (await db.getMusicAlbum(albumUid))!;
    expect(album.discUid, isNotNull);
    final List<MusicTrackRow> tracks = sortAlbumTracks(
      await db.listMusicTracks(albumUid: albumUid),
    );
    expect(tracks, hasLength(3));

    final MusicResolvedMedia media = await resolveMusicMedia(
      musicPlayItemOf(tracks[1], album: album),
    );
    expect(media.media.uri, 'cdda://E:');
    // 毫秒按扇区还原到轨界（1000 帧 = 13.333… s），起止都后挪 1 µs（mpv 截断取样本）。
    expect(media.fileLocal['start'], '13.333334333');
    expect(media.fileLocal['end'], '30.000001000');
    final MusicResolvedMedia last = await resolveMusicMedia(
      musicPlayItemOf(tracks[2], album: album),
    );
    expect(last.fileLocal.containsKey('end'), isFalse);
    // 盘上相邻的后一首在同一个文件里接着播：终点取它的（末轨 = 盘尾）。
    final MusicPlayItem second = musicPlayItemOf(tracks[1], album: album);
    final MusicPlayItem third = musicPlayItemOf(tracks[2], album: album);
    expect(musicCddaContinues(second, third), isTrue);
    expect(
      musicCddaContinues(musicPlayItemOf(tracks[0], album: album), third),
      isFalse,
    );
    final MusicResolvedMedia through = await resolveMusicMedia(
      musicPlayItemOf(tracks[0], album: album),
      playThrough: second,
    );
    expect(through.fileLocal['start'], '0.000001000');
    expect(through.fileLocal['end'], '30.000001000');

    await service.import(
      info,
      device: 'F:',
      fallbackTitle: (int n) => 'No. $n',
      fallbackAlbumTitle: 'Audio CD',
    );
    final List<MusicTrackRow> again = sortAlbumTracks(
      await db.listMusicTracks(albumUid: albumUid),
    );
    expect(again.map((MusicTrackRow t) => t.title), <String>[
      'Intro',
      'No. 2',
      'No. 3',
    ]);
    expect(again.first.path, 'cdda://F:');
    expect((await db.listMusicDiscSources()).single.path, 'F:');
  });

  test('毫秒 → 盘时间：按 CD 扇区还原轨界，误差 ≤ 1 ms 的往返都落回同一扇区', () {
    for (final int frame in <int>[0, 1, 1000, 17446, 334000]) {
      final double exact = frame / kAudioCdFramesPerSecond;
      final int ms = (frame * 1000 / kAudioCdFramesPerSecond).round();
      for (final int err in <int>[-1, 0, 1]) {
        expect(musicCddaSeconds(ms + err), exact, reason: '$frame $err');
      }
    }
    expect(musicCddaDevice('cdda://E:'), 'E:');
    expect(musicCddaDevice('cdda:///dev/sr0'), '/dev/sr0');
  });

  test('不同盘符 / 不同光驱上的同一张盘不算相邻；CUE 文件不算', () {
    const MusicPlayItem a = MusicPlayItem(
      trackUid: 'a',
      path: 'cdda://E:',
      title: 'a',
      startMs: 0,
      endMs: 13333,
    );
    const MusicPlayItem b = MusicPlayItem(
      trackUid: 'b',
      path: 'cdda://E:',
      title: 'b',
      startMs: 13333,
      endMs: 30000,
    );
    expect(musicCddaContinues(a, b), isTrue);
    expect(
      musicCddaContinues(
        a,
        const MusicPlayItem(
          trackUid: 'b',
          path: 'cdda://F:',
          title: 'b',
          startMs: 13333,
        ),
      ),
      isFalse,
    );
    expect(musicCddaContinues(b, a), isFalse);
    expect(
      musicCddaContinues(
        const MusicPlayItem(
          trackUid: 'x',
          path: '/m/a.flac',
          title: 'x',
          startMs: 0,
          endMs: 1000,
        ),
        const MusicPlayItem(
          trackUid: 'y',
          path: '/m/a.flac',
          title: 'y',
          startMs: 1000,
        ),
      ),
      isFalse,
    );
  });

  test('播放前核对盘：同一张 / 换了盘 / 没盘 / 数据盘', () async {
    final String uid2 = musicCdTrackUid(_info.discId!, 2);
    Future<MusicCdDiscCheck> check(MusicCdDiscIdReader read) =>
        musicCdCheckDisc(
          device: 'E:',
          trackUid: uid2,
          trackNo: 2,
          readDiscId: read,
        );
    expect(await check((String d) async => _info.discId), MusicCdDiscCheck.ok);
    expect(
      await check((String d) async => 'some-other-disc-id-xxxxxxxxx-'),
      MusicCdDiscCheck.otherDisc,
    );
    expect(
      await check((String d) async => throw AudioCdReadException(d, 1)),
      MusicCdDiscCheck.noDisc,
    );
    expect(await check((String d) async => null), MusicCdDiscCheck.noDisc);
    // 轨号对不上（曲目行坏了）也不当成这张盘播。
    expect(
      await musicCdCheckDisc(
        device: 'E:',
        trackUid: uid2,
        trackNo: null,
        readDiscId: (String d) async => _info.discId,
      ),
      MusicCdDiscCheck.otherDisc,
    );
  });

  test('数据盘（没有音频轨）明确报错', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final MusicAudioCdService service = MusicAudioCdService(
      db,
      read: (String device) async => const AudioCdInfo(
        firstTrack: 1,
        lastTrack: 1,
        leadoutLba: 100,
        tracks: <AudioCdTrack>[
          AudioCdTrack(number: 1, isData: true, lba: 0, lengthFrames: 100),
        ],
        cdText: <AudioCdTextEntry>[],
      ),
    );
    await expectLater(
      service.read('E:'),
      throwsA(isA<MusicAudioCdNotAudioException>()),
    );
  });

  final String? drive = Platform.environment['FUSHI_TEST_CD_DRIVE'];
  test(
    '真盘：读光驱 → Disc ID 查 MusicBrainz → 入库',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final MusicAudioCdService service = MusicAudioCdService(db);
      expect(await service.listDrives(), contains(drive));
      final AudioCdInfo info = await service.read(drive!);
      final MusicBrainzProvider mb = MusicBrainzProvider();
      addTearDown(mb.close);
      final List<MusicReleaseTracklist> releases = await service.lookup(
        info,
        mb,
      );
      final String albumUid = await service.import(
        info,
        device: drive,
        release: releases.isEmpty ? null : releases.first,
        fallbackTitle: (int n) => 'Track $n',
        fallbackAlbumTitle: 'Audio CD',
      );
      final MusicAlbumRow album = (await db.getMusicAlbum(albumUid))!;
      final List<MusicTrackRow> tracks = sortAlbumTracks(
        await db.listMusicTracks(albumUid: albumUid),
      );
      expect(tracks, hasLength(info.audioTracks.length));
      // ignore: avoid_print
      print(
        'disc ${info.discId}: ${releases.length} release(s); album "${album.title}" '
        '${album.mbReleaseId}; tracks: ${tracks.map((MusicTrackRow t) => '${t.trackNo}. ${t.title} (${t.durationMs} ms)').join(' / ')}',
      );
    },
    skip: drive == null
        ? 'set FUSHI_TEST_CD_DRIVE with an audio CD in it'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
