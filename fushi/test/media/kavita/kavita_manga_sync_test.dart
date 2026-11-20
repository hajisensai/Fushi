import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_manga_sync.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
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
  _Server({
    this.pageNum = 0,
    this.modifiedAt,
    this.offline = false,
    this.hang,
    this.progressStatus = 200,
  });

  int pageNum;
  int? modifiedAt;
  bool offline;

  /// 非空时 get-progress 一直挂到它完成（模拟连上了但迟迟不答的服务器）。
  Completer<void>? hang;

  /// get-progress 的 HTTP 状态（非 200 = 服务器在、但出错）。
  int progressStatus;
  int progressCalls = 0;
  int chapterInfoCalls = 0;

  /// 写请求（推进度 / 标已读）的 HTTP 状态（非 200 = 服务器在、但拒绝）。
  int writeStatus = 200;
  final List<http.Request> writes = <http.Request>[];

  /// 同一台服务器始终是同一个协议层实例（生产里由 `KavitaApiRegistry` 保证）。
  KavitaApi api() => _api ??= _newApi();
  KavitaApi? _api;

  KavitaApi _newApi() => KavitaApi(
    serverUrl: 'https://kavita.example.com',
    apiKey: 'K',
    client: MockClient((http.Request r) async {
      if (r.url.path == '/api/Plugin/authenticate') {
        return http.Response('{"token":"jwt"}', 200);
      }
      if (offline) throw http.ClientException('offline');
      if (r.url.path == '/api/Reader/get-progress') {
        progressCalls++;
        final Completer<void>? gate = hang;
        if (gate != null) await gate.future;
        if (progressStatus != 200) return http.Response('', progressStatus);
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
      if (writeStatus != 200) return http.Response('', writeStatus);
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
  late KavitaReachability reachability;
  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    stamps = InMemoryKavitaMangaSyncStampStore();
    // 每个用例一份：进程级的那份会把上一个离线用例的「不可达」带到下一个用例。
    reachability = KavitaReachability();
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
    Duration pullTimeout = const Duration(seconds: 2),
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
      reachability: reachability,
      debounce: const Duration(milliseconds: 20),
      pullTimeout: pullTimeout,
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

  group('server marked the chapter unread', () {
    // 本机读完（末页 + 已读标记），上次同步停在末页；服务器随后被标未读回 0。
    Future<_Server> arrange() async {
      await setLocal(9);
      await db.markMangaChaptersRead(
        bookUid: _uid,
        chapterKeys: <String>[_chapterKey],
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      await stamps.record(_uid, _chapterKey, now - 100 * _min, page: 9);
      return _Server(pageNum: 0, modifiedAt: now);
    }

    Future<MangaChapterStateRow?> state() =>
        db.getMangaChapterState(bookUid: _uid, chapterKey: _chapterKey);

    test('user adopts the server: read flag cleared, back to page 0', () async {
      final _Server server = await arrange();
      final KavitaMangaSyncSession? session = await attach(
        server,
        prompt: (KavitaProgress s, MangaChapterStateRow l) async =>
            KavitaSyncAction.adoptServer,
      );
      await session!.close();
      final MangaChapterStateRow row = (await state())!;
      expect(row.lastPage, 0);
      expect(row.readAt, isNull);
      expect(server.pushedPages, isEmpty);
    });

    test('no prompt (or keep local): stays read, nothing pushed', () async {
      final _Server server = await arrange();
      final KavitaMangaSyncSession? session = await attach(server);
      await session!.close();
      final MangaChapterStateRow row = (await state())!;
      expect(row.lastPage, 9);
      expect(row.readAt, isNotNull);
      expect(server.pushedPages, isEmpty);
    });

    test('series page reconcile leaves a locally read chapter alone', () async {
      await arrange();
      await reconcileKavitaChapterStates(
        db: db,
        bookUid: _uid,
        chapters: <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: _chapterKey,
            name: 'c',
            raw: const <String, Object?>{'pages': 10, 'pagesRead': 0},
          ),
        ],
      );
      expect((await state())!.readAt, isNotNull);
    });
  });

  group('alignKavitaMangaChapterMark', () {
    test('unread: clears read, page 0, baseline 0', () async {
      await setLocal(9);
      await db.markMangaChaptersRead(
        bookUid: _uid,
        chapterKeys: <String>[_chapterKey],
      );
      await alignKavitaMangaChapterMark(
        db: db,
        stamps: stamps,
        bookUid: _uid,
        chapterKey: _chapterKey,
        read: false,
        totalPages: 10,
        nowMs: () => _base,
      );
      final MangaChapterStateRow row = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: _chapterKey,
      ))!;
      expect(row.readAt, isNull);
      expect(row.lastPage, 0);
      expect(stamps.stampOf(_uid, _chapterKey), (at: _base, page: 0));
    });

    test('read: marks read, last page, baseline last page', () async {
      await alignKavitaMangaChapterMark(
        db: db,
        stamps: stamps,
        bookUid: _uid,
        chapterKey: _chapterKey,
        read: true,
        totalPages: 10,
        nowMs: () => _base,
      );
      final MangaChapterStateRow row = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: _chapterKey,
      ))!;
      expect(row.readAt, _base);
      expect(row.lastPage, 9);
      expect(stamps.stampOf(_uid, _chapterKey), (at: _base, page: 9));
    });

    test('server not updated (offline): local still marks read, baseline stays '
        'on the last known server page, next open pushes the mark', () async {
      await setLocal(3);
      await stamps.record(_uid, _chapterKey, _base, page: 3);
      await alignKavitaMangaChapterMark(
        db: db,
        stamps: stamps,
        bookUid: _uid,
        chapterKey: _chapterKey,
        read: true,
        totalPages: 10,
        serverConfirmed: false,
        knownServerPage: 3,
        nowMs: () => _base + _min,
      );
      final MangaChapterStateRow row = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: _chapterKey,
      ))!;
      expect(row.readAt, _base + _min, reason: 'local mark takes effect');
      expect(row.lastPage, 9);
      expect(stamps.stampOf(_uid, _chapterKey)?.page, 3);

      // 回到线上、服务器仍停在 3：本地离开了基线 → 开章时推本机的标记。
      final _Server server = _Server(pageNum: 3, modifiedAt: _base);
      final KavitaMangaSyncSession? session = await attach(server);
      expect(session!.adoptedPage, isNull);
      await session.close();
      expect(server.pushedPages, <int>[9]);
    });

    test(
      'offline unread without a prior baseline: the known server page becomes '
      'the baseline and the series refresh does not re-mark it read',
      () async {
        await setLocal(9);
        await db.markMangaChaptersRead(
          bookUid: _uid,
          chapterKeys: <String>[_chapterKey],
        );
        await alignKavitaMangaChapterMark(
          db: db,
          stamps: stamps,
          bookUid: _uid,
          chapterKey: _chapterKey,
          read: false,
          totalPages: 10,
          serverConfirmed: false,
          knownServerPage: 9,
          nowMs: () => _base,
        );
        expect(stamps.stampOf(_uid, _chapterKey)?.page, 9);
        // 作品页刷新拿到服务器的旧状态（仍读完）：本机未推的标未读不被改回去。
        await reconcileKavitaChapterStates(
          db: db,
          bookUid: _uid,
          chapters: <OnlineMangaChapter>[
            OnlineMangaChapter(
              key: _chapterKey,
              name: 'c',
              raw: const <String, Object?>{'pages': 10, 'pagesRead': 10},
            ),
          ],
          stamps: stamps,
          nowMs: () => _base + _min,
        );
        final MangaChapterStateRow row = (await db.getMangaChapterState(
          bookUid: _uid,
          chapterKey: _chapterKey,
        ))!;
        expect(row.readAt, isNull);
        expect(row.lastPage, 0);
      },
    );
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

  group('unreachable server is remembered (manga-d11)', () {
    setUp(() => ErrorLogService.instance.clear());

    bool unreachable(
      _Server server, {
      Duration within = const Duration(seconds: 2),
    }) => reachability.isUnreachable('srv', server.api(), within: within);

    List<ErrorLogEntry> pullDiagnostics() => ErrorLogService
        .instance
        .diagnosticEntries
        .where((ErrorLogEntry e) => e.source == 'KavitaMangaSync.pull')
        .toList();

    // 推送失败原来在 KavitaProgressSync 里被整个吞掉，关章 close() 也不记：离线 /
    // 服务器报错时进度没推出去却无迹可查（路线图 #3722 c12 遗留）。
    test('a failed push leaves one diagnostic and marks the server', () async {
      final _Server server = _Server();
      final KavitaMangaSyncSession? session = await attach(server);
      server.offline = true;
      session!.onPageSaved(_chapterKey, 3);
      await session.close();
      expect(server.pushedPages, isEmpty);
      expect(
        ErrorLogService.instance.diagnosticEntries
            .where((ErrorLogEntry e) => e.source == 'KavitaMangaSync.push')
            .length,
        1,
      );
      expect(unreachable(server), isTrue);
    });

    test('a push the server rejects is logged as an error', () async {
      final _Server server = _Server();
      final KavitaMangaSyncSession? session = await attach(server);
      server.writeStatus = 500;
      session!.onPageSaved(_chapterKey, 3);
      await session.close();
      expect(
        ErrorLogService.instance.entries
            .where((ErrorLogEntry e) => e.source == 'KavitaMangaSync.push')
            .length,
        1,
      );
      expect(unreachable(server), isFalse);
    });

    test('second open does not wait for the pull again', () async {
      final Completer<void> hang = Completer<void>();
      final _Server server = _Server(pageNum: 6, modifiedAt: _base, hang: hang);
      // 第一次：把拉取预算等满，记为不可达。
      final KavitaMangaSyncSession? first = await attach(
        server,
        pullTimeout: const Duration(milliseconds: 100),
      );
      expect(first, isNotNull);
      expect(first!.adoptedPage, isNull);
      expect(unreachable(server), isTrue);
      await first.close();

      // 第二次：预算给到 1 分钟，服务器照样挂着——等的话这条用例必超时。
      final KavitaMangaSyncSession? second = await attach(
        server,
        pullTimeout: const Duration(minutes: 1),
      );
      expect(hang.isCompleted, isFalse, reason: 'returned without the server');
      expect(second, isNotNull);
      expect(second!.adoptedPage, isNull);
      await pumpEventQueue();
      expect(hang.isCompleted, isFalse);
      expect(server.progressCalls, 2, reason: 'the pull still goes out');
      expect(await localPage(), isNull, reason: 'local untouched');
      await second.close();
      hang.complete();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test(
      'a probe answered in time clears the mark; the next open syncs fully',
      () async {
        final _Server server = _Server(
          pageNum: 6,
          modifiedAt: _base,
          offline: true,
        );
        final KavitaMangaSyncSession? first = await attach(server);
        await first!.close();
        expect(unreachable(server), isTrue);

        // 服务器回来了：这次开章不等（不采用服务器进度），但探针让标记失效。
        server.offline = false;
        final KavitaMangaSyncSession? second = await attach(server);
        expect(second!.adoptedPage, isNull);
        await second.close();
        await pumpEventQueue();
        expect(unreachable(server), isFalse);

        final KavitaMangaSyncSession? third = await attach(server);
        expect(third!.adoptedPage, 6);
        expect(await localPage(), 6);
        await third.close();
      },
    );

    test('a probe that also fails keeps the mark', () async {
      final _Server server = _Server(offline: true);
      await (await attach(server))!.close();
      await (await attach(server))!.close();
      await pumpEventQueue();
      expect(unreachable(server), isTrue);
      expect(
        pullDiagnostics(),
        hasLength(1),
        reason: 'one diagnostic per outage, not one per chapter',
      );
      expect(
        ErrorLogService.instance.entries,
        isEmpty,
        reason: 'offline is not an app error',
      );
    });

    test('a server that answers with an error is not unreachable', () async {
      final _Server server = _Server(progressStatus: 500);
      final KavitaMangaSyncSession? session = await attach(server);
      expect(session, isNotNull);
      await session!.close();
      expect(unreachable(server), isFalse);
      expect(pullDiagnostics(), isEmpty);
      final List<ErrorLogEntry> errors = ErrorLogService.instance.entries;
      expect(errors, hasLength(1));
      expect(errors.single.source, 'KavitaMangaSync.pull');
      expect(errors.single.error, contains('500'));
    });

    test(
      'any answer from the server ends the outage: the very next open syncs',
      () async {
        final _Server server = _Server(
          pageNum: 6,
          modifiedAt: _base,
          offline: true,
        );
        await (await attach(server))!.close();
        expect(unreachable(server), isTrue);

        // 服务器回来后，开章之前先有别的请求成功了（作品页刷新、浏览、取页图
        // 走的都是同一个协议层）：这一次开章就该完整对账，而不是再按离线放行。
        server.offline = false;
        await server.api().getChapterInfo(201);

        final KavitaMangaSyncSession? next = await attach(server);
        expect(next!.adoptedPage, 6);
        expect(await localPage(), 6);
        await next.close();
      },
    );

    test('an answer slower than the pull budget does not end it', () async {
      const Duration budget = Duration(milliseconds: 100);
      final Completer<void> hang = Completer<void>();
      final _Server server = _Server(pageNum: 6, modifiedAt: _base, hang: hang);
      await (await attach(server, pullTimeout: budget))!.close();
      expect(unreachable(server, within: budget), isTrue);

      // 那次拉取过了预算才答上来：等了也用不上，继续不等。
      await Future<void>.delayed(budget * 3);
      hang.complete();
      await pumpEventQueue();
      expect(unreachable(server, within: budget), isTrue);

      // 之后答得快了才算恢复。
      server.hang = null;
      await server.api().getProgress(201);
      expect(unreachable(server, within: const Duration(seconds: 30)), isFalse);
    });

    test('a replaced api instance (connection settings changed) starts '
        'fresh', () async {
      final _Server old = _Server(offline: true);
      await (await attach(old))!.close();
      expect(unreachable(old), isTrue);
      final _Server server = _Server(pageNum: 6, modifiedAt: _base);
      final KavitaMangaSyncSession? session = await attach(server);
      expect(session!.adoptedPage, 6);
      await session.close();
    });

    for (final int status in <int>[502, 503, 504]) {
      test('a gateway $status counts as unreachable: one diagnostic, no error '
          'entries', () async {
        final _Server server = _Server(progressStatus: status);
        await (await attach(server))!.close();
        await (await attach(server))!.close();
        await (await attach(server))!.close();
        await pumpEventQueue();
        expect(unreachable(server), isTrue);
        expect(pullDiagnostics(), hasLength(1));
        expect(ErrorLogService.instance.entries, isEmpty);
        expect(server.progressCalls, 3, reason: 'the probe still goes out');

        // Kavita 起来了：探针答上话，再下一次开章恢复对账。
        server
          ..progressStatus = 200
          ..pageNum = 6
          ..modifiedAt = _base;
        await (await attach(server))!.close();
        await pumpEventQueue();
        final KavitaMangaSyncSession? back = await attach(server);
        expect(back!.adoptedPage, 6);
        await back.close();
      });
    }

    test('the mark is per server', () async {
      reachability.markUnreachable('other', _Server().api());
      final _Server server = _Server(pageNum: 6, modifiedAt: _base);
      final KavitaMangaSyncSession? session = await attach(server);
      expect(session!.adoptedPage, 6);
      await session.close();
    });
  });

  group('swallowed store failures are logged', () {
    setUp(() => ErrorLogService.instance.clear());

    List<String> sources() => <String>[
      for (final ErrorLogEntry e in ErrorLogService.instance.entries) e.source,
    ];

    // 让章进度表的读写都抛库错误。
    Future<void> breakChapterStates() =>
        db.customStatement('DROP TABLE manga_chapter_states');

    test('reconcile', () async {
      await breakChapterStates();
      final int written = await reconcileKavitaChapterStates(
        db: db,
        bookUid: _uid,
        chapters: <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: _chapterKey,
            name: 'c',
            raw: const <String, Object?>{'pages': 10, 'pagesRead': 4},
          ),
        ],
      );
      expect(written, 0);
      expect(sources(), <String>['KavitaMangaSync.reconcile']);
    });

    test('align mark', () async {
      await breakChapterStates();
      await alignKavitaMangaChapterMark(
        db: db,
        stamps: stamps,
        bookUid: _uid,
        chapterKey: _chapterKey,
        read: true,
        totalPages: 10,
      );
      expect(sources(), <String>['KavitaMangaSync.alignMark']);
    });

    test('stamp write, with credentials redacted', () async {
      final PrefKavitaMangaSyncStampStore store = PrefKavitaMangaSyncStampStore(
        read: () => '',
        write: (String v) async => throw StateError(
          'write failed for https://kavita.example.com/x?apiKey=SECRET-KEY',
        ),
      );
      await store.record('a', '1', 10, page: 4);
      expect(sources(), <String>['KavitaMangaSync.recordStamp']);
      expect(
        ErrorLogService.instance.entries.single.error,
        isNot(contains('SECRET-KEY')),
      );
    });
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

  group('reconcileKavitaChapterStates', () {
    OnlineMangaChapter ch(String key, int pages, int pagesRead) =>
        OnlineMangaChapter(
          key: key,
          name: key,
          raw: <String, Object?>{'pages': pages, 'pagesRead': pagesRead},
        );

    test('adopts server progress for chapters never opened here', () async {
      final int written = await reconcileKavitaChapterStates(
        db: db,
        bookUid: _uid,
        chapters: <OnlineMangaChapter>[
          ch('1', 10, 0),
          ch('2', 10, 4),
          ch('3', 10, 10),
        ],
        nowMs: () => _base,
      );
      expect(written, 2);
      expect(
        await db.getMangaChapterState(bookUid: _uid, chapterKey: '1'),
        isNull,
      );
      final MangaChapterStateRow two = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: '2',
      ))!;
      expect(two.lastPage, 4);
      expect(two.readAt, isNull);
      final MangaChapterStateRow three = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: '3',
      ))!;
      expect(three.lastPage, 9);
      expect(three.readAt, _base);
    });

    test('keeps local mid-chapter progress, marks finished read', () async {
      await db.saveMangaChapterState(
        bookUid: _uid,
        chapterKey: '2',
        lastPage: 7,
        pageCount: 10,
      );
      await db.saveMangaChapterState(
        bookUid: _uid,
        chapterKey: '3',
        lastPage: 2,
        pageCount: 10,
      );
      await reconcileKavitaChapterStates(
        db: db,
        bookUid: _uid,
        chapters: <OnlineMangaChapter>[ch('2', 10, 4), ch('3', 10, 10)],
        nowMs: () => _base,
      );
      expect(
        (await db.getMangaChapterState(
          bookUid: _uid,
          chapterKey: '2',
        ))!.lastPage,
        7,
      );
      final MangaChapterStateRow three = (await db.getMangaChapterState(
        bookUid: _uid,
        chapterKey: '3',
      ))!;
      expect(three.readAt, _base);
    });
  });
}
