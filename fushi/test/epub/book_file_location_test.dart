import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/epub/book_file_location.dart';
import 'package:fushi/src/media/manga/book_format_rebuild.dart';

/// 书架「打开文件位置」的路径决策。
///
/// 这里守的是三件容易悄悄坏掉的事：
/// * EPUB 行的主产物是**解压书目录本身**，盘上没有 `.epub`（BUG-088）。谁把它
///   「统一」成 `p.join(extractDir, epubPath)`，拼出来的就是一条永远不存在的路径——
///   不崩，只是每一本 EPUB 都静默走退回分支，下一个拿这个路径去「分享/拷贝主文件」
///   的调用方会踩空。
/// * `bookMainFilePath` 与 `BookFormatRebuild.probeSource(...).sourcePath` 必须是
///   同一个答案：「这本书的源在哪」只允许一份真相源。
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

      expect(
        p.basename(path),
        'manga.json',
        reason: '用户手改 mokuro 数据要的就是这个文件被选中',
      );
      expect(p.equals(p.dirname(path), '/books/Volume 01'), isTrue);
    });

    test('PDF 指向书目录里的那个 PDF', () async {
      final EpubBookRow pdf = await _seedBook(
        bookKey: 'Paper',
        epubPath: 'book.pdf',
        extractDir: '/books/Paper',
        format: 'pdf',
      );

      expect(p.equals(bookMainFilePath(pdf), '/books/Paper/book.pdf'), isTrue);
    });

    test('EPUB 的主产物是解压书目录本身，不是 extractDir/epubPath', () async {
      final EpubBookRow epub = await _seedBook(
        bookKey: 'Novel',
        epubPath: 'novel.epub',
        extractDir: '/books/Novel',
        format: 'epub',
      );

      expect(
        p.equals(bookMainFilePath(epub), '/books/Novel'),
        isTrue,
        reason:
            '本仓 EPUB 导入即解压、盘上没有 .epub；'
            '拼 novel.epub 得到的是一条永远不存在的路径（BUG-088）',
      );
    });

    test('未知 format 按 EPUB 处理（与 BookFormat.parseOrEpub 同口径）', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'Legacy',
        epubPath: 'legacy.epub',
        extractDir: '/books/Legacy',
        format: 'something-new',
      );

      expect(p.equals(bookMainFilePath(row), '/books/Legacy'), isTrue);
    });

    // `/…` 开头在 windows 与 posix 两种 path context 下都算 rooted，故这条断言在
    // 本机 Windows 与 CI Linux 上是同一个判据。
    test('绝对 epubPath 原样返回，不被拼到书目录后面', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'External',
        epubPath: '/elsewhere/original.pdf',
        extractDir: '/books/External',
        format: 'pdf',
      );

      expect(
        p.equals(bookMainFilePath(row), '/elsewhere/original.pdf'),
        isTrue,
      );
    });
  });

  group('与 BookFormatRebuild.probeSource 同一份真相源', () {
    for (final (String format, String epubPath) in <(String, String)>[
      ('epub', 'novel.epub'),
      ('pdf', 'document.pdf'),
      ('manga', 'manga.json'),
    ]) {
      test('$format 行两处答案一致', () async {
        final EpubBookRow row = await _seedBook(
          bookKey: 'Probe $format',
          epubPath: epubPath,
          extractDir: '/books/Probe $format',
          format: format,
        );

        // 目录不存在，probe 只会报 sourceExists=false，不碰真实磁盘内容。
        expect(
          BookFormatRebuild.probeSource(row).sourcePath,
          bookMainFilePath(row),
          reason: '转化探测与「打开文件位置」对「源在哪」不许各答各的',
        );
      });
    }
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

    test('EPUB 行只有书目录一个目标，打不开也不重复调用', () async {
      final EpubBookRow row = await _seedBook(
        bookKey: 'Novel 2',
        epubPath: 'novel.epub',
        extractDir: '/books/Novel 2',
        format: 'epub',
      );
      final List<String> targets = <String>[];

      final bool revealed = await revealBookLocation(
        row,
        reveal: (String path) async {
          targets.add(path);
          return false;
        },
      );

      expect(revealed, isFalse);
      expect(targets, hasLength(1));
      expect(
        p.equals(targets.single, '/books/Novel 2'),
        isTrue,
        reason: 'EPUB 的主产物就是书目录，没有第二个目标可退',
      );
    });
  });
}
