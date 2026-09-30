/// 手机经互联把「AI 下视频」交给电脑（`/api/assistant`）。
///
/// 对真实 [FushiSyncServer] 挂 [VideoAcquisitionAssistantHost]（会话里是真的
/// [VideoAcquisitionService]，外部端口是假的），用真实 [InterconnectAssistantClient]
/// 与 [RemoteVideoAcquisitionSession] 走一遍：能力位 → 开会话 → 手机说一句话 →
/// 电脑的状态机搜作品 / 搜资源 → 手机收到摘要问句 → 手机点「就这个」→ 入队发生在
/// **电脑**的端口上。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi/src/media/video/acquisition/remote_video_acquisition_session.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi-app-assistant-host-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(FushiSyncServer, String)> startHost(VideoAcquisitionAssistantHost? host) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync'),
      port: 0,
      token: 'tok',
      assistant: host,
    );
    await server.start();
    addTearDown(server.stop);
    final String url = 'http://127.0.0.1:${server.port}';
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: url, deviceName: 'PC'),
    ]);
    await repo.setFushiClientToken('tok');
    return (server, url);
  }

  InterconnectAssistantClient client() =>
      InterconnectAssistantClient(repo: repo);

  /// 等远端会话的视图满足条件（长轮询是真实网络往返）。
  Future<VideoAcquisitionView> viewWhere(
    RemoteVideoAcquisitionSession session,
    bool Function(VideoAcquisitionView view) test,
  ) async {
    if (test(session.view)) return session.view;
    return session.views.firstWhere(test).timeout(const Duration(seconds: 10));
  }

  test(
      '能力位：就绪 → 宣告 videoAcquire；缺 AI 指派 → supported=false + reason；'
      '老 host 没有能力位 → unsupported', () async {
    String? blocker;
    final _HostPorts ports = _HostPorts();
    final (FushiSyncServer server, String url) = await startHost(
      ports.host(blocker: () => blocker),
    );
    final HostAssistantTarget? ready = await client().probeUrl(url);
    expect(ready, isNotNull);
    expect(ready!.label, 'PC');
    expect(ready.supports(kHostAssistantFeatureVideoAcquire), isTrue);
    expect(ready.reason, isNull);

    blocker = kHostAssistantReasonNoProvider;
    final HostAssistantTarget? blocked = await client().probeUrl(url);
    expect(blocked!.supports(kHostAssistantFeatureVideoAcquire), isFalse);
    expect(blocked.reason, kHostAssistantReasonNoProvider);
    await server.stop();

    final (_, String oldUrl) = await startHost(null);
    final HostAssistantTarget? old = await client().probeUrl(oldUrl);
    expect(old!.features, isEmpty);
    expect(old.reason, kHostAssistantReasonUnsupported);
    expect(
      await client().probeUrl('http://192.0.2.1:1'),
      isNull,
      reason: '不在配对清单里的地址不探',
    );
  });

  test('开会话时 host 缺前置 → 409 带 reason 短码，入口据此给出具体引导', () async {
    final _HostPorts ports = _HostPorts();
    final (_, String url) = await startHost(
      ports.host(blocker: () => kHostAssistantReasonNotReady),
    );
    final InterconnectAssistantClient c = client();
    final HostAssistantTarget target = HostAssistantTarget(
      baseUrl: url,
      deviceName: 'PC',
      features: const <String>[kHostAssistantFeatureVideoAcquire],
    );
    await expectLater(
      RemoteVideoAcquisitionSession.open(
        client: c,
        target: target,
        locale: 'zh-CN',
      ),
      throwsA(
        isA<HostAssistantException>()
            .having((HostAssistantException e) => e.code, 'code', 'http_409')
            .having(
              (HostAssistantException e) => e.detail,
              'detail',
              kHostAssistantReasonNotReady,
            ),
      ),
    );
    expect(ports.opened, isEmpty, reason: '门没过不得在 host 上建会话');
  });

  test('手机说一句话 → 电脑的状态机办事 → 手机点「就这个」→ 入队发生在电脑上', () async {
    final _HostPorts ports = _HostPorts();
    final (_, String url) = await startHost(ports.host());
    final InterconnectAssistantClient c = client();
    final HostAssistantTarget target = (await c.probeUrl(url))!;
    final RemoteVideoAcquisitionSession session =
        await RemoteVideoAcquisitionSession.open(
      client: c,
      target: target,
      locale: 'ja-JP',
    );
    addTearDown(session.dispose);
    expect(ports.opened, <String>['ja-JP'], reason: 'AI 解析按手机的语言写提示词');
    expect(session.view.stage, VideoAcquisitionStage.idle);

    await session.submitText('下 Show');
    final VideoAcquisitionView asked = await viewWhere(
      session,
      (VideoAcquisitionView v) =>
          v.stage == VideoAcquisitionStage.awaitingResourceConfirm,
    );
    expect(ports.parsed, <String>['下 Show'], reason: '一句话交给的是电脑的 AI 端口');
    expect(asked.question?.slot, VideoAcquisitionSlot.resource);
    expect(
      asked.question?.options.map((VideoAcquisitionOption o) => o.id),
      containsAll(<String>[
        kVideoAcquisitionOptionConfirm,
        kVideoAcquisitionOptionNext,
      ]),
    );
    final VideoAcquisitionAssistantMessage summary = asked.transcript
        .whereType<VideoAcquisitionAssistantMessage>()
        .lastWhere(
          (VideoAcquisitionAssistantMessage m) =>
              m.say.kind == VideoAcquisitionSayKind.summary,
        );
    expect(summary.say.args['releaseGroup'], 'Group');
    expect(summary.say.args['count'], 3);
    expect(
      asked.workActions,
      isNotEmpty,
      reason: '作品操作条（换一部 / 整个系列）也要过线',
    );

    await session.confirm();
    final VideoAcquisitionView done = await viewWhere(
      session,
      (VideoAcquisitionView v) => v.stage == VideoAcquisitionStage.done,
    );
    expect(ports.calls, <String>[
      'setSeriesSubtitleLanguage:ja',
      'submitDownload:3',
    ]);
    expect(
      done.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .last
          .say
          .kind,
      VideoAcquisitionSayKind.submitted,
    );

    session.dispose();
    await _eventually(() => ports.released == 1);
    expect(ports.released, 1, reason: '手机退出页面 → host 关会话并释放发现服务');
  });

  test('电脑连不上 → 手机记录里插一条「连接中断」且放开输入；持续断线只提示一次', () async {
    final _HostPorts ports = _HostPorts();
    final (FushiSyncServer server, String url) = await startHost(ports.host());
    final InterconnectAssistantClient c = client();
    final HostAssistantTarget target = (await c.probeUrl(url))!;
    final RemoteVideoAcquisitionSession session =
        await RemoteVideoAcquisitionSession.open(
      client: c,
      target: target,
      locale: 'zh-CN',
      retryDelay: const Duration(milliseconds: 50),
      longPollWait: const Duration(seconds: 1),
    );
    addTearDown(session.dispose);

    await server.stop();
    await session.submitText('Show');
    final VideoAcquisitionView offline = await viewWhere(
      session,
      (VideoAcquisitionView v) => v.transcript.isNotEmpty,
    );
    final List<VideoAcquisitionAssistantMessage> failures = offline.transcript
        .whereType<VideoAcquisitionAssistantMessage>()
        .where(
          (VideoAcquisitionAssistantMessage m) =>
              m.say.kind == VideoAcquisitionSayKind.failed,
        )
        .toList();
    expect(failures, hasLength(1));
    expect(
      failures.single.say.args['message'],
      kVideoAcquisitionFailureRemoteUnavailable,
    );
    expect(offline.busy, isFalse);
    expect(offline.failureHint, VideoAcquisitionFailureHint.none);

    // 持续连不上只提示一次。
    await session.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      session.view.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .where(
            (VideoAcquisitionAssistantMessage m) =>
                m.say.kind == VideoAcquisitionSayKind.failed,
          )
          .length,
      1,
    );
  });

  test('会话表：非法动作 400、长轮询无变化等满超时回原 revision、关后 404', () async {
    final _HostPorts ports = _HostPorts();
    final HostAssistantSessions sessions = HostAssistantSessions(
      ports.host(),
      idleTimeout: const Duration(minutes: 1),
    );
    addTearDown(sessions.dispose);
    final Map<String, Object?> first = await sessions.open(
      kHostAssistantFeatureVideoAcquire,
      locale: 'zh-CN',
    );
    final String id = first['id']! as String;
    final int revision = first['revision']! as int;

    await expectLater(
      sessions.act(id, <String, Object?>{'type': 'choose', 'slot': 'nope'}),
      throwsArgumentError,
    );
    await expectLater(
      sessions.act(id, <String, Object?>{'type': 'rm -rf'}),
      throwsArgumentError,
    );
    await expectLater(
      sessions.open('somethingElse', locale: 'zh-CN'),
      throwsArgumentError,
    );

    final Stopwatch watch = Stopwatch()..start();
    final Map<String, Object?>? idle = await sessions.read(
      id,
      after: revision,
      wait: const Duration(milliseconds: 300),
    );
    expect(idle!['revision'], revision);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));

    // 有变化的长轮询立即返回。
    final Future<Map<String, Object?>?> pending = sessions.read(
      id,
      after: revision,
      wait: const Duration(seconds: 10),
    );
    await sessions.act(id, <String, Object?>{'type': 'text', 'text': 'Show'});
    final Map<String, Object?>? changed = await pending.timeout(
      const Duration(seconds: 5),
    );
    expect(changed!['revision'] as int, greaterThan(revision));

    expect(await sessions.close(id), isTrue);
    expect(await sessions.read(id), isNull);
    expect(ports.released, 1);
  });

  test('会话闲置超时被回收；超过并发上限先关最久没碰的', () async {
    DateTime now = DateTime(2026, 9, 28, 12);
    final _HostPorts ports = _HostPorts();
    final HostAssistantSessions sessions = HostAssistantSessions(
      ports.host(),
      idleTimeout: const Duration(minutes: 30),
      maxSessions: 2,
      now: () => now,
    );
    addTearDown(sessions.dispose);
    final String a = (await sessions.open(
      kHostAssistantFeatureVideoAcquire,
      locale: 'zh-CN',
    ))['id']! as String;
    now = now.add(const Duration(minutes: 1));
    final String b = (await sessions.open(
      kHostAssistantFeatureVideoAcquire,
      locale: 'zh-CN',
    ))['id']! as String;
    now = now.add(const Duration(minutes: 1));
    await sessions.open(kHostAssistantFeatureVideoAcquire, locale: 'zh-CN');
    expect(await sessions.read(a), isNull, reason: '最久没碰的 a 被挤掉');
    expect(await sessions.read(b), isNotNull);

    now = now.add(const Duration(minutes: 31));
    expect(await sessions.read(b), isNull, reason: '闲置超过 30 分钟回收');
  });
}

