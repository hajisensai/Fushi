import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';

/// 「允许已配对设备使用 AI 助手」（2026-10-27 审查）：app 当互联 host 时远端 AI 助手
/// 与服务端 `ai.agent_for_peers` 同一判据——默认关、只能由用户在设置页亲手打开。
/// 门本身的行为（关着 → disabled、不建模型）在 test/sync/app_agent_assistant_host_test.dart。
void main() {
  SettingsSwitchItem item() =>
      buildAiDestination().sections
              .expand((SettingsSection s) => s.items)
              .singleWhere((SettingsItem i) => i.id == 'ai.agent_for_peers')
          as SettingsSwitchItem;

  test('默认关', () {
    expect(item().defaultValue, isFalse);
  });

  test('授权开关只能在设置页拨：控制通道（含 AI 的 settings.set）写不进去', () {
    expect(item().uiOnly, isTrue);
    expect(isCtlWritableSettingItem(item()), isFalse);
    // 普通开关照旧可写。
    final SettingsSwitchItem ordinary = buildAiDestination().sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsSwitchItem>()
        .firstWhere((SettingsSwitchItem i) => !i.uiOnly);
    expect(isCtlWritableSettingItem(ordinary), isTrue);
  });
}
