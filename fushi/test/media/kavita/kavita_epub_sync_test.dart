import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_epub_sync.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const int _min = 60 * 1000;
final int _base = DateTime.utc(2026, 10, 26, 8).millisecondsSinceEpoch;

KavitaServerConfig _server({bool enabled = true}) => KavitaServerConfig(
  id: 'srv',
  name: 'n',
  serverUrl: Uri.parse('https://kavita.example.com'),
  apiKey: 'K',
  enabled: enabled,
);

KavitaBookBinding _binding({int? pushedAt, int? pulledAt, int? page}) =>
    KavitaBookBinding(
      serverConfigId: 'srv',
      seriesId: 477,
      volumeId: 4146,
      chapterId: 43011,
      libraryId: 5,
      lastPushedAt: pushedAt,
      lastPulledAt: pulledAt,
      lastPushedPage: page,
    );

class _Server {
  _Server({this.pageNum = 0, this.modifiedAt, this.offline = false});

  int pageNum;
  int? modifiedAt;
  bool offline;
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
            'chapterId': 43011,
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
      writes.add(r);
      return http.Response('', 200);
    }),
  );

  List<int> get pushedPages => <int>[
    for (final http.Request r in writes)
      if (r.url.path == '/api/Reader/progress')
        (jsonDecode(r.body) as Map<String, Object?>)['pageNum']! as int,
  ];
}

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<EpubBookRow> insertBook({
    String? meta,
    int chapters = 12,
    int? localSection,
    int? localAt,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Book',
        title: 'Book',
        epubPath: '/x/Book.epub',
        extractDir: '/x/Book',
        chapterCount: chapters,
        chaptersJson: '["c"]',
        importedAt: 0,
        sourceMetadata: Value<String?>(meta),
      ),
    );
    final EpubBookRow row = (await db.getEpubBook('Book'))!;
    if (localSection != null) {
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value(row.uid),
          sectionIndex: Value(localSection),
          normCharOffset: const Value(0),
          updatedAt: Value(localAt ?? _base),
        ),
      );
    }
    return row;
  }

  Future<KavitaEpubSyncSession?> attach(
    EpubBookRow row,
    _Server server, {
    KavitaConflictPrompt? prompt,
    List<KavitaServerConfig>? servers,
  }) => KavitaEpubSyncSession.attach(
    db: db,
    row: row,
    servers: servers ?? <KavitaServerConfig>[_server()],
    apiFor: (KavitaServerConfig _) => server.api(),
    promptConflict: prompt,
    debounce: const Duration(milliseconds: 20),
    pullTimeout: const Duration(seconds: 2),
    nowMs: () => _base + 500 * _min,
  );

  test('plain books and unconfigured servers get no session', () async {
    final EpubBookRow plain = await insertBook();
    expect(await attach(plain, _Server()), isNull);
    await db.deleteEpubBook('Book');
    final EpubBookRow bound = await insertBook(meta: _binding().encode());
    expect(
      await attach(bound, _Server(), servers: <KavitaServerConfig>[]),
      isNull,
    );
    expect(
      await attach(
        bound,
        _Server(),
        servers: <KavitaServerConfig>[_server(enabled: false)],
      ),
      isNull,
    );
  });

  test('server ahead of an unread local copy: adopt its page', () async {
    final EpubBookRow row = await insertBook(meta: _binding().encode());
    final _Server server = _Server(pageNum: 7, modifiedAt: _base + 5 * _min);
    final KavitaEpubSyncSession? session = await attach(row, server);
    expect(session, isNotNull);
    final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
    expect(pos!.sectionIndex, 7);
    expect(pos.normCharOffset, 0);
    expect(
      (await db.getEpubBook('Book'))!.sourceMetadata,
      contains('lastPulledAt'),
    );
    expect(server.pushedPages, isEmpty, reason: 'adopting never writes back');
    await session!.close();
  });

  test('adopted page is clamped to the last local section', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding().encode(),
      chapters: 5,
    );
    final _Server server = _Server(pageNum: 99, modifiedAt: _base);
    await attach(row, server);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 4);
  });

  test('local ahead and synced before: pushes the local page', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, pulledAt: _base, page: 2).encode(),
      localSection: 6,
      localAt: _base + 100 * _min,
    );
    final _Server server = _Server(pageNum: 2, modifiedAt: _base);
    final KavitaEpubSyncSession? session = await attach(row, server);
    await session!.close();
    expect(server.pushedPages, <int>[6]);
  });

  test('same page both sides: nothing is written either way', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding().encode(),
      localSection: 4,
      localAt: _base,
    );
    final _Server server = _Server(pageNum: 4, modifiedAt: _base);
    final KavitaEpubSyncSession? session = await attach(row, server);
    await session!.close();
    expect(server.pushedPages, isEmpty);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 4);
  });

  test('conflict asks the user; each answer is honoured', () async {
    final String meta = _binding(pushedAt: _base, pulledAt: _base).encode();
    KavitaProgress? asked;
    // adopt server
    EpubBookRow row = await insertBook(
      meta: meta,
      localSection: 3,
      localAt: _base + 60 * _min,
    );
    _Server server = _Server(pageNum: 9, modifiedAt: _base + 120 * _min);
    KavitaEpubSyncSession? session = await attach(
      row,
      server,
      prompt: (KavitaProgress s, ReaderPositionRow? l) async {
        asked = s;
        expect(l!.sectionIndex, 3);
        return KavitaSyncAction.adoptServer;
      },
    );
    expect(asked!.pageNum, 9);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 9);
    await session!.close();
    expect(server.pushedPages, isEmpty);

    // keep local -> push
    await db.deleteEpubBook('Book');
    row = await insertBook(
      meta: meta,
      localSection: 3,
      localAt: _base + 60 * _min,
    );
    server = _Server(pageNum: 9, modifiedAt: _base + 120 * _min);
    session = await attach(
      row,
      server,
      prompt: (KavitaProgress s, ReaderPositionRow? l) async =>
          KavitaSyncAction.pushLocal,
    );
    await session!.close();
    expect(server.pushedPages, <int>[3]);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 3);
  });

  test('conflict without a prompt keeps local and does not push', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, pulledAt: _base).encode(),
      localSection: 3,
      localAt: _base + 60 * _min,
    );
    final _Server server = _Server(pageNum: 9, modifiedAt: _base + 120 * _min);
    final KavitaEpubSyncSession? session = await attach(row, server);
    await session!.close();
    expect(server.pushedPages, isEmpty);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 3);
  });

  test(
    'offline at open still yields a session and local pos is untouched',
    () async {
      final EpubBookRow row = await insertBook(
        meta: _binding().encode(),
        localSection: 5,
        localAt: _base,
      );
      final _Server server = _Server(offline: true);
      final KavitaEpubSyncSession? session = await attach(row, server);
      expect(session, isNotNull);
      expect((await db.getReaderPosition(row.uid))!.sectionIndex, 5);
      server.offline = false;
      server.pageNum = 0; // 服务器无记录：首次推送放行
      session!.onPositionSaved(6);
      await session.close();
      expect(server.pushedPages, <int>[6]);
    },
  );

  test(
    'reading pushes the last saved section on close and stamps binding',
    () async {
      final EpubBookRow row = await insertBook(meta: _binding().encode());
      final _Server server = _Server();
      final KavitaEpubSyncSession? session = await attach(row, server);
      session!.onPositionSaved(1);
      session.onPositionSaved(2);
      session.onPositionSaved(3);
      await session.close();
      expect(server.pushedPages, <int>[3]);
      // recordSync 是 fire-and-forget，让出一轮事件循环。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final KavitaBookBinding b = KavitaBookBinding.tryParse(
        (await db.getEpubBook('Book'))!.sourceMetadata,
      )!;
      expect(b.lastPushedPage, 3);
      expect(b.lastPushedAt, isNotNull);
    },
  );
}
