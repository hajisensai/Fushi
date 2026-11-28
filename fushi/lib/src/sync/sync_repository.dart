import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:fushi/src/models/library_grid_columns.dart'
    show kLibraryGridColumnsPrefKey;
import 'package:fushi/src/models/preference_keys.dart'
    show
        kAnkiSettingsPrefKey,
        kOnlineLibraryLedgerPrefKey,
        kWhatsNewCardDismissedVersionPrefKey,
        kWhatsNewSeenSeqPrefKey,
        kWhatsNewSeenVersionPrefKey,
        kWorkProfileSessionPrefKey;
import 'package:fushi/src/prefs/fushi_pref_registry.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellLayoutInstallDefault;
import 'package:fushi/src/models/preferences_repository.dart'
    show
        kDownloadExecutionHostPrefKey,
        kFloatingLyricWindowRectPrefKey,
        kGameStreamButtonProfilePrefKey,
        kGameStreamLookupLayoutPrefKey,
        kGameStreamRemoteLaunchPrefKey,
        kGameStreamSecondScreenPrefKey,
        PreferencesRepository;
import 'package:fushi_engine/media/torrent/bt_site_legacy_migration.dart'
    show kBtSitesLegacyMigrationPref;
import 'package:fushi_engine/media/identity/pending_identity.dart'
    show kBookScrapeIgnoredPrefKey, kGameScrapeIgnoredPrefKey;
import 'package:fushi_engine/media/video/metadata/video_scrape_ignored_works.dart'
    show kVideoScrapeIgnoredWorksPrefKey;
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_registry.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig, JellyfinVideoClient;
import 'package:fushi/src/sync/remote_video_list_store.dart'
    show RemoteVideoListStore;
import 'package:fushi/src/sync/remote_audiobook_revision.dart'
    show kInterconnectAudiobookRevisionsPrefKey;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show applyIssuedInterconnectToken, InterconnectAddressOwnerConflict;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart'
    show decodeInterconnectPublicUrls, kInterconnectPublicUrlsPref;
import 'package:fushi_engine/sync/interconnect_owner_devices.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart'
    show
        kInterconnectP2pEnabledPref,
        kInterconnectP2pRelayUrlsPref,
        kInterconnectP2pSecretPref;
import 'package:fushi_engine/sync/ai_relay_routes.dart'
    show kInterconnectAiRelayEnabledPref;
import 'package:fushi_engine/sync/interconnect_transcode_prefs.dart';
import 'package:fushi_engine/sync/pairing/interconnect_device_key.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:fushi_engine/sync/collection_sync_baseline.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart'
    show kSyncWebHistoryPrefKey, readWebHistorySyncEnabled;
export 'package:fushi_engine/sync/sync_channel_scope.dart'
    show SyncChannelScope;

/// 触达一台 Fushi 同步服务器的一个候选地址。
///
/// 同一台服务器通常可经多条路由触达（局域网、外网），按列表顺序尝试、第一个
/// 可达者胜出。
///
/// BUG-1550：凭据的基数必须与地址的基数一致。host 侧 per-peer token（TODO-961
/// M1b）按 `clientDeviceId` 逐台派发，而列表里的地址可能属于**不同的 host**
/// （LAN 发现里点谁配谁，每次都往同一个列表 append）。凭据若只有一个全局槽，
/// 配对第二台就会把第一台的 token 覆盖掉——之后第一台地址排在前面、依然可达、
/// 却用着第二台的 token → 401。故 token 落在**地址行上**，[token] 为空的行
/// （老配置 / 手动加的同 host 备用地址）回落到全局键，行为与升级前逐字一致。
class FushiClientUrl {
  const FushiClientUrl({
    required this.url,
    this.enabled = true,
    this.fingerprintSha256,
    this.deviceName,
    this.token,
    this.hostId,
    this.learned = false,
    this.addressKind,
    this.lookupEnabled = true,
  });

  final String url;
  final bool enabled;

  /// https 端点的证书 SHA-256 指纹钉扎值（aa:bb:.. 形式）。null = 明文 http
  /// 老路径不钉扎（向后兼容）；非 null = https 路径，client 用它做指纹钉扎。
  /// M0 仅落地字段，钉扎接线在 M1。
  final String? fingerprintSha256;

  /// 对端展示名（M0 仅落地，UI/配对在 M1 使用）。
  final String? deviceName;

  /// 本地址专属的访问凭据（BUG-1550）。配对成功时写在这里；null/空 = 老配置或
  /// 同 host 的备用地址，回落全局 `sync_hibiki_client_token`。
  ///
  /// 该字段随 `sync_hibiki_client_urls` 落库，而该键已在
  /// [SyncRepository.deviceLocalPrefKeys] 的设备本地清单里，故不会随备份/同步
  /// 携带出设备（与全局 token 键同待遇）。
  final String? token;

  /// 这条地址属于哪台 host（host 的稳定设备 id，来自 `/api/ping` 与
  /// `/api/host/addresses` 回报的 `hostId`）。同 hostId 的多条地址是**同一台机器**的不同路径（LAN / IPv6 /
  /// 组网 / 公网 / P2P），选路时组内并发、列设备时合并为一台。null = 老条目或
  /// 老 host，单独成组，行为与升级前逐字一致
  /// （docs/specs/2026-09-28-interconnect-remote-reach.md §1）。
  final String? hostId;

  /// 由 host 公布的地址集自动学到（而非用户手输）。只有 learned 条目会被后续
  /// 刷新自动增删；手输条目永不被自动改动。
  final bool learned;

  /// learned 条目由 host 标注的地址种类（`InterconnectAddressKind.name`）。组网
  /// 网卡上的私网段（ZeroTier 10.x、Tailscale fd7a::）单看 URL 会被当成局域网，
  /// 排序要用 host 的原始判断。手输条目为 null（按 URL 推断）。
  final String? addressKind;

  /// 「用这台服务器查词典」（按配对 / host 的设备本地开关，默认 true = 与升级前一致）。
  /// false 时远端查词与服务器词典目录刷新都跳过这条地址（[isDictionaryLookupCandidate]），
  /// 同步 / 制卡 / 音频等其它互联用途不受影响。随 `sync_hibiki_client_urls` 落库，与
  /// [token] 同为设备本地。同一台 host 的多条地址由设置页一起改。
  final bool lookupEnabled;

  /// 这条地址此刻能否承担远端**词典**查词：已启用且没关掉 [lookupEnabled]。
  bool get isDictionaryLookupCandidate => enabled && lookupEnabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'enabled': enabled,
    if (fingerprintSha256 != null) 'fingerprintSha256': fingerprintSha256,
    if (deviceName != null) 'deviceName': deviceName,
    if (token != null && token!.isNotEmpty) 'token': token,
    if (hostId != null) 'hostId': hostId,
    if (learned) 'learned': true,
    if (addressKind != null) 'kind': addressKind,
    // 只记非默认值：默认开着的老条目写回后逐字节不变。
    if (!lookupEnabled) 'lookupEnabled': false,
  };

  factory FushiClientUrl.fromJson(Map<String, dynamic> json) => FushiClientUrl(
    url: json['url'] as String,
    enabled: json['enabled'] as bool? ?? true,
    fingerprintSha256: json['fingerprintSha256'] as String?,
    deviceName: json['deviceName'] as String?,
    token: json['token'] as String?,
    hostId: json['hostId'] as String?,
    learned: json['learned'] as bool? ?? false,
    addressKind: json['kind'] as String?,
    lookupEnabled: json['lookupEnabled'] as bool? ?? true,
  );

  /// 复制并覆盖部分字段（不可变更新）。`null` 入参保留原值；要显式清空请直接构造。
  FushiClientUrl copyWith({
    String? url,
    bool? enabled,
    String? fingerprintSha256,
    String? deviceName,
    String? token,
    String? hostId,
    bool? learned,
    String? addressKind,
    bool? lookupEnabled,
  }) => FushiClientUrl(
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
    fingerprintSha256: fingerprintSha256 ?? this.fingerprintSha256,
    deviceName: deviceName ?? this.deviceName,
    token: token ?? this.token,
    hostId: hostId ?? this.hostId,
    learned: learned ?? this.learned,
    addressKind: addressKind ?? this.addressKind,
    lookupEnabled: lookupEnabled ?? this.lookupEnabled,
  );
}

/// 服务器托管词典（`remote_dictionary_metadata`）按哪个 host 身份归档：配对记下的
/// [FushiClientUrl.hostId]；老条目没有 hostId 时用地址本身（去掉首尾空白与结尾 `/`）
/// 充当伪 id——与 `InterconnectSyncBackend.connectedHostIdentity` 对老条目的口径一致，
/// 同步编排的词典阶段拿到的身份与这里算出的能对上。
String remoteDictionaryHostIdOf(FushiClientUrl candidate) {
  final String? hostId = candidate.hostId;
  if (hostId != null && hostId.isNotEmpty) return hostId;
  final String url = candidate.url.trim();
  return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}

/// [remoteDictionaryHostIdOf] 给出的是不是**地址充当的伪 id**（老条目没有 hostId，
/// 拿 URL 顶上）。伪 id 是服务器地址，配置导出时必须剔掉（不把用户的服务器地址带出
/// 本机）；真 hostId 是不透明的设备 id，照常导出。
bool isRemoteDictionaryPseudoHostId(String hostId) => hostId.contains('://');

/// 「用这台服务器查词典」是按 host 的设置：一台 host 原有的地址全都关掉了它时，
/// 这次写入里**新加入**这台 host 的地址（新 URL，或原有 URL 新归到这台 host）也跟着
/// 关掉——否则配对学到一条新地址 / 手动加一条地址后，用户关掉的 host 会悄悄重新
/// 参与查词。原有地址的值（含用户刚在设置页整组打开）一律不动。没有任何变化时原样
/// 返回 [after]（调用方靠 `identical` 判断要不要落库）。
List<FushiClientUrl> inheritInterconnectLookupDisabled(
  List<FushiClientUrl> before,
  List<FushiClientUrl> after,
) {
  final Map<String, bool> allOffByHost = <String, bool>{};
  final Set<String> knownMembership = <String>{};
  for (final FushiClientUrl u in before) {
    final String host = remoteDictionaryHostIdOf(u);
    allOffByHost[host] = (allOffByHost[host] ?? true) && !u.lookupEnabled;
    knownMembership.add('$host\u0000${u.url}');
  }
  if (!allOffByHost.containsValue(true)) return after;
  bool changed = false;
  final List<FushiClientUrl> out = <FushiClientUrl>[
    for (final FushiClientUrl u in after)
      if (u.lookupEnabled &&
          allOffByHost[remoteDictionaryHostIdOf(u)] == true &&
          !knownMembership.contains(
            '${remoteDictionaryHostIdOf(u)}\u0000${u.url}',
          ))
        () {
          changed = true;
          return u.copyWith(lookupEnabled: false);
        }()
      else
        u,
  ];
  return changed ? out : after;
}

/// [urls] 里此刻承担远端词典查词的 host 身份集合（[FushiClientUrl.isDictionaryLookupCandidate]
/// 的地址按 [remoteDictionaryHostIdOf] 归组）。词典仓库只把这些 host 的目录行混进查词过滤。
Set<String> remoteDictionaryLookupHostIdsOf(Iterable<FushiClientUrl> urls) =>
    <String>{
      for (final FushiClientUrl u in urls)
        if (u.isDictionaryLookupCandidate) remoteDictionaryHostIdOf(u),
    };

/// BUG-1550：解析某个候选地址该用哪份凭据——地址行自带的 [FushiClientUrl.token]
/// 优先，为空时回落全局 token（老配置 / 同 host 的备用地址）。两者都空返回 null，
/// 调用方按「未配置凭据」处理。
///
/// 抽成顶层函数而非 [SyncRepository] 方法：全部消费方（sync backend / POST 传输层 /
/// 漫画 OCR client）都已经各自把候选列表与全局 token 读在手上，这里只做纯选择，
/// 不再多打一次库。
String? interconnectTokenFor(FushiClientUrl candidate, String? fallbackToken) {
  final String? own = candidate.token;
  if (own != null && own.isNotEmpty) return own;
  if (fallbackToken != null && fallbackToken.isNotEmpty) return fallbackToken;
  return null;
}

/// TODO-961 M1：当一个已记录非空指纹的 https 候选地址再次出现、但带来的新指纹与
/// 已存指纹不符时抛出（疑似 MITM 或 host 重置了证书）。**绝不静默覆盖已存指纹**——
/// 由调用方告警并要求用户显式重置该条目，这是 TOFU 钉扎的硬约束（设计稿 §3.5）。
class FushiFingerprintMismatchException implements Exception {
  const FushiFingerprintMismatchException({
    required this.url,
    required this.storedFingerprint,
    required this.incomingFingerprint,
  });

  final String url;
  final String storedFingerprint;
  final String incomingFingerprint;

  @override
  String toString() =>
      'FushiFingerprintMismatchException($url: stored=$storedFingerprint '
      'incoming=$incomingFingerprint)';
}

/// 设备级「同步设置」开关的 pref key（见 [SyncRepository.isSettingsSyncEnabled]）。
const String kSyncSettingsEnabledPrefKey = 'sync_settings_enabled';

/// 合并导入备份时是否也并入可移植设置（反馈 AWp-0BtDDv，见
/// [SyncRepository.isBackupMergeSettingsEnabled]）。
const String kBackupMergeSettingsPrefKey = 'backup_merge_import_settings';

/// 同步配置和缓存的持久化层（基于 Preferences 表）。
///
/// 桌面 OAuth 凭据（refresh token, client secret）存储在用户级 SQLite 数据库中，
/// 采用 base64 编码。安全模型与 gcloud/aws-cli 等桌面 CLI 工具一致：
/// 依赖操作系统文件权限保护用户数据目录。
class SyncRepository {
  SyncRepository(this._db);
  final FushiDatabase _db;

