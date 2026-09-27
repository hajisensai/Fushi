// 「AI 下视频」整套下载 + 操作条 / 再下一部 / 版本直选 / 只下最新一集。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi/src/media/video/discovery/video_franchise.dart';

class _Resource extends VideoResourceCandidate {
  _Resource({
    required super.remoteId,
    required super.title,
    super.releaseGroup,
    super.seeders = 10,
  }) : super(
         resolution: '1080p',
         providerId: 'nyaa',
         providerInstanceId: 'nyaa',
         providerPriority: 100,
         trusted: true,
       );
}

class _Session {
  _Session(this.defaults);

  final VideoAcquisitionDefaults defaults;
  VideoAcquisitionState state = const VideoAcquisitionState();

  List<VideoAcquisitionEffect> feed(VideoAcquisitionEvent event) {
    final (VideoAcquisitionState next, List<VideoAcquisitionEffect> effects) =
        reduceVideoAcquisition(state, event, defaults);
    state = next;
    return effects;
  }

  List<VideoAcquisitionSayKind> get said => <VideoAcquisitionSayKind>[
    for (final VideoAcquisitionMessage message in state.transcript)
      if (message is VideoAcquisitionAssistantMessage) message.say.kind,
  ];

  List<String> get optionIds => <String>[
    for (final VideoAcquisitionOption option in state.question!.options)
      option.id,
  ];
}

const VideoAcquisitionDefaults _defaults = VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 7, label: 'Anime'),
  ],
);

VideoDiscoveryItem _work({
  required String id,
  required String title,
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  int? year,
  String? status,
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'tmdb',
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    year: year,
  ),
  metadataWork: VideoMetadataWork(
    provider: VideoMetadataProviderKind.tmdb,
    kind: kind,
    title: title,
    status: status,
  ),
);

final VideoDiscoveryItem _show = _work(
  id: 'tv1',
  title: 'Doraemon',
  year: 2005,
  status: 'Currently Airing',
);
final VideoDiscoveryItem _movie1980 = _work(
  id: 'm1',
  title: 'Nobita no Kyouryuu',
  kind: VideoMetadataMediaKind.movie,
  year: 1980,
);
final VideoDiscoveryItem _movie2006 = _work(
  id: 'm2',
  title: 'Nobita no Kyouryuu 2006',
  kind: VideoMetadataMediaKind.movie,
  year: 2006,
);

VideoAcquisitionAiIntentEvent _provide(VideoAcquisitionIntentPatch patch) =>
    VideoAcquisitionAiIntentEvent(
      VideoAcquisitionIntent(VideoAcquisitionIntentKind.provide, patch),
      utterance: 'Doraemon',
    );

/// 说「哆啦A梦所有剧场版」走到找系列那一步。
List<VideoAcquisitionEffect> _reachFranchise(
  _Session s, {
  VideoAcquisitionScope scope = VideoAcquisitionScope.franchiseMovies,
}) {
  s.feed(const VideoAcquisitionUserTextEvent('Doraemon movies'));
  s.feed(
    _provide(
      VideoAcquisitionIntentPatch(
        workQueries: const <String>['Doraemon'],
        scope: scope,
      ),
    ),
  );
  s.feed(
    VideoAcquisitionWorksLoadedEvent(
      query: 'Doraemon',
      items: <VideoDiscoveryItem>[_show],
    ),
  );
  return s.feed(VideoAcquisitionDetailsLoadedEvent(work: _show.metadataWork));
}

VideoFranchise get _franchise => VideoFranchise(
  name: 'Doraemon',
  series: <VideoDiscoveryItem>[_show],
  movies: <VideoDiscoveryItem>[_movie1980, _movie2006],
);

