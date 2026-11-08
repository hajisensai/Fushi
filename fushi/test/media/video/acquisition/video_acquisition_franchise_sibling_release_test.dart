// BUG-4241：选「BanG Dream! ガルパ☆ピコ」（AniList 101632，2018）却入队了续作
// 《ガルパ☆ピコ ふぃーばー！》（2021）的 26 集，版本卡还把第二季《～大盛り～》的
// BD 包算进片源 / 每集体积。下面的发布名是 nyaa 上的原样标题，作品标题取 AniList
// 的原样 native / romaji / english。
import 'package:test/test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_work_match.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

int _nextId = 0;

class _Resource extends VideoResourceCandidate {
  _Resource(String title, {super.seeders = 10, super.sizeBytes})
    : super(
        remoteId: 'r${_nextId++}',
        title: title,
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        providerPriority: 100,
        trusted: false,
      );
}

VideoMediaReference _anime(
  int anilistId,
  String title, {
  required int year,
  String? originalTitle,
  List<String> aliases = const <String>[],
}) => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '$anilistId',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: title,
  originalTitle: originalTitle,
  aliases: aliases,
  year: year,
  anilistId: anilistId,
);

final VideoMediaReference _pico2018 = _anime(
  101632,
  'BanG Dream! ガルパ☆ピコ',
  year: 2018,
  aliases: const <String>[
    'BanG Dream! Garupa☆Pico',
    'BanG Dream! Girls Band Party!☆PICO',
    'Bandori',
  ],
);
final VideoMediaReference _ohmori2020 = _anime(
  113906,
  'BanG Dream! ガルパ☆ピコ~大盛り~',
  year: 2020,
  aliases: const <String>[
    'BanG Dream! Garupa☆Pico: Oomori',
    'BanG Dream! Girls Band Party!☆PICO～OHMORI～',
  ],
);
final VideoMediaReference _fever2021 = _anime(
  135171,
  'BanG Dream! ガルパ☆ピコ ふぃーばー！',
  year: 2021,
  aliases: const <String>[
    'BanG Dream! Garupa☆Pico Fever!',
    'BanG Dream! Girls Band Party!☆PICO FEVER!',
  ],
);
final VideoMediaReference _bangDream2017 = _anime(
  21687,
  'BanG Dream!',
  year: 2017,
  aliases: const <String>['バンドリ', 'Bandori'],
);
final VideoMediaReference _bangDream2nd = _anime(
  101633,
  'BanG Dream! 2nd Season',
  year: 2019,
);
final VideoMediaReference _myGo2023 = _anime(
  158028,
  "BanG Dream! It's MyGO!!!!!",
  year: 2023,
);

String _fever(int episode) =>
    '[喵萌Production&LoliHouse] BanG Dream! 少女乐团派对☆PICO FEVER! / '
    'Garupa Pico: Fever! - ${episode.toString().padLeft(2, '0')} '
    '[WebRip 1080p HEVC-10bit AAC][简繁内封字幕]';

const String _ohmoriBd =
    '[喵萌Production&LoliHouse] BanG Dream! 少女乐团派对!☆PICO～大盛～ / '
    'Garupa☆PICO～OHMORI～ [BDRip 1080p HEVC-10bit FLAC]';

String _pico(int episode) =>
    '[Owari Subs] BanG Dream! Garupa Pico - '
    '${episode.toString().padLeft(2, '0')} [1080p]';

VideoResourceWorkMismatch? _mismatch(
  String release,
  VideoMediaReference work,
  List<VideoMediaReference> siblings,
) => videoResourceWorkMismatch(
  release,
  VideoResourceWorkTarget.seriesFromReference(work, siblings: siblings),
);

