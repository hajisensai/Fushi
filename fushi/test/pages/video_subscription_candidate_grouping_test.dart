import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';

/// 用户报障：订阅页搜一部番，列表里是同一个字幕组同一分辨率的十几集，一集一
/// 行，「重复的数据太多了」。根子是**列表行单位 ≠ 订阅生效单位**。
///
/// 这里钉死聚合语义，尤其是「分组键必须是 filter.json 本身」——自己另写一个
/// 「releaseGroup + resolution」的键看着等价，但会漏掉 nyaa 的 trusted、
/// torznab 的 source/codec/language，把本该分开的两条规则合成一行。
class _Candidate extends VideoResourceCandidate {
  _Candidate({
    required super.title,
    super.providerId = 'nyaa',
    super.providerInstanceId = 'nyaa.si',
    String? remoteId,
    super.providerPriority = 0,
    super.seeders = 0,
    super.publishedAt,
    super.resolution = '1080p',
    super.releaseGroup = 'Erai-raws',
    super.trusted = true,
    super.category = '1_2',
  }) : super(remoteId: remoteId ?? title);
}

void main() {
  DateTime day(int d) => DateTime.utc(2026, 4, d);

  test('同一字幕组同一分辨率的多集聚合成一行，集数区间正确', () {
    final List<VideoSubscriptionCandidateGroup> groups =
        groupVideoSubscriptionCandidates(<VideoResourceCandidate>[
      _Candidate(
          title: '[Erai-raws] Show - 01 [1080p]',
          seeders: 10,
          publishedAt: day(1)),
      _Candidate(
          title: '[Erai-raws] Show - 02 [1080p]',
          seeders: 30,
          publishedAt: day(2)),
      _Candidate(
          title: '[Erai-raws] Show - 04 [1080p]',
          seeders: 20,
          publishedAt: day(4)),
    ]);

    expect(groups, hasLength(1), reason: '三集同规则必须只占一行');
    expect(groups.single.memberCount, 3);
    expect(groups.single.episodeNumbers, <int>[1, 2, 4]);
    expect(groups.single.latestPublishedAt, day(4));
    expect(groups.single.representative.seeders, 30, reason: '代表条取做种最多的那条');
  });

  test('trusted 不同必须分成两行——这正是「自己发明分组键」会合错的地方', () {
    final List<VideoSubscriptionCandidateGroup> groups =
        groupVideoSubscriptionCandidates(<VideoResourceCandidate>[
      _Candidate(title: '[Erai-raws] Show - 01 [1080p]', trusted: true),
      _Candidate(title: '[Erai-raws] Show - 02 [1080p]', trusted: false),
    ]);

    expect(groups, hasLength(2),
        reason: 'nyaa 的 filter 锁 trusted，两条订起来不是同一条规则；'
            '按「releaseGroup + resolution」分组会错误合并。');
  });

  test('分辨率不同、字幕组不同各自成行', () {
    final List<VideoSubscriptionCandidateGroup> groups =
        groupVideoSubscriptionCandidates(<VideoResourceCandidate>[
      _Candidate(
          title: 'A - 01', resolution: '1080p', releaseGroup: 'Erai-raws'),
      _Candidate(
          title: 'B - 01', resolution: '720p', releaseGroup: 'Erai-raws'),
      _Candidate(
          title: 'C - 01', resolution: '1080p', releaseGroup: 'SubsPlease'),
    ]);
    expect(groups, hasLength(3));
  });

  test('推不出订阅规则的条目不聚合、各占一行，且排在可订阅的后面', () {
    final List<VideoSubscriptionCandidateGroup> groups =
        groupVideoSubscriptionCandidates(<VideoResourceCandidate>[
      // nyaa 缺 releaseGroup -> deriveStrictVideoSubscriptionFilter 返回 null
      _Candidate(title: 'raw upload 1', releaseGroup: null, resolution: null),
      _Candidate(title: '[Erai-raws] Show - 01 [1080p]'),
      _Candidate(title: 'raw upload 2', releaseGroup: null, resolution: null),
    ]);

    expect(groups, hasLength(3));
    expect(groups.first.filter, isNotNull, reason: '可订阅的排前面');
    expect(groups[1].filter, isNull);
    expect(groups[2].filter, isNull);
    expect(
        groups.where((VideoSubscriptionCandidateGroup g) => g.filter == null),
        hasLength(2),
        reason: '两条不可订阅的必须各占一行，不能被并成一坨——'
            '并起来只会让「为什么订不了」更难看懂');
  });

  test('聚合保持来源顺序，且代表条选择是全序（同一输入渲染两次结果一致）', () {
    final List<VideoResourceCandidate> input = <VideoResourceCandidate>[
      _Candidate(title: 'B - 01', releaseGroup: 'Bbb', seeders: 5),
      _Candidate(title: 'A - 01', releaseGroup: 'Aaa', seeders: 5),
      _Candidate(title: 'B - 02', releaseGroup: 'Bbb', seeders: 5),
    ];
    final List<VideoSubscriptionCandidateGroup> first =
        groupVideoSubscriptionCandidates(input);
    final List<VideoSubscriptionCandidateGroup> second =
        groupVideoSubscriptionCandidates(input);

    expect(first.map((VideoSubscriptionCandidateGroup g) => g.filter!.json),
        second.map((VideoSubscriptionCandidateGroup g) => g.filter!.json));
    expect(first.first.representative.releaseGroup, 'Bbb',
        reason: '首次出现序决定行序，聚合不得让列表跳动');
    // seeders 全并列时靠标题字典序定代表条，两次必须一致。
    expect(first.first.representative.title, second.first.representative.title);
  });
}
