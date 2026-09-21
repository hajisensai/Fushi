// BUG-2619 守卫：从一条整包（合集 / 全集 / 认不出集号的 BD 打包）资源建订阅时，
// 创建端必须建一次性订阅而不是追更订阅——追更规则在整包上结构性地永不命中，
// 界面却只会说「还没有跟踪到任何发布」，用户无从分辨是没更新还是规则对不上。
//
// 订阅列表的一行是**一条规则**（同 filter 的发布聚合成一行），所以判据落在组上：
// 组里还有单集就照旧追更，整组都是整包才降级成一次性。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';

/// 用户实际选中的那条：纯 TV 本篇 BD 打包，没有集数区间也没有 batch 关键词，
/// 唯一特征是解析不出集号。
const String _batchTitle =
    '[DMG&MakariHoshiyume&VCB-Studio] Shoujo Kageki Revue Starlight '
    '10-bit 1080p HEVC BDRip [Fin]';

/// 另一个发布组的逐集发布——与整包分属两条规则，各占一行。
const String _episodeTitle =
    '[SubsPlease] Shoujo Kageki Revue Starlight - 05 [1080p]';

class _Candidate extends VideoResourceCandidate {
  _Candidate({
    required String remoteId,
    required String title,
    String group = 'VCB-Studio',
    int seeders = 10,
  }) : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa.si',
          remoteId: remoteId,
          title: title,
          releaseGroup: group,
          resolution: '1080p',
          category: '1_3',
          trusted: true,
          seeders: seeders,
          providerPriority: 1,
        );
}

class _Provider implements VideoResourceProvider {
  _Provider(this.candidates);

  final List<VideoResourceCandidate> candidates;

  @override
  String get id => 'nyaa';

  @override
  int get priority => 1;

  @override
  Set<VideoDiscoveryCategory> get categories => <VideoDiscoveryCategory>{};

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(candidates);

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

VideoMediaReference _media() => VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '77777',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Shoujo Kageki Revue Starlight',
      year: 2018,
      season: 1,
      externalIds: <String, String>{'tmdb': '77777'},
    );

const MediaSourceRow _source = MediaSourceRow(
  videoGroupingMode: 'series',
  id: 1,
  label: 'Videos',
  mediaKind: 'video',
  transport: 'local',
  rootPath: 'D:/videos',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<VideoDiscoverySubscriptionSelection?> subscribeTo(
    WidgetTester tester,
    List<VideoResourceCandidate> candidates,
    String rowTitle, {
    bool submit = true,
  }) async {
    VideoDiscoverySubscriptionSelection? submitted;
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoResourceSearchSurface(
            pageMode: true,
            initialItem: VideoDiscoveryItem(reference: _media()),
            registry: VideoResourceRegistry(
              <VideoResourceProvider>[_Provider(candidates)],
            ),
            sources: const <MediaSourceRow>[_source],
            onSubscriptionSubmit:
                (VideoDiscoverySubscriptionSelection selection) async {
              submitted = selection;
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(rowTitle));
    await tester.pumpAndSettle();
    if (submit) {
      await tester
          .tap(find.byKey(const ValueKey<String>('video-subscription-submit')));
      await tester.pumpAndSettle();
    }
    return submitted;
  }

  List<VideoResourceCandidate> twoRules() => <VideoResourceCandidate>[
        _Candidate(remoteId: 'batch', title: _batchTitle),
        _Candidate(
          remoteId: 'ep5',
          title: _episodeTitle,
          group: 'SubsPlease',
        ),
      ];

  testWidgets('选中整包时说明是一次性下载，且不给起始集号', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await subscribeTo(tester, twoRules(), _batchTitle, submit: false);

    expect(
      find.byKey(const ValueKey<String>('video-subscription-start-after')),
      findsNothing,
      reason: '整包一次下完，没有「从第几集起追」这一维',
    );
    expect(
      find.text(
        t.download_subscription_choice_hint_batch(
          group: 'VCB-Studio',
          resolution: '1080p',
        ),
      ),
      findsOneWidget,
      reason: '确认行必须说清将要建的是一次性订阅而不是追更',
    );
  });

  testWidgets('整包提交为一次性订阅，单集提交仍是追更', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final VideoDiscoverySubscriptionSelection? batch =
        await subscribeTo(tester, twoRules(), _batchTitle);
    expect(batch, isNotNull);
    expect(batch!.batchRelease, isTrue);
    expect(
      batch.startAfterEpisode,
      isNull,
      reason: '整包没有起点，带出去只会让一次性订阅显示一个无意义的集号',
    );

    final VideoDiscoverySubscriptionSelection? episode =
        await subscribeTo(tester, twoRules(), _episodeTitle);
    expect(episode, isNotNull);
    expect(episode!.batchRelease, isFalse, reason: '单集发布仍然按追更订阅');
    expect(episode.startAfterEpisode, 5);
  });

  testWidgets('同一规则下还有单集时不降级成一次性', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 同组同清晰度：整包与单集聚合成一行，代表条是做种更多的整包。
    final List<VideoResourceCandidate> mixed = <VideoResourceCandidate>[
      _Candidate(remoteId: 'batch', title: _batchTitle, seeders: 99),
      _Candidate(
        remoteId: 'ep5',
        title: '[DMG&MakariHoshiyume&VCB-Studio] Shoujo Kageki Revue '
            'Starlight - 05 [1080p]',
        seeders: 3,
      ),
    ];

    final VideoDiscoverySubscriptionSelection? submitted =
        await subscribeTo(tester, mixed, _batchTitle);

    expect(submitted, isNotNull);
    expect(
      submitted!.batchRelease,
      isFalse,
      reason: '这条规则底下还有单集发布，追更是活的，不该被代表条拖成一次性',
    );
  });
}
