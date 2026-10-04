// 「AI 下视频」整套下载的编排：找系列 → 逐部找资源 → 在播的订阅、完结的下载 →
// 逐部提交（单部失败不拖垮其余）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';

class _Resource extends VideoResourceCandidate {
  _Resource(String id, String title)
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        providerPriority: 100,
        remoteId: id,
        title: title,
        releaseGroup: 'G',
        resolution: '1080p',
        trusted: true,
        seeders: 10,
      );
}

VideoDiscoveryItem _work(
  String id,
  String title,
  VideoMetadataMediaKind kind, {
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

void main() {
  test('整套：在播剧集建订阅、剧场版入队下载，单部失败只计数', () async {
    final VideoDiscoveryItem show = _work(
      'tv',
      'Doraemon',
      VideoMetadataMediaKind.tv,
      year: 2005,
      status: 'Returning Series',
    );
    final VideoDiscoveryItem movieA = _work(
      'a',
      'Movie A',
      VideoMetadataMediaKind.movie,
      year: 1980,
    );
    final VideoDiscoveryItem movieB = _work(
      'b',
      'Movie B',
      VideoMetadataMediaKind.movie,
      year: 1981,
    );
    final List<String> calls = <String>[];
    final Map<String, List<VideoResourceCandidate>> resources =
        <String, List<VideoResourceCandidate>>{
          'tv': <VideoResourceCandidate>[
            _Resource('e1', '[G] Doraemon - 01 (1080p)'),
            _Resource('e2', '[G] Doraemon - 02 (1080p)'),
          ],
          'a': <VideoResourceCandidate>[
            _Resource('ra', '[G] Movie A (1980) [1080p]'),
          ],
          'b': <VideoResourceCandidate>[
            _Resource('rb', '[G] Movie B (1981) [1080p]'),
          ],
        };
    final VideoAcquisitionService service = VideoAcquisitionService(
      defaults: const VideoAcquisitionDefaults(
        qualityPref: '1080p',
        subtitleLanguagePref: 'ja',
        sources: <VideoAcquisitionSource>[
          VideoAcquisitionSource(id: 7, label: 'Anime'),
        ],
      ),
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
        loadDetails: (VideoDiscoveryItem item) async {
          calls.add('details:${item.reference.mediaId}');
          return item.metadataWork;
        },
        loadFranchise: (_) async => VideoFranchise(
          name: 'Doraemon',
          series: <VideoDiscoveryItem>[show],
          movies: <VideoDiscoveryItem>[movieA, movieB],
        ),
        queryPresence: (_) async => VideoLibraryPresence.none,
        isSubscribed: (_) async => false,
        searchResources: (VideoResourceSearchRequest request) async =>
            ProviderBatchResult<VideoResourceCandidate>.success(
              resources[request.media?.mediaId] ??
                  const <VideoResourceCandidate>[],
            ),
        parseIntent: (_) async => const VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(
            workQueries: <String>['Doraemon'],
            scope: VideoAcquisitionScope.franchise,
          ),
        ),
        decideIdentity: (_) async => null,
        persistPreference: (_, _) async {},
        setSeriesSubtitleLanguage:
            (VideoMediaReference reference, String code) async =>
                calls.add('lang:${reference.mediaId}=$code'),
        submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
          if (effect.item.reference.mediaId == 'b') {
            throw StateError('torrent rejected');
          }
          calls.add('download:${effect.item.reference.mediaId}');
          return effect.plan.picks.length;
        },
        submitSubscription:
            (VideoAcquisitionSubmitSubscriptionEffect effect) async =>
                calls.add('subscribe:${effect.item.reference.mediaId}'),
      ),
    );
    addTearDown(service.dispose);

    await service.submitText('哆啦A梦 整套');
    expect(service.state.stage, VideoAcquisitionStage.awaitingFranchiseConfirm);
    expect(
      service.state.franchiseEntries.map(
        (VideoAcquisitionFranchiseEntry e) => e.mode,
      ),
      <VideoAcquisitionMode>[
        VideoAcquisitionMode.subscribe,
        VideoAcquisitionMode.download,
        VideoAcquisitionMode.download,
      ],
    );
    // 只有剧集拉详情（定下载还是订阅），电影不拉。
    expect(
      calls.where((String c) => c.startsWith('details:')),
      <String>['details:tv', 'details:tv'],
      reason: '锚点在选定作品时拉一次、清单里再拉一次；电影一次都不拉',
    );

    await service.choose(
      VideoAcquisitionSlot.franchise,
      kVideoAcquisitionOptionSubmitAll,
    );
    expect(service.state.stage, VideoAcquisitionStage.done);
    expect(
      calls,
      containsAllInOrder(<String>[
        'lang:tv=ja',
        'subscribe:tv',
        'lang:a=ja',
        'download:a',
      ]),
    );
    final VideoAcquisitionAssistantMessage last = service.state.transcript
        .whereType<VideoAcquisitionAssistantMessage>()
        .last;
    expect(last.say.kind, VideoAcquisitionSayKind.franchiseSubmitted);
    expect(last.say.args, <String, Object?>{
      'downloads': 1,
      'subscriptions': 1,
      'failed': 1,
    });
  });

  test('找系列在飞时取消立即生效；结果回来被丢弃，不再发下一步', () async {
    final VideoDiscoveryItem show = _work(
      'tv',
      'Doraemon',
      VideoMetadataMediaKind.tv,
      year: 2005,
      status: 'Returning Series',
    );
    final Completer<VideoFranchise?> franchise = Completer<VideoFranchise?>();
    int resourceSearches = 0;
    final VideoAcquisitionService service = VideoAcquisitionService(
      defaults: const VideoAcquisitionDefaults(
        qualityPref: '1080p',
        subtitleLanguagePref: 'ja',
        sources: <VideoAcquisitionSource>[
          VideoAcquisitionSource(id: 7, label: 'Anime'),
        ],
      ),
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
        loadFranchise: (_) => franchise.future,
        queryPresence: (_) async => VideoLibraryPresence.none,
        isSubscribed: (_) async => false,
        searchResources: (_) async {
          resourceSearches++;
          return ProviderBatchResult<VideoResourceCandidate>.success(
            const <VideoResourceCandidate>[],
          );
        },
        parseIntent: (_) async => const VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(
            workQueries: <String>['Doraemon'],
            scope: VideoAcquisitionScope.franchise,
          ),
        ),
        decideIdentity: (_) async => null,
        persistPreference: (_, _) async {},
        setSeriesSubtitleLanguage: (_, _) async {},
        submitDownload: (_) async => 0,
        submitSubscription: (_) async {},
      ),
    );
    addTearDown(service.dispose);

    final Future<void> running = service.submitText('哆啦A梦 整套');
    await pumpEventQueue();
    expect(service.state.stage, VideoAcquisitionStage.resolvingFranchise);
    await service.cancel();
    expect(service.state.stage, VideoAcquisitionStage.cancelled);

    franchise.complete(
      VideoFranchise(
        name: 'Doraemon',
        series: <VideoDiscoveryItem>[show],
        movies: <VideoDiscoveryItem>[
          _work('a', 'Movie A', VideoMetadataMediaKind.movie, year: 1980),
        ],
      ),
    );
    await running;
    expect(service.state.stage, VideoAcquisitionStage.cancelled);
    expect(resourceSearches, 0);
  });

  // BUG-2937：系列分批查完——服务执行续查效果，直到最后一批才出清单。
  group('分批续查', () {
    final VideoDiscoveryItem show = _work(
      'tv',
      'Doraemon',
      VideoMetadataMediaKind.tv,
      year: 2005,
      status: 'Ended',
    );
    final VideoDiscoveryItem movieA = _work(
      'a',
      'Movie A',
      VideoMetadataMediaKind.movie,
      year: 1980,
    );
    final VideoDiscoveryItem movieB = _work(
      'b',
      'Movie B',
      VideoMetadataMediaKind.movie,
      year: 2018,
    );

    VideoAcquisitionService build(
      Future<VideoFranchise?> Function(VideoDiscoveryItem item) loadFranchise,
    ) {
      final VideoAcquisitionService service = VideoAcquisitionService(
        defaults: const VideoAcquisitionDefaults(
          qualityPref: '1080p',
          subtitleLanguagePref: 'ja',
          sources: <VideoAcquisitionSource>[
            VideoAcquisitionSource(id: 7, label: 'Anime'),
          ],
        ),
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
          loadFranchise: loadFranchise,
          queryPresence: (_) async => VideoLibraryPresence.none,
          isSubscribed: (_) async => false,
          searchResources: (_) async =>
              ProviderBatchResult<VideoResourceCandidate>.success(
                const <VideoResourceCandidate>[],
              ),
          parseIntent: (_) async => const VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(
              workQueries: <String>['Doraemon'],
              scope: VideoAcquisitionScope.franchiseMovies,
            ),
          ),
          decideIdentity: (_) async => null,
          persistPreference: (_, _) async {},
          setSeriesSubtitleLanguage: (_, _) async {},
          submitDownload: (_) async => 0,
          submitSubscription: (_) async {},
        ),
      );
      addTearDown(service.dispose);
      return service;
    }

    List<VideoAcquisitionSayKind> said(
      VideoAcquisitionService service,
    ) => <VideoAcquisitionSayKind>[
      for (final VideoAcquisitionMessage message in service.state.transcript)
        if (message is VideoAcquisitionAssistantMessage) message.say.kind,
    ];

    test('第一批带续查入口 → 服务接着查，最后一批才出清单', () async {
      int continued = 0;
      final VideoAcquisitionService service = build(
        (_) async => VideoFranchise(
          name: 'Doraemon',
          series: <VideoDiscoveryItem>[show],
          movies: <VideoDiscoveryItem>[movieA],
          more: () async {
            continued++;
            return VideoFranchise(
              name: 'Doraemon',
              series: <VideoDiscoveryItem>[show],
              movies: <VideoDiscoveryItem>[movieA, movieB],
            );
          },
        ),
      );
      await service.submitText('全部哆啦A梦剧场版');
      expect(continued, 1);
      expect(
        service.state.stage,
        VideoAcquisitionStage.awaitingFranchiseConfirm,
      );
      expect(
        service.state.franchiseEntries.map(
          (VideoAcquisitionFranchiseEntry e) => e.item.reference.mediaId,
        ),
        <String>['a', 'b'],
      );
      final List<VideoAcquisitionSayKind> kinds = said(service);
      expect(
        kinds.indexOf(VideoAcquisitionSayKind.franchiseProgress),
        lessThan(kinds.indexOf(VideoAcquisitionSayKind.franchiseFound)),
      );
      expect(
        kinds,
        isNot(contains(VideoAcquisitionSayKind.franchiseTruncated)),
      );
    });

    test('续查抛异常 → 交出已收到的，说清单不全，会话不卡在找系列', () async {
      final VideoAcquisitionService service = build(
        (_) async => VideoFranchise(
          name: 'Doraemon',
          series: <VideoDiscoveryItem>[show],
          movies: <VideoDiscoveryItem>[movieA],
          more: () async => throw StateError('jikan 503'),
        ),
      );
      await service.submitText('全部哆啦A梦剧场版');
      expect(
        service.state.stage,
        VideoAcquisitionStage.awaitingFranchiseConfirm,
      );
      expect(service.state.franchiseEntries, hasLength(1));
      expect(
        said(service),
        contains(VideoAcquisitionSayKind.franchiseTruncated),
      );
    });
  });
}