  static const _keyRootFolderId = 'sync_root_folder_id';
  static const _keyFolderCache = 'sync_folder_cache';
  // 云盘旧名 `<title>.epub` 内容资产的内容判型缓存（JSON：资产 id → {folder,
  // revision, size, kind}，见 `CloudLegacyMangaSniffer`）。按通道分槽；设备本地
  // （[_perChannelDeviceLocalBases]）：它是本机对远端字节的观测缓存，不是用户设置，
  // 不进导出。条目按后端内容版本标记校验，带到别处也不会给出错的结论。
  static const _keyContentSniffCache = 'sync_content_sniff_cache';
  static const _keySyncStats = 'sync_stats_enabled';
  static const _keySyncAudioBook = 'sync_audiobook_enabled';
  // 废弃：词典与本地音频源数据库不再有「同步开关」，改成设置页的显式上传 / 下载
  // 动作（见 `SyncOrchestrator.runAssetTransferOnly`）。存量库里的这两行不做 schema
  // 迁移（要冒着改动已发布版本的风险），但**必须还读一次**：升级前开着自动同步的
  // 用户，升级后同步会静默停下——「立即同步」照常报「完成 N 项」，而新导入的词典
  // 再也不上云。用户没有任何信号知道备份里已经没有词典了。这不是数据丢失，是
  // 「我以为还在备份」的静默失效，正是 never break userspace 要挡的东西。所以留一条
  // 一次性告知（见 sync_settings_schema 的 sync.asset_legacy_notice），读到 true 就
  // 在同步设置页说明改动，用户确认后写 false 关掉，此后这两个键才真正是死数据。
  static const _keyLegacySyncDictionary = 'sync_dictionary_enabled';
  static const _keyLegacySyncLocalAudio = 'sync_local_audio_enabled';
  static const _keySyncAudioBookFiles = 'sync_audiobook_files_enabled';
  static const _keySyncVideoFiles = 'sync_video_files_enabled';
  static const _keyAutoSync = 'sync_auto_enabled';
  // 互联通道专属的自动同步开关（反馈 5nWEirdCs2）；迁移规则见
  // [isInterconnectAutoSyncEnabled]。与 [_keyAutoSync] 同为行为开关，随备份恢复。
  static const _keyInterconnectAutoSync = 'interconnect_sync_auto';
  // 复习（SRS）数据的自动同步开关（反馈 VNz9dsLeIy，默认开）；见 [isSrsAutoSyncEnabled]。
  // 行为开关，随备份恢复（与上面两个自动同步开关同类）。
  static const _keySrsAutoSync = 'srs_sync_auto';
  static const _keyLastSyncMs = 'sync_last_sync_ms';
  static const _keyCollectionsBaselineMs = 'sync_collections_baseline_ms';
  // 删除墓碑消费的因果基线：描述「本设备见过远端删除标记到什么时刻」。远端墓碑
  // deletedAt 晚于它才是「新闻」（弹逐条确认），早于它视为本设备已处理过、不再反复弹。
  // 设备本地（[deviceLocalPrefKeys]）：随备份跨设备会让新设备把老墓碑误判为新闻反复弹。
  static const _keyDeletionTombstonesBaselineMs =
      'sync_deletion_tombstones_baseline_ms';
  // 7c 视频刮削元数据增量拉取基线：本设备从该通道见过的最大 host updatedAt。
  // 设备本地：随备份到新设备会让它以为已见过、永远不全量拉。
  static const _keyVideoMetadataSyncSinceMs = 'sync_video_metadata_since_ms';
  // 流媒体书拉取基线（拍板台 Z2OhxAjKVv）：本设备从该通道见过的最大 host 拥有时刻。
  // 晚于它的 host 流媒体书才落到本机——早于它、本机却没有的，是本机删掉的，不再建回。
  // 设备本地：随备份到新设备会让它以为已见过、永远拉不到。
  static const _keyStreamVideoPullSinceMs = 'sync_stream_video_pull_since_ms';
  // 删除墓碑**推送**的因果基线（互联通道专用，与上面的消费基线镜像对称）：描述
  // 「本设备已把删除推给对端 host 到什么时刻」。deletedAt 晚于它的墓碑才需要推。
  // 为什么不复用墓碑行上的 `remotePublishedAt`：那个字段的语义是「已写进云端
  // `__tombstones__` 资产」。互联推送去标它，会让同时配了云备份的设备在云通道
  // `syncDeletionTombstones` 的 `remotePublishedAt == 0` 过滤里永远跳过这条——只连
  // 云的第三台设备就再也收不到这次删除了。两个通道各记各的账。
  // 设备本地（[deviceLocalPrefKeys]）：随备份跨设备会让新设备以为自己已经推过一批
  // 它从没连过的 host。
  static const _keyDeletionTombstonesPushBaselineMs =
      'sync_deletion_tombstones_push_baseline_ms';
  static const _keyDesktopCredentials = 'sync_desktop_credentials';
  static const _keyBackendType = 'sync_backend_type';
  // 云备份通道总开关（默认开），与互联总开关 [_keyInterconnectEnabled] 对称；见
  // [isCloudSyncEnabled]。设备本地（[deviceLocalPrefKeys]），理由见清单处注释。
  static const _keyCloudSyncEnabled = 'sync_cloud_enabled';
  // 「与 Hoshi/ッツ 共享」开关：开启后 Google Drive 后端改用可见 My Drive /
  // ttu-reader-data + 完整 drive scope（[GoogleDriveSyncSpace]）。属设备本地（改的是
  // 本机 Drive 存储空间/scope），不随备份导入覆盖。
  static const _keySyncContent = 'sync_content_enabled';
  // 「上传漫画文件」（所有者 2026-10-21：书籍和漫画分开）。从未设置过时继承同通道
  // 「上传书籍文件」的当前值，升级后行为不变；设置过就按自己的值。
  static const _keySyncMangaContent = 'sync_manga_content_enabled';
  // BUG-988：互联通道专属的「上传内容到互联对端」开关，独立于云备份的
  // sync_*_enabled（那套只管云通道）。互联解耦(PR#223)后互联通道曾复用云备份的
  // 共享开关，用户失去「只对互联单独控制上不上传」的能力；这几个键把互联通道的内容
  // 上传拆出来单独控制。默认 false（用户显式 opt-in，不被「启用互联连接」裹挟着自动传）。
  // 词典原本也有一个（`interconnect_sync_dictionary`），BUG-2762 删掉了：互联词典只由
  // 设置页的显式上传 / 下载动作搬，库里残留的旧行不再有读取方。
  static const _keyInterconnectSyncContent = 'interconnect_sync_content';
  // 互联通道的「上传漫画文件」，继承规则同 [_keySyncMangaContent]（继承的是
  // [_keyInterconnectSyncContent]）。
  static const _keyInterconnectSyncMangaContent =
      'interconnect_sync_manga_content';
  static const _keyInterconnectSyncAudioBookFiles =
      'interconnect_sync_audiobook_files';
  static const _keyInterconnectSyncVideoFiles = 'interconnect_sync_video_files';
  // 互联「配置文件」（Profile）双向搬运的 **host 侧**开关：允许已配对设备读取 /
  // 写入本机配置。默认 false —— 入站写没有显式开关就是「无 UI 的隐形通道」
  // （BUG-988 立过的规矩），出站也一样：整份 Profile 比四个内容上传开关更敏感。
  static const _keyInterconnectProfileTransfer =
      'interconnect_profile_transfer';
  // 「允许已配对设备自动登录我的 Fushi 账户」的 **host 侧**开关（所有者 2026-10-16 拍板：
  // 默认开——已配对本身就是信任凭据）。关掉时 `/api/interconnect/leaderboard-link` 403。
  // 对端只交来它自己的公钥，本机私钥 / 恢复码从不外传。
  static const _keyInterconnectLeaderboardLinkHost =
      'interconnect_leaderboard_link_host';
  // **client 侧**开关「跟随已配对设备自动登录」（默认开）：本机没有 Fushi 账户、且连上已
  // 登录账户的已配对 host 时，后台自动把本机新生成的设备钥匙挂到同一账户。
  static const _keyLeaderboardFollowPairedLogin =
      'leaderboard_follow_paired_login';
  // host 侧「我的设备」标记（所有者 2026-10-16 拍板）与配对时验签通过的设备公钥指纹：
  // 键名与格式见引擎 `interconnect_owner_devices.dart`（[kInterconnectOwnerDevicePeersPref] /
  // [kInterconnectPeerDeviceKeysPref]，与无头服务端共用）。被标记的已配对 peer 才能跟随本机
  // 账户自动登录；升级前配对过的 peer 不在集合里 = 「仅互联」，不追溯授权。设备本地。
  // client 侧：本机互联设备私钥（base64url P-256 标量）。配对时签 host 下发的会话
  // nonce，证明「这个 deviceId 真是我」。设备本地 + 名字命中凭据红线（`private_key`），
  // 不进备份 / Profile 快照 / 导出；私钥外带 = 两台设备共用一个身份。
  static const _keyInterconnectDevicePrivateKey =
      'sync_interconnect_device_private_key';
  // 互联「远程更新本机」的 **host 侧**开关（反馈 Pp8XPyve0N）：允许已配对设备查看并
  // 触发本机 app 更新。默认 false —— 让别的设备在本机下载安装可执行文件，必须是主机
  // 主人的显式意愿（Never break userspace：升级后什么都不会自己发生）。
  static const _keyInterconnectRemoteUpdate = 'interconnect_remote_update';
  // 互联通道专属的「共享统计 / 共享收藏夹」开关。此前互联的聚合同步（统计 + 收藏
  // 词句）无条件复用云备份的 sync_stats_enabled，用户在互联页既看不到这两类数据
  // 正在跨设备流动，也没法只对互联单独关掉——与 BUG-988 拆四个上传开关时修掉的
  // 是同一个毛病（互联通道借用云备份开关 = 用户失去分通道控制权）。
  // 缺键时**继承旧键 sync_stats_enabled 的当前值**（不是硬编码 true）：旧键是个
  // 用户可见开关，把它关掉的存量用户升级后绝不能被默认值静默复位成「又在同步」。
  // 只有用户真的动过互联这两个新开关（新键有行）时才用新值。
  static const _keyInterconnectSyncStats = 'interconnect_sync_stats';
  static const _keyInterconnectSyncFavorites = 'interconnect_sync_favorites';
  // apikey 同步设定重设计（2026-08-17）：互联 service-config（host 的外部服务
  // API key / 服务配置，interconnect_service_config.dart 白名单）此前是**无 UI、
  // 无开关**的隐形通道——用户既看不见「配对后 host 的 Jimaku/TMDB key 会同步过来」
  // 这件事，也关不掉它。默认 true 保持既有行为（TLS 开着的互联用户无感知），
  // 开关落设备本地（要不要接收 host 凭据是每台设备自己的信任决策，不跨设备跟随）。
  static const _keyInterconnectServiceConfigSync =
      'interconnect_sync_service_config';
  // 互联「来源共享」（拍板台 wOMR4_Er7s，interconnect_source_share_sync.dart）：
  // client 侧「接收 host 共享的服务器来源与插件」、host 侧「把来源共享给我的设备」。
  // 都默认开（维护者要的是自动共享；凭据只发给 host 主人标过「我的设备」的 peer，
  // 端点另有 HTTPS + per-peer token 两道门）。都落设备本地：要不要收 / 发凭据是每台
  // 设备自己的信任决策。
  static const _keyInterconnectSourceShareSync =
      'interconnect_sync_source_share';
  static const _keyInterconnectSourceShareHost =
      'interconnect_source_share_host';
  // host 主人逐项勾选共享的来源（`kind/id` 的 JSON 数组）。拍板台原文「凭据由用户逐项
  // 勾选，不能默认全量下发」：默认空 = 一条都不共享。
  static const _keyInterconnectSourceShareHostItems =
      'interconnect_source_share_host_items';
  // client 侧「也接收插件」：插件是第三方可执行代码，host 是谁标的「我的设备」是 host 单方面
  // 的判断，往本机装代码必须这台设备的主人自己点头。默认关。
  static const _keyInterconnectSourceSharePlugins =
      'interconnect_sync_source_share_plugins';
  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = 'sync_webdav_password';

  static const String syncStatsPreferenceKey = _keySyncStats;
  static const String syncAudioBookPreferenceKey = _keySyncAudioBook;

  // ── Folder cache（按通道分槽，BUG-1576） ───────────────────────────
  // 根 folderId 与「书名→folderId」映射描述的是**某一个远端**的目录布局，绝不是
  // 设备的属性。双通道并存后共用一份全局键 = 后写者覆盖先写者，而互联/WebDAV 的
  // folderId 是绝对 URL，被另一条通道读回后会连同自己的凭据发往对端主机
  // （webdav_ops 的 buildRequest 对绝对 URL 直接 open + 附 Authorization）。
  // 故读写一律带 [SyncChannelScope]。

  Future<String?> getRootFolderId(SyncChannelScope scope) async {
    final row =
        await (_db.select(_db.preferences)
              ..where((t) => t.key.equals(scope.key(_keyRootFolderId))))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> setRootFolderId(SyncChannelScope scope, String? id) async {
    final String key = scope.key(_keyRootFolderId);
    if (id == null) {
      await (_db.delete(_db.preferences)..where((t) => t.key.equals(key))).go();
      return;
    }
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(key: key, value: id),
        );
  }

  Future<Map<String, String>> getFolderCache(SyncChannelScope scope) async {
    final row =
        await (_db.select(_db.preferences)
              ..where((t) => t.key.equals(scope.key(_keyFolderCache))))
            .getSingleOrNull();
    if (row == null) return {};
    return Map<String, String>.from(
      jsonDecode(row.value) as Map<String, dynamic>,
    );
  }

