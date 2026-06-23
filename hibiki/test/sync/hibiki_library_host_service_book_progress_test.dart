import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// host-apply 测试（TODO-767 / BUG-417）：互联书籍进度 live 端点必须真读写 host
/// 自己的 `reader_positions` DB（修复根因：旧路径只把进度写进 host 永不回灌 DB 的
/// WebDAV 文件箱 progress_*.json）。
AppModelLibraryHostService _svc(HibikiDatabase db) =>
    AppModelLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

Future<void> _seedLocalPosition(
  HibikiDatabase db, {
  required String bookKey,
  required int sectionIndex,
  required int normCharOffset,
  required int charOffset,
  required int updatedAt,
}) =>
    db.upsertReaderPosition(ReaderPositionsCompanion(
      bookKey: Value(bookKey),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      charOffset: Value(charOffset),
      updatedAt: Value(updatedAt),
    ));

/// 把书 [bookKey] 插进 host 自己的 epub_books 表（真实场景：host 有这本书才允许
/// 接受其进度 PUT；putBookProgress 的存在性闸门要求 host 书库先有该书）。
Future<void> _seedHostBook(HibikiDatabase db, String bookKey) =>
    db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp/$bookKey',
      chapterCount: 3,
      chaptersJson: '["ch1","ch2","ch3"]',
      importedAt: 1700000000000,
    ));

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('resolveBookProgressSync 纯函数', () {
    test('remote 时间戳更新 → 取 remote', () {
      final RemoteBookProgress winner = resolveBookProgressSync(
        local: const RemoteBookProgress(
            sectionIndex: 1,
            normCharOffset: 100,
            charOffset: 5,
            updatedAtMs: 10),
        remote: const RemoteBookProgress(
            sectionIndex: 3,
            normCharOffset: 200,
            charOffset: 9,
            updatedAtMs: 20),
      );
      expect(winner.sectionIndex, 3);
      expect(winner.normCharOffset, 200);
      expect(winner.updatedAtMs, 20);
    });

    test('local 时间戳更新 → 取 local', () {
      final RemoteBookProgress winner = resolveBookProgressSync(
        local: const RemoteBookProgress(
            sectionIndex: 5,
            normCharOffset: 50,
            charOffset: 1,
            updatedAtMs: 99),
        remote: const RemoteBookProgress(
            sectionIndex: 1, normCharOffset: 10, charOffset: 1, updatedAtMs: 1),
      );
      expect(winner.sectionIndex, 5);
      expect(winner.updatedAtMs, 99);
    });

    test('时间戳相等 → 取读得更远者（先比 section 再比 normCharOffset）', () {
      final RemoteBookProgress winner = resolveBookProgressSync(
        local: const RemoteBookProgress(
            sectionIndex: 2,
            normCharOffset: 100,
            charOffset: 1,
            updatedAtMs: 7),
        remote: const RemoteBookProgress(
            sectionIndex: 2,
            normCharOffset: 300,
            charOffset: 1,
            updatedAtMs: 7),
      );
      expect(winner.normCharOffset, 300); // remote 更远
    });

    test('两侧都无记录（updatedAt=0）→ 取位置更靠后者', () {
      final RemoteBookProgress winner = resolveBookProgressSync(
        local: RemoteBookProgress.empty,
        remote: const RemoteBookProgress(
            sectionIndex: 1, normCharOffset: 0, charOffset: -1, updatedAtMs: 0),
      );
      expect(winner.sectionIndex, 1);
    });
  });

  group('getBookProgress', () {
    test('host 无记录 → empty', () async {
      final AppModelLibraryHostService svc = _svc(db);
      final RemoteBookProgress p = await svc.getBookProgress('BookX');
      expect(p.updatedAtMs, 0);
      expect(p.sectionIndex, 0);
      expect(p.charOffset, -1);
    });

    test('host 有 reader_positions 行 → 返回真实字段', () async {
      await _seedLocalPosition(db,
          bookKey: 'BookA',
          sectionIndex: 4,
          normCharOffset: 4500,
          charOffset: 1234,
          updatedAt: 1700000000000);
      final AppModelLibraryHostService svc = _svc(db);
      final RemoteBookProgress p = await svc.getBookProgress('BookA');
      expect(p.sectionIndex, 4);
      expect(p.normCharOffset, 4500);
      expect(p.charOffset, 1234);
      expect(p.updatedAtMs, 1700000000000);
    });
  });

  group('putBookProgress（host-apply：真写 reader_positions）', () {
    test('PUT 新进度 → host reader_positions 真更新（GET 拉回一致）', () async {
      await _seedHostBook(db, 'BookB');
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putBookProgress(
        'BookB',
        const RemoteBookProgress(
            sectionIndex: 2,
            normCharOffset: 3000,
            charOffset: 777,
            updatedAtMs: 1700000000000),
      );

      // 直查 DB：真行落地（这正是旧路径缺失的——host 从不回灌 DB）。
      final ReaderPositionRow? row = await db.getReaderPosition('BookB');
      expect(row, isNotNull);
      expect(row!.sectionIndex, 2);
      expect(row.normCharOffset, 3000);
      expect(row.charOffset, 777);
      expect(row.updatedAt, 1700000000000);

      // GET 端点拉回同值。
      final RemoteBookProgress got = await svc.getBookProgress('BookB');
      expect(got.sectionIndex, 2);
      expect(got.normCharOffset, 3000);
      expect(got.updatedAtMs, 1700000000000);
    });

    test('上报旧时间戳 → 不覆盖 host 已存新进度（取较新）', () async {
      await _seedHostBook(db, 'BookC');
      await _seedLocalPosition(db,
          bookKey: 'BookC',
          sectionIndex: 9,
          normCharOffset: 9000,
          charOffset: 90,
          updatedAt: 2000);
      final AppModelLibraryHostService svc = _svc(db);

      await svc.putBookProgress(
        'BookC',
        const RemoteBookProgress(
            sectionIndex: 1,
            normCharOffset: 10,
            charOffset: 1,
            updatedAtMs: 1000), // 更旧
      );

      final ReaderPositionRow? row = await db.getReaderPosition('BookC');
      expect(row!.sectionIndex, 9); // host 新进度保留
      expect(row.updatedAt, 2000);
    });

    test('上报新时间戳 → 覆盖 host 旧进度', () async {
      await _seedHostBook(db, 'BookD');
      await _seedLocalPosition(db,
          bookKey: 'BookD',
          sectionIndex: 1,
          normCharOffset: 100,
          charOffset: 1,
          updatedAt: 1000);
      final AppModelLibraryHostService svc = _svc(db);

      await svc.putBookProgress(
        'BookD',
        const RemoteBookProgress(
            sectionIndex: 6,
            normCharOffset: 6000,
            charOffset: 66,
            updatedAtMs: 5000), // 更新
      );

      final ReaderPositionRow? row = await db.getReaderPosition('BookD');
      expect(row!.sectionIndex, 6);
      expect(row.updatedAt, 5000);
    });

    test('负 normCharOffset clamp 到 0', () async {
      await _seedHostBook(db, 'BookE');
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putBookProgress(
        'BookE',
        const RemoteBookProgress(
            sectionIndex: 0,
            normCharOffset: -50,
            charOffset: -1,
            updatedAtMs: 1234),
      );
      final ReaderPositionRow? row = await db.getReaderPosition('BookE');
      expect(row!.normCharOffset, 0);
    });

    test('host 书库无该书 → PUT 进度被闸门挡掉（不写孤儿 reader_positions 行）', () async {
      // host 没有 BookOrphan（任意 client 上报任意 bookKey）：闸门 no-op，
      // 不产生孤儿行，避免 host 日后导入同 sanitize bookKey 的书时取到陈旧污染位置。
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putBookProgress(
        'BookOrphan',
        const RemoteBookProgress(
            sectionIndex: 7,
            normCharOffset: 7000,
            charOffset: 77,
            updatedAtMs: 1700000000000),
      );

      final ReaderPositionRow? row = await db.getReaderPosition('BookOrphan');
      expect(row, isNull); // 孤儿写被挡，DB 无该 bookKey 行。

      // GET 端点也对不存在的书返回 empty。
      final RemoteBookProgress got = await svc.getBookProgress('BookOrphan');
      expect(got.updatedAtMs, 0);
    });
  });
}
