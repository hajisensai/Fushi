import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 外部 AI 访问（MCP，反馈 uILXKiYRhl）：默认关，只能由用户在设置页亲手打开；
/// 配对令牌只在设置页生成，控制通道 / AI 签发不了；两者都设备本地。
void main() {
  Iterable<SettingsItem> items() =>
      buildAiDestination().sections.expand((SettingsSection s) => s.items);

  test('开关默认关，且 AI 的 settings.set 写不进去', () {
    final SettingsSwitchItem item =
        items().singleWhere((SettingsItem i) => i.id == 'ai.mcp_access')
            as SettingsSwitchItem;
    expect(item.defaultValue, isFalse);
    expect(item.userOnly, isTrue);
    expect(isModelWritableSetting(item.id, item), isFalse);
  });

  test('令牌只能在设置页生成：控制通道没有对应的 CLI 动作', () {
    final SettingsActionItem item =
        items().singleWhere((SettingsItem i) => i.id == 'ai.mcp_token')
            as SettingsActionItem;
    final SettingsCliAction cli = item.cli!;
    expect(cli.unsupportedHint, isNotNull);
    expect((cli.run, cli.sameAsTap), (null, false));
  });

  test('开关与令牌摘要设备本地（不进备份 / Profile / 同步）', () {
    for (final String key in <String>[
      'ai_mcp_enabled',
      'ai_mcp_token_sha256',
    ]) {
      expect(kKnownPreferenceKeys, contains(key));
      expect(SyncRepository.deviceLocalPrefKeys, contains(key));
    }
  });
}
