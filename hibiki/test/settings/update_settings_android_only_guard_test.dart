import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-013 回归守卫：自动更新整条链路仅 Android 实现
/// （`UpdateChecker._check` 在 `!Platform.isAndroid` 时直接 return，原生
/// `installApk` 通道也只在 Android `MainActivity` 注册）。因此「更新」设置分区
/// 必须**仅在 Android 可见**，否则 iOS/macOS/Windows/Linux 会出现「可见但拨动
/// 无效」的死开关。
///
/// 用源码扫描守卫（不依赖宿主平台、零 schema 重量级 wiring）：锚定稳定的持久化
/// key 字面量（`system.update_*`，按仓库纪律不可改）+ 网关表达式 + 数据侧
/// `!Platform.isAndroid` 早退，任一侧被移除即触发红灯。
void main() {
  test('update settings section is gated to Android (BUG-013)', () {
    final String source =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();

    // 截取 _systemDestination() 函数体（更新分区所在）。结束锚点 =
    // 紧随其后的 _selectedUpdateChannel 顶层函数。
    final String systemDest = _functionSource(
      source,
      'SettingsDestination _systemDestination() {',
      'String _selectedUpdateChannel(',
    );

    // 三个更新设置的持久化 key（稳定字面量，仓库纪律禁止随手改）。
    const List<String> updateIds = <String>[
      "id: 'system.update_channel'",
      "id: 'system.update_never_remind'",
      "id: 'system.update_auto_install'",
    ];

    const String gate = 'visible: (_) => Platform.isAndroid';
    const String sectionTitle = 'title: t.section_update,';

    // 更新分区是 _systemDestination 内第一个 SettingsSection（title=section_update）。
    final int sectionTitleIdx = systemDest.indexOf(sectionTitle);
    expect(sectionTitleIdx, isNonNegative,
        reason: '更新分区应以 title: t.section_update 标识');

    // 网关须存在，且紧跟在更新分区标题之后（即它网关的是更新分区，
    // 而非该 destination 的第二个「系统」分区）。
    final int gateIdx = systemDest.indexOf(gate, sectionTitleIdx);
    expect(gateIdx, isNonNegative,
        reason: '更新分区必须带 $gate 网关（BUG-013：否则非 Android 死开关）');

    // 三个更新设置都必须落在网关之后（被网关覆盖）。
    for (final String id in updateIds) {
      final int idIdx = systemDest.indexOf(id);
      expect(idIdx, isNonNegative, reason: '缺更新设置项: $id');
      expect(gateIdx, lessThan(idIdx),
          reason: 'Android 网关必须声明在 $id 之前，才能真正网关该项');
    }

    // summary 也按平台分流，非 Android 不挂「更新」副标题。
    expect(
      systemDest,
      contains('summary: Platform.isAndroid ? t.section_update : null'),
      reason: '非 Android 下「系统」分区不应以更新作为副标题',
    );
  });

  test('UpdateChecker pipeline delegates gating to PlatformUpdater', () {
    final String source =
        File('lib/src/utils/misc/update_checker.dart').readAsStringSync();

    // 数据侧不变量（Phase 1 重构后）：检查/选包/安装整条链不再硬编码
    // `!Platform.isAndroid`，而是委托 `updaterForCurrentPlatform()`：
    //   - `supportsUpdateCheck` 决定是否拉取 release（全平台为 true）；
    //   - `supportsInAppInstall` 决定能否自动下载安装（Android/Windows）
    //     还是只「检查→打开发布页」（iOS/mac/Linux）。
    // BUG-013 的死开关风险改由各 PlatformUpdater 的 supports* + UI 网关共同
    // 保证，二者仍须同进退。
    expect(
      source,
      isNot(contains('if (!Platform.isAndroid) return;')),
      reason: 'Phase 1 起 UpdateChecker 不再硬门控 Android；'
          '应委托 updaterForCurrentPlatform()',
    );
    expect(
      source,
      contains('final PlatformUpdater updater = updaterForCurrentPlatform();'),
      reason: 'UpdateChecker._check 必须委托 updaterForCurrentPlatform() 选平台策略',
    );
    expect(
      source,
      contains('if (!updater.supportsUpdateCheck) return;'),
      reason: '检查更新门控须走 updater.supportsUpdateCheck',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
