import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// Host-owned service configuration that a paired child may import over the
/// authenticated interconnect channel.
///
/// This is intentionally a small allowlist, not a general preferences backup.
/// Device identity, pairing credentials, local paths, inbound API passwords and
/// media-source secrets must never enter this payload.
class InterconnectServiceConfigSnapshot {
  InterconnectServiceConfigSnapshot._(this.preferences);

  static const int schemaVersion = 1;

  /// Preferences that describe external services shared by the user's devices.
  ///
  /// 判据是**这条配置描述的是「外部服务」还是「本机」**，不是「它像不像凭据」：
  /// 用户在一台设备上配好的第三方服务账号（Bangumi 追番、Jimaku、OpenSubtitles、
  /// AniDB/TMDB 刮削、Torznab 索引器、qBittorrent 连接），在他自己的另一台已配对
  /// 设备上就应该照样能用——否则「互联」只搬内容不搬能力，用户得在每台设备上重填
  /// 一遍同一个 token。本通道是**已配对 + 已认证**的点对点链路，对端是用户自己的
  /// 设备，与备份 zip 落第三方云盘、Profile 分享 JSON 给别人是不同的出境等级
  /// （那两条仍由 [PrefRedactionPolicy] 全量剔除，本清单不影响它们）。
  ///
  /// 仍然**绝不**进这个 payload 的三类：
  /// - `yomitan_api_key`：它保护的是**本机**入站 API，不是外部服务身份；
  /// - `media_source_secret_*`、`sync_*`：网络来源密码/私钥与配对凭据，属设备本地；
  /// - 设备身份与本地路径（device_id、端口、下载根、因果基线等）。
  static const Set<String> sharedPreferenceKeys = <String>{
    'jimaku_api_key',
    // 启用开关必须跟着 key 一起搬：只搬 key 不搬开关，子设备会拿到一把
    // 配好却处于关闭状态的 key——正是本清单文档里说的「只搬内容不搬能力」。
    'jimaku_enabled',
    'qb_connection_config',
    'manga_online_catalog_base_url',
    'manga_online_catalog_enabled',
    // Bangumi 追番同步：令牌 + 账号显示名成对同步（只搬令牌会让子设备 UI 挂着
    // 上一个账号的名字）。令牌变更的对账水位归零见 [applyTo]。
    kBangumiAccessTokenPref,
    kBangumiAccountNamePref,
    // 视频刮削 / 字幕 / 资源索引器的外部服务身份：同一套账号在哪台设备上都该
    // 刮到同一份资料、搜到同一批字幕。
    kVideoMetadataAniDbClientNamePref,
    kVideoMetadataAniDbClientVersionPref,
    'video_scraper_tmdb_api_key',
    'video_subtitle_opensubtitles_config',
    // SubDL：key + 开关成对搬（同 jimaku 那对的理由）。
    'video_subtitle_subdl_api_key',
    'video_subtitle_subdl_enabled',
    'video_resource_torznab_config',
    // 用户 BT 站：与 Torznab 同一类「资源索引器的外部服务身份」，主设备配好、
    // 子设备同样能搜。
    'resource_bt_sites',
  };

  static final Map<String, String> _defaultRawValues = <String, String>{
    'jimaku_api_key': PrefCodec.encode(''),
    'jimaku_enabled': PrefCodec.encode(true),
    'qb_connection_config': PrefCodec.encode(''),
    'manga_online_catalog_base_url': PrefCodec.encode('https://mokuro.moe'),
    'manga_online_catalog_enabled': PrefCodec.encode(true),
    kBangumiAccessTokenPref: PrefCodec.encode(''),
    kBangumiAccountNamePref: PrefCodec.encode(''),
    kVideoMetadataAniDbClientNamePref: PrefCodec.encode(''),
    kVideoMetadataAniDbClientVersionPref: PrefCodec.encode(''),
    'video_scraper_tmdb_api_key': PrefCodec.encode(''),
    'video_subtitle_opensubtitles_config': PrefCodec.encode(''),
    'video_subtitle_subdl_api_key': PrefCodec.encode(''),
    'video_subtitle_subdl_enabled': PrefCodec.encode(true),
    'video_resource_torznab_config': PrefCodec.encode(''),
    'resource_bt_sites': PrefCodec.encode(''),
  };

