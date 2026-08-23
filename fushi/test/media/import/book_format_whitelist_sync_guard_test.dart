import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// BUG-1789 结构守卫：「哪些文件算一本书」在仓库里被**手抄了四份**，四份必须同时认。
///
/// BUG-1789 的形状不是「PDF 导入器坏了」——`ImportCarrier.pdf` → `PdfImporter` 一直
/// 是对的。坏的是四份手抄白名单里有三份没跟上，于是同一份 PDF 在四个入口得到四种
/// 答案：按钮能导、拖进去说不支持、漫画框选不中、扫文件夹静默跳过。补齐那三份只
/// 消除了 `pdf` 这一个症状，**四份手抄的结构没变**：下一种单文件书格式照样会漏。
///
/// 这条守卫把「下次再漏」从静默 bug 变成红测试。新增一种单文件书格式时，下面四处
/// 必须一起改：
///
/// 1. `BookImportDialog._bookExtensions`（书籍导入框的文件选择器，private → 源码扫描）
/// 2. [kDragBookExtensions]（拖放分类，不带点）
/// 3. [kScanBookExtensions]（「导入文件夹」扫描，不带点）
/// 4. 该格式对应的 [ImportCarrier] 分支 + 导入器分流
///
/// 第 4 处不在本守卫的断言里（它有自己的 `import_carrier_test.dart`），但列在这里，
/// 因为漏了它前三处补齐也没用。
void main() {
  /// 单文件书格式（不带点、小写）：**一个文件**就能落成 `EpubBooks` 一行、由某个
  /// Importer 直接吃下的格式。
  ///
  /// 不含 `mokuro` / `cbz` / `zip`——那些是漫画载体，走漫画流程；也不含
  /// `TextToEpub.supportedExtensions`（txt/html/…），那些要先转成 EPUB，只有书籍
  /// 框和拖放认，扫描器有意不认（目录里的散装 txt 不该被当书批量导入）。
  const Set<String> singleFileBookExts = <String>{'epub', 'pdf'};

  group('单文件书格式的三份入口白名单必须同步', () {
    test('拖放白名单认全部单文件书格式', () {
      for (final String ext in singleFileBookExts) {
        expect(
          kDragBookExtensions,
          contains(ext),
          reason: '拖放白名单漏了 .$ext：按钮能导、拖进去却说「本页面不支持」，'
              '同一件东西两个入口两种答案（BUG-1789 的原始症状之一）。',
        );
      }
    });

    test('文件夹扫描白名单认全部单文件书格式', () {
      for (final String ext in singleFileBookExts) {
        expect(
          kScanBookExtensions,
          contains(ext),
          reason: '扫描白名单漏了 .$ext：「导入文件夹」会把目录里每一份 .$ext '
              '静默跳过——不报错、不计数，看起来像扫描漏了文件（BUG-1789）。',
        );
      }
    });

    test('书籍导入框的选择器白名单认全部单文件书格式', () {
      // private static，只能扫源码。路径变了这条会先红在 existsSync 上。
      final File dialog =
          File('lib/src/media/audiobook/book_import_dialog.dart');
      expect(
        dialog.existsSync(),
        isTrue,
        reason: '找不到 ${dialog.path}；文件挪位置了就必须同步更新这条守卫。',
      );
      final String source = dialog.readAsStringSync();
      final int start = source.indexOf('_bookExtensions');
      expect(
        start,
        isNonNegative,
        reason: '_bookExtensions 改名了；它是书籍框选择器的白名单，'
            '改名后必须同步更新这条守卫，否则守卫会变成一条永远不看的死断言。',
      );
      final int end = source.indexOf('];', start);
      expect(end, isNonNegative, reason: '_bookExtensions 的列表字面量没有结尾');
      final String block = source.substring(start, end);
      for (final String ext in singleFileBookExts) {
        expect(
          block,
          contains("'$ext'"),
          reason: '书籍框选择器白名单漏了 .$ext：用户在书架点「导入书籍」'
              '根本选不中这个文件。',
        );
      }
    });
  });

  group('漫画选择器白名单与 isMangaCapable 判据一致', () {
    test('白名单里每一项都真的能成为一本漫画', () {
      // 反向不变式：选择器让用户选得中，判据就必须收得下。BUG-1789 是它的正向
      // 失败（判据说能、选择器选不中）；反向失败同样是 bug——用户选中了文件，
      // 却被告知「不支持的格式」。
      //
      // `isImageArchive` 恒真是这条断言的**前提而非放水**：`.zip` / `.epub` 光看
      // 扩展名与词典包 / 普通电子书同形，真定性靠开包。本条问的是「内容确实是
      // 页图时，白名单里的这个扩展名能不能成为漫画」——开包发现不是页图而落回
      // 书籍流程，是正确行为，不该被这条守卫拦。
      for (final String ext in kMangaCarrierFileExtensions) {
        final String path = '/m/volume$ext';
        final ImportCarrier carrier = classifyImportCarrier(
          path,
          isDirectory: (String _) => false,
          isImageArchive: (String _) => true,
          directoryHasPageImages: (String _) => false,
          directoryCarrierFileCount: (String _) => 0,
        );
        expect(
          carrier.isMangaCapable,
          isTrue,
          reason: '$ext 在漫画选择器白名单里，但它的载体 $carrier '
              'isMangaCapable 为 false——用户选得中、导不进。',
        );
      }
    });

    test('pdf 两个判据分居两侧（书籍框不转交、漫画框收得下）', () {
      expect(
        ImportCarrier.pdf.isManga,
        isFalse,
        reason: 'pdf 并进 isManga 会让「从书架选一份 PDF」被误判成漫画并转走，'
            '那是把一个本来正确的行为改坏。',
      );
      expect(ImportCarrier.pdf.isMangaCapable, isTrue);
    });
  });
}
