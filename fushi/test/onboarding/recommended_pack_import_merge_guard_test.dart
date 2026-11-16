import 'dart:io';

import 'package:test/test.dart';

/// BUG-4694 守卫：app 内的推荐包入口一律经 `importRecommendedPackFile` /
/// `importDownloadedRecommendedPack`（恒合并预设），不得直接调
/// `runBackupImportFlowForFile`——那条路径不带预设时弹的是默认「覆盖」的通用导入
/// 确认框，用户照默认点下去就整库被推荐包替换（漫画 / 小说 / 进度全没）。
///
/// 合并本身能把推荐包装全、且不动书库，由
/// `test/sync/recommended_pack_merge_import_test.dart` 跑真实合并验证；这里只咬住
/// 「入口走对了函数」这一层，因为发起点要立起真 AppModel 才能跑，widget 层够不着。
void main() {
  const String lib = 'lib/src';
  String read(String rel) => File('$lib/$rel').readAsStringSync();

  // 推荐包的全部 app 内发起点。新增发起点时加进来。
  const List<String> entryFiles = <String>[
    'pages/implementations/onboarding_wizard_page.dart',
    'onboarding/recommended_pack_download_mini_bar.dart',
    'settings/settings_schema_system.dart',
  ];

  for (final String rel in entryFiles) {
    test('$rel never calls runBackupImportFlowForFile directly', () {
      expect(read(rel), isNot(contains('runBackupImportFlowForFile(')));
    });
  }

  test('onboarding pack step imports through importRecommendedPackFile', () {
    expect(
      read('pages/implementations/onboarding_wizard_page.dart'),
      contains('await importRecommendedPackFile('),
    );
  });

  test(
    'the shared pack import always forwards a preset (merge by default)',
    () {
      final String src = read('onboarding/recommended_pack_import.dart');
      // 唯一一处直接调用，且必须带预设（否则弹默认覆盖的通用框）。
      expect('runBackupImportFlowForFile('.allMatches(src), hasLength(1));
      expect(src, contains('preset: preset,'));
      expect(
        src,
        contains('BackupImportPreset preset = kRecommendedPackImportPreset'),
      );
      expect(src, isNot(contains('BackupImportPreset? preset')));
    },
  );
}
