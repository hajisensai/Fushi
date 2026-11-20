// BUG-4907：PDF 导入的书目录归属（沿用 BUG-4840 的漫画 / EPUB 做法）。
//
// `document.pdf` 与封面先备进书库根下本次独占的 `.tmp-*`，落位锁内才挪进
// `<bookKey>/` 并插行；失败回滚只删本次自己建的目录。此前是
// `EpubStorage.bookDirectory`（存在即复用）直接往 `<bookKey>/` 里写、失败无条件
// 整个删掉。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  // 封面原子写会驱逐图片缓存（PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDocDir;
  late Directory srcRoot;
  late String booksRoot;
  late FushiDatabase db;

  setUp(() {
    appDocDir = Directory.systemTemp.createTempSync('pdf_dir_owner_app_');
    srcRoot = Directory.systemTemp.createTempSync('pdf_dir_owner_src_');
    EpubStorage.debugBaseDirectoryOverride = appDocDir.path;
    booksRoot = p.join(appDocDir.path, 'fushi_books');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[appDocDir, srcRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  String fakePdf(String name, String body) {
    final File file = File(p.join(srcRoot.path, name))
      ..writeAsStringSync('%PDF-1.4\n$body\n');
    return file.path;
  }

  final Uint8List cover = Uint8List.fromList(
    img.encodePng(img.Image(width: 12, height: 16)),
  );

  List<String> stagingNames() => Directory(booksRoot).existsSync()
      ? <String>[
          for (final FileSystemEntity e in Directory(booksRoot).listSync())
            if (p.basename(e.path).startsWith(EpubStorage.kStagingDirPrefix))
              p.basename(e.path),
        ]
      : <String>[];

  test('并发导入同名 PDF：两本都入库，各占各的目录、文件不串', () async {
    final String a = fakePdf('a.pdf', 'AAA');
    final String b = fakePdf('b.pdf', 'BBB');

    final List<String> keys = await Future.wait(<Future<String>>[
      PdfImporter.persistRendered(
        db: db,
        filePath: a,
        title: '同名 PDF',
        policy: const DuplicatePolicy.suffix(),
        pageCount: 3,
        coverPng: cover,
      ),
      PdfImporter.persistRendered(
        db: db,
        filePath: b,
        title: '同名 PDF',
        policy: const DuplicatePolicy.suffix(),
        pageCount: 5,
        coverPng: cover,
      ),
    ]);

    expect(keys.toSet(), hasLength(2));
    final Set<String> bodies = <String>{};
    for (final String key in keys) {
      final EpubBookRow row = (await db.getEpubBook(key))!;
      final File pdf = File(p.join(row.extractDir, PdfImporter.kPdfFileName));
      expect(pdf.existsSync(), isTrue, reason: key);
      bodies.add(pdf.readAsStringSync());
      expect(row.coverPath, PdfImporter.kCoverFileName);
      expect(
        File(p.join(row.extractDir, PdfImporter.kCoverFileName)).existsSync(),
        isTrue,
      );
    }
    expect(bodies, hasLength(2), reason: '两本各是各的 document.pdf');
    expect(stagingNames(), isEmpty);
  });

  test('导入失败不删同名的无主目录（可能是「找回书库」能恢复的孤儿）', () async {
    final Directory orphan = Directory(p.join(booksRoot, '孤儿书'))
      ..createSync(recursive: true);
    File(p.join(orphan.path, 'keep.txt')).writeAsStringSync('orphan');

    await expectLater(
      PdfImporter.persistRendered(
        db: db,
        filePath: p.join(srcRoot.path, 'missing.pdf'),
        title: '孤儿书',
        policy: const DuplicatePolicy.suffix(),
        pageCount: 1,
        coverPng: cover,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(p.join(orphan.path, 'keep.txt')).readAsStringSync(), 'orphan');
    expect(stagingNames(), isEmpty, reason: '暂存目录随失败一起回收');
    expect(await db.getEpubBookMetas(), isEmpty);
  });

  test('跳过策略先判重：已在库的标题不打开 PDF 就中止', () async {
    await PdfImporter.persistRendered(
      db: db,
      filePath: fakePdf('first.pdf', 'X'),
      title: '已在库',
      policy: const DuplicatePolicy.suffix(),
      pageCount: 1,
      coverPng: null,
    );
    // 路径不存在、pdfium 也没初始化：走到开文档那一步就会抛别的异常。
    await expectLater(
      PdfImporter.importFromPath(
        db: db,
        filePath: p.join(srcRoot.path, 'not-there.pdf'),
        fileName: 'not-there.pdf',
        title: '已在库',
        policy: const DuplicatePolicy.skip(),
      ),
      throwsA(
        isA<DuplicateImportCancelledException>().having(
          (DuplicateImportCancelledException e) => e.title,
          'title',
          '已在库',
        ),
      ),
    );
  });
}
