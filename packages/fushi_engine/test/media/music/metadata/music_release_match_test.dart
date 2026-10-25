import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 光盘专辑的发行级 MusicBrainz 结论（音乐方案 §9.2）。离线 fixture 是 2026-10-24 从
/// musicbrainz.org 实取的响应（核心数据 CC0）：
///   * `mb_discid_kaguya_tokuten.json`：本机光驱里一张真 CD 的 Disc ID
///     `wQ8ygYRJ6TxS9evQ5yIRDW8yJLo-`（Rust `cd.rs` 算出）的查询结果；
///   * `mb_release_search_live_disc.json` + 两张详情：按标题搜 DVD / BD 发行。
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

({MusicBrainzProvider provider, List<http.Request> requests}) _fakeMb(
  Map<String, String> routes,
) {
  final List<http.Request> requests = <http.Request>[];
  final MockClient client = MockClient((http.Request req) async {
    requests.add(req);
    for (final MapEntry<String, String> e in routes.entries) {
      if (req.url.path.endsWith(e.key)) {
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
      throttle: MusicRequestThrottle(
        Duration.zero,
        sleep: (Duration _) async {},
      ),
    ),
    requests: requests,
  );
}

void main() {
  test('Disc ID 查发行：曲目表、录音 MBID、带 TOC 查询串', () async {
    final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
        _fakeMb(<String, String>{
          'discid/wQ8ygYRJ6TxS9evQ5yIRDW8yJLo-':
              'mb_discid_kaguya_tokuten.json',
        });
    final List<MusicReleaseTracklist> releases = await mb.provider.lookupDiscId(
      'wQ8ygYRJ6TxS9evQ5yIRDW8yJLo-',
      toc: '1 12 208100 150 17596',
    );
    expect(releases, hasLength(1));
    final MusicReleaseTracklist r = releases.single;
    expect(r.mbReleaseId, '4708cedb-2d47-44c1-ac15-8a456a6e205c');
    expect(r.media.single.format, 'CD');
    expect(r.media.single.tracks, hasLength(12));
    expect(r.media.single.tracks.first.durationMs, 232613);
    expect(r.media.single.tracks.first.mbRecordingId, isNotNull);
    final Uri uri = mb.requests.single.url;
    expect(uri.queryParameters['toc'], '1 12 208100 150 17596');
    // `media` 不是 discid 端点的合法 inc（实测 400）。
    expect(uri.queryParameters['inc'], isNot(contains('media')));
    expect(mb.requests.single.headers['User-Agent'], startsWith('fushi/'));
  });

  test('按标题搜 DVD / BD 发行：先搜索再逐张取详情；查询带格式条件', () async {
    final ({MusicBrainzProvider provider, List<http.Request> requests}) mb =
        _fakeMb(<String, String>{
          '/release': 'mb_release_search_live_disc.json',
          'release/5823db14-ac35-4aa6-b0ff-4b4149e5a2d6':
              'mb_release_live_bd.json',
          'release/942c45ed-705b-4689-a19e-a1d60f10ec09':
              'mb_release_live_bd2.json',
        });
    final List<MusicReleaseTracklist> releases = await mb.provider
        .searchDiscReleases('LiVE is Smile Always', limit: 2);
    expect(releases, hasLength(2));
    expect(
      mb.requests.first.url.queryParameters['query'],
      buildMusicBrainzDiscReleaseQuery('LiVE is Smile Always'),
    );
    expect(
      buildMusicBrainzDiscReleaseQuery('LiVE is Smile Always'),
      'release:"LiVE is Smile Always" AND '
      '(format:"DVD-Video" OR format:"Blu-ray" OR format:"DVD")',
    );
    expect(releases.first.formatSummary, 'Blu-ray + CD');

    // 章节时长 = 第一张发行 BD 盘的曲目时长 ± 1.5 s：只有它对得上（第二张 35 曲、无时长）。
    final MusicReleaseMedium bd = releases.first.media.first;
    final List<int> chapters = <int>[
      for (int i = 0; i < bd.tracks.length; i++)
        bd.tracks[i].durationMs! + (i.isEven ? 1500 : -1200),
    ];
    final List<MusicDiscReleaseMatch> ranked = rankMusicDiscReleaseMatches(
      chapters,
      releases,
    );
    expect(ranked, hasLength(1));
    expect(ranked.single.release.mbReleaseId, releases.first.mbReleaseId);
    expect(ranked.single.medium.format, 'Blu-ray');
    expect(ranked.single.isConfident, isTrue);
    expect(ranked.single.meanErrorMs, inInclusiveRange(1200, 1500));
  });

  test('曲数一样但时长差太多 / 没有时长：只当候选，不算可信', () {
    const MusicReleaseTracklist r = MusicReleaseTracklist(
      mbReleaseId: 'x',
      title: 'x',
      media: <MusicReleaseMedium>[
        MusicReleaseMedium(
          position: 1,
          format: 'DVD-Video',
          tracks: <MusicReleaseTrack>[
            MusicReleaseTrack(position: 1, title: 'a', durationMs: 200000),
            MusicReleaseTrack(position: 2, title: 'b', durationMs: 200000),
          ],
        ),
        MusicReleaseMedium(
          position: 2,
          format: 'CD',
          tracks: <MusicReleaseTrack>[
            MusicReleaseTrack(position: 1, title: 'a', durationMs: 100000),
            MusicReleaseTrack(position: 2, title: 'b', durationMs: 100000),
          ],
        ),
      ],
    );
    // 视频盘优先：即使 CD 那张时长完全吻合，也先看 DVD-Video 那张。
    final MusicDiscReleaseMatch m = matchMusicDiscChapters(<int>[
      100000,
      100000,
    ], r)!;
    expect(m.medium.format, 'DVD-Video');
    expect(m.isConfident, isFalse);
    expect(matchMusicDiscChapters(<int>[1, 2, 3], r), isNull);
  });
}
