import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/epub/book_file_location.dart';

/// 书架「打开文件位置」的路径决策。
///
/// 这里守的是两件容易悄悄坏掉的事：
/// * EPUB / PDF / 漫画三种书身份取磁盘路径**是同一件事**（同一张表、同样两列），
///   一旦有人给某一种加 `format` 分支，本文件的三条同构断言会同时变得可疑。
/// * `epubPath` 存量里有「书目录内文件名」和「绝对路径」两种形态。无条件 join 会
///   把后者拼成一条谁都打不开的字符串；这条退化路径没有 UI 报错，只会表现成
///   「点了打开文件位置，资源管理器开在别处」。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<EpubBookRow> _seedBook({
  required String bookKey,
  required String epubPath,
  required String extractDir,
  required String format,
}) async {
  final FushiDatabase db = await _openDb();
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: epubPath,
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1700000000000,
      format: Value<String>(format),
    ),
  );
  return (await db.getEpubBook(bookKey))!;
}

void main() {
  group('bookMainFilePath', () {
    test('漫画卷指向书目录里的 manga.json', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'Volume 01',
        epubPath: 'manga.json',
        extractDir: '/books/Volume 01',
        format: 'manga',
      );

      final String path = bookMainFilePath(row);

      expect(p.basename(path), 'manga.json',
          reason: '用户手改 mokuro 数据要的就是这个文件被选中');
      expect(p.equals(p.dirname(path), '/books/Volume 01'), isTrue);
    });

    test('EPUB 与 PDF 走同一条语句，不按 format 分叉', () async {
      final EpubBookRow epub = await _seedBook(
        bookKey: 'Novel',
        epubPath: 'novel.epub',
        extractDir: '/books/Novel',
        format: 'epub',
      );
      final EpubBookRow pdf = await _seedBook(
        bookKey: 'Paper',
        epubPath: 'book.pdf',
        extractDir: '/books/Paper',
        format: 'pdf',
      );

      expect(p.equals(bookMainFilePath(epub), '/books/Novel/novel.epub'),
          isTrue);
      expect(p.equals(bookMainFilePath(pdf), '/books/Paper/book.pdf'), isTrue);
    });

    // `/…` 开头在 windows 与 posix 两种 path context 下都算 rooted，故这条断言在
    // 本机 Windows 与 CI Linux 上是同一个判据。
    test('绝对 epubPath 原样返回，不被拼到书目录后面', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'External',
        epubPath: '/elsewhere/original.epub',
        extractDir: '/books/External',
        format: 'epub',
      );

      expect(p.equals(bookMainFilePath(row), '/elsewhere/original.epub'),
          isTrue);
    });
  });

  group('revealBookLocation', () {
    Future<EpubBookRow> mangaRow() => _seedBook(
          bookKey: 'Volume 02',
          epubPath: 'manga.json',
          extractDir: '/books/Volume 02',
          format: 'manga',
        );

    test('主文件在就只定位主文件，不退回目录', () async {
      final EpubBookRow row = await mangaRow();
      final List<String> targets = <String>[];

      final bool revealed = await revealBookLocation(
        row,
        reveal: (String path) async {
          targets.add(path);
          return true;
        },
      );

      expect(revealed, isTrue);
      expect(targets, hasLength(1));
      expect(p.basename(targets.single), 'manga.json');
    });

    test('主文件没了退回打开书目录', () async {
      final EpubBookRow row = await mangaRow();
      final List<String> targets = <String>[];

      final bool revealed = await revealBookLocation(
        row,
        reveal: (String path) async {
          targets.add(path);
          return p.basename(path) != 'manga.json';
        },
      );

      expect(revealed, isTrue);
      expect(targets, hasLength(2));
      expect(p.equals(targets.last, '/books/Volume 02'), isTrue);
    });

    test('两个目标都打不开时报失败，调用方必须提示', () async {
      final EpubBookRow row = await mangaRow();

      expect(
        await revealBookLocation(row, reveal: (String _) async => false),
        isFalse,
      );
    });

    test('主文件路径退化成书目录本身时不重复调用', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'Degenerate',
        epubPath: '',
        extractDir: '/books/Degenerate',
        format: 'epub',
      );
      int calls = 0;

      final bool revealed = await revealBookLocation(
        row,
        reveal: (String _) async {
          calls++;
          return false;
        },
      );

      expect(revealed, isFalse);
      expect(calls, 1);
    });
  });
}
