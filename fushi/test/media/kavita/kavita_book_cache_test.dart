// 回归（PR #2565 审查）：Kavita EPUB 的缓存 / 下载两态曾经只是一个标记——缓存副本
// 从不清理（`cachedBookKeys()` 没有调用方），「移除下载」只把标记翻回去、文件与书架
// 条目都还在。这里钉住真正的两态：缓存有上限按最近使用淘汰、可一键清理；移除下载
// 真删本地书；删之前未同步的进度先推，推不出去就保留。
import 'dart:convert';
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

const int _now = 1000000;

KavitaBookBinding _binding(
  int chapterId, {
  bool cachedOnly = true,
  int? lastOpenedAt,
  int? lastPushedPage,
  int? lastPushedAt,
}) => KavitaBookBinding(
  serverConfigId: 'srv',
  seriesId: 477,
  volumeId: 4146,
  chapterId: chapterId,
  libraryId: 5,
  cachedOnly: cachedOnly,
  lastOpenedAt: lastOpenedAt,
  lastPushedPage: lastPushedPage,
  lastPushedAt: lastPushedAt,
);

/// 假 Kavita：记录推上来的页号；[offline] 时除鉴权外一律断网。
class _Server {
  _Server({this.offline = false, this.serverPage = 0, this.serverModifiedAt});

