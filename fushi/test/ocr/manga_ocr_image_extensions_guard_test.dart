/// BUG-1121 守卫：漫画「导入」与「整卷 OCR」两道关卡的页图扩展名口径必须一致。
///
/// 历史：两表各自手写整表，OCR 侧比导入侧少 `.bmp` / `.gif`——导入能收的
/// bmp 漫画整卷 OCR 时 bmp 页被静默跳过、产物 manga.json 缺页无任何提示。
/// 现两表统一取共享基集 `kImageExtensionsBase`（media_extensions.dart）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';

void main() {
  group('漫画页图扩展名两道关卡口径一致（BUG-1121）', () {
    test('整卷 OCR 白名单与导入白名单完全一致', () {
      expect(
        kMangaOcrImageExtensions,
        equals(kMangaImageExtensions),
        reason: '导入能收的页图 OCR 必须能扫；两表漂移会让该格式页在整卷 OCR '
            '被静默跳过、产物缺页无提示（BUG-1121：bmp）',
      );
    });

    test('两道关卡都以图片扩展名基集为源，.bmp / .gif 不再缺席', () {
      expect(kMangaImageExtensions, equals(kImageExtensionsBase));
      expect(kMangaOcrImageExtensions, containsAll(<String>{'.bmp', '.gif'}));
    });
  });
}
