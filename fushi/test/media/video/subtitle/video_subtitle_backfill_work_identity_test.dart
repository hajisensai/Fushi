import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// BUG-3068 / BUG-3069：刮削后自动补字幕把别的作品、别的语言的字幕装到了用户的
/// 哆啦A梦剧场版旁边。这里用**真实 provider 实现**（Jimaku / AJATT / OpenSubtitles
/// 各自的客户端 + MockClient 桩出线上响应形状）走完整的补字幕服务，候选全部取自
/// 用户库里实际被装上的文件名。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-backfill-work-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<SubtitleBackfillTarget> movieTarget(
    String title,
    int year, {
    int? tmdbId,
    int? anilistId,
    String? originalLanguage,
  }) async {
    final File video = File(p.join(root.path, '$title ($year).mkv'));
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    return SubtitleBackfillTarget(
      bookUid: 'book-$year',
      videoPath: video.path,
      originalLanguage: originalLanguage,
      media: VideoMediaReference(
        providerId: 'anidb',
        mediaId: '$year',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: title,
        year: year,
        tmdbId: tmdbId,
        anilistId: anilistId,
      ),
    );
  }

  List<String> sidecarsNextTo(SubtitleBackfillTarget target) => <String>[
    for (final FileSystemEntity e in root.listSync())
      if (e is File && !e.path.endsWith('.mkv')) p.basename(e.path),
  ];

  group('BUG-3068 不是这部作品的字幕一律不装', () {
    final List<
      ({
        String name,
        String title,
        int year,
        Map<String, Object?> entry,
        String file,
      })
    >
    jimakuCases =
        <
          ({
            String name,
            String title,
            int year,
            Map<String, Object?> entry,
            String file,
          })
        >[
          (
            name: '① 1986 鉄人兵団 ← 2011 重制版「新・…はばたけ天使たち」',
            title: '映画ドラえもん のび太と鉄人兵団',
            year: 1986,
            entry: <String, Object?>{
              'id': 6101,
              'name':
                  'Doraemon: Shin Nobita to Tetsujin Heidan - Habatake Tenshi-tachi',
              'japanese_name': '映画ドラえもん 新・のび太と鉄人兵団 ～はばたけ 天使たち～',
              'flags': <String, Object?>{'anime': true},
            },
            file: '映画ドラえもん.新・のび太と鉄人兵団.はばたけ.天使たち.WEBRip.Netflix.ja[cc].srt',
          ),
          (
            name: '② 1985 宇宙小戦争 ← 2022 重制版（发布名带 2021）',
            title: '映画ドラえもん のび太の宇宙小戦争',
            year: 1985,
            entry: <String, Object?>{
              'id': 6102,
              'name': 'Doraemon: Nobita no Little Star Wars 2021',
              'japanese_name': '映画ドラえもん のび太の宇宙小戦争 2021',
              'flags': <String, Object?>{'anime': true, 'movie': true},
            },
            file: '映画ドラえもん.のび太の宇宙小戦争.2021.WEBRip.Netflix.ja[cc].srt',
          ),
          (
            name: '③ 1989 日本誕生 ← 2016 重制版「新・」',
            title: '映画ドラえもん のび太の日本誕生',
            year: 1989,
            entry: <String, Object?>{
              'id': 6103,
              'name': 'Doraemon: Shin Nobita no Nippon Tanjou',
              'japanese_name': '映画ドラえもん 新・のび太の日本誕生',
              'flags': <String, Object?>{'anime': true},
            },
            file: '映画ドラえもん.新・のび太の日本誕生.WEBRip.Netflix.ja[cc].srt',
          ),
        ];
    for (final c in jimakuCases) {
      test('Jimaku ${c.name}', () async {
        final _Jimaku jimaku = _Jimaku(
          entries: <Map<String, Object?>>[c.entry],
          files: <int, List<String>>{
            c.entry['id']! as int: <String>[c.file],
          },
        );
        final SubtitleBackfillTarget target = await movieTarget(
          c.title,
          c.year,
        );
        final SubtitleBackfillResult result = await _service(
          <VideoSubtitleProvider>[jimaku.provider],
        ).backfill(target);
        expect(jimaku.searchCalls, greaterThan(0), reason: '确实搜到了这条候选');
        expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
        expect(jimaku.downloads, isEmpty, reason: '错作品在下载之前就该被拒');
        expect(sidecarsNextTo(target), isEmpty);
      });
    }

    test('Jimaku：目标带 AniList id、条目是另一部的 id → 按 id 拒', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[
          <String, Object?>{...jimakuCases.first.entry, 'anilist_id': 9002},
        ],
        files: <int, List<String>>{
          6101: <String>['Doraemon.Movie.ja.srt'],
        },
      );
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太と鉄人兵団',
        1986,
        anilistId: 2471,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
      ).backfill(target);
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(result.detail, contains('ids differ'));
      expect(sidecarsNextTo(target), isEmpty);
    });

    test('AJATT ④ 2006 恐竜2006 ← 1980 版「のび太の恐竜」', () async {
      final _Ajatt ajatt = _Ajatt();
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太の恐竜2006',
        2006,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[ajatt.provider],
      ).backfill(target);
      expect(
        ajatt.listedPages,
        contains('anime_movie/doraemon-nobita-no-kyouryuu.html'),
        reason: '目录模糊匹配确实把 1980 版带进来了',
      );
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(ajatt.downloads, isEmpty);
      expect(sidecarsNextTo(target), isEmpty);
    });

    test('AJATT ⑤ 1997 ねじ巻き都市冒険記 ← TV 系列 Doraemon (2005) 的一集', () async {
      final _Ajatt ajatt = _Ajatt();
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太のねじ巻き都市冒険記',
        1997,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[ajatt.provider],
      ).backfill(target);
      expect(ajatt.listedPages, contains('anime_tv/doraemon-(2005).html'));
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(ajatt.downloads, isEmpty);
      expect(sidecarsNextTo(target), isEmpty);
    });

    test('OpenSubtitles ⑥ 1999 宇宙漂流記 ← Pinky and the Brain S03E25', () async {
      final _OpenSubtitles os = _OpenSubtitles(<Map<String, Object?>>[
        _pinkyAndTheBrain,
      ]);
      // 不给语言偏好：证明光靠作品身份就拒得掉，不是碰巧被语言挡住。
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太の宇宙漂流記',
        1999,
        tmdbId: 44251,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[os.client],
      ).backfill(target);
      expect(os.searchCalls, greaterThan(0));
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(os.downloadCalls, 0, reason: '配额不该花在错作品上');
      expect(sidecarsNextTo(target), isEmpty);
    });

    test('对照：1992 雲の王国 ← 同名 Netflix 文件，照常装上', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[
          <String, Object?>{
            'id': 6200,
            'name': 'Doraemon: Nobita to Kumo no Oukoku',
            'japanese_name': '映画ドラえもん のび太と雲の王国',
            'flags': <String, Object?>{'anime': true},
          },
        ],
        files: <int, List<String>>{
          6200: <String>['映画ドラえもん.のび太と雲の王国.WEBRip.Netflix.ja[cc].srt'],
        },
      );
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太と雲の王国',
        1992,
        originalLanguage: 'ja',
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
      ).backfill(target);
      expect(result.outcome, SubtitleBackfillOutcome.installed);
      expect(result.language, 'ja');
      expect(sidecarsNextTo(target), <String>[
        '映画ドラえもん のび太と雲の王国 (1992).ja.srt',
      ]);
    });
  });

  group('BUG-3069 原语言（ja）字幕之外一律不装', () {
    for (final ({int year, String title, String language}) c
        in <({int year, String title, String language})>[
          (year: 1991, title: '映画ドラえもん のび太のドラビアンナイト', language: 'id'),
          (year: 1990, title: '映画ドラえもん のび太とアニマル惑星', language: 'fr'),
          (year: 1983, title: '映画ドラえもん のび太の海底鬼岩城', language: 'fr'),
        ]) {
      test('${c.year} ← OpenSubtitles ${c.language}（作品身份完全正确）', () async {
        final _OpenSubtitles os = _OpenSubtitles(<Map<String, Object?>>[
          _feature(
            fileId: 900000 + c.year,
            fileName: 'Doraemon.Movie.${c.year}.DVDRip.${c.language}.srt',
            language: c.language,
            tmdbId: 100000 + c.year,
            year: c.year,
          ),
        ]);
        final SubtitleBackfillTarget target = await movieTarget(
          c.title,
          c.year,
          tmdbId: 100000 + c.year,
          originalLanguage: 'ja',
        );
        final SubtitleBackfillResult result = await _service(
          <VideoSubtitleProvider>[os.client],
        ).backfill(target);
        expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
        expect(result.detail, contains('wanted ja'));
        expect(os.downloadCalls, 0);
        expect(sidecarsNextTo(target), isEmpty);
      });
    }

    test('标着 ja、正文却是中文 → 下载后按正文拒收', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[
          <String, Object?>{
            'id': 6300,
            'name': 'Doraemon: Nobita to Kumo no Oukoku',
            'japanese_name': '映画ドラえもん のび太と雲の王国',
          },
        ],
        files: <int, List<String>>{
          6300: <String>['映画ドラえもん.のび太と雲の王国.ja.srt'],
        },
        body: _srt(<String>['大雄你在这里做什么', '哆啦A梦快来帮帮我们', '这个国家在云上面']),
      );
      final SubtitleBackfillTarget target = await movieTarget(
        '映画ドラえもん のび太と雲の王国',
        1992,
        originalLanguage: 'ja',
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
      ).backfill(target);
      expect(jimaku.downloads, hasLength(1));
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(result.detail, contains('wanted ja'));
      expect(sidecarsNextTo(target), isEmpty);
    });
  });

  group('BUG-3083 全局默认内容语言只排序、不硬拒', () {
    Map<String, Object?> yourNameEntry(int id) => <String, Object?>{
      'id': id,
      'name': 'Your Name',
      'flags': <String, Object?>{'anime': true, 'movie': true},
    };

    test('作品与音轨都没有语言证据：英语片的英文字幕照常装上', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[yourNameEntry(7001)],
        files: <int, List<String>>{
          7001: <String>['Your.Name.WEBRip.en.srt'],
        },
        body: _englishSrt,
      );
      // 没有 originalLanguage、测试视频也没有可探的音轨 tag。
      final SubtitleBackfillTarget target = await movieTarget(
        'Your Name',
        2016,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
        defaultContentLanguage: 'ja',
      ).backfill(target);
      expect(
        result.outcome,
        SubtitleBackfillOutcome.installed,
        reason: result.detail,
      );
      expect(result.language, 'en');
      expect(jimaku.downloads, hasLength(1));
    });

    test('同上，但候选里有默认语言的那条：它排在前面先装', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[yourNameEntry(7002)],
        files: <int, List<String>>{
          7002: <String>['Your.Name.WEBRip.en.srt', 'Your.Name.WEBRip.ja.srt'],
        },
      );
      final SubtitleBackfillTarget target = await movieTarget(
        'Your Name',
        2016,
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
        defaultContentLanguage: 'ja',
      ).backfill(target);
      expect(result.outcome, SubtitleBackfillOutcome.installed);
      expect(result.language, 'ja');
      expect(jimaku.downloads, hasLength(1));
    });

    test('对照：作品有原语言证据（ja）时英文字幕仍被硬拒', () async {
      final _Jimaku jimaku = _Jimaku(
        entries: <Map<String, Object?>>[yourNameEntry(7003)],
        files: <int, List<String>>{
          7003: <String>['Your.Name.WEBRip.en.srt'],
        },
        body: _englishSrt,
      );
      final SubtitleBackfillTarget target = await movieTarget(
        'Your Name',
        2016,
        originalLanguage: 'ja',
      );
      final SubtitleBackfillResult result = await _service(
        <VideoSubtitleProvider>[jimaku.provider],
        defaultContentLanguage: 'ja',
      ).backfill(target);
      expect(result.outcome, SubtitleBackfillOutcome.allCandidatesRejected);
      expect(result.detail, contains('wanted ja'));
      expect(sidecarsNextTo(target), isEmpty);
    });
  });
}

