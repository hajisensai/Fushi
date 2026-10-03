import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';

/// 漫画 OCR 提速组件（KV cache decoder）的清单守卫。
///
/// 同一份发布资产在两处登记：运行时下载清单 [kMangaOcrKvAcceleratorManifest]
/// 与工具目录的 `tool/manga_ocr_kv/model_manifest.json`（导出、校验、发 release
/// 都按它走）。两边字节数或 sha256 一旦不一致，结果是静默的：要么下载后校验
/// 失败、用户永远装不上，要么校验的不是导出时验过的那份权重。
///
/// 上游 manga-ocr 用到了 **Manga109-s**，其条款要求使用该数据集的衍生模型明确
/// 标注——我们从同一份权重导出并分发 ONNX，署名须随清单与仓库 README 一起走
/// （与分镜模型 `manga_panel_model_attribution_guard_test.dart` 同一口径）。
void main() {
  final Map<String, dynamic> manifest =
      jsonDecode(
            File('../tool/manga_ocr_kv/model_manifest.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('运行时清单与工具清单逐文件一致（文件名 / URL / 字节数 / sha256）', () {
    final List<dynamic> assets = manifest['assets'] as List<dynamic>;
    expect(kMangaOcrKvAcceleratorManifest, hasLength(assets.length));
    for (final (int index, MangaOcrModelFile file)
        in kMangaOcrKvAcceleratorManifest.indexed) {
      final Map<String, dynamic> asset = assets[index] as Map<String, dynamic>;
      expect(file.fileName, asset['file']);
      expect(file.url, asset['url']);
      expect(file.expectedBytes, asset['bytes']);
      expect(file.sha256, asset['sha256']);
    }
  });

  test('资产钉在不可变 release tag 上，每个文件都带 sha256', () {
    expect(kMangaOcrKvReleaseBase, endsWith('/${manifest['releaseTag']}'));
    for (final MangaOcrModelFile file in kMangaOcrKvAcceleratorManifest) {
      expect(file.url, '$kMangaOcrKvReleaseBase/${file.fileName}');
      expect(file.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(file.expectedBytes, greaterThan(0));
    }
  });

  test('训练集署名：工具清单与仓库 README 都带着 Manga109-s', () {
    final Map<String, dynamic>? training =
        manifest['trainingData'] as Map<String, dynamic>?;
    expect(training, isNotNull);
    expect(training!['name'], 'Manga109-s');
    expect((training['terms'] as String?) ?? '', isNotEmpty);
    final String readme = File('../README.md').readAsStringSync();
    expect(readme, contains('tool/manga_ocr_kv/'));
    expect(readme, contains('Manga109-s'));
  });
}
