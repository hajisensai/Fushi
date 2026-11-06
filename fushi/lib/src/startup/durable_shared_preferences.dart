import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// 桌面 SharedPreferences 落盘文件名（与官方 Windows / Linux 插件一致，存量数据原地沿用）。
const String kSharedPreferencesFileName = 'shared_preferences.json';

/// 上一份读通过的偏好文件副本（损坏时据此恢复）。
const String kSharedPreferencesBackupSuffix = '.bak';

/// 损坏文件隔离后的后缀前缀（后接时间戳）。
const String kSharedPreferencesCorruptSuffix = '.corrupt-';

/// 反馈 p8vt5jHJgC：Windows「配置完重启后」启动报
/// `FormatException: Unexpected character (at character 1)` + 一长串方框。
///
/// 根因在官方 `shared_preferences_windows` / `shared_preferences_linux` 插件：
///   - 写盘是**原地** `writeAsStringSync`（不 flush、不走临时文件），写完不久断电 /
///     强制关机，NTFS 会留下一份长度对、内容全是 NUL 的文件；
///   - 读盘直接 `json.decode`，不接异常——一份坏文件让**每一次**
///     `SharedPreferences.getInstance()` 都抛 FormatException（失败不缓存，次次重读），
///     启动链上任何一处没包 try 的读取都把整个初始化打成错误屏，Retry 也一样。
///
/// 本存储替换这两个插件（同一个文件、同一份 JSON 格式，存量数据零迁移）：
///   - 写：临时文件 + flush + rename 原子替换，断电只会留下旧的完整文件；
///   - 读：解析失败（含空文件 / 非对象 JSON / 非法 UTF-8）**不抛**——把坏文件改名隔离到
///     `shared_preferences.json.corrupt-<时间>`（原样保留可取证 / 手动找回），再用上次
///     读通过时留的 `.bak` 恢复；没有备份才以空偏好继续启动。每次恢复都记进
///     [recoveryReports]，错误日志就绪后由 [drainRecoveryReports] 折进去。
class DurableFileSharedPreferencesStore extends SharedPreferencesStorePlatform {
  DurableFileSharedPreferencesStore(
    this._resolveFile, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 固定文件（测试根 / 单测）。
  DurableFileSharedPreferencesStore.at(File file, {DateTime Function()? clock})
    : this(() async => file, clock: clock);

  final Future<File?> Function() _resolveFile;
  final DateTime Function() _clock;
  File? _file;
  Map<String, Object>? _cache;

  static const String _defaultPrefix = 'flutter.';

  /// 本进程内发生过的损坏恢复说明（给错误日志用）。
  static final List<String> recoveryReports = <String>[];

  /// 取走并清空 [recoveryReports]。
  static List<String> drainRecoveryReports() {
    final List<String> out = List<String>.of(recoveryReports);
    recoveryReports.clear();
    return out;
  }

  Future<File?> _target() async => _file ??= await _resolveFile();

  Future<Map<String, Object>> _read() async {
    final Map<String, Object>? cached = _cache;
    if (cached != null) return cached;
    final File? file = await _target();
    return _cache = file == null ? <String, Object>{} : _load(file);
  }

  Map<String, Object> _load(File file) {
    if (!file.existsSync()) return <String, Object>{};
    final Map<String, Object>? data = _tryParse(file);
    if (data != null) {
      // 读通过的才当备份：下次主文件坏了就回到这一份。
      _writeAtomically(
        File('${file.path}$kSharedPreferencesBackupSuffix'),
        data,
      );
      return data;
    }
    return _recover(file);
  }

  Map<String, Object> _recover(File file) {
    final String stamp = _clock().toIso8601String().replaceAll(
      RegExp(r'[:\-.]'),
      '',
    );
    final String quarantined =
        '${file.path}$kSharedPreferencesCorruptSuffix$stamp';
    String moved;
    try {
      file.renameSync(quarantined);
      moved = quarantined;
    } on FileSystemException catch (e) {
      moved = '(隔离失败，原文件未动：$e)';
    }
    final File backup = File('${file.path}$kSharedPreferencesBackupSuffix');
    final Map<String, Object>? restored = backup.existsSync()
        ? _tryParse(backup)
        : null;
    if (restored != null) {
      _writeAtomically(file, restored);
      _report(
        '偏好文件损坏（无法解析为 JSON），已隔离到 $moved，并用上次的备份恢复了 '
        '${restored.length} 项设置',
      );
      return restored;
    }
    _report(
      '偏好文件损坏（无法解析为 JSON）且没有可用备份，已隔离到 $moved，'
      '本次以默认设置启动（自定义数据位置等需在设置里重新选择）',
    );
    return <String, Object>{};
  }

  void _report(String message) {
    debugPrint('[DurableSharedPreferences] $message');
    recoveryReports.add(message);
  }

  /// 解析成功返回数据；坏文件（空 / 非法 UTF-8 / 非 JSON / 不是对象）返回 null。
  /// 读不了（占用 / 权限）不算损坏，照常抛出，不隔离用户文件。
  static Map<String, Object>? _tryParse(File file) {
    final List<int> bytes = file.readAsBytesSync();
    final Object? decoded;
    try {
      final String raw = utf8.decode(bytes);
      if (raw.trim().isEmpty) return null;
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Map<String, Object> data = <String, Object>{};
    decoded.forEach((Object? key, Object? value) {
      if (key is! String || value == null) return;
      data[key] = value is List
          ? value.map((Object? e) => '$e').toList()
          : value;
    });
    return data;
  }

  static bool _writeAtomically(File file, Map<String, Object> data) {
    try {
      file.parent.createSync(recursive: true);
      final File staging = File('${file.path}.tmp');
      staging.writeAsStringSync(jsonEncode(data), flush: true);
      staging.renameSync(file.path);
      return true;
    } on FileSystemException catch (e) {
      debugPrint('[DurableSharedPreferences] write ${file.path} failed: $e');
      return false;
    }
  }

  Future<bool> _write(Map<String, Object> data) async {
    final File? file = await _target();
    if (file == null) return false;
    return _writeAtomically(file, data);
  }

  bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) &&
      (filter.allowList == null || filter.allowList!.contains(key));

  @override
  Future<bool> remove(String key) async {
    final Map<String, Object> data = await _read();
    data.remove(key);
    return _write(data);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final Map<String, Object> data = await _read();
    data[key] = value;
    return _write(data);
  }

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final Map<String, Object> data = await _read();
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
    final Map<String, Object> result = Map<String, Object>.from(await _read());
    result.removeWhere((String key, _) => !_matches(key, parameters.filter));
    return result;
  }
}

/// Windows / Linux 生产环境：把 SharedPreferences 换成 [DurableFileSharedPreferencesStore]
/// （同一文件，`getApplicationSupportDirectory()/shared_preferences.json`，与官方插件
/// 的 `getApplicationSupportPath()` 同源）。macOS 走 NSUserDefaults、移动端各有原生
/// 存储，都不经这条 JSON 文件，不装。
///
/// 必须在进程内第一次 `SharedPreferences.getInstance()` 之前调用；文件路径延迟到第一次
/// 读写才解析，所以放在 `migrateLegacySupportDir()` 之前也安全。已装过（含测试根隔离
/// 存储）时不动。返回是否已装上。
bool installDurableDesktopSharedPreferences({bool? isWindowsOrLinux}) {
  if (SharedPreferencesStorePlatform.instance
      is DurableFileSharedPreferencesStore) {
    return true;
  }
  if (!(isWindowsOrLinux ?? (Platform.isWindows || Platform.isLinux))) {
    return false;
  }
  SharedPreferencesStorePlatform.instance = DurableFileSharedPreferencesStore(
    () async => File(
      p.join(
        (await getApplicationSupportDirectory()).path,
        kSharedPreferencesFileName,
      ),
    ),
  );
  return true;
}