VideoSubtitleBackfillService _service(
  List<VideoSubtitleProvider> providers, {
  String? defaultContentLanguage,
}) => VideoSubtitleBackfillService(
  registry: VideoSubtitleRegistry(providers),
  defaultContentLanguage: defaultContentLanguage,
);

String _srt(List<String> lines) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 40; i++) {
    final int s = 10 + i * 60;
    String ts(int sec) =>
        '${(sec ~/ 3600).toString().padLeft(2, '0')}:'
        '${((sec ~/ 60) % 60).toString().padLeft(2, '0')}:'
        '${(sec % 60).toString().padLeft(2, '0')},000';
    b.write(
      '${i + 1}\n${ts(s)} --> ${ts(s + 3)}\n${lines[i % lines.length]}\n\n',
    );
  }
  return b.toString();
}

final String _japaneseSrt = _srt(<String>[
  'のび太くん、どこにいるの？',
  'ドラえもん、たすけてよ！',
  'くものうえにくにをつくろう',
]);

final String _englishSrt = _srt(<String>[
  'Where are you going?',
  'I keep dreaming about a town I have never seen.',
  'Have we met somewhere before?',
]);

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

http.Response _utf8(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
);

/// Jimaku API 桩：`/entries/search` 恒返回 [entries]，`/entries/<id>/files` 返回
/// [files]，文件 URL 返回 [body]。
class _Jimaku {
  _Jimaku({required this.entries, required this.files, String? body})
    : body = body ?? _japaneseSrt;

