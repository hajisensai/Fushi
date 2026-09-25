import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

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

/// 整份 JSON 落单文件的 SharedPreferences 存储（写临时文件再 rename，防半截文件）。
class TestRootSharedPreferencesStore extends SharedPreferencesStorePlatform {
  TestRootSharedPreferencesStore(this.file);

  final File file;
  Map<String, Object>? _cache;

  static const String _defaultPrefix = 'flutter.';

  Map<String, Object> _read() {
    final Map<String, Object>? cached = _cache;
    if (cached != null) return cached;
    final Map<String, Object> data = <String, Object>{};
    if (file.existsSync()) {
      final String raw = file.readAsStringSync();
      if (raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((Object? key, Object? value) {
            if (key is! String || value == null) return;
            data[key] = value is List ? value.cast<String>().toList() : value;
          });
        }
      }
    }
    return _cache = data;
  }

  bool _write(Map<String, Object> data) {
    file.parent.createSync(recursive: true);
    final File staging = File('${file.path}.tmp');
    staging.writeAsStringSync(jsonEncode(data), flush: true);
    staging.renameSync(file.path);
    return true;
  }

  bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) &&
      (filter.allowList == null || filter.allowList!.contains(key));

  @override
  Future<bool> remove(String key) async {
    final Map<String, Object> data = _read();
    data.remove(key);
    return _write(data);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final Map<String, Object> data = _read();
    data[key] = value;
    return _write(data);
  }

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final Map<String, Object> data = _read();
    data.removeWhere((String key, _) => _matches(key, parameters.filter));
    return _write(data);
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final Map<String, Object> result = Map<String, Object>.from(_read());
    result.removeWhere((String key, _) => !_matches(key, parameters.filter));
    return result;
  }
}
