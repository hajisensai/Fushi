import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi/src/pages/implementations/ai_video_acquisition_page.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 对话页只渲染 service 状态：文本经 AI 解析、chip 永不经 AI、摘要卡三按钮、
/// 「以后默认」勾选框默认勾上且值随 chip 一起回传。不挂 ProviderScope。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget harness(VideoAcquisitionService service) => TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          home: AiVideoAcquisitionPage(service: service),
        ),
      );

  testWidgets('typing sends the text through the AI port; chips bypass it', (
    WidgetTester tester,
  ) async {
    final _Ports ports = _Ports();
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: ports.build(),
      defaults: const VideoAcquisitionDefaults(
        qualityPref: '',
        subtitleLanguagePref: 'ja',
        sources: <VideoAcquisitionSource>[
          VideoAcquisitionSource(id: 1, label: 'Videos'),
        ],
        defaultSourceId: 1,
      ),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));

    await tester.enterText(
      find.byKey(const ValueKey<String>('ai-video-acquire-input')),
      'Show',
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('ai-video-acquire-send')));
    await tester.pumpAndSettle();

    expect(ports.parseCalls, 1);
    // 画质偏好未设置 → 问画质，带「以后默认」勾选框且默认勾上。
    expect(service.state.question?.slot, VideoAcquisitionSlot.quality);
    final Checkbox remember = tester.widget<Checkbox>(
      find.byKey(const ValueKey<String>('ai-video-acquire-remember')),
    );
    expect(remember.value, isTrue);

    await tester.tap(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-quality-1080p')),
    );
    await tester.pumpAndSettle();

    // chip 不经 AI；勾选着 → 写偏好。
    expect(ports.parseCalls, 1);
    expect(ports.persisted, <String>['quality=1080p']);
    expect(service.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
    expect(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-resource-confirm')),
      findsOneWidget,
    );
    expect(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-resource-next')),
      findsOneWidget,
    );
    expect(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-resource-cancel')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-resource-confirm')),
    );
    await tester.pumpAndSettle();
    expect(ports.submitted, 3);
    expect(service.state.stage, VideoAcquisitionStage.done);
  });

  testWidgets(
      'unchecking "use as default" keeps the choice for this request only', (
    WidgetTester tester,
  ) async {
    final _Ports ports = _Ports();
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: ports.build(),
      defaults: const VideoAcquisitionDefaults(
        qualityPref: '',
        subtitleLanguagePref: 'ja',
        sources: <VideoAcquisitionSource>[
          VideoAcquisitionSource(id: 1, label: 'Videos'),
        ],
        defaultSourceId: 1,
      ),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.enterText(
      find.byKey(const ValueKey<String>('ai-video-acquire-input')),
      'Show',
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('ai-video-acquire-send')));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('ai-video-acquire-remember')));
    await tester.pump();
    await tester.tap(
      find.byKey(
          const ValueKey<String>('ai-video-acquire-option-quality-720p')),
    );
    await tester.pumpAndSettle();

    expect(ports.persisted, isEmpty);
    expect(service.state.slots.quality, VideoAcquisitionQuality.p720);
  });
}

VideoDiscoveryItem _finishedShow() => VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'mal',
        mediaId: '1',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Show',
        year: 2026,
      ),
      metadataWork: VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show',
        status: 'Finished Airing',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: '1', isDefault: true),
        ],
      ),
    );

class _Candidate extends VideoResourceCandidate {
  _Candidate(int episode, String resolution)
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          remoteId: 'r$episode-$resolution',
          title:
              '[Group] Show - ${episode.toString().padLeft(2, '0')} ($resolution)',
          providerPriority: 100,
          releaseGroup: 'Group',
          resolution: resolution,
          trusted: true,
          seeders: 10,
        );
}

class _Ports {
  int parseCalls = 0;
  int submitted = 0;
  final List<String> persisted = <String>[];

  VideoAcquisitionPorts build() => VideoAcquisitionPorts(
        searchWorks: (_) async =>
            ProviderBatchResult<VideoDiscoveryPage>.success(
          <VideoDiscoveryPage>[
            VideoDiscoveryPage(
              items: <VideoDiscoveryItem>[_finishedShow()],
              page: 1,
              hasMore: false,
            ),
          ],
        ),
        loadDetails: (VideoDiscoveryItem item) async => item.metadataWork,
        queryPresence: (_) async => VideoLibraryPresence.none,
        isSubscribed: (_) async => false,
        searchResources: (_) async =>
            ProviderBatchResult<VideoResourceCandidate>.success(
          <VideoResourceCandidate>[
            for (final String resolution in <String>['1080p', '720p'])
              for (int episode = 1; episode <= 3; episode++)
                _Candidate(episode, resolution),
          ],
        ),
        parseIntent: (VideoAcquisitionIntentQuery query) async {
          parseCalls++;
          return const VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
          );
        },
        decideIdentity: (_) async => null,
        persistPreference: (VideoAcquisitionPreference p, String v) async =>
            persisted.add('${p.name}=$v'),
        setSeriesSubtitleLanguage: (_, _) async {},
        submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
          submitted = effect.plan.picks.length;
          return submitted;
        },
        submitSubscription: (_) async {},
      );
}
