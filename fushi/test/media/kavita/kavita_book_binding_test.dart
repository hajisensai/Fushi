import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

KavitaBookBinding _binding({bool cachedOnly = true}) => KavitaBookBinding(
  serverConfigId: 'srv',
  seriesId: 477,
  volumeId: 4146,
  chapterId: 43011,
  libraryId: 5,
  cachedOnly: cachedOnly,
);

Future<void> _insertBook(FushiDatabase db, String key, {String? meta}) =>
    db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/x/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
        sourceMetadata: Value<String?>(meta),
      ),
    );

void main() {
  group('KavitaBookBinding', () {
    test('encode/decode round-trips every field and carries no secrets', () {
      final KavitaBookBinding b = _binding().copyWith(
        lastPushedAt: 5,
        lastPulledAt: 6,
        lastPushedPage: 3,
        bookScrollId: 'x/y',
      );
      final String json = b.encode();
      expect(json, contains(kKavitaBookMarker));
      expect(json.toLowerCase(), isNot(contains('apikey')));
      final KavitaBookBinding? back = KavitaBookBinding.tryParse(json);
      expect(back, isNotNull);
      expect(back!.serverConfigId, 'srv');
      expect(back.chapterId, 43011);
      expect(back.lastPushedAt, 5);
      expect(back.lastPulledAt, 6);
      expect(back.lastPushedPage, 3);
      expect(back.bookScrollId, 'x/y');
      expect(back.cachedOnly, isTrue);
    });

    test('foreign descriptors and garbage never parse as a binding', () {
      expect(KavitaBookBinding.tryParse(null), isNull);
      expect(KavitaBookBinding.tryParse(''), isNull);
      expect(KavitaBookBinding.tryParse('{not json'), isNull);
      expect(
        KavitaBookBinding.tryParse(
          '{"type":"hibiki-online-manga","version":3,"runtime":"interconnect"}',
        ),
        isNull,
      );
      expect(
        KavitaBookBinding.tryParse(
          '{"type":"fushi-lnreader-online","chapterId":1,"seriesId":2}',
        ),
        isNull,
      );
      expect(
        KavitaBookBinding.tryParse('{"type":"$kKavitaBookMarker"}'),
        isNull,
      );
      expect(isKavitaBookMetadata(_binding().encode()), isTrue);
    });
  });

  group('KavitaBookService', () {
    late FushiDatabase db;
    late Directory tmp;
    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('kavita_book_svc_');
    });
    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    KavitaApi apiWith(List<int> payload) => KavitaApi(
      serverUrl: 'http://kavita.test:5000',
      apiKey: 'K',
      client: MockClient((http.Request r) async {
        if (r.url.path == '/api/Plugin/authenticate') {
          return http.Response('{"token":"jwt"}', 200);
        }
        return http.Response.bytes(
          payload,
          200,
          headers: <String, String>{
            'content-disposition': 'attachment; filename="Book.epub"',
          },
        );
      }),
    );

    const KavitaSeries series = KavitaSeries(
      id: 477,
      name: 'n',
      libraryId: 5,
      format: KavitaFormat.epub,
      pages: 12,
      pagesRead: 0,
    );
    final KavitaChapter chapter = KavitaChapter.fromJson(<String, Object?>{
      'id': 43011,
      'volumeId': 4146,
      'pages': 12,
    });

    test('first open downloads, imports and writes the binding', () async {
      final List<String> imported = <String>[];
      final KavitaBookService svc = KavitaBookService(
        db: db,
        tempRoot: tmp,
        importEpub: (String path, String name) async {
          expect(File(path).existsSync(), isTrue);
          imported.add(name);
          await _insertBook(db, 'Book');
          return 'Book';
        },
      );
      final String key = await svc.openOrImport(
        serverConfigId: 'srv',
        api: apiWith(<int>[1, 2, 3]),
        series: series,
        chapter: chapter,
      );
      expect(key, 'Book');
      expect(imported, <String>['Book.epub']);
      final KavitaBookBinding? b = await svc.bindingFor('Book');
      expect(b!.chapterId, 43011);
      expect(b.volumeId, 4146);
      expect(b.libraryId, 5);
      expect(b.cachedOnly, isTrue);
      expect(tmp.listSync(), isEmpty, reason: 'temp download cleaned up');
    });

    test('second open reuses the bound book without downloading', () async {
      await _insertBook(db, 'Have', meta: _binding().encode());
      int downloads = 0;
      final KavitaBookService svc = KavitaBookService(
        db: db,
        tempRoot: tmp,
        importEpub: (String a, String b) async {
          downloads++;
          return 'never';
        },
      );
      final String key = await svc.openOrImport(
        serverConfigId: 'srv',
        api: apiWith(<int>[1]),
        series: series,
        chapter: chapter,
      );
      expect(key, 'Have');
      expect(downloads, 0);
      expect(
        await svc.findBookKey(serverConfigId: 'other', chapterId: 43011),
        isNull,
      );
    });

    test(
      'failed import removes the temp download and writes no binding',
      () async {
        final KavitaBookService svc = KavitaBookService(
          db: db,
          tempRoot: tmp,
          importEpub: (String a, String b) async => throw StateError('bad'),
        );
        await expectLater(
          svc.openOrImport(
            serverConfigId: 'srv',
            api: apiWith(<int>[9]),
            series: series,
            chapter: chapter,
          ),
          throwsStateError,
        );
        expect(tmp.listSync(), isEmpty);
        expect(await svc.cachedBookKeys(), isEmpty);
      },
    );

    test('pin/unpin toggle cachedOnly; unbound books are untouched', () async {
      await _insertBook(db, 'Have', meta: _binding().encode());
      await _insertBook(db, 'Plain');
      final KavitaBookService svc = KavitaBookService(db: db, tempRoot: tmp);
      expect(await svc.cachedBookKeys(), <String>['Have']);
      expect(await svc.pin('Have'), isTrue);
      expect((await svc.bindingFor('Have'))!.cachedOnly, isFalse);
      expect(await svc.cachedBookKeys(), isEmpty);
      expect(await svc.unpin('Have'), isTrue);
      expect(await svc.pin('Plain'), isFalse);
      expect((await db.getEpubBook('Plain'))!.sourceMetadata, isNull);
    });

    test('recordSync stamps push/pull and keeps identity', () async {
      await _insertBook(db, 'Have', meta: _binding().encode());
      final KavitaBookService svc = KavitaBookService(
        db: db,
        tempRoot: tmp,
        nowMs: () => 1234,
      );
      await svc.recordSync('Have', pushed: true, page: 7, bookScrollId: 'a');
      final KavitaBookBinding b = (await svc.bindingFor('Have'))!;
      expect(b.lastPushedAt, 1234);
      expect(b.lastPushedPage, 7);
      expect(b.lastPulledAt, isNull);
      expect(b.bookScrollId, 'a');
      expect(b.chapterId, 43011);
      await svc.recordSync('Have', pulled: true);
      expect((await svc.bindingFor('Have'))!.lastPulledAt, 1234);
    });
  });
}
