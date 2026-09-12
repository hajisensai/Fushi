import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-898：手动「立即检查更新」按钮源码守卫。
///
/// 不变量：
/// - 系统设置在 `t.section_update` 分区有 `id: 'system.check_update_now'` 动作项。
/// - 编排函数 `checkAppUpdateNow`（`updates/app_update_check.dart`，设置页与更新
///   中心共用）传 `neverRemind: false` + `autoInstall: false`（手动语义，防回归成
///   「点一下就静默自动装」/「被免提醒吞掉」）。
/// - 防连点靠模块级 `_manualCheckInFlight` 旗标。
/// - 更新中心的 app 新版本条目落到同一条应用内链路，不 `launchUrl` 跳浏览器。
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
      'Future<void> _exportStudyDiagLog(',
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
        File('lib/src/updates/app_update_check.dart').readAsStringSync();
    final String orchestration = _functionSource(
      src,
      'Future<void> checkAppUpdateNow(',
      'UpdateChannel appUpdateChannelOf(',
    );
    // 设置页按钮必须委托到这条共用编排，不再各自复制一份。
    final String settings =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    expect(settings, contains('checkAppUpdateNow('));
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

  test('updates center lands app release on in-app update, not the browser',
      () {
    final String src =
        File('lib/src/pages/implementations/updates_center_open.dart')
            .readAsStringSync();
    final String appRelease = _functionSource(
      src,
      'case UpdateFeedKind.appRelease:',
      'case UpdateFeedKind.videoEpisode:',
    );
    expect(appRelease, contains('checkAppUpdateNow('),
        reason: 'app 新版本必须走应用内检查 → 下载 → 安装');
    expect(src, isNot(contains('launchUrl(')),
        reason: '更新中心的落点全在 app 内，不该把用户送到浏览器');
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
