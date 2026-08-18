import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';

/// 来源开关的偏好层：默认值即**兼容契约**，所以每一条默认值都要有断言。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('jimakuEnabled defaults to true so existing keys keep working', () {
    // 本键出现之前「填了 key」即启用。默认 false 会让所有已填 key 的存量用户在
    // 升级后 Jimaku 无声失效，且他们无从知道是新加了一个开关。
    expect(prefs.jimakuEnabled, isTrue);
  });

  test('jimakuEnabled round-trips', () async {
    await prefs.setJimakuEnabled(false);
    expect(prefs.jimakuEnabled, isFalse);
    await prefs.setJimakuEnabled(true);
    expect(prefs.jimakuEnabled, isTrue);
  });

  test('built-in video sources are all enabled out of the box', () async {
    expect(prefs.videoResourceDisabledSources, '');
    await prefs.setVideoResourceDisabledSources('apibay,knaben');
    expect(prefs.videoResourceDisabledSources, 'apibay,knaben');
  });

  test('discovery keeps sukebei out of the aggregate by default', () {
    // 出厂默认停用 18+ 源；新加的开关 UI 不得改变这个出厂值。
    expect(prefs.discoveryDisabledSources, 'sukebei');
  });

  test('both new keys are registered as known preference keys', () {
    // 未登记的键会被偏好审计当成孤儿清掉。
    expect(kKnownPreferenceKeys, contains('jimaku_enabled'));
    expect(kKnownPreferenceKeys, contains('video_resource_disabled_sources'));
  });

  test('the Jimaku switch travels with the key across interconnected devices',
      () {
    // 只搬 key 不搬开关，子设备会拿到一把配好却处于关闭状态的 key。
    expect(
      InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
      containsAll(<String>['jimaku_api_key', 'jimaku_enabled']),
    );
    // 停用清单是设备本地口味，不跨设备携带。
    expect(
      InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
      isNot(contains('video_resource_disabled_sources')),
    );
    expect(
      InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
      isNot(contains('discovery_disabled_sources')),
    );
  });
}
