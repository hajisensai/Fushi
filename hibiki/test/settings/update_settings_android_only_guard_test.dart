import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-013 演进（全平台自动更新 Phase 1）：更新分区不再仅 Android。
/// 不变量：分区按 platformSupportsUpdateCheck()（恒真）可见；自动安装开关按
/// platformSupportsInAppInstall()（本期 Android+Windows）网关；数据侧 UpdateChecker
/// 不再硬门控 Android，而是按 updater.supportsUpdateCheck。
void main() {
  test('update section gated by capability helper, not Platform.isAndroid', () {
    final String src =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    final String systemDest = _functionSource(
      src,
      'SettingsDestination _systemDestination() {',
      'String _selectedUpdateChannel(',
    );
    expect(
        systemDest, contains('visible: (_) => platformSupportsUpdateCheck()'));
    expect(systemDest.contains('visible: (_) => Platform.isAndroid'), isFalse,
        reason: '更新分区不应再硬绑 Android（已扩展到全平台）');
    final int autoIdx = systemDest.indexOf("id: 'system.update_auto_install'");
    expect(autoIdx, isNonNegative);
    expect(
        systemDest, contains('visible: (_) => platformSupportsInAppInstall()'),
        reason: '自动安装开关必须按 platformSupportsInAppInstall 网关');
  });

  test('UpdateChecker no longer hard-returns on non-Android', () {
    final String src =
        File('lib/src/utils/misc/update_checker.dart').readAsStringSync();
    expect(src.contains('if (!Platform.isAndroid) return;'), isFalse,
        reason: '检查流程已按 updater.supportsUpdateCheck 门控');
    expect(src, contains('updaterForCurrentPlatform()'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
