/// 载体分类（漫画/书籍导入分家的判据核心）。
///
/// [classifyImportCarrier] 是从 `BookImportDialog._importEpubOnly` 函数体里提出来的
/// ——那里原本有 4 个按顺序早退的 if（目录 / .pdf / .mokuro / .cbz|图片型压缩包），
/// 埋在导入执行阶段、必须真跑一次导入才能验证。提成纯函数后可以在这里穷举，包括
/// 那几条**顺序敏感**的分支：分支顺序一旦被人「整理」乱，PDF 会被当文本转成乱码
/// EPUB、.mokuro 的 JSON 会被当纯文本吞掉、带点的目录名会取出假扩展名。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/import/import_carrier.dart';

/// 默认判据：什么都不是目录、什么都不是图片压缩包。
ImportCarrier classify(
  String path, {
  Set<String> directories = const <String>{},
  Set<String> imageArchives = const <String>{},
}) =>
    classifyImportCarrier(
      path,
      isDirectory: directories.contains,
      isImageArchive: imageArchives.contains,
    );

void main() {
  group('漫画载体', () {
    test('目录 → mangaFolder', () {
      expect(
        classify('/m/vol1', directories: <String>{'/m/vol1'}),
        ImportCarrier.mangaFolder,
      );
    });

    test('目录判定必须先于扩展名判定：带点的目录名不会被当成文件', () {
      // `p.extension('/m/Vol.1')` == '.1'，落到任何扩展名分支都会误判。
      expect(
        classify('/m/Vol.1', directories: <String>{'/m/Vol.1'}),
        ImportCarrier.mangaFolder,
      );
      // 更狠的一例：目录名以真实文件扩展名结尾。
      expect(
        classify('/m/scan.zip', directories: <String>{'/m/scan.zip'}),
        ImportCarrier.mangaFolder,
      );
    });

    test('.mokuro → mangaMokuro（不得被文本分支吞掉）', () {
      expect(classify('/m/vol1.mokuro'), ImportCarrier.mangaMokuro);
    });

    test('.cbz → mangaArchive，无需读包', () {
      expect(classify('/m/vol1.cbz'), ImportCarrier.mangaArchive);
    });

    test('图片型 .zip → mangaArchive', () {
      expect(
        classify('/m/vol1.zip', imageArchives: <String>{'/m/vol1.zip'}),
        ImportCarrier.mangaArchive,
      );
    });

    test('图片型 .epub（扫描版漫画）→ mangaArchive', () {
      expect(
        classify('/m/scan.epub', imageArchives: <String>{'/m/scan.epub'}),
        ImportCarrier.mangaArchive,
      );
    });

    test('isManga 覆盖且仅覆盖三种漫画载体', () {
      expect(ImportCarrier.mangaFolder.isManga, isTrue);
      expect(ImportCarrier.mangaMokuro.isManga, isTrue);
      expect(ImportCarrier.mangaArchive.isManga, isTrue);
      expect(ImportCarrier.pdf.isManga, isFalse);
      expect(ImportCarrier.epub.isManga, isFalse);
      expect(ImportCarrier.text.isManga, isFalse);
    });
  });

  group('书籍载体', () {
    test('.pdf → pdf（必须先于文本分支，否则二进制被转成乱码 EPUB）', () {
      expect(classify('/b/doc.pdf'), ImportCarrier.pdf);
    });

    test('普通 .epub → epub', () {
      expect(classify('/b/novel.epub'), ImportCarrier.epub);
    });

    test('非图片型 .zip → epub 分支（维持既有兜底语义）', () {
      expect(classify('/b/dict.zip'), ImportCarrier.epub);
    });

    test('.txt / .md / .html → text', () {
      expect(classify('/b/a.txt'), ImportCarrier.text);
      expect(classify('/b/a.md'), ImportCarrier.text);
      expect(classify('/b/a.html'), ImportCarrier.text);
    });

    test('无扩展名文件 → text（非 epub/zip 一律尝试文本转换）', () {
      expect(classify('/b/README'), ImportCarrier.text);
    });

    test('不认识的扩展名 → text', () {
      expect(classify('/b/a.weirdext'), ImportCarrier.text);
    });
  });

  group('读包判据只在真正二义时才被调用', () {
    test('.cbz / .mokuro / .pdf / .txt 都不触发读包', () {
      final List<String> probed = <String>[];
      for (final String path in <String>[
        '/x/a.cbz',
        '/x/a.mokuro',
        '/x/a.pdf',
        '/x/a.txt',
      ]) {
        classifyImportCarrier(
          path,
          isDirectory: (_) => false,
          isImageArchive: (String pth) {
            probed.add(pth);
            return false;
          },
        );
      }
      expect(probed, isEmpty, reason: '扩展名已能定性时不得白开一次包');
    });

    test('目录不触发读包', () {
      final List<String> probed = <String>[];
      classifyImportCarrier(
        '/x/vol.zip',
        isDirectory: (_) => true,
        isImageArchive: (String pth) {
          probed.add(pth);
          return false;
        },
      );
      expect(probed, isEmpty, reason: '目录在读包判据之前就已早退');
    });

    test('.zip / .epub 才触发读包', () {
      final List<String> probed = <String>[];
      for (final String path in <String>['/x/a.zip', '/x/a.epub']) {
        classifyImportCarrier(
          path,
          isDirectory: (_) => false,
          isImageArchive: (String pth) {
            probed.add(pth);
            return false;
          },
        );
      }
      expect(probed, <String>['/x/a.zip', '/x/a.epub']);
    });
  });

  group('大小写与路径分隔符', () {
    test('扩展名大小写不敏感', () {
      expect(classify('/m/VOL1.CBZ'), ImportCarrier.mangaArchive);
      expect(classify('/m/VOL1.MOKURO'), ImportCarrier.mangaMokuro);
      expect(classify('/b/DOC.PDF'), ImportCarrier.pdf);
    });

    test('Windows 反斜杠路径同样定性', () {
      expect(classify(r'C:\manga\vol1.cbz'), ImportCarrier.mangaArchive);
      expect(classify(r'C:\books\novel.epub'), ImportCarrier.epub);
    });
  });
}
