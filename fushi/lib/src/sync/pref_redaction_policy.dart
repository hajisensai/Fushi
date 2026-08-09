import 'package:fushi/src/sync/sync_repository.dart';

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
///   `category='pref'` 行原样躺在导出的 `hibiki.db` 里。
///
/// 所以判定必须收敛成一个谓词，由所有出境通道共用。形状兜底不再限定 `sync_`
/// 前缀：一个 key 只要长得像凭据，无论属于哪个子系统都不出境。
///
/// **对称性红线**：导出剔除什么，导入就必须从本机 bak 保留什么。凡是这里返回
/// true 的 key，[BackupService._readDeviceLocalPrefs] 都会用同一谓词从本机捞出
/// 来、在导入后由 `_applyPreservedConfig` 写回去。两侧共用本谓词，是这条对称
/// 契约不再随新增 key 漂移的原因——绝不能一侧改成硬编码清单。
abstract final class PrefRedactionPolicy {
  /// 形状兜底：key 含这些子串即视为凭据，**不限前缀**。
  ///
  /// 已核对全仓 128 个真实 pref key：命中者只有 `yomitan_api_key` /
  /// `jimaku_api_key` / `manga_cloud_ocr_api_key`（外加白名单里的 `sync_*`
  /// 家族），全是真凭据，零误伤。其余同形状字符串都是 i18n 标签
  /// （`settings_secret_hide`、`video_setting_qb_password` 等），永远不落
  /// `preferences` 表，与本谓词无交集。
  static const List<String> credentialSubstrings = <String>[
    'password',
    'token',
    'secret',
    'private_key',
    'credential',
    'api_key',
  ];

  /// 前缀兜底：整族按行 id 展开、无法逐个列举的凭据 key。
  ///
  /// `media_source_secret_<sourceId>` 是网络来源（SFTP/FTP）的登录密码与私钥
  /// PEM，base64 存 `preferences`、与来源行一一对应（见
  /// `SourceLibraryCredentialStore`）。它其实也被 `secret` 子串命中，这里显式列
  /// 出是为了把「整族按 id 展开」这件事写在判定里，而不是靠子串巧合。
  static const List<String> sensitiveKeyPrefixes = <String>[
    'media_source_secret_',
  ];

  /// 名字看不出是凭据、但值里裹着凭据的 key——必须逐个点名。
  ///
  /// 形状兜底对它们无效（`qb_connection_config` 不含任何凭据子串），而它们的值
  /// 确实是明文密码或 API key。新增同类 key 时必须补进这里。
  static const Set<String> sensitiveKeys = <String>{
    // qBittorrent WebUI 连接配置：{host, port, username, password} JSON，密码明文。
    'qb_connection_config',
    // 第三方服务 API key（都被 `api_key` 子串覆盖，显式列出以便审计时一眼看全）。
    'yomitan_api_key',
    'jimaku_api_key',
    'manga_cloud_ocr_api_key',
    'video_scraper_tmdb_api_key',
    'video_metadata_fanart_api_key',
    'video_metadata_bangumi_token',
    'video_metadata_douban_authorized_token',
    // 授权端点可能是私有服务 URL，也可能携带 query credential；它的名字没有
    // token/api_key 形状，必须显式点名，避免备份/Profile 分享时旁路出境。
    'video_metadata_douban_authorized_endpoint',
  };

  /// key 是否属于「设备本地 / 凭据」，即备份、Profile 快照与 Profile 分享 JSON
  /// 三条出境通道都必须剔除、且导入时必须从本机保留的那一类。
  ///
  /// 判定顺序（任一命中即 true）：
  /// 1. [SyncRepository.deviceLocalPrefKeys] 白名单——主防线，同步后端凭据 +
  ///    设备本地配置（device_id / 端口 / 因果基线等）的单一真相源；
  /// 2. [sensitiveKeys] 点名——名字不像凭据但值是凭据的；
  /// 3. [sensitiveKeyPrefixes] 前缀——按行 id 展开的整族凭据；
  /// 4. [credentialSubstrings] 形状兜底——将来新增、还没进前三条的凭据 key 也
  ///    先拦下来（防漏优先于防误伤：漏一个是泄密，误伤一个只是该 key 不跨设备
  ///    跟随，而导入侧的对称保留会把本机值原样留住）。
  static bool isDeviceLocalOrCredential(String key) {
    if (SyncRepository.deviceLocalPrefKeys.contains(key)) return true;
    if (sensitiveKeys.contains(key)) return true;
    final String lower = key.toLowerCase();
    for (final String prefix in sensitiveKeyPrefixes) {
      if (lower.startsWith(prefix)) return true;
    }
    for (final String substring in credentialSubstrings) {
      if (lower.contains(substring)) return true;
    }
    return false;
  }
}
