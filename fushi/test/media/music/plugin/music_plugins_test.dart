import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 插件曲目的播放身份 / 路径 / 音质换算，与歌词服务里「插件自带歌词」这一档（真 Rust 解析器）。
const String _yrc =
    '{"t":0,"c":[{"tx":"作词: "},{"tx":"Ayase"}]}\n'
    '[1000,2000](1000,500,0)夜(1500,500,0)に(2000,1000,0)駆ける\n'
    '[4000,2000](4000,1000,0)沈(5000,1000,0)む';
const String _translation =
    '[00:01.00]奔向夜晚\n'
    '[00:04.00]沉没';

Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

void main() {
  group('播放路径与身份', () {
    test('路径往返：曲目 id 里的特殊字符原样保留', () {
      for (final String id in <String>['1409311773', 'a/b?c#d', '夜 曲']) {
        final String path = musicPluginTrackPath('moe.example.music', id);
        expect(path, startsWith('fushi-music-plugin://moe.example.music/'));
        expect(parseMusicPluginTrackPath(path), (
          pluginId: 'moe.example.music',
          trackId: id,
        ));
        expect(isMusicPluginPath(path), isTrue);
      }
      expect(parseMusicPluginTrackPath('C:/music/a.flac'), isNull);
      expect(parseMusicPluginTrackPath('https://x/y'), isNull);
    });

    test('uid 稳定、按插件区分、与服务器曲目命名空间不同', () {
      final String a = musicPluginTrackUid('p1', '1');
      expect(a, musicPluginTrackUid('p1', '1'));
      expect(a, isNot(musicPluginTrackUid('p2', '1')));
      expect(a, startsWith('plg'));
      expect(a.length, 3 + 30);
    });

    test('码率上限 → 插件音质档', () {
      expect(musicPluginQualityForBitrate(0), MusicPluginQuality.lossless);
      expect(musicPluginQualityForBitrate(320), MusicPluginQuality.high);
      expect(musicPluginQualityForBitrate(192), MusicPluginQuality.standard);
      expect(musicPluginQualityForBitrate(128), MusicPluginQuality.standard);
    });

    test('播放项带上元数据；专辑标题 / 封面缺省时用调用方给的', () {
      const MusicPluginTrack track = MusicPluginTrack(
        id: '7',
        title: '夜に駆ける',
        artists: <MusicPluginArtistRef>[
          MusicPluginArtistRef(name: 'YOASOBI'),
          MusicPluginArtistRef(name: 'Ayase'),
        ],
        albumId: '84072830',
        durationMs: 261013,
      );
      final item = musicPluginPlayItem(
        'moe.example.music',
        track,
        albumTitle: 'THE BOOK',
        coverUrl: 'https://p1.img.example-music.com/c.jpg',
      );
      expect(item.path, musicPluginTrackPath('moe.example.music', '7'));
      expect(item.artist, 'YOASOBI / Ayase');
      expect(item.album, 'THE BOOK');
      expect(item.coverPath, 'https://p1.img.example-music.com/c.jpg');
      expect(
        item.albumUid,
        musicPluginAlbumUid('moe.example.music', '84072830'),
      );
    });

    test('没装配插件宿主时取流按不可播放处理', () async {
      musicPluginPlaybackHost = null;
      await expectLater(
        resolveMusicPluginStream(musicPluginTrackPath('p', '1')),
        throwsA(isA<MusicPluginStreamUnavailable>()),
      );
    });
  });

  group('插件自带歌词', () {
    late FushiDatabase db;
    late int now;
    late int fetches;
    MusicPluginLyrics? reply;
    MusicPluginException? fail;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      now = 1000000;
      fetches = 0;
      reply = null;
      fail = null;
    });
    tearDown(() => db.close());

    MusicLyricsService service() => MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
      onlineEnabled: () => false,
      parse: _parse,
      now: () => now,
      pluginLyrics: (String pluginId, String trackId) async {
        expect((pluginId, trackId), ('moe.example.music', '7'));
        fetches++;
        if (fail != null) throw fail!;
        return reply;
      },
    );

    MusicLyricsTrackRef track() => MusicLyricsTrackRef(
      trackUid: musicPluginTrackUid('moe.example.music', '7'),
      path: musicPluginTrackPath('moe.example.music', '7'),
      title: '夜に駆ける',
      artist: 'YOASOBI',
      durationMs: 261000,
    );

    test('逐字 YRC + 译文合并、落库存 TTML、之后走缓存', () async {
      reply = const MusicPluginLyrics(
        original: MusicPluginLyricText(format: 'yrc', text: _yrc),
        translation: MusicPluginLyricText(
          format: 'lrc',
          text: _translation,
          language: 'zh-Hans',
        ),
      );
      final MusicLyricsResolution r = (await service().resolve(track()))!;
      expect(r.source, MusicLyricsSource.plugin('moe.example.music'));
      expect(r.timeline.timingQuality, LyricTimingQuality.syllable);
      final List<LyricLine> sung = r.timeline.lines
          .where((LyricLine l) => l.startMs >= 1000)
          .toList();
      expect(sung.first.text, '夜に駆ける');
      expect(sung.first.translations.single.text, '奔向夜晚');
      expect(sung.first.translations.single.lang, 'zh-Hans');
      final MusicLyricRow row =
          await (db.select(db.musicLyrics)..where(
                ($MusicLyricsTable t) => t.source.like('provider:plugin:%'),
              ))
              .getSingle();
      expect(row.format, 'ttml');
      // 第二次直接走缓存，不再问插件。
      await service().resolve(track());
      expect(fetches, 1);
    });

    test('YRC 与译文时间轴整体错开 1.5 s：译文仍是原文副行、不成独立行', () async {
      // 按真实数据的时间轴改写（文字换成占位）：翻译轴跟着旧行级 lrc 打时间，比逐字轴晚约 1.5 s。
      const String yrc =
          '[11380,3030](11380,450,0)w1 (11830,270,0)w2 (12100,690,0)w3 '
          '(12790,270,0)w4 (13060,390,0)w5 (13450,960,0)w6\n'
          '[14680,2310](14680,510,0)w7 (15190,210,0)w8 (15400,600,0)w9 '
          '(16000,990,0)w10\n'
          '[17350,3720](17350,600,0)w11 (17950,60,0)w12 (18010,360,0)w13 '
          '(18370,600,0)w14 (18970,420,0)w15 (19390,420,0)w16 (19810,1260,0)w17\n'
          '[22000,3180](22000,450,0)w18 (22450,240,0)w19 (22690,420,0)w20 '
          '(23110,300,0)w21 (23410,300,0)w22 (23710,450,0)w23 (24160,1020,0)w24';
      const String translation =
          '[by:x]\n\n'
          '[00:12.86]译文一\n'
          '[00:16.17]译文二\n'
          '[00:18.85]译文三\n'
          '[00:23.45]译文四';
      reply = const MusicPluginLyrics(
        original: MusicPluginLyricText(format: 'yrc', text: yrc),
        translation: MusicPluginLyricText(
          format: 'lrc',
          text: translation,
          language: 'zh-Hans',
        ),
      );
      final MusicLyricsResolution r = (await service().resolve(track()))!;
      expect(r.timeline.lines.map((LyricLine l) => l.text).toList(), <String>[
        'w1 w2 w3 w4 w5 w6',
        'w7 w8 w9 w10',
        'w11 w12 w13 w14 w15 w16 w17',
        'w18 w19 w20 w21 w22 w23 w24',
      ]);
      expect(
        r.timeline.lines
            .map((LyricLine l) => l.translations.single.text)
            .toList(),
        <String>['译文一', '译文二', '译文三', '译文四'],
      );
    });

    test('旧解析器合并的缓存：回插件重取并重新合并；取不到时先用旧的、下次再问', () async {
      // 旧版合并把对不上的译文插成了独立行，落库的是这份派生 TTML。
      final LyricTimeline badMerge = FushiLyrics.parse(
        utf8.encode('[00:01.00]夜に駆ける\n[00:01.80]奔向夜晚'),
        hint: 'lrc',
      );
      await db
          .into(db.musicLyrics)
          .insert(
            MusicLyricsCompanion.insert(
              trackUid: track().trackUid,
              source: MusicLyricsSource.plugin('moe.example.music'),
              format: 'ttml',
              raw: FushiLyrics.export(badMerge, 'ttml'),
              timelineVersion: Value<int>(FushiLyrics.parserVersion - 1),
              offsetMs: const Value<int>(120),
              updatedAt: now,
            ),
          );
      fail = const MusicPluginException('离线');
      final MusicLyricsResolution stale = (await service().resolve(track()))!;
      expect(stale.timeline.lines.length, 2, reason: '取不到时旧结果顶上');
      expect(fetches, 1);

      fail = null;
      reply = const MusicPluginLyrics(
        original: MusicPluginLyricText(format: 'yrc', text: _yrc),
        translation: MusicPluginLyricText(
          format: 'lrc',
          text: _translation,
          language: 'zh-Hans',
        ),
      );
      final MusicLyricsResolution fresh = (await service().resolve(track()))!;
      expect(fetches, 2, reason: '上次没取到不回写版本，这次再问');
      expect(fresh.timeline.offsetMs, 120, reason: '保留用户调过的偏移');
      final LyricLine first = fresh.timeline.lines.firstWhere(
        (LyricLine l) => l.text == '夜に駆ける',
      );
      expect(first.translations.single.text, '奔向夜晚');
      expect(
        fresh.timeline.lines.where((LyricLine l) => l.text == '奔向夜晚'),
        isEmpty,
      );
      await service().resolve(track());
      expect(fetches, 2, reason: '新版本合并结果之后走缓存');
    });

    test('插件说没有：负缓存一天；插件报错：不写负缓存', () async {
      expect(await service().resolve(track()), isNull);
      expect(await service().resolve(track()), isNull);
      expect(fetches, 1, reason: '负缓存期内不再问');
      now += kPluginLyricsNegativeCacheTtl.inMilliseconds;
      fail = const MusicPluginException('风控');
      expect(await service().resolve(track()), isNull);
      expect(await service().resolve(track()), isNull);
      expect(fetches, 3, reason: '报错不算「没有」，下次还问');
    });
  });
}
