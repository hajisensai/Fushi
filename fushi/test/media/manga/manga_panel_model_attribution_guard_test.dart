import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/panel_model_manifest.dart';

/// 分镜模型的训练集署名（PR #1591 审查）。
///
/// 上游权重训练自 **Manga109-s**：它的条款允许把训练所得模型用于商业用途，但
/// **要求明确标明用到了该数据集**。署名只写在上游模型卡里不算数——我们分发的是
/// 从它导出的 ONNX 资产，所以清单、工具文档和仓库 README 三处都要带着它。
/// 这条守卫存在的理由是：这类合规声明一旦漏掉，本地和 CI 全绿，出问题时才发现。
void main() {
  test('运行时清单带着 Manga109-s 署名', () {
    expect(kMangaPanelModelTrainingData, 'Manga109-s');
    expect(kMangaPanelModelTrainingDataUrl, contains('manga109.org'));
    expect(kMangaPanelModelTrainingDataNotice, contains('Manga109-s'));
    expect(kMangaPanelModelManifest.trainingData, 'Manga109-s');
  });

  test('工具清单 JSON 记录训练集与其条款', () {
    final File manifest = File('../tool/manga_panel/model_manifest.json');
    expect(manifest.existsSync(), isTrue);
    final Map<String, dynamic> json =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic>? training =
        json['trainingData'] as Map<String, dynamic>?;
    expect(training, isNotNull, reason: '清单必须记录训练集来源');
    expect(training!['name'], 'Manga109-s');
    expect((training['terms'] as String?) ?? '', isNotEmpty);
    expect(training['citations'], isA<List<dynamic>>());
    expect((training['citations'] as List<dynamic>).length, greaterThan(1));
  });

  test('仓库 README 的模型致谢列出 Manga109-s', () {
    final String readme = File('../README.md').readAsStringSync();
    expect(readme, contains('manga-panel-detector-yolo26n'));
    expect(readme, contains('Manga109-s'));
  });
}
