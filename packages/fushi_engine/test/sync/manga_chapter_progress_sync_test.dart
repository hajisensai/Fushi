/// 互联章级漫画进度（拍板 design-ic-manga-chapter-progress）：按章 LWW 判定、wire 编解码、host 合并。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show kSyncFutureStampToleranceMs;
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/manga_chapter_progress_sync.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:test/test.dart';

const int _now = 1800000000000;

RemoteMangaChapterState _s({
  int page = 0,
  int fraction = -1,
  int? pages,
  int? readAt,
  required int at,
}) => RemoteMangaChapterState(
  lastPage: page,
  lastFraction: fraction,
  pageCount: pages,
  readAt: readAt,
  updatedAtMs: at,
);

void main() {
  group('mangaChapterStateReplaces', () {
    test('本端没有这一章 → 收下', () {
      expect(
        mangaChapterStateReplaces(
          current: null,
          incoming: _s(page: 3, at: 1),
          nowMs: _now,
        ),
        isTrue,
      );
    });

    test('较新者胜，较旧者不盖', () {
      final RemoteMangaChapterState older = _s(page: 9, at: _now - 2000);
      final RemoteMangaChapterState newer = _s(page: 2, at: _now - 1000);
      expect(
        mangaChapterStateReplaces(current: older, incoming: newer, nowMs: _now),
        isTrue,
      );
      expect(
        mangaChapterStateReplaces(current: newer, incoming: older, nowMs: _now),
        isFalse,
      );
    });

    test('标为未读（readAt 置空、戳更新）盖掉旧的已读', () {
      expect(
        mangaChapterStateReplaces(
          current: _s(
            page: 20,
            pages: 21,
            readAt: _now - 5000,
            at: _now - 5000,
          ),
          incoming: _s(page: 20, pages: 21, at: _now - 10),
          nowMs: _now,
        ),
        isTrue,
      );
    });

    test('同戳不同内容：两个方向结论互斥（不会来回推），完全相同则都不写', () {
      final RemoteMangaChapterState a = _s(page: 4, at: _now - 100);
      final RemoteMangaChapterState b = _s(page: 4, readAt: 1, at: _now - 100);
      final bool ab = mangaChapterStateReplaces(
        current: a,
        incoming: b,
        nowMs: _now,
      );
      final bool ba = mangaChapterStateReplaces(
        current: b,
        incoming: a,
        nowMs: _now,
      );
      expect(ab, isNot(ba));
      expect(ab, isTrue, reason: '同戳时已读者胜');
      expect(
        mangaChapterStateReplaces(current: a, incoming: a, nowMs: _now),
        isFalse,
      );
    });

    test('超出未来余量的毒戳按 0 比较：持有毒戳的一端落败', () {
      final RemoteMangaChapterState poisoned = _s(
        page: 99,
        at: _now + kSyncFutureStampToleranceMs + 86400000,
      );
      final RemoteMangaChapterState sane = _s(page: 5, at: _now - 1000);
      expect(
        mangaChapterStateReplaces(
          current: sane,
          incoming: poisoned,
          nowMs: _now,
        ),
        isFalse,
      );
      expect(
        mangaChapterStateReplaces(
          current: poisoned,
          incoming: sane,
          nowMs: _now,
        ),
        isTrue,
      );
      expect(
        cappedMangaChapterState(poisoned, nowMs: _now).updatedAtMs,
        _now + kSyncFutureStampToleranceMs,
      );
    });
  });

  test('planMangaChapterStateSync：逐章分到 pull / push，相同的两边都不出现', () {
    final MangaChapterSyncPlan plan = planMangaChapterStateSync(
      local: <String, RemoteMangaChapterState>{
        'c1': _s(page: 1, at: 100),
        'c2': _s(page: 7, at: 300),
        'c4': _s(page: 2, at: 50),
      },
      remote: <String, RemoteMangaChapterState>{
        'c1': _s(page: 6, at: 200),
        'c2': _s(page: 3, at: 250),
        'c3': _s(page: 9, readAt: 400, at: 400),
        'c4': _s(page: 2, at: 50),
      },
      nowMs: _now,
    );
    expect(plan.pull.keys.toSet(), <String>{'c1', 'c3'});
    expect(plan.push.keys.toSet(), <String>{'c2'});
    expect(plan.pull['c1'], _s(page: 6, at: 200));
  });

  test('wire 编解码往返；缺 updatedAt 整份拒收', () {
    final Map<String, RemoteMangaChapterState> states =
        <String, RemoteMangaChapterState>{
          'https://src/ch/1': _s(page: 3, fraction: 250, pages: 20, at: 9),
          '第2話': _s(page: 19, pages: 20, readAt: 8, at: 10),
        };
    expect(decodeMangaChapterStates(encodeMangaChapterStates(states)), states);
    expect(
      () => decodeMangaChapterStates(<String, Object?>{
        'states': <String, Object?>{
          'c': <String, Object?>{'lastPage': 1},
        },
      }),
      throwsFormatException,
    );
  });

  group('LocalLibraryHostService 章级进度', () {
    late FushiDatabase db;
    late Directory root;
    late LocalLibraryHostService svc;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('host_manga_chapters');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      svc = LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: root,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'mihon-series',
          title: 'Series',
          epubPath: '',
          extractDir: '/tmp/mihon-series',
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'novel',
          title: 'Novel',
          epubPath: '/tmp/novel.epub',
          extractDir: '/tmp/novel',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: 1,
        ),
      );
    });

    tearDown(() async {
      await db.close();
      root.deleteSync(recursive: true);
    });

    test('不在库 / 不是漫画 → null（端点 404，不写孤儿行）', () async {
      expect(await svc.readMangaChapterProgress('missing'), isNull);
      expect(await svc.readMangaChapterProgress('novel'), isNull);
      expect(
        await svc.mergeMangaChapterProgress(
          'missing',
          <String, RemoteMangaChapterState>{'c': _s(at: 1)},
        ),
        isNull,
      );
    });

    test('按章 LWW 合并，updatedAt 逐字保留，回合并后的全部章', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      expect(await svc.readMangaChapterProgress('mihon-series'), isEmpty);
      await svc.mergeMangaChapterProgress(
        'mihon-series',
        <String, RemoteMangaChapterState>{
          'c1': _s(page: 4, at: now - 3000),
          'c2': _s(page: 10, pages: 11, readAt: now - 2000, at: now - 2000),
        },
      );
      final Map<String, RemoteMangaChapterState>? merged = await svc
          .mergeMangaChapterProgress(
            'mihon-series',
            <String, RemoteMangaChapterState>{
              // 更旧：不盖。
              'c1': _s(page: 1, at: now - 9000),
              // 更新的「标为未读」：盖掉已读。
              'c2': _s(page: 10, pages: 11, at: now - 100),
            },
          );
      expect(merged, <String, RemoteMangaChapterState>{
        'c1': _s(page: 4, at: now - 3000),
        'c2': _s(page: 10, pages: 11, at: now - 100),
      });
      final MangaChapterStateRow row = (await db.getMangaChapterState(
        bookUid: (await db.getEpubBook('mihon-series'))!.uid,
        chapterKey: 'c2',
      ))!;
      expect(row.readAt, isNull);
      expect(row.updatedAt, now - 100);
    });
  });
}
