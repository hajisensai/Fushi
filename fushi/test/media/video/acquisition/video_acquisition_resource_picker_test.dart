// AI 下视频：资源选择层的确定性规则（画质过滤 / 订阅可行性 / 下载选集）。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

class _FakeCandidate extends VideoResourceCandidate {
  _FakeCandidate({
    required super.remoteId,
    required super.title,
    super.providerId = 'nyaa',
    super.providerInstanceId = 'nyaa',
    super.providerPriority = 100,
    super.releaseGroup,
    super.resolution,
    super.trusted,
    super.seeders,
  });
}

int _nextId = 0;

/// 逐集发布：`[Group] Show - 05 (1080p)`。
_FakeCandidate _episode(
  String group,
  String resolution,
  int episode, {
  int seeders = 10,
  bool trusted = true,
  String? releaseGroup = '',
}) => _FakeCandidate(
  remoteId: 'r${_nextId++}',
  title: '[$group] Show - ${episode.toString().padLeft(2, '0')} ($resolution)',
  releaseGroup: releaseGroup == '' ? group : releaseGroup,
  resolution: resolution,
  trusted: trusted,
  seeders: seeders,
);

/// 整季合集：`[Group] Show (01-12) (Batch) (1080p)`。
_FakeCandidate _batch(
  String group,
  String resolution, {
  int seeders = 10,
  String marker = '(01-12) (Batch)',
}) => _FakeCandidate(
  remoteId: 'r${_nextId++}',
  title: '[$group] Show $marker ($resolution)',
  releaseGroup: group,
  resolution: resolution,
  trusted: true,
  seeders: seeders,
);

List<VideoResourceVersionGroup> _groupsOf(List<VideoResourceCandidate> items) =>
    buildVideoResourceVersionGroups(items);

VideoResourceVersionGroup _single(List<VideoResourceCandidate> items) {
  final List<VideoResourceVersionGroup> groups = _groupsOf(items);
  expect(groups, hasLength(1), reason: '测试素材应落进同一张版本卡');
  return groups.single;
}

List<String?> _groupNames(List<VideoResourceVersionGroup> groups) => <String?>[
  for (final VideoResourceVersionGroup group in groups) group.releaseGroup,
];

List<String> _titles(VideoAcquisitionResourcePlan plan) => <String>[
  for (final VideoResourceCandidate pick in plan.picks) pick.title,
];

