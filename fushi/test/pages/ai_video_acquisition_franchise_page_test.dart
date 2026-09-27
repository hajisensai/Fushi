// 对话页：整套清单卡（勾选 / 状态文案）、作品操作条、再下一部、入口带入的文字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi/src/pages/implementations/ai_video_acquisition_page.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

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
        sizeBytes: 2 * 1024 * 1024 * 1024,
      );
}

VideoDiscoveryItem _movie(String id, String title, int year) =>
    VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'tmdb',
        mediaId: id,
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: title,
        year: year,
      ),
    );

class _Ports {
  final List<String> texts = <String>[];

  VideoAcquisitionPorts build() => VideoAcquisitionPorts(
    searchWorks: (VideoDiscoveryRequest request) async {
      texts.add(request.query ?? '');
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        const <VideoDiscoveryPage>[],
      );
    },
    loadDetails: (_) async => null,
    loadFranchise: (_) async => null,
    queryPresence: (_) async => VideoLibraryPresence.none,
    isSubscribed: (_) async => false,
    searchResources: (_) async =>
        ProviderBatchResult<VideoResourceCandidate>.success(
          const <VideoResourceCandidate>[],
        ),
    // 未指派 AI：原文直接当作品查询词（便于断言入口带入的文字）。
    parseIntent: (_) async => null,
    decideIdentity: (_) async => null,
    persistPreference: (_, _) async {},
    setSeriesSubtitleLanguage: (_, _) async {},
    submitDownload: (_) async => 1,
    submitSubscription: (_) async {},
  );
}

const VideoAcquisitionDefaults _defaults = VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 1, label: 'Videos'),
  ],
  defaultSourceId: 1,
);

VideoAcquisitionState _franchiseState() {
  final VideoResourceVersionGroup group = buildVideoResourceVersionGroups(
    <VideoResourceCandidate>[
      _Resource('r', '[G] Movie A (1980) [1080p] BDRip'),
    ],
  ).single;
  final VideoAcquisitionResourcePlan plan = VideoAcquisitionResourcePlan(
    group: group,
    picks: <VideoResourceCandidate>[group.representative],
  );
  final VideoDiscoveryItem a = _movie('a', 'Movie A', 1980);
  return VideoAcquisitionState(
    stage: VideoAcquisitionStage.awaitingFranchiseConfirm,
    chosenItem: a,
    slots: const VideoAcquisitionSlots(
      scope: VideoAcquisitionScope.franchiseMovies,
      quality: VideoAcquisitionQuality.p1080,
      subtitleLanguage: 'ja',
      targetSourceId: 1,
      mode: VideoAcquisitionMode.download,
    ),
    franchiseName: 'Series',
    franchiseEntries: <VideoAcquisitionFranchiseEntry>[
      VideoAcquisitionFranchiseEntry(
        item: a,
        status: VideoAcquisitionFranchiseEntryStatus.ready,
        plan: plan,
      ),
      VideoAcquisitionFranchiseEntry(
        item: _movie('b', 'Movie B', 1981),
        status: VideoAcquisitionFranchiseEntryStatus.noResource,
        selected: false,
      ),
    ],
    question: const VideoAcquisitionQuestion(
      slot: VideoAcquisitionSlot.franchise,
      options: <VideoAcquisitionOption>[
        VideoAcquisitionOption(id: kVideoAcquisitionOptionSubmitAll),
        VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
      ],
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget harness(VideoAcquisitionService service, {String? initialQuery}) =>
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          home: AiVideoAcquisitionPage(
            service: service,
            initialQuery: initialQuery,
          ),
        ),
      );

  testWidgets('整套清单：每部一行，版本写明片源与每集体积，勾选写回状态', (WidgetTester tester) async {
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: _Ports().build(),
      defaults: _defaults,
      initial: _franchiseState(),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();

    expect(find.text('Movie A (1980)'), findsOneWidget);
    expect(
      find.text(
        t.ai_video_acquire_franchise_entry_download(
          version: 'G · 1080p · BD · 2.0 GiB',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text(t.ai_video_acquire_franchise_entry_none), findsOneWidget);
    expect(
      find.text(t.ai_video_acquire_option_submit_all(count: '1')),
      findsOneWidget,
    );
    // 没资源的行勾选框禁用。
    final Checkbox disabled = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('ai-video-acquire-franchise-1')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(disabled.onChanged, isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('ai-video-acquire-franchise-0')),
    );
    await tester.pumpAndSettle();
    expect(service.state.franchiseEntries.first.selected, isFalse);
    expect(
      find.text(t.ai_video_acquire_option_submit_all(count: '0')),
      findsOneWidget,
    );
  });

  testWidgets('作品操作条渲染，点「只下这一部」切回单部', (WidgetTester tester) async {
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: _Ports().build(),
      defaults: _defaults,
      initial: _franchiseState(),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();

    expect(find.text(t.ai_video_acquire_action_change_work), findsOneWidget);
    expect(find.text(t.ai_video_acquire_action_scope_all), findsOneWidget);
    await tester.tap(find.text(t.ai_video_acquire_action_scope_work));
    await tester.pumpAndSettle();
    expect(service.state.slots.scope, VideoAcquisitionScope.work);
    expect(service.state.franchiseEntries, isEmpty);
  });

  testWidgets('结束后出现「再下一部」，输入框仍可用', (WidgetTester tester) async {
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: _Ports().build(),
      defaults: _defaults,
      initial: const VideoAcquisitionState(stage: VideoAcquisitionStage.done),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();

    final TextField input = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('ai-video-acquire-input')),
    );
    expect(input.enabled, isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-video-acquire-restart')),
    );
    await tester.pumpAndSettle();
    expect(service.state.stage, VideoAcquisitionStage.idle);
    expect(
      find.byKey(const ValueKey<String>('ai-video-acquire-restart')),
      findsNothing,
    );
  });

  testWidgets('提交在飞：取消按钮禁用', (WidgetTester tester) async {
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: _Ports().build(),
      defaults: _defaults,
      initial: const VideoAcquisitionState(
        stage: VideoAcquisitionStage.submitting,
        busy: true,
      ),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.pump();
    final IconButton cancel = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('ai-video-acquire-cancel')),
    );
    expect(cancel.onPressed, isNull);
  });

  testWidgets('入口带入的文字直接当第一句话发出', (WidgetTester tester) async {
    final _Ports ports = _Ports();
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: ports.build(),
      defaults: _defaults,
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service, initialQuery: '  哆啦A梦 '));
    await tester.pumpAndSettle();
    expect(ports.texts, <String>['哆啦A梦']);
    expect(find.text('哆啦A梦'), findsOneWidget);
  });

  testWidgets('固定失败键翻成人话，不把 no_candidates 原样丢给用户', (WidgetTester tester) async {
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: _Ports().build(),
      defaults: _defaults,
      initial: const VideoAcquisitionState(
        transcript: <VideoAcquisitionMessage>[
          VideoAcquisitionAssistantMessage(
            VideoAcquisitionSay(
              VideoAcquisitionSayKind.failed,
              args: <String, Object?>{'message': 'no_candidates'},
            ),
          ),
        ],
      ),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    expect(
      find.text(
        t.ai_video_acquire_failed(
          message: t.ai_video_acquire_failure_no_candidates,
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('no_candidates'), findsNothing);
  });
}
