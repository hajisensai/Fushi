// 资源排序消费索引器自己的信任标记（Nyaa trusted / remake）。
//
// 根因：Nyaa 行 class 读出的 remake 在 provider → candidate 边界被丢掉，
// trusted 只进了版本卡分组键、不参与任何排序——同标题的非 trusted / remake
// 仿名逐集发布只要单集做种更多，就会压过 trusted 原发布成为默认推荐。
// 修法：candidate 补 remake 字段，相关度排序在季号 / 标题贴合度同档内按
// trusted > 普通 > remake 排，再回到上游做种次序；不按组名拉黑或降权。
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_relevance.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';

import 'nyaa_html_fixture.dart';

class _Candidate extends VideoResourceCandidate {
  _Candidate(
    String title, {
    required int seeders,
    bool trusted = false,
    bool remake = false,
  }) : super(
         providerId: 'nyaa',
         providerInstanceId: 'nyaa',
         remoteId: title,
         title: title,
         providerPriority: 100,
         seeders: seeders,
         trusted: trusted,
         remake: remake,
         sizeBytes: 1400000000,
       );
}

/// registry 的实际管线：去重（priority → seeders）→ 相关度重排 → 版本卡 → 选卡。
List<VideoResourceVersionGroup> _pipeline(
  List<VideoResourceCandidate> raw, {
  required String query,
}) => buildVideoResourceVersionGroups(
  rankVideoResourcesByRelevance(deduplicateVideoResources(raw), query: query),
);

List<VideoResourceCandidate> _episodes(
  String group, {
  required List<int> seeders,
  bool trusted = false,
  bool remake = false,
}) => <VideoResourceCandidate>[
  for (int i = 0; i < seeders.length; i++)
    _Candidate(
      '[$group] Show Title - ${(i + 1).toString().padLeft(2, '0')} (1080p)',
      seeders: seeders[i],
      trusted: trusted,
      remake: remake,
    ),
];

void main() {
  test('Nyaa provider 把 danger 行映射为 remake、success 行映射为 trusted', () async {
    final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
      siteId: 'nyaa-test',
      categoryByDomain: const <VideoDiscoveryCategory, String>{
        VideoDiscoveryCategory.anime: '1_0',
      },
      client: NyaaClient(
        baseUrl: 'https://nyaa.si',
        minRequestInterval: Duration.zero,
        client: MockClient(
          (http.Request request) async => http.Response(
            nyaaSearchHtml(<NyaaHtmlRow>[
              NyaaHtmlRow(
                title: '[Remaker] Show Title - 01 (1080p)',
                infoHash: 'a' * 40,
                id: '1',
                remake: true,
              ),
              NyaaHtmlRow(
                title: '[Origin] Show Title - 01 (1080p)',
                infoHash: 'b' * 40,
                id: '2',
                trusted: true,
              ),
              NyaaHtmlRow(
                title: '[Plain] Show Title - 01 (1080p)',
                infoHash: 'c' * 40,
                id: '3',
              ),
            ]),
            200,
          ),
        ),
      ),
    );
    addTearDown(provider.close);
    final ProviderBatchResult<VideoResourceCandidate> result = await provider
        .search(const VideoResourceSearchRequest(query: 'Show Title'));
    final Map<String, VideoResourceCandidate> byHash =
        <String, VideoResourceCandidate>{
          for (final VideoResourceCandidate c in result.items) c.infoHash!: c,
        };
    expect(byHash['a' * 40]!.remake, isTrue);
    expect(byHash['a' * 40]!.indexerTrustTier, 0);
    expect(byHash['b' * 40]!.trusted, isTrue);
    expect(byHash['b' * 40]!.remake, isFalse);
    expect(byHash['b' * 40]!.indexerTrustTier, 2);
    expect(byHash['c' * 40]!.indexerTrustTier, 1);
  });

  group('rankVideoResourcesByRelevance 的信任档', () {
    test('同等相关度：trusted > 普通 > remake，做种数只在同档内比', () {
      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        deduplicateVideoResources(<VideoResourceCandidate>[
          _Candidate(
            '[Remaker] Show Title - 01 (1080p)',
            seeders: 500,
            remake: true,
          ),
          _Candidate('[Plain] Show Title - 01 (1080p)', seeders: 300),
          _Candidate(
            '[Origin] Show Title - 01 (1080p)',
            seeders: 10,
            trusted: true,
          ),
        ]),
        query: 'Show Title',
      );
      expect(
        ranked.map((VideoResourceCandidate c) => c.title.split(']').first),
        <String>['[Origin', '[Plain', '[Remaker'],
      );
    });

    test('信任档不压过季号：trusted 错季仍排在普通正确季之后', () {
      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        <VideoResourceCandidate>[
          _Candidate('[Origin] Show S03 (1080p)', seeders: 900, trusted: true),
          _Candidate('[Plain] Show S02 (1080p)', seeders: 1),
        ],
        query: 'Show',
        season: 2,
      );
      expect(ranked.first.title, contains('S02'));
    });
  });

  group('版本卡与默认选卡', () {
    test('remake 与原发布同组名同清晰度也分成两张卡', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(<VideoResourceCandidate>[
            _Candidate('[Same] Show Title - 01 (1080p)', seeders: 5),
            _Candidate(
              '[Same] Show Title - 02 (1080p)',
              seeders: 5,
              remake: true,
            ),
          ]);
      expect(groups, hasLength(2));
      expect(
        groups.where((VideoResourceVersionGroup g) => g.remake),
        hasLength(1),
      );
    });

    test('同为 1080p：默认首选 trusted 卡，remake 卡排最后', () {
      final List<VideoResourceVersionGroup> groups = _pipeline(
        <VideoResourceCandidate>[
          ..._episodes('Remaker', seeders: <int>[900, 880, 870], remake: true),
          ..._episodes('Plain', seeders: <int>[300, 290, 280]),
          ..._episodes('Origin', seeders: <int>[20, 19, 18], trusted: true),
        ],
        query: 'Show Title',
      );
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(
        outcome.eligible.map((VideoResourceVersionGroup g) => g.releaseGroup),
        <String>['Origin', 'Plain', 'Remaker'],
      );
    });

    test('现场回归：同为 trusted 时不按组名降权（SobsPlease 是 trusted 独立字幕组）', () {
      // nyaa 2026-11-08 实测：SobsPlease 01-13 与 SubsPlease 合集行 class 都是
      // success。两者同档，保持上游做种次序——不允许以后靠组名名单改变结果。
      final List<VideoResourceVersionGroup> groups =
          _pipeline(<VideoResourceCandidate>[
            for (int i = 0; i < 13; i++)
              _Candidate(
                '[SobsPlease] Girls Band Cry - '
                '${(i + 1).toString().padLeft(2, '0')} (1080p) [0351EB74].mkv',
                seeders: 71 - i * 2,
                trusted: true,
              ),
            _Candidate(
              '[SubsPlease] Girls Band Cry (01-13) (1080p) [Batch]',
              seeders: 29,
              trusted: true,
            ),
          ], query: 'Girls Band Cry');
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(outcome.eligible.first.releaseGroup, 'SobsPlease');
    });
  });
}
