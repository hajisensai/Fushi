// 「AI 下视频」全集计划：标题认不出的 BD 整包按需取种子文件列表作整包证据
// （反馈 rCT8Ms0AIe）。单作品流程打 reducer，整套下载打 service + 假端口。
import 'package:test/test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/download/video_release_scope_evidence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

class _Resource extends VideoResourceCandidate {
  _Resource(String id, String title, {int seeders = 10})
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'site',
        providerPriority: 100,
        remoteId: id,
        title: title,
        resolution: '1080p',
        trusted: true,
        seeders: seeders,
      );
}

const String _bdPack = '[Grp] Show [BDRip 1080p HEVC-10bit FLAC]';
const String _special = '[Grp] Show Special [BDRip 1080p HEVC-10bit FLAC]';

VideoReleaseManifest _seasonFiles() => VideoReleaseManifest(<String>[
  for (int i = 1; i <= 12; i++)
    'Show/[Grp] Show - ${i.toString().padLeft(2, '0')} [BDRip 1080p].mkv',
  'Show/Fonts/font.otf',
]);

VideoReleaseManifest _specialFiles() =>
    VideoReleaseManifest(<String>['[Grp] Show Special [BDRip 1080p].mkv']);

VideoDiscoveryItem _work(
  String id,
  String title,
  VideoMetadataMediaKind kind, {
  String status = 'Finished Airing',
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'mal',
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
  ),
  metadataWork: VideoMetadataWork(
    provider: VideoMetadataProviderKind.mal,
    kind: kind,
    title: title,
    status: status,
    episodeCount: 12,
  ),
);

const VideoAcquisitionDefaults _defaults = VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 7, label: 'Anime'),
  ],
);

class _Session {
  VideoAcquisitionState state = const VideoAcquisitionState();

  List<VideoAcquisitionEffect> feed(VideoAcquisitionEvent event) {
    final (VideoAcquisitionState next, List<VideoAcquisitionEffect> effects) =
        reduceVideoAcquisition(state, event, _defaults);
    state = next;
    return effects;
  }

  /// 走到资源搜索效果发出（已完结剧集 → 下载全部集）。
  void reachResources() {
    final VideoDiscoveryItem item = _work(
      '1',
      'Show',
      VideoMetadataMediaKind.tv,
    );
    feed(const VideoAcquisitionUserTextEvent('Show'));
    feed(
      const VideoAcquisitionAiIntentEvent(
        VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
        utterance: 'Show',
      ),
    );
    feed(
      VideoAcquisitionWorksLoadedEvent(
        query: 'Show',
        items: <VideoDiscoveryItem>[item],
      ),
    );
    final List<VideoAcquisitionEffect> effects = feed(
      VideoAcquisitionDetailsLoadedEvent(work: item.metadataWork),
    );
    expect(effects.single, isA<VideoAcquisitionSearchResourcesEffect>());
    expect(state.slots.mode, VideoAcquisitionMode.download);
    expect(state.slots.episodes, isA<VideoAcquisitionAllEpisodes>());
  }

  VideoAcquisitionSay get lastSay =>
      state.transcript.whereType<VideoAcquisitionAssistantMessage>().last.say;
}