  Future<void> setFolderCache(
    SyncChannelScope scope,
    Map<String, String> cache,
  ) async {
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            key: scope.key(_keyFolderCache),
            value: jsonEncode(cache),
          ),
        );
  }

  /// [scope] 通道的云盘内容判型缓存（`CloudLegacyMangaSniffer`）；没有或损坏返回空表。
  Future<Map<String, Object?>> getContentSniffCache(
    SyncChannelScope scope,
  ) async {
    final row =
        await (_db.select(_db.preferences)
              ..where((t) => t.key.equals(scope.key(_keyContentSniffCache))))
            .getSingleOrNull();
    if (row == null) return <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(row.value);
    } on FormatException {
      // 缓存行坏了就当没有缓存：最坏是重新嗅探一遍，不影响任何用户数据。
      return <String, Object?>{};
    }
    return decoded is Map<String, dynamic>
        ? Map<String, Object?>.of(decoded)
        : <String, Object?>{};
  }

  Future<void> setContentSniffCache(
    SyncChannelScope scope,
    Map<String, Object?> entries,
  ) async {
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            key: scope.key(_keyContentSniffCache),
            value: jsonEncode(entries),
          ),
        );
  }

  Future<void> clearFolderCache(SyncChannelScope scope) async {
    await (_db.delete(_db.preferences)..where(
          (t) => t.key.isIn(<String>[
            scope.key(_keyRootFolderId),
            scope.key(_keyFolderCache),
          ]),
        ))
        .go();
  }

  /// 清掉**所有**通道的 folder 缓存（含解耦前的旧全局键）。
  ///
  /// 备份导入用：导入库里带的是**备份来源机**的目录布局，对本机保留下来的后端账号
  /// 全部无效，一条通道都不能留。键目录由 [SyncChannelScope.all] 展开，新增后端
  /// 自动被覆盖。
  Future<void> clearAllFolderCaches() async {
    final List<String> keys = <String>[
      _keyRootFolderId,
      _keyFolderCache,
      for (final SyncChannelScope scope in SyncChannelScope.all) ...<String>[
        scope.key(_keyRootFolderId),
        scope.key(_keyFolderCache),
      ],
    ];
    await (_db.delete(_db.preferences)..where((t) => t.key.isIn(keys))).go();
  }

  /// 一次性清理解耦前的**全局** folder 缓存键（BUG-1576 迁移）。
  ///
  /// 迁移语义是**丢弃而不是搬运**：这两个键的值此刻已经无法归因到任何一条通道
  /// （双通道 sweep 里谁最后写的就是谁的，正是本 bug 的成因），把它搬进任何一个
  /// 槽位都等于把污染固化下来。而它本身是**纯缓存**：根目录由
  /// `findOrCreateRootFolder` 按名查找/创建、书文件夹由 `ensureBookFolder` 按名
  /// 解析，丢了只是下一轮同步多几次目录解析，不丢任何用户数据（切后端时本来就
  /// 会 [clearFolderCache]，见 `applyBackupBackendChange`）。
  ///
  /// 幂等：键已不存在时是 no-op。
  Future<void> migrateFolderCacheToPerChannel() async {
    await (_db.delete(_db.preferences)..where(
          (t) => t.key.isIn(<String>[_keyRootFolderId, _keyFolderCache]),
        ))
        .go();
  }

  // ── Sync settings ─────────────────────────────────────────────────

  /// 升级前这台设备是否开着词典 / 本地音频的自动同步（任一为真即算）。
  /// 只被那条一次性告知读；确认后经 [acknowledgeLegacyAssetAutoSync] 归零。
  Future<bool> hadLegacyAssetAutoSync() async =>
      await _db.getPrefTyped<bool>(_keyLegacySyncDictionary, false) ||
      await _db.getPrefTyped<bool>(_keyLegacySyncLocalAudio, false);

  /// 用户已看过告知：把两个废弃键写 false，提示不再出现。
  /// 写 false 而不是删行——`Preferences` 没有删除接口，写值不需要动已发布 schema。
  Future<void> acknowledgeLegacyAssetAutoSync() async {
    await _db.setPrefTyped<bool>(_keyLegacySyncDictionary, false);
    await _db.setPrefTyped<bool>(_keyLegacySyncLocalAudio, false);
  }

  Future<bool> isSyncStatsEnabled() =>
      _db.getPrefTyped<bool>(_keySyncStats, true);
  Future<void> setSyncStatsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncStats, v);

  Future<bool> isSyncAudioBookEnabled() async => true;
  Future<void> setSyncAudioBookEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncAudioBook, true);

  /// 是否同步有声书文件（音频 + 字幕包）。默认 false：包大，需用户显式开启。
  Future<bool> isSyncAudioBookFilesEnabled() =>
      _db.getPrefTyped<bool>(_keySyncAudioBookFiles, false);
  Future<void> setSyncAudioBookFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncAudioBookFiles, v);

  /// 是否上传本地视频文件到云 `__videos__/` 命名空间（多端库联合视图 §2.6）。
  /// 默认 false：视频体积 / 流量大，须用户显式 opt-in。与 syncAudioBookFiles 同为
  /// 行为开关，不进 [deviceLocalPrefKeys]（当作用户设置，随备份跨设备恢复）。
  Future<bool> isSyncVideoFilesEnabled() =>
      _db.getPrefTyped<bool>(_keySyncVideoFiles, false);
  Future<void> setSyncVideoFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncVideoFiles, v);

  /// **云同步通道**的自动同步开关（默认关：云盘流量 / 配额由用户显式 opt-in）。
  ///
  /// 反馈 5nWEirdCs2 起它只管云通道；互联通道读自己的
  /// [isInterconnectAutoSyncEnabled]。
  Future<bool> isAutoSyncEnabled() =>
      _db.getPrefTyped<bool>(_keyAutoSync, false);

  /// 写云通道开关前先把互联开关落成显式值（[isInterconnectAutoSyncEnabled] 的
  /// 一次性迁移）：否则一个从没碰过两个开关的用户此刻关掉云同步，互联开关的「继承
  /// 旧值」判据就会把这次写入当成历史意愿，把互联也跟着关掉——两个开关从此不再独立。
  Future<void> setAutoSyncEnabled(bool v) async {
    await isInterconnectAutoSyncEnabled();
    await _db.setPrefTyped<bool>(_keyAutoSync, v);
  }

  /// **互联通道**的自动同步开关（反馈 5nWEirdCs2）。默认开：互联页向用户承诺统计 /
  /// 收藏「与已配对设备双向合并、默认开启」，而合并只发生在同步轮次里；互联通道的
  /// 重内容上传开关又全默认关，自动轮次只搬进度、统计、收藏、合集这类轻量数据。
  ///
  /// 迁移（只迁一次，读即落盘）：本键缺行时按旧的全局开关 [_keyAutoSync]
  /// （拆开关前它同时管两条通道）**是否存在**决定——
  /// - 旧键缺行 = 用户从没动过自动同步 → 取新默认 true；
  /// - 旧键有行 = 用户显式设过 → 继承它的值（关过的老用户升级后不被静默打开）。
  ///
  /// 判据只看「偏好行是否存在」，不看值是否等于默认。结论当场写进本键，此后旧键再怎么
  /// 写（用户只想关云同步）都不再影响互联；[setAutoSyncEnabled] 写旧键前也先调本方法
  /// 落盘，堵住「迁移还没发生就先写了旧键」的窗口。
  Future<bool> isInterconnectAutoSyncEnabled() async {
    if (await _db.getPref(_keyInterconnectAutoSync) != null) {
      return _db.getPrefTyped<bool>(_keyInterconnectAutoSync, true);
    }
    final bool migrated = await _db.getPref(_keyAutoSync) == null
        ? true
        : await isAutoSyncEnabled();
    await _db.setPrefTyped<bool>(_keyInterconnectAutoSync, migrated);
    return migrated;
  }

  Future<void> setInterconnectAutoSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectAutoSync, v);

  /// 复习（SRS）数据的自动同步（反馈 VNz9dsLeIy，默认开）。关掉后复习数据不再在后台同步：常规同步
  /// 通道之后的复习步骤、本机写入后的推送、互联快速通道（已配对设备有新数据立刻同步）、本机作为主机
  /// 收到写入后的同步都不跑；只剩牌组列表「立即同步」、AnkiConnect `sync` 与进入复习页的节流同步
  /// （`srs_sync_scheduler.dart`）。只管复习数据，书 / 视频进度等常规同步不受影响。
  Future<bool> isSrsAutoSyncEnabled() =>
      _db.getPrefTyped<bool>(_keySrsAutoSync, true);

  Future<void> setSrsAutoSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySrsAutoSync, v);

  /// 「与 Hoshi/ッツ 共享 Google Drive」开关。默认关（老用户云端数据留在隐藏
  /// appDataFolder 原地不动）。

  /// 某条通道上次**整轮**同步完成的时刻（自动同步冷却窗判据）。
  ///
  /// 按通道分槽（BUG-1580）：解耦前是单份全局键，两条通道各写各的、却被
  /// [sync_auto_trigger] 的一次冷却判定当成同一个闸——云通道刚跑完就把互联通道
  /// 一起压住 5 分钟，反之亦然；一条通道失败重试也会被另一条的成功戳压制。
  ///
  /// 迁移：本槽位无值时回落解耦前的全局键（升级后第一轮不会因为「新键为空」而把
  /// 刚同步过的通道当成从未同步、立刻再跑一轮）。写侧只写本槽位。
  Future<int?> getLastSyncMs(SyncChannelScope scope) async {
    final s =
        await _getStringOrNull(scope.key(_keyLastSyncMs)) ??
        await _getStringOrNull(_keyLastSyncMs);
    return s == null ? null : int.tryParse(s);
  }

  Future<void> setLastSyncMs(SyncChannelScope scope, int ms) =>
      _setString(scope.key(_keyLastSyncMs), ms.toString());

  /// 本端上次**成功**合集同步的毫秒戳（多端库联合视图 §2.3：合集同步引擎的
  /// 因果基线——removedAt/deletedAt 晚于它的墓碑才是「新闻」，早于它的墓碑视为
  /// 本端已裁决过、成员/合集仍在即代表之后重加/重建）。0 = 从未同步过。
  /// 设备本地（[deviceLocalPrefKeys]）：它描述「本设备见过共享清单到什么时刻」，
  /// 随备份跨设备会让新设备把没见过的墓碑误判为旧闻而复活成员。
  ///
  /// 按通道分槽（BUG-1579）：云通道、互联 client 通道、以及本机作为互联 host 收到
  /// 对端 POST 时的合并，三方原先读写**同一个键**。双通道下的具体后果是：互联对端
  /// 推来的「成员移出墓碑」被云通道刚推进过的基线判成旧闻 → 引擎按「活胜」撤销这
  /// 次移出 → 再回传给 host，用户的移出操作被自己另一条通道悄悄撤销。因果基线描述
  /// 的是「本端相对**某一个远端**见过什么」，三条轴必须各记各的。
  ///
  /// 迁移：本槽位无值时回落解耦前的全局键作初值（升级后第一轮不会把所有历史墓碑
  /// 当成新闻重裁一遍）。写侧只写本槽位。
  Future<int> getCollectionsSyncBaselineMs(SyncChannelScope scope) =>
      readCollectionsSyncBaselineMs(_db, scope);

  Future<void> setCollectionsSyncBaselineMs(SyncChannelScope scope, int ms) =>
      writeCollectionsSyncBaselineMs(_db, scope, ms);

  /// 7c 视频刮削元数据增量拉取基线：上次从该通道见过的最大 host `updatedAt`
  /// （毫秒）。0 = 从未拉过（全量）。设备本地、按通道分槽。
  Future<int> getVideoMetadataSyncSinceMs(SyncChannelScope scope) async {
    final String? s = await _getStringOrNull(
      scope.key(_keyVideoMetadataSyncSinceMs),
    );
    return s == null ? 0 : int.tryParse(s) ?? 0;
  }

  Future<void> setVideoMetadataSyncSinceMs(SyncChannelScope scope, int ms) =>
      _setString(scope.key(_keyVideoMetadataSyncSinceMs), ms.toString());

  /// 流媒体书拉取基线：上次从该通道见过的最大 host 拥有时刻（毫秒，host 时钟）。
  /// 0 = 从未拉过（全量）。设备本地、按通道分槽。
  Future<int> getStreamVideoPullSinceMs(SyncChannelScope scope) async =>
      _parseStreamVideoPullSinceMs(
        await _getStringOrNull(scope.key(_keyStreamVideoPullSinceMs)),
      );

  /// [getStreamVideoPullSinceMs] 的快照版：从一份已读好的整表偏好（`getAllPrefs`）里
  /// 取，不再查库。视频进度 sweep 开头本来就读整表偏好，拉取基线顺手从里面拿。
  static int streamVideoPullSinceMsFromPrefs(
    SyncChannelScope scope,
    Map<String, String> prefs,
  ) => _parseStreamVideoPullSinceMs(
    prefs[scope.key(_keyStreamVideoPullSinceMs)],
  );

  static int _parseStreamVideoPullSinceMs(String? s) =>
      s == null ? 0 : int.tryParse(s) ?? 0;

  Future<void> setStreamVideoPullSinceMs(SyncChannelScope scope, int ms) =>
      _setString(scope.key(_keyStreamVideoPullSinceMs), ms.toString());

  /// 删除墓碑消费的因果基线（毫秒）。远端删除标记 deletedAt 晚于它才弹逐条确认；
  /// 早于它视为本设备已处理过、不再反复弹。0 = 从未消费过。设备本地
  /// （[deviceLocalPrefKeys]），随备份跨设备会让新设备把老墓碑误判为新闻反复骚扰。
  ///
  /// 按通道分槽（BUG-1579）：**推送**基线早就是互联通道专属的独立键（见
  /// [getDeletionTombstonesPushBaselineMs] 的理由——「两个通道各记各的账」），消费侧
  /// 却仍是一份全局键，两边不对称。后果：用户在云通道的确认框里处理完一批删除、
  /// 基线被推到 T，互联对端此前那批 deletedAt < T 的墓碑就此永远不再弹确认——那些
  /// 条目在本机留了下来，而用户以为「所有设备都删了」。消费轴按通道拆开后与推送轴
  /// 同形。
  ///
  /// 迁移：本槽位无值时回落解耦前的全局键作初值（升级后不会把用户早已复核过的老
  /// 墓碑重新当成新闻、逐条再弹一遍）。写侧只写本槽位。
  Future<int> getDeletionTombstonesBaselineMs(SyncChannelScope scope) async {
    final String? s =
        await _getStringOrNull(scope.key(_keyDeletionTombstonesBaselineMs)) ??
        await _getStringOrNull(_keyDeletionTombstonesBaselineMs);
    return s == null ? 0 : int.tryParse(s) ?? 0;
  }

  Future<void> setDeletionTombstonesBaselineMs(
    SyncChannelScope scope,
    int ms,
  ) => _setString(scope.key(_keyDeletionTombstonesBaselineMs), ms.toString());

  /// 删除墓碑**推送**的因果基线（毫秒，互联通道专用）。本地墓碑 deletedAt 晚于它才
  /// 推给对端 host；早于它视为本设备已推过、不再重复请求。0 = 从未推送过。
  ///
  /// 单一全局键（不按 host 分）：互联是 host/client 模型且 client 侧后端是单例
  /// [InterconnectSyncBackend.instance]，实际只对一个 host 推送；消费侧基线
  /// （[getDeletionTombstonesBaselineMs]）也是同样的全局口径，两侧保持一致。
  /// 设备本地（[deviceLocalPrefKeys]），理由见键定义处注释。
  Future<int> getDeletionTombstonesPushBaselineMs() async {
    final String? s = await _getStringOrNull(
      _keyDeletionTombstonesPushBaselineMs,
    );
    return s == null ? 0 : int.tryParse(s) ?? 0;
  }

  Future<void> setDeletionTombstonesPushBaselineMs(int ms) =>
      _setString(_keyDeletionTombstonesPushBaselineMs, ms.toString());

  // ── Desktop OAuth credentials ──────────────────────────────────────

  Future<String?> getDesktopCredentials() async {
    final encoded = await _getStringOrNull(_keyDesktopCredentials);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setDesktopCredentials(String? json) async {
    if (json == null) {
      await (_db.delete(
        _db.preferences,
      )..where((t) => t.key.equals(_keyDesktopCredentials))).go();
      return;
    }
    await _setString(_keyDesktopCredentials, _encodeSecret(json));
  }

  Future<void> clearDesktopSession() async {
    await (_db.delete(
      _db.preferences,
    )..where((t) => t.key.equals(_keyDesktopCredentials))).go();
  }

  // ── Backend type ───────────────────────────────────────────────────

  Future<SyncBackendType> getBackendType() async {
    final raw = await _getStringOrNull(_keyBackendType);
    if (raw == null) return SyncBackendType.googleDrive;
    for (final type in SyncBackendType.values) {
      if (type.name == raw) return type;
    }
    return SyncBackendType.googleDrive;
  }

  Future<void> setBackendType(SyncBackendType type) =>
      _setString(_keyBackendType, type.name);

  /// 云备份通道总开关，与 [isInterconnectEnabled] 对称。默认 true：开关出现前云通道
  /// 「只要选了后端就恒尝试」，缺行时保持这一既有行为。
  ///
  /// 关掉后 `enabledSyncChannelBackends` 不再列出云备份那一格，于是常规同步（自动 /
  /// 手动）、复习同步（`runOnAuthenticatedSyncChannels`）、资产传输、云端远端占位卡
  /// 都不再碰云盘。**只停用、不登出**：后端选择与凭据原样保留，重新打开即接着用。
  Future<bool> isCloudSyncEnabled() =>
      _db.getPrefTyped<bool>(_keyCloudSyncEnabled, true);

  Future<void> setCloudSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyCloudSyncEnabled, v);

  /// [type] 这条通道在本机**是否已配置**（凭据/地址已落盘）。
  ///
  /// 纯本地 preferences 读，**零网络**——调用点包括删除确认弹窗这类不许做 IO 的 UI
  /// 路径，绝不能改成去探测连通性（互联后端的 `restoreAuth` 会探测地址）。
  ///
  /// 语义是「配置过」而非「此刻连得上」：离线时删东西、勾「从所有设备删除」，墓碑
  /// 留在本地等下次同步发布，这是正确行为，不该因为当下离线就把选项藏起来。
  ///
  /// 穷尽 switch 无 default：新增后端时编译器强制在此表态，避免新后端被默默当成
  /// 「未配置」而让用户失去删除传播选项。
  ///
  /// googleDrive 移动端的登录态由 google_sign_in 插件自己持有、不落本表，所以它多认
  /// 一个 [getRootFolderId]（同步真跑过一次就有），剩下的缺口由调用方 OR 上后端的
  /// 内存态 `isAuthenticated` 补齐（见 `hasDeletionPropagationChannel`）。
  Future<bool> hasStoredBackendConfig(SyncBackendType type) async {
    bool present(String? v) => v != null && v.isNotEmpty;
    switch (type) {
      case SyncBackendType.googleDrive:
        // BUG-1576：这里读的必须是 **Drive 自己那格** 的根 folderId。用全局键时，
        // 一台从未登录过 Drive 的设备只要跑过一轮互联同步，全局键里就躺着互联对端
        // 的 URL，于是「云已配置」为真 → `hasDeletionPropagationChannel` 放行
        // 「从所有设备删除」→ 用户以为删干净了，实际没有任何云通道去发布墓碑。
        return present(await getDesktopCredentials()) ||
            present(
              await getRootFolderId(
                SyncChannelScope.forBackendType(SyncBackendType.googleDrive),
              ),
            );
      case SyncBackendType.webDav:
        return present(await getWebDavUrl());
      case SyncBackendType.ftp:
        return present(await getFtpHost());
      case SyncBackendType.sftp:
        return present(await getSftpHost());
      case SyncBackendType.dropbox:
        return present(await getDropboxToken());
      case SyncBackendType.oneDrive:
        return present(await getOneDriveToken());
      case SyncBackendType.fushiServer:
        // 互联双向：本机连别人（已填对端地址）或别人连本机（开着服务且有已配对
        // 对端——对端会经 `/api/tombstones` 读走本机墓碑）都算通道存在。
        if ((await getFushiClientUrls()).isNotEmpty) return true;
        return await isServerEnabled() &&
            (await _db.getPairedPeers()).isNotEmpty;
    }
  }

  /// 一次性迁移：把已废弃的 "SMB"(实为 WebDAV 网关) 配置并入 WebDAV，并删除全部
  /// `sync_smb_*` 死键。仅当对应 WebDAV 字段为空时才搬运，绝不覆盖用户已有的
  /// WebDAV 配置。幂等：无 SMB 数据时是 no-op。
  ///
  /// 用原始 key 字符串而非常量，因为 SMB 的 key 常量已随后端一并删除；迁移代码
  /// 必须独立于已删除的符号。
  Future<void> migrateSmbToWebDav() async {
    const String kSmbUrl = 'sync_smb_webdav_url';
    const String kSmbUser = 'sync_smb_username';
    const String kSmbPass = 'sync_smb_password';

    final String? backend = await _getStringOrNull(_keyBackendType);
    if (backend == 'smb') {
      // All-or-nothing: only seed WebDAV from SMB when there's no existing
      // WebDAV config at all. Avoids a hybrid (URL from one source, password
      // from the other) when the user had configured both.
      final bool hasWebDav = (await _getStringOrNull(_keyWebDavUrl)) != null;
      if (!hasWebDav) {
        final String? smbUrl = await _getStringOrNull(kSmbUrl);
        final String? smbUser = await _getStringOrNull(kSmbUser);
        // 密码以 base64 存储，原样搬运（不解码再编码，避免双重编码）。
        final String? smbPass = await _getStringOrNull(kSmbPass);
        if (smbUrl != null) await _setString(_keyWebDavUrl, smbUrl);
        if (smbUser != null) await _setString(_keyWebDavUsername, smbUser);
        if (smbPass != null) await _setString(_keyWebDavPassword, smbPass);
      }
      await _setString(_keyBackendType, SyncBackendType.webDav.name);
    }

    for (final String k in const <String>[
      kSmbUrl,
      kSmbUser,
      kSmbPass,
      'sync_smb_host',
      'sync_smb_share',
      'sync_smb_domain',
    ]) {
      await _deleteKey(k);
    }
  }

  /// 一次性幂等迁移：把「互联=互斥的 backendType==fushiServer 单选」旧模型迁到
  /// 独立的 [isInterconnectEnabled] 开关（互联与云备份不再冲突，可并存）。
  ///
  /// 旧模型里选互联意味着 `sync_backend_type == 'fushiServer'`（配对设备时也会被
  /// 强写成这个值，见 interconnect UI）。迁移：这类用户置互联开关为 true，并把
  /// backendType 迁到云默认 googleDrive（未认证时云通道自动 no-op），使升级后互联
  /// 照常跑、且不再占着「云后端选择」这个位置。互联自身的持久化字段（serverEnabled
  /// / clientUrls / token 等）本就独立存储，无需搬运。
  ///
  /// 一次性：迁移过一次后（[_keyInterconnectBackendMigrated] 落盘）永远 no-op。
  /// 这点是硬要求而非优化——解耦后用户仍可主动把云备份后端选成互联（互联页的
  /// 「用互联做备份后端」按钮，把备份写到已配对对端而不是云盘）。若迁移继续只看
  /// 「backendType 是不是 fushiServer」，这个用户选择会在下次启动被当成旧数据
  /// 抹回 googleDrive，按钮变成重启即失效的假开关。
  ///
  /// 必须在任何 [getBackendType]（未知值静默回落 googleDrive）之前、init 期跑一次。
  /// 用原始 key 字符串读取 backendType，独立于枚举符号的存亡。
  Future<void> migrateInterconnectBackendToToggle() async {
    if (await _db.getPrefTyped<bool>(_keyInterconnectBackendMigrated, false)) {
      return;
    }
    final String? backend = await _getStringOrNull(_keyBackendType);
    if (backend == SyncBackendType.fushiServer.name) {
      await setInterconnectEnabled(true);
      await _setString(_keyBackendType, SyncBackendType.googleDrive.name);
    }
    // 无论本机是否真有旧数据要搬，都记「迁移已跑过」：新装用户同样只有这一次窗口，
    // 之后的 backendType 一律是用户的真实选择。
    await _db.setPrefTyped<bool>(_keyInterconnectBackendMigrated, true);
  }

  // ── Content sync ──────────────────────────────────────────────────

  Future<bool> isSyncContentEnabled() =>
      _db.getPrefTyped<bool>(_keySyncContent, false);
  Future<void> setSyncContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncContent, v);

  /// 云通道「上传漫画文件」。键从未写过时继承 [isSyncContentEnabled]。
  Future<bool> isSyncMangaContentEnabled() async {
    if (await _db.getPref(_keySyncMangaContent) == null) {
      return isSyncContentEnabled();
    }
    return _db.getPrefTyped<bool>(_keySyncMangaContent, false);
  }

  Future<void> setSyncMangaContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncMangaContent, v);

  // ── 互联通道专属上传开关（BUG-988） ────────────────────────────────
  // 只作用于互联通道（[_runSyncChannel] 的 isInterconnect==true），与上面的云备份
  // sync_*_enabled 完全解耦；默认 false，让用户独立控制「要不要把本设备内容上传到
  // 互联对端」，不被「启用互联连接」自动裹挟。位置/统计等轻量进度仍走共享开关（跨设备
  // 续读是互联本意），此处仅拆「重内容」三类：书籍/内容、有声书文件、视频文件（词典
  // 已无自动同步开关，见 BUG-2762）。

  Future<bool> isInterconnectSyncContentEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncContent, false);
  Future<void> setInterconnectSyncContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncContent, v);

  /// 互联通道「上传漫画文件」。键从未写过时继承
  /// [isInterconnectSyncContentEnabled]。
  Future<bool> isInterconnectSyncMangaContentEnabled() async {
    if (await _db.getPref(_keyInterconnectSyncMangaContent) == null) {
      return isInterconnectSyncContentEnabled();
    }
    return _db.getPrefTyped<bool>(_keyInterconnectSyncMangaContent, false);
  }

  Future<void> setInterconnectSyncMangaContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncMangaContent, v);

  Future<bool> isInterconnectSyncAudioBookFilesEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncAudioBookFiles, false);
  Future<void> setInterconnectSyncAudioBookFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncAudioBookFiles, v);

  Future<bool> isInterconnectSyncVideoFilesEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncVideoFiles, false);
  Future<void> setInterconnectSyncVideoFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncVideoFiles, v);

  /// host 侧：是否允许已配对设备读取 / 写入本机「配置文件」（Profile）。
  ///
  /// 端点还要求 TLS + 已配对 peer token；本开关是**用户意图**那一道，默认关。
  Future<bool> isInterconnectProfileTransferEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectProfileTransfer, false);
  Future<void> setInterconnectProfileTransferEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectProfileTransfer, v);

  /// host 侧：是否允许已配对设备跟随本机账户自动登录（默认开）。
  Future<bool> isInterconnectLeaderboardLinkHostEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectLeaderboardLinkHost, true);
  Future<void> setInterconnectLeaderboardLinkHostEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectLeaderboardLinkHost, v);

  /// host 侧「我的设备」标记与设备钥匙指纹（实现与无头服务端共用，见引擎
  /// `interconnect_owner_devices.dart`）。
  InterconnectOwnerDeviceStore get _ownerDevices =>
      InterconnectOwnerDeviceStore(_db);

  /// host 侧：被标记为「我的设备」的已配对 peer（peerId 集合）。
  Future<Set<String>> getOwnerDevicePeerIds() =>
      _ownerDevices.ownerDevicePeerIds();

  /// 标记 / 取消一台已配对 peer 为「我的设备」。返回最终是否为「我的设备」。
  ///
  /// 标记要求这台 peer 配对时证明过设备钥匙（[getPeerDeviceKeyFingerprints] 里有它）；
  /// 没证明过的（旧版 client / 没上报设备钥匙）标不上，返回 false。
  Future<bool> setOwnerDevicePeer(String peerId, bool owner) =>
      _ownerDevices.setOwnerDevicePeer(peerId, owner);

  /// host 侧：配对时验签通过的设备公钥指纹（peerId → fingerprint）。
  Future<Map<String, String>> getPeerDeviceKeyFingerprints() =>
      _ownerDevices.deviceKeyFingerprints();

  /// 记下 / 清掉一台 peer 的已验签设备公钥指纹（null = 本次配对没证明设备钥匙）。
  Future<void> setPeerDeviceKeyFingerprint(
    String peerId,
    String? fingerprint,
  ) => _ownerDevices.setDeviceKeyFingerprint(peerId, fingerprint);

  /// 持 [token] 的已配对 peer 是否被标记为「我的设备」（token 不属于任何现存 peer = false）。
  /// 同时要求这台 peer 有已验签的设备钥匙记录：标记集合里的 peerId 不能单独生效。
  Future<bool> isOwnerDevicePeerToken(String token) =>
      _ownerDevices.isOwnerDevicePeerToken(token);

  /// client 侧：本机无账户时是否跟随已配对设备自动登录（默认开）。
  Future<bool> isLeaderboardFollowPairedLoginEnabled() =>
      _db.getPrefTyped<bool>(_keyLeaderboardFollowPairedLogin, true);
  Future<void> setLeaderboardFollowPairedLoginEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyLeaderboardFollowPairedLogin, v);

  /// host 侧：是否允许已配对设备远程更新本机 app（`/api/host/update`）。
  ///
  /// 端点另有已配对 peer token + 一次性 nonce 几道门（不按来源网络区分）；本开关是
  /// **用户意图**那一道，默认关。
  Future<bool> isInterconnectRemoteUpdateEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectRemoteUpdate, false);
  Future<void> setInterconnectRemoteUpdateEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectRemoteUpdate, v);

  /// 互联通道「共享统计」：阅读/观看时长、字数、逐时桶、查词与制卡计数。关掉后本设备
  /// 既不把统计推给对端，也不把对端统计折进本地——两个方向一起停，否则「关了还在收」
  /// 会让本地统计继续被对端撑大，用户看到的仍是没关掉。
  ///
  /// **缺键时继承旧开关 [isSyncStatsEnabled]**，不是硬编码 true。拆开关前互联的
  /// 统计/收藏就是由 `sync_stats_enabled` 一刀切代管的（那是个**无 visible 门控、
  /// 文案就叫「同步统计」的用户可见开关**）。存量用户把它关掉 = 明示「别同步我的
  /// 统计」；新键硬编码默认 true 会让升级后第一轮互联 sweep 就把统计 + 收藏词句推给
  /// 对端并把对端的折回本地，用户零操作、零提示 —— never break userspace。只有用户
  /// **真的动过互联那个新开关**（新键有行才成立）时才用新值。
  Future<bool> isInterconnectSyncStatsEnabled() =>
      _interconnectAggregateFlag(_keyInterconnectSyncStats);
  Future<void> setInterconnectSyncStatsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncStats, v);

  /// 设备级「同步浏览历史」：浏览器历史（及清除历史的墓碑）是否进聚合快照，云备份
  /// 与互联两条通道共用；host 侧也按它决定是否发出 / 接收历史。**缺行 = 关**——历史
  /// 不跟「共享收藏夹」走（书签仍跟收藏走），已开共享收藏的存量用户升级后不会零操作
  /// 就把整份浏览轨迹推出去。设备本地键（见 [deviceLocalPrefKeys]）。
  Future<bool> isWebHistorySyncEnabled() => readWebHistorySyncEnabled(_db);
  Future<void> setWebHistorySyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(kSyncWebHistoryPrefKey, v);

  /// 设备级「同步设置」（反馈 AWp-0BtDDv）：可移植的偏好设置（见
  /// `PortableSettingsPolicy`）是否随云备份 / 互联两条通道跨设备同步。**缺行 = 关**：
  /// 开了以后别的设备上改的设置会覆盖这台的，升级不能替用户默默打开。设备本地键——
  /// 从别的设备恢复备份不得替这台设备打开「接收别人的设置」。
  Future<bool> isSettingsSyncEnabled() =>
      _db.getPrefTyped<bool>(kSyncSettingsEnabledPrefKey, false);

  ///
  /// 开关本身不携带合并状态：打开（含关掉再开）后每一轮都按每项的真实修改时刻
  /// LWW（见 `settingsToAdopt`），没有「首次以远端为准」的重置。
  Future<void> setSettingsSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(kSyncSettingsEnabledPrefKey, v);

  /// 合并导入备份时是否也并入备份里的可移植设置（`PortableSettingsPolicy`，按每项
  /// 的修改时刻取较新者）。**缺行 = 关**：合并导入一直以来的承诺是「只添加内容、
  /// 不动本机设置」，升级不能悄悄改掉这条语义。覆盖导入的「导入设置」不受它影响。
  Future<bool> isBackupMergeSettingsEnabled() =>
      _db.getPrefTyped<bool>(kBackupMergeSettingsPrefKey, false);
  Future<void> setBackupMergeSettingsEnabled(bool v) =>
      _db.setPrefTyped<bool>(kBackupMergeSettingsPrefKey, v);

  /// 互联通道「共享收藏夹」：收藏词 + 收藏句（以及它们的删除墓碑，取消收藏要能
  /// 跨端传播）。与统计同为聚合快照的一半，但语义不同——收藏是用户挑出来的内容，
  /// 值得独立开关。同样双向一起停；缺键时同样继承旧的 [isSyncStatsEnabled]
  /// （收藏族拆开关前也归它管，见 [isInterconnectSyncStatsEnabled] 的说明）。
  Future<bool> isInterconnectSyncFavoritesEnabled() =>
      _interconnectAggregateFlag(_keyInterconnectSyncFavorites);
  Future<void> setInterconnectSyncFavoritesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncFavorites, v);

  /// 聚合快照两族（统计 / 收藏）互联侧开关的统一读法：新键有行就用新值，缺行则
  /// 回退到拆开关前代管它们的旧键 `sync_stats_enabled`（其自身默认 true）。
  Future<bool> _interconnectAggregateFlag(String key) async {
    if (await _db.getPref(key) == null) return isSyncStatsEnabled();
    return _db.getPrefTyped<bool>(key, true);
  }

  /// 互联 service-config 同步（host 的外部服务 API key / 服务配置随互联下发）。
  /// 默认 true = 既有行为不变；关掉后本设备不再向 host 请求 service-config，
  /// 已导入的值保持原样（不回滚——那是用户此刻正在用的配置）。
  /// client 侧：是否接收 host 共享的服务器来源与插件（默认开）。
  Future<bool> isInterconnectSourceShareEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSourceShareSync, true);
  Future<void> setInterconnectSourceShareEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSourceShareSync, v);

  /// host 侧：是否把本机的服务器来源与插件共享给「我的设备」（默认开）。
  Future<bool> isInterconnectSourceShareHostEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSourceShareHost, true);
  Future<void> setInterconnectSourceShareHostEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSourceShareHost, v);

  /// client 侧：是否也接收 host 共享的插件包（默认关，见 [_keyInterconnectSourceSharePlugins]）。
  Future<bool> isInterconnectSourceSharePluginsEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSourceSharePlugins, false);
  Future<void> setInterconnectSourceSharePluginsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSourceSharePlugins, v);

  /// host 侧：主人勾选共享的来源（`kind/id`）。坏值当空（= 不共享），不会因解析失败多发。
  Future<Set<String>> getInterconnectSourceShareHostItems() async {
    final String raw = await _db.getPrefTyped<String>(
      _keyInterconnectSourceShareHostItems,
      '',
    );
    if (raw.isEmpty) return <String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      return <String>{
        if (decoded is List)
          for (final Object? k in decoded)
            if (k is String && k.isNotEmpty) k,
      };
    } on FormatException {
      return <String>{};
    }
  }

  /// 勾选 / 取消勾选一条（[key] = `kind/id`）。
  Future<void> setInterconnectSourceShareHostItem(
    String key, {
    required bool shared,
  }) async {
    final Set<String> items = await getInterconnectSourceShareHostItems();
    if (shared ? !items.add(key) : !items.remove(key)) return;
    await _db.setPrefTyped<String>(
      _keyInterconnectSourceShareHostItems,
      jsonEncode(<String>[...items]..sort()),
    );
  }

  Future<bool> isInterconnectServiceConfigSyncEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectServiceConfigSync, true);
  Future<void> setInterconnectServiceConfigSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectServiceConfigSync, v);

  // ── Per-book audiobook position (synced) ──────────────────────────

  static const _keyAudiobookPositionPrefix = 'audiobook_pos_';

  /// 每本书的有声书播放位置（毫秒）。键为书的 bookKey，与
  /// AudiobookRepository 的 `audiobook_pos_<bookKey>` 同一键空间。默认 0 表示
  /// 无记录。集中走仓库层，避免散落的 `audiobook_pos_...` 字面量与类型漂移。
  Future<int> getAudiobookPosition(String bookKey) =>
      _db.getPrefTyped<int>('$_keyAudiobookPositionPrefix$bookKey', 0);
  Future<void> setAudiobookPosition(String bookKey, int positionMs) =>
      _db.setPrefTyped<int>('$_keyAudiobookPositionPrefix$bookKey', positionMs);

  // ── WebDAV credentials ────────────────────────────────────────────

  Future<String?> getWebDavUrl() => _getStringOrNull(_keyWebDavUrl);
  Future<void> setWebDavUrl(String? url) async {
    if (url == null) {
      await (_db.delete(
        _db.preferences,
      )..where((t) => t.key.equals(_keyWebDavUrl))).go();
      return;
    }
    await _setString(_keyWebDavUrl, url);
  }

  Future<String?> getWebDavUsername() => _getStringOrNull(_keyWebDavUsername);
  Future<void> setWebDavUsername(String? username) async {
    if (username == null) {
      await (_db.delete(
        _db.preferences,
      )..where((t) => t.key.equals(_keyWebDavUsername))).go();
      return;
    }
    await _setString(_keyWebDavUsername, username);
  }

  Future<String?> getWebDavPassword() async {
    final encoded = await _getStringOrNull(_keyWebDavPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setWebDavPassword(String? password) async {
    if (password == null) {
      await (_db.delete(
        _db.preferences,
      )..where((t) => t.key.equals(_keyWebDavPassword))).go();
      return;
    }
    await _setString(_keyWebDavPassword, _encodeSecret(password));
  }

  // ── Encoding ─────────────────────────────────────────────────────

  static String _encodeSecret(String value) => base64Encode(utf8.encode(value));

  static String _decodeSecret(String encoded) {
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return encoded;
    }
  }

  // ── OneDrive credentials ────────────────────────────────────────

  static const _keyOneDriveToken = 'sync_onedrive_token';

  Future<String?> getOneDriveToken() async {
    final encoded = await _getStringOrNull(_keyOneDriveToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setOneDriveToken(String? token) async {
    if (token == null) {
      await _deleteKey(_keyOneDriveToken);
      return;
    }
    await _setString(_keyOneDriveToken, _encodeSecret(token));
  }

  // ── Dropbox credentials ─────────────────────────────────────────

  static const _keyDropboxToken = 'sync_dropbox_token';

  Future<String?> getDropboxToken() async {
    final encoded = await _getStringOrNull(_keyDropboxToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setDropboxToken(String? token) async {
    if (token == null) {
      await _deleteKey(_keyDropboxToken);
      return;
    }
    await _setString(_keyDropboxToken, _encodeSecret(token));
  }

  // ── FTP credentials ─────────────────────────────────────────────

  static const _keyFtpHost = 'sync_ftp_host';
  static const _keyFtpPort = 'sync_ftp_port';
  static const _keyFtpUsername = 'sync_ftp_username';
  static const _keyFtpPassword = 'sync_ftp_password';
  static const _keyFtpUseTls = 'sync_ftp_use_tls';

  Future<String?> getFtpHost() => _getStringOrNull(_keyFtpHost);
  Future<void> setFtpHost(String? v) => _setOrDelete(_keyFtpHost, v);
  Future<int> getFtpPort() => _db.getPrefTyped<int>(_keyFtpPort, 21);
  Future<void> setFtpPort(int v) => _db.setPrefTyped<int>(_keyFtpPort, v);
  Future<String?> getFtpUsername() => _getStringOrNull(_keyFtpUsername);
  Future<void> setFtpUsername(String? v) => _setOrDelete(_keyFtpUsername, v);

  Future<String?> getFtpPassword() async {
    final encoded = await _getStringOrNull(_keyFtpPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setFtpPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keyFtpPassword);
      return;
    }
    await _setString(_keyFtpPassword, _encodeSecret(v));
  }

  Future<bool> isFtpTlsEnabled() =>
      _db.getPrefTyped<bool>(_keyFtpUseTls, false);
  Future<void> setFtpTlsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyFtpUseTls, v);

  // ── SFTP credentials ────────────────────────────────────────────

  static const _keySftpHost = 'sync_sftp_host';
  static const _keySftpPort = 'sync_sftp_port';
  static const _keySftpUsername = 'sync_sftp_username';
  static const _keySftpPassword = 'sync_sftp_password';
  static const _keySftpPrivateKey = 'sync_sftp_private_key';

  Future<String?> getSftpHost() => _getStringOrNull(_keySftpHost);
  Future<void> setSftpHost(String? v) => _setOrDelete(_keySftpHost, v);
  Future<int> getSftpPort() => _db.getPrefTyped<int>(_keySftpPort, 22);
  Future<void> setSftpPort(int v) => _db.setPrefTyped<int>(_keySftpPort, v);
  Future<String?> getSftpUsername() => _getStringOrNull(_keySftpUsername);
  Future<void> setSftpUsername(String? v) => _setOrDelete(_keySftpUsername, v);

  Future<String?> getSftpPassword() async {
    final encoded = await _getStringOrNull(_keySftpPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setSftpPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keySftpPassword);
      return;
    }
    await _setString(_keySftpPassword, _encodeSecret(v));
  }

  Future<String?> getSftpPrivateKey() async {
    final encoded = await _getStringOrNull(_keySftpPrivateKey);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setSftpPrivateKey(String? v) async {
    if (v == null) {
      await _deleteKey(_keySftpPrivateKey);
      return;
    }
    await _setString(_keySftpPrivateKey, _encodeSecret(v));
  }

  // ── Fushi Server config ─────────────────────────────────────────

  static const _keyInterconnectEnabled = 'sync_interconnect_enabled';

  /// 「旧互联后端 → 独立开关」迁移的一次性完成标记。见
  /// [migrateInterconnectBackendToToggle]：迁移过去靠「backendType 不再是
  /// fushiServer」当哨兵，于是用户之后主动把备份后端设回互联（互联页的
  /// 「用互联做备份后端」按钮）会在下次启动被迁移当成旧数据再改回 googleDrive。
  /// 用独立标记记「本机已迁移过」，让迁移真正只跑一次。
  static const _keyInterconnectBackendMigrated =
      'sync_interconnect_backend_migrated';
  static const _keyServerEnabled = 'sync_server_enabled';
  static const _keyServerPort = 'sync_server_port';
  static const _keyServerPassword = 'sync_server_password';
  static const _keyDeviceId = 'sync_device_id';

  /// 「本机作为制卡落地设备」开关打开的时刻（毫秒）；0 = 关。跨设备中转按它与远端
  /// 认领比大小决定谁是落地设备（后打开者胜），见 `PendingMineRelay`。设备本地。
  static const _keyPendingMineLandingClaimedAt =
      'sync_pending_mine_landing_claimed_at';

  Future<int> getPendingMineLandingClaimedAt() =>
      _db.getPrefTyped<int>(_keyPendingMineLandingClaimedAt, 0);

  /// 打开时记下此刻（作为新的认领），关闭写 0。
  Future<void> setPendingMineLanding(bool enabled) => _db.setPrefTyped<int>(
    _keyPendingMineLandingClaimedAt,
    enabled ? DateTime.now().millisecondsSinceEpoch : 0,
  );
  static const _keyLanRequiresPin = 'sync_lan_requires_pin';
  static const _keyServerTlsEnabled = 'sync_server_tls_enabled';
  static const _keyInterconnectPublicUrls = kInterconnectPublicUrlsPref;
  static const _keyInterconnectP2pEnabled = kInterconnectP2pEnabledPref;
  static const _keyInterconnectP2pSecret = kInterconnectP2pSecretPref;
  static const _keyInterconnectP2pRelayUrls = kInterconnectP2pRelayUrlsPref;

  /// Single source of truth for the default Fushi sync-server port.
  /// 38765 is in the IANA User Ports range (1024–49151) but unassigned and
  /// clear of the crowded 8xxx dev-server band and the 49152+ ephemeral range,
  /// so initial bind conflicts are unlikely. Referenced everywhere the default
  /// is needed so the value can never drift between call sites.
  static const int defaultServerPort = 38765;

  /// 互联总开关，独立于 [getBackendType]（云备份后端选择）。为 true 时互联作为
  /// 一条独立的同步/端到端通道运行——连接对端、远端查词/音频/占位卡 live 数据源、
  /// 以及与云备份并行的元数据同步通道——与用户选的云后端并存、互不排斥。
  ///
  /// 历史上互联是 `SyncBackendType.fushiServer` 这个互斥单选项；已由
  /// [migrateInterconnectBackendToToggle] 迁移到本独立布尔开关。默认 false。
  Future<bool> isInterconnectEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectEnabled, false);

  /// 互联总开关的进程内「已变更」广播（BUG-1560）。
  ///
  /// 这个开关有两个写入口——同步设置页的「启用互联」开关和库页来源视图里的互联
  /// 虚拟来源行——而两边各自还缓存着一份内存态（设置页的 `_SyncSettingsState` 按
  /// AppModel 缓存、`load()` 一辈子只跑一次；来源视图在 initState 读一次）。谁写
  /// 完都不通知对方，另一边就一直显示旧值、互联各 section 的显隐也跟着错，直到
  /// 重启 app。
  ///
  /// 真值只有一个——preferences 里那一位；本 notifier 只是它的变更广播。bump 放在
  /// **唯一的写方法** [setInterconnectEnabled] 里，所以再多写入口也不可能漏发通知
  /// （消费方 re-read 真值，不信广播里的载荷，故没有第二份真相）。
  static final ValueNotifier<int> interconnectEnabledRevision =
      ValueNotifier<int>(0);

  Future<void> setInterconnectEnabled(bool v) async {
    await _db.setPrefTyped<bool>(_keyInterconnectEnabled, v);
    interconnectEnabledRevision.value++;
  }

  Future<bool> isServerEnabled() =>
      _db.getPrefTyped<bool>(_keyServerEnabled, false);
  Future<void> setServerEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyServerEnabled, v);
  Future<int> getServerPort() =>
      _db.getPrefTyped<int>(_keyServerPort, defaultServerPort);
  Future<void> setServerPort(int v) => _db.setPrefTyped<int>(_keyServerPort, v);

  /// TODO-961 取舍 A：LAN 自动发现的对端是否仍需 PIN 才能配对。默认 false=
  /// 自家局域网免 PIN（公网入站恒强制，与本开关无关，见配对协议
  /// [FushiPairingProtocol.computePinRequired]）。
  /// host 侧用户填写的公网 / 反代 / DDNS 地址（有序，可多条）。经
  /// `/api/capabilities` 的地址集公布给已配对 client 自动学习
  /// （docs/specs/2026-09-28-interconnect-remote-reach.md §1）。设备本地：这是
  /// 「这台机器在外网叫什么」，换一台机器就不对了。
  Future<List<String>> getInterconnectPublicUrls() async {
    return decodeInterconnectPublicUrls(
      await _getStringOrNull(_keyInterconnectPublicUrls),
    );
  }

  Future<void> setInterconnectPublicUrls(List<String> urls) async {
    final List<String> cleaned = <String>[
      for (final String u in urls)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    if (cleaned.isEmpty) {
      await _deleteKey(_keyInterconnectPublicUrls);
      return;
    }
    await _setString(_keyInterconnectPublicUrls, jsonEncode(cleaned));
  }

  /// host 侧「允许经 P2P 隧道远程连接」（默认关，见 [kInterconnectP2pEnabledPref]）。
  Future<bool> isInterconnectP2pEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectP2pEnabled, false);
  Future<void> setInterconnectP2pEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectP2pEnabled, v);

  /// 本机 iroh 私钥（设备本地；同一把钥匙出现在两台设备上就是同一个 NodeId）。
  Future<String?> getInterconnectP2pSecret() async {
    final String? encoded = await _getStringOrNull(_keyInterconnectP2pSecret);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setInterconnectP2pSecret(String v) =>
      _setString(_keyInterconnectP2pSecret, _encodeSecret(v));

  /// 自建 iroh-relay 地址（空 = iroh 默认公共中继）。
  Future<List<String>> getInterconnectP2pRelayUrls() async =>
      decodeInterconnectPublicUrls(
        await _getStringOrNull(_keyInterconnectP2pRelayUrls),
      );

  Future<void> setInterconnectP2pRelayUrls(List<String> urls) async {
    final List<String> cleaned = <String>[
      for (final String u in urls)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    if (cleaned.isEmpty) {
      await _deleteKey(_keyInterconnectP2pRelayUrls);
      return;
    }
    await _setString(_keyInterconnectP2pRelayUrls, jsonEncode(cleaned));
  }

  Future<bool> getLanRequiresPin() =>
      _db.getPrefTyped<bool>(_keyLanRequiresPin, false);
  Future<void> setLanRequiresPin(bool v) =>
      _db.setPrefTyped<bool>(_keyLanRequiresPin, v);

  /// TODO-961 M1：host 是否以 HTTPS（自签证书 + 指纹钉扎）对外服务。默认 false=
  /// 明文 HTTP 老路径（Never break userspace：现有 LAN 用户升级后行为不变，直到
  /// 主动开 TLS）。开启后 [FushiSyncServerController] 用 [FushiTlsIdentityStore]
  /// 起 TLS 并在配对响应里回传指纹供 client TOFU 钉扎。
  Future<bool> getServerTlsEnabled() =>
      _db.getPrefTyped<bool>(_keyServerTlsEnabled, false);
  Future<void> setServerTlsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyServerTlsEnabled, v);

  /// TODO-961 B 段：全新设备**首次**启用 hosting 时默认打开 TLS。判据是
  /// preferences 表里 [_keyServerTlsEnabled] 与 [_keyServerEnabled] 两个 key 都
  /// **从未写入过**——存量 hosting（或曾 hosting）设备至少写过 serverEnabled，
  /// 显式设置过 TLS 的更不动，保持明文现状（Never break userspace）。
  /// 返回是否真的应用了默认值（供 UI 同步开关显示）。
  Future<bool> applyFirstHostingTlsDefault() async {
    if (await _getStringOrNull(_keyServerTlsEnabled) != null) return false;
    if (await _getStringOrNull(_keyServerEnabled) != null) return false;
    await setServerTlsEnabled(true);
    return true;
  }

  Future<String?> getServerPassword() async {
    final encoded = await _getStringOrNull(_keyServerPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setServerPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keyServerPassword);
      return;
    }
    await _setString(_keyServerPassword, _encodeSecret(v));
  }

  /// Stable per-install identifier used to (a) advertise this device over the
  /// LAN and (b) filter our own service out of discovery results. Generated
  /// once on first use and persisted; never overwritten by a backup import.
  Future<String> getOrCreateDeviceId() async {
    final existing = await _getStringOrNull(_keyDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final String id = FushiSyncServer.generateToken();
    await _setString(_keyDeviceId, id);
    return id;
  }

  /// client 侧：本机互联设备钥匙（首次使用时生成并落设备本地偏好）。配对时用它签
  /// host 下发的会话 nonce（`interconnect_device_key.dart`）。存的值坏了就换一把新的：
  /// 只影响之后的配对能否被标成「我的设备」，已配对关系（per-peer token）不受影响。
  ///
  /// 存储取舍：与 iroh P2P 私钥同样落 app 私有目录下的偏好表，靠设备本地清单 + 凭据红线挡住
  /// 备份 / 导出外带。仓内现在有 flutter_secure_storage（2026-10-29 为音乐插件凭据保险库的数据
  /// 密钥引入，见 `media/music/plugin/music_plugin_vault_key.dart`），这两把钥匙尚未迁过去。
  Future<InterconnectDeviceKey> getOrCreateInterconnectDeviceKey() async {
    final String? encoded = await _getStringOrNull(
      _keyInterconnectDevicePrivateKey,
    );
    if (encoded != null && encoded.isNotEmpty) {
      try {
        return InterconnectDeviceKey.decodePrivateKey(_decodeSecret(encoded));
      } on FormatException {
        // 坏值：落到下面重新生成。
      }
    }
    final InterconnectDeviceKey key = InterconnectDeviceKey.generate();
    await _setString(
      _keyInterconnectDevicePrivateKey,
      _encodeSecret(key.encodePrivateKey()),
    );
    return key;
  }

  // ── 媒体服务器（Jellyfin / Emby / Plex） ─────────────────────────────

  /// v1 单服务器键（一条 [JellyfinServerConfig] JSON）。只在 [getJellyfinServers]
  /// 的一次性迁移里读，此后不再写；常量保留是为了黑名单与迁移代码引用同一字面量。
  static const _keyJellyfinServer = 'sync_jellyfin_server';

  /// v2 多服务器键：JSON 数组，每项 [MediaServerConfig.toJson]。列表顺序 =
  /// 用户添加顺序（视频页「媒体服务器」栏目一台一张卡片按此排）。键名带
  /// `jellyfin` 是历史名（冻结）：Plex 等其它类型也落在这个数组里，按 `kind`
  /// 字段区分，缺字段 = Jellyfin。
  static const _keyJellyfinServers = 'sync_jellyfin_servers';

  /// 已登录的全部媒体服务器（Jellyfin 家族 + Plex，按添加顺序）；未配置 → 空列表。
  ///
  /// 与 Jellyfin 共用 [_keyJellyfinServers]（键名冻结不改）：每项按
  /// `kind` 字段经 [decodeMediaServerConfig] 分发，**缺字段按 Jellyfin 读**
  /// （存量数据全是它）。认不出的 `kind` 与脏项逐项丢弃。
  ///
  /// **旧单值键迁移在读路径完成**：列表键不存在而 [_keyJellyfinServer] 存在时，把
  /// 旧值包成单元素列表写进列表键并删旧键。不走 schema migration——这只是 prefs
  /// 表里一行 JSON 的形状变化，读一次就收敛，且旧键脏 JSON 时同样删旧键（它本来
  /// 也读成「未配置」，留着只会让每次读都重跑一遍迁移）。
  ///
  /// 脏项（非 Map / 缺必填字段）逐项丢弃，不整列表作废：一台服务器的配置坏了
  /// 不该把其它几台一起登出。
  Future<List<MediaServerConfig>> getMediaServers() async {
    final String? raw = await _getStringOrNull(_keyJellyfinServers);
    if (raw != null) return _decodeMediaServers(raw);
    final String? legacy = await _getStringOrNull(_keyJellyfinServer);
    if (legacy == null) return const <MediaServerConfig>[];
    final JellyfinServerConfig? migrated = _decodeJellyfinServer(legacy);
    final List<MediaServerConfig> servers = <MediaServerConfig>[
      if (migrated != null) migrated,
    ];
    await setMediaServers(servers);
    await _deleteKey(_keyJellyfinServer);
    return servers;
  }

  /// 整表覆盖；空列表 = 删键（全部登出）。
  ///
  /// 登录 / 登出 / 改配置全都经过这里，所以「已不在列表里的服务器，它的远端视频
  /// 清单磁盘缓存一并删掉」也只在这里做一次（[RemoteVideoListStore.retainSources]）。
  Future<void> setMediaServers(List<MediaServerConfig> servers) async {
    if (servers.isEmpty) {
      await _deleteKey(_keyJellyfinServers);
    } else {
      await _setString(
        _keyJellyfinServers,
        jsonEncode(<Map<String, Object?>>[
          for (final MediaServerConfig s in servers) s.toJson(),
        ]),
      );
    }
    // 不等删文件：在册名单在调用时同步生效（之后到的写入照名单丢弃），删文件
    // 本身是缓存清理，不该拖住登录 / 登出。
    unawaited(
      RemoteVideoListStore.retainSources(<String>[
        for (final MediaServerConfig s in servers) s.sourceId,
      ]),
    );
  }

  /// 按 [MediaServerConfig.sourceId] 身份替换（原位，不打乱用户排好的顺序）或追加。
  Future<void> upsertMediaServer(MediaServerConfig config) async {
    final List<MediaServerConfig> servers = await getMediaServers();
    final int index = servers.indexWhere(
      (MediaServerConfig s) => s.sourceId == config.sourceId,
    );
    final List<MediaServerConfig> next = List<MediaServerConfig>.of(servers);
    if (index < 0) {
      next.add(config);
    } else {
      next[index] = config;
    }
    await setMediaServers(next);
  }

  /// 只登出一台（按 [MediaServerConfig.sourceId]）；不在列表里 = no-op。
  Future<void> removeMediaServer(String sourceId) async {
    final List<MediaServerConfig> servers = await getMediaServers();
    final List<MediaServerConfig> next = <MediaServerConfig>[
      for (final MediaServerConfig s in servers)
        if (s.sourceId != sourceId) s,
    ];
    if (next.length == servers.length) return;
    await setMediaServers(next);
  }

  /// 已登录的全部 Jellyfin/Emby 服务器（按添加顺序）；未配置 → 空列表。
  /// = [getMediaServers] 里 [MediaServerKind.jellyfin] 的那些（Plex 不在其中）。
  Future<List<JellyfinServerConfig>> getJellyfinServers() async =>
      <JellyfinServerConfig>[
        for (final MediaServerConfig s in await getMediaServers())
          if (s is JellyfinServerConfig) s,
      ];

  /// 覆盖全部 Jellyfin 家族服务器；**其它类型（Plex）原样保留**在原位。空列表 =
  /// 只登出全部 Jellyfin 家族服务器（整表空了才删键）。
  ///
  /// 保序口径：旧表里 Jellyfin 项的槽位按顺序由 [servers] 依次填入，多出来的
  /// 追加到末尾、少了的槽位删掉；非 Jellyfin 项位置不动。
  Future<void> setJellyfinServers(List<JellyfinServerConfig> servers) async {
    final List<MediaServerConfig> current = await getMediaServers();
    final Iterator<JellyfinServerConfig> replacements = servers.iterator;
    final List<MediaServerConfig> next = <MediaServerConfig>[
      for (final MediaServerConfig s in current)
        if (s is! JellyfinServerConfig)
          s
        else if (replacements.moveNext())
          replacements.current,
    ];
    while (replacements.moveNext()) {
      next.add(replacements.current);
    }
    await setMediaServers(next);
  }

  /// 按 `(serverUrl, userId)` 身份替换或追加一台服务器。
  ///
  /// 身份键走 [JellyfinVideoClient.sourceIdFor]（= 远端清单缓存槽的身份），同一
  /// 账号重复登录只是换令牌 / 改库选择，列表里不会出现第二张同服务器卡片；替换
  /// 保持原位，不把用户排好的顺序打乱。
  Future<void> upsertJellyfinServer(JellyfinServerConfig config) =>
      upsertMediaServer(config);

  /// 只登出一台（按 `(serverUrl, userId)` 身份）；不在列表里 = no-op。
  Future<void> removeJellyfinServer({
    required String serverUrl,
    required String userId,
  }) => removeMediaServer(
    JellyfinVideoClient.sourceIdFor(serverUrl: serverUrl, userId: userId),
  );

  /// 过渡口径：**列表第一项**（多服务器化之前只有一台，「第一台」就是那一台）。
  /// 单远端源架构的消费端（home_video_page `_resolveJellyfinVideoClient`）在改成
  /// 逐台解析前先靠它维持旧行为；新代码一律用 [getJellyfinServers]。
  @Deprecated('Use getJellyfinServers')
  Future<JellyfinServerConfig?> getJellyfinServer() async {
    final List<JellyfinServerConfig> servers = await getJellyfinServers();
    return servers.isEmpty ? null : servers.first;
  }

  /// 过渡口径：`null` = 清空全部 Jellyfin 家族服务器（旧的「登出 = 删键」语义，
  /// 多台时等于全部登出；Plex 不受影响）；非 null = [upsertJellyfinServer]。新代码
  /// 用 [upsertJellyfinServer] / [removeJellyfinServer] 点名操作。
  @Deprecated('Use upsertJellyfinServer / removeJellyfinServer')
  Future<void> setJellyfinServer(JellyfinServerConfig? config) => config == null
      ? setJellyfinServers(const <JellyfinServerConfig>[])
      : upsertJellyfinServer(config);

  static List<MediaServerConfig> _decodeMediaServers(String raw) {
    if (raw.isEmpty) return const <MediaServerConfig>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return <MediaServerConfig>[
          for (final Object? item in decoded)
            if (item is Map<String, dynamic>)
              if (decodeMediaServerConfig(item)
                  case final MediaServerConfig config)
                config,
        ];
      }
    } catch (_) {
      // Best-effort: 脏 JSON 一律当「未配置」（下面返回空表），不弹错也不抛——
      // 这条只是读缓存里的服务器配置，设置页会让用户重新登录。
    }
    return const <MediaServerConfig>[];
  }

  static JellyfinServerConfig? _decodeJellyfinServer(String raw) {
    if (raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return JellyfinServerConfig.fromJson(decoded);
      }
    } catch (_) {
      // 同上：旧单值键的脏 JSON 当「未配置」。
    }
    return null;
  }

  // ── Fushi Client (connect to another Fushi instance) ───────────

  static const _keyFushiClientUrl = 'sync_hibiki_client_url';
  static const _keyFushiClientUrls = 'sync_hibiki_client_urls';
  static const _keyFushiClientToken = 'sync_hibiki_client_token';
  // 视频模块遥控按钮上次选中的 host（hostId）。指向本设备配对的那台电脑，
  // 随备份到别的设备只会指错，属设备本地。
  static const _keyVideoRemoteLastHostId = 'video_remote_last_host_id';

  Future<String?> getVideoRemoteLastHostId() =>
      _getStringOrNull(_keyVideoRemoteLastHostId);
  Future<void> setVideoRemoteLastHostId(String? hostId) =>
      _setOrDelete(_keyVideoRemoteLastHostId, hostId);

  /// 旧的单地址 API，仅为向后兼容保留；新代码请用 [getFushiClientUrls]。
  @Deprecated('Use getFushiClientUrls / setFushiClientUrls')
  Future<String?> getFushiClientUrl() => _getStringOrNull(_keyFushiClientUrl);
  @Deprecated('Use getFushiClientUrls / setFushiClientUrls')
  Future<void> setFushiClientUrl(String? v) =>
      _setOrDelete(_keyFushiClientUrl, v);

  /// 有序候选地址列表（下标即优先级）。新键缺失时，从旧的单地址键迁移种子，
  /// 保证老用户无感。
  Future<List<FushiClientUrl>> getFushiClientUrls() async {
    final raw = await _getStringOrNull(_keyFushiClientUrls);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(FushiClientUrl.fromJson).toList();
    }
    final legacy = await _getStringOrNull(_keyFushiClientUrl);
    if (legacy != null && legacy.isNotEmpty) {
      return <FushiClientUrl>[FushiClientUrl(url: legacy)];
    }
    return const <FushiClientUrl>[];
  }

  /// 候选地址列表的进程内「已变更」广播。除了设置页，后台的地址学习
  /// （[InterconnectAddressLearner]）也会写这个列表；设置页若只认自己的内存副本，
  /// 下一次用户编辑就会把刚学到的地址整份覆盖掉。bump 放在**唯一的写方法**
  /// [setFushiClientUrls] 里（与 [interconnectEnabledRevision] 同一范式），消费方
  /// 收到后重读真值。
  static final ValueNotifier<int> fushiClientUrlsRevision = ValueNotifier<int>(
    0,
  );

  /// 候选列表「读-改-写」的进程级串行化：后台地址学习、链接配对各自读-改-写，
  /// 并发时后写者会把前者的结果（甚至用户刚删掉的 host 连同 token）写回来
  /// （审查问题 10）。[transform] 返回同一个实例 = 不写盘。
  static Future<void> _urlsWriteChain = Future<void>.value();

  Future<List<FushiClientUrl>> updateFushiClientUrls(
    List<FushiClientUrl> Function(List<FushiClientUrl> current) transform,
  ) {
    final Future<List<FushiClientUrl>> result = _urlsWriteChain.then((_) async {
      final List<FushiClientUrl> before = await getFushiClientUrls();
      final List<FushiClientUrl> after = inheritInterconnectLookupDisabled(
        before,
        transform(before),
      );
      if (!identical(after, before)) await setFushiClientUrls(after);
      return after;
    });
    _urlsWriteChain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> setFushiClientUrls(List<FushiClientUrl> urls) async {
    if (urls.isEmpty) {
      await _deleteKey(_keyFushiClientUrls);
    } else {
      await _setString(
        _keyFushiClientUrls,
        jsonEncode(urls.map((FushiClientUrl u) => u.toJson()).toList()),
      );
    }
    fushiClientUrlsRevision.value++;
  }

  /// 追加 / 升级一个候选地址（TOFU 指纹记录器）。保持原有顺序与 token 不变，返回最终列表。
  /// 用于 LAN 发现与手动配对：把对端地址加入列表，而不是覆盖整套配置。
  ///
  /// TODO-961 M1（TOFU 接线，设计稿 §3.1 / §3.5）：
  /// - [fingerprint] 非空（https 钉扎指纹）时，把它写进对应条目；这是「首次信任并
  ///   记录」(TOFU) 的落脚点。
  /// - 若该 URL 已存在且**已记录非空指纹**，而本次新指纹与之**不符**，抛
  ///   [FushiFingerprintMismatchException]，**绝不覆盖已存指纹**（疑似 MITM）。
  /// - 已存指纹为空（明文老条目）→ 允许首次写入指纹（http 升级为 https 钉扎）。
  /// - 指纹相同 / 本次 [fingerprint] 为 null（明文 http）→ 幂等：仅补 deviceName。
  Future<List<FushiClientUrl>> addFushiClientUrl(
    String url, {
    String? fingerprint,
    String? deviceName,
  }) {
    final String? incomingFp = (fingerprint != null && fingerprint.isNotEmpty)
        ? fingerprint
        : null;
    // 读改写在 [updateFushiClientUrls] 的串行链里做：与后台地址学习、链接配对、
    // 设置页编辑互斥，谁都不会拿过期快照覆盖别人刚写的条目。
    return updateFushiClientUrls((List<FushiClientUrl> urls) {
      final int existingIdx = urls.indexWhere(
        (FushiClientUrl u) => u.url == url,
      );
      if (existingIdx < 0) {
        return <FushiClientUrl>[
          ...urls,
          FushiClientUrl(
            url: url,
            fingerprintSha256: incomingFp,
            deviceName: deviceName,
          ),
        ];
      }
      final FushiClientUrl existing = urls[existingIdx];
      final String? storedFp = existing.fingerprintSha256;
      // MITM 守卫：已记录非空指纹且新指纹非空且不符 → 拒绝覆盖，抛异常告警。
      if (incomingFp != null &&
          storedFp != null &&
          storedFp.isNotEmpty &&
          !_fingerprintEquals(storedFp, incomingFp)) {
        throw FushiFingerprintMismatchException(
          url: url,
          storedFingerprint: storedFp,
          incomingFingerprint: incomingFp,
        );
      }
      // 指纹处理：已存非空（且与新值归一化相等，否则上面已抛）→ 保留原存值，
      // 不被新写法（大小写/冒号差异）改写；已存为空 → 首次写入新指纹（http→https 升级）。
      final String? nextFp = (storedFp != null && storedFp.isNotEmpty)
          ? storedFp
          : incomingFp;
      final FushiClientUrl upgraded = existing.copyWith(
        fingerprintSha256: nextFp,
        deviceName: deviceName,
      );
      if (upgraded.fingerprintSha256 == existing.fingerprintSha256 &&
          upgraded.deviceName == existing.deviceName) {
        return urls; // 无变化，避免无谓写盘。
      }
      return <FushiClientUrl>[...urls]..[existingIdx] = upgraded;
    });
  }

  /// 指纹相等比较——直接用铉扎层那份归一化（BUG-1557：原本这里自己又写了一遍
  /// 同语义的 norm，两份实现一旦漂开就会出现「铉扎握手过了、TOFU 说不符」）。
  static bool _fingerprintEquals(String a, String b) => fingerprintEquals(a, b);

  Future<String?> getFushiClientToken() async {
    final encoded = await _getStringOrNull(_keyFushiClientToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setFushiClientToken(String? v) async {
    if (v == null) {
      await _deleteKey(_keyFushiClientToken);
      return;
    }
    await _setString(_keyFushiClientToken, _encodeSecret(v));
  }

  /// BUG-1550：把配对拿到的 per-peer token 落在**这一条地址**上，并同步写全局键。
  ///
  /// 两处都写的理由：地址行上的 token 让「多台对端各自一份凭据」成立（这是本 bug
  /// 的根因修复）；全局键继续维持，是为了那些 token 为空的行（老配置、用户手动补
  /// 的同 host 备用地址）仍能鉴权——升级前的行为逐字保留（Never break userspace）。
  ///
  /// [url] 不在列表里时只写全局键（配对流程会在此之前把地址 append 进去，正常路径
  /// 不会走到；防御性处理避免凭据丢失）。
  ///
  /// 53NT7G_tSO：host 按设备只认一份 token（重新配对即作废旧的），所以新 token 同时
  /// 写到**同一台 host 的全部地址**；[hostId]（配对时 ping 回报的身份）让还没归组的
  /// 新地址先按指纹判据归组，见 [applyIssuedInterconnectToken]。
  ///
  /// 地址归属闸：[url] 已归另一台 host 而 [reassignOwner] 为 false 时，变换里抛
  /// [InterconnectAddressOwnerConflict]（与 [addFushiClientUrl] 抛
  /// [FushiFingerprintMismatchException] 同一模式），列表与全局 token 键都不写。
  Future<void> setFushiClientTokenForUrl(
    String url,
    String token, {
    String? hostId,
    bool reassignOwner = false,
  }) async {
    await updateFushiClientUrls(
      (List<FushiClientUrl> urls) => applyIssuedInterconnectToken(
        urls,
        url: url,
        token: token,
        hostId: hostId,
        reassignOwner: reassignOwner,
      ),
    );
    await setFushiClientToken(token);
  }

  /// BUG-1550：清空所有地址行上的 per-peer token，让全局键重新成为唯一凭据。
  /// 用户在设置页手贴 token 时调用——那是显式覆盖，不该被残留的行内凭据压过。
  Future<void> clearFushiClientUrlTokens() async {
    await updateFushiClientUrls((List<FushiClientUrl> urls) {
      if (!urls.any((FushiClientUrl u) => u.token != null)) return urls;
      return <FushiClientUrl>[
        for (final FushiClientUrl u in urls)
          FushiClientUrl(
            url: u.url,
            enabled: u.enabled,
            fingerprintSha256: u.fingerprintSha256,
            deviceName: u.deviceName,
            hostId: u.hostId,
            learned: u.learned,
            addressKind: u.addressKind,
            lookupEnabled: u.lookupEnabled,
          ),
      ];
    });
  }

  /// BUG-1557：某条地址已铉扎的证书指纹（未铉扎 / 地址不在列表里 → null）。
  ///
  /// 配对前的 TOFU 比对靠它：**先**拿这个已存值与本次握手所见指纹比，不符就
  /// 当场中止；而不是先把设备名/deviceId 送出去、等 host 都落库了才发现不对。
  Future<String?> getFushiClientFingerprint(String url) async {
    final List<FushiClientUrl> urls = await getFushiClientUrls();
    for (final FushiClientUrl u in urls) {
      if (u.url == url) {
        final String? fp = u.fingerprintSha256;
        return (fp != null && fp.isEmpty) ? null : fp;
      }
    }
    return null;
  }

  /// BUG-1557：清掉某条地址的铉扎指纹（下次配对重新 TOFU）。返回是否真清了。
  ///
  /// [addFushiClientUrl] 的 MITM 守卫故意**绝不覆盖**已存指纹，那就必须给用户一个
  /// 显式的重置入口，否则 host 真换了机器 / 重置了证书时，那条 URL 永远连不上也
  /// 修不好（只能删了重加，而用户根本不知道要那么做）。
  Future<bool> clearFushiClientFingerprint(String url) async {
    bool cleared = false;
    await updateFushiClientUrls((List<FushiClientUrl> urls) {
      final int idx = urls.indexWhere((FushiClientUrl u) => u.url == url);
      if (idx < 0) return urls;
      final FushiClientUrl existing = urls[idx];
      final String? fp = existing.fingerprintSha256;
      if (fp == null || fp.isEmpty) return urls;
      cleared = true;
      // 显式构造而非 copyWith：copyWith 的 `?? this.x` 语义根本清不掉字段。
      return <FushiClientUrl>[...urls]
        ..[idx] = FushiClientUrl(
          url: existing.url,
          enabled: existing.enabled,
          deviceName: existing.deviceName,
          token: existing.token,
          hostId: existing.hostId,
          learned: existing.learned,
          addressKind: existing.addressKind,
          lookupEnabled: existing.lookupEnabled,
        );
    });
    return cleared;
  }

  // ── Device-local key catalog ──────────────────────────────────────

  /// 设备本地的键：导入备份时必须保留在本设备、不能被备份覆盖——后端选择 +
  /// 全部凭据/令牌 + 本机服务器配置 + 互联客户端地址/令牌（含旧单地址键）。从偏好键登记表
  /// 派生（[PrefTrait.deviceLocal]，含 [prefKeyDefs] 与各模块自带的登记），不再手写清单。
  /// `contains(key)` 按生效策略判定（固定键与键族一视同仁），`.keys` / `.families` 是同一个
  /// 集合的枚举形态。
  ///
  /// 故意不在其中：
  /// - 行为开关 `sync_auto_enabled`/`sync_stats_enabled`/`sync_audiobook_enabled`/
  ///   `sync_content_enabled`/`sync_manga_content_enabled` —— 当作用户设置，随备份恢复。
  /// - 内容 `audiobook_pos_*` —— 随备份恢复。
  /// - folder cache `sync_root_folder_id`/`sync_folder_cache` —— 不还原，下次同步重建。
  static final PrefKeySelection deviceLocalPrefKeys = kFushiPrefRegistry.select(
    PrefTrait.deviceLocal,
  );

  /// 设备本地键里更严的一类：描述**本次安装**的一次性判定 / 迁移结论
  /// （[PrefTrait.installScoped]，固定键与键族一视同仁）。
  ///
  /// 和其余设备本地键一样导出时剔除、不进 Profile 快照 / 分享。导入侧更严：导入
  /// 设置的覆盖恢复（含崩溃恢复重放）会把它们**清掉**——外来值是别的机器的结论，
  /// 本机旧值依据的是恢复前的数据，两者都不留，下次启动按恢复后的数据重新判定
  /// （见 `BackupRestoreService._clearInstallScopedPrefs`）。不导入设置的恢复把设置层
  /// 整层写回本机，判定随之保留。旧版本导出的、还带着这些键的包也靠这一步兜住。
  static final PrefKeySelection installScopedPrefKeys = kFushiPrefRegistry
      .select(PrefTrait.installScoped);

  /// 按通道分槽、且属设备本地的键基名（展开进 [deviceLocalPrefKeys]）。
  ///
  /// 不含 `sync_last_sync_ms`：它解耦前就不在设备本地清单里（冷却戳随备份恢复是
  /// 既有行为），拆键不改变这一点。不含 folder 缓存：那本来就是「不还原、下次同步
  /// 重建」的一类（见上面的排除说明）。
  static const List<String> _perChannelDeviceLocalBases = <String>[
    _keyCollectionsBaselineMs,
    _keyDeletionTombstonesBaselineMs,
    _keyVideoMetadataSyncSinceMs,
    _keyStreamVideoPullSinceMs,
    _keyContentSniffCache,
    // 云后端最近一次取到的账号（BUG-4434）：文件箱进度基线按它挑槽；随备份带到
    // 登着别的账号的设备，邮箱缺失时会挑错槽，且把账号邮箱带进备份。
    syncRemoteAccountPrefBase,
  ];

  /// 按通道分槽的「云后端最近一次取到的账号」键基名（BUG-4434）；完整键见
  /// `syncRemoteAccountPrefKey`（`sync_baseline_scope.dart`）。设备本地。
  static const String syncRemoteAccountPrefBase = 'sync_remote_account';

  /// 同步 / 备份域登记的设备本地键（架构重构 F1）：凡是「只对这台设备成立、绝不随备份 /
  /// 设置同步 / Profile 走」的固定键都在这里声明一次，[deviceLocalPrefKeys]、
  /// [installScopedPrefKeys]、`PrefRedactionPolicy`、`ProfileKeys.isExcludedPref` 全部从
  /// 登记表派生。内置浏览器、页面背景、功能模块的键在各自文件里登记。
  ///
  /// BUG-1579：因果基线拆成 per-channel 键后，这里同步登记「基名 × 全部槽位」
  /// （[_perChannelDeviceLocalBases] × [SyncChannelScope.all]）。漏登的后果不是编译错误
  /// 而是静默泄漏——基线会随备份跨设备携带。
  static final List<PrefKeyDef> prefKeyDefs = <PrefKeyDef>[
    // 楽天ブックス书籍检索凭据：用户自己注册的应用凭据，只留在这台设备。
    // 楽天ブックス书籍检索凭据：键名没有 api_key / token 形状，必须点名。也在
    // deviceLocalPrefKeys 中。
    // 楽天ブックス书籍检索凭据。
    PrefKey<String>(
      'book_scrape_rakuten_access_key',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'book_scrape_rakuten_application_id',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 「同步浏览历史」是这台设备的隐私许可：从另一台设备恢复备份不得替这台设备
    // 打开浏览轨迹外流。
    PrefKey.untyped(
      kSyncWebHistoryPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「同步设置」同理是这台设备「接收别处设置」的许可。
    PrefKey.untyped(
      kSyncSettingsEnabledPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 第二块屏启动策略、已同意的副屏与查词显示屏（SecondScreenController 的键）：
    // 描述的是本机硬件，不跟去别的设备。
    PrefKey.untyped(
      'second_screen_mode',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      'second_screen_approved_displays',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      'second_screen_lookup_screen',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 手柄查词模式的开启方式（ControllerLookupStyle）：跟这台设备的手柄走。
    PrefKey.untyped(
      'controller_lookup_style',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // v105 统计按 Profile 隔离：legacy 统计归属 Profile 的值是本库自增 id，
    // 换一台设备就指向别的 Profile，绝不随备份 / Profile 分享出境。
    // v105 统计按 Profile 隔离：legacy 统计家族归属哪个 Profile 是**本库**的
    // 事实（值是本库自增 id），与 active_profile_id 同族。进快照就会被别的
    // Profile 的 applyProfile 剪掉，legacy 历史随即对所有 Profile 可见。
    PrefKey.untyped(
      kStatLegacyProfileIdPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 主进程此刻打开的作品会话（值是本库自增配置 id，只给本机弹窗进程镜像用）。
    // 主进程此刻打开的作品会话（发给弹窗进程镜像）：与 active_profile_id 同族。
    PrefKey<String>(
      kWorkProfileSessionPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 「本版新内容」看到哪个版本：描述这台设备装过的包，跟去别的设备会误判。
    // 「本版新内容」看到哪个版本：描述本机装过的包，与新手引导标志同族。
    PrefKey<String>(
      kWhatsNewSeenVersionPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<int>(
      kWhatsNewSeenSeqPrefKey,
      defaultValue: 0,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<String>(
      kWhatsNewCardDismissedVersionPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 库页「每行数量」：合适的列数取决于这台设备的屏幕（BUG-4219）。
    PrefKey<String?>(
      kLibraryGridColumnsPrefKey,
      defaultValue: null,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 库页布局出厂判定（G1：新安装 = 拼贴 / 升级上来 = 封面网格 + 待弹选择框）：
    // 本设备一次性的判定结论。不进 Profile 快照 / 备份 / 设置同步，导入时保留本机
    // 值——随推荐包或老 Profile 换进来会把新用户重判成老用户（切网格并弹框）。
    // 有意不放进 [installScopedPrefKeys]：那一类导入时会被清掉、下次启动重判，
    // 而重判在已有书库的数据上必然得出「升级上来」。
    PrefKey.untyped(
      ShellLayoutInstallDefault.prefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 书架文件夹导入「缺字幕就转录」：几个小时的设备端推理，跑不跑得动是这台设备
    // 的事（手机上开着、恢复到没有 ASR 算力的机器上不该跟着开）。同组的总开关
    // `audiobook_auto_transcribe` 是同步的，这一个有意设成设备本地。
    PrefKey<bool>(
      PreferencesRepository.audiobookFolderImportTranscribeKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // Android 桌面小组件的默认隐私：描述这台设备的桌面。
    // Android 桌面小组件的默认隐私：描述这台设备的桌面，不随 Profile 走。
    PrefKey<bool>(
      PreferencesRepository.widgetPrivacyHideTitlesKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<bool>(
      PreferencesRepository.widgetPrivacyHideDefinitionsKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<bool>(
      PreferencesRepository.widgetPrivacyHideProfileKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 复习同步 v2 的文件夹存储位置：路径是这台设备的磁盘 / 挂载点，换设备恢复带过去没有意义。
    PrefKey<String>(
      PreferencesRepository.srsFolderLocationsKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 移除了、本机复习内核还没忘掉的位置：描述的是这台设备的内核状态，与上一项同一个事务写。
    PrefKey<String>(
      PreferencesRepository.srsForgetPendingKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 复习同步 v2 里关掉的通道位置：是这台设备「在不在那里同步」的选择，别的设备恢复备份不能替它关 / 开。
    PrefKey<String>(
      PreferencesRepository.srsDisabledLocationsKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 首次 v2 同步的确认是这台设备做的：别的设备恢复备份带过来不能替它确认。
    PrefKey<bool>(
      PreferencesRepository.srsSync2MergeConfirmedKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 复习同步 v2 存储位置的加密密钥：凭据，绝不随备份 / Profile 出境（换设备时重新输入口令）。
    // 复习同步 v2 各存储位置的端到端加密密钥（hex）。
    // 复习同步 v2 各存储位置的集合密钥（hex）。
    PrefKey<String>(
      PreferencesRepository.srsLocationKeysKey,
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.state,
    ),
    // 复习首页「已配对设备」的牌组摘要缓存（kSrsHomePairedCachePrefKey）：描述的是这台设备配对的主机与
    // 上次看到的数字，别的设备恢复备份带过来只会画出它没配对的主机。
    PrefKey.untyped(
      'srs_home_paired_cache',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // BUG-3644 统计同步的 Profile 名字别名：键是本库自增 id，同上。
    // BUG-3644 统计同步的 Profile 名字别名：键是本库自增 id，同族。
    PrefKey.untyped(
      kStudyProfileNameAliasesPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 待确认队列里「忽略」的作品：元素是本机合集自增 id / 书 uid 拼的作品键，
    // 换一台设备就指向别的作品（反馈 Fbchzxuq6f）。
    PrefKey.untyped(
      kVideoScrapeIgnoredWorksPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 书 / 漫画与游戏的同一种忽略（BUG-5283）：键里是本机合集 / 游戏自增 id。
    PrefKey.untyped(
      kBookScrapeIgnoredPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      kGameScrapeIgnoredPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      _keyBackendType,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 云备份通道开关与上一行的后端选择是同一件事的两半——「这台设备走不走云盘、
    // 走哪个」——而凭据本就设备本地。随备份 / 设置同步漂走会出错：只想在电脑上
    // 保留互联的用户一关，手机恢复备份（或收到同步过来的设置）就跟着静默停掉云备份，
    // 而对只靠云盘同步的设备，这等于用同步本身把同步通道切断。
    PrefKey.untyped(
      _keyCloudSyncEnabled,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「新下载任务交给哪台互联 host 执行」指向的是本设备配的 host 地址，随备份
    // 到别的设备只会指错（PC 恢复手机的备份后把任务投给它自己）。
    PrefKey<String>(
      kDownloadExecutionHostPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「允许配对设备远程启动游戏」是本机安全开关：从另一台电脑恢复备份不得替
    // 这台电脑打开远程起进程的门。
    PrefKey<bool>(
      kGameStreamRemoteLaunchPrefKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 串流查词栏尺寸按这台设备的屏幕调：平板上调大的值恢复到手机上只会不合身。
    PrefKey<String>(
      kGameStreamLookupLayoutPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 串流手柄按键映射按这台设备的手柄配：掌机的映射恢复到手机上没有意义。
    PrefKey<String>(
      kGameStreamButtonProfilePrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 串流第二块屏开关按这台设备有没有第二块屏选：掌机的选择恢复到手机上没有意义。
    PrefKey<String>(
      kGameStreamSecondScreenPrefKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // Windows 悬浮字幕窗口矩形存的是本机物理像素坐标：换一台显示器布局 / DPI
    // 不同的设备恢复，窗口会落到屏幕外或尺寸错位。
    PrefKey.untyped(
      kFloatingLyricWindowRectPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 「本机作为制卡落地设备」：换设备恢复备份若把它带过去，就会同时有两台落地设备，
    // 同一张卡被两边各落一次。
    PrefKey.untyped(
      _keyPendingMineLandingClaimedAt,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // Anki 制卡设置：AnkiConnect 地址 / apiKey（明文）/ 本机 Anki 路径都是这台设备的
    // 事实，迁 Drift 之前它活在 SharedPreferences 里，本来就不随备份 / 同步出境。
    // 同形：AnkiSettings JSON 里的 AnkiConnect apiKey 明文。
    // Anki 制卡设置整份 JSON（含 AnkiConnect apiKey）：牌组 / 笔记类型 / 映射等
    // 字段已由 [ankiSettingsToMap] 按字段随 Profile 走；整行进快照的话，切到迁 Drift
    // 之前建的老 Profile 会因「快照里没有这个键」把它删掉，Anki 设置整份清空。
    // （它同时在设备本地名单里，[isExcludedPref] 第一道判定已拦；这里点名防名单漂移。）
    // AnkiSettings JSON 里的 AnkiConnect apiKey（明文）。
    PrefKey.untyped(
      kAnkiSettingsPrefKey,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // （旧键 google_drive_hoshi_compat 已由 fushi_core v72 迁移清行：Hoshi 共享
    // 空间功能删除后它无任何读写方；导入的旧备份库开库时同样被清，故无需再列。）
    PrefKey.untyped(
      _keyDesktopCredentials,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyOneDriveToken,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyDropboxToken,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyWebDavUrl,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyWebDavUsername,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyWebDavPassword,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFtpHost,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFtpPort,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFtpUsername,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFtpPassword,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFtpUseTls,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keySftpHost,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keySftpPort,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keySftpUsername,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keySftpPassword,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keySftpPrivateKey,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyServerEnabled,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyServerPort,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyServerPassword,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyDeviceId,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      _keyLanRequiresPin,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyServerTlsEnabled,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyInterconnectPublicUrls,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // P2P：私钥外带 = 两台设备同一个 NodeId；开关与中继是本机的意愿与网络环境。
    PrefKey.untyped(
      _keyInterconnectP2pEnabled,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyInterconnectP2pSecret,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      _keyInterconnectP2pRelayUrls,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 互联设备钥匙与「我的设备」：私钥外带 = 两台设备共用一个身份；host 侧的标记 /
    // 指纹描述的是**本机**配对表里的 peer，搬到别的设备上毫无意义（还会串号）。
    PrefKey.untyped(
      _keyInterconnectDevicePrivateKey,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      kInterconnectOwnerDevicePeersPref,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      kInterconnectPeerDeviceKeysPref,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      _keyFushiClientUrls,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFushiClientToken,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyFushiClientUrl,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyVideoRemoteLastHostId,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // Jellyfin 服务器绑定含访问令牌，属设备本地凭据，绝不随备份跨设备。旧单值键
    // 与新列表键都列：旧键在迁移前的备份里仍可能存在。
    PrefKey.untyped(
      _keyJellyfinServer,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyJellyfinServers,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「要不要接收 host 的 service-config（外部服务 API key）」是每台设备自己的
    // 信任决策，跨设备携带会把 A 机的选择强加给 B 机。
    PrefKey.untyped(
      _keyInterconnectServiceConfigSync,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 来源共享的收 / 发开关与账本（记的是「这台设备从哪台 host 收下了哪条来源」）：
    // 都只对这台设备成立。
    PrefKey.untyped(
      _keyInterconnectSourceShareSync,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyInterconnectSourceShareHost,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      _keyInterconnectSourceShareHostItems,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      _keyInterconnectSourceSharePlugins,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      'interconnect_source_share_ledger',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 在线源条目同步账本（拍板台 mY5VWg1nD-）：记的是这台设备的库见过哪些在线条目，
    // 随 Profile 快照 / 备份走会让本机删过的条目被建回、或对端新加的建不出来。
    PrefKey.untyped(
      kOnlineLibraryLedgerPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 「当 host 时愿不愿意为对端转码视频」是本机算力的意愿：一台台式机说「可以」，
    // 不代表那台跑着同一份备份的旧笔记本也愿意被烤。
    PrefKey<bool>(
      kInterconnectTranscodeEnabledPref,
      defaultValue: true,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「当 host 时让不让已配对设备用本机的 AI 额度」同理是这台机器主人的决定。
    PrefKey<bool>(
      kInterconnectAiRelayEnabledPref,
      defaultValue: true,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 合集同步因果基线：描述「本设备见过共享清单到什么时刻」，跨设备携带会让
    // 新设备把没见过的墓碑误判成旧闻而复活成员（见 getCollectionsSyncBaselineMs）。
    // 这两条是**解耦前的全局键**：现值仍被 per-channel 读作迁移初值，故照旧不能
    // 跨设备携带；per-channel 槽位由 _perChannelDeviceLocalBases 展开补上。
    PrefKey.untyped(
      _keyCollectionsBaselineMs,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 删除墓碑消费基线：同理设备本地，跨设备携带会让新设备反复弹老墓碑确认框。
    PrefKey.untyped(
      _keyDeletionTombstonesBaselineMs,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 删除墓碑推送基线：同理设备本地，跨设备携带会让新设备以为自己已经把一批删除
    // 推给过一个它从没连过的 host（漏推 = 对端该删的没删）。
    PrefKey.untyped(
      _keyDeletionTombstonesPushBaselineMs,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // TODO-1961：下载保存根与历史根都是**本机绝对路径**（如 D:\downloads），跨设备
    // 恢复必然指向新机不存在的位置。启动校验会回退默认根并警告（不丢数据），但让它
    // 漂过去只会给用户「我明明设过怎么变了」的困惑，故按设备本地处理不随备份携带。
    // TODO-1961: the download folder (and the history of folders we still have
    // to recognise) describes this device's disks, not a reading profile.
    // Snapshotting it would make a profile switch redirect downloads onto a
    // path that may not even exist on this machine.
    PrefKey<String>(
      'download_save_root',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'download_save_root_history',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 发现/下载闭环：第三方 indexer / 字幕服务配置、下载后端路径映射和受管来源
    // 都描述本机能力。跨设备恢复会携带明文凭据、无效绝对路径或错误 source id。
    // JSON 内含 API key / OpenSubtitles 登录密码；名字本身不含 credential 形状，
    // 必须显式点名。
    PrefKey.untyped(
      'video_resource_torznab_config',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'video_subtitle_opensubtitles_config',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 用户 BT 站清单：与 Torznab 同类（第三方 indexer 地址，可能带 passkey）。
    // 同形：用户 BT 站清单，地址里可能带站点 passkey。
    PrefKey.untyped(
      'resource_bt_sites',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 旧内置 BT 站迁移的已跑标记：描述本安装的一次性判定，随备份漂到新装设备会让
    // 新设备跳过判定、漂回老设备会让它重跑，都不对。
    PrefKey.untyped(
      kBtSitesLegacyMigrationPref,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 用户自配的 AI 提供商：条目里带 base64 的 API key，且本地推理服务（Ollama /
    // LM Studio）的地址是 `http://localhost:11434` 这种只对本机成立的端点。跨设备
    // 恢复既泄付费凭据又指向一台并不在跑的服务。功能映射按 provider id 指向它们，
    // 单独漂过去只会变成一堆悬空 id，故一并设备本地。
    // AI 提供商清单：每条里带 base64 的 API key，键名本身没有 api_key/token 形状，
    // 必须显式点名，否则备份/Profile 分享时会把用户的付费 key 旁路带出设备。
    // 每条 AI 提供商记录里带 base64 的 apiKeyB64。
    PrefKey<String>(
      'ai_providers',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'ai_feature_providers',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 多 key 轮换的冷却记录：按本机 key 的指纹索引，换台设备全是悬空记录。
    PrefKey.untyped(
      'ai_key_health',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 联网搜索后端：JSON 内含 Brave API key，SearXNG 地址也可能是本机实例。
    // 同形：联网搜索配置 JSON 里的 Brave API key。
    // 联网搜索配置 JSON 里的 Brave API key。
    PrefKey<String?>(
      'ai_web_search',
      defaultValue: null,
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 「抓搜索结果网页交给 AI」的同意：同意的是这台设备上配的那个后端，跟着它设备本地。
    PrefKey.untyped(
      'ai_web_search_page_fetch',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「AI 助手自主联网搜索」的首次确认：同理跟着这台设备配的后端设备本地。
    PrefKey.untyped(
      'ai_agent_web_search',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「允许已配对设备远程使用 AI 助手」：授权的是这台机器的 AI 指派与操作目录，
    // 只对点它的那台设备成立；漂过去会让另一台设备静默对配对设备开放。
    PrefKey<bool>(
      'ai_agent_for_peers',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // AI 助手在本机还是远端执行：远端指的是这台设备配对的执行设备，换台设备没有意义。
    PrefKey<String>(
      'ai_agent_executor',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 外部 AI 访问（MCP）的开关与配对令牌摘要：授权的是这台机器上的 MCP 客户端，
    // 漂过去会让另一台设备静默对外开放、或让旧令牌在新设备上生效。
    PrefKey<bool>(
      'ai_mcp_enabled',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'ai_mcp_token_sha256',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.state,
    ),
    // AI 助手接入的外部 MCP server：请求头里可能有 token，本地程序的命令与路径只对
    // 这台机器成立；漂到别的设备既泄凭据又会去拉起一个不存在的程序。
    // 同形：外部 MCP server 清单里 base64 的请求头 / 环境变量值（可能是 token）。
    // 外部 MCP server 清单里 base64 的请求头 / 环境变量值（可能是 token）。
    PrefKey<String>(
      'ai_mcp_client_servers',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 音乐输出设备与独占模式描述的是这台机器的声卡 / DAC：别的设备上同名设备不存在，
    // 独占在另一台机器上会让别的程序静默无声。
    PrefKey<String>(
      'music_audio_device',
      defaultValue: 'auto',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<bool>(
      'music_exclusive_output',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // Apple Music 账号连接：授权（Apple ID / Music-User-Token）只在授权的那台设备上存在，
    // 漂过去会让另一台设备显示「已连接」却拿不到 token。
    PrefKey<bool>(
      'music_apple_music_connected',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 漫画 OCR 大模型档位：开了就是「上传漫画页 + 按量计费」，这种同意只对点它的
    // 那台设备成立，漂过去会让另一台配了 AI 的设备静默开始上传。
    PrefKey<String>(
      'manga_ocr_ai_mode',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 视频日语字幕的 AI 校对开关与「会发送什么」的同意：与上一条同理，只对点它的
    // 那台设备成立。分段方式 / MOSS 后端取决于这台机器的显卡，换设备没有意义。
    PrefKey<bool>(
      'video_subtitle_ai_proofread',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<bool>(
      'video_subtitle_ai_consented',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 画面参考（AI 校对时附上视频画面）与它的同意：发图的同意同样只对点它的那台设备成立。
    PrefKey<bool>(
      'video_subtitle_ai_frames',
      defaultValue: true,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<bool>(
      'video_subtitle_ai_frames_consented',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // AI 整理库：自动整理开关、开关时刻与「会发送什么」的同意——与上两条同理只对
    // 点它的那台设备成立（只在一台设备上开就够，结果靠合集同步传播）。
    PrefKey<String>(
      'library_organize_allowed_keys',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<bool>(
      'library_organize_auto',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<int>(
      'library_organize_auto_since',
      defaultValue: 0,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<bool>(
      'library_organize_consented',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // AI 库管家：自动开关与本机运行记录 / 水位——同理只对这台设备成立。
    PrefKey<bool>(
      'library_curate_auto',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'library_curate_state',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // AI 管库自动复查：开关与本机复查水位——同理只对这台设备成立（水位漂过去会让
    // 另一台设备以为已经全库复查过）。
    PrefKey<bool>(
      'library_agent_review_auto',
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'library_agent_review_state',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<String>(
      'video_subtitle_segmenter',
      defaultValue: 'auto',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'video_subtitle_moss_backend',
      defaultValue: 'auto',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 按系列记住的字幕文件夹（0PZAhFd1RO）：值是这台机器上的外部绝对路径，系列键里
    // 是本库自增的合集 id——换台设备路径不存在、id 指向别的合集。
    PrefKey<String>(
      'video_subtitle_series_dirs',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 已删除的「查词自动按句意挑词条」开关（2026-10-09 移除）：存量值仍是
    // 设备本地的计费同意，留在清单里免得旧备份把它漂到别的设备。
    PrefKey.untyped(
      'lookup_ai_context_auto',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 用户自配的 OPDS 书目服务器：条目里带 base64 密码，且服务器地址多是
    // 局域网 IP（`http://192.168.x.x:8080`），跨设备恢复既泄凭据又指向一台
    // 新机根本连不到的主机。
    // 同形：JSON 内含 base64 的 OPDS 服务器密码，键名本身没有 credential 形状。
    // 每条 OPDS 服务器记录里带 base64 的 passwordB64。
    PrefKey<String>(
      'discovery_opds_servers',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 同形：AList / OpenList 站点清单，条目里带 base64 密码。
    // 同形：AList / OpenList 站点清单里的 base64 密码。
    // 每条 AList / OpenList 站点记录里带 base64 的 passwordB64。
    PrefKey<String>(
      'discovery_alist_sites',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 同形：Kavita 服务器清单，条目里带 base64 长期 API key，服务器地址多是局域网 IP。
    // 同形：Kavita 服务器清单里的 base64 长期 API key。
    // 每条 Kavita 服务器记录里带 base64 的长期 API key。
    PrefKey.untyped(
      'kavita_servers',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // Kavita 漫画每章「上次成功同步」时刻：只对这台设备的本地进度有意义，漂到别的
    // 设备会让进度决策的基线错位（把别处的推进误判成冲突或被覆盖）。
    PrefKey.untyped(
      'kavita_manga_sync_state',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 同形：Audiobookshelf 服务器清单，条目里带 base64 令牌（refresh token 会轮换，
    // 两台设备共用一枚只会互相把对方挤下线）。
    // 同形：Audiobookshelf 服务器清单里的 base64 access / refresh token。
    // 每条 Audiobookshelf 服务器记录里带 base64 的 access / refresh token。
    PrefKey<String>(
      'discovery_audiobookshelf_servers',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    // 同形：OpenSubsonic 服务器清单（服务器曲库），条目里带 base64 密码 / API key；
    // 混排开关按这些服务器的 id 记，跟着一起设备本地。
    // 同形：OpenSubsonic 服务器清单（服务器曲库）里的 base64 密码 / API key。
    // 每条 OpenSubsonic 服务器记录里带 base64 的 passwordB64 / apiKeyB64。
    PrefKey<String>(
      'music_subsonic_servers',
      defaultValue: '',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'music_server_library_mix',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 音乐库生成字幕按条目记住的「先分离人声」：键是本机曲库的曲目 / 专辑身份与本库
    // 自增的来源 id，换台设备指向别的条目。
    PrefKey<String>(
      'music_subtitle_vocal_separation',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'video_download_backend_path_mappings',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<int>(
      'video_download_target_source_id',
      defaultValue: 0,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'video_download_embedded_installation_id',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 安装统计（updates/usage_heartbeat.dart）：回退种子 / PoW 缓存随备份漂到另一台设备，
    // 两台设备就可能被算成同一个安装；发不发统计是这台设备上的同意，上次心跳时刻也只对本机有意义。
    PrefKey<bool>(
      'usage_stats_enabled',
      defaultValue: true,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey<String>(
      'usage_stats_install_id',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<String>(
      'usage_stats_install_pow',
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey<int>(
      'usage_stats_last_ping_at',
      defaultValue: 0,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 服务端通知（updates/notice_feed.dart）：缓存的是发给这台设备这份构建的通知，
    // 已弹过的记录也只对本机有意义。
    PrefKey.untyped(
      'notices_cache',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    PrefKey.untyped(
      'notices_seen',
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 书架「仅从本机移除」的远端书：语义就是只对这台设备成立，随备份漂到另一台
    // 设备会让那边的同一份远端书也莫名消失。
    PrefKey<String?>(
      'hidden_remote_books',
      defaultValue: null,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 朗读声音预设：带 base64 的 API key，地址多是本机 / 局域网的 GPT-SoVITS
    // 服务（`http://127.0.0.1:9880`），跨设备带过去只会指向一台不存在的服务。
    // 当前预设 id 指向的就是这份清单里的条目，一起留在本机。
    // 同形：朗读声音预设清单里 base64 的 Azure / Google API key 与网关 Bearer。
    // 每份朗读声音预设里 base64 的 secretsB64（API key / Bearer）。
    PrefKey.untyped(
      'tts_voice_presets',
      policy: PrefPolicy.localCredential,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      'tts_active_preset_id',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 朗读声音按作品记（本书 / 系列 + 语言 → 预设 id）：同样指向上面清单里的条目。
    PrefKey.untyped(
      'tts_media_voices',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 制卡单词音频的 TTS 兜底声音：可能是上面清单里某份预设的 id，一起留在本机。
    // 各配置自己那份按 uid 停放（`mining_tts_fallback_voice::<uid>`，
    // 偏好键登记表的设备本地键族），同样不离开本机。
    PrefKey.untyped(
      'mining_tts_fallback_voice',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // galgame 台词浮窗 TTS 设置：里面的声音也是上面清单里的预设 id。
    PrefKey.untyped(
      'gal_line_tts_settings',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 本机 GPT-SoVITS 整合包的磁盘路径与端口：换一台设备毫无意义。
    PrefKey.untyped(
      'tts_gpt_sovits_local',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 本机 Irodori-TTS-Server 的专属目录与端口：同上。
    PrefKey.untyped(
      'tts_irodori_local',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 「制卡到已配对设备」每台主机的「保存到」：按 hostId 记、指向这台设备配对过的主机，
    // 带到另一台设备上没有意义。
    PrefKey<String>(
      PreferencesRepository.mineToServerTargetsKey,
      defaultValue: '',
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    // 从互联对端下载的有声书当时的内容版本：记的是「这台设备手上是哪一份」，带到别的
    // 设备上会让它误报 / 漏报「对端有更新」。
    PrefKey.untyped(
      kInterconnectAudiobookRevisionsPrefKey,
      policy: PrefPolicy.local,
      kind: PrefKind.state,
    ),
    // 电脑端「缓存其他应用的声音」：开着就常驻录这台机器的系统混音，是这台设备的
    // 录音许可，不能随备份 / 同步在别的设备上被替用户打开。
    PrefKey<bool>(
      PreferencesRepository.crossAppAudioCaptureDesktopKey,
      defaultValue: false,
      policy: PrefPolicy.local,
      kind: PrefKind.setting,
    ),
    PrefKey.untyped(
      PreferencesRepository.srsMiningTargetInstallDefaultKey,
      policy: PrefPolicy.installScopedLocal,
      kind: PrefKind.state,
    ),
    PrefKey<bool>(
      PreferencesRepository.remoteLookupHostSwitchesMigratedKey,
      defaultValue: false,
      policy: PrefPolicy.installScopedLocal,
      kind: PrefKind.state,
    ),
    for (final String base in _perChannelDeviceLocalBases)
      for (final SyncChannelScope scope in SyncChannelScope.all)
        PrefKey.untyped(
          scope.key(base),
          policy: PrefPolicy.local,
          kind: PrefKind.state,
        ),
  ];

  // ── Helpers ───────────────────────────────────────────────────────

  Future<void> _setOrDelete(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _deleteKey(key);
      return;
    }
    await _setString(key, value);
  }

  Future<void> _deleteKey(String key) async {
    await (_db.delete(_db.preferences)..where((t) => t.key.equals(key))).go();
  }

  Future<String?> _getStringOrNull(String key) async {
    final row = await (_db.select(
      _db.preferences,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _setString(String key, String value) async {
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(key: key, value: value),
        );
  }
}
