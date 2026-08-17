import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';

typedef _Loader = Future<ProviderBatchResult<DiscoveryResultPage>> Function(
  DiscoveryRequest request,
);

class _FakeSource extends MediaDiscoverySource {
  _FakeSource({
    required this.id,
    required this.priority,
    required DiscoveryCapabilities capabilities,
    _Loader? onSearch,
    _Loader? onBrowse,
  })  : _capabilities = capabilities,
        _onSearch = onSearch,
        _onBrowse = onBrowse;

  @override
  final String id;

  @override
  String get displayName => id;

  @override
  final int priority;

  final DiscoveryCapabilities _capabilities;
  final _Loader? _onSearch;
  final _Loader? _onBrowse;

  int searchCalls = 0;
  int browseCalls = 0;
  bool closed = false;

  @override
  DiscoveryCapabilities get capabilities => _capabilities;

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) {
    searchCalls++;
    return _onSearch!(request);
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) {
    browseCalls++;
    final _Loader? onBrowse = _onBrowse;
    if (onBrowse == null) return super.browse(request);
    return onBrowse(request);
  }

  @override
  void close() => closed = true;
}

ProviderBatchResult<DiscoveryResultPage> _pageOf(
  String sourceId,
  List<String> titles, {
  bool hasMore = false,
}) {
  return ProviderBatchResult<DiscoveryResultPage>.success(
    <DiscoveryResultPage>[
      DiscoveryResultPage(
        entries: <DiscoveryEntry>[
          for (final String title in titles)
            DiscoveryResourceItem(
              sourceId: sourceId,
              title: title,
              id: title,
              kind: DiscoveryMediaKind.novel,
              payloadKind: DiscoveryPayloadKind.httpFile,
            ),
        ],
        page: 1,
        hasMore: hasMore,
      ),
    ],
  );
}