  bool offline;
  int serverPage;
  int? serverModifiedAt;
  final List<int> pushedPages = <int>[];

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
            'chapterId': 1,
            'pageNum': serverPage,
            if (serverModifiedAt != null)
              'lastModifiedUtc': DateTime.fromMillisecondsSinceEpoch(
                serverModifiedAt!,
                isUtc: true,
              ).toIso8601String(),
          }),
          200,
        );
      }
      if (r.url.path == '/api/Reader/progress') {
        pushedPages.add(
          (jsonDecode(r.body) as Map<String, Object?>)['pageNum']! as int,
        );
      }
      return http.Response('', 200);
    }),
  );
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late List<String> deleted;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('kavita_book_cache_');
    deleted = <String>[];
  });
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 删书桩：真删 DB 行（与删书原语同一个事务入口），并记下删了谁。
  Future<bool> deleteBook(String bookKey) async {
    deleted.add(bookKey);
    return await db.deleteEpubBook(bookKey) > 0;
  }

  KavitaBookService service({
    _Server? server,
    int cacheLimit = kKavitaCachedBookLimit,
  }) => KavitaBookService(
    db: db,
    tempRoot: tmp,
    deleteBook: deleteBook,
    apiFor: server == null ? null : (String _) => server.api(),
    cacheLimit: cacheLimit,
    pushTimeout: const Duration(seconds: 2),
    nowMs: () => _now,
  );

  Future<EpubBookRow> insertBook(
    String key,
    KavitaBookBinding binding, {
    int? localSection,
    int importedAt = 0,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/x/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 12,
        chaptersJson: '["c"]',
        importedAt: importedAt,
        sourceMetadata: Value<String?>(binding.encode()),
      ),
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    if (localSection != null) {
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value(row.uid),
          sectionIndex: Value(localSection),
          normCharOffset: const Value(0),
          updatedAt: const Value(10),
        ),
      );
    }
    return row;
  }

  group('trimCache', () {
    test(
      'keeps the most recently used cached copies, evicts the rest',
      () async {
        for (int i = 1; i <= 5; i++) {
          await insertBook('C$i', _binding(i, lastOpenedAt: i * 100));
        }
        await insertBook('Pinned', _binding(99, cachedOnly: false));
        final KavitaCacheCleanup result = await service(
          cacheLimit: 2,
        ).trimCache();
        expect(result.removed, 3);
        expect(deleted.toSet(), <String>{'C1', 'C2', 'C3'});
        expect(
          await service().cachedBookKeys(),
          unorderedEquals(<String>['C4', 'C5']),
        );
        expect(
          await db.getEpubBook('Pinned'),
          isNotNull,
          reason: '显式下载的副本不计入上限、也不被淘汰',
        );
      },
    );

    test('the just-opened copy is never evicted even if oldest', () async {
      await insertBook('Old', _binding(1, lastOpenedAt: 1));
      await insertBook('Mid', _binding(2, lastOpenedAt: 200));
      await insertBook('New', _binding(3, lastOpenedAt: 300));
      await service(cacheLimit: 2).trimCache(keep: 'Old');
      expect(deleted, <String>['Mid']);
    });

    test('reading position recency counts as use', () async {
      await insertBook('A', _binding(1, lastOpenedAt: 5));
      // B 打开得更早，但最近读过（位置更新于 10 > 5）。
      await insertBook('B', _binding(2, lastOpenedAt: 1), localSection: 0);
      await service(cacheLimit: 1).trimCache();
      expect(deleted, <String>['A']);
    });

    test('under the limit nothing is touched', () async {
      await insertBook('C1', _binding(1));
      final KavitaCacheCleanup result = await service().trimCache();
      expect(result.removed, 0);
      expect(deleted, isEmpty);
    });

    test('opening an existing copy stamps lastOpenedAt', () async {
      await insertBook('Have', _binding(43011, lastOpenedAt: 1));
      final String key = await service().openOrImport(
        serverConfigId: 'srv',
        api: _Server().api(),
        series: const KavitaSeries(
          id: 477,
          name: 'n',
          libraryId: 5,
          format: KavitaFormat.epub,
          pages: 12,
          pagesRead: 0,
        ),
        chapter: KavitaChapter.fromJson(<String, Object?>{
          'id': 43011,
          'volumeId': 4146,
          'pages': 12,
        }),
      );
      expect(key, 'Have');
      expect((await service().bindingFor('Have'))!.lastOpenedAt, _now);
    });
  });

  group('clearCache', () {
    test('removes every cached copy and leaves downloads alone', () async {
      await insertBook('C1', _binding(1));
      await insertBook('C2', _binding(2, lastPushedPage: 4), localSection: 4);
      await insertBook('D', _binding(3, cachedOnly: false));
      final KavitaCacheCleanup result = await service().clearCache();
      expect(result.removed, 2);
      expect(deleted.toSet(), <String>{'C1', 'C2'});
      expect(await db.getEpubBook('D'), isNotNull);
    });

    test(
      'unsynced progress without a reachable server is kept, not lost',
      () async {
        await insertBook('C1', _binding(1, lastPushedPage: 2), localSection: 7);
        final KavitaCacheCleanup offline = await service(
          server: _Server(offline: true),
        ).clearCache();
        expect(offline.removed, 0);
        expect(offline.keptUnsynced, 1);
        final KavitaCacheCleanup noServer = await service().clearCache();
        expect(noServer.keptUnsynced, 1);
        expect(deleted, isEmpty);
        expect(await db.getEpubBook('C1'), isNotNull);
      },
    );

    test(
      'unsynced progress is pushed first, then the copy is removed',
      () async {
        final _Server server = _Server();
        await insertBook('C1', _binding(1, lastPushedPage: 2), localSection: 7);
        final KavitaCacheCleanup result = await service(
          server: server,
        ).clearCache();
        expect(server.pushedPages, <int>[7]);
        expect(result.removed, 1);
        expect(deleted, <String>['C1']);
      },
    );

    test(
      'a newer server position supersedes the local one: removed without pushing',
      () async {
        // 上次同步在 100；服务器 500 时被别处推进到第 9 章，本地停在第 7 章。
        final _Server server = _Server(serverPage: 9, serverModifiedAt: 500000);
        await insertBook(
          'C1',
          _binding(1, lastPushedPage: 2, lastPushedAt: 100),
          localSection: 7,
        );
        final KavitaCacheCleanup result = await service(
          server: server,
        ).clearCache();
        expect(server.pushedPages, isEmpty, reason: '不覆盖更新的服务器进度');
        expect(result.removed, 1);
      },
    );
  });

  group('removeDownload', () {
    test('really deletes the local book (not just flipping a flag)', () async {
      await insertBook('D', _binding(3, cachedOnly: false));
      final KavitaLocalRemoval outcome = await service().removeDownload('D');
      expect(outcome, KavitaLocalRemoval.removed);
      expect(deleted, <String>['D']);
      expect(await db.getEpubBook('D'), isNull);
    });

    test('unsynced and offline: kept, downgraded to a cached copy', () async {
      await insertBook(
        'D',
        _binding(3, cachedOnly: false, lastPushedPage: 1),
        localSection: 5,
      );
      final KavitaLocalRemoval outcome = await service(
        server: _Server(offline: true),
      ).removeDownload('D');
      expect(outcome, KavitaLocalRemoval.keptUnsynced);
      expect(deleted, isEmpty);
      expect((await service().bindingFor('D'))!.cachedOnly, isTrue);
    });

    test('non-Kavita books are refused', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Plain',
          title: 'Plain',
          epubPath: '/x/p.epub',
          extractDir: '/x/p',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: 0,
        ),
      );
      expect(
        await service().removeDownload('Plain'),
        KavitaLocalRemoval.failed,
      );
      expect(await db.getEpubBook('Plain'), isNotNull);
    });
  });
}
