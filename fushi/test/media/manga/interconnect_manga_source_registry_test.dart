/// 「Fushi 互联」漫画来源合集：注册表（聚合 / 去重 / 本机开关 / 互联总开关）与
/// 书架侧适配器（entry → 对端 → 归一化 / 错误分类）的契约，全走假传输层。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_registry.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_source_library_adapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

const RemoteMangaSourceInfo _rawkuma = RemoteMangaSourceInfo(
  id: 'mihon:pkg.rawkuma:1',
  runtime: 'mihon',
  name: 'Rawkuma',
  language: 'ja',
);
const RemoteMangaSourceInfo _mangadex = RemoteMangaSourceInfo(
  id: 'aidoku:multi.mangadex',
  runtime: 'aidoku',
  name: 'MangaDex',
  language: 'en',
);

InterconnectMangaSourcePeer _peer(
  String name,
  List<RemoteMangaSourceInfo> sources,
) => InterconnectMangaSourcePeer(
  baseUrl: 'http://$name.local:38765',
  token: 't',
  deviceName: name,
  sources: sources,
);

class _FakeTransport implements InterconnectMangaSourceTransport {
  List<InterconnectMangaSourcePeer> peers = <InterconnectMangaSourcePeer>[];
  int probes = 0;
  Exception? failWith;
  final List<String> calls = <String>[];

  /// 非空时 probe 先等它完成（模拟慢对端）。
  Future<void>? probeGate;

  @override
  Future<List<InterconnectMangaSourcePeer>> probe() async {
    probes++;
    final Future<void>? gate = probeGate;
    if (gate != null) {
      probeGate = null;
      await gate;
    }
    return peers;
  }

  void _maybeFail() {
    final Exception? f = failWith;
    if (f != null) throw f;
  }

  @override
  Future<List<Map<String, Object?>>> filters(
    InterconnectMangaSourcePeer peer,
    String sourceId,
  ) async => const <Map<String, Object?>>[];

  @override
  Future<RemoteMangaBrowsePage> browse(
    InterconnectMangaSourcePeer peer,
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  }) async => const RemoteMangaBrowsePage(
    items: <Map<String, Object?>>[],
    hasNextPage: false,
  );

  @override
  Future<RemoteMangaSeriesDetail> details(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
  ) async {
    calls.add('details:${peer.deviceName}:$sourceId:${series['key']}');
    _maybeFail();
    return RemoteMangaSeriesDetail(
      series: <String, Object?>{...series, 'title': 'Refreshed'},
      chapters: <Map<String, Object?>>[
        <String, Object?>{
          'key': 'c1',
          'name': 'Ch 1',
          'raw': <String, Object?>{'url': 'c1'},
        },
        <String, Object?>{'name': 'no key → skipped'},
      ],
    );
  }

  @override
  Future<List<Map<String, Object?>>> pages(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  ) async {
    calls.add('pages:${peer.deviceName}:$sourceId:${chapter['key']}');
    _maybeFail();
    return <Map<String, Object?>>[
      <String, Object?>{'index': 0, 'url': 'p0'},
      <String, Object?>{'index': 1, 'url': 'p1'},
    ];
  }

  @override
  Future<Uint8List> pageImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  ) async {
    calls.add('image:${peer.deviceName}:$sourceId:${page['url']}');
    return Uint8List.fromList(<int>[1, (page['index'] as num).toInt()]);
  }

  @override
  Future<Uint8List> coverImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    String url,
  ) async {
    calls.add('cover:${peer.deviceName}:${series['key']}:$url');
    return Uint8List.fromList(<int>[9]);
  }
}

