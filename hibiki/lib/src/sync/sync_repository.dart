import 'dart:convert';

import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';

/// 触达一台 Hibiki 同步服务器的一个候选地址。同一台服务器通常可经多条路由
/// 触达（局域网、外网），它们共享同一个 token，按列表顺序尝试、第一个可达者胜出。
class FushiClientUrl {
  const FushiClientUrl({
    required this.url,
    this.enabled = true,
    this.fingerprintSha256,
    this.deviceName,
  });

  final String url;
  final bool enabled;

  /// https 端点的证书 SHA-256 指纹钉扎值（aa:bb:.. 形式）。null = 明文 http
  /// 老路径不钉扎（向后兼容）；非 null = https 路径，client 用它做指纹钉扎。
  /// M0 仅落地字段，钉扎接线在 M1。
  final String? fingerprintSha256;

  /// 对端展示名（M0 仅落地，UI/配对在 M1 使用）。
  final String? deviceName;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'enabled': enabled,
        if (fingerprintSha256 != null) 'fingerprintSha256': fingerprintSha256,
        if (deviceName != null) 'deviceName': deviceName,
      };

  factory FushiClientUrl.fromJson(Map<String, dynamic> json) => FushiClientUrl(
        url: json['url'] as String,
        enabled: json['enabled'] as bool? ?? true,
        fingerprintSha256: json['fingerprintSha256'] as String?,
        deviceName: json['deviceName'] as String?,
      );

  /// 复制并覆盖部分字段（不可变更新）。`null` 入参保留原值；要显式清空请直接构造。
  FushiClientUrl copyWith({
    String? url,
    bool? enabled,
    String? fingerprintSha256,
    String? deviceName,
  }) =>
      FushiClientUrl(
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
        fingerprintSha256: fingerprintSha256 ?? this.fingerprintSha256,
        deviceName: deviceName ?? this.deviceName,
      );
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
  static const _keySyncStats = 'sync_stats_enabled';
  static const _keySyncAudioBook = 'sync_audiobook_enabled';
  static const _keySyncDictionary = 'sync_dictionary_enabled';
  static const _keySyncAudioBookFiles = 'sync_audiobook_files_enabled';
  static const _keySyncVideoFiles = 'sync_video_files_enabled';
  static const _keySyncLocalAudio = 'sync_local_audio_enabled';
  static const _keyAutoSync = 'sync_auto_enabled';
  static const _keyLastSyncMs = 'sync_last_sync_ms';
  static const _keyCollectionsBaselineMs = 'sync_collections_baseline_ms';
  // 删除墓碑消费的因果基线：描述「本设备见过远端删除标记到什么时刻」。远端墓碑
  // deletedAt 晚于它才是「新闻」（弹逐条确认），早于它视为本设备已处理过、不再反复弹。
  // 设备本地（[deviceLocalPrefKeys]）：随备份跨设备会让新设备把老墓碑误判为新闻反复弹。
  static const _keyDeletionTombstonesBaselineMs =
      'sync_deletion_tombstones_baseline_ms';
  // 删除墓碑**推送**的因果基线（互联通道专用，与上面的消费基线镜像对称）：描述
  // 「本设备已把删除推给对端 host 到什么时刻」。deletedAt 晚于它的墓碑才需要推。
  //
  // 为什么不复用墓碑行上的 `remotePublishedAt`：那个字段的语义是「已写进云端
  // `__tombstones__` 资产」。互联推送去标它，会让同时配了云备份的设备在云通道
  // `syncDeletionTombstones` 的 `remotePublishedAt == 0` 过滤里永远跳过这条——只连
  // 云的第三台设备就再也收不到这次删除了。两个通道各记各的账。
  //
  // 设备本地（[deviceLocalPrefKeys]）：随备份跨设备会让新设备以为自己已经推过一批
  // 它从没连过的 host。
  static const _keyDeletionTombstonesPushBaselineMs =
      'sync_deletion_tombstones_push_baseline_ms';
  static const _keyDesktopCredentials = 'sync_desktop_credentials';
  static const _keyBackendType = 'sync_backend_type';
  // 「与 Hoshi/ッツ 共享」开关：开启后 Google Drive 后端改用可见 My Drive /
  // ttu-reader-data + 完整 drive scope（[GoogleDriveSyncSpace]）。属设备本地（改的是
  // 本机 Drive 存储空间/scope），不随备份导入覆盖。
  static const _keySyncContent = 'sync_content_enabled';
  // BUG-988：互联通道专属的「上传内容到互联对端」开关，独立于云备份的
  // sync_*_enabled（那套只管云通道）。互联解耦(PR#223)后互联通道曾复用云备份的
  // 共享开关，用户失去「只对互联单独控制上不上传」的能力；这四个键把互联通道的内容
  // 上传拆出来单独控制。默认 false（用户显式 opt-in，不被「启用互联连接」裹挟着自动传）。
  static const _keyInterconnectSyncContent = 'interconnect_sync_content';
  static const _keyInterconnectSyncDictionary = 'interconnect_sync_dictionary';
  static const _keyInterconnectSyncAudioBookFiles =
      'interconnect_sync_audiobook_files';
  static const _keyInterconnectSyncVideoFiles = 'interconnect_sync_video_files';
  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = 'sync_webdav_password';

  static const String syncStatsPreferenceKey = _keySyncStats;
  static const String syncAudioBookPreferenceKey = _keySyncAudioBook;
  static const String syncDictionaryPreferenceKey = _keySyncDictionary;

  // ── Folder cache ──────────────────────────────────────────────────

  Future<String?> getRootFolderId() async {
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(_keyRootFolderId)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setRootFolderId(String? id) async {
    if (id == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyRootFolderId)))
          .go();
      return;
    }
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: _keyRootFolderId, value: id),
        );
  }

  Future<Map<String, String>> getFolderCache() async {
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(_keyFolderCache)))
        .getSingleOrNull();
    if (row == null) return {};
    return Map<String, String>.from(
        jsonDecode(row.value) as Map<String, dynamic>);
  }

  Future<void> setFolderCache(Map<String, String> cache) async {
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(
              key: _keyFolderCache, value: jsonEncode(cache)),
        );
  }

  Future<void> clearFolderCache() async {
    await (_db.delete(_db.preferences)
          ..where((t) => t.key.isIn([_keyRootFolderId, _keyFolderCache])))
        .go();
  }

  // ── Sync settings ─────────────────────────────────────────────────

  Future<bool> isSyncStatsEnabled() =>
      _db.getPrefTyped<bool>(_keySyncStats, true);
  Future<void> setSyncStatsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncStats, v);

  Future<bool> isSyncAudioBookEnabled() async => true;
  Future<void> setSyncAudioBookEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncAudioBook, true);

  Future<bool> isSyncDictionaryEnabled() =>
      _db.getPrefTyped<bool>(_keySyncDictionary, false);
  Future<void> setSyncDictionaryEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncDictionary, v);

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

  /// 是否同步本地音频来源（DB 文件 + 配置）。默认 false：DB 大，需用户显式开启。
  Future<bool> isSyncLocalAudioEnabled() =>
      _db.getPrefTyped<bool>(_keySyncLocalAudio, false);
  Future<void> setSyncLocalAudioEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncLocalAudio, v);

  Future<bool> isAutoSyncEnabled() =>
      _db.getPrefTyped<bool>(_keyAutoSync, false);
  Future<void> setAutoSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyAutoSync, v);

  /// 「与 Hoshi/ッツ 共享 Google Drive」开关。默认关（老用户云端数据留在隐藏
  /// appDataFolder 原地不动）。

  Future<int?> getLastSyncMs() async {
    final s = await _getStringOrNull(_keyLastSyncMs);
    return s == null ? null : int.tryParse(s);
  }

  Future<void> setLastSyncMs(int ms) =>
      _setString(_keyLastSyncMs, ms.toString());

  /// 本端上次**成功**合集同步的毫秒戳（多端库联合视图 §2.3：合集同步引擎的
  /// 因果基线——removedAt/deletedAt 晚于它的墓碑才是「新闻」，早于它的墓碑视为
  /// 本端已裁决过、成员/合集仍在即代表之后重加/重建）。0 = 从未同步过。
  /// 设备本地（[deviceLocalPrefKeys]）：它描述「本设备见过共享清单到什么时刻」，
  /// 随备份跨设备会让新设备把没见过的墓碑误判为旧闻而复活成员。
  Future<int> getCollectionsSyncBaselineMs() async {
    final String? s = await _getStringOrNull(_keyCollectionsBaselineMs);
    return s == null ? 0 : int.tryParse(s) ?? 0;
  }

  Future<void> setCollectionsSyncBaselineMs(int ms) =>
      _setString(_keyCollectionsBaselineMs, ms.toString());

  /// 删除墓碑消费的因果基线（毫秒）。远端删除标记 deletedAt 晚于它才弹逐条确认；
  /// 早于它视为本设备已处理过、不再反复弹。0 = 从未消费过。设备本地
  /// （[deviceLocalPrefKeys]），随备份跨设备会让新设备把老墓碑误判为新闻反复骚扰。
  Future<int> getDeletionTombstonesBaselineMs() async {
    final String? s = await _getStringOrNull(_keyDeletionTombstonesBaselineMs);
    return s == null ? 0 : int.tryParse(s) ?? 0;
  }

  Future<void> setDeletionTombstonesBaselineMs(int ms) =>
      _setString(_keyDeletionTombstonesBaselineMs, ms.toString());

  /// 删除墓碑**推送**的因果基线（毫秒，互联通道专用）。本地墓碑 deletedAt 晚于它才
  /// 推给对端 host；早于它视为本设备已推过、不再重复请求。0 = 从未推送过。
  ///
  /// 单一全局键（不按 host 分）：互联是 host/client 模型且 client 侧后端是单例
  /// [InterconnectSyncBackend.instance]，实际只对一个 host 推送；消费侧基线
  /// （[getDeletionTombstonesBaselineMs]）也是同样的全局口径，两侧保持一致。
  /// 设备本地（[deviceLocalPrefKeys]），理由见键定义处注释。
  Future<int> getDeletionTombstonesPushBaselineMs() async {
    final String? s =
        await _getStringOrNull(_keyDeletionTombstonesPushBaselineMs);
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
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyDesktopCredentials)))
          .go();
      return;
    }
    await _setString(_keyDesktopCredentials, _encodeSecret(json));
  }

  Future<void> clearDesktopSession() async {
    await (_db.delete(_db.preferences)
          ..where((t) => t.key.equals(_keyDesktopCredentials)))
        .go();
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
        return present(await getDesktopCredentials()) ||
            present(await getRootFolderId());
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
      case SyncBackendType.hibikiServer:
        // 互联双向：本机连别人（已填对端地址）或别人连本机（开着服务且有已配对
        // 对端——对端会经 `/api/tombstones` 读走本机墓碑）都算通道存在。
        if ((await getHibikiClientUrls()).isNotEmpty) return true;
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

  /// 一次性幂等迁移：把「互联=互斥的 backendType==hibikiServer 单选」旧模型迁到
  /// 独立的 [isInterconnectEnabled] 开关（互联与云备份不再冲突，可并存）。
  ///
  /// 旧模型里选互联意味着 `sync_backend_type == 'hibikiServer'`（配对设备时也会被
  /// 强写成这个值，见 interconnect UI）。迁移：这类用户置互联开关为 true，并把
  /// backendType 迁到云默认 googleDrive（未认证时云通道自动 no-op），使升级后互联
  /// 照常跑、且不再占着「云后端选择」这个位置。互联自身的持久化字段（serverEnabled
  /// / clientUrls / token 等）本就独立存储，无需搬运。
  ///
  /// 一次性：迁移过一次后（[_keyInterconnectBackendMigrated] 落盘）永远 no-op。
  /// 这点是硬要求而非优化——解耦后用户仍可主动把云备份后端选成互联（互联页的
  /// 「用互联做备份后端」按钮，把备份写到已配对对端而不是云盘）。若迁移继续只看
  /// 「backendType 是不是 hibikiServer」，这个用户选择会在下次启动被当成旧数据
  /// 抹回 googleDrive，按钮变成重启即失效的假开关。
  ///
  /// 必须在任何 [getBackendType]（未知值静默回落 googleDrive）之前、init 期跑一次。
  /// 用原始 key 字符串读取 backendType，独立于枚举符号的存亡。
  Future<void> migrateInterconnectBackendToToggle() async {
    if (await _db.getPrefTyped<bool>(_keyInterconnectBackendMigrated, false)) {
      return;
    }
    final String? backend = await _getStringOrNull(_keyBackendType);
    if (backend == SyncBackendType.hibikiServer.name) {
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

  // ── 互联通道专属上传开关（BUG-988） ────────────────────────────────
  // 只作用于互联通道（[_runSyncChannel] 的 isInterconnect==true），与上面的云备份
  // sync_*_enabled 完全解耦；默认 false，让用户独立控制「要不要把本设备内容上传到
  // 互联对端」，不被「启用互联连接」自动裹挟。位置/统计等轻量进度仍走共享开关（跨设备
  // 续读是互联本意），此处仅拆「重内容」四类：书籍/内容、词典、有声书文件、视频文件。

  Future<bool> isInterconnectSyncContentEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncContent, false);
  Future<void> setInterconnectSyncContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncContent, v);

  Future<bool> isInterconnectSyncDictionaryEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncDictionary, false);
  Future<void> setInterconnectSyncDictionaryEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncDictionary, v);

  Future<bool> isInterconnectSyncAudioBookFilesEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncAudioBookFiles, false);
  Future<void> setInterconnectSyncAudioBookFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncAudioBookFiles, v);

  Future<bool> isInterconnectSyncVideoFilesEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectSyncVideoFiles, false);
  Future<void> setInterconnectSyncVideoFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectSyncVideoFiles, v);

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
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavUrl)))
          .go();
      return;
    }
    await _setString(_keyWebDavUrl, url);
  }

  Future<String?> getWebDavUsername() => _getStringOrNull(_keyWebDavUsername);
  Future<void> setWebDavUsername(String? username) async {
    if (username == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavUsername)))
          .go();
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
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavPassword)))
          .go();
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

  // ── Hibiki Server config ────────────────────────────────────────

  static const _keyInterconnectEnabled = 'sync_interconnect_enabled';

  /// 「旧互联后端 → 独立开关」迁移的一次性完成标记。见
  /// [migrateInterconnectBackendToToggle]：迁移过去靠「backendType 不再是
  /// hibikiServer」当哨兵，于是用户之后主动把备份后端设回互联（互联页的
  /// 「用互联做备份后端」按钮）会在下次启动被迁移当成旧数据再改回 googleDrive。
  /// 用独立标记记「本机已迁移过」，让迁移真正只跑一次。
  static const _keyInterconnectBackendMigrated =
      'sync_interconnect_backend_migrated';
  static const _keyServerEnabled = 'sync_server_enabled';
  static const _keyServerPort = 'sync_server_port';
  static const _keyServerPassword = 'sync_server_password';
  static const _keyDeviceId = 'sync_device_id';
  static const _keyLanRequiresPin = 'sync_lan_requires_pin';
  static const _keyServerTlsEnabled = 'sync_server_tls_enabled';

  /// Single source of truth for the default Hibiki sync-server port.
  /// 38765 is in the IANA User Ports range (1024–49151) but unassigned and
  /// clear of the crowded 8xxx dev-server band and the 49152+ ephemeral range,
  /// so initial bind conflicts are unlikely. Referenced everywhere the default
  /// is needed so the value can never drift between call sites.
  static const int defaultServerPort = 38765;

  /// 互联总开关，独立于 [getBackendType]（云备份后端选择）。为 true 时互联作为
  /// 一条独立的同步/端到端通道运行——连接对端、远端查词/音频/占位卡 live 数据源、
  /// 以及与云备份并行的元数据同步通道——与用户选的云后端并存、互不排斥。
  ///
  /// 历史上互联是 `SyncBackendType.hibikiServer` 这个互斥单选项；已由
  /// [migrateInterconnectBackendToToggle] 迁移到本独立布尔开关。默认 false。
  Future<bool> isInterconnectEnabled() =>
      _db.getPrefTyped<bool>(_keyInterconnectEnabled, false);
  Future<void> setInterconnectEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyInterconnectEnabled, v);

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

  // ── Hibiki Client (connect to another Hibiki instance) ─────────

  static const _keyHibikiClientUrl = 'sync_hibiki_client_url';
  static const _keyHibikiClientUrls = 'sync_hibiki_client_urls';
  static const _keyHibikiClientToken = 'sync_hibiki_client_token';

  /// 旧的单地址 API，仅为向后兼容保留；新代码请用 [getHibikiClientUrls]。
  @Deprecated('Use getHibikiClientUrls / setHibikiClientUrls')
  Future<String?> getHibikiClientUrl() => _getStringOrNull(_keyHibikiClientUrl);
  @Deprecated('Use getHibikiClientUrls / setHibikiClientUrls')
  Future<void> setHibikiClientUrl(String? v) =>
      _setOrDelete(_keyHibikiClientUrl, v);

  /// 有序候选地址列表（下标即优先级）。新键缺失时，从旧的单地址键迁移种子，
  /// 保证老用户无感。
  Future<List<FushiClientUrl>> getHibikiClientUrls() async {
    final raw = await _getStringOrNull(_keyHibikiClientUrls);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(FushiClientUrl.fromJson).toList();
    }
    final legacy = await _getStringOrNull(_keyHibikiClientUrl);
    if (legacy != null && legacy.isNotEmpty) {
      return <FushiClientUrl>[FushiClientUrl(url: legacy)];
    }
    return const <FushiClientUrl>[];
  }

  Future<void> setHibikiClientUrls(List<FushiClientUrl> urls) async {
    if (urls.isEmpty) {
      await _deleteKey(_keyHibikiClientUrls);
      return;
    }
    await _setString(
      _keyHibikiClientUrls,
      jsonEncode(urls.map((FushiClientUrl u) => u.toJson()).toList()),
    );
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
  Future<List<FushiClientUrl>> addHibikiClientUrl(
    String url, {
    String? fingerprint,
    String? deviceName,
  }) async {
    final List<FushiClientUrl> urls = await getHibikiClientUrls();
    final int existingIdx = urls.indexWhere((FushiClientUrl u) => u.url == url);

    final String? incomingFp =
        (fingerprint != null && fingerprint.isNotEmpty) ? fingerprint : null;

    if (existingIdx >= 0) {
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
      final String? nextFp =
          (storedFp != null && storedFp.isNotEmpty) ? storedFp : incomingFp;
      final FushiClientUrl upgraded = existing.copyWith(
        fingerprintSha256: nextFp,
        deviceName: deviceName,
      );
      if (upgraded.fingerprintSha256 == existing.fingerprintSha256 &&
          upgraded.deviceName == existing.deviceName) {
        return urls; // 无变化，避免无谓写盘。
      }
      final List<FushiClientUrl> updated = <FushiClientUrl>[...urls];
      updated[existingIdx] = upgraded;
      await setHibikiClientUrls(updated);
      return updated;
    }

    final List<FushiClientUrl> updated = <FushiClientUrl>[
      ...urls,
      FushiClientUrl(
        url: url,
        fingerprintSha256: incomingFp,
        deviceName: deviceName,
      ),
    ];
    await setHibikiClientUrls(updated);
    return updated;
  }

  /// 指纹相等比较：去冒号、去空白、转小写后逐字符比对（与
  /// hibiki_pinning_http 的归一化同语义，避免 aa:bb vs AABB 误判为不符）。
  static bool _fingerprintEquals(String a, String b) {
    String norm(String s) =>
        s.replaceAll(':', '').replaceAll(RegExp(r'\s'), '').toLowerCase();
    return norm(a) == norm(b);
  }

  Future<String?> getHibikiClientToken() async {
    final encoded = await _getStringOrNull(_keyHibikiClientToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setHibikiClientToken(String? v) async {
    if (v == null) {
      await _deleteKey(_keyHibikiClientToken);
      return;
    }
    await _setString(_keyHibikiClientToken, _encodeSecret(v));
  }

  // ── Device-local key catalog ──────────────────────────────────────

  /// 导入备份时必须保留在本设备、不能被备份覆盖的 preference key：后端选择 +
  /// 全部凭据/令牌 + 本机服务器配置 + Hibiki 客户端地址/令牌（含旧单地址键）。
  ///
  /// 故意排除：
  /// - 行为开关 `sync_auto_enabled`/`sync_stats_enabled`/`sync_audiobook_enabled`/
  ///   `sync_dictionary_enabled`/`sync_content_enabled` —— 当作用户设置，随备份恢复。
  /// - 内容 `audiobook_pos_*` —— 随备份恢复。
  /// - folder cache `sync_root_folder_id`/`sync_folder_cache` —— 不还原，下次同步重建。
  ///
  /// 这是"哪些 key 属于设备本地"的唯一真相源；备份导入只引用本清单，杜绝两处漂移。
  static const List<String> deviceLocalPrefKeys = <String>[
    _keyBackendType,
    // （旧键 google_drive_hoshi_compat 已由 fushi_core v72 迁移清行：Hoshi 共享
    // 空间功能删除后它无任何读写方；导入的旧备份库开库时同样被清，故无需再列。）
    _keyDesktopCredentials,
    _keyOneDriveToken,
    _keyDropboxToken,
    _keyWebDavUrl,
    _keyWebDavUsername,
    _keyWebDavPassword,
    _keyFtpHost,
    _keyFtpPort,
    _keyFtpUsername,
    _keyFtpPassword,
    _keyFtpUseTls,
    _keySftpHost,
    _keySftpPort,
    _keySftpUsername,
    _keySftpPassword,
    _keySftpPrivateKey,
    _keyServerEnabled,
    _keyServerPort,
    _keyServerPassword,
    _keyDeviceId,
    _keyLanRequiresPin,
    _keyServerTlsEnabled,
    _keyHibikiClientUrls,
    _keyHibikiClientToken,
    _keyHibikiClientUrl,
    // 合集同步因果基线：描述「本设备见过共享清单到什么时刻」，跨设备携带会让
    // 新设备把没见过的墓碑误判成旧闻而复活成员（见 getCollectionsSyncBaselineMs）。
    _keyCollectionsBaselineMs,
    // 删除墓碑消费基线：同理设备本地，跨设备携带会让新设备反复弹老墓碑确认框。
    _keyDeletionTombstonesBaselineMs,
    // 删除墓碑推送基线：同理设备本地，跨设备携带会让新设备以为自己已经把一批删除
    // 推给过一个它从没连过的 host（漏推 = 对端该删的没删）。
    _keyDeletionTombstonesPushBaselineMs,
    // TODO-1961：下载保存根与历史根都是**本机绝对路径**（如 D:\downloads），跨设备
    // 恢复必然指向新机不存在的位置。启动校验会回退默认根并警告（不丢数据），但让它
    // 漂过去只会给用户「我明明设过怎么变了」的困惑，故按设备本地处理不随备份携带。
    'download_save_root',
    'download_save_root_history',
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
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setString(String key, String value) async {
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: key, value: value),
        );
  }
}