  final List<Map<String, Object?>> entries;
  final Map<int, List<String>> files;
  final String body;
  int searchCalls = 0;
  final List<String> downloads = <String>[];

  late final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
    client: JimakuClient(
      apiKey: 'k',
      client: MockClient((http.Request request) async {
        final String path = request.url.path;
        if (path == '/api/entries/search') {
          searchCalls++;
          return _json(entries);
        }
        final RegExpMatch? list = RegExp(
          r'^/api/entries/(\d+)/files$',
        ).firstMatch(path);
        if (list != null) {
          return _json(<Map<String, Object?>>[
            for (final String name in files[int.parse(list.group(1)!)] ?? [])
              <String, Object?>{
                'name': name,
                'url': 'https://jimaku.cc/file/${Uri.encodeComponent(name)}',
                'size': 40000,
              },
          ]);
        }
        if (path.startsWith('/file/')) {
          downloads.add(path);
          return _utf8(body);
        }
        return http.Response('unexpected $path', 500);
      }),
    ),
  );
}

/// AJATT 站点桩：目录里一部剧场版（1980 年「のび太の恐竜」）与 TV 系列
/// `Doraemon (2005)`，各自作品页一个文件。
class _Ajatt {
  final List<String> listedPages = <String>[];
  final List<String> downloads = <String>[];