void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  late PreferencesRepository prefs;
  late _FakeTransport transport;
  late InterconnectMangaSourceRegistry registry;
  DateTime clock = DateTime(2026, 9, 13, 12);

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setInterconnectEnabled(true);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    transport = _FakeTransport()
      ..peers = <InterconnectMangaSourcePeer>[
        _peer('desk', <RemoteMangaSourceInfo>[_rawkuma]),
        // 第二台也有 Rawkuma：去重后仍按第一台走。
        _peer('mac', <RemoteMangaSourceInfo>[_rawkuma, _mangadex]),
      ];
    registry = InterconnectMangaSourceRegistry(
      transport: transport,
      syncRepository: repo,
      prefs: prefs,
      now: () => clock,
    );
  });

  tearDown(() async {
    registry.dispose();
    prefs.dispose();
    await db.close();
  });

  group('registry', () {
    test('按源 id 去重、保留先探到的对端；enabledSources 尊重本机开关', () async {
      await registry.refresh();
      expect(registry.interconnectEnabled, isTrue);
      expect(
        registry.sources.map((InterconnectRemoteSource s) => s.id),
        <String>['mihon:pkg.rawkuma:1', 'aidoku:multi.mangadex'],
      );
      expect(registry.sources.first.peer.deviceName, 'desk');
      expect(registry.enabledSources, hasLength(2));

      await prefs.setMangaInterconnectSourceEnabled(
        'mihon:pkg.rawkuma:1',
        false,
      );
      expect(registry.isSourceEnabled('mihon:pkg.rawkuma:1'), isFalse);
      expect(
        registry.enabledSources.map((InterconnectRemoteSource s) => s.id),
        <String>['aidoku:multi.mangadex'],
      );
      // 来源页要把关掉的也列出来给用户开回去。
      expect(registry.sources, hasLength(2));

      await prefs.setMangaInterconnectSourcesEnabled(false);
      expect(registry.enabledSources, isEmpty);
      expect(registry.libraryEnabled, isFalse);
    });

    test('互联总开关关着：快照恒空、不探对端；广播打开后重探', () async {
      await repo.setInterconnectEnabled(false);
      await registry.refresh();
      expect(transport.probes, 0);
      expect(registry.sources, isEmpty);
      expect(registry.libraryEnabled, isFalse);

      // 唯一写方法会 bump revision → 注册表自己重探。
      await repo.setInterconnectEnabled(true);
      await Future<void>.delayed(Duration.zero);
      await registry.refresh();
      expect(transport.probes, greaterThanOrEqualTo(1));
      expect(registry.sources, hasLength(2));
      expect(registry.libraryEnabled, isTrue);
    });

    test('ensureFresh 节流；并发 refresh 合并；resolve 未命中时重探一次', () async {
      await registry.ensureFresh();
      await registry.ensureFresh();
      expect(transport.probes, 1);
      await Future.wait(<Future<void>>[registry.refresh(), registry.refresh()]);
      expect(transport.probes, 2);

      transport.peers = <InterconnectMangaSourcePeer>[
        _peer('desk', <RemoteMangaSourceInfo>[
          _rawkuma,
          const RemoteMangaSourceInfo(
            id: 'mihon:new:7',
            runtime: 'mihon',
            name: 'New',
            language: 'ja',
          ),
        ]),
      ];
      // 快照没过期：未命中不重探（对端离线时不能每次都探）。
      expect(await registry.resolve('mihon:new:7'), isNull);
      expect(transport.probes, 2);
      // 过期后未命中才重探一次，探到新源。
      clock = clock.add(registry.staleAfter + const Duration(seconds: 1));
      final InterconnectRemoteSource? found = await registry.resolve(
        'mihon:new:7',
      );
      expect(found?.name, 'New');
      expect(transport.probes, 3);
      expect(await registry.resolve('mihon:none:0'), isNull);
      expect(transport.probes, 3);
    });
  });

  group('adapter', () {
    late InterconnectSourceLibraryAdapter adapter;
    late OnlineMangaLibraryEntry entry;

    setUp(() {
      adapter = InterconnectSourceLibraryAdapter(
        registry: registry,
        transport: transport,
      );
      entry = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.interconnectSource,
        extensionPackage: kInterconnectMangaPackage,
        sourceId: 'aidoku:multi.mangadex',
        series: const OnlineMangaSeries(
          key: 'series-1',
          title: 'Seed',
          raw: <String, Object?>{'key': 'series-1'},
        ),
        chapters: const <OnlineMangaChapter>[],
      );
    });

    test('身份：bookKey 前缀 = 新运行时 wire 值、不含对端设备', () {
      final String key = OnlineMangaLibraryService.bookKeyOf(entry);
      expect(key, startsWith('interconnect_source-'));
      expect(
        OnlineMangaRuntimeKind.fromWire('interconnect_source'),
        OnlineMangaRuntimeKind.interconnectSource,
      );
      // 描述符往返：runtime / sourceId 原样落库、再解析。
      final OnlineMangaLibraryEntry? parsed = OnlineMangaLibraryEntry.tryParse(
        entry.encode(),
      );
      expect(parsed?.runtime, OnlineMangaRuntimeKind.interconnectSource);
      expect(parsed?.sourceId, 'aidoku:multi.mangadex');
    });

    test(
      'refresh / resolveChapterPages / fetchChapterPage 定向打提供该源的对端',
      () async {
        final OnlineMangaRefreshResult result = await adapter.refresh(entry);
        expect(result.series.title, 'Refreshed');
        expect(result.series.key, 'series-1');
        expect(result.chapters.map((OnlineMangaChapter c) => c.key), <String>[
          'c1',
        ]);
        expect(
          transport.calls,
          contains('details:mac:aidoku:multi.mangadex:series-1'),
        );

        final List<OnlineMangaPageRef> pages = await adapter
            .resolveChapterPages(entry: entry, chapter: result.chapters.single);
        expect(pages, hasLength(2));
        expect(pages[1].index, 1);
        expect(await adapter.fetchChapterPage(pages[1]), <int>[1, 1]);
        expect(transport.calls, contains('image:mac:aidoku:multi.mangadex:p1'));
        expect(await adapter.sourceLabel(entry), 'MangaDex · mac');
        expect(await adapter.fetchCover(entry, 'https://x/c.jpg'), <int>[9]);
        expect(transport.calls, contains('cover:mac:series-1:https://x/c.jpg'));
      },
    );

    test('resolve 未命中按 staleAfter 节流：对端离线时不会每页都重探', () async {
      await registry.refresh();
      final int before = transport.probes;
      for (int i = 0; i < 5; i++) {
        expect(await registry.resolve('mihon:none:$i'), isNull);
      }
      expect(transport.probes, before);
    });

    test('探测在飞时切互联总开关：本轮完成后自动再探一轮', () async {
      final Completer<void> gate = Completer<void>();
      transport.probeGate = gate.future;
      final Future<void> first = registry.refresh();
      await repo.setInterconnectEnabled(false);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await first;
      // 第二轮读到总开关已关 → 快照清空、不再探对端。
      await Future<void>.delayed(Duration.zero);
      await registry.refresh();
      expect(registry.interconnectEnabled, isFalse);
      expect(registry.sources, isEmpty);
    });

    test('没有对端提供该源 → sourceDisabled；对端运行时错误 → runtimeFailure', () async {
      final OnlineMangaLibraryEntry orphan = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.interconnectSource,
        extensionPackage: kInterconnectMangaPackage,
        sourceId: 'mihon:gone:0',
        series: entry.series,
        chapters: const <OnlineMangaChapter>[],
      );
      await expectLater(
        adapter.refresh(orphan),
        throwsA(
          isA<OnlineMangaUnavailable>().having(
            (OnlineMangaUnavailable e) => e.reason,
            'reason',
            OnlineMangaUnavailableReason.sourceDisabled,
          ),
        ),
      );
      expect(await adapter.sourceLabel(orphan), isNull);

      transport.failWith = const InterconnectMangaSourceException(
        HostMangaSourceException.codeCloudflare,
        'blocked',
      );
      await expectLater(
        adapter.refresh(entry),
        throwsA(
          isA<OnlineMangaUnavailable>()
              .having(
                (OnlineMangaUnavailable e) => e.reason,
                'reason',
                OnlineMangaUnavailableReason.runtimeFailure,
              )
              .having(
                (OnlineMangaUnavailable e) => e.stage,
                'stage',
                'details',
              ),
        ),
      );
    });

    test('presetSource 优先于注册表；只接受自己的 PageRef', () async {
      final InterconnectRemoteSource preset = InterconnectRemoteSource(
        info: _mangadex,
        peer: _peer('preset', <RemoteMangaSourceInfo>[_mangadex]),
      );
      final InterconnectSourceLibraryAdapter withPreset =
          InterconnectSourceLibraryAdapter(
            registry: registry,
            transport: transport,
            presetSource: preset,
          );
      await withPreset.refresh(entry);
      expect(transport.calls.last, startsWith('details:preset:'));
      expect(transport.probes, 0);
      expect(
        () => withPreset.fetchChapterPage(
          const InterconnectMangaPageRef(
            index: 0,
            bookKey: 'b',
            remoteIndex: 0,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
