import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/music/metadata/music_auxiliary_providers.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_resolver.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_text.dart';
import 'package:fushi_engine/media/music/metadata/music_versions.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 离线 fixture：2026-10-24 从 musicbrainz.org / coverartarchive.org 实取的响应（MusicBrainz
/// 核心数据 CC0），发行列表截到前 4 张。
String _fixture(String name) {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    for (final String rel in <String>[
      'test/media/music/metadata/fixtures/$name',
      'packages/fushi_engine/test/media/music/metadata/fixtures/$name',
    ]) {
      final File f = File('${dir.path}/$rel');
      if (f.existsSync()) return f.readAsStringSync();
    }
    dir = dir.parent;
  }
  throw StateError('fixture $name not found');
}

Map<String, Object?> _json(String name) =>
    jsonDecode(_fixture(name)) as Map<String, Object?>;

const String _lemon = '79a8b80c-018d-4004-b3ff-cc10d21a3ddd';
const String _lemonWork = 'd69ecd96-bb2c-461f-9762-29102d2b50a1';

/// 不睡的闸门：测试只验证顺序与调用，不等真实间隔。
MusicRequestThrottle _noWait() => MusicRequestThrottle(
  Duration.zero,
  sleep: (Duration _) async {},
);

/// 按路径分发 fixture 的假 MusicBrainz，记下每个请求（断言 UA / 次数）。
({MusicBrainzProvider provider, List<http.Request> requests}) _fakeMb({
  Map<String, String> routes = const <String, String>{},
}) {
  final List<http.Request> requests = <http.Request>[];
  final MockClient client = MockClient((http.Request req) async {
    requests.add(req);
    final String path = req.url.path;
    for (final MapEntry<String, String> e in routes.entries) {
      if (path.endsWith(e.key) ||
          (e.key.startsWith('?') &&
              req.url.queryParameters.containsKey(e.key.substring(1)))) {
        return http.Response.bytes(
          utf8.encode(_fixture(e.value)),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
    }
    return http.Response('{"error":"Not Found"}', 404);
  });
  return (
    provider: MusicBrainzProvider(
      transport: VideoMetadataHttpClient(client: client, maxAttempts: 1),
      throttle: _noWait(),
    ),
    requests: requests,
  );
}

void main() {
  group('文本归一化', () {
    test('全角 / 标点 / 大小写', () {
      expect(normalizeMusicText('ＬＥＭＯＮ！'), 'lemon');
      expect(normalizeMusicText('「残酷な天使のテーゼ」'), '残酷な天使のテーゼ');
      expect(musicTitleSimilarity('Lemon', 'lemon'), 1);
      expect(musicTitleSimilarity('Lemon (TV size)', 'Lemon'), 0.8);
      expect(musicTitleSimilarity('Lemon - Remastered 2020', 'Lemon'), 0.8);
      expect(musicTitleSimilarity('Lemon', 'Orange'), 0);
    });

    test('艺人拆分与交集', () {
      expect(splitMusicArtists('KOBASOLO & 春茶'), <String>{'kobasolo', '春茶'});
      expect(musicArtistSimilarity('米津玄師', <String>['米津玄師']), 1);
      expect(musicArtistSimilarity('春茶', <String>['KOBASOLO & 春茶']), 0.8);
      expect(musicArtistSimilarity('LiSA', <String>['Aimer']), 0);
    });

    test('残缺日期排序', () {
      final List<String?> dates = <String?>[
        null,
        '2018-03-14',
        '2018',
        '2017-12',
      ]..sort((String? a, String? b) => musicDateSortKey(a).compareTo(musicDateSortKey(b)));
      expect(dates, <String?>['2017-12', '2018', '2018-03-14', null]);
    });
  });

  group('MusicBrainz 解析', () {
    test('查询串：短语转义 + 只要音频录音', () {
      expect(
        buildMusicBrainzRecordingQuery(
          const MusicRecordingSearchQuery(
            title: 'Say "Hi"',
            artist: r'A\B',
            album: 'X',
          ),
        ),
        r'recording:"Say \"Hi\"" AND artist:"A\\B" AND release:"X" AND video:false',
      );
      expect(normalizeMusicBrainzId(' 79A8B80C-018D-4004-B3FF-CC10D21A3DDD '), _lemon);
      expect(normalizeMusicBrainzId('not-a-mbid'), isNull);
    });

    test('录音详情：作品关系 / URL 关系 / 发行与曲序', () {
      final MusicRecording r = parseMusicBrainzRecording(
        _json('mb_recording_lemon.json'),
      )!;
      expect(r.mbRecordingId, _lemon);
      expect(r.title, 'Lemon');
      expect(r.durationMs, 255826);
      expect(r.artistCreditText, '米津玄師');
      expect(r.works.single.mbWorkId, _lemonWork);
      expect(r.works.single.attributes, isEmpty);
      expect(r.urls.map((MusicUrlRelation u) => u.type), contains('streaming'));
      expect(r.releases, hasLength(4));
      expect(r.releases.first.trackPosition, 1);
      expect(r.releases.first.discPosition, 1);
      expect(r.releases.first.primaryType, 'Single');
      expect(r.isrcs, isNotEmpty);
    });

    test('搜索结果（media[].track[] 形态）', () {
      final Map<String, Object?> json = _json('mb_search_lemon.json');
      final List<Object?> list = json['recordings']! as List<Object?>;
      final MusicRecording r = parseMusicBrainzRecording(
        list.first! as Map<String, Object?>,
      )!;
      expect(r.mbRecordingId, _lemon);
      expect(r.searchScore, 100);
      expect(r.releases, isNotEmpty);
    });

    test('发行的目录编号来自 label-info', () {
      final MusicReleaseRef rel = parseMusicBrainzRelease(<String, Object?>{
        'id': 'dad6dbbe-68a8-4b31-8c60-2fd287360d50',
        'title': 'Lemon',
        'label-info': <Object?>[
          <String, Object?>{'catalog-number': 'SECL-2270'},
          <String, Object?>{'catalog-number': null},
        ],
      })!;
      expect(rel.catalogNumbers, <String>['SECL-2270']);
    });

    test('MV 关系方向：forward = 本录音的 MV', () {
      final MusicRecording r = parseMusicBrainzRecording(<String, Object?>{
        'id': _lemon,
        'title': 'Lemon',
        'relations': <Object?>[
          <String, Object?>{
            'type': 'music video',
            'direction': 'forward',
            'target-type': 'recording',
            'recording': <String, Object?>{'id': 'video-1'},
          },
          <String, Object?>{
            'type': 'music video',
            'direction': 'backward',
            'target-type': 'recording',
            'recording': <String, Object?>{'id': 'audio-1'},
          },
        ],
      })!;
      expect(r.musicVideoRecordingIds, <String>['video-1']);
      expect(r.musicVideoOfRecordingIds, <String>['audio-1']);
    });
  });

  group('原曲与其它版本（§8.2）', () {
    test('Lemon：原曲是米津玄師版，翻唱都进其它版本，视频录音不算', () {
      final MusicWork work = parseMusicBrainzWork(
        _json('mb_work_lemon.json'),
        _json('mb_work_recordings_lemon.json'),
      )!;
      expect(work.title, 'Lemon');
      final MusicVersions self = resolveMusicVersions(work, _lemon);
      expect(self.original?.mbRecordingId, _lemon);
      expect(self.selfIsOriginal, isTrue);
      expect(
        self.others.every((MusicWorkRecording r) => !r.isVideo && r.isCover),
        isTrue,
      );
      // 从翻唱的视角看：原曲还是同一条，自己不在其它版本里。
      const String cover = '47ff3783-34ea-47a3-a945-1e4fca3b3085';
      final MusicVersions fromCover = resolveMusicVersions(work, cover);
      expect(fromCover.original?.mbRecordingId, _lemon);
      expect(fromCover.selfIsOriginal, isFalse);
      expect(
        fromCover.others.map((MusicWorkRecording r) => r.mbRecordingId),
        isNot(contains(cover)),
      );
      expect(
        fromCover.others.map((MusicWorkRecording r) => r.mbRecordingId),
        isNot(contains(_lemon)),
      );
    });
  });

  group('识别顺序（§8.1）', () {
    const MusicTrackFacts lemonTags = MusicTrackFacts(
      trackUid: 't1',
      title: 'Lemon',
      artist: '米津玄師',
      album: 'Lemon',
      durationMs: 255900,
      trackNo: 1,
    );

    test('MBID 标签：直接取，不搜索', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(
            routes: <String, String>{
              'recording/$_lemon': 'mb_recording_lemon.json',
            },
          );
      final MusicIdentification id = await MusicMetadataResolver(
        musicBrainz: mb.provider,
      ).identify(
        const MusicTrackFacts(
          trackUid: 't1',
          title: 'whatever',
          mbRecordingIdTag: _lemon,
        ),
      );
      expect(id.method, MusicIdentificationMethod.mbidTag);
      expect(id.recordingId, _lemon);
      expect(mb.requests, hasLength(1));
      expect(mb.requests.single.url.path, endsWith('recording/$_lemon'));
      expect(
        mb.requests.single.headers['User-Agent'],
        'fushi/musicbrainz (https://fushi.moe)',
      );
    });

    test('标签精确查：唯一严格命中', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(routes: <String, String>{'?query': 'mb_search_lemon.json'});
      final MusicIdentification id = await MusicMetadataResolver(
        musicBrainz: mb.provider,
      ).identify(lemonTags);
      expect(id.method, MusicIdentificationMethod.tagSearch);
      expect(id.recordingId, _lemon);
      final String q = mb.requests.first.url.queryParameters['query']!;
      expect(q, contains('recording:"Lemon"'));
      expect(q, contains('artist:"米津玄師"'));
    });

    test('时长差 > 15 s 硬拒：不识别，交手选（AcoustID 没配 → 记原因）', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(routes: <String, String>{'?query': 'mb_search_lemon.json'});
      final MusicIdentification id = await MusicMetadataResolver(
        musicBrainz: mb.provider,
        acoustid: AcoustidProvider(apiKey: '  '),
      ).identify(
        const MusicTrackFacts(
          trackUid: 't1',
          title: 'Lemon',
          artist: '米津玄師',
          durationMs: 90000,
        ),
      );
      expect(id.matched, isFalse);
      expect(id.acoustidSkippedReason, contains('API key'));
    });

    test('艺人对不上：不算严格命中', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(routes: <String, String>{'?query': 'mb_search_lemon.json'});
      final MusicIdentification id = await MusicMetadataResolver(
        musicBrainz: mb.provider,
      ).identify(
        const MusicTrackFacts(
          trackUid: 't1',
          title: 'Lemon',
          artist: 'Someone Else',
          durationMs: 255900,
        ),
      );
      expect(id.matched, isFalse);
      expect(id.candidates, isNotEmpty);
    });

    test('AcoustID：标签认不出时用声纹，只上传声纹串 + 时长 + key', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(routes: <String, String>{'?query': 'mb_search_lemon.json'});
      final List<http.Request> acoustidRequests = <http.Request>[];
      final AcoustidProvider acoustid = AcoustidProvider(
        apiKey: 'test-key',
        throttle: _noWait(),
        client: MockClient((http.Request req) async {
          acoustidRequests.add(req);
          return http.Response(
            jsonEncode(<String, Object?>{
              'status': 'ok',
              'results': <Object?>[
                <String, Object?>{
                  'id': 'acoustid-1',
                  'score': 0.97,
                  'recordings': <Object?>[
                    <String, Object?>{'id': _lemon},
                  ],
                },
                <String, Object?>{
                  'id': 'acoustid-low',
                  'score': 0.3,
                  'recordings': <Object?>[
                    <String, Object?>{
                      'id': '00000000-0000-0000-0000-000000000000',
                    },
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );
      final MusicIdentification id =
          await MusicMetadataResolver(
            musicBrainz: mb.provider,
            acoustid: acoustid,
          ).identify(
            // 标题被写成文件名，标签查不到严格命中。
            const MusicTrackFacts(trackUid: 't1', title: '01 track'),
            fingerprint: () async => (fingerprint: 'AQAAAQE', durationSec: 256),
          );
      expect(id.method, MusicIdentificationMethod.acoustid);
      expect(id.recordingId, _lemon);
      expect(id.acoustid, 'acoustid-1');
      final Map<String, String> form = acoustidRequests.single.bodyFields;
      expect(form.keys.toSet(), <String>{
        'client',
        'duration',
        'fingerprint',
        'meta',
        'format',
      });
      expect(form['client'], 'test-key');
      expect(form['duration'], '256');
    });

    test('AcoustID key 无效：识别结束并报原因，不重试', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb();
      int calls = 0;
      final AcoustidProvider acoustid = AcoustidProvider(
        apiKey: 'bad',
        throttle: _noWait(),
        client: MockClient((http.Request req) async {
          calls++;
          return http.Response(
            '{"error": {"code": 4, "message": "invalid API key"}, "status": "error"}',
            400,
          );
        }),
      );
      final MusicIdentification id =
          await MusicMetadataResolver(
            musicBrainz: mb.provider,
            acoustid: acoustid,
          ).identify(
            const MusicTrackFacts(trackUid: 't1', title: 'x'),
            fingerprint: () async => (fingerprint: 'AQAAAQE', durationSec: 10),
          );
      expect(id.matched, isFalse);
      expect(id.acoustidSkippedReason, contains('rejected'));
      expect(calls, 1);
    });
  });

  group('补全', () {
    test('识别后取作品与封面：原曲 + CAA 正面图（https）', () async {
      final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
          _fakeMb(
            routes: <String, String>{
              'recording/$_lemon': 'mb_recording_lemon.json',
              'work/$_lemonWork': 'mb_work_lemon.json',
              '?work': 'mb_work_recordings_lemon.json',
            },
          );
      final CoverArtArchiveProvider caa = CoverArtArchiveProvider(
        throttle: _noWait(),
        client: MockClient(
          (http.Request req) async =>
              http.Response.bytes(utf8.encode(_fixture('caa_release_lemon.json')), 200),
        ),
      );
      final MusicScrapeResult r = await MusicMetadataScraper(
        resolver: MusicMetadataResolver(musicBrainz: mb.provider),
        covers: caa,
      ).scrape(
        const MusicTrackFacts(
          trackUid: 't1',
          title: 'Lemon',
          mbRecordingIdTag: _lemon,
        ),
      );
      expect(r.identification.method, MusicIdentificationMethod.mbidTag);
      expect(r.release?.mbReleaseId, isNotNull);
      expect(r.cover?.front, isTrue);
      expect(r.cover!.displayUrl, startsWith('https://'));
      expect(r.versions?.selfIsOriginal, isTrue);
      expect(r.warnings, isEmpty);
    });

    test('闸门：同一闸门上的请求串行且间隔 ≥ minInterval', () async {
      DateTime t = DateTime.utc(2026);
      final List<Duration> slept = <Duration>[];
      final MusicRequestThrottle gate = MusicRequestThrottle(
        const Duration(seconds: 1),
        now: () => t,
        sleep: (Duration d) async {
          slept.add(d);
          t = t.add(d);
        },
      );
      final List<int> order = <int>[];
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 3; i++)
          gate.run(() async {
            order.add(i);
            t = t.add(const Duration(milliseconds: 200));
          }),
      ]);
      expect(order, <int>[0, 1, 2]);
      expect(slept, <Duration>[
        const Duration(milliseconds: 800),
        const Duration(milliseconds: 800),
      ]);
    });
  });

  group('VGMdb', () {
    test('只认目录编号唯一精确相等', () {
      final Map<String, Object?> json = <String, Object?>{
        'results': <String, Object?>{
          'albums': <Object?>[
            <String, Object?>{
              'catalog': 'LACA-5203',
              'link': 'album/1234',
              'titles': <String, Object?>{'en': 'Title', 'ja': 'タイトル'},
              'release_date': '2004-01-21',
            },
            <String, Object?>{
              'catalog': 'LACA-52030',
              'link': 'album/9',
              'titles': <String, Object?>{},
            },
          ],
        },
      };
      final VgmdbAlbum a = parseVgmdbCatalogSearch(json, catalog: 'laca 5203')!;
      expect(a.id, '1234');
      expect(a.link, 'https://vgmdb.net/album/1234');
      expect(a.japaneseName, 'タイトル');
      final Map<String, Object?> dup = <String, Object?>{
        'results': <String, Object?>{
          'albums': <Object?>[
            <String, Object?>{'catalog': 'X-1', 'link': 'album/1'},
            <String, Object?>{'catalog': 'X-1', 'link': 'album/2'},
          ],
        },
      };
      expect(parseVgmdbCatalogSearch(dup, catalog: 'X-1'), isNull);
    });

    test('关掉时不可用、不发请求', () {
      final VgmdbProvider p = VgmdbProvider(enabled: false);
      expect(p.isAvailable, isFalse);
      expect(
        () => p.findAlbumByCatalog('X'),
        throwsA(isA<MusicMetadataProviderUnavailable>()),
      );
    });
  });
}
