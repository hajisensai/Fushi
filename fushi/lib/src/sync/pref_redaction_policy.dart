import 'package:fushi_core/fushi_core.dart' show PrefKeyRegistry, PrefPolicy;
import 'package:fushi/src/prefs/fushi_pref_registry.dart';

/// 「一条 `preferences` key 能不能离开本设备」的**唯一真相源**。
///
/// 在此之前这个判定散落在三处、各写各的，而且三处的形状兜底都只对 `sync_`
/// 前缀生效，于是同一个问题在每条出境通道上重复出现：
///
/// 1. [BackupService._stripCredentials]（备份 zip）——白名单 +
///    `key LIKE 'sync_%password%'` 之类的 SQL 兜底；
/// 2. `ProfileRepository._isCredentialOrDeviceLocalPref`（Profile 分享 JSON）
///    ——白名单 + 子串兜底，但 `if (!lower.startsWith('sync_')) return false;`
///    把兜底锁死在 `sync_` 家族里；
/// 3. [ProfileKeys.isExcludedPref]（Profile 快照 `profile_settings`）——**完全
///    没有凭据判定**，只筛 app 状态键。
///
/// 后果是两类真实泄漏：
///
/// - **不以 `sync_` 开头的凭据全员漏网**：`media_source_secret_<id>`（SFTP/FTP
///   密码 + 私钥 PEM，base64 明文）、`qb_connection_config`（qBittorrent WebUI
///   明文密码 JSON）、`yomitan_api_key` / `jimaku_api_key` /
///   `manga_cloud_ocr_api_key` / 视频元数据 provider key 与 token。三处判定
///   一个都拦不住。
/// - **`profile_settings` 是一条无人看守的旁路**：`snapshotCurrentSettings` 把
///   *全部* Drift prefs 逐行复制进快照，而备份导出只 DELETE `preferences`。
///   默认导出类别包含 `profiles`（见 `defaultBackupExportCategories()`），所以
///   只要用户切换过一次 Profile，`preferences` 那份删了也白删——凭据以
///   `category='pref'` 行原样躺在导出的 `fushi.db` 里。
///
/// 所以判定必须收敛成一个谓词，由所有出境通道共用。形状兜底不再限定 `sync_`
/// 前缀：一个 key 只要长得像凭据，无论属于哪个子系统都不出境。
///
/// **对称性红线**：导出剔除什么，导入就必须从本机 bak 保留什么。凡是这里返回
/// true 的 key，[BackupService._readDeviceLocalPrefs] 都会用同一谓词从本机捞出
/// 来、在导入后由 `_applyPreservedConfig` 写回去。两侧共用本谓词，是这条对称
/// 契约不再随新增 key 漂移的原因——绝不能一侧改成硬编码清单。
abstract final class PrefRedactionPolicy {
  /// key 是否属于「设备本地 / 凭据」，即备份、Profile 快照与 Profile 分享 JSON
  /// 三条出境通道都必须剔除、且导入时必须从本机保留的那一类；ctl 读值同样打码。
  ///
  /// 从偏好键登记表派生（[kFushiPrefRegistry]）：声明了 [PrefPolicy.deviceLocal] 或
  /// [PrefPolicy.credential] 的固定键与键族（同步后端凭据、设备本地配置、按 id 展开的设备
  /// 本地状态、名字不像凭据但值是凭据的键、整族凭据 `media_source_secret_<id>`），再叠上
  /// 名字形状兜底（[PrefKeyRegistry.defaultCredentialShapes]：键名含 password / token /
  /// secret / private_key / credential / api_key 即按凭据拦，**不限前缀**）——将来新增、
  /// 还没登记的凭据键也先拦下来（防漏优先于防误伤：漏一个是泄密，误伤一个只是该 key
  /// 不跨设备跟随，而导入侧的对称保留会把本机值原样留住）。名字像凭据的固定键在登记表
  /// 构造期就必须声明成凭据。
  static bool isDeviceLocalOrCredential(String key) =>
      kFushiPrefRegistry.policyOf(key).redacted;
}