  static const Map<String, String> _pages = <String, String>{
    'anime_movie/doraemon-nobita-no-kyouryuu.html':
        '映画ドラえもん.のび太の恐竜.WEBRip.Netflix.ja[cc].srt',
    'anime_tv/doraemon-(2005).html': 'Doraemon (2018.05.18).srt',
  };

  static String _row(
    String type,
    String page,
    String name,
    String en,
    String ja,
  ) =>
      '<tr data-timestamp="1787963826" data-entry-type="$type">'
      '<td class="entry_name"><a href="$page">$name</a></td>'
      '<td class="english_name">$en</td>'
      '<td class="japanese_name">$ja</td></tr>\n';

  static String _filePage(String fileName) =>
      '<table class="file_list_table">'
      '<tr data-timestamp="1787659912" data-file-size="36114">'
      '<td><input type="checkbox" data-download-url="'
      'https://raw.githubusercontent.com/x/${Uri.encodeComponent(fileName)}" '
      'data-filename="$fileName"></td></tr></table>';

  late final AjattVideoSubtitleProvider provider = AjattVideoSubtitleProvider(
    client: AjattClient(
      parseInIsolate: false,
      client: MockClient((http.Request request) async {
        final String url = request.url.toString();
        if (url == 'https://subtitles.ajatt.top/index.html') {
          return _utf8(
            _row(
                  'anime_movie',
                  'anime_movie/doraemon-nobita-no-kyouryuu.html',
                  'Doraemon Movie 1: Nobita no Kyouryuu',
                  "Doraemon: Nobita's Dinosaur",
                  '映画ドラえもん のび太の恐竜',
                ) +
                _row(
                  'anime_tv',
                  'anime_tv/doraemon-(2005).html',
                  'Doraemon (2005)',
                  'Doraemon',
                  'ドラえもん',
                ),
          );
        }
        if (url == 'https://subtitles.ajatt.top/drama.html') return _utf8('');
        for (final MapEntry<String, String> page in _pages.entries) {
          if (request.url.path == '/${page.key}') {
            listedPages.add(page.key);
            return _utf8(_filePage(page.value));
          }
        }
        if (url.startsWith('https://raw.githubusercontent.com/')) {
          downloads.add(url);
          return _utf8(_japaneseSrt);
        }
        return http.Response('unexpected $url', 500);
      }),
    ),
  );
}

