import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

import '../../integration_test/helpers/schema_settings_verifier.dart';

void main() {
  test('verdict marks a switch verified when value flips and probe confirms',
      () {
    bool model = false; // 被测“配置项”的真实存储

    final SettingsSwitchItem item = SettingsSwitchItem(
      id: 'demo.flag',
      title: 'Flag',
      value: (_) => model,
      onChanged: (_, bool v) => model = v,
    );

    final ItemVerdict v = verifyItemLogic(
      controlType: 'SettingsSwitchItem',
      id: item.id,
      readValue: () => model,
      applyChange: () => model = !model, // 焦点激活的“等价”逻辑
      effect: () => true, // demo：model 翻转即视为生效（真实接 effect_probes）
      restore: (Object? before) => model = before! as bool,
    );

    expect(v.reached, isTrue);
    expect(v.changed, isTrue);
    expect(v.persisted, isTrue);
    expect(v.effectVerified, isTrue);
    expect(v.restored, isTrue);
    expect(v.isPass, isTrue);
    expect(model, isFalse, reason: '必须还原到初值');
  });

  test('verdict is WARN (not pass) when no effect probe is available', () {
    bool model = false;
    final ItemVerdict v = verifyItemLogic(
      controlType: 'SettingsSwitchItem',
      id: 'demo.noprobe',
      readValue: () => model,
      applyChange: () => model = !model,
      effect: null, // 没探针
      restore: (Object? before) => model = before! as bool,
    );
    expect(v.persisted, isTrue);
    expect(v.effectVerified, isFalse);
    expect(v.isPass, isFalse, reason: '只写穿不算 PASS，必须标 UNVERIFIED');
    expect(v.note, contains('EFFECT UNVERIFIED'));
  });
}
