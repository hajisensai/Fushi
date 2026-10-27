import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_manga_sync.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const int _min = 60 * 1000;
final int _base = DateTime.utc(2026, 10, 26, 8).millisecondsSinceEpoch;
const String _uid = 'book-uid-1';
const String _chapterKey = '201';

KavitaServerConfig _server({bool enabled = true}) => KavitaServerConfig(
  id: 'srv',
  name: 'n',
  serverUrl: Uri.parse('https://kavita.example.com'),
  apiKey: 'K',
  enabled: enabled,
);

OnlineMangaChapter _chapter({bool withIds = true, String key = _chapterKey}) =>
    OnlineMangaChapter(
      key: key,
      name: 'Ch. 5',
      number: 5,
      raw: <String, Object?>{
        'chapterId': int.tryParse(key),
        if (withIds) 'volumeId': 11,
        if (withIds) 'pages': 10,
      },
    );

OnlineMangaLibraryEntry _entry({
  OnlineMangaRuntimeKind runtime = OnlineMangaRuntimeKind.kavita,
  bool withIds = true,
}) => OnlineMangaLibraryEntry(
  runtime: runtime,
  extensionPackage: kKavitaMangaPackage,
  sourceId: 'srv',
  series: OnlineMangaSeries(
    key: '42',
    title: 'Series',
    raw: <String, Object?>{'seriesId': 42, if (withIds) 'libraryId': 1},
  ),
  chapters: <OnlineMangaChapter>[_chapter(withIds: withIds)],
);

class _Server {
  _Server({this.pageNum = 0, this.modifiedAt, this.offline = false});

  int pageNum;
  int? modifiedAt;
  bool offline;
  int chapterInfoCalls = 0;
  final List<http.Request> writes = <http.Request>[];

  KavitaApi api() => KavitaApi(
    serverUrl: 'https://kavita.example.com',
    apiKey: 'K',
    client: MockClient((http.Request r) async {
      if (r.url.path == '/api/Plugin/authenticate') {
        return http.Response('{"token":"jwt"}', 200);
      }
      if (offline) throw http.ClientException('offline');
      if (r.url.path == '/api/Reader/get-progress') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'chapterId': 201,
            'pageNum': pageNum,
            if (modifiedAt != null)
              'lastModifiedUtc': DateTime.fromMillisecondsSinceEpoch(
                modifiedAt!,
                isUtc: true,
              ).toIso8601String(),
          }),
          200,
        );
      }
      if (r.url.path == '/api/Reader/chapter-info') {
        chapterInfoCalls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'pages': 8,
            'seriesId': 42,
            'volumeId': 11,
            'libraryId': 1,
            'seriesFormat': 1,
          }),
          200,
        );
      }
      writes.add(r);
      return http.Response('', 200);
    }),
  );

  List<Map<String, Object?>> get pushed => <Map<String, Object?>>[
    for (final http.Request r in writes)
      if (r.url.path == '/api/Reader/progress')
        jsonDecode(r.body) as Map<String, Object?>,
  ];

  List<int> get pushedPages => <int>[
    for (final Map<String, Object?> body in pushed) body['pageNum']! as int,
  ];

  int get markReadCalls => writes
      .where((http.Request r) => r.url.path == '/api/Reader/mark-multiple-read')
      .length;
}

