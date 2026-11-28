/// app 的偏好键登记表（架构重构 F1）：各域的 [PrefKeyDef] 在这里汇总成一张
/// [PrefKeyRegistry]。
///
/// Profile 快照（`ProfileKeys.isExcludedPref`）、出境打码（`PrefRedactionPolicy`）、
/// 备份（`settingsPrefPredicate` / `progressPrefPredicate` / 设备本地剔除）、设置同步
/// （`PortableSettingsPolicy`）、同步域的设备本地清单都从这一张表派生，而且只走两个入口：
/// `kFushiPrefRegistry.has(key, trait)`（逐键判定）与 `kFushiPrefRegistry.select(trait)`
/// （同一条性质的枚举形态）——两者出自同一份生效策略。新增一个有特殊归属的键：在它所属
/// 域的登记里加一条声明，不再去各通道的名单里分别登记。
///
/// 各域的 `prefKeyDefs` 只能是纯声明：初始化时不得读本文件的登记表或任何派生名单
/// （那会成环，Dart 在第一次访问时就抛错，任何碰到登记表的测试都会红）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preference_keys.dart'
    show kKnownPreferenceKeys;
import 'package:fushi/src/prefs/app_pref_keys.dart';
import 'package:fushi/src/prefs/non_portable_setting_shape.dart';
import 'package:fushi/src/sync/backup_service.dart'
    show backupContentPrefKeyDefs;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart'
    show kPageBackdropPrefKeyDefs;
import 'package:fushi/src/web_browser/web_browser_prefs.dart'
    show kWebBrowserPrefKeyDefs;

/// app 进程的偏好键登记表。
final PrefKeyRegistry kFushiPrefRegistry = PrefKeyRegistry(
  <PrefKeyDef>[
    ...SyncRepository.prefKeyDefs,
    ...ModuleId.prefKeyDefs,
    ...kWebBrowserPrefKeyDefs,
    ...kPageBackdropPrefKeyDefs,
    ...backupContentPrefKeyDefs,
    ...kAppPrefKeyDefs,
  ],
  shapeRules: const <PrefShapeRule>[
    PrefKeyRegistry.credentialShapeRule,
    kNonPortableSettingShapeRule,
  ],
);

/// [key] 是否是登记过的固定键：登记表里的 [PrefKey]，或还没迁进登记表、只登记了名字的
/// [kKnownPreferenceKeys]（只减不增，见 `preference_keys_guard_test.dart`）。
bool isKnownPreferenceKey(String key) =>
    kFushiPrefRegistry.keyNamed(key) != null ||
    kKnownPreferenceKeys.contains(key);
