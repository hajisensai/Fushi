// 「AI 下视频」整套下载 + 操作条 / 再下一部 / 版本直选 / 只下最新一集。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';

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

    test('系列解析没走完（BUG-2935）：照常逐部找资源，但明说清单可能不全', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: const <VideoDiscoveryItem>[],
            movies: <VideoDiscoveryItem>[_movie1980, _movie2006],
            truncated: true,
          ),
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.planningFranchise);
      expect(
        effects.single,
        isA<VideoAcquisitionResolveFranchiseEntryEffect>(),
      );
      expect(
        s.said,
        containsAllInOrder(<VideoAcquisitionSayKind>[
          VideoAcquisitionSayKind.franchiseFound,
          VideoAcquisitionSayKind.franchiseTruncated,
        ]),
      );
    });

    test('系列走完了不提「可能不全」', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(VideoAcquisitionFranchiseLoadedEvent(_franchise));
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseFound));
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseTruncated)),
      );
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

    // BUG-2936：「全部哆啦A梦剧场版」资料源不可用时，旧逻辑静默改成单部、
    // 去下锚点那部 TV（1979 版 1700+ 集）——替用户下了别的东西。
    test('BUG-2936 系列来源不可用（null）→ 说明并问，不静默改下锚点', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionFranchiseLoadedEvent(null),
      );
      expect(effects, isEmpty);
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseUnavailable));
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseNotFound)),
      );
      expect(s.state.question!.slot, VideoAcquisitionSlot.franchiseFallback);
      expect(s.state.question!.args['title'], 'Doraemon');
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionContinue,
        kVideoAcquisitionOptionCancel,
      ]);
      // 用户还没答：范围仍是「剧场版」。
      expect(s.state.slots.scope, VideoAcquisitionScope.franchiseMovies);
      expect(s.state.busy, isFalse);
    });

    test('BUG-2936 要剧场版但系列里一部剧场版都没有 → 问，不拿 TV 锚点顶替', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: const <VideoDiscoveryItem>[],
          ),
        ),
      );
      // 清单完整，只是没有剧场版：不说「取不到」，直接问。
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseUnavailable)),
      );
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseNotFound)),
      );
      expect(s.state.question!.slot, VideoAcquisitionSlot.franchiseFallback);
      expect(s.state.slots.scope, VideoAcquisitionScope.franchiseMovies);
    });

    test('BUG-2936 问后选「继续」→ 按单部走；选「取消」→ 结束', () {
      final _Session go = _Session(_defaults);
      _reachFranchise(go);
      go.feed(const VideoAcquisitionFranchiseLoadedEvent(null));
      go.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.franchiseFallback,
          optionId: kVideoAcquisitionOptionContinue,
        ),
      );
      expect(go.state.slots.scope, VideoAcquisitionScope.work);
      // 单部流程：在播剧集要问下载还是订阅。
      expect(go.state.question!.slot, VideoAcquisitionSlot.mode);

      final _Session stop = _Session(_defaults);
      _reachFranchise(stop);
      stop.feed(const VideoAcquisitionFranchiseLoadedEvent(null));
      stop.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.franchiseFallback,
          optionId: kVideoAcquisitionOptionCancel,
        ),
      );
      expect(stop.said.last, VideoAcquisitionSayKind.cancelled);
    });

    test('BUG-2936 清单不全且只剩锚点 → 不能说「没有同系列」，要说取不到并问', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s, scope: VideoAcquisitionScope.franchise);
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: const <VideoDiscoveryItem>[],
            truncated: true,
          ),
        ),
      );
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseUnavailable));
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseNotFound)),
      );
      expect(s.state.question!.slot, VideoAcquisitionSlot.franchiseFallback);
    });
  });

  // BUG-2937：系列大到一批查不完时，分批续查直到走完，而不是在半张清单上开工。
  group('分批续查', () {
    final VideoDiscoveryItem malMovie = _work(
      id: 'm3',
      title: 'Nobita no Uchuu Kaitakushi',
      kind: VideoMetadataMediaKind.movie,
      year: 1981,
    );

    test('还有下一批 → 报进度、发续查效果，不开始逐部找资源', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      Future<VideoFranchise> rest() async => _franchise;
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: <VideoDiscoveryItem>[_movie1980],
            more: rest,
          ),
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.resolvingFranchise);
      expect(s.state.busy, isTrue);
      expect(s.state.franchiseEntries, isEmpty);
      final VideoAcquisitionContinueFranchiseEffect effect =
          effects.single as VideoAcquisitionContinueFranchiseEffect;
      expect(effect.more, same(rest));
      final VideoAcquisitionAssistantMessage progress =
          s.state.transcript.last as VideoAcquisitionAssistantMessage;
      expect(progress.say.kind, VideoAcquisitionSayKind.franchiseProgress);
      // 范围是「只要剧场版」：进度只数剧场版。
      expect(progress.say.args['movies'], 1);
      expect(progress.say.args['series'], 0);
      expect(s.state.franchiseDraft!.more, isNull, reason: '草稿不留用过的入口');
      expect(s.said, isNot(contains(VideoAcquisitionSayKind.franchiseFound)));
    });

    test('最后一批回来 → 与已收到的合并去重后出清单', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      // 第一批：TMDB 的剧场版 + MAL 第一批。
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: <VideoDiscoveryItem>[_movie1980, _movie2006],
            more: () async => _franchise,
          ),
        ),
      );
      // 最后一批（MAL 到目前为止的全部）：与第一批重叠一部、新增一部。
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'ドラえもん',
            series: <VideoDiscoveryItem>[_show],
            movies: <VideoDiscoveryItem>[_movie1980, malMovie],
          ),
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.planningFranchise);
      expect(
        s.state.franchiseEntries.map(
          (VideoAcquisitionFranchiseEntry e) => e.item.reference.mediaId,
        ),
        <String>['m1', 'm3', 'm2'],
      );
      // 系列名取第一批的（TMDB collection 名在前）。
      expect(s.state.franchiseName, 'Doraemon');
      expect(s.state.franchiseDraft, isNull);
      expect(
        effects.single,
        isA<VideoAcquisitionResolveFranchiseEntryEffect>(),
      );
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.franchiseTruncated)),
      );
    });

    test('续查失败（空的 truncated 批）→ 交出已收到的并说清单不全', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: <VideoDiscoveryItem>[_movie1980, _movie2006],
            more: () async => _franchise,
          ),
        ),
      );
      s.feed(
        const VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: '',
            series: <VideoDiscoveryItem>[],
            movies: <VideoDiscoveryItem>[],
            truncated: true,
          ),
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.planningFranchise);
      expect(s.state.franchiseEntries, hasLength(2));
      expect(s.said, contains(VideoAcquisitionSayKind.franchiseTruncated));
    });

    test('续查途中取消 → 迟到的批次被丢弃', () {
      final _Session s = _Session(_defaults);
      _reachFranchise(s);
      s.feed(
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'Doraemon',
            series: <VideoDiscoveryItem>[_show],
            movies: <VideoDiscoveryItem>[_movie1980],
            more: () async => _franchise,
          ),
        ),
      );
      s.feed(const VideoAcquisitionCancelEvent());
      final VideoAcquisitionStage cancelled = s.state.stage;
      expect(cancelled, isNot(VideoAcquisitionStage.resolvingFranchise));
      final List<VideoAcquisitionEffect> late = s.feed(
        VideoAcquisitionFranchiseLoadedEvent(_franchise),
      );
      expect(late, isEmpty);
      expect(s.state.stage, cancelled);
      expect(s.state.franchiseEntries, isEmpty);
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
