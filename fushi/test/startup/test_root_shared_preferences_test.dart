import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 集成测试（run_windows_itest.ps1）只改了 APPDATA 环境变量，而 Windows 的
/// SharedPreferences 经 SHGetKnownFolderPath 取真实 RoamingAppData——游戏串流 E2E
/// 写的 Anki 设置 `tags=fushi_game_stream_e2e_<时间戳>` 因此落进了用户真实的
/// prefs，之后每张卡都带这个标签。测试根生效时 prefs 必须落在测试根里。
void main() {
  late Directory root;
  late SharedPreferencesStorePlatform original;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_prefs_root_');
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = original;
    SharedPreferences.resetStatic();
    root.deleteSync(recursive: true);
  });

  File prefsFile() => File(
    p.join(root.path, 'app-support', kTestRootSharedPreferencesFileName),
  );

  test('测试根生效：写入落在 <根>/app-support，且跨实例读回', () async {
    expect(
      isolateSharedPreferencesUnderTestRoot(
        environment: <String, String>{'FUSHI_TEST_ROOT': root.path},
        dartDefineRoot: '',
        isDesktop: true,
      ),
      isTrue,
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('fushi_anki_settings', '{"tags":"e2e"}');
    await prefs.setStringList('list', <String>['a', 'b']);
    await prefs.setBool('flag', true);

    final Map<String, dynamic> onDisk =
        jsonDecode(prefsFile().readAsStringSync()) as Map<String, dynamic>;
    expect(onDisk['flutter.fushi_anki_settings'], '{"tags":"e2e"}');

    // 模拟重启：新 store 从文件读回，类型保真。
    SharedPreferencesStorePlatform.instance = TestRootSharedPreferencesStore(
      prefsFile(),
    );
    SharedPreferences.resetStatic();
    final SharedPreferences reopened = await SharedPreferences.getInstance();
    expect(reopened.getString('fushi_anki_settings'), '{"tags":"e2e"}');
    expect(reopened.getStringList('list'), <String>['a', 'b']);
    expect(reopened.getBool('flag'), isTrue);
    await reopened.remove('flag');
    expect(reopened.containsKey('flag'), isFalse);
  });

  test('重复调用幂等，不会换掉已装的 store', () {
    final Map<String, String> env = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    isolateSharedPreferencesUnderTestRoot(
      environment: env,
      dartDefineRoot: '',
      isDesktop: true,
    );
    final SharedPreferencesStorePlatform first =
        SharedPreferencesStorePlatform.instance;
    isolateSharedPreferencesUnderTestRoot(
      environment: env,
      dartDefineRoot: '',
      isDesktop: true,
    );
    expect(identical(SharedPreferencesStorePlatform.instance, first), isTrue);
  });

  test('没有测试根或是移动端：不动平台 store', () {
    final SharedPreferencesStorePlatform before =
        SharedPreferencesStorePlatform.instance;
    expect(
      isolateSharedPreferencesUnderTestRoot(
        environment: const <String, String>{},
        dartDefineRoot: '',
        isDesktop: true,
      ),
      isFalse,
    );
    expect(
      isolateSharedPreferencesUnderTestRoot(
        environment: <String, String>{'FUSHI_TEST_ROOT': root.path},
        dartDefineRoot: '',
        isDesktop: false,
      ),
      isFalse,
    );
    expect(identical(SharedPreferencesStorePlatform.instance, before), isTrue);
  });
}