Future<void> _eventually(bool Function() condition) async {
  for (int i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 电脑这边的假外部端口：状态机是真的，搜作品 / 搜资源 / AI / 入队是假的。
class _HostPorts {
  final List<String> opened = <String>[];
  final List<String> parsed = <String>[];
  final List<String> calls = <String>[];
  int released = 0;

  VideoAcquisitionAssistantHost host({String? Function()? blocker}) => VideoAcquisitionAssistantHost(
        videoAcquireBlocker: () async => blocker?.call(),
        openVideoAcquisition: (String locale) async {
          opened.add(locale);
          return (service: _service(), release: () => released++);
        },
      );

  VideoAcquisitionService _service() => VideoAcquisitionService(
        defaults: const VideoAcquisitionDefaults(
          qualityPref: '1080p',
          subtitleLanguagePref: 'ja',
          sources: <VideoAcquisitionSource>[
            VideoAcquisitionSource(id: 1, label: 'Videos'),
          ],
          defaultSourceId: 1,
          locale: 'zh-CN',
        ),
        ports: VideoAcquisitionPorts(
          searchWorks: (VideoDiscoveryRequest request) async =>
              ProviderBatchResult<
                  VideoDiscoveryPage>.success(<VideoDiscoveryPage>[
            VideoDiscoveryPage(
              items: <VideoDiscoveryItem>[_finishedShow()],
              page: 1,
              hasMore: false,
            ),
          ]),
          loadDetails: (VideoDiscoveryItem item) async => item.metadataWork,
          loadFranchise: (_) async => null,
          queryPresence: (_) async => VideoLibraryPresence.none,
          isSubscribed: (_) async => false,
          searchResources: (_) async =>
              ProviderBatchResult<VideoResourceCandidate>.success(
            <VideoResourceCandidate>[
              _Candidate(1),
              _Candidate(2),
              _Candidate(3),
            ],
          ),
          parseIntent: (VideoAcquisitionIntentQuery query) async {
            parsed.add(query.utterance);
            return const VideoAcquisitionIntent(
              VideoAcquisitionIntentKind.provide,
              VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
            );
          },
          decideIdentity: (_) async => null,
          persistPreference: (VideoAcquisitionPreference p, String v) async =>
              calls.add('persist:${p.name}=$v'),
          setSeriesSubtitleLanguage: (_, String code) async =>
              calls.add('setSeriesSubtitleLanguage:$code'),
          submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
            calls.add('submitDownload:${effect.plan.picks.length}');
            return effect.plan.picks.length;
          },
          submitSubscription: (_) async => calls.add('submitSubscription'),
        ),
      );
}

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
