import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 本地专辑 → MusicBrainz 发行（为了拿 Cover Art Archive 的盘面扫描）。fixture 与
/// `music_release_match_test.dart` 共用（2026-10-24 实取，CC0）。
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

http.Response _json(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

({MusicBrainzProvider provider, List<http.Request> requests}) _fakeMb({
  bool artistSearchEmpty = false,
}) {
  final List<http.Request> requests = <http.Request>[];
  final MockClient client = MockClient((http.Request req) async {
    requests.add(req);
    final String path = req.url.path;
    if (path.endsWith('/release')) {
      final String q = req.url.queryParameters['query'] ?? '';
      if (artistSearchEmpty && q.contains('artist:')) {
        return _json('{"releases":[]}');
      }
      return _json(_fixture('mb_release_search_live_disc.json'));
    }
    if (path.endsWith('release/5823db14-ac35-4aa6-b0ff-4b4149e5a2d6')) {
      return _json(_fixture('mb_release_live_bd.json'));
    }
    if (path.endsWith('release/942c45ed-705b-4689-a19e-a1d60f10ec09')) {
      return _json(_fixture('mb_release_live_bd2.json'));
    }
    return http.Response('{"error":"Not Found"}', 404);
  });
  return (
    provider: MusicBrainzProvider(
      transport: VideoMetadataHttpClient(client: client, maxAttempts: 1),
      throttle: MusicRequestThrottle(
        Duration.zero,
        sleep: (Duration _) async {},
      ),
    ),
    requests: requests,
  );
}

MusicReleaseMedium _medium(int position, List<int?> lengths) =>
    MusicReleaseMedium(
      position: position,
      format: 'CD',
      tracks: <MusicReleaseTrack>[
        for (int i = 0; i < lengths.length; i++)
          MusicReleaseTrack(
            position: i + 1,
            title: 't$i',
            durationMs: lengths[i],
          ),
      ],
    );

MusicReleaseTracklist _release(String id, List<MusicReleaseMedium> media) =>
    MusicReleaseTracklist(mbReleaseId: id, title: 'A', media: media);

void main() {
  test('专辑级查询串：不带格式条件；艺人可选；短语转义', () {
    expect(
      buildMusicBrainzAlbumReleaseQuery('LiVE is Smile Always'),
      'release:"LiVE is Smile Always"',
    );
    expect(
      buildMusicBrainzAlbumReleaseQuery(' A "b" \\ ', artist: ' LiSA '),
      r'release:"A \"b\" \\" AND artist:"LiSA"',
    );
    // DVD / BD 那条不受影响。
    expect(
      buildMusicBrainzDiscReleaseQuery('X'),
      'release:"X" AND '
      '(format:"DVD-Video" OR format:"Blu-ray" OR format:"DVD")',
    );
  });

  test('搜索结果按本地各盘曲数筛：装不下的发行不取详情', () {
    final Map<String, Object?> hit = <String, Object?>{
      'id': 'x',
      'media': <Object?>[
        <String, Object?>{'track-count': 20},
        <String, Object?>{'track-count': 13},
      ],
    };
    expect(musicBrainzReleaseHitFitsTrackCounts(hit, null), isTrue);
    expect(musicBrainzReleaseHitFitsTrackCounts(hit, <int>[13]), isTrue);
    expect(musicBrainzReleaseHitFitsTrackCounts(hit, <int>[20, 13]), isTrue);
    expect(musicBrainzReleaseHitFitsTrackCounts(hit, <int>[13, 13]), isFalse);
    expect(musicBrainzReleaseHitFitsTrackCounts(hit, <int>[14]), isFalse);
    expect(
      musicBrainzReleaseHitFitsTrackCounts(
        <String, Object?>{'id': 'y'},
        <int>[14],
      ),
      isTrue,
      reason: '搜索结果没带 media 时不筛',
    );
  });

  test('provider：带艺人搜 → 按曲数筛 → 只取对得上的详情 → 挑出可信发行', () async {
    final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
        _fakeMb();
    final List<MusicReleaseTracklist> releases = await mb.provider
        .searchAlbumReleases(
          'LiVE is Smile Always',
          artist: 'LiSA',
          discTrackCounts: <int>[13],
        );
    expect(mb.requests, hasLength(2), reason: '一次搜索 + 一张详情（第二张没有 13 曲盘）');
    expect(
      mb.requests.first.url.queryParameters['query'],
      buildMusicBrainzAlbumReleaseQuery('LiVE is Smile Always', artist: 'LiSA'),
    );
    expect(releases.single.mbReleaseId, '5823db14-ac35-4aa6-b0ff-4b4149e5a2d6');

    // 本地是那张 CD（发行里第 2 张 medium），时长 ±1 s。
    final MusicReleaseMedium cd = releases.single.media[1];
    final List<int> local = <int>[
      for (int i = 0; i < cd.tracks.length; i++)
        cd.tracks[i].durationMs! + (i.isEven ? 1000 : -800),
    ];
    final MusicAlbumReleaseMatch? m = pickMusicAlbumRelease(<int, List<int>>{
      1: local,
    }, releases);
    expect(m, isNotNull);
    expect(m!.release.mbReleaseId, '5823db14-ac35-4aa6-b0ff-4b4149e5a2d6');
    expect(m.discs[1]!.medium.format, 'CD');
    expect(m.coversAllMedia, isFalse);
    expect(m.meanErrorMs, inInclusiveRange(800, 1000));
  });

  test('provider：带艺人搜不到时只按专辑名再搜一次', () async {
    final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
        _fakeMb(artistSearchEmpty: true);
    final List<MusicReleaseTracklist> releases = await mb.provider
        .searchAlbumReleases(
          'LiVE is Smile Always',
          artist: 'Unknown',
          discTrackCounts: <int>[14],
        );
    expect(
      mb.requests
          .where((http.Request r) => r.url.path.endsWith('/release'))
          .map((http.Request r) => r.url.queryParameters['query']),
      <String>[
        buildMusicBrainzAlbumReleaseQuery(
          'LiVE is Smile Always',
          artist: 'Unknown',
        ),
        buildMusicBrainzAlbumReleaseQuery('LiVE is Smile Always'),
      ],
    );
    expect(releases.single.mbReleaseId, '942c45ed-705b-4689-a19e-a1d60f10ec09');
  });

  group('matchMusicAlbumRelease / pickMusicAlbumRelease', () {
    final MusicReleaseTracklist twoDisc = _release('two', <MusicReleaseMedium>[
      _medium(1, <int>[200000, 210000, 220000]),
      _medium(2, <int>[300000, 310000]),
    ]);

    test('多盘：每张本地盘对上不同的 medium；按位置优先', () {
      final MusicAlbumReleaseMatch? m = matchMusicAlbumRelease(<int, List<int>>{
        1: <int>[201000, 209000, 221000],
        2: <int>[300500, 309500],
      }, twoDisc);
      expect(m, isNotNull);
      expect(m!.coversAllMedia, isTrue);
      expect(m.discs[1]!.medium.position, 1);
      expect(m.discs[2]!.medium.position, 2);
      expect(m.meanErrorMs, 800);
    });

    test('本地盘号与 medium 位置不一致：贪心按时长分配', () {
      final MusicAlbumReleaseMatch? m = matchMusicAlbumRelease(<int, List<int>>{
        1: <int>[300500, 309500],
        2: <int>[201000, 209000, 221000],
      }, twoDisc);
      expect(m!.discs[1]!.medium.position, 2);
      expect(m.discs[2]!.medium.position, 1);
    });

    test('任何一张盘对不上 / 缺时长 / 同一 medium 不能用两次：返回 null', () {
      expect(
        matchMusicAlbumRelease(<int, List<int>>{
          1: <int>[201000, 209000, 221000],
          2: <int>[400000, 309500],
        }, twoDisc),
        isNull,
        reason: '第 2 张误差太大',
      );
      expect(
        matchMusicAlbumRelease(<int, List<int>>{
          1: <int>[201000, 0, 221000],
        }, twoDisc),
        isNull,
        reason: '本地缺时长',
      );
      expect(
        matchMusicAlbumRelease(<int, List<int>>{
          1: <int>[300500, 309500],
          2: <int>[300400, 309600],
        }, twoDisc),
        isNull,
        reason: '两张本地盘不能共用一张 medium',
      );
      expect(
        matchMusicAlbumRelease(
          <int, List<int>>{
            1: <int>[200000, 210000, 220000],
          },
          _release('nolen', <MusicReleaseMedium>[
            _medium(1, <int?>[null, null, null]),
          ]),
        ),
        isNull,
        reason: '发行没有时长：只靠曲数不算可信',
      );
    });

    test('多张候选：盘数与 medium 数一致的优先，再按误差；都对不上返回 null', () {
      final MusicReleaseTracklist withBonus = _release(
        'bonus',
        <MusicReleaseMedium>[
          _medium(1, <int>[200000, 210000, 220000]),
          _medium(2, <int>[300000, 310000]),
          _medium(3, <int>[100000]),
        ],
      );
      final MusicReleaseTracklist closer = _release(
        'closer',
        <MusicReleaseMedium>[
          _medium(1, <int>[201000, 209000, 221000]),
          _medium(2, <int>[300500, 309500]),
          _medium(3, <int>[100000]),
        ],
      );
      final Map<int, List<int>> local = <int, List<int>>{
        1: <int>[201000, 209000, 221000],
        2: <int>[300500, 309500],
      };
      expect(
        pickMusicAlbumRelease(local, <MusicReleaseTracklist>[
          closer,
          withBonus,
          twoDisc,
        ])!.release.mbReleaseId,
        'two',
        reason: '盘数一致优先于误差更小',
      );
      expect(
        pickMusicAlbumRelease(local, <MusicReleaseTracklist>[
          withBonus,
          closer,
        ])!.release.mbReleaseId,
        'closer',
      );
      expect(
        pickMusicAlbumRelease(
          <int, List<int>>{
            1: <int>[1000, 2000],
          },
          <MusicReleaseTracklist>[twoDisc, closer],
        ),
        isNull,
      );
    });
  });
}