void main() {
  group('整套下载', () {
    test('说「所有剧场版」→ 不问模式 / 季，槽位齐了去找系列', () {
      final _Session s = _Session(_defaults);
      final List<VideoAcquisitionEffect> effects = _reachFranchise(s);
      expect(s.state.stage, VideoAcquisitionStage.resolvingFranchise);
      expect(effects.single, isA<VideoAcquisitionLoadFranchiseEffect>());
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseSearching));
      expect(s.said, isNot(contains(VideoAcquisitionSayKind.question)));
    });

    test('范围 movies 只收剧场版，逐部串行找资源', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(_franchise),
      );
      expect(s.state.stage, VideoAcquisitionStage.planningFranchise);
      expect(
        s.state.franchiseEntries.map(
          (VideoAcquisitionFranchiseEntry e) => e.item.reference.mediaId,
        ),
        <String>['m1', 'm2'],
      );
      final VideoAcquisitionResolveFranchiseEntryEffect first =
          effects.single as VideoAcquisitionResolveFranchiseEntryEffect;
      expect(first.index, 0);
      expect(first.item.reference.mediaId, 'm1');
    });

    test('同名重制版按年份排除：1980 那部不会下成 2006 的', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      final List<VideoAcquisitionEffect> next = s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'r2006',
              title: '[G] Nobita no Kyouryuu (2006) [1080p]',
              releaseGroup: 'G',
              seeders: 99,
            ),
            _Resource(
              remoteId: 'r1980',
              title: '[G] Nobita no Kyouryuu (1980) [1080p]',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      final VideoAcquisitionFranchiseEntry entry = s.state.franchiseEntries[0];
      expect(entry.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(entry.mode, VideoAcquisitionMode.download);
      expect(entry.plan!.picks.single.remoteId, 'r1980');
      expect(
        (next.single as VideoAcquisitionResolveFranchiseEntryEffect).index,
        1,
      );
    });

    test('在播剧集自动订阅；完结剧集下载；没资源的行不勾', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s, scope: VideoAcquisitionScope.franchise);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      expect(s.state.franchiseEntries.first.item.reference.mediaId, 'tv1');
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          work: VideoMetadataWork(
            provider: VideoMetadataProviderKind.tmdb,
            kind: VideoMetadataMediaKind.tv,
            title: 'Doraemon',
            status: 'Returning Series',
          ),
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'e1',
              title: '[G] Doraemon - 801 (1080p)',
              releaseGroup: 'G',
            ),
            _Resource(
              remoteId: 'e2',
              title: '[G] Doraemon - 802 (1080p)',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      final VideoAcquisitionFranchiseEntry series = s.state.franchiseEntries[0];
      expect(series.mode, VideoAcquisitionMode.subscribe);
      expect(series.plan!.filter, isNotNull);
      expect(series.selected, isTrue);

      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 1,
          presence: const VideoLibraryPresence(
            workId: 42,
            managedEpisodeKeys: <String>{},
          ),
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'r1980',
              title: '[G] Nobita no Kyouryuu (1980) [1080p]',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      expect(s.state.franchiseEntries[1].owned, isTrue);
      expect(s.state.franchiseEntries[1].selected, isFalse);

      s.feed(const VideoAcquisitionFranchiseEntryResolvedEvent(index: 2));
      expect(
        s.state.franchiseEntries[2].status,
        VideoAcquisitionFranchiseEntryStatus.noResource,
      );
      expect(s.state.stage, VideoAcquisitionStage.awaitingFranchiseConfirm);
      expect(s.said.last, VideoAcquisitionSayKind.question);
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseReady));
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionSubmitAll,
        kVideoAcquisitionOptionCancel,
      ]);
    });

    test('勾选 → 提交只带可提交的行，字幕语言统一写', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      for (int i = 0; i < 2; i++) {
        s.feed(
          VideoAcquisitionFranchiseEntryResolvedEvent(
            index: i,
            items: <VideoResourceCandidate>[
              _Resource(
                remoteId: 'r$i',
                title: i == 0
                    ? '[G] Nobita no Kyouryuu (1980) [1080p]'
                    : '[G] Nobita no Kyouryuu (2006) [1080p]',
                releaseGroup: 'G',
              ),
            ],
          ),
        );
      }
      s.feed(const VideoAcquisitionFranchiseEntryToggledEvent(1));
      expect(s.state.franchiseEntries[1].selected, isFalse);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.franchise,
          optionId: kVideoAcquisitionOptionSubmitAll,
        ),
      );
      final VideoAcquisitionSubmitFranchiseEffect submit =
          effects.single as VideoAcquisitionSubmitFranchiseEffect;
      expect(submit.entries.single.item.reference.mediaId, 'm1');
      expect(submit.targetSourceId, 7);
      expect(submit.subtitleLanguageCode, 'ja');

      final List<VideoAcquisitionEffect> done = s.feed(
        const VideoAcquisitionFranchiseSubmittedEvent(
          downloads: 1,
          subscriptions: 0,
          failed: 0,
        ),
      );
      expect(done.single, isA<VideoAcquisitionCloseEffect>());
      expect(s.state.stage, VideoAcquisitionStage.done);
      expect(s.said.last, VideoAcquisitionSayKind.franchiseSubmitted);
    });

    test('同一颗种子只归一部：前一部已选的发布不再给后一部', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      final _Resource pack = _Resource(
        remoteId: 'pack',
        title: '[G] Doraemon Movie Pack [1080p]',
        releaseGroup: 'G',
      );
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[pack],
        ),
      );
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 1,
          items: <VideoResourceCandidate>[pack],
        ),
      );
      expect(
        s.state.franchiseEntries[0].status,
        VideoAcquisitionFranchiseEntryStatus.ready,
      );
      expect(
        s.state.franchiseEntries[1].status,
        VideoAcquisitionFranchiseEntryStatus.noResource,
      );
    });

    test('同名剧集按年份分开：1979 那部不拿写着 2005 的发布', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s, scope: VideoAcquisitionScope.franchiseSeries);
      final VideoDiscoveryItem old = _work(
        id: 'tv0',
        title: 'Doraemon',
        year: 1979,
        status: 'Ended',
      );
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[old, _show],
            movies: const <VideoDiscoveryItem>[],
          ),
        ),
      );
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'new',
              title: '[G] Doraemon (2005) - 01 (1080p)',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      expect(
        s.state.franchiseEntries[0].status,
        VideoAcquisitionFranchiseEntryStatus.noResource,
      );
    });

    test('提交在飞时取消不生效；清单态打字「确认」= 全部提交', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'r',
              title: '[G] Nobita no Kyouryuu (1980) [1080p]',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      s.feed(const VideoAcquisitionFranchiseEntryResolvedEvent(index: 1));
      s.feed(const VideoAcquisitionUserTextEvent('好的'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.confirm,
            VideoAcquisitionIntentPatch(),
          ),
          utterance: '好的',
        ),
      );
      expect(effects.single, isA<VideoAcquisitionSubmitFranchiseEffect>());
      expect(s.state.stage, VideoAcquisitionStage.submitting);
      expect(s.feed(const VideoAcquisitionCancelEvent()), isEmpty);
      expect(s.state.stage, VideoAcquisitionStage.submitting);
    });

    test('一部都没勾就提交 → 说明原因并留在清单', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      s.feed(const VideoAcquisitionFranchiseEntryResolvedEvent(index: 0));
      s.feed(const VideoAcquisitionFranchiseEntryResolvedEvent(index: 1));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.franchise,
          optionId: kVideoAcquisitionOptionSubmitAll,
        ),
      );
      expect(effects, isEmpty);
      expect(s.state.stage, VideoAcquisitionStage.awaitingFranchiseConfirm);
      expect(s.state.question!.slot, VideoAcquisitionSlot.franchise);
    });

    test('提交失败（整批）→ 回到清单再问', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      s.feed(
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[
            _Resource(
              remoteId: 'r',
              title: '[G] Nobita no Kyouryuu (1980) [1080p]',
              releaseGroup: 'G',
            ),
          ],
        ),
      );
      s.feed(const VideoAcquisitionFranchiseEntryResolvedEvent(index: 1));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.franchise,
          optionId: kVideoAcquisitionOptionSubmitAll,
        ),
      );
      s.feed(const VideoAcquisitionFailedEvent('backend down'));
      expect(s.state.stage, VideoAcquisitionStage.awaitingFranchiseConfirm);
      expect(s.state.question!.slot, VideoAcquisitionSlot.franchise);
      expect(s.state.franchiseEntries, hasLength(2));
    });

    test('系列里只有它自己 → 说一声按单部继续', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s, scope: VideoAcquisitionScope.franchise);
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: const <VideoDiscoveryItem>[],
          ),
        ),
      );
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseNotFound));
      expect(s.state.slots.scope, VideoAcquisitionScope.work);
      // 单部流程：在播剧集要问下载还是订阅。
      expect(effects, isEmpty);
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
    });

    test('没有系列来源（null）同样退回单部', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(const VideoAcquisitionFranchiseLoadedEvent(null));
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseNotFound));
      expect(s.state.slots.scope, VideoAcquisitionScope.work);
    });
  });

  group('作品操作条', () {
    test('选定作品后常驻：换一部 + 三种系列范围；点「整个系列」直接去找', () {
      final _Session s = _Session(_defaults);
      s.feed(const VideoAcquisitionUserTextEvent('Doraemon'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Doraemon']),
        ),
      );
      s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Doraemon',
          items: <VideoDiscoveryItem>[_show],
        ),
      );
      s.feed(VideoAcquisitionDetailsLoadedEvent(work: _show.metadataWork));
      // 在播剧集：停在「下载还是订阅」。
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
      expect(videoAcquisitionWorkActions(s.state), <String>[
        kVideoAcquisitionOptionNone,
        '${kVideoAcquisitionOptionScopePrefix}all',
        '${kVideoAcquisitionOptionScopePrefix}movies',
        '${kVideoAcquisitionOptionScopePrefix}series',
      ]);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.work,
          optionId: '${kVideoAcquisitionOptionScopePrefix}all',
        ),
      );
      expect(effects.single, isA<VideoAcquisitionLoadFranchiseEffect>());
      expect(s.state.slots.scope, VideoAcquisitionScope.franchise);
    });

    test('忙着的时候 / 还没选作品时不显示', () {
      expect(
        videoAcquisitionWorkActions(const VideoAcquisitionState()),
        isEmpty,
      );
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      expect(s.state.busy, isTrue);
      expect(videoAcquisitionWorkActions(s.state), isEmpty);
    });
  });

  group('再下一部', () {
    test('完成后打字直接开始下一部，保留对话与通用偏好', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(const VideoAcquisitionCancelEvent());
      expect(s.state.stage, VideoAcquisitionStage.cancelled);
      final int before = s.state.transcript.length;
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionUserTextEvent('Conan'),
      );
      expect(effects.single, isA<VideoAcquisitionParseIntentEffect>());
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.state.transcript.length, before + 1);
      expect(s.state.slots.targetSourceId, 7);
      expect(s.state.slots.scope, VideoAcquisitionScope.work);
      expect(s.state.franchiseEntries, isEmpty);
    });

    test('RestartEvent 回到开场白', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(const VideoAcquisitionCancelEvent());
      s.feed(const VideoAcquisitionRestartEvent());
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.said.last, VideoAcquisitionSayKind.greeting);
    });
  });

  group('版本卡', () {
    VideoAcquisitionState presented(_Session s) {
      final VideoDiscoveryItem finished = _work(
        id: 'f',
        title: 'Show',
        status: 'Finished Airing',
      );
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[finished],
        ),
      );
      s.feed(VideoAcquisitionDetailsLoadedEvent(work: finished.metadataWork));
      s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          for (final String group in <String>['A', 'B', 'C'])
            for (int episode = 1; episode <= 3; episode++)
              _Resource(
                remoteId: '$group$episode',
                title: '[$group] Show - 0$episode (1080p)',
                releaseGroup: group,
              ),
        ]),
      );
      return s.state;
    }

    test('其它版本直接列成 chip；点了就用它提交', () {
      final _Session s = _Session(_defaults);
      presented(s);
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionConfirm,
        '${kVideoAcquisitionOptionAltPrefix}1',
        '${kVideoAcquisitionOptionAltPrefix}2',
        kVideoAcquisitionOptionLatest,
        kVideoAcquisitionOptionNext,
        kVideoAcquisitionOptionCancel,
      ]);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: '${kVideoAcquisitionOptionAltPrefix}2',
        ),
      );
      final VideoAcquisitionSubmitDownloadEffect submit = effects
          .whereType<VideoAcquisitionSubmitDownloadEffect>()
          .single;
      expect(submit.plan.group.releaseGroup, 'C');
    });

    test('只下最新一集 → 计划收成最大集号那一条；「全部」撤销', () {
      final _Session s = _Session(_defaults);
      presented(s);
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionLatest,
        ),
      );
      expect(s.state.plan!.picks.single.remoteId, 'A3');
      expect(s.optionIds, isNot(contains(kVideoAcquisitionOptionLatest)));
      expect(s.optionIds, contains(kVideoAcquisitionOptionAll));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionAll,
        ),
      );
      expect(s.state.plan!.picks, hasLength(3));
      expect(s.state.slots.episodes, isA<VideoAcquisitionAllEpisodes>());
    });
  });

  group('候选清洗', () {
    test('跳过特典时丢掉只有特典的发布', () {
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _Resource(remoteId: 'op', title: '[G] Show - NCOP (1080p)'),
        _Resource(remoteId: 'ep', title: '[G] Show - 01 (1080p)'),
      ];
      expect(
        cleanResourceCandidates(
          items,
          skipExtras: true,
        ).map((VideoResourceCandidate c) => c.remoteId),
        <String>['ep'],
      );
      expect(cleanResourceCandidates(items, skipExtras: false), hasLength(2));
    });

    test('年份冲突：写了别的年份才丢，没写年份照留，±1 容忍', () {
      expect(releaseYearConflicts('Movie (2006) [1080p]', 1980), isTrue);
      expect(releaseYearConflicts('Movie (1981) [1080p]', 1980), isFalse);
      expect(releaseYearConflicts('Movie [1080p] x265', 1980), isFalse);
      expect(releaseYearConflicts('Movie 1920x1080', 1980), isFalse);
    });
  });
}