void main() {
  group('filterResourceGroups', () {
    final List<VideoResourceVersionGroup> mixed =
        _groupsOf(<VideoResourceCandidate>[
          _episode('SubsPlease', '1080p', 1, seeders: 50),
          _episode('SubsPlease', '720p', 1, seeders: 40),
          _episode('Erai-raws', '1080P', 1, seeders: 30),
          _episode('Judas', '480p', 1, seeders: 20),
          _episode('Ohys', 'HD', 1, seeders: 5),
        ]);

    test('精确画质只留该档，保持输入顺序；大小写不敏感', () {
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        mixed,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.ok);
      expect(_groupNames(outcome.eligible), <String>[
        'SubsPlease',
        'Erai-raws',
      ]);
      expect(outcome.eligible.first.resolution, '1080p');
      expect(outcome.eligible.last.resolution, '1080P');
    });

    test('any 不过滤', () {
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        mixed,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.any,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.ok);
      expect(outcome.eligible, hasLength(mixed.length));
      expect(_groupNames(outcome.eligible), _groupNames(mixed));
    });

    test('空结果 → noCandidates', () {
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        const <VideoResourceVersionGroup>[],
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.any,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.noCandidates);
      expect(outcome.eligible, isEmpty);
      expect(outcome.availableResolutions, isEmpty);
    });

    test('画质不命中 → resolutionMismatch，列出可用分辨率（去重、高度降序、未知殿后）', () {
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        mixed,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p2160,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.resolutionMismatch);
      expect(outcome.eligible, isEmpty);
      expect(outcome.availableResolutions, <String>[
        '1080p',
        '720p',
        '480p',
        'HD',
      ]);
    });

    test('订阅模式剔除推不出严格规则的卡（nyaa 缺发布组）', () {
      final List<VideoResourceVersionGroup> groups =
          _groupsOf(<VideoResourceCandidate>[
            _episode('Anon', '1080p', 1, seeders: 90, releaseGroup: null),
            _episode('SubsPlease', '1080p', 1, seeders: 50),
          ]);
      expect(groups, hasLength(2));
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.subscribe,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.ok);
      expect(_groupNames(outcome.eligible), <String>['SubsPlease']);
    });

    test('订阅模式一张都推不出 → noSubscribableVersion，仍带可用分辨率', () {
      final List<VideoResourceVersionGroup> groups =
          _groupsOf(<VideoResourceCandidate>[
            _episode('Anon', '1080p', 1, releaseGroup: null),
            _episode('Anon2', '720p', 1, releaseGroup: null),
          ]);
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.subscribe,
        quality: VideoAcquisitionQuality.any,
      );
      expect(
        outcome.reason,
        VideoAcquisitionResourceReason.noSubscribableVersion,
      );
      expect(outcome.eligible, isEmpty);
      expect(outcome.availableResolutions, <String>['1080p', '720p']);
    });

    test('下载模式不要求发布组', () {
      final List<VideoResourceVersionGroup> groups = _groupsOf(
        <VideoResourceCandidate>[
          _episode('Anon', '1080p', 1, releaseGroup: null),
        ],
      );
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(outcome.reason, VideoAcquisitionResourceReason.ok);
      expect(outcome.eligible, hasLength(1));
    });
  });

  group('planResourceFromGroup', () {
    test('movie → 代表条（做种最多）', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _FakeCandidate(
          remoteId: 'm1',
          title: '[G] Film (1080p) v1',
          releaseGroup: 'G',
          resolution: '1080p',
          seeders: 5,
        ),
        _FakeCandidate(
          remoteId: 'm2',
          title: '[G] Film (1080p) v2',
          releaseGroup: 'G',
          resolution: '1080p',
          seeders: 80,
        ),
      ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.download,
        kind: VideoMetadataMediaKind.movie,
        episodes: const VideoAcquisitionAllEpisodes(),
      );
      expect(plan, isNotNull);
      expect(_titles(plan!), <String>['[G] Film (1080p) v2']);
      expect(plan.usesBatch, isFalse);
      expect(plan.filter, isNull);
      expect(plan.startAfterEpisode, isNull);
      expect(plan.missingEpisodes, isEmpty);
    });

    test('tv All 有合集 → 只取做种最多的合集，usesBatch', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 1, seeders: 300),
        _episode('SubsPlease', '1080p', 2, seeders: 300),
        _batch('SubsPlease', '1080p', seeders: 50),
        _batch('SubsPlease', '1080p', seeders: 200, marker: '[01-12]'),
      ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.download,
        kind: VideoMetadataMediaKind.tv,
        episodes: const VideoAcquisitionAllEpisodes(),
      );
      expect(plan, isNotNull);
      expect(plan!.usesBatch, isTrue);
      expect(_titles(plan), <String>['[SubsPlease] Show [01-12] (1080p)']);
      expect(plan.missingEpisodes, isEmpty);
    });

    test('tv All 无合集 → 所有能解析出集号的成员，同集去重取做种最多，集号升序', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 3, seeders: 5),
        _episode('SubsPlease', '1080p', 1, seeders: 10),
        _episode('SubsPlease', '1080p', 3, seeders: 30),
        _episode('SubsPlease', '1080p', 2, seeders: 10),
      ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.download,
        kind: VideoMetadataMediaKind.tv,
        episodes: const VideoAcquisitionAllEpisodes(),
      );
      expect(plan, isNotNull);
      expect(plan!.usesBatch, isFalse);
      expect(plan.picks, hasLength(3));
      expect(
        plan.picks.map((VideoResourceCandidate p) => p.title).toList(),
        <String>[
          '[SubsPlease] Show - 01 (1080p)',
          '[SubsPlease] Show - 02 (1080p)',
          '[SubsPlease] Show - 03 (1080p)',
        ],
      );
      expect(plan.picks[2].seeders, 30, reason: '同集取做种最多的那条');
    });

    test('tv All 无合集且解析不出任何集号 → null', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _FakeCandidate(
          remoteId: 'x1',
          title: '[G] Show Special (1080p)',
          releaseGroup: 'G',
          resolution: '1080p',
        ),
      ]);
      expect(
        planResourceFromGroup(
          group,
          mode: VideoAcquisitionMode.download,
          kind: VideoMetadataMediaKind.tv,
          episodes: const VideoAcquisitionAllEpisodes(),
        ),
        isNull,
      );
    });

    test('Single(3) 命中取做种最多的那条；未命中 → null', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 3, seeders: 5),
        _episode('SubsPlease', '1080p', 3, seeders: 30),
        _episode('SubsPlease', '1080p', 4, seeders: 50),
      ]);
      final VideoAcquisitionResourcePlan? hit = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.download,
        kind: VideoMetadataMediaKind.tv,
        episodes: const VideoAcquisitionSingleEpisode(3),
      );
      expect(hit, isNotNull);
      expect(hit!.picks, hasLength(1));
      expect(hit.picks.single.seeders, 30);
      expect(hit.usesBatch, isFalse);
      expect(
        planResourceFromGroup(
          group,
          mode: VideoAcquisitionMode.download,
          kind: VideoMetadataMediaKind.tv,
          episodes: const VideoAcquisitionSingleEpisode(9),
        ),
        isNull,
      );
    });

    test('Range(2,5) 取范围内成员、同集去重，缺集升序进 missingEpisodes', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 1),
        _episode('SubsPlease', '1080p', 2),
        _episode('SubsPlease', '1080p', 3, seeders: 5),
        _episode('SubsPlease', '1080p', 3, seeders: 30),
        _episode('SubsPlease', '1080p', 5),
        _episode('SubsPlease', '1080p', 6),
      ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.download,
        kind: VideoMetadataMediaKind.tv,
        episodes: const VideoAcquisitionEpisodeRange(2, 5),
      );
      expect(plan, isNotNull);
      expect(_titles(plan!), <String>[
        '[SubsPlease] Show - 02 (1080p)',
        '[SubsPlease] Show - 03 (1080p)',
        '[SubsPlease] Show - 05 (1080p)',
      ]);
      expect(plan.picks[1].seeders, 30);
      expect(plan.missingEpisodes, <int>[4]);
      expect(plan.usesBatch, isFalse);
    });

    test('Range 一集都没有 → null', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 1),
      ]);
      expect(
        planResourceFromGroup(
          group,
          mode: VideoAcquisitionMode.download,
          kind: VideoMetadataMediaKind.tv,
          episodes: const VideoAcquisitionEpisodeRange(7, 9),
        ),
        isNull,
      );
    });

    test('订阅 → 严格规则 + 起点 = 最小集号 + 代表条单条', () {
      final VideoResourceVersionGroup group = _single(<VideoResourceCandidate>[
        _episode('SubsPlease', '1080p', 4, seeders: 10),
        _episode('SubsPlease', '1080p', 3, seeders: 90),
        _episode('SubsPlease', '1080p', 5, seeders: 20),
      ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        group,
        mode: VideoAcquisitionMode.subscribe,
        kind: VideoMetadataMediaKind.tv,
        episodes: const VideoAcquisitionAllEpisodes(),
      );
      expect(plan, isNotNull);
      expect(plan!.filter, isNotNull);
      expect(plan.filter!.releaseGroup, 'SubsPlease');
      expect(plan.filter!.resolution, '1080p');
      expect(plan.startAfterEpisode, 3);
      expect(plan.picks, hasLength(1));
      expect(plan.picks.single.seeders, 90, reason: '代表条 = 做种最多');
      expect(plan.usesBatch, isFalse);
    });

    test('订阅：推不出严格规则 → null；无集号 → startAfterEpisode 为 null', () {
      final VideoResourceVersionGroup ungroupable = _single(
        <VideoResourceCandidate>[
          _episode('Anon', '1080p', 1, releaseGroup: null),
        ],
      );
      expect(
        planResourceFromGroup(
          ungroupable,
          mode: VideoAcquisitionMode.subscribe,
          kind: VideoMetadataMediaKind.tv,
          episodes: const VideoAcquisitionAllEpisodes(),
        ),
        isNull,
      );
      final VideoResourceVersionGroup noEpisodes =
          _single(<VideoResourceCandidate>[
            _FakeCandidate(
              remoteId: 'f1',
              title: '[G] Film (1080p)',
              releaseGroup: 'G',
              resolution: '1080p',
            ),
          ]);
      final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
        noEpisodes,
        mode: VideoAcquisitionMode.subscribe,
        kind: VideoMetadataMediaKind.movie,
        episodes: const VideoAcquisitionAllEpisodes(),
      );
      expect(plan, isNotNull);
      expect(plan!.filter, isNotNull);
      expect(plan.startAfterEpisode, isNull);
    });
  });

  group('availableResolutionsOf', () {
    test('大小写不敏感去重、高度降序、解析不出的殿后按字面序', () {
      final List<VideoResourceVersionGroup> groups =
          _groupsOf(<VideoResourceCandidate>[
            _episode('A', '720p', 1),
            _episode('B', '1080P', 1),
            _episode('C', 'SD', 1),
            _episode('D', '1080p', 1),
            _episode('E', '2160p', 1),
            _episode('F', 'HD', 1),
          ]);
      expect(availableResolutionsOf(groups), <String>[
        '2160p',
        '1080P',
        '720p',
        'HD',
        'SD',
      ]);
    });

    test('无分辨率的卡被跳过', () {
      final List<VideoResourceVersionGroup> groups = _groupsOf(
        <VideoResourceCandidate>[
          _FakeCandidate(
            remoteId: 'n1',
            title: '[G] Show - 01',
            releaseGroup: 'G',
          ),
        ],
      );
      expect(availableResolutionsOf(groups), isEmpty);
    });
  });
}