void main() {
  const VideoAcquisitionDefaults defaults = VideoAcquisitionDefaults();

  group('兄弟作品判据', () {
    test('Pico 2018：Fever 逐集与大盛 BD 包判为兄弟作品', () {
      final List<VideoMediaReference> siblings = <VideoMediaReference>[
        _ohmori2020,
        _fever2021,
      ];
      expect(
        _mismatch(_fever(1), _pico2018, siblings),
        VideoResourceWorkMismatch.sibling,
      );
      expect(
        _mismatch(_fever(26), _pico2018, siblings),
        VideoResourceWorkMismatch.sibling,
      );
      expect(
        _mismatch(_ohmoriBd, _pico2018, siblings),
        VideoResourceWorkMismatch.sibling,
      );
    });

    test('Pico 2018 自己的发布（含中文标题写法）不误杀', () {
      final List<VideoMediaReference> siblings = <VideoMediaReference>[
        _ohmori2020,
        _fever2021,
        // 兄弟带目标没有的中文别名：目标自己的中文发布不能因此被判成兄弟。
        _anime(
          21687,
          'BanG Dream!',
          year: 2017,
          aliases: const <String>['BanG Dream! 少女乐团派对'],
        ),
      ];
      expect(_mismatch(_pico(5), _pico2018, siblings), isNull);
      expect(
        _mismatch(
          '[喵萌Production&LoliHouse] BanG Dream! 少女乐团派对☆PICO - 05 '
          '[WebRip 1080p HEVC-10bit AAC]',
          _pico2018,
          siblings,
        ),
        isNull,
      );
    });

    test('BanG Dream! 第一季：MyGO 的发布是兄弟，Season 01 / S1 写法不误杀', () {
      final List<VideoMediaReference> siblings = <VideoMediaReference>[
        _bangDream2nd,
        _myGo2023,
      ];
      expect(
        _mismatch(
          "[DKB] BanG Dream! It's MyGO!!!!! - 01 [1080p][HEVC]",
          _bangDream2017,
          siblings,
        ),
        VideoResourceWorkMismatch.sibling,
      );
      expect(
        _mismatch(
          'BanG Dream! Season 01 - 05 [1080p]',
          _bangDream2017,
          siblings,
        ),
        isNull,
      );
      expect(
        _mismatch(
          '[Group] BanG Dream! S1 [BDRip 1080p]',
          _bangDream2017,
          siblings,
        ),
        isNull,
      );
      expect(
        _mismatch('[Group] BanG Dream! - 05 [1080p]', _bangDream2017, siblings),
        isNull,
      );
    });

    test('MyGO：兄弟「BanG Dream!」与「FILM LIVE」没有区分词，不误杀 MyGO 的发布', () {
      expect(
        _mismatch(
          "[DKB] BanG Dream! It's MyGO!!!!! - 01 [1080p][HEVC]",
          _myGo2023,
          <VideoMediaReference>[
            _bangDream2017,
            _anime(100000, 'BanG Dream! FILM LIVE', year: 2019),
          ],
        ),
        isNull,
      );
    });

    test('反方向：目标是续作时，写全了基础作标题、没写续作词的发布判为基础作', () {
      expect(
        _mismatch(_pico(5), _fever2021, <VideoMediaReference>[
          _pico2018,
          _ohmori2020,
        ]),
        VideoResourceWorkMismatch.sibling,
      );
      expect(
        _mismatch(_pico(5), _ohmori2020, <VideoMediaReference>[
          _pico2018,
          _fever2021,
        ]),
        VideoResourceWorkMismatch.sibling,
      );
      expect(
        _mismatch(_fever(3), _fever2021, <VideoMediaReference>[
          _pico2018,
          _ohmori2020,
        ]),
        isNull,
      );
      expect(
        _mismatch(_ohmoriBd, _ohmori2020, <VideoMediaReference>[
          _pico2018,
          _fever2021,
        ]),
        isNull,
      );
    });

    test('反方向不误杀：发布写了季号，或带兄弟标题解释不了的中文译名', () {
      final List<VideoMediaReference> siblings = <VideoMediaReference>[
        _bangDream2017,
      ];
      expect(
        _mismatch(
          '[X] BanG Dream! 迷途之子!!!!! - 01 [1080p]',
          _myGo2023,
          siblings,
        ),
        isNull,
      );
      expect(
        _mismatch('[X] BanG Dream! S1 - 05 [1080p]', _myGo2023, siblings),
        isNull,
      );
      expect(
        _mismatch('[X] BanG Dream! - 05 [1080p]', _myGo2023, siblings),
        VideoResourceWorkMismatch.sibling,
      );
      // 与兄弟只差季号（2nd Season）时没有目标独有词，交给季号判据。
      expect(
        _mismatch('[X] BanG Dream! - 05 [1080p]', _bangDream2nd, siblings),
        isNull,
      );
    });

    test('与目标可能是同一部的条目（同 id / 同年同类型）不当兄弟', () {
      final VideoMediaReference sameWorkOtherSource = VideoMediaReference(
        providerId: 'tmdb',
        mediaId: '80000',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: '少女乐团派对☆PICO',
        year: 2018,
      );
      expect(
        videoResourceSiblingTitles(_pico2018, <VideoMediaReference>[
          sameWorkOtherSource,
          _pico2018,
          _fever2021,
        ]),
        hasLength(1),
      );
    });
  });

  group('单作品路径', () {
    test('作品搜索的其它候选记成兄弟，剧集资源也按兄弟排除', () {
      VideoAcquisitionState state = const VideoAcquisitionState(
        stage: VideoAcquisitionStage.resolvingWork,
      );
      for (final VideoAcquisitionEvent event in <VideoAcquisitionEvent>[
        VideoAcquisitionWorksLoadedEvent(
          query: 'Garupa Pico',
          items: <VideoDiscoveryItem>[
            VideoDiscoveryItem(reference: _pico2018),
            VideoDiscoveryItem(reference: _ohmori2020),
            VideoDiscoveryItem(reference: _fever2021),
          ],
        ),
        const VideoAcquisitionIdentityDecidedEvent(null),
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.work,
          optionId: '0',
        ),
      ]) {
        state = reduceVideoAcquisition(state, event, defaults).$1;
      }
      expect(state.chosenItem?.reference.mediaId, '101632');
      expect(
        state.siblingWorks.map((VideoMediaReference r) => r.mediaId),
        <String>['113906', '135171'],
      );

      final VideoAcquisitionState resolving = state.copyWith(
        stage: VideoAcquisitionStage.resolvingResources,
        slots: state.slots.copyWith(
          mode: VideoAcquisitionMode.download,
          quality: VideoAcquisitionQuality.best,
        ),
      );
      final VideoAcquisitionState loaded = reduceVideoAcquisition(
        resolving,
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          for (int e = 1; e <= 26; e++) _Resource(_fever(e), seeders: 5),
          _Resource(_ohmoriBd, seeders: 40),
          for (int e = 1; e <= 26; e++) _Resource(_pico(e), seeders: 4),
        ]),
        defaults,
      ).$1;
      final List<String> titles = <String>[
        for (final VideoResourceVersionGroup group in loaded.groups)
          for (final VideoResourceCandidate member in group.members)
            member.title,
      ];
      expect(titles, hasLength(26));
      expect(titles.every((String t) => t.contains('Owari Subs')), isTrue);
    });
  });

  group('系列路径（planFranchiseEntry）', () {
    final List<VideoResourceCandidate> mixed = <VideoResourceCandidate>[
      for (int e = 1; e <= 26; e++) _Resource(_fever(e), seeders: 5),
      _Resource(_ohmoriBd, seeders: 40),
      for (int e = 1; e <= 26; e++) _Resource(_pico(e), seeders: 4),
    ];

    VideoAcquisitionFranchiseEntry plan(
      VideoMediaReference work,
      List<VideoMediaReference> siblings,
    ) => planFranchiseEntry(
      VideoAcquisitionFranchiseEntry(item: VideoDiscoveryItem(reference: work)),
      VideoAcquisitionFranchiseEntryResolvedEvent(
        index: 0,
        work: VideoMetadataWork(
          provider: VideoMetadataProviderKind.tmdb,
          kind: VideoMetadataMediaKind.tv,
          title: work.title,
          status: 'Ended',
        ),
        items: mixed,
      ),
      quality: VideoAcquisitionQuality.best,
      defaults: defaults,
      siblings: siblings,
    );

    test('Pico 2018 只拿到自己的 26 集，没有 Fever / 大盛的种子', () {
      final VideoAcquisitionFranchiseEntry entry = plan(
        _pico2018,
        <VideoMediaReference>[_ohmori2020, _fever2021],
      );
      expect(entry.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(entry.plan!.picks, hasLength(26));
      expect(
        entry.plan!.picks.every(
          (VideoResourceCandidate c) => c.title.contains('Owari Subs'),
        ),
        isTrue,
      );
    });

    test('Fever 条目拿到 Fever 的 26 集（不混进 Pico 的逐集）', () {
      final VideoAcquisitionFranchiseEntry entry = plan(
        _fever2021,
        <VideoMediaReference>[_pico2018, _ohmori2020],
      );
      expect(entry.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(entry.plan!.picks, hasLength(26));
      expect(
        entry.plan!.picks.every(
          (VideoResourceCandidate c) => c.title.contains('FEVER'),
        ),
        isTrue,
      );
    });

    test('大盛条目不拿 Pico / Fever 的发布（没写 batch 的 BD 包不当全集，见 BUG-4241 剩余缺口）', () {
      final VideoAcquisitionFranchiseEntry entry = plan(
        _ohmori2020,
        <VideoMediaReference>[_pico2018, _fever2021],
      );
      expect(entry.status, VideoAcquisitionFranchiseEntryStatus.noResource);
      expect(entry.plan, isNull);
    });
  });

  group('版本分组', () {
    test('同组同 1080p 的 BDRip 无集号包与 WebRip 逐集分成两张卡', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(<VideoResourceCandidate>[
            for (int e = 1; e <= 3; e++)
              _Resource(_fever(e), seeders: 5, sizeBytes: 150000000),
            _Resource(_ohmoriBd, seeders: 40, sizeBytes: 6000000000),
          ]);
      expect(groups, hasLength(2));
      final VideoResourceVersionGroup episodes = groups.firstWhere(
        (VideoResourceVersionGroup g) => !g.wholeRelease,
      );
      expect(episodes.members, hasLength(3));
      expect(videoResourceSourceTag(episodes), 'WEBRip');
      expect(estimatedBytesPerEpisode(episodes), 150000000);
      final VideoResourceVersionGroup whole = groups.firstWhere(
        (VideoResourceVersionGroup g) => g.wholeRelease,
      );
      expect(whole.members.single.title, _ohmoriBd);
      expect(videoResourceSourceTag(whole), 'BD');
    });
  });
}
