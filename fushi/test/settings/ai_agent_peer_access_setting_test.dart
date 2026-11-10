import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';

/// 「允许已配对设备使用 AI 助手」（2026-10-27 审查）：app 当互联 host 时远端 AI 助手
/// 与服务端 `ai.agent_for_peers` 同一判据——默认关、只能由用户在设置页亲手打开。
/// 门本身的行为（关着 → disabled、不建模型）在 test/sync/app_agent_assistant_host_test.dart。
/// 这一行是对已配对设备的授权，和别的「允许已配对设备…」一起住在
/// 「Fushi 互联 › 主机服务」子页（入口 interconnect.host），不在 AI 页里。
void main() {
  SettingsDestination hostPage() =>
      (buildInterconnectDestination().sections
                  .expand((SettingsSection s) => s.items)
                  .singleWhere((SettingsItem i) => i.id == 'interconnect.host')
              as SettingsNavigationItem)
          .child!();

  SettingsSwitchItem item() =>
      hostPage().sections
              .expand((SettingsSection s) => s.items)
              .singleWhere((SettingsItem i) => i.id == 'ai.agent_for_peers')
          as SettingsSwitchItem;

  test('住在互联主机服务页，不再挂在 AI 页', () {
    expect(item(), isNotNull);
    expect(
      buildAiDestination().sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id),
      isNot(contains('ai.agent_for_peers')),
    );
  });

  test('默认关', () {
    expect(item().defaultValue, isFalse);
  });

  test('授权开关只能由用户拨：AI 的 settings.set 写不进去', () {
    expect(item().userOnly, isTrue);
    expect(isModelWritableSetting(item().id, item()), isFalse);
    // 普通开关照旧可写。
    final SettingsSwitchItem ordinary = buildAiDestination().sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsSwitchItem>()
        .firstWhere((SettingsSwitchItem i) => !i.userOnly);
    expect(isModelWritableSetting(ordinary.id, ordinary), isTrue);
  });
}