void main() {
  group('单作品「全集」', () {
    test('没写 batch 的 BD 包：先取文件列表，证成整包后给出整包计划', () {
      final _Session s = _Session()..reachResources();
      final _Resource pack = _Resource('bd', _bdPack);
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[pack]),
      );
      final VideoAcquisitionInspectReleasesEffect inspect =
          effects.single as VideoAcquisitionInspectReleasesEffect;
      expect(
        inspect.targets.map((VideoResourceCandidate c) => c.remoteId),
        <String>['bd'],
      );
      expect(inspect.franchiseIndex, isNull);
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
      expect(s.state.busy, isTrue);

      final List<VideoAcquisitionEffect> after = s.feed(
        VideoAcquisitionReleasesInspectedEvent(
          manifests: <String, VideoReleaseManifest?>{
            pack.identityKey: _seasonFiles(),
          },
        ),
      );
      expect(after, isEmpty);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(s.state.plan!.usesBatch, isTrue);
      expect(s.state.plan!.picks.single.remoteId, 'bd');
    });

    test('反例：「Show Special」文件列表只有一个视频 → 不当全集，给不出计划', () {
      final _Session s = _Session()..reachResources();
      final _Resource special = _Resource('sp', _special);
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[special]),
      );
      expect(effects.single, isA<VideoAcquisitionInspectReleasesEffect>());
      final List<VideoAcquisitionEffect> after = s.feed(
        VideoAcquisitionReleasesInspectedEvent(
          manifests: <String, VideoReleaseManifest?>{
            special.identityKey: _specialFiles(),
          },
        ),
      );
      expect(after, isEmpty, reason: '取过的不再取');
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.lastSay.kind, VideoAcquisitionSayKind.failed);
      expect(
        s.lastSay.args['message'],
        kVideoAcquisitionFailureNoPlannableVersion,
      );
    });

    test('拿不到文件列表（只有磁链的索引器）→ 维持保守，不重取、不当全集', () {
      final _Session s = _Session()..reachResources();
      final _Resource pack = _Resource('bd', _bdPack);
      s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[pack]),
      );
      final List<VideoAcquisitionEffect> after = s.feed(
        VideoAcquisitionReleasesInspectedEvent(
          manifests: <String, VideoReleaseManifest?>{pack.identityKey: null},
        ),
      );
      expect(after, isEmpty);
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(
        s.lastSay.args['message'],
        kVideoAcquisitionFailureNoPlannableVersion,
      );
    });

    test('第一张能落地的卡已是写明合集的整包 → 不取文件列表', () {
      final _Session s = _Session()..reachResources();
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          _Resource('batch', '[Grp] Show (01-12) [1080p] Batch', seeders: 50),
          _Resource('bd', '[Other] Show [BDRip 1080p HEVC-10bit FLAC]'),
        ]),
      );
      expect(effects, isEmpty);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(s.state.plan!.picks.single.remoteId, 'batch');
    });
  });

  group('整套下载', () {
    Future<VideoAcquisitionService> run(
      Map<String, List<VideoResourceCandidate>> resources,
      Map<String, VideoReleaseManifest?> manifests,
      List<String> inspected,
    ) async {
      final VideoDiscoveryItem show = _work(
        'tv',
        'Show',
        VideoMetadataMediaKind.tv,
      );
      final VideoAcquisitionService service = VideoAcquisitionService(
        defaults: _defaults,
        ports: VideoAcquisitionPorts(
          searchWorks: (_) async =>
              ProviderBatchResult<VideoDiscoveryPage>.success(
                <VideoDiscoveryPage>[
                  VideoDiscoveryPage(
                    items: <VideoDiscoveryItem>[show],
                    page: 1,
                    hasMore: false,
                  ),
                ],
              ),
          loadDetails: (VideoDiscoveryItem item) async => item.metadataWork,
          loadFranchise: (_) async => VideoFranchise(
            name: 'Show',
            series: <VideoDiscoveryItem>[show],
            // 只有一部时退回单作品流程；带一部剧场版让它走整套清单。
            movies: <VideoDiscoveryItem>[
              _work('movie', 'Show the Movie', VideoMetadataMediaKind.movie),
            ],
          ),
          queryPresence: (_) async => VideoLibraryPresence.none,
          isSubscribed: (_) async => false,
          searchResources: (VideoResourceSearchRequest request) async =>
              ProviderBatchResult<VideoResourceCandidate>.success(
                resources[request.media?.mediaId] ??
                    const <VideoResourceCandidate>[],
              ),
          inspectRelease: (VideoResourceCandidate candidate) async {
            inspected.add(candidate.remoteId);
            if (candidate.remoteId == 'boom') throw StateError('HTTP 503');
            return manifests[candidate.remoteId];
          },
          parseIntent: (_) async => const VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(
              workQueries: <String>['Show'],
              scope: VideoAcquisitionScope.franchise,
            ),
          ),
          decideIdentity: (_) async => null,
          persistPreference: (_, _) async {},
          setSeriesSubtitleLanguage: (_, _) async {},
          submitDownload: (_) async => (queued: 1, alreadyQueued: 0),
          submitSubscription: (_) async {},
        ),
      );
      addTearDown(service.dispose);
      await service.submitText('Show 整套');
      expect(
        service.state.stage,
        VideoAcquisitionStage.awaitingFranchiseConfirm,
      );
      return service;
    }

    test('没写 batch 的 BD 包：取文件列表后这一部从「无资源」变成整包下载', () async {
      final List<String> inspected = <String>[];
      final VideoAcquisitionService service = await run(
        <String, List<VideoResourceCandidate>>{
          'tv': <VideoResourceCandidate>[_Resource('bd', _bdPack)],
        },
        <String, VideoReleaseManifest?>{'bd': _seasonFiles()},
        inspected,
      );
      expect(inspected, <String>['bd']);
      final VideoAcquisitionFranchiseEntry entry =
          service.state.franchiseEntries.first;
      expect(entry.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(entry.mode, VideoAcquisitionMode.download);
      expect(entry.plan!.usesBatch, isTrue);
      expect(entry.plan!.picks.single.remoteId, 'bd');
    });

    test('反例：「Show Special」单视频 → 仍是无资源；取失败只少一份证据', () async {
      final List<String> inspected = <String>[];
      final VideoAcquisitionService service = await run(
        <String, List<VideoResourceCandidate>>{
          'tv': <VideoResourceCandidate>[
            _Resource('sp', _special, seeders: 20),
            _Resource('boom', '[Grp2] Show [BDRip 1080p HEVC-10bit FLAC]'),
          ],
        },
        <String, VideoReleaseManifest?>{'sp': _specialFiles()},
        inspected,
      );
      expect(inspected, unorderedEquals(<String>['sp', 'boom']));
      expect(
        service.state.franchiseEntries.first.status,
        VideoAcquisitionFranchiseEntryStatus.noResource,
      );
    });
  });
}
