// BUG-2496：四处绕过封面收口的直写（书 override 缩略图 / 字幕书封面 / PDF 首页封面
// / 在线漫画封面）改走封面收口（MediaCoverService.applyCover* 或其背后的引擎 writer），由收口
// 校验「完整可解码图片」后原子写 + 驱逐；封面坏了记诊断、coverPath 留空，不让导入 /
// 保存整体失败。
//
// 这四个文件的封面目的地都不在 media_cover_write_guard_test 的 kCoverDestMarker
// 派生标记里（thumbnails/ 的 hashCode 文件名、persistDir/cover.*、书目录 cover.png、
// 漫画目录 cover.*），那条守卫结构上扫不到它们——所以这里按文件逐条钉死：
//   ① 文件里必须经收口落盘（MediaCoverService.applyCover* 或引擎 writeCoverBytesAtomically /
//      copyCoverFileAtomically）；
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

/// 封面收口：`MediaCoverService.applyCover*` 只是引擎 `cover_file_writer` 的薄委派，
/// 校验可解码 + 原子写 + 驱逐（经 evictImageCacheForFile 钩子）都在引擎 writer 里，
/// 两种写法是同一个收口。底层文件直接调引擎 writer，免得为一行委派 import 读
/// AppModel 的 `media_cover_service`、把自己拖进 import 大环（import_cycle_guard_test）。
final RegExp kCoverSink = RegExp(
  r'MediaCoverService\.applyCover|writeCoverBytesAtomically\(|copyCoverFileAtomically\(',
);

/// 裸写调用（对文件的写 / 拷 / 同步拷）。
final RegExp kRawWrite = RegExp(r'writeAsBytes\(|\.copy\(|copySync\(');

/// 文件 → 允许保留的裸写行锚点（每条锚点恰好命中一行，且那一行搬的不是封面）。
const Map<String, List<String>>
kAllowedRawWriteAnchors = <String, List<String>>{
  'lib/src/media/media_source.dart': <String>[],
  'lib/src/media/audiobook/book_import_dialog.dart': <String>[],
  // PDF 本体拷进书目录（document.pdf），不是封面。
  'lib/src/pdf/pdf_importer.dart': <String>['kPdfFileName'],
  // 旧位置目录整体搬家的逐项 copy 已收进 lib/src/storage/directory_move.dart
  // 的 copyTreeMerging（通用目录搬移，不写封面），这里不再有裸写。
  'lib/src/media/manga/library/online_manga_library_service.dart': <String>[],
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

      test('封面落盘经收口（MediaCoverService.applyCover* 或引擎 writer）', () {
        expect(
          kCoverSink.hasMatch(masked),
          isTrue,
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
