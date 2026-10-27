import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_backends.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_controller.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

VideoMediaReference _reference({
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
}) => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '1',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: category,
  title: '葬送のフリーレン',
  originalTitle: 'Sousou no Frieren',
  aliases: const <String>['ソウソウノフリーレン', 'Frieren: Beyond Journey\'s End'],
);

/// 可控的假渠道：每次 lookup 返回一个由测试决定何时完成的 Completer。
class _FakeBackend implements VideoAcquisitionChannelBackend {
  _FakeBackend(this.channel);

  @override
  final VideoAcquisitionChannel channel;

  final List<Completer<VideoAcquisitionLookup>> calls =
      <Completer<VideoAcquisitionLookup>>[];

  @override
  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference) {
    final Completer<VideoAcquisitionLookup> completer =
        Completer<VideoAcquisitionLookup>();
    calls.add(completer);
    return completer.future;
  }
}

VideoAcquisitionHit _hit(String id) =>
    VideoAcquisitionHit(id: id, title: 'hit $id');

void main() {
  group('VideoWorkAcquisitionController', () {
    late Map<VideoAcquisitionChannel, _FakeBackend> backends;
    late VideoWorkAcquisitionController controller;

    setUp(() {
      backends = <VideoAcquisitionChannel, _FakeBackend>{
        for (final VideoAcquisitionChannel channel
            in VideoAcquisitionChannel.values)
          channel: _FakeBackend(channel),
      };
      controller = VideoWorkAcquisitionController(
        reference: _reference(),
        // 故意乱序传入：面板顺序由枚举决定，不由装配顺序决定。
        backends: backends.values.toList().reversed,
      );
    });

    tearDown(() => controller.dispose());

    test('四个渠道并发发起，一个渠道挂起不阻塞其余', () async {
      expect(controller.channels, VideoAcquisitionChannel.values);
      unawaited(controller.loadAll());
      for (final _FakeBackend backend in backends.values) {
        expect(backend.calls, hasLength(1), reason: '${backend.channel} 应已发起');
      }
      for (final VideoAcquisitionChannel channel in controller.channels) {
        expect(
          controller.stateOf(channel).status,
          VideoAcquisitionChannelStatus.loading,
        );
      }

      backends[VideoAcquisitionChannel.library]!.calls.single.complete(
        VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[_hit('a')]),
      );
      backends[VideoAcquisitionChannel.torrent]!.calls.single.complete(
        const VideoAcquisitionLookup.unconfigured(),
      );
      backends[VideoAcquisitionChannel.mediaServer]!.calls.single.complete(
        const VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[]),
      );
      await pumpEventQueue();

      expect(
        controller.stateOf(VideoAcquisitionChannel.library).status,
        VideoAcquisitionChannelStatus.ready,
      );
      expect(
        controller.stateOf(VideoAcquisitionChannel.library).hits.single.id,
        'a',
      );
      expect(
        controller.stateOf(VideoAcquisitionChannel.torrent).status,
        VideoAcquisitionChannelStatus.unconfigured,
      );
      expect(
        controller.stateOf(VideoAcquisitionChannel.mediaServer).status,
        VideoAcquisitionChannelStatus.empty,
      );
      // 在线源仍挂着，不影响其余三组已出结果。
      expect(
        controller.stateOf(VideoAcquisitionChannel.onlineSource).status,
        VideoAcquisitionChannelStatus.loading,
      );
    });

    test('失败可重试；重试后旧查询晚到的结果被丢弃', () async {
      unawaited(controller.load(VideoAcquisitionChannel.onlineSource));
      final _FakeBackend backend =
          backends[VideoAcquisitionChannel.onlineSource]!;
      backend.calls.single.completeError(StateError('boom'));
      await pumpEventQueue();
      final VideoAcquisitionChannelState failed = controller.stateOf(
        VideoAcquisitionChannel.onlineSource,
      );
      expect(failed.status, VideoAcquisitionChannelStatus.failed);
      expect(failed.error, isA<StateError>());

      // 重试两次：第一次的结果晚于第二次回来，必须被丢弃。
      unawaited(controller.load(VideoAcquisitionChannel.onlineSource));
      unawaited(controller.load(VideoAcquisitionChannel.onlineSource));
      expect(backend.calls, hasLength(3));
      backend.calls[2].complete(
        VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[
          _hit('new'),
        ], failedSourceCount: 1),
      );
      await pumpEventQueue();
      backend.calls[1].complete(
        VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[_hit('stale')]),
      );
      await pumpEventQueue();
      final VideoAcquisitionChannelState state = controller.stateOf(
        VideoAcquisitionChannel.onlineSource,
      );
      expect(state.status, VideoAcquisitionChannelStatus.ready);
      expect(state.hits.single.id, 'new');
      expect(state.failedSourceCount, 1);
    });

    test('dispose 之后晚到的结果不再通知', () async {
      int notifications = 0;
      final VideoWorkAcquisitionController local =
          VideoWorkAcquisitionController(
            reference: _reference(),
            backends: <VideoAcquisitionChannelBackend>[
              backends[VideoAcquisitionChannel.library]!,
            ],
          );
      local.addListener(() => notifications++);
      unawaited(local.loadAll());
      final int before = notifications;
      local.dispose();
      backends[VideoAcquisitionChannel.library]!.calls.single.complete(
        VideoAcquisitionLookup.hits(<VideoAcquisitionHit>[_hit('a')]),
      );
      await pumpEventQueue();
      expect(notifications, before);
    });

    test('没传后端的渠道不出现（合规门关掉的整组不渲染）', () {
      final VideoWorkAcquisitionController local =
          VideoWorkAcquisitionController(
            reference: _reference(),
            backends: <VideoAcquisitionChannelBackend>[
              backends[VideoAcquisitionChannel.mediaServer]!,
              backends[VideoAcquisitionChannel.library]!,
            ],
          );
      addTearDown(local.dispose);
      expect(local.channels, <VideoAcquisitionChannel>[
        VideoAcquisitionChannel.library,
        VideoAcquisitionChannel.mediaServer,
      ]);
    });
  });

  test('搜索词：标题 → 原名 → 别名，按搜索口径去重并限量', () {
    final List<String> titles = videoAcquisitionSearchTitles(_reference());
    // 平假名 / 片假名归一后与原标题不同，但「ソウソウノフリーレン」与
    // 「葬送のフリーレン」不同字，所以都保留；上限 3。
    expect(titles, <String>['葬送のフリーレン', 'Sousou no Frieren', 'ソウソウノフリーレン']);
    final List<String> deduped = videoAcquisitionSearchTitles(
      VideoMediaReference(
        providerId: 'tmdb',
        mediaId: '2',
        mediaKind: VideoMetadataMediaKind.movie,
        discoveryCategory: VideoDiscoveryCategory.movie,
        title: 'Ｄｕｎｅ',
        originalTitle: 'dune',
        aliases: const <String>['  ', 'Dune Part One'],
      ),
    );
    expect(deduped, <String>['Ｄｕｎｅ', 'Dune Part One']);
  });

  group('searchVideoAcquisitionTargets', () {
    test('逐个查询词回落，首个有命中的为准；部分来源失败计数', () async {
      final List<String> queriedA = <String>[];
      final VideoAcquisitionLookup lookup = await searchVideoAcquisitionTargets(
        targets: <VideoAcquisitionSearchTarget>[
          VideoAcquisitionSearchTarget(
            id: 'a',
            name: 'A',
            search: (String query) async {
              queriedA.add(query);
              return query == 'second'
                  ? <VideoAcquisitionHit>[_hit('a1')]
                  : const <VideoAcquisitionHit>[];
            },
          ),
          VideoAcquisitionSearchTarget(
            id: 'b',
            name: 'B',
            search: (String query) async => throw StateError('down'),
          ),
        ],
        titles: const <String>['first', 'second', 'third'],
        logTag: 'test',
      );
      expect(queriedA, <String>['first', 'second']);
      expect(lookup.hits.map((VideoAcquisitionHit h) => h.id), <String>['a1']);
      expect(lookup.failedSourceCount, 1);
    });

    test('全部来源失败 = 整个渠道失败', () async {
      await expectLater(
        searchVideoAcquisitionTargets(
          targets: <VideoAcquisitionSearchTarget>[
            VideoAcquisitionSearchTarget(
              id: 'a',
              name: 'A',
              search: (String query) async => throw StateError('down'),
            ),
          ],
          titles: const <String>['q'],
          logTag: 'test',
        ),
        throwsA(isA<VideoAcquisitionChannelFailure>()),
      );
    });
  });

  group('后端', () {
    test('媒体库：找到 = 一条命中，找不到 = 无结果', () async {
      final VideoAcquisitionLookup found = await LibraryAcquisitionBackend(
        find: (VideoMediaReference reference) async => _hit('local'),
      ).lookup(_reference());
      expect(found.hits.single.id, 'local');
      final VideoAcquisitionLookup missing = await LibraryAcquisitionBackend(
        find: (VideoMediaReference reference) async => null,
      ).lookup(_reference());
      expect(missing.configured, isTrue);
      expect(missing.hits, isEmpty);
    });

    test('在线源 / 媒体服务器：没有来源 = 未配置', () async {
      final VideoAcquisitionLookup online =
          await OnlineSourceAcquisitionBackend(
            targets: () async => const <VideoAcquisitionSearchTarget>[],
          ).lookup(_reference());
      expect(online.configured, isFalse);
      final VideoAcquisitionLookup servers =
          await MediaServerAcquisitionBackend(
            sessions: () async => const <MediaServerSession>[],
          ).lookup(_reference());
      expect(servers.configured, isFalse);
    });

    Future<void> noop(Object _) async {}

    test('BT：没有注册表 / 没有适用来源 = 未配置（带添加搜索站引导）', () async {
      Future<void> configure(Object _) async {}
      final VideoAcquisitionLookup noRegistry = await TorrentAcquisitionBackend(
        registry: () => null,
        openSearch: noop,
        configure: configure,
      ).lookup(_reference());
      expect(noRegistry.configured, isFalse);
      expect(noRegistry.configure, configure);

      // 只有电影域的来源：动画作品没有适用来源。
      final VideoAcquisitionLookup noApplicable =
          await TorrentAcquisitionBackend(
            registry: () => VideoResourceRegistry(<VideoResourceProvider>[
              _FakeProvider(
                categories: const <VideoDiscoveryCategory>{
                  VideoDiscoveryCategory.movie,
                },
              ),
            ]),
            openSearch: noop,
            configure: configure,
          ).lookup(_reference());
      expect(noApplicable.configured, isFalse);
    });

    test('BT：预览前几条、报总数并挂上资源搜索入口', () async {
      final VideoAcquisitionLookup lookup = await TorrentAcquisitionBackend(
        registry: () => VideoResourceRegistry(<VideoResourceProvider>[
          _FakeProvider(
            candidates: <VideoResourceCandidate>[
              for (int i = 0; i < 5; i++)
                _FakeCandidate('r$i', seeders: 10 - i),
            ],
          ),
        ]),
        openSearch: noop,
        configure: noop,
        previewLimit: 2,
      ).lookup(_reference());
      expect(lookup.configured, isTrue);
      expect(lookup.hits, hasLength(2));
      expect(lookup.effectiveTotalCount, 5);
      expect(lookup.entry, noop);
      expect(lookup.hits.first.open, isNull, reason: 'BT 预览不能单独打开');
    });

    test('BT：全部来源失败 = 渠道失败', () async {
      await expectLater(
        TorrentAcquisitionBackend(
          registry: () => VideoResourceRegistry(<VideoResourceProvider>[
            _FakeProvider(fail: true),
          ]),
          openSearch: noop,
          configure: noop,
        ).lookup(_reference()),
        throwsA(isA<ExternalProviderFailure>()),
      );
    });
  });
}

class _FakeCandidate extends VideoResourceCandidate {
  _FakeCandidate(String id, {super.seeders})
    : super(
        providerId: 'fake',
        providerInstanceId: 'i',
        remoteId: id,
        title: 'Frieren $id',
        providerPriority: 0,
        infoHash: id.padRight(40, '0'),
      );
}

class _FakeProvider implements VideoResourceProvider {
  _FakeProvider({
    this.categories = const <VideoDiscoveryCategory>{},
    this.candidates = const <VideoResourceCandidate>[],
    this.fail = false,
  });

  @override
  final Set<VideoDiscoveryCategory> categories;
  final List<VideoResourceCandidate> candidates;
  final bool fail;

  @override
  String get id => 'fake';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    if (fail) throw StateError('site down');
    return ProviderBatchResult<VideoResourceCandidate>.success(candidates);
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() {}
}
