import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fushi/src/startup/durable_shared_preferences.dart';
import 'package:fushi/src/startup/test_environment.dart';

/// 测试根下 SharedPreferences 的文件名（与桌面插件的默认文件名一致，方便取证对照）。
const String kTestRootSharedPreferencesFileName = 'shared_preferences.json';

/// `FUSHI_TEST_ROOT` 生效时，把桌面端 SharedPreferences 换成落在
/// `<测试根>/app-support/shared_preferences.json` 的文件存储。
///
/// 为什么需要：Drift / [AppPaths] 早就按测试根隔离了，但 SharedPreferences 不是——
/// Windows 插件经 `SHGetKnownFolderPath(RoamingAppData)` 取目录，不看
/// `run_windows_itest.ps1` 改掉的 `APPDATA` 环境变量；macOS 走 bundle id 域的
/// NSUserDefaults。于是集成测试写的 Anki 设置（牌组、`tags`）直接落进用户真实的
/// `%APPDATA%\Fushi\Fushi\shared_preferences.json`，用户之后制的每张卡都带上
/// `fushi_game_stream_e2e_<时间戳>` 标签。
///
/// 必须在进程内**第一次** `SharedPreferences.getInstance()` 之前调用（插件会缓存
/// 首次读到的整份数据）；重复调用是幂等的。移动端各 app 自带沙盒、不装。
/// 返回是否已处于隔离状态。
bool isolateSharedPreferencesUnderTestRoot({
  Map<String, String>? environment,
  String dartDefineRoot = const String.fromEnvironment('FUSHI_TEST_ROOT'),
  bool? isDesktop,
}) {
  if (SharedPreferencesStorePlatform.instance
      is TestRootSharedPreferencesStore) {
    return true;
  }
  final bool desktop =
      isDesktop ?? (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  if (!desktop) return false;
  final Directory? support = fushiTestDirectory(
    'app-support',
    environment: environment,
    dartDefineRoot: dartDefineRoot,
  );
  if (support == null) return false;
  SharedPreferencesStorePlatform.instance = TestRootSharedPreferencesStore(
    File(p.join(support.path, kTestRootSharedPreferencesFileName)),
  );
  return true;
}

/// 测试根下的偏好存储：与生产同一套原子写 / 损坏隔离实现，只是文件固定在测试根。
class TestRootSharedPreferencesStore extends DurableFileSharedPreferencesStore {
  TestRootSharedPreferencesStore(this.file) : super(() async => file);

  final File file;
}
