import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/sandbox_relocation.dart';

/// iOS「每次更新文件都失效」的回归。
///
/// 根因：库里存绝对路径，而 iOS 的 app 容器 UUID **每次安装/更新都会变**。文件
/// 随容器被系统搬走，库里那串旧 UUID 路径集体悬空 —— 症状是整个书架全部
/// 「找不到书籍文件」，且每次更新复发一次。
///
/// 本测试盯三件事：
///  1. **不猜**：只有「改写后的目标在磁盘上真的存在」的映射才被采纳；
///  2. **能自愈已经坏掉的安装**：台账为空（本功能上线前就被挪走的那一批）时，
///     能从存量数据反推出旧根；
///  3. **今后不再复发**：每次启动都写台账，下一次漂移走精确路径、不需要反推。
void main() {
  group('纯函数内核：只采纳被磁盘证实的映射', () {
    const String oldRoot =
        '/var/mobile/Containers/Data/Application/AAAA-1111/Documents';
    const String newRoot =
        '/var/mobile/Containers/Data/Application/BBBB-2222/Documents';
    const String stored = '$oldRoot/fushi_books/言の葉の庭';

    String? derive({
      String storedPath = stored,
      String currentDocumentsRoot = newRoot,
      required Set<String> onDisk,
    }) =>
        SandboxRelocation.deriveOldRootFromPath(
          storedPath: storedPath,
          currentDocumentsRoot: currentDocumentsRoot,
          exists: onDisk.contains,
        );

    test('容器 UUID 变了：旧路径没了、新路径在 → 反推出旧根', () {
      expect(
        derive(onDisk: <String>{'$newRoot/fushi_books/言の葉の庭'}),
        oldRoot,
      );
    });

    test('旧路径还在 → 根没坏，不重基', () {
      expect(
        derive(onDisk: <String>{
          stored,
          '$newRoot/fushi_books/言の葉の庭',
        }),
        isNull,
        reason: '老路径仍可达就说明根没被挪走，此时改写只会把好数据改坏',
      );
    });

    test('改写后的目标不存在 → 拒绝，不猜', () {
      expect(
        derive(onDisk: const <String>{}),
        isNull,
        reason: '没有磁盘证据的映射一律不采纳——这是本模块与启发式的分界线',
      );
    });

    test('外部路径（不含白名单顶层段）不碰', () {
      expect(
        derive(
          storedPath: '/Users/me/NAS/anime/EP01.mkv',
          onDisk: <String>{'$newRoot/anime/EP01.mkv'},
        ),
        isNull,
        reason: '用户自选的外部媒体库不是数据根内路径，永远不该被重基',
      );
    });

    test('相对路径不碰', () {
      expect(
        derive(storedPath: 'manga.json', onDisk: const <String>{}),
        isNull,
      );
      expect(
        derive(storedPath: 'images/p001.jpg', onDisk: const <String>{}),
        isNull,
      );
    });

    test('路径里出现两个白名单段时取靠右那个', () {
      // 旧根自己就叫 `.../videos`：靠左那个 `videos` 是根的一部分，不是数据根首段。
      const String trickyOld = '/container/AAAA/videos/Documents';
      const String trickyNew = '/container/BBBB/videos/Documents';
      expect(
        SandboxRelocation.deriveOldRootFromPath(
          storedPath: '$trickyOld/video_covers/a.jpg',
          currentDocumentsRoot: trickyNew,
          exists: <String>{'$trickyNew/video_covers/a.jpg'}.contains,
        ),
        trickyOld,
        reason: '取靠右的白名单段，否则旧根会被截断成 /container/AAAA',
      );
    });

    test('旧根与当前根相同 → 无事发生', () {
      expect(
        derive(
          storedPath: '$newRoot/fushi_books/x',
          onDisk: <String>{'$newRoot/fushi_books/x'},
        ),
        isNull,
      );
    });
  });

  group('端到端：真实磁盘 + 真实库', () {
    late Directory sandbox;
    late Directory oldRoot;
    late Directory newRoot;
    late FushiDatabase db;

    /// 造一个「容器被挪走」的现场：书的文件只在**新**根下存在，库里记的却是
    /// **旧**根 —— 这正是 iOS 更新后用户看到的状态。
    Future<String> seedMovedBook() async {
      final Directory moved =
          Directory(p.join(newRoot.path, 'fushi_books', 'book1'));
      moved.createSync(recursive: true);
      File(p.join(moved.path, 'manga.json')).writeAsStringSync('{}');
      final String staleDir = p.join(oldRoot.path, 'fushi_books', 'book1');
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'book1',
        title: '言の葉の庭',
        epubPath: 'manga.json',
        extractDir: staleDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      return staleDir;
    }

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('sandbox_reloc_');
      oldRoot = Directory(p.join(sandbox.path, 'AAAA-1111', 'Documents'));
      newRoot = Directory(p.join(sandbox.path, 'BBBB-2222', 'Documents'))
        ..createSync(recursive: true);
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('台账为空 + 存量已被挪走 → 反推并重基（补救已经坏掉的安装）', () async {
      final String staleDir = await seedMovedBook();

      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );

      expect(outcome.rebased, isTrue);
      expect(outcome.source, SandboxRelocationSource.derivedFromData);

      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(row.extractDir, isNot(staleDir));
      expect(
        Directory(row.extractDir).existsSync(),
        isTrue,
        reason: '重基后的目录必须真的存在——否则等于把一种坏换成另一种坏',
      );
      expect(
        File(p.join(row.extractDir, 'manga.json')).existsSync(),
        isTrue,
        reason: '书的正文文件要能沿新路径打开，这才是用户口中的「书回来了」',
      );
    });

    test('重基后写下台账：下一次漂移走精确路径，不再依赖反推', () async {
      await seedMovedBook();
      await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );
      expect(
        await db.getPref(SandboxRelocation.lastDocumentsRootPrefKey),
        newRoot.path,
      );

      // 再挪一次容器（把文件搬到第三个根），这次台账里有精确旧根。
      final Directory thirdRoot =
          Directory(p.join(sandbox.path, 'CCCC-3333', 'Documents'))
            ..createSync(recursive: true);
      Directory(p.join(thirdRoot.path, 'fushi_books', 'book1'))
          .createSync(recursive: true);
      File(p.join(thirdRoot.path, 'fushi_books', 'book1', 'manga.json'))
          .writeAsStringSync('{}');

      final SandboxRelocationOutcome second = await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: thirdRoot.path,
        supportRoot: p.join(sandbox.path, 'CCCC-3333', 'Support'),
      );

      expect(second.rebased, isTrue);
      expect(second.source, SandboxRelocationSource.ledger);
      expect(second.oldDocumentsRoot, newRoot.path);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(p.isWithin(thirdRoot.path, row.extractDir), isTrue);
    });

    test('根没变 → 一个字节都不改，只记台账', () async {
      final Directory live =
          Directory(p.join(newRoot.path, 'fushi_books', 'book1'))
            ..createSync(recursive: true);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'book1',
        title: 'stable',
        epubPath: 'manga.json',
        extractDir: live.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final SandboxRelocationOutcome first = await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );
      expect(first.rebased, isFalse);

      // 第二次启动，根仍然没变。
      final SandboxRelocationOutcome second = await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );
      expect(second.rebased, isFalse);
      expect((await db.getAllEpubBooks()).single.extractDir, live.path);
    });

    test('全新安装（库是空的）→ 无事发生，不炸', () async {
      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );
      expect(outcome.rebased, isFalse);
      expect(outcome.error, isNull);
      expect(
        await db.getPref(SandboxRelocation.lastDocumentsRootPrefKey),
        newRoot.path,
      );
    });

    test('外部路径在重基中原样不动', () async {
      await seedMovedBook();
      final Directory external =
          Directory(p.join(sandbox.path, 'external', 'nas'))
            ..createSync(recursive: true);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'external1',
        title: 'external',
        epubPath: 'x.epub',
        extractDir: external.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );

      final EpubBookRow kept = (await db.getAllEpubBooks())
          .firstWhere((EpubBookRow r) => r.bookKey == 'external1');
      expect(
        kept.extractDir,
        external.path,
        reason: '数据根之外的路径不在重基作用域内，改它就是数据损坏',
      );
    });

    test('旧根**之下**的非 Hibiki 路径同样原样不动', () async {
      // 上一条用例的外部路径落在 `<sandbox>/external/nas`，压根不在 oldRoot 之下
      // —— `isInScope` 第一句就返回 false，scopeTopLevelNames 传什么都能通过。
      // 真正要守的形状是**位于旧根之内、但不属于 Hibiki 顶层项**的路径：用户把
      // 外部媒体库放在数据根旁边，它就长这样。
      await seedMovedBook();
      final Directory foreign =
          Directory(p.join(oldRoot.path, 'MyNasLibrary', 'anime'))
            ..createSync(recursive: true);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'foreign1',
        title: 'foreign',
        epubPath: 'x.epub',
        extractDir: foreign.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: newRoot.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );
      expect(outcome.rebased, isTrue, reason: '本轮确实发生了重基，断言才有意义');

      final EpubBookRow kept = (await db.getAllEpubBooks())
          .firstWhere((EpubBookRow r) => r.bookKey == 'foreign1');
      expect(
        kept.extractDir,
        foreign.path,
        reason: 'MyNasLibrary 不是 Hibiki 的顶层项，重基不该碰它 —— '
            'scopeTopLevelNames 传 null 时这里会被一起改写',
      );
    });

    test('新根套在旧台账根里面 → 不重基（已被 DataRootMigrator 改写过）', () async {
      // DataRootMigrator 把数据收进 `<旧根>/Hibiki/data`：全库路径它已经改写好，
      // 但台账不在 kPathRebasePrefs 里、仍停在旧根。此时若照台账再重基一次，
      // 就会把已经正确的 `<新根>/fushi_books/book1` 再前缀一遍。
      final Directory nested = Directory(p.join(oldRoot.path, 'Hibiki', 'data'))
        ..createSync(recursive: true);
      final Directory live =
          Directory(p.join(nested.path, 'fushi_books', 'book1'))
            ..createSync(recursive: true);
      await db.setPref(
          SandboxRelocation.lastDocumentsRootPrefKey, oldRoot.path);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'nested1',
        title: 'nested',
        epubPath: 'x.epub',
        extractDir: live.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
        db: db,
        documentsRoot: nested.path,
        supportRoot: p.join(sandbox.path, 'BBBB-2222', 'Support'),
      );

      expect(outcome.rebased, isFalse, reason: '嵌套根不是容器漂移，不该重基');
      expect(
        (await db.getAllEpubBooks()).single.extractDir,
        live.path,
        reason: '再重基一次就会变成 <新根>/Hibiki/data/fushi_books/book1（BUG-1174 ③）',
      );
      expect(
        await db.getPref(SandboxRelocation.lastDocumentsRootPrefKey),
        nested.path,
        reason: '台账要跟上新根，否则下次启动还会再判一次嵌套',
      );
    });
  });
}