void main() {
  final DiscoveryCapabilities novelSearch = DiscoveryCapabilities(
    kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.novel},
  );

  test('sourcesFor 按媒体域过滤并按 priority 排序', () {
    final _FakeSource a = _FakeSource(
      id: 'a',
      priority: 20,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('a', <String>[]),
    );
    final _FakeSource b = _FakeSource(
      id: 'b',
      priority: 10,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('b', <String>[]),
    );
    final _FakeSource g = _FakeSource(
      id: 'g',
      priority: 1,
      capabilities: DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
      ),
      onSearch: (DiscoveryRequest _) async => _pageOf('g', <String>[]),
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[a, b, g],
    );

    expect(
      service
          .sourcesFor(DiscoveryMediaKind.novel)
          .map((MediaDiscoverySource s) => s.id),
      <String>['b', 'a'],
    );
    expect(
      service
          .sourcesFor(DiscoveryMediaKind.game)
          .map((MediaDiscoverySource s) => s.id),
      <String>['g'],
    );
  });

  test('聚合搜索只扇出到支持该域且支持搜索的源，分片按 priority 顺序', () async {
    final _FakeSource a = _FakeSource(
      id: 'a',
      priority: 2,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('a', <String>['a1']),
    );
    final _FakeSource b = _FakeSource(
      id: 'b',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('b', <String>['b1']),
    );
    final _FakeSource noSearch = _FakeSource(
      id: 'browse-only',
      priority: 0,
      capabilities: DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.novel},
        supportsSearch: false,
        supportsBrowse: true,
      ),
      onSearch: (DiscoveryRequest _) async => _pageOf('x', <String>[]),
    );
    final _FakeSource game = _FakeSource(
      id: 'game',
      priority: 0,
      capabilities: DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
      ),
      onSearch: (DiscoveryRequest _) async => _pageOf('game', <String>[]),
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[a, b, noSearch, game],
    );

    final DiscoveryAggregateResult result = await service.load(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
    );

    expect(
      result.slices.map((DiscoverySourceSlice s) => s.sourceId),
      <String>['b', 'a'],
    );
    expect(
      result.entries.map((DiscoveryEntry e) => e.title),
      <String>['b1', 'a1'],
    );
    expect(result.successfulSourceCount, 2);
    expect(result.hasFailures, isFalse);
    expect(noSearch.searchCalls, 0);
    expect(game.searchCalls, 0);
  });

  test('单源抛异常收敛为脱敏失败，不拖垮整页（部分成功）', () async {
    final _FakeSource ok = _FakeSource(
      id: 'ok',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('ok', <String>['x']),
    );
    final _FakeSource broken = _FakeSource(
      id: 'broken',
      priority: 2,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async =>
          throw const SocketException('boom'),
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[ok, broken],
    );

    final DiscoveryAggregateResult result = await service.load(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
    );

    expect(result.isPartial, isTrue);
    expect(result.isTotalFailure, isFalse);
    expect(result.failures.single.providerId, 'broken');
    expect(result.slices.single.sourceId, 'ok');
  });

  test('指定 sourceId 只调该源；未知 sourceId 抛 ArgumentError', () async {
    final _FakeSource a = _FakeSource(
      id: 'a',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('a', <String>['a1']),
    );
    final _FakeSource b = _FakeSource(
      id: 'b',
      priority: 2,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('b', <String>['b1']),
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[a, b],
    );

    final DiscoveryAggregateResult result = await service.load(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
      sourceId: 'b',
    );
    expect(result.slices.single.sourceId, 'b');
    expect(a.searchCalls, 0);

    expect(
      () => service.load(
        const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
        sourceId: 'nope',
      ),
      throwsArgumentError,
    );
  });

  test('深层目录浏览必须指定 sourceId', () async {
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[],
    );
    expect(
      () => service.load(
        const DiscoveryRequest(kind: DiscoveryMediaKind.game, path: '/sub'),
      ),
      throwsArgumentError,
    );
  });

  test('browse 默认实现返回 unsupported 失败', () async {
    final _FakeSource searchOnly = _FakeSource(
      id: 'search-only',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('s', <String>[]),
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[searchOnly],
    );

    final DiscoveryAggregateResult result = await service.load(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
      sourceId: 'search-only',
    );

    expect(result.isTotalFailure, isTrue);
    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.unsupported,
    );
  });

  test('resolvePayload 默认返回条目自带 payload；无 payload 抛脱敏失败', () async {
    final _FakeSource source = _FakeSource(
      id: 's',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('s', <String>[]),
    );
    const DiscoveryHttpPayload payload =
        DiscoveryHttpPayload(url: 'https://example.com/f.epub');
    const DiscoveryResourceItem withPayload = DiscoveryResourceItem(
      sourceId: 's',
      title: 't',
      id: '1',
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.httpFile,
      payload: payload,
    );
    const DiscoveryResourceItem withoutPayload = DiscoveryResourceItem(
      sourceId: 's',
      title: 't',
      id: '2',
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.httpFile,
    );

    expect(await source.resolvePayload(withPayload), same(payload));
    expect(
      () => source.resolvePayload(withoutPayload),
      throwsA(isA<ExternalProviderFailure>()),
    );
  });

  test('渐进交付：快源先上屏不等慢源，分片顺序恒按 priority', () async {
    final Completer<void> slowGate = Completer<void>();
    final _FakeSource fast = _FakeSource(
      id: 'fast',
      priority: 2,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('fast', <String>['f1']),
    );
    final _FakeSource slow = _FakeSource(
      id: 'slow',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async {
        await slowGate.future;
        return _pageOf('slow', <String>['s1']);
      },
    );
    final MediaDiscoveryService service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[fast, slow],
    );

    final List<List<String>> snapshots = <List<String>>[];
    final Future<DiscoveryAggregateResult> pending = service.load(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
      onUpdate: (DiscoveryAggregateResult partial) => snapshots.add(
        partial.slices.map((DiscoverySourceSlice s) => s.sourceId).toList(),
      ),
    );
    // 快源完成后就该有一次只含 fast 的快照——不等慢源。
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.first, <String>['fast']);

    slowGate.complete();
    final DiscoveryAggregateResult result = await pending;
    // 最终快照与返回值都按 priority 序（slow priority 1 在前），
    // 与完成顺序无关。
    expect(snapshots.last, <String>['slow', 'fast']);
    expect(
      result.slices.map((DiscoverySourceSlice s) => s.sourceId),
      <String>['slow', 'fast'],
    );
  });

  test('close 逐源下发', () {
    final _FakeSource a = _FakeSource(
      id: 'a',
      priority: 1,
      capabilities: novelSearch,
      onSearch: (DiscoveryRequest _) async => _pageOf('a', <String>[]),
    );
    MediaDiscoveryService(sources: <MediaDiscoverySource>[a]).close();
    expect(a.closed, isTrue);
  });
}