  /// 只在 host **真有这一行**时才放进快照的键：凭据与配置清单。
  ///
  /// 这些键清空时一律写一行空值（`setPref('')` / 空 JSON 数组 `[]`），而且都属设备
  /// 本地 / 凭据，Profile 切换的剪枝碰不到它们——所以 host 上**没有这一行** = host
  /// 从没配过，不是「清空了」。把缺行物化成默认值发出去，会把子设备自己配好的
  /// BT 站 / Torznab / API key 清掉（旧版本 host、或 host 上从没配过的用户都会触发）。
  /// 显式清空（有行、值为空）照常随快照下发、清掉子设备的旧值。
  static const Set<String> _rowRequiredKeys = <String>{
    'jimaku_api_key',
    'qb_connection_config',
    kBangumiAccessTokenPref,
    'video_scraper_tmdb_api_key',
    'video_subtitle_opensubtitles_config',
    'video_subtitle_subdl_api_key',
    'video_resource_torznab_config',
    'resource_bt_sites',
  };

  /// 跟着另一个键一起出现 / 缺席的键（成对同步）：Bangumi 账号显示名跟令牌走——
  /// 令牌没下发时名字也不下发，否则子设备留着自己的令牌、名字却被清成空。
  static const Map<String, String> _companionOf = <String, String>{
    kBangumiAccountNamePref: kBangumiAccessTokenPref,
  };

  /// Raw [PrefCodec] values, kept raw so the client does not double-encode
  /// strings or JSON.
  ///
  /// 缺行的处理分两类：普通开关 / 标量设置缺行 = 用户在用默认值（Profile 切换的
  /// 剪枝会删掉这类行），物化成默认值下发；[_rowRequiredKeys] 缺行 = host 从没配过，
  /// 整个键不下发，客户端 [applyTo] 对缺席的键什么都不做（旧版本 host 不认识的键同理）。
  final Map<String, String> preferences;

  factory InterconnectServiceConfigSnapshot.fromPreferences(
    Map<String, String> allPreferences,
  ) {
    bool exported(String key) {
      final String? companion = _companionOf[key];
      if (companion != null) return exported(companion);
      return !_rowRequiredKeys.contains(key) || allPreferences.containsKey(key);
    }

    return InterconnectServiceConfigSnapshot._(<String, String>{
      for (final String key in sharedPreferenceKeys)
        if (exported(key)) key: allPreferences[key] ?? _defaultRawValues[key]!,
    });
  }

  factory InterconnectServiceConfigSnapshot.fromJson(
    Map<String, Object?> json,
  ) {
    final Object? rawPreferences = json['preferences'];
    if (json['schemaVersion'] != schemaVersion || rawPreferences is! Map) {
      throw const FormatException('Unsupported service config snapshot');
    }
    final Map<String, String> accepted = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in rawPreferences.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is! String ||
          value is! String ||
          !sharedPreferenceKeys.contains(key)) {
        continue;
      }
      accepted[key] = value;
    }
    return InterconnectServiceConfigSnapshot._(accepted);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'preferences': preferences,
  };

  /// Applies only changed allowlisted rows. Returns the number of rows changed.
  ///
  /// Unknown/missing fields are ignored: a missing key means the host has
  /// nothing to say about it (never configured there, or an older host that
  /// does not know the key), so the local value stays as is. An explicitly
  /// cleared value arrives as an encoded empty value and is applied.
  ///
  /// Bangumi 令牌换人时同时归零本设备的对账水位
  /// （[kBangumiTokenScopedWatermarkPrefs]），与设置页写令牌那条路径共用同一条
  /// 不变式：不归零，子设备就永远不会把「换账号之前看完的条目」推给新账号。
  /// 水位归零本身不计入返回值——它是令牌那一行的副作用，不是导入的一条配置。
  Future<int> applyTo(FushiDatabase db) async {
    int changed = 0;
    bool bangumiTokenChanged = false;
    for (final MapEntry<String, String> entry in preferences.entries) {
      if (!sharedPreferenceKeys.contains(entry.key)) continue;
      if (await db.getPref(entry.key) == entry.value) continue;
      await db.setPref(entry.key, entry.value);
      if (entry.key == kBangumiAccessTokenPref) bangumiTokenChanged = true;
      changed++;
    }
    if (bangumiTokenChanged) {
      for (final String key in kBangumiTokenScopedWatermarkPrefs) {
        await db.setPref(key, PrefCodec.encode(0));
      }
    }
    return changed;
  }
}

/// Optional host capability kept separate from [FushiLibraryHostService]'s
/// large media interface so older/test host implementations remain compatible.
abstract interface class InterconnectServiceConfigHost {
  Future<InterconnectServiceConfigSnapshot> getInterconnectServiceConfig();
}