void main() {
  late FushiDatabase db;
  late InMemoryKavitaMangaSyncStampStore stamps;
  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    stamps = InMemoryKavitaMangaSyncStampStore();
  });
  tearDown(() => db.close());

  Future<void> setLocal(int page) => db.saveMangaChapterState(
    bookUid: _uid,
    chapterKey: _chapterKey,
    lastPage: page,
    pageCount: 10,
  );

  Future<int?> localPage() async => (await db.getMangaChapterState(
    bookUid: _uid,
    chapterKey: _chapterKey,
  ))?.lastPage;

  Future<KavitaMangaSyncSession?> attach(
    _Server server, {
    OnlineMangaLibraryEntry? entry,
    KavitaMangaConflictPrompt? prompt,
    List<KavitaServerConfig>? servers,
    int? nowMs,
  }) {
    final OnlineMangaLibraryEntry e = entry ?? _entry();
    return KavitaMangaSyncSession.attach(
      db: db,
      bookUid: _uid,
      entry: e,
      chapter: e.chapters.single,
      servers: servers ?? <KavitaServerConfig>[_server()],
      apiFor: (KavitaServerConfig _) => server.api(),
      stamps: stamps,
      promptConflict: prompt,
      debounce: const Duration(milliseconds: 20),
      pullTimeout: const Duration(seconds: 2),
      nowMs: () => nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  test('non-Kavita entries and unusable servers get no session', () async {
    expect(
      await attach(
        _Server(),
        entry: _entry(runtime: OnlineMangaRuntimeKind.interconnect),
      ),
      isNull,
    );
    expect(await attach(_Server(), servers: <KavitaServerConfig>[]), isNull);
    expect(
      await attach(
        _Server(),
        servers: <KavitaServerConfig>[_server(enabled: false)],
      ),
      isNull,
    );
  });

  test('server ahead of an unread chapter: adopt its page', () async {
    final _Server server = _Server(pageNum: 6, modifiedAt: _base);
    final KavitaMangaSyncSession? session = await attach(server);
    expect(session, isNotNull);
    expect(session!.adoptedPage, 6);
    expect(await localPage(), 6);
    expect(stamps.lastSyncAt(_uid, _chapterKey), isNotNull);
    await session.close();
    expect(server.pushedPages, isEmpty, reason: 'adopting never writes back');
    expect(server.chapterInfoCalls, 0, reason: 'descriptor ids suffice');
  });

  test('adopted page is clamped to the chapter page count', () async {
    final _Server server = _Server(pageNum: 99, modifiedAt: _base);
    final KavitaMangaSyncSession? session = await attach(server);
    expect(session!.adoptedPage, 9);
    final MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: _uid,
      chapterKey: _chapterKey,
    ))!;
    expect(state.lastPage, 9);
    expect(state.readAt, isNotNull, reason: 'server finished the chapter');
    await session.close();
  });

  test('missing descriptor ids fall back to chapter-info', () async {
    final _Server server = _Server(pageNum: 99, modifiedAt: _base);
    final KavitaMangaSyncSession? session = await attach(
      server,
      entry: _entry(withIds: false),
    );
    expect(server.chapterInfoCalls, 1);
    expect(session!.pageCount, 8);
    expect(session.adoptedPage, 7);
    await session.close();
  });

  test('local ahead and synced before: pushes the local page', () async {
    await setLocal(7);
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 上次同步在本地这次推进之前很久；服务器自那以后没动。
    await stamps.record(_uid, _chapterKey, now - 100 * _min);
    final _Server server = _Server(pageNum: 2, modifiedAt: now - 101 * _min);
    final KavitaMangaSyncSession? session = await attach(server);
    expect(session!.adoptedPage, isNull);
    await session.close();
    expect(server.pushedPages, <int>[7]);
    expect(server.pushed.single['seriesId'], 42);
    expect(server.pushed.single['volumeId'], 11);
    expect(server.pushed.single['libraryId'], 1);
    expect(server.pushed.single['chapterId'], 201);
    expect(await localPage(), 7);
  });

  test('same page both sides: nothing is written', () async {
    await setLocal(4);
    final _Server server = _Server(pageNum: 4, modifiedAt: _base);
    final KavitaMangaSyncSession? session = await attach(server);
    await session!.close();
    expect(server.pushedPages, isEmpty);
    expect(await localPage(), 4);
  });

  test('local still on the last agreed page: a newer server page is adopted '
      'without a conflict prompt (same-page saves are not movement)', () async {
    // 本地上次与服务器在第 3 页一致；之后同页标已读等落库把 updatedAt 推到现在，
    // 另一台设备读到第 8 页。本地没离开一致的页，不该弹冲突。
    await setLocal(3);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await stamps.record(_uid, _chapterKey, now - 100 * _min, page: 3);
    final _Server server = _Server(pageNum: 8, modifiedAt: now);
    bool prompted = false;
    final KavitaMangaSyncSession? session = await attach(
      server,
      prompt: (KavitaProgress s, MangaChapterStateRow l) async {
        prompted = true;
        return KavitaSyncAction.none;
      },
    );
    expect(prompted, isFalse);
    expect(session!.adoptedPage, 8);
    expect(await localPage(), 8);
    expect(stamps.stampOf(_uid, _chapterKey)?.page, 8);
    await session.close();
    expect(server.pushedPages, isEmpty);
  });

  test('pref stamp store keeps the agreed page across records', () async {
    String stored = '';
    final PrefKavitaMangaSyncStampStore store = PrefKavitaMangaSyncStampStore(
      read: () => stored,
      write: (String v) async => stored = v,
    );
    await store.record('a', '1', 10, page: 4);
    expect(store.stampOf('a', '1'), (at: 10, page: 4));
    // 拉取后两侧仍不一致（page 为 null）：只刷时刻，保留旧的页级基线。
    await store.record('a', '1', 20);
    expect(store.stampOf('a', '1'), (at: 20, page: 4));
  });

  group('conflict asks the user', () {
    // 两侧都在上次同步之后动过、页号不同。
    Future<_Server> arrange() async {
      await setLocal(3);
      final int now = DateTime.now().millisecondsSinceEpoch;
      await stamps.record(_uid, _chapterKey, now - 100 * _min);
      return _Server(pageNum: 8, modifiedAt: now);
    }

    final List<({KavitaSyncAction answer, int local, List<int> pushed})> cases =
        <({KavitaSyncAction answer, int local, List<int> pushed})>[
          (answer: KavitaSyncAction.adoptServer, local: 8, pushed: <int>[]),
          (answer: KavitaSyncAction.pushLocal, local: 3, pushed: <int>[3]),
          (answer: KavitaSyncAction.none, local: 3, pushed: <int>[]),
        ];
    for (final c in cases) {
      test('answer ${c.answer.name}', () async {
        final _Server server = await arrange();
        KavitaProgress? asked;
        final KavitaMangaSyncSession? session = await attach(
          server,
          prompt: (KavitaProgress s, MangaChapterStateRow l) async {
            asked = s;
            expect(l.lastPage, 3);
            return c.answer;
          },
        );
        expect(asked!.pageNum, 8);
        await session!.close();
        expect(await localPage(), c.local);
        expect(server.pushedPages, c.pushed);
      });
    }

    test('without a prompt keeps local and does not push', () async {
      final _Server server = await arrange();
      final KavitaMangaSyncSession? session = await attach(server);
      await session!.close();
      expect(await localPage(), 3);
      expect(server.pushedPages, isEmpty);
    });
  });

  test('offline at open: session still opens, local untouched', () async {
    await setLocal(5);
    final _Server server = _Server(offline: true);
    final Stopwatch watch = Stopwatch()..start();
    final KavitaMangaSyncSession? session = await attach(server);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(session, isNotNull);
    expect(session!.adoptedPage, isNull);
    expect(await localPage(), 5);
    // 回到在线：服务器无记录，首次推送前校验放行。
    server.offline = false;
    session.onPageSaved(_chapterKey, 6);
    await session.close();
    expect(server.pushedPages, <int>[6]);
  });

  test('offline and no descriptor ids: no session (cannot push)', () async {
    final _Server server = _Server(offline: true);
    expect(await attach(server, entry: _entry(withIds: false)), isNull);
  });

  test(
    'reading pushes the last page only and ignores other chapters',
    () async {
      final _Server server = _Server();
      final KavitaMangaSyncSession? session = await attach(server);
      session!.onPageSaved(_chapterKey, 1);
      session.onPageSaved(_chapterKey, 2);
      session.onPageSaved('999', 5);
      session.onPageSaved(_chapterKey, 3);
      await session.close();
      expect(server.pushedPages, <int>[3]);
      expect(server.markReadCalls, 0);
    },
  );

  test('reaching the last page marks the chapter read on Kavita', () async {
    final _Server server = _Server();
    final KavitaMangaSyncSession? session = await attach(server);
    session!.onPageSaved(_chapterKey, 9);
    await session.close();
    expect(server.pushedPages, <int>[9]);
    expect(server.markReadCalls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(stamps.lastSyncAt(_uid, _chapterKey), isNotNull);
  });

  test('pref stamp store round-trips and caps its size', () async {
    String stored = '';
    final PrefKavitaMangaSyncStampStore store = PrefKavitaMangaSyncStampStore(
      read: () => stored,
      write: (String v) async => stored = v,
      maxEntries: 2,
    );
    expect(store.lastSyncAt('a', '1'), isNull);
    await store.record('a', '1', 10);
    await store.record('a', '2', 20);
    await store.record('a', '3', 30);
    expect(store.lastSyncAt('a', '1'), isNull, reason: 'oldest dropped');
    expect(store.lastSyncAt('a', '2'), 20);
    expect(store.lastSyncAt('a', '3'), 30);
    expect(stored, isNot(contains('K')), reason: 'no credentials');
    stored = 'not json';
    expect(store.lastSyncAt('a', '2'), isNull);
  });
}
