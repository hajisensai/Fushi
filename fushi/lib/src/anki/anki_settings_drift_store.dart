/// Anki 制卡设置的 Drift 存储与「SharedPreferences → Drift」一次性迁移
/// （反馈 fiwDIpFep7：主 app 改了牌组，应用外查词制卡仍用旧牌组）。
///
/// 根因：设置原先整份存在 SharedPreferences，SP 插件在每个进程 / isolate 里各
/// 缓存一份。Android 的 `:popup` 是独立进程、悬浮词典是同进程另一个 engine，
/// 两者初始化后一直读自己那份旧缓存。Drift `preferences` 表是三个入口共用的同一个
/// 库文件：这里**每次读都直查单行**（不走 [PreferencesRepository] 的进程内缓存），
/// 写经 [FushiDatabase.setPref]（同事务递增跨进程 `prefs_version`），于是任何
/// entry point 下一次 [BaseAnkiRepository.loadSettings] 都拿到最新值。
library;

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drift 实现：值以 [PrefCodec] 字符串形态存在 [kAnkiSettingsPrefKey] 一行里。
class DriftAnkiSettingsStore implements AnkiSettingsStore {
  /// [database] 每次读写时求值：库被替换（数据根迁移 / 恢复后重开）也跟得上。
  DriftAnkiSettingsStore(this._database);

  final FushiDatabase Function() _database;

  @override
  Future<String?> read() async {
    final String? raw = await _database().getPref(kAnkiSettingsPrefKey);
    if (raw == null) return null;
    return PrefCodec.decode<String?>(raw, null);
  }

  @override
  Future<void> write(String json) =>
      _database().setPref(kAnkiSettingsPrefKey, PrefCodec.encode(json));
}

/// 把 [database] 装成本 isolate 的 Anki 设置存储，并做一次性迁移。
///
/// 每个打开 Drift 库的 entry point（主 app `initialise` / `:popup` 与悬浮词典的
/// `initialiseForDictionaryPopup`）都调用，且必须早于任何 `loadSettings`。
Future<void> installDriftAnkiSettingsStore(
  FushiDatabase Function() database,
) async {
  await migrateAnkiSettingsFromSharedPreferences(database());
  BaseAnkiRepository.defaultSettingsStore = DriftAnkiSettingsStore(database);
}

/// SP 旧值 → Drift 的一次性迁移。返回是否真的写入了。
///
/// - **Drift 已有该行就跳过**，不读也不碰 SP（常态启动只多一次单行查询）。
/// - 否则读 SP 现存值（新键优先、Hibiki 旧键兜底，**只读不写**），用
///   [FushiDatabase.insertPrefIfAbsent] 写入：单条 `INSERT OR IGNORE`，主进程与
///   `:popup` 首启并发时只有一方落地、另一方无副作用，连跑多次幂等。
/// - **绝不删除 SP 旧键**：`:popup` 进程里改 SP 会在 Android 上整文件写回、
///   覆盖主进程的值；主进程保留它则是给降级回旧版本留的退路（旧版本仍只认 SP）。
///   代价是 SP 里留一份不再更新的旧串，新版本不再读它（Drift 有行即跳过）。
/// - 载入期的内容迁移（别名改写、MiscInfo 升级、空映射补默认）不在这里做，照旧
///   由 [BaseAnkiRepository.readSettingsJson] / `AnkiSettings.fromJson` 在新存储
///   上读时完成。
Future<bool> migrateAnkiSettingsFromSharedPreferences(
  FushiDatabase database,
) async {
  if (await database.getPref(kAnkiSettingsPrefKey) != null) return false;
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? legacy = AnkiSettingsSharedPreferencesKeys.readLegacyJson(
    prefs,
  );
  if (legacy == null) return false;
  return database.insertPrefIfAbsent(
    kAnkiSettingsPrefKey,
    PrefCodec.encode(legacy),
  );
}
