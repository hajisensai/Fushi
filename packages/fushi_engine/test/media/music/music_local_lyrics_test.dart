// 本地歌词层与封面选取搬进引擎（BUG-5300）：app 本机播放与互联 host 共用同一份规则。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/host/engine_music_library_host.dart';
import 'package:fushi_engine/media/music/lyrics/music_local_lyrics.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_engine/media/music/music_cover_source.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

EmbeddedLyrics _emb(String key, LyricTimingQuality q, String text) =>
    EmbeddedLyrics(
      key: key,
      format: 'lrc',
      raw: Uint8List.fromList(utf8.encode(text)),
      timeline: LyricTimeline(
        format: 'lrc',
        timingQuality: q,
        lines: const <LyricLine>[
          LyricLine(startMs: 0, endMs: 1000, syllables: <LyricSyllable>[]),
        ],
      ),
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('music_local_lyr_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('MusicLocalLyrics', () {
    test('同名 sidecar + 翻译；排除的文件不算，退回下一档', () async {
      final String audio = '${tmp.path}/Song.flac';
      File(audio).writeAsBytesSync(<int>[0]);
      File('${tmp.path}/Song.ja.srt').writeAsStringSync('1');
      File('${tmp.path}/Song.lrc').writeAsStringSync('[00:01.00]a');
      final MusicLocalLyrics local = MusicLocalLyrics();
      final LyricSidecarSet all = await local.sidecars(audio);
      expect(all.primary!.path, endsWith('Song.lrc'));
      final LyricSidecarSet noLrc = await local.sidecars(
        audio,
        exclude: (String p) async => p.endsWith('.lrc'),
      );
      expect(noLrc.primary?.path, isNot(endsWith('Song.lrc')));
    });

    test('没有同名文件时认头部指向这首的 UltraStar .txt', () async {
      final String audio = '${tmp.path}/track01.mp3';
      File(audio).writeAsBytesSync(<int>[0]);
      File(
        '${tmp.path}/Other - Song.txt',
      ).writeAsStringSync('#TITLE:x\n#BPM:120\n#MP3:other.mp3\n');
      File('${tmp.path}/Artist - Song.txt').writeAsStringSync(
        '#TITLE:Song\n#BPM:120\n#MP3:Track01.mp3\n: 0 1 0 a\n',
      );
      final LyricSidecarSet set = await MusicLocalLyrics().sidecars(audio);
      expect(set.primary!.ext, 'ultrastar');
      expect(set.primary!.path, endsWith('Artist - Song.txt'));
    });

    test('内嵌：取时间轴最细的一条；读不了为 null', () async {
      final MusicLocalLyrics local = MusicLocalLyrics(
        readEmbedded: (String p, int? d) async => p.endsWith('bad')
            ? throw const LyricsParseException('x')
            : <EmbeddedLyrics>[
                _emb('unsyncedlyrics', LyricTimingQuality.line, 'line'),
                _emb('sylt', LyricTimingQuality.syllable, 'syl'),
              ],
      );
      expect((await local.bestEmbedded('/a.flac'))!.key, 'sylt');
      expect(await local.bestEmbedded('/bad'), isNull);
    });
  });

  group('封面选取', () {
    test('目录封面优先；专辑选定的内嵌封面曲目其次；最后这首自己', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await db
          .into(db.musicTracks)
          .insert(
            MusicTracksCompanion.insert(
              trackUid: 'c',
              path: '/m/c.flac',
              title: 'c',
              fileMtimeAt: 1,
              fileSize: 1,
              addedAt: 1,
              hasEmbeddedCover: const Value<bool>(true),
            ),
          );
      await db
          .into(db.musicAlbums)
          .insert(
            MusicAlbumsCompanion.insert(
              albumUid: 'a',
              title: 'A',
              coverTrackUid: const Value<String?>('c'),
              addedAt: 1,
              updatedAt: 1,
            ),
          );
      final MusicAlbumRow album = (await db.getMusicAlbum('a'))!;
      final MusicTrackRow self = await _self(db);
      expect(await loadMusicCoverSource(db, track: self, album: album), (
        coverPath: null,
        embeddedFromPath: '/m/c.flac',
      ));
      expect(
        musicCoverSourceOf(
          track: self,
          album: album.copyWith(
            coverPath: const Value<String?>('/m/cover.jpg'),
          ),
        ),
        (coverPath: '/m/cover.jpg', embeddedFromPath: '/m/self.flac'),
      );
      expect(musicCoverSourceOf(track: self), (
        coverPath: null,
        embeddedFromPath: '/m/self.flac',
      ));
      expect(
        musicCoverSourceOf(
          album: album.copyWith(coverPath: const Value<String?>('')),
        ),
        (coverPath: null, embeddedFromPath: null),
      );
    });
  });

  test('host 歌词：库里没有行、没有 sidecar 时给文件内嵌那份（与本机同一层）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String audio = '${tmp.path}/Song.flac';
    File(audio).writeAsBytesSync(<int>[0]);
    await db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: 't',
            path: audio,
            title: 'Song',
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    final EngineMusicLibraryHost host = EngineMusicLibraryHost(
      database: () => db,
      cddaSupported: false,
      localLyrics: MusicLocalLyrics(
        readEmbedded: (String p, int? d) async => <EmbeddedLyrics>[
          _emb('lyrics', LyricTimingQuality.line, '[00:01.00]emb'),
        ],
      ),
    );
    final RemoteMusicLyrics l = (await host.lyrics('t'))!;
    expect(l.source, MusicLyricsSource.embedded);
    expect(utf8.decode(l.raw), '[00:01.00]emb');
    // 有了 sidecar 就用 sidecar。
    File('${tmp.path}/Song.lrc').writeAsStringSync('[00:02.00]side');
    final RemoteMusicLyrics s = (await host.lyrics('t'))!;
    expect(s.source, MusicLyricsSource.sidecar);
  });
}

Future<MusicTrackRow> _self(FushiDatabase db) async {
  await db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: 'self',
          path: '/m/self.flac',
          title: 'self',
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
          albumUid: const Value<String?>('a'),
          hasEmbeddedCover: const Value<bool>(true),
        ),
      );
  return (await db.getMusicTrack('self'))!;
}
