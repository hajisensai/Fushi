import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 编排器的端到端契约（假端口）：文本 → AI 解析 → 搜作品 → 拉详情 → 搜资源 →
/// 摘要确认 → 先写每系列字幕语言、再入队。AI 端口失败 / 未指派时流程照样能走完。
void main() {
  test(
    'text to download: series subtitle language is written before enqueue',
    () async {
      final _Ports ports = _Ports();
      final VideoAcquisitionService service = VideoAcquisitionService(
        ports: ports.build(),
        defaults: _defaults(),
      );
      addTearDown(service.dispose);

      await service.submitText('下 Show');

      expect(ports.searchQueries, <String>['Show']);
      expect(
        service.state.stage,
        VideoAcquisitionStage.awaitingResourceConfirm,
      );
      expect(service.state.question?.slot, VideoAcquisitionSlot.resource);
      expect(service.state.plan?.picks, hasLength(3));

      await service.confirm();

      expect(service.state.stage, VideoAcquisitionStage.done);
      expect(ports.calls, <String>[
        'setSeriesSubtitleLanguage:ja',
        'submitDownload:3',
      ]);
      expect(ports.submittedInstallSubtitles, isTrue);
      final VideoAcquisitionAssistantMessage last = service.state.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .last;
      expect(last.say.kind, VideoAcquisitionSayKind.submitted);
      expect(last.say.args['count'], 3);
    },
  );

  test(
    'an unassigned AI provider degrades to the raw text as the query',
    () async {
      final _Ports ports = _Ports(intent: null);
      final VideoAcquisitionService service = VideoAcquisitionService(
        ports: ports.build(),
        defaults: _defaults(),
      );
      addTearDown(service.dispose);

      await service.submitText('Show');

      expect(
        service.state.transcript
            .whereType<VideoAcquisitionAssistantMessage>()
            .map((VideoAcquisitionAssistantMessage m) => m.say.kind),
        contains(VideoAcquisitionSayKind.aiUnavailable),
      );
      expect(ports.searchQueries, <String>['Show']);
      expect(
        service.state.stage,
        VideoAcquisitionStage.awaitingResourceConfirm,
      );
    },
  );

  test(
    'a failing enqueue keeps the confirmation open and exposes the error',
    () async {
      final _Ports ports = _Ports(
        submitError: const FormatException('backend down'),
      );
      final VideoAcquisitionService service = VideoAcquisitionService(
        ports: ports.build(),
        defaults: _defaults(),
      );
      addTearDown(service.dispose);

      await service.submitText('Show');
      await service.confirm();

      expect(service.lastError, isA<FormatException>());
      expect(service.state.stage, isNot(VideoAcquisitionStage.done));
      expect(
        service.state.transcript
            .whereType<VideoAcquisitionAssistantMessage>()
            .map((VideoAcquisitionAssistantMessage m) => m.say.kind),
        contains(VideoAcquisitionSayKind.failed),
      );
    },
  );

  test('a failing effect aborts the rest of its batch: nothing is enqueued '
      'after the series subtitle write throws', () async {
    final _Ports ports = _Ports(
      setSeriesError: const FormatException('prefs locked'),
    );
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: ports.build(),
      defaults: _defaults(),
    );
    addTearDown(service.dispose);

    await service.submitText('下 Show');
    await service.confirm();

    expect(
      ports.calls,
      isEmpty,
      reason:
          '记忆写失败后入队不得执行——否则 UI 报失败、下载其实已入队，'
          '用户再点「就这个」就是重复入队',
    );
    expect(
      service.state.stage,
      VideoAcquisitionStage.awaitingResourceConfirm,
      reason: '回到确认态，用户可以重试',
    );
    expect(service.lastError, isA<FormatException>());
  });

  test('cancel closes the session from any stage', () async {
    final _Ports ports = _Ports();
    final VideoAcquisitionService service = VideoAcquisitionService(
      ports: ports.build(),
      defaults: _defaults(),
    );
    addTearDown(service.dispose);

    await service.submitText('Show');
    await service.cancel();

    expect(service.state.stage, VideoAcquisitionStage.cancelled);
    expect(ports.calls, isEmpty);
  });
}

VideoAcquisitionDefaults _defaults() => const VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 1, label: 'Videos'),
  ],
  defaultSourceId: 1,
  locale: 'zh-CN',
);

VideoDiscoveryItem _finishedShow() {
  final VideoMetadataWork work = VideoMetadataWork(
    provider: VideoMetadataProviderKind.mal,
    kind: VideoMetadataMediaKind.tv,
    title: 'Show',
    status: 'Finished Airing',
    ids: const <VideoMetadataId>[
      VideoMetadataId(type: 'mal', value: '1', isDefault: true),
    ],
  );
  return VideoDiscoveryItem(
    reference: VideoMediaReference(
      providerId: 'mal',
      mediaId: '1',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Show',
      year: 2026,
    ),
    metadataWork: work,
  );
}

class _Candidate extends VideoResourceCandidate {
  _Candidate(int episode)
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        remoteId: 'r$episode',
        title: '[Group] Show - ${episode.toString().padLeft(2, '0')} (1080p)',
        providerPriority: 100,
        releaseGroup: 'Group',
        resolution: '1080p',
        trusted: true,
        seeders: 10,
      );
}

class _Ports {
  _Ports({
    this.intent = const VideoAcquisitionIntent(
      VideoAcquisitionIntentKind.provide,
      VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
    ),
    this.submitError,
    this.setSeriesError,
  });

  final VideoAcquisitionIntent? intent;
  final Exception? submitError;
  final Exception? setSeriesError;
  final List<String> searchQueries = <String>[];
  final List<String> calls = <String>[];
  bool? submittedInstallSubtitles;

  VideoAcquisitionPorts build() => VideoAcquisitionPorts(
    searchWorks: (VideoDiscoveryRequest request) async {
      searchQueries.add(request.query ?? '');
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: <VideoDiscoveryItem>[_finishedShow()],
            page: 1,
            hasMore: false,
          ),
        ],
      );
    },
    loadDetails: (VideoDiscoveryItem item) async => item.metadataWork,
    queryPresence: (_) async => VideoLibraryPresence.none,
    isSubscribed: (_) async => false,
    searchResources: (_) async =>
        ProviderBatchResult<VideoResourceCandidate>.success(
          <VideoResourceCandidate>[_Candidate(1), _Candidate(2), _Candidate(3)],
        ),
    parseIntent: (VideoAcquisitionIntentQuery query) async => intent,
    decideIdentity: (_) async => null,
    persistPreference: (VideoAcquisitionPreference p, String v) async =>
        calls.add('persist:${p.name}=$v'),
    setSeriesSubtitleLanguage: (_, String code) async {
      if (setSeriesError != null) throw setSeriesError!;
      calls.add('setSeriesSubtitleLanguage:$code');
    },
    submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
      if (submitError != null) throw submitError!;
      submittedInstallSubtitles = effect.installSubtitles;
      calls.add('submitDownload:${effect.plan.picks.length}');
      return effect.plan.picks.length;
    },
    submitSubscription: (_) async => calls.add('submitSubscription'),
  );
}
