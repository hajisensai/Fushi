import 'dart:io';

import 'package:test/test.dart';

/// BUG-4698 守卫：app 内的推荐包入口一律经 `importRecommendedPackFile` /
/// `importDownloadedRecommendedPack`（确认框预选合并），不得直接调
/// `runBackupImportFlowForFile`——那条路径缺省预选「覆盖」，用户照默认点下去就整库
/// 被推荐包替换（漫画 / 小说 / 进度全没）。
///
/// 拍板台 pr3449：确认框照弹（不跳过最终确认与内容摘要），只是预选合并；预选本身由
/// `test/sync/backup_import_confirm_initial_mode_test.dart` 真弹框验证。
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

  test('the shared pack import preselects merge and never presets the app '
      'entries', () {
    final String src = read('onboarding/recommended_pack_import.dart');
    // 唯一一处直接调用，确认框预选合并。
    expect('runBackupImportFlowForFile('.allMatches(src), hasLength(1));
    expect(src, contains('confirmInitialMode: kRecommendedPackImportMode,'));
    expect(
      src,
      contains(
        'const BackupImportMode kRecommendedPackImportMode = '
        'BackupImportMode.merge;',
      ),
    );
    // app 内入口不带预设（带预设会跳过确认框，只有控制通道的知情选择可以）。
    expect(src, contains('BackupImportPreset? preset,'));
    expect(src, isNot(contains('BackupImportPreset preset =')));
  });

  test('runBackupImportFlowForFile forwards confirmInitialMode to the '
      'confirm dialog', () {
    // 编排函数把 confirmInitialMode 转给确认框；这一行被删，确认框会退回缺省「覆盖」，
    // BUG-4698 原样复发，而直接调确认框的 widget 测试仍全绿。
    final String src = read('sync/sync_settings_schema/backup.part.dart');
    final int start = src.indexOf('Future<void> runBackupImportFlowForFile({');
    expect(start, isNonNegative);
    final int dialogCall = src.indexOf(
      'await _showBackupImportConfirmDialog(',
      start,
    );
    expect(dialogCall, isNonNegative);
    final int callEnd = src.indexOf(');', dialogCall);
    expect(
      src.substring(dialogCall, callEnd),
      contains('initialMode: confirmInitialMode,'),
    );
  });

  for (final String rel in entryFiles) {
    test('$rel does not preset the pack import (dialog must show)', () {
      expect(read(rel), isNot(contains('preset:')));
    });
  }
}
