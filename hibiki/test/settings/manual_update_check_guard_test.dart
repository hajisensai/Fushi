import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-898：手动「立即检查更新」按钮源码守卫。
///
/// 不变量：
/// - 系统设置在 `t.section_update` 分区有 `id: 'system.check_update_now'` 动作项。
/// - 编排函数 `_checkUpdateNow` 传 `neverRemind: false` + `autoInstall: false`
///   （手动语义，防回归成「点一下就静默自动装」/「被免提醒吞掉」）。
/// - 防连点靠模块级 `_manualCheckInFlight` 旗标。
/// - `UpdateChecker.scheduleCheck` 仍带默认 null 的 onUpToDate/onError 回调
///   （向后兼容，自动检查零变化）。
void main() {
  test('system settings expose a manual check-update action in update section',
      () {
    final String src =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    final String systemDest = _functionSource(
      src,
      'SettingsDestination buildSystemDestination() {',
      'bool _manualCheckInFlight',
    );
    final int updateSectionIdx = systemDest.indexOf('title: t.section_update,');
    expect(updateSectionIdx, isNonNegative,
        reason: 'update section must exist');
    final int actionIdx = systemDest.indexOf("id: 'system.check_update_now'");
    expect(actionIdx, isNonNegative,
        reason: 'manual check-update action must exist');
    expect(actionIdx, greaterThan(updateSectionIdx),
        reason: '按钮必须落在更新分区内（在 section_update 之后出现）');
    expect(systemDest, contains('title: t.settings_check_update_now'));
    expect(systemDest, contains('onTap: _checkUpdateNow'));
  });

  test('manual orchestration uses manual semantics (no silent auto-install)',
      () {
    final String src =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    final String orchestration = _functionSource(
      src,
      'Future<void> _checkUpdateNow(',
      'Widget _buildUpdateCustomProxyField(',
    );
    expect(orchestration, contains('neverRemind: false'), reason: '手动检查无视免提醒');
    expect(orchestration, contains('autoInstall: false'),
        reason: '手动检查走确认弹窗，不静默自动装');
    expect(orchestration, contains('onUpToDate:'));
    expect(orchestration, contains('onError:'));
    expect(orchestration, contains('t.update_checking_now'), reason: '点击即时反馈');
    expect(orchestration, contains('t.update_already_latest'));
    expect(orchestration, contains('t.update_check_failed'));
    // 防连点旗标。
    expect(src, contains('bool _manualCheckInFlight = false;'));
    expect(orchestration, contains('if (_manualCheckInFlight) return;'));
    expect(orchestration, contains('_manualCheckInFlight = true;'));
    expect(orchestration, contains('_manualCheckInFlight = false;'));
  });

  test('scheduleCheck keeps default-null callbacks (auto-check unchanged)', () {
    final String src = File('lib/src/utils/misc/update_checker_release.dart')
        .readAsStringSync();
    expect(src, contains('void Function()? onUpToDate,'));
    expect(src, contains('void Function(Object error)? onError,'));
    // 三条「无可更新版本」早退都要触发 onUpToDate（必修1）。
    final int upToDateCalls = 'onUpToDate?.call();'.allMatches(src).length;
    expect(upToDateCalls, greaterThanOrEqualTo(3),
        reason: 'onUpToDate 必须覆盖三条无更新早退（selection==null / tag空 / 已最新）');
    expect(src, contains('onError?.call(e)'), reason: 'onError 挂在 catch 分支');
    // 可注入 fetcher seam（必修2），不拆网络层。
    expect(src, contains('fetchReleases'));
    expect(
        src,
        contains(
            'await (fetchReleases ?? _fetchReleasesForChannel)(client, channel)'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
