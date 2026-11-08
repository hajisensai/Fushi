import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-4245：手动 IP / 发现列表配对时，host 在 `/api/ping` 报了展示名（身份确认框里给用户看过），
/// 配对成功收尾却把这条地址的 deviceName 写成 null——复习页「已配对设备」、地址列表都只能显示
/// IP。
void main() {
  // 收尾在设置页 part 的私有 State 里，没有低成本的行为入口：用源码切片钉住「名字一路传到落库」。
  test('pairing passes the host name reported by ping through to the saved '
      'address', () {
    final String source = maskComments(readSyncSettingsSchemaSource());
    final int flowStart = source.indexOf('  Future<void> _runPairingV2({');
    final int successStart = source.indexOf('Future<String> _onPairSuccess(');
    expect(flowStart, greaterThanOrEqualTo(0), reason: '_runPairingV2 丢失');
    expect(successStart, greaterThan(flowStart), reason: '_onPairSuccess 丢失');
    final String flow = source.substring(flowStart, successStart);
    final RegExp call = RegExp(
      r'_onPairSuccess\([^;]*deviceName:\s*deviceName[^;]*\);',
    );
    expect(
      call.hasMatch(flow),
      isTrue,
      reason: '_runPairingV2 拿到的 host 展示名必须交给 _onPairSuccess',
    );

    final int successEnd = source.indexOf('\n  }\n', successStart);
    final String success = source.substring(successStart, successEnd);
    expect(
      success,
      isNot(contains('deviceName: null')),
      reason: '配对收尾不得把展示名写成 null',
    );
    expect(
      RegExp(r'addFushiClientUrl\([^;]*deviceName:\s*name').hasMatch(success),
      isTrue,
      reason: '展示名要写进这条地址',
    );
  });

  test(
    'the saved address keeps the host name, and a later nameless update does '
    'not erase it',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      const String url = 'https://192.0.2.10:38865';
      await repo.addFushiClientUrl(
        url,
        fingerprint: 'aa:bb',
        deviceName: 'srs-host',
      );
      await repo.addFushiClientUrl(url, fingerprint: 'aa:bb');
      final FushiClientUrl saved = (await repo.getFushiClientUrls()).single;
      expect(saved.deviceName, 'srs-host');
    },
  );
}
