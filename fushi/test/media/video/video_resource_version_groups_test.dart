// B2 资源选版：下载模式「发布组›清晰度」聚类纯函数。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

class _FakeResource extends VideoResourceCandidate {
  _FakeResource({
    required super.remoteId,
    required super.title,
    super.providerId = 'nyaa',
    super.providerInstanceId = 'nyaa',
    super.providerPriority = 100,
    super.releaseGroup,
    super.resolution,
    super.seeders,
    super.publishedAt,
  });
}

void main() {
  group('isLikelyBatchVideoRelease', () {
    test('关键词与带界定符的区间判合集', () {
      expect(isLikelyBatchVideoRelease('[SubsPlease] Show (01-12) (Batch)'),
          isTrue);
      expect(isLikelyBatchVideoRelease('Show Complete Series 1080p'), isTrue);
      expect(isLikelyBatchVideoRelease('【喵萌】剧场版+TV全集'), isTrue);
      expect(isLikelyBatchVideoRelease('[Sub] Show [01-24 Fin]'), isTrue);
      expect(isLikelyBatchVideoRelease('第01-12话 合集'), isTrue);
    });

    test('日期/分辨率/单集不误判', () {
      expect(
          isLikelyBatchVideoRelease('[SubsPlease] Show - 05 (1080p)'), isFalse);
      expect(isLikelyBatchVideoRelease('Show 2023-08 Special'), isFalse,
          reason: '裸日期区间没有 第/括号引导也没有话/集收尾');
      expect(isLikelyBatchVideoRelease('Show S01E05 720p'), isFalse);
    });
  });

  group('buildVideoResourceVersionGroups', () {
    List<VideoResourceCandidate> items() => <VideoResourceCandidate>[
          for (int ep = 1; ep <= 3; ep++)
            _FakeResource(
              remoteId: 'sp$ep',
              title: '[SubsPlease] Show - 0$ep (1080p) [ABCD123$ep]',
              releaseGroup: 'SubsPlease',
              resolution: '1080p',
              seeders: 10 * ep,
              publishedAt: DateTime.utc(2026, 8, ep),
            ),
          _FakeResource(
            remoteId: 'er1',
            title: '[Erai-raws] Show - 01 [720p]',
            releaseGroup: 'Erai-raws',
            resolution: '720p',
            seeders: 5,
            publishedAt: DateTime.utc(2026, 8, 10),
          ),
        ];

    test('同组同清晰度折一张卡；组间按最高做种数排序', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(items());
      expect(groups, hasLength(2));
      expect(groups.first.releaseGroup, 'SubsPlease',
          reason: 'bestSeeders 30 > 5');
      expect(groups.first.episodes, <int>{1, 2, 3});
      expect(groups.first.members.first.remoteId, 'sp1', reason: '卡内集号升序');
      expect(groups.first.representative.remoteId, 'sp3', reason: '代表条 = 做种最多');
      expect(groups.first.labelParts, contains('1080p'));
    });

    test('结构化字段缺失时从标题回退组名/清晰度', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(<VideoResourceCandidate>[
        _FakeResource(
          remoteId: 'a',
          title: '[VCB-Studio] Show - 01 [1080p]',
        ),
        _FakeResource(
          remoteId: 'b',
          title: '[VCB-Studio] Show - 02 [1080p]',
        ),
      ]);
      final VideoResourceVersionGroup group = groups.single;
      expect(group.releaseGroup, 'VCB-Studio');
      expect(group.resolution, '1080p');
    });
  });

  group('pickResourceVersionCandidate', () {
    test('指定集精确命中；未指定且多条 → null；单条 → 它', () {
      final VideoResourceVersionGroup group = buildVideoResourceVersionGroups(
        <VideoResourceCandidate>[
          _FakeResource(remoteId: 'a', title: '[G] S - 01 [1080p]', seeders: 3),
          _FakeResource(remoteId: 'b', title: '[G] S - 02 [1080p]', seeders: 9),
        ],
      ).single;
      expect(
        pickResourceVersionCandidate(group, episode: 2)!.remoteId,
        'b',
      );
      expect(pickResourceVersionCandidate(group, episode: 9), isNull);
      expect(pickResourceVersionCandidate(group), isNull);

      final VideoResourceVersionGroup single = buildVideoResourceVersionGroups(
        <VideoResourceCandidate>[
          _FakeResource(remoteId: 'm', title: '[G] Movie [1080p]'),
        ],
      ).single;
      expect(pickResourceVersionCandidate(single)!.remoteId, 'm');
    });
  });
}
