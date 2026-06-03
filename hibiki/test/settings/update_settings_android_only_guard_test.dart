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

  test('UpdateChecker pipeline is Android-only (data-side invariant)', () {
    final String source =
        File('lib/src/utils/misc/update_checker.dart').readAsStringSync();

    // 数据侧不变量：检查/下载/安装整条链在非 Android 直接 return。
    // 这是上面 UI 网关的根因——二者必须同进退。
    expect(
      source,
      contains('if (!Platform.isAndroid) return;'),
      reason: 'UpdateChecker._check 必须在非 Android 早退；'
          '若放开更新到其它平台，须同时重审 UI 网关（BUG-013）',
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
