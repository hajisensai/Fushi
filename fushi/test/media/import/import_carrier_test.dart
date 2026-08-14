/// 载体分类（漫画/书籍导入分家的判据核心）。
///
/// [classifyImportCarrier] 是从 `BookImportDialog._importEpubOnly` 函数体里提出来的
/// ——那里原本有 4 个按顺序早退的 if（目录 / .pdf / .mokuro / .cbz|图片型压缩包），
/// 埋在导入执行阶段、必须真跑一次导入才能验证。提成纯函数后可以在这里穷举，包括
/// 那几条**顺序敏感**的分支：分支顺序一旦被人「整理」乱，PDF 会被当文本转成乱码
/// EPUB、.mokuro 的 JSON 会被当纯文本吞掉、带点的目录名会取出假扩展名。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/import_carrier.dart';

/// 默认判据：什么都不是目录、什么都不是图片压缩包、没有目录含页图或整卷文件。
ImportCarrier classify(
  String path, {
  Set<String> directories = const <String>{},
  Set<String> imageArchives = const <String>{},
  Set<String> pageImageDirs = const <String>{},
  Map<String, int> carrierFileDirs = const <String, int>{},
}) =>
    classifyImportCarrier(
      path,
      isDirectory: directories.contains,
      isImageArchive: imageArchives.contains,
      directoryHasPageImages: pageImageDirs.contains,
      directoryCarrierFileCount: (String p) => carrierFileDirs[p] ?? 0,
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

    test('isManga 覆盖且仅覆盖四种漫画载体', () {
      expect(ImportCarrier.mangaFolder.isManga, isTrue);
      expect(ImportCarrier.mangaBatchFolder.isManga, isTrue);
      expect(ImportCarrier.mangaMokuro.isManga, isTrue);
      expect(ImportCarrier.mangaArchive.isManga, isTrue);
      expect(ImportCarrier.pdf.isManga, isFalse);
      expect(ImportCarrier.epub.isManga, isFalse);
      expect(ImportCarrier.text.isManga, isFalse);
    });
  });

  /// BUG-1649：用户在漫画框选了一个**装着 20 卷 EPUB 的文件夹**，被当成页图目录，
  /// 扫不到任何图片扩展名的文件，报 `Manga image folder has no pages`。目录里装
  /// 什么是数据的形状，不是错误情况——缺的是一个载体身份。
  group('目录的两种形状（BUG-1649）', () {
    test('有页图 → mangaFolder（与改动前逐字节一致）', () {
      expect(
        classify(
          '/m/vol1',
          directories: <String>{'/m/vol1'},
          pageImageDirs: <String>{'/m/vol1'},
        ),
        ImportCarrier.mangaFolder,
      );
    });

    test('无页图但装着整卷文件 → mangaBatchFolder', () {
      expect(
        classify(
          '/m/series',
          directories: <String>{'/m/series'},
          carrierFileDirs: <String, int>{'/m/series': 20},
        ),
        ImportCarrier.mangaBatchFolder,
      );
    });

    test('页图与整卷文件同时在场 → mangaFolder（页图这条解释优先）', () {
      expect(
        classify(
          '/m/mixed',
          directories: <String>{'/m/mixed'},
          pageImageDirs: <String>{'/m/mixed'},
          carrierFileDirs: <String, int>{'/m/mixed': 3},
        ),
        ImportCarrier.mangaFolder,
      );
    });

    test('空目录 → mangaFolder（让导入器抛那句「没有页」，这里没有更准确的话）', () {
      expect(
        classify('/m/empty', directories: <String>{'/m/empty'}),
        ImportCarrier.mangaFolder,
      );
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
          directoryHasPageImages: (_) => false,
          directoryCarrierFileCount: (_) => 0,
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
        directoryHasPageImages: (_) => false,
        directoryCarrierFileCount: (_) => 0,
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
          directoryHasPageImages: (_) => false,
          directoryCarrierFileCount: (_) => 0,
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

  group('ImportCarrierResolver 按路径记忆（不重复开包）', () {
    /// 造一个会数「开了几次包」的 resolver。`isImageArchive` 就是真实现里那次
    /// 全量同步解压的位置，数它 = 数解压次数。
    ({ImportCarrierResolver resolver, List<String> probes}) makeResolver({
      Set<String> imageArchives = const <String>{},
    }) {
      final List<String> probes = <String>[];
      return (
        resolver: ImportCarrierResolver(
          isDirectory: (String _) => false,
          isImageArchive: (String path) {
            probes.add(path);
            return imageArchives.contains(path);
          },
          directoryHasPageImages: (String _) => false,
          directoryCarrierFileCount: (String _) => 0,
        ),
        probes: probes,
      );
    }

    test('同一个 .epub 问三次只开一次包（书籍导入的真实提问序列）', () {
      // 这三次提问对应 BookImportDialog 里真实存在的三处：选中时的漫画闸门、
      // _doImport 的兜底闸门、_importEpubOnly 的分派。修复前每次都整包解压。
      final r = makeResolver();
      for (int i = 0; i < 3; i++) {
        expect(r.resolver.resolve('/b/novel.epub'), ImportCarrier.epub);
      }
      expect(r.probes.length, 1, reason: '载体身份是路径的函数，问三次不该解压三次');
    });

    test('有声书对齐路径：两次闸门也只开一次包', () {
      // EPUB+字幕 走 _importEpubWithAlignment，根本不进 _importEpubOnly，
      // 所以它只被问两次——但分家前它一次都不开包，重复开包在这条路上纯属白开。
      final r = makeResolver();
      r.resolver.resolve('/b/novel.epub');
      r.resolver.resolve('/b/novel.epub');
      expect(r.probes.length, 1);
    });

    test('换路径必须重新定性（不得把上一个文件的判定张冠李戴）', () {
      final r = makeResolver(imageArchives: <String>{'/m/scan.zip'});
      expect(r.resolver.resolve('/b/novel.epub'), ImportCarrier.epub);
      expect(r.resolver.resolve('/m/scan.zip'), ImportCarrier.mangaArchive);
      expect(r.resolver.resolve('/b/novel.epub'), ImportCarrier.epub);
      expect(
          r.probes, <String>['/b/novel.epub', '/m/scan.zip', '/b/novel.epub'],
          reason: '换路径就得重算，记忆只对「同一个路径连续问」生效');
    });

    test('invalidate() 后重新开包（文件可能在对话框开着时被换掉）', () {
      final r = makeResolver();
      r.resolver.resolve('/b/novel.epub');
      r.resolver.invalidate();
      r.resolver.resolve('/b/novel.epub');
      expect(r.probes.length, 2);
    });

    test('记忆不改变判定结果本身（词典包一票否决照常）', () {
      // /d/dict.zip 不在 imageArchives 里 = 判据说它不是图片包（真实现里正是
      // 词典包一票否决给出的答案）。记忆层不得把它变成漫画。
      final r = makeResolver(imageArchives: <String>{'/m/scan.zip'});
      for (int i = 0; i < 3; i++) {
        expect(r.resolver.resolve('/d/dict.zip'), ImportCarrier.epub,
            reason: '缓存只省重复提问，绝不改答案');
      }
      expect(r.probes.length, 1);
    });
  });
}
