import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show isLocalFrameExtractableVideoSource;
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_badges.dart'
    show isProbableStreamUrl;
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart'
    show isStreamVideoBook;
import 'package:fushi/src/media/video/url_stream_video.dart'
    show StreamVideoSpec;
import 'package:fushi/src/media/video/video_resource_check.dart'
    show videoResourceRequiresLocalCheck;

/// 浏览阶段 2b：在线视频源入库集的 `anime-source://` 标识、判据门与重开规格。
void main() {
  const String pkg = 'eu.kanade.tachiyomi.animeextension.all.fixture';

  group('isAnimeSourceVideoPath', () {
    test('recognises the scheme case-insensitively with leading blanks', () {
      expect(isAnimeSourceVideoPath('anime-source://p/1/Show - E01'), isTrue);
      expect(isAnimeSourceVideoPath('ANIME-SOURCE://p/1/x'), isTrue);
      expect(isAnimeSourceVideoPath('  \tanime-source://p/1/x'), isTrue);
      expect(isAnimeSourceVideoPath('anime-source://'), isTrue);
    });

    test('rejects null, empty, other schemes and look-alikes', () {
      expect(isAnimeSourceVideoPath(null), isFalse);
      expect(isAnimeSourceVideoPath(''), isFalse);
      expect(isAnimeSourceVideoPath('anime-source:'), isFalse);
      expect(isAnimeSourceVideoPath('anime-source:/p/1/x'), isFalse);
      expect(isAnimeSourceVideoPath('anime-sources://p'), isFalse);
      expect(isAnimeSourceVideoPath('https://anime-source://x'), isFalse);
      expect(isAnimeSourceVideoPath(r'D:\videos\anime-source\ep.mkv'), isFalse);
      expect(isAnimeSourceVideoPath('/videos/anime-source://x.mp4'), isFalse);
    });
  });

  group('animeSourceVideoPath', () {
    test('joins package / source / label under the scheme', () {
      final String path = animeSourceVideoPath(
        extensionPackage: pkg,
        sourceId: '42',
        label: 'Fixture Show - E03',
      );
      expect(path, 'anime-source://$pkg/42/Fixture Show - E03');
      expect(isAnimeSourceVideoPath(path), isTrue);
      expect(isNetworkOnlyVideoPath(path), isTrue);
    });

    test('illegal path characters in the label become underscores', () {
      final String path = animeSourceVideoPath(
        extensionPackage: pkg,
        sourceId: '42',
        label: 'Re:Zero / S2 * "OVA" <1>? |x|\\y\u0001',
      );
      expect(path, 'anime-source://$pkg/42/Re_Zero _ S2 _ _OVA_ _1__ _x__y_');
    });

    test('blank label falls back to a stable placeholder', () {
      expect(
        animeSourceVideoPath(extensionPackage: pkg, sourceId: '42', label: ''),
        'anime-source://$pkg/42/episode',
      );
      expect(
        animeSourceVideoPath(
          extensionPackage: pkg,
          sourceId: '42',
          label: '   ',
        ),
        'anime-source://$pkg/42/episode',
      );
    });
  });

  group('isNetworkOnlyVideoPath', () {
    test('http / https streams and anime-source rows are network-only', () {
      expect(isNetworkOnlyVideoPath('http://example.com/a.mp4'), isTrue);
      expect(isNetworkOnlyVideoPath('HTTPS://example.com/a.m3u8'), isTrue);
      expect(isNetworkOnlyVideoPath('  https://example.com/a'), isTrue);
      expect(isNetworkOnlyVideoPath('anime-source://p/1/x'), isTrue);
    });

    test('local paths, file uris and null are not', () {
      expect(isNetworkOnlyVideoPath(null), isFalse);
      expect(isNetworkOnlyVideoPath(''), isFalse);
      expect(isNetworkOnlyVideoPath(r'D:\videos\ep01.mkv'), isFalse);
      expect(isNetworkOnlyVideoPath('/home/u/ep01.mp4'), isFalse);
      expect(isNetworkOnlyVideoPath('file:///home/u/ep01.mp4'), isFalse);
      expect(isNetworkOnlyVideoPath('httpfoo/ep.mp4'), isFalse);
    });
  });

  group('gates treat anime-source rows as network-only', () {
    const String animePath = 'anime-source://$pkg/42/Fixture Show - E01';

    VideoBookRow row(String videoPath) => VideoBookRow(
      bookUid: 'anime-source:$pkg:42:/ep/1',
      title: 'Episode 1',
      videoPath: videoPath,
      lastPositionMs: 0,
      currentEpisode: 0,
      delayMs: 0,
      streamSpecJson: null,
    );

    test('isStreamVideoBook', () {
      expect(isStreamVideoBook(row(animePath)), isTrue);
      expect(isStreamVideoBook(row('ANIME-SOURCE://p/1/x')), isTrue);
      expect(isStreamVideoBook(row(r'D:\videos\ep01.mkv')), isFalse);
    });

    test('videoResourceRequiresLocalCheck', () {
      expect(videoResourceRequiresLocalCheck(animePath), isFalse);
      expect(videoResourceRequiresLocalCheck('  $animePath  '), isFalse);
      expect(videoResourceRequiresLocalCheck(r'D:\videos\ep01.mkv'), isTrue);
    });

    test('isProbableStreamUrl', () {
      expect(isProbableStreamUrl(animePath), isTrue);
      expect(isProbableStreamUrl('  $animePath'), isTrue);
      expect(isProbableStreamUrl(r'D:\videos\ep01.mkv'), isFalse);
    });

    test('isLocalFrameExtractableVideoSource', () {
      expect(isLocalFrameExtractableVideoSource(animePath), isFalse);
      expect(isLocalFrameExtractableVideoSource(' $animePath'), isFalse);
      expect(isLocalFrameExtractableVideoSource(r'D:\videos\ep01.mkv'), isTrue);
    });
  });

  group('AnimeSourceBookSpec', () {
    const MihonAnime anime = MihonAnime(
      url: '/anime/1',
      title: 'Fixture Show',
      coverUrl: 'https://site.example/cover.jpg',
      description: 'A show.',
      status: 2,
      initialized: true,
    );
    const MihonEpisode episode = MihonEpisode(
      url: '/ep/3',
      name: 'Episode 3',
      uploadedAt: 1700000000000,
      number: 3,
      scanlator: 'SubGroup',
    );
    const AnimeSourceBookSpec spec = AnimeSourceBookSpec(
      extensionPackage: pkg,
      sourceId: '42',
      anime: anime,
      episode: episode,
    );

    test('encode → tryParse round-trips every field', () {
      final String raw = spec.encode();
      expect(
        (jsonDecode(raw) as Map<String, Object?>)['kind'],
        AnimeSourceBookSpec.kind,
      );
      final AnimeSourceBookSpec parsed = AnimeSourceBookSpec.tryParse(raw)!;
      expect(parsed.extensionPackage, pkg);
      expect(parsed.sourceId, '42');
      expect(parsed.anime.toJson(), anime.toJson());
      expect(parsed.episode.toJson(), episode.toJson());
      expect(parsed.sameWorkAs(spec), isTrue);
    });

    test('sameWorkAs compares extension, source and anime url only', () {
      const AnimeSourceBookSpec otherEpisode = AnimeSourceBookSpec(
        extensionPackage: pkg,
        sourceId: '42',
        anime: MihonAnime(url: '/anime/1', title: 'Renamed'),
        episode: MihonEpisode(
          url: '/ep/9',
          name: 'x',
          uploadedAt: 0,
          number: 9,
        ),
      );
      expect(spec.sameWorkAs(otherEpisode), isTrue);
      const AnimeSourceBookSpec otherSource = AnimeSourceBookSpec(
        extensionPackage: pkg,
        sourceId: '43',
        anime: anime,
        episode: episode,
      );
      expect(spec.sameWorkAs(otherSource), isFalse);
      const AnimeSourceBookSpec otherPackage = AnimeSourceBookSpec(
        extensionPackage: 'other.pkg',
        sourceId: '42',
        anime: anime,
        episode: episode,
      );
      expect(spec.sameWorkAs(otherPackage), isFalse);
      const AnimeSourceBookSpec otherAnime = AnimeSourceBookSpec(
        extensionPackage: pkg,
        sourceId: '42',
        anime: MihonAnime(url: '/anime/2', title: 'Fixture Show'),
        episode: episode,
      );
      expect(spec.sameWorkAs(otherAnime), isFalse);
    });

    test('tryParse returns null for garbage, other kinds and '
        'StreamVideoSpec JSON', () {
      expect(AnimeSourceBookSpec.tryParse(null), isNull);
      expect(AnimeSourceBookSpec.tryParse(''), isNull);
      expect(AnimeSourceBookSpec.tryParse('not json'), isNull);
      expect(AnimeSourceBookSpec.tryParse('{"kind":'), isNull);
      expect(AnimeSourceBookSpec.tryParse('[]'), isNull);
      expect(AnimeSourceBookSpec.tryParse('42'), isNull);
      expect(AnimeSourceBookSpec.tryParse('null'), isNull);
      expect(AnimeSourceBookSpec.tryParse('{"kind":"other"}'), isNull);
      // 直链流 spec 与本 spec 同列共存：互不误认。
      final String streamSpec = const StreamVideoSpec(
        subtitleUrl: 'https://cdn.example/a.vtt',
        referer: 'https://site.example/',
      ).toStorageJson()!;
      expect(AnimeSourceBookSpec.tryParse(streamSpec), isNull);
      expect(StreamVideoSpec.fromStorageJson(spec.encode()).isEmpty, isTrue);
      // 缺字段 / 字段形状不对。
      final Map<String, Object?> full =
          jsonDecode(spec.encode()) as Map<String, Object?>;
      expect(
        AnimeSourceBookSpec.tryParse(
          jsonEncode(<String, Object?>{...full}..remove('anime')),
        ),
        isNull,
      );
      expect(
        AnimeSourceBookSpec.tryParse(
          jsonEncode(<String, Object?>{...full, 'episode': 'x'}),
        ),
        isNull,
      );
      expect(
        AnimeSourceBookSpec.tryParse(
          jsonEncode(<String, Object?>{...full, 'extensionPackage': ''}),
        ),
        isNull,
      );
    });

    test('tryParse never throws on type-mismatched nested fields', () {
      // 「解析失败返回 null，绝不抛」：嵌套字段类型错（坏数据 / 手改）也不能炸重开。
      final Map<String, Object?> full =
          jsonDecode(spec.encode()) as Map<String, Object?>;
      final String badStatus = jsonEncode(<String, Object?>{
        ...full,
        'anime': <String, Object?>{
          ...(full['anime']! as Map<String, Object?>),
          'status': 'ongoing',
        },
      });
      final String badNumber = jsonEncode(<String, Object?>{
        ...full,
        'episode': <String, Object?>{
          ...(full['episode']! as Map<String, Object?>),
          'episode_number': 'three',
        },
      });
      expect(() => AnimeSourceBookSpec.tryParse(badStatus), returnsNormally);
      expect(AnimeSourceBookSpec.tryParse(badStatus), isNull);
      expect(() => AnimeSourceBookSpec.tryParse(badNumber), returnsNormally);
      expect(AnimeSourceBookSpec.tryParse(badNumber), isNull);
    });
  });

  group('animeSourceEpisodeLabel', () {
    const MihonAnime anime = MihonAnime(url: '/a', title: 'Show');

    MihonEpisode ep(double number, [String name = 'Special']) =>
        MihonEpisode(url: '/e', name: name, uploadedAt: 0, number: number);

    test('integral numbers are zero-padded to two digits', () {
      expect(animeSourceEpisodeLabel(anime, ep(3)), 'Show - E03');
      expect(animeSourceEpisodeLabel(anime, ep(12)), 'Show - E12');
      expect(animeSourceEpisodeLabel(anime, ep(123)), 'Show - E123');
    });

    test('fractional numbers keep the fraction', () {
      expect(animeSourceEpisodeLabel(anime, ep(2.5)), 'Show - E2.5');
    });

    test('no number falls back to the episode name', () {
      expect(animeSourceEpisodeLabel(anime, ep(0, 'OVA')), 'Show - OVA');
      expect(animeSourceEpisodeLabel(anime, ep(-1, 'PV')), 'Show - PV');
    });
  });
}
