import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_progress_refresher.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
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
  _Server({
    this.pageNum = 0,
    this.modifiedAt,
    this.offline = false,
    this.infoPages,
  });

  int pageNum;
  int? modifiedAt;
  bool offline;

  /// `Reader/chapter-info` 报的页数；null = 该接口不可用（旧行为：放行）。
  int? infoPages;
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
      if (r.url.path == '/api/Reader/chapter-info' && infoPages != null) {
        return http.Response(
          jsonEncode(<String, Object?>{'pages': infoPages}),
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

  int clock = _base + 500 * _min;
  KavitaProgressRefresher refresher() =>
      KavitaProgressRefresher(nowMs: () => clock);

  Future<int> run(
    KavitaProgressRefresher r,
    _Server server, {
    bool force = false,
    List<KavitaServerConfig>? servers,
  }) => r.refresh(
    db: db,
    servers: servers ?? <KavitaServerConfig>[_server()],
    apiFor: (KavitaServerConfig _) => server.api(),
    force: force,
  );

  test('server moved since last sync: adopts page and records pull', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 3).encode(),
      localSection: 3,
    );
    final _Server server = _Server(pageNum: 9, modifiedAt: _base + 60 * _min);
    expect(await run(refresher(), server), 1);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 9);
    final String meta = (await db.getEpubBook('Book'))!.sourceMetadata!;
    expect(meta, contains('lastPulledAt'));
    expect(server.pushedPages, isEmpty);
  });

  test('conflict (both moved) is left untouched', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 3).encode(),
      localSection: 5,
      localAt: _base + 30 * _min,
    );
    final _Server server = _Server(pageNum: 9, modifiedAt: _base + 60 * _min);
    expect(await run(refresher(), server), 0);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 5);
  });

  test('server reset to page 0 is a conflict, not adopted', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 6).encode(),
      localSection: 6,
    );
    final _Server server = _Server(pageNum: 0, modifiedAt: _base + 60 * _min);
    expect(await run(refresher(), server), 0);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 6);
  });

  test('spine count mismatch is skipped', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 3).encode(),
      localSection: 3,
    );
    final _Server server = _Server(
      pageNum: 9,
      modifiedAt: _base + 60 * _min,
      infoPages: 13,
    );
    expect(await run(refresher(), server), 0);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 3);
  });

  test('offline is a silent no-op', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 3).encode(),
      localSection: 3,
    );
    final _Server server = _Server(offline: true);
    expect(await run(refresher(), server), 0);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 3);
  });

  test('plain books and missing servers are ignored', () async {
    await insertBook(localSection: 2);
    final _Server server = _Server(pageNum: 9, modifiedAt: _base + 60 * _min);
    expect(await run(refresher(), server), 0);
    await db.deleteEpubBook('Book');
    await insertBook(meta: _binding().encode());
    expect(await run(refresher(), server, servers: <KavitaServerConfig>[]), 0);
  });

  test('throttled within the interval, runs again after it', () async {
    final EpubBookRow row = await insertBook(
      meta: _binding(pushedAt: _base, page: 3).encode(),
      localSection: 3,
    );
    final KavitaProgressRefresher r = refresher();
    final _Server stale = _Server(pageNum: 3, modifiedAt: _base);
    expect(await run(r, stale), 0);
    final _Server moved = _Server(pageNum: 9, modifiedAt: _base + 60 * _min);
    clock += _min;
    expect(await run(r, moved), 0, reason: 'inside 3 minute window');
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 3);
    clock += 5 * _min;
    expect(await run(r, moved), 1);
    expect((await db.getReaderPosition(row.uid))!.sectionIndex, 9);
  });
}
