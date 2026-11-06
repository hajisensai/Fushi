import 'package:shared_preferences/shared_preferences.dart';

/// Anki 制卡设置（整份 [AnkiSettings] JSON 原始串）的持久化端口。
///
/// 为什么抽这一层：设置以前只存在 SharedPreferences 里，而 SP 插件在**每个
/// isolate / 进程**里各有一份内存缓存——Android 的 `:popup` 独立进程与悬浮词典
/// 副 engine 一旦初始化过，就一直读自己那份旧缓存，主 app 改了牌组 / 配置，应用外
/// 制卡仍用旧值（反馈 fiwDIpFep7）。app 侧把实现换成 Drift `preferences` 表（每次
/// 读直查 DB 单行、写递增跨进程版本号），本包不依赖 fushi_core，故只定义端口。
///
/// 默认实现 [SharedPreferencesAnkiSettingsStore] 留给测试与没有 Drift 库的宿主。
abstract interface class AnkiSettingsStore {
  /// 读原始 JSON 串；null = 从未存过。
  Future<String?> read();

  /// 写原始 JSON 串。失败必须抛异常（调用方据此报「保存失败」）。
  Future<void> write(String json);
}

/// 存量 SharedPreferences 键与它们的只读视图。
///
/// 旧字面量只允许活在这里（W2-7 迁移输入）；[readLegacyJson] **只读不写**，
/// 供 app 把 SP 旧值一次性搬进新存储时用——那条路径可能跑在 `:popup` 进程里，
/// 绝不能在那里改写 / 删除 SP（Android 整文件写回会盖掉主进程的值）。
abstract final class AnkiSettingsSharedPreferencesKeys {
  /// 当前 SP 键。
  static const String settingsKey = 'fushi_anki_settings';

  /// Hibiki 时代的旧键：载入期搬到 [settingsKey] 后删除。
  static const String legacySettingsKey = 'hoshi_anki_settings';

  /// 只读取 SP 里现存的设置串（新键优先，否则旧键），不做任何写入。
  static String? readLegacyJson(SharedPreferences prefs) =>
      prefs.getString(settingsKey) ?? prefs.getString(legacySettingsKey);
}

/// SharedPreferences 实现（行为与迁移前完全一致，含 W2-7 旧键搬移）。
class SharedPreferencesAnkiSettingsStore implements AnkiSettingsStore {
  const SharedPreferencesAnkiSettingsStore();

  @override
  Future<String?> read() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(
      AnkiSettingsSharedPreferencesKeys.settingsKey,
    );
    if (raw != null) return raw;
    final String? legacy = prefs.getString(
      AnkiSettingsSharedPreferencesKeys.legacySettingsKey,
    );
    if (legacy == null) return null;
    await prefs.setString(
      AnkiSettingsSharedPreferencesKeys.settingsKey,
      legacy,
    );
    await prefs.remove(AnkiSettingsSharedPreferencesKeys.legacySettingsKey);
    return legacy;
  }

  @override
  Future<void> write(String json) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool saved = await prefs.setString(
      AnkiSettingsSharedPreferencesKeys.settingsKey,
      json,
    );
    if (!saved) {
      throw StateError('Failed to persist Anki settings.');
    }
  }
}
