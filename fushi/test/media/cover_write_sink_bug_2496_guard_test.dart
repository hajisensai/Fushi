// BUG-2496：四处绕过封面收口的直写（书 override 缩略图 / 字幕书封面 / PDF 首页封面
// / 在线漫画封面）改走 MediaCoverService.applyCoverFile / applyCoverBytes，由收口
// 校验「完整可解码图片」后原子写 + 驱逐；封面坏了记诊断、coverPath 留空，不让导入 /
// 保存整体失败。
//
// 这四个文件的封面目的地都不在 media_cover_write_guard_test 的 kCoverDestMarker
// 派生标记里（thumbnails/ 的 hashCode 文件名、persistDir/cover.*、书目录 cover.png、
// 漫画目录 cover.*），那条守卫结构上扫不到它们——所以这里按文件逐条钉死：
//   ① 文件里必须经 MediaCoverService.applyCover* 落盘；
//   ② 必须显式 catch CoverImageInvalidException（封面失败不得炸主流程）；
//   ③ 裸写调用是封闭集合：只剩「非封面资产」那几处，每处按同行锚点登记，
//      多一处（新的裸写封面）或少一处（登记过期）都红。
//
// 行为层的对应用例：书 override 在 media_cover_service_test.dart，在线漫画在
// online_manga_library_test.dart。字幕书对话框与 PDF 导入器分别要拉起整个导入
// 对话框 / pdfrx native，落不了行为测试，只有本守卫。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 裸写调用（对文件的写 / 拷 / 同步拷）。
final RegExp kRawWrite = RegExp(r'writeAsBytes\(|\.copy\(|copySync\(');

/// 文件 → 允许保留的裸写行锚点（每条锚点恰好命中一行，且那一行搬的不是封面）。
const Map<String, List<String>> kAllowedRawWriteAnchors =
    <String, List<String>>{
      'lib/src/media/media_source.dart': <String>[],
      'lib/src/media/audiobook/book_import_dialog.dart': <String>[],
      // PDF 本体拷进书目录（document.pdf），不是封面。
      'lib/src/pdf/pdf_importer.dart': <String>['kPdfFileName'],
      // 旧 <runtimeRoot>/library 目录整体搬家（跨卷回退到逐项 copy），不是封面写入。
      'lib/src/media/manga/library/online_manga_library_service.dart': <String>[
        'entity.copy(targetPath)',
      ],
    };

void main() {
  kAllowedRawWriteAnchors.forEach((String path, List<String> anchors) {
    group(path, () {
      late String masked;

      setUpAll(() {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: '守卫目标文件应存在：$path');
        masked = maskComments(file.readAsStringSync());
      });

      test('封面落盘经 MediaCoverService.applyCover*', () {
        expect(
          masked,
          contains('MediaCoverService.applyCover'),
          reason: '封面必须走收口（校验可解码 + 原子写 + 驱逐），不得裸写',
        );
      });

      test('显式 catch CoverImageInvalidException（封面坏了不炸主流程）', () {
        expect(
          masked,
          contains('on CoverImageInvalidException'),
          reason:
              '收口对非图片 / 截断图片抛 CoverImageInvalidException；'
              '不接住就是「一张坏封面让整本书导入失败」',
        );
      });

      test('裸写调用是封闭集合（只剩登记过的非封面资产）', () {
        final List<String> rawLines = masked
            .split('\n')
            .where((String line) => kRawWrite.hasMatch(line))
            .map((String line) => line.trim())
            .toList(growable: false);
        final List<String> unexpected = rawLines
            .where(
              (String line) =>
                  !anchors.any((String anchor) => line.contains(anchor)),
            )
            .toList(growable: false);
        expect(
          unexpected,
          isEmpty,
          reason:
              '出现了未登记的裸写——如果写的是封面，改走 '
              'MediaCoverService.applyCover*；如果是别的资产，把同行锚点登记进 '
              'kAllowedRawWriteAnchors：\n${unexpected.join('\n')}',
        );
        for (final String anchor in anchors) {
          expect(
            rawLines.where((String line) => line.contains(anchor)).length,
            1,
            reason:
                '登记锚点「$anchor」应恰好命中一行裸写；命中 0 行说明登记过期，'
                '命中多行说明锚点太宽',
          );
        }
      });
    });
  });
}