/// OpenSubtitles REST 桩：每次 `/subtitles` 都回 [records]；`/download` 只计数。
class _OpenSubtitles {
  _OpenSubtitles(this.records);

  final List<Map<String, Object?>> records;
  int searchCalls = 0;
  int downloadCalls = 0;

  late final OpenSubtitlesClient client = OpenSubtitlesClient(
    config: OpenSubtitlesConfig(apiKey: 'k'),
    client: MockClient((http.Request request) async {
      if (request.url.path.endsWith('/subtitles')) {
        searchCalls++;
        return _json(<String, Object?>{'data': records});
      }
      downloadCalls++;
      return http.Response('{}', 500);
    }),
  );
}

/// 用户库里实际被装上的那条（OpenSubtitles file id 2109485）。
final Map<String, Object?> _pinkyAndTheBrain = <String, Object?>{
  'id': '2109485',
  'type': 'subtitle',
  'attributes': <String, Object?>{
    'language': 'en',
    'download_count': 1200,
    'moviehash_match': true,
    'files': <Map<String, Object?>>[
      <String, Object?>{
        'file_id': 2109485,
        'file_name': 'Pinky.And.The.Brain.S03E25.DVDRip.XviD-SAiNTS.srt',
      },
    ],
    'feature_details': <String, Object?>{
      'feature_type': 'Episode',
      'year': 1997,
      'title': 'Star Warners',
      'movie_name': 'Pinky and the Brain - S03E25  Star Warners',
      'parent_title': 'Pinky and the Brain',
      'parent_imdb_id': 112123,
      'parent_tmdb_id': 2489,
      'season_number': 3,
      'episode_number': 25,
    },
  },
};

Map<String, Object?> _feature({
  required int fileId,
  required String fileName,
  required String language,
  required int tmdbId,
  required int year,
}) => <String, Object?>{
  'id': '$fileId',
  'type': 'subtitle',
  'attributes': <String, Object?>{
    'language': language,
    'files': <Map<String, Object?>>[
      <String, Object?>{'file_id': fileId, 'file_name': fileName},
    ],
    'feature_details': <String, Object?>{
      'feature_type': 'Movie',
      'year': year,
      'title': 'Doraemon Movie',
      'tmdb_id': tmdbId,
    },
  },
};
