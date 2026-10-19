// 媒体名 / 字幕时序 / Fribb 原生解析（ffc_parse_filename_* / ffc_parse_subtiming_* /
// ffc_parse_fribb_*）的 FFI 契约测试：批量接口的记录布局、空批量、孤立代理往返、
// 错误种类。规则本身的逐条一致性由 fushi_engine 的
// test/media/video/native_media_parse_vectors_test.dart 用旧 Dart 实现冻结的摘要钉死。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

const List<String> _exts = <String>['.mkv', '.mp4'];

void main() {
  setUpAll(() {
    expect(
      () => MediaNameNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  group('MediaNameNative', () {
    test('empty batch returns empty list', () {
      expect(
        MediaNameNative.instance.parseNames(
          const <String>[],
          extensions: _exts,
          currentYear: 2026,
        ),
        isEmpty,
      );
      expect(
        MediaNameNative.instance.trailingSeasons(const <String>[]),
        isEmpty,
      );
    });

    test('batch records map one-to-one with all fields', () {
      final List<FfcParsedName> r = MediaNameNative.instance.parseNames(
        <String>[
          '[Lilith-Raws] Sousou no Frieren - 05 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4].mp4',
          '',
          'Death Race 2000.mkv',
          '[组] 剧场版 某作品 ～副标题～ (2019).mkv',
        ],
        extensions: _exts,
        currentYear: 2026,
      );
      expect(r.map((FfcParsedName e) => e.inputIndex), <int>[0, 1, 2, 3]);
      expect(r[0].title, 'Sousou no Frieren');
      expect(r[0].episode, 5);
      expect(r[0].releaseGroup, 'Lilith-Raws');
      expect(r[0].resolution, '1080p');
      expect(r[0].season, isNull);
      expect(r[1].title, '');
      expect(r[1].episode, isNull);
      expect(r[2].title, 'Death Race');
      expect(r[2].year, 2000);
      expect(r[2].titleWithTrailingYear, 'Death Race 2000');
      expect(r[3].isMovieHint, isTrue);
      expect(r[3].year, 2019);
      expect(r[3].secondaryTitle, '副标题');
    });

    test('current year is an input: a bare year after next year is title', () {
      List<int?> years(int now) => MediaNameNative.instance
          .parseNames(
            <String>['Frieren 2028'],
            extensions: _exts,
            currentYear: now,
          )
          .map((FfcParsedName e) => e.year)
          .toList();
      expect(years(2026), <int?>[null]);
      expect(years(2027), <int?>[2028]);
    });

    test('lone surrogates and astral chars round-trip through the pool', () {
      const String name = 'A\uD800B \u{1F600} \uDC00C - 03';
      final FfcParsedName r = MediaNameNative.instance
          .parseNames(<String>[name], extensions: _exts, currentYear: 2026)
          .single;
      expect(r.title.codeUnits, 'A\uD800B \u{1F600} \uDC00C'.codeUnits);
      expect(r.episode, 3);
    });

    test('candidates carry the path index and keep dir-then-file order', () {
      final List<FfcParsedName> r = MediaNameNative.instance.candidatesForPaths(
        <String>[
          'D:/Anime/Frieren/[ANi] Frieren - 01.mkv',
          'Downloads/VID_20260701.mp4',
          r'C:\x\Yuru Camp 2\03.mkv',
        ],
        extensions: _exts,
        currentYear: 2026,
      );
      expect(
        r.map((FfcParsedName e) => '${e.inputIndex}:${e.title}:${e.episode}'),
        <String>['0:Frieren:null', '0:Frieren:1', '2:Yuru Camp 2:null', '2::3'],
      );
    });

    test('trailing season gives the title range inside the input', () {
      final List<FfcTrailingSeason?> r = MediaNameNative.instance
          .trailingSeasons(<String>[
            '  Hibike! Euphonium 2 ',
            'Mob Psycho 100',
            '2',
          ]);
      expect(r[0]?.season, 2);
      expect(
        '  Hibike! Euphonium 2 '.substring(r[0]!.titleStart, r[0]!.titleEnd),
        'Hibike! Euphonium',
      );
      expect(r[1], isNull);
      expect(r[2], isNull);
    });
  });

  group('SubtitleTimingNative', () {
    test('srt, vtt, ass and empty', () {
      final SubtitleTimingNative n = SubtitleTimingNative.instance;
      expect(
        n.summarize(
          '1\n00:00:01,000 --> 00:00:02,500\nhi\n\n2\n00:01:00,000 --> 00:01:03,000\n',
        ),
        (cueCount: 2, firstStartMs: 1000, lastEndMs: 63000),
      );
      expect(
        n.summarize('Dialogue: 0,0:01:02.34,0:01:05.67,Default,,0,0,0,,x'),
        (cueCount: 1, firstStartMs: 62340, lastEndMs: 65670),
      );
      expect(n.summarize(''), (cueCount: 0, firstStartMs: 0, lastEndMs: 0));
    });
  });

  group('FribbNative', () {
    Uint8List bytes(String s) => utf8.encode(s);

    test('merges rows and keeps first-appearance order', () {
      final List<FfcFribbEntry> e = FribbNative.instance.parseEntries(
        bytes(
          '[{"anidb_id": 9, "mal_id": 2, "themoviedb_id": {"movie": [0, "7"]}, "type": " MOVIE "},'
          '{"anidb_id": 3, "mal_id": 1, "themoviedb_id": {"tv": 5}, "season": {"tmdb": 0}},'
          '{"anidb_id": "9", "mal_id": 4, "tvdb_id": 8}]',
        ),
      );
      expect(e.map((FfcFribbEntry x) => x.anidbId), <int>[9, 3]);
      expect(e[0].malIds, <int>[2, 4]);
      expect(e[0].tmdbId, 7);
      expect(e[0].tmdbIsMovieNamespace, isTrue);
      expect(e[0].type, 'MOVIE');
      expect(e[0].tvdbId, 8);
      expect(e[1].tmdbSeason, 0);
      expect(e[1].tmdbIsMovieNamespace, isFalse);
      expect(e[1].type, isNull);
    });

    test('error kinds', () {
      expect(
        () => FribbNative.instance.parseEntries(bytes('[1,]')),
        throwsA(isA<FfcFribbInvalidJson>()),
      );
      expect(
        () => FribbNative.instance.parseEntries(bytes('{"a": 1}')),
        throwsA(isA<FfcFribbNotAList>()),
      );
      expect(
        () => FribbNative.instance.parseEntries(Uint8List(0)),
        throwsA(isA<FfcFribbInvalidJson>()),
      );
      expect(FribbNative.instance.parseEntries(bytes('[]')), isEmpty);
    });
  });
}
