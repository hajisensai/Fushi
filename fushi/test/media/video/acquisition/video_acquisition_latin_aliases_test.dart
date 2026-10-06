// BUG-2854：「AI 下视频」搜资源必须用详情补齐了罗马字 / 英文名的作品身份。
//
// 实测形状（2026-10-02，nyaa.si）：TMDB 搜索项只有日文原名 `FX戦士くるみちゃん`
// 与 JP 区风格化别名 `FX Senshi KURUMICHAN`，两个在 Nyaa 都是 0 条；详情里的
// 英文名 `FX Fighter Kurumi-chan` 有 9 条。修前 AI 流程只拿搜索项身份去搜，
// 报「这部作品没搜到任何资源」，而资源搜索页（经别名补齐端口）能搜到。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/media/video/download/video_discovery_submit.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

const String _japanese = 'FX戦士くるみちゃん';
const String _styled = 'FX Senshi KURUMICHAN';
const String _english = 'FX Fighter Kurumi-chan';

class _Resource extends VideoResourceCandidate {
  _Resource(String id, String title)
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        providerPriority: 100,
        remoteId: id,
        title: title,
        releaseGroup: 'ToonsHub',
        resolution: '1080p',
        trusted: true,
        seeders: 10,
      );
}

/// TMDB 搜索列表项的形状：只有原名与风格化别名，没有详情。
VideoDiscoveryItem _searchItem({
  String id = '311842',
  String title = _japanese,
  List<String> aliases = const <String>[_styled],
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'tmdb',
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    originalTitle: title,
    aliases: aliases,
  ),
);

/// 详情：罗马字取的是同一个风格化写法，英文名才是发布组用的拼写。
VideoMetadataWork _details({
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  String? romaji = _styled,
}) => VideoMetadataWork(
  provider: VideoMetadataProviderKind.tmdb,
  kind: kind,
  title: _japanese,
  romajiTitle: romaji,
  englishTitle: _english,
  status: 'Returning Series',
  episodeCount: 12,
);

/// 与生产同口径算 Nyaa 实际要发的查询词。
List<String> _nyaaQueries(VideoMediaReference reference) => nyaaSearchQueries(
  VideoResourceSearchRequest(
    media: reference,
    query: videoResourceSubscriptionSearchQuery(reference),
  ),
);

const VideoAcquisitionDefaults _defaults = VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 7, label: 'Anime'),
  ],
);

