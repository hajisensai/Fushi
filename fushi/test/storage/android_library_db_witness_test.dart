import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/android_library_db_witness.dart';
import 'package:fushi/src/storage/android_stray_library_merge.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 拍板台 review-library-anchor-both-roots（承接 BUG-5375 / #4356）：Android 两个书库根
/// 都有文件时，用主库存量路径作证选根，并把散在落选根里的书并回来。
void main() {
  const String internal = AppPaths.androidDocumentsLocationInternal;
  const String external = AppPaths.androidDocumentsLocationExternal;

  group('reconcileAndroidDocumentsLocation 两边都有书时听主库的', () {
    test('主库里的书多数只在另一个根 → 改到另一个根', () {
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: internal,
          anchoredHasLibrary: true,
          otherHasLibrary: true,
          dbWitness: const AndroidLibraryDbWitness(
            sampled: 12,
            onlyInAnchored: 2,
            onlyInOther: 10,
          ),
        ),
        external,
        reason: '锚点错指期间往错根导入了 2 本，真书库 10 本在外部：必须回到外部',
      );
    });

    test('平局（中断迁移的完整副本）/ 多数在锚定根 / 没有证据 → 沿用锚点', () {
      for (final AndroidLibraryDbWitness? w in <AndroidLibraryDbWitness?>[
        const AndroidLibraryDbWitness(
          sampled: 5,
          onlyInAnchored: 0,
          onlyInOther: 0,
        ),
        const AndroidLibraryDbWitness(
          sampled: 5,
          onlyInAnchored: 3,
          onlyInOther: 2,
        ),
        null,
      ]) {
        expect(
          AppPaths.reconcileAndroidDocumentsLocation(
            anchored: external,
            anchoredHasLibrary: true,
            otherHasLibrary: true,
            dbWitness: w,
          ),
          external,
          reason: '$w',
        );
      }
    });

    test('只有一边有书时不看主库（原判据不变）', () {
      const AndroidLibraryDbWitness w = AndroidLibraryDbWitness(
        sampled: 3,
        onlyInAnchored: 0,
        onlyInOther: 3,
      );
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: external,
          anchoredHasLibrary: true,
          otherHasLibrary: false,
          dbWitness: w,
        ),
        external,
      );
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: external,
          anchoredHasLibrary: false,
          otherHasLibrary: true,
        ),
        internal,
      );
    });
  });

  group('libraryRelativeTail', () {
    test('取最右边的自有顶层段之后的尾段', () {
      expect(
        AndroidLibraryDbWitness.libraryRelativeTail(
          '/data/user/0/app/app_flutter/Fushi/data/fushi_books/Bk',
        ),
        'fushi_books/Bk',
      );
      expect(
        AndroidLibraryDbWitness.libraryRelativeTail(
          r'C:\x\videos\data\audiobooks\Bk\a.mp3',
        ),
        'audiobooks/Bk/a.mp3',
      );
    });

    test('相对路径 / 非数据根路径 / 只有首段 / 不计证据的运行目录 → null', () {
      for (final String s in <String>[
        '',
        'fushi_books/Bk',
        '/storage/emulated/0/Movies/a.mp4',
        '/x/fushi_books',
        '/x/fushiExport/a.epub',
      ]) {
        expect(
          AndroidLibraryDbWitness.libraryRelativeTail(s),
          isNull,
          reason: s,
        );
      }
    });
  });

  test('*.fushi-part 半截文件不算书库证据', () {
    expect(AppPaths.isLibraryEvidenceFileName('a.mp3.fushi-part'), isFalse);
    expect(AppPaths.isLibraryEvidenceFileName('a.mp3'), isTrue);
  });

  group('磁盘 + 真主库', () {
    late Directory tmp;
    late Directory support;
    late Directory internalRoot;
    late Directory externalRoot;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_anchor_witness_');
      support = Directory(p.join(tmp.path, 'files'))..createSync();
      internalRoot = Directory(p.join(tmp.path, 'app_flutter', 'Fushi', 'data'))
        ..createSync(recursive: true);
      externalRoot = Directory(p.join(tmp.path, 'ext', 'files', 'data'))
        ..createSync(recursive: true);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File bookFile(Directory root, String key, [String name = 'a.html']) =>
        File(p.join(root.path, 'fushi_books', key, name));

    void writeBook(Directory root, String key, {String body = 'hello'}) {
      bookFile(root, key)
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    Future<void> seed(Map<String, Directory> books) async {
      final FushiDatabase db = FushiDatabase(support.path);
      try {
        for (final MapEntry<String, Directory> e in books.entries) {
          final String dir = p.join(e.value.path, 'fushi_books', e.key);
          await db.insertEpubBook(
            EpubBooksCompanion.insert(
              bookKey: e.key,
              title: e.key,
              epubPath: p.join(dir, 'o.epub'),
              extractDir: dir,
              chapterCount: 1,
              chaptersJson: '["c"]',
              importedAt: 0,
            ),
          );
        }
      } finally {
        await db.close();
      }
    }

    Future<Map<String, String>> extractDirs() async {
      final FushiDatabase db = FushiDatabase(support.path);
      try {
        return <String, String>{
          for (final EpubBookRow r in await db.getAllEpubBooks())
            r.bookKey: r.extractDir,
        };
      } finally {
        await db.close();
      }
    }

    test('锚点错指内部期间往内部导入了 1 本，外部是真书库 → 主库作证改回外部', () async {
      // 真书库在外部（3 本）；锚点被冲回内部后，用户又往内部导入了 1 本。
      for (final String k in <String>['A', 'B', 'C']) {
        writeBook(externalRoot, k);
      }
      writeBook(internalRoot, 'New');
      await seed(<String, Directory>{
        'A': externalRoot,
        'B': externalRoot,
        'C': externalRoot,
        'New': internalRoot,
      });

      final AndroidLibraryDbWitness? w = await AndroidLibraryDbWitness.probe(
        supportRoot: support,
        anchoredRoot: internalRoot,
        otherRoot: externalRoot,
      );
      expect(w, isNotNull, reason: '只读另开连接必须读得到刚写完的主库');
      expect(w!.sampled, 4);
      expect(w.onlyInAnchored, 1);
      expect(w.onlyInOther, 3);
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: internal,
          anchoredHasLibrary: await AppPaths.hasLibraryFiles(
            internalRoot,
            onTimeout: true,
          ),
          otherHasLibrary: await AppPaths.hasLibraryFiles(
            externalRoot,
            onTimeout: false,
          ),
          dbWitness: w,
        ),
        external,
        reason: '旧判据（两边都有 = 迁移中断，沿用锚点）在这里永远停在错的内部根',
      );
    });

    test('主库不存在 → 没有证据', () async {
      expect(
        await AndroidLibraryDbWitness.readStoredLibraryPaths(support),
        isNull,
      );
    });

    test('合并：散书搬回书库根、库内路径改写、落选根清空', () async {
      writeBook(externalRoot, 'A');
      writeBook(internalRoot, 'New', body: 'stray');
      // 中断复制留下的半截文件 + 一份逐字节相同的副本。
      writeBook(internalRoot, 'A');
      File(
        p.join(internalRoot.path, 'fushi_books', 'A', 'big.bin.fushi-part'),
      ).writeAsStringSync('half');
      await seed(<String, Directory>{'A': externalRoot, 'New': internalRoot});

      final FushiDatabase db = FushiDatabase(support.path);
      final AndroidStrayMergeOutcome outcome;
      try {
        outcome = await AndroidStrayLibraryMerge.run(
          db: db,
          libraryRoot: externalRoot,
          strayRoot: internalRoot,
          supportRoot: support.path,
        );
      } finally {
        await db.close();
      }
      expect(
        outcome.status,
        AndroidStrayMergeStatus.merged,
        reason: outcome.describe(),
      );
      expect(outcome.plan!.moves, hasLength(1));
      expect(outcome.plan!.duplicates, hasLength(1));
      expect(outcome.plan!.partials, hasLength(1));

      expect(bookFile(externalRoot, 'New').readAsStringSync(), 'stray');
      expect(bookFile(externalRoot, 'A').readAsStringSync(), 'hello');
      expect(
        await AppPaths.hasLibraryFiles(internalRoot, onTimeout: true),
        isFalse,
        reason: '并完之后落选根里不再有书，下次启动不再走两边都有的分支',
      );
      final Map<String, String> dirs = await extractDirs();
      expect(dirs['New'], p.join(externalRoot.path, 'fushi_books', 'New'));
      expect(dirs['A'], p.join(externalRoot.path, 'fushi_books', 'A'));
      expect(Directory(dirs['New']!).existsSync(), isTrue);
    });

    test('合并：同名文件内容不同 → 整次放弃，磁盘与主库一个字节都不动', () async {
      writeBook(externalRoot, 'A', body: 'library');
      writeBook(internalRoot, 'A', body: 'different');
      writeBook(internalRoot, 'New', body: 'stray');
      await seed(<String, Directory>{'A': externalRoot, 'New': internalRoot});

      final FushiDatabase db = FushiDatabase(support.path);
      final AndroidStrayMergeOutcome outcome;
      try {
        outcome = await AndroidStrayLibraryMerge.run(
          db: db,
          libraryRoot: externalRoot,
          strayRoot: internalRoot,
          supportRoot: support.path,
        );
      } finally {
        await db.close();
      }
      expect(outcome.status, AndroidStrayMergeStatus.conflicted);
      expect(outcome.plan!.conflicts, <String>[
        p.join('fushi_books', 'A', 'a.html'),
      ]);
      expect(bookFile(internalRoot, 'A').readAsStringSync(), 'different');
      expect(bookFile(internalRoot, 'New').readAsStringSync(), 'stray');
      expect(bookFile(externalRoot, 'New').existsSync(), isFalse);
      expect(
        (await extractDirs())['New'],
        p.join(internalRoot.path, 'fushi_books', 'New'),
      );
    });

    test('合并：长度相同、内容不同也算冲突（逐字节比），整次放弃', () async {
      writeBook(externalRoot, 'A', body: 'aaaa');
      writeBook(internalRoot, 'A', body: 'aaab');
      writeBook(internalRoot, 'New', body: 'stray');
      await seed(<String, Directory>{'A': externalRoot, 'New': internalRoot});

      final FushiDatabase db = FushiDatabase(support.path);
      final AndroidStrayMergeOutcome outcome;
      try {
        outcome = await AndroidStrayLibraryMerge.run(
          db: db,
          libraryRoot: externalRoot,
          strayRoot: internalRoot,
          supportRoot: support.path,
        );
      } finally {
        await db.close();
      }
      expect(outcome.status, AndroidStrayMergeStatus.conflicted);
      expect(bookFile(internalRoot, 'A').readAsStringSync(), 'aaab');
      expect(bookFile(externalRoot, 'New').existsSync(), isFalse);
      expect(
        (await extractDirs())['New'],
        p.join(internalRoot.path, 'fushi_books', 'New'),
      );
    });

    test('合并：复制到书库根失败（空间不够等）→ 撤掉暂存件，主库与落选根原样', () async {
      writeBook(externalRoot, 'A');
      writeBook(internalRoot, 'New1', body: 'one');
      writeBook(internalRoot, 'New2', body: 'two');
      await seed(<String, Directory>{
        'A': externalRoot,
        'New1': internalRoot,
        'New2': internalRoot,
      });
      // 让其中一本的暂存件写不进去：暂存件路径上已有同名目录，复制必然失败。
      Directory(
        p.join(externalRoot.path, 'fushi_books', 'New2', 'a.html.fushi-part'),
      ).createSync(recursive: true);

      final FushiDatabase db = FushiDatabase(support.path);
      final AndroidStrayMergeOutcome outcome;
      try {
        outcome = await AndroidStrayLibraryMerge.run(
          db: db,
          libraryRoot: externalRoot,
          strayRoot: internalRoot,
          supportRoot: support.path,
        );
      } finally {
        await db.close();
      }
      expect(outcome.status, AndroidStrayMergeStatus.failed);
      expect(
        bookFile(internalRoot, 'New1').readAsStringSync(),
        'one',
        reason: '源一个都不能删',
      );
      expect(bookFile(internalRoot, 'New2').readAsStringSync(), 'two');
      expect(bookFile(externalRoot, 'New1').existsSync(), isFalse);
      expect(
        File('${bookFile(externalRoot, 'New1').path}.fushi-part').existsSync(),
        isFalse,
        reason: '已写好的暂存件要撤掉',
      );
      final Map<String, String> dirs = await extractDirs();
      expect(
        dirs['New1'],
        p.join(internalRoot.path, 'fushi_books', 'New1'),
        reason: '主库不能先于文件改写：改了就指向书库根里不存在的书',
      );
      expect(dirs['New2'], p.join(internalRoot.path, 'fushi_books', 'New2'));
    });

    test('合并后再作证结论不变（尾段计票与路径前缀无关，不会来回翻）', () async {
      writeBook(externalRoot, 'A');
      writeBook(externalRoot, 'B');
      writeBook(internalRoot, 'New');
      await seed(<String, Directory>{
        'A': externalRoot,
        'B': externalRoot,
        'New': internalRoot,
      });
      final AndroidLibraryDbWitness? before =
          await AndroidLibraryDbWitness.probe(
            supportRoot: support,
            anchoredRoot: externalRoot,
            otherRoot: internalRoot,
          );
      expect(before!.favorsOther, isFalse);

      // 模拟合并做到一半崩溃：库内路径已改写，文件还没搬。
      final FushiDatabase db = FushiDatabase(support.path);
      try {
        await db.updateEpubBookContentPaths(
          'New',
          epubPath: p.join(externalRoot.path, 'fushi_books', 'New', 'o.epub'),
          extractDir: p.join(externalRoot.path, 'fushi_books', 'New'),
        );
      } finally {
        await db.close();
      }
      final AndroidLibraryDbWitness? after =
          await AndroidLibraryDbWitness.probe(
            supportRoot: support,
            anchoredRoot: externalRoot,
            otherRoot: internalRoot,
          );
      expect(after!.onlyInAnchored, before.onlyInAnchored);
      expect(after.onlyInOther, before.onlyInOther);
    });
  });
}
