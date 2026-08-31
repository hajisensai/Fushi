import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1980 的迁移判据：旧安装没有 `network_proxy_mode` 键时，`networkProxyMode`
/// 要从存量的 `update_custom_proxy` 推导出一个模式。
///
/// 判据必须是「这个存量地址**归一得出来**吗」，而不是「非空吗」。设置页历来对非法
/// 地址只弹 SnackBar 却仍存原串，所以存量里真实存在 `[::1]:7890`（IPv6 不支持）、
/// 带路径、带空格这类「存下来了但归一失败」的值。按非空推成 manual，而 manual 归一
/// 失败时 `applyAppProxy` 硬走 DIRECT —— 这类用户升级一次就全应用断网。旧行为在这种
/// 值上是 fail-open（落回 env > 系统代理），迁移不得把它翻成 fail-closed。
///
/// 只有「用户显式选了 manual」才该 fail-closed（新语义，正确）；从旧数据**推导**出来
/// 的 manual 必须保持 fail-open。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('没有存量地址 → auto', () async {
    expect(prefs.networkProxyMode, 'auto');
  });

  test('存量地址合法 → manual（这条是旧行为，必须保住）', () async {
    await prefs.setPref('update_custom_proxy', '127.0.0.1:7890');
    expect(prefs.networkProxyMode, 'manual');
  });

  test('存量地址归一失败 → auto（fail-open），不得推成 manual', () async {
    // 每一个都是设置页会存下来、而 normalizeUserProxyHostPort 归不出来的真实形态。
    for (final String stored in <String>[
      '[::1]:7890', // IPv6 字面量，归一化明确不支持
      'not a proxy', // 带空格
      'http://127.0.0.1:7890/pac', // 带路径
      '127.0.0.1:99999', // 端口越界
      '127.0.0.1', // 缺端口
    ]) {
      await prefs.setPref('update_custom_proxy', stored);
      expect(prefs.networkProxyMode, 'auto',
          reason: '$stored 归一失败，推成 manual 会让这批存量用户升级即断网');
    }
  });

  test('显式存了模式就以它为准，不再看地址', () async {
    await prefs.setPref('update_custom_proxy', 'not a proxy');
    await prefs.setPref('network_proxy_mode', 'manual');
    expect(prefs.networkProxyMode, 'manual',
        reason: '用户显式选的 manual 该 fail-closed，这是新语义');
    await prefs.setPref('network_proxy_mode', 'direct');
    expect(prefs.networkProxyMode, 'direct');
  });
}
