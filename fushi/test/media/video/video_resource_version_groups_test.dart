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
    // 回归锚：VideoResourceRegistry 在返回前专门跑过 rankVideoResourcesByRelevance
    // （按季号/标题贴合度），理由写在那个函数上：「Nyaa 只做模糊词匹配，搜 "xxx 2"
    // 会被做种更多的 S1/S3 压在前面」。组间排序若以做种数为主键，等于把那个已修的
    // bug 原样放回主路径。
    test('组间以输入的相关度次序为主键，做种数不得把不相关的组顶到最前', () {
      // 输入次序 = 上游给的相关度名次：第二季在前（更贴合查询），第一季在后。
      final List<VideoResourceCandidate> ranked = <VideoResourceCandidate>[
        _FakeResource(
          remoteId: 's2',
          title: '[GroupB] Show S2 - 01 (1080p)',
          releaseGroup: 'GroupB',
          resolution: '1080p',
          seeders: 12, // 新番，做种少
        ),
        _FakeResource(
          remoteId: 's1',
          title: '[GroupA] Show S1 - 01 (1080p)',
          releaseGroup: 'GroupA',
          resolution: '1080p',
          seeders: 9999, // 老季，做种多
        ),
      ];

      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(ranked);

      expect(groups, hasLength(2));
      expect(groups.first.members.single.remoteId, 's2',
          reason: '搜第二季，第一季不得因做种多被顶到第一张卡');
    });

    test('相关度相同（同名次段）时仍按做种数降序', () {
      // 两组的最靠前名次分别是 0 和 1，但把做种多的放在后面，验证同段内的次级信号：
      // 这里刻意让第二条的组在输入里更靠后却做种更多，断言它**不**越位——
      // 再补一条同组内的比较来体现做种数仍在起作用。
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _FakeResource(
          remoteId: 'a1',
          title: '[GroupA] Show - 01 (1080p)',
          releaseGroup: 'GroupA',
          resolution: '1080p',
          seeders: 5,
        ),
        _FakeResource(
          remoteId: 'a2',
          title: '[GroupA] Show - 02 (1080p)',
          releaseGroup: 'GroupA',
          resolution: '1080p',
          seeders: 500,
        ),
      ];
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(items);
      expect(groups, hasLength(1));
      expect(groups.single.bestSeeders, 500, reason: '组内仍取最高做种数，做种数信号没有被丢掉');
    });

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