void main() {
  test('前提：只用搜索项身份时 Nyaa 查询词里没有可命中的拼写', () {
    expect(_nyaaQueries(_searchItem().reference), <String>[_styled, _japanese]);
  });

  test('单作品：详情到达后，搜资源的身份带上详情的英文名', () {
    VideoAcquisitionState state = const VideoAcquisitionState();
    List<VideoAcquisitionEffect> feed(VideoAcquisitionEvent event) {
      final (VideoAcquisitionState next, List<VideoAcquisitionEffect> fx) =
          reduceVideoAcquisition(state, event, _defaults);
      state = next;
      return fx;
    }

    feed(const VideoAcquisitionUserTextEvent('fx战士'));
    feed(
      const VideoAcquisitionAiIntentEvent(
        VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(
            workQueries: <String>['fx战士'],
            mode: VideoAcquisitionMode.download,
          ),
        ),
        utterance: 'fx战士',
      ),
    );
    final List<VideoAcquisitionEffect> load = feed(
      VideoAcquisitionWorksLoadedEvent(
        query: 'fx战士',
        items: <VideoDiscoveryItem>[_searchItem()],
      ),
    );
    expect(load.single, isA<VideoAcquisitionLoadDetailsEffect>());
    final List<VideoAcquisitionEffect> effects = feed(
      VideoAcquisitionDetailsLoadedEvent(work: _details()),
    );

    expect(state.stage, VideoAcquisitionStage.resolvingResources);
    final VideoMediaReference searched =
        (effects.single as VideoAcquisitionSearchResourcesEffect).reference;
    expect(searched.aliases, contains(_english));
    expect(_nyaaQueries(searched), contains(_english));
    // 提交（下载 / 订阅）用的也是这份身份。
    expect(state.reference!.aliases, contains(_english));
    // 其它身份字段不变。
    expect(searched.mediaId, '311842');
    expect(searched.title, _japanese);
  });

  test('单作品：没有详情时身份原样', () {
    VideoAcquisitionState state = const VideoAcquisitionState();
    for (final VideoAcquisitionEvent event in <VideoAcquisitionEvent>[
      const VideoAcquisitionUserTextEvent('x'),
      const VideoAcquisitionAiIntentEvent(
        VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(
            workQueries: <String>['x'],
            mode: VideoAcquisitionMode.download,
          ),
        ),
        utterance: 'x',
      ),
      VideoAcquisitionWorksLoadedEvent(
        query: 'x',
        items: <VideoDiscoveryItem>[_searchItem()],
      ),
      const VideoAcquisitionDetailsLoadedEvent(),
    ]) {
      state = reduceVideoAcquisition(state, event, _defaults).$1;
    }
    expect(state.reference!.aliases, <String>[_styled]);
  });

  test('整套计划：条目身份补上详情的英文名（订阅检索词 / 身份同源）', () {
    final VideoAcquisitionFranchiseEntry planned = planFranchiseEntry(
      VideoAcquisitionFranchiseEntry(item: _searchItem()),
      VideoAcquisitionFranchiseEntryResolvedEvent(
        index: 0,
        work: _details(),
        items: <VideoResourceCandidate>[
          _Resource('e1', '[ToonsHub] $_english S01E01 1080p'),
        ],
      ),
      quality: VideoAcquisitionQuality.best,
      defaults: _defaults,
    );
    expect(planned.item.reference.aliases, contains(_english));
    expect(planned.status, VideoAcquisitionFranchiseEntryStatus.ready);
  });

  test('整套 service：没有拉丁标题的电影也取详情，用补齐后的身份搜资源', () async {
    final VideoDiscoveryItem anchor = _searchItem(
      id: 'tv',
      title: 'Kurumi',
      aliases: const <String>[],
    );
    final VideoDiscoveryItem movie = _searchItem(
      id: 'movie',
      aliases: const <String>[],
      kind: VideoMetadataMediaKind.movie,
    );
    final List<String> detailCalls = <String>[];
    final Map<String, List<String>> searchedQueries = <String, List<String>>{};
    final VideoAcquisitionService service = VideoAcquisitionService(
      defaults: _defaults,
      ports: VideoAcquisitionPorts(
        searchWorks: (_) async =>
            ProviderBatchResult<VideoDiscoveryPage>.success(
              <VideoDiscoveryPage>[
                VideoDiscoveryPage(
                  items: <VideoDiscoveryItem>[anchor],
                  page: 1,
                  hasMore: false,
                ),
              ],
            ),
        loadDetails: (VideoDiscoveryItem item) async {
          detailCalls.add(item.reference.mediaId);
          return item.reference.mediaId == 'movie'
              ? _details(kind: VideoMetadataMediaKind.movie, romaji: null)
              : null;
        },
        loadFranchise: (_) async => VideoFranchise(
          name: 'Kurumi',
          series: const <VideoDiscoveryItem>[],
          movies: <VideoDiscoveryItem>[movie],
        ),
        queryPresence: (_) async => VideoLibraryPresence.none,
        isSubscribed: (_) async => false,
        searchResources: (VideoResourceSearchRequest request) async {
          searchedQueries[request.media!.mediaId] = nyaaSearchQueries(request);
          return ProviderBatchResult<VideoResourceCandidate>.success(
            const <VideoResourceCandidate>[],
          );
        },
        parseIntent: (_) async => const VideoAcquisitionIntent(
          VideoAcquisitionIntentKind.provide,
          VideoAcquisitionIntentPatch(
            workQueries: <String>['Kurumi'],
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

    await service.submitText('くるみ 整套');
    expect(detailCalls, contains('movie'));
    expect(searchedQueries['movie'], contains(_english));
  });
}
