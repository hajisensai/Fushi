import 'package:fushi/src/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
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
  /// TMDB/Fanart 刮削、Torznab 索引器、qBittorrent 连接），在他自己的另一台已配对
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
    'qb_connection_config',
    'manga_online_catalog_base_url',
    'manga_online_catalog_enabled',
    // Bangumi 追番同步：令牌 + 账号显示名成对同步（只搬令牌会让子设备 UI 挂着
    // 上一个账号的名字）。令牌变更的对账水位归零见 [applyTo]。
    kBangumiAccessTokenPref,
    kBangumiAccountNamePref,
    // 视频刮削 / 字幕 / 资源索引器的外部服务身份：同一套账号在哪台设备上都该
    // 刮到同一份资料、搜到同一批字幕。
    'video_metadata_bangumi_token',
    'video_scraper_tmdb_api_key',
    'video_metadata_fanart_api_key',
    'video_metadata_douban_authorized_endpoint',
    'video_metadata_douban_authorized_token',
    'video_subtitle_opensubtitles_config',
    'video_resource_torznab_config',
  };

  static final Map<String, String> _defaultRawValues = <String, String>{
    'jimaku_api_key': PrefCodec.encode(''),
    'qb_connection_config': PrefCodec.encode(''),
    'manga_online_catalog_base_url': PrefCodec.encode('https://mokuro.moe'),
    'manga_online_catalog_enabled': PrefCodec.encode(true),
    kBangumiAccessTokenPref: PrefCodec.encode(''),
    kBangumiAccountNamePref: PrefCodec.encode(''),
    'video_metadata_bangumi_token': PrefCodec.encode(''),
    'video_scraper_tmdb_api_key': PrefCodec.encode(''),
    'video_metadata_fanart_api_key': PrefCodec.encode(''),
    'video_metadata_douban_authorized_endpoint': PrefCodec.encode(''),
    'video_metadata_douban_authorized_token': PrefCodec.encode(''),
    'video_subtitle_opensubtitles_config': PrefCodec.encode(''),
    'video_resource_torznab_config': PrefCodec.encode(''),
  };

  /// Raw [PrefCodec] values, kept raw so the client does not double-encode
  /// strings or JSON. Missing host rows are materialized as semantic defaults,
  /// allowing a cleared/rotated key to clear an older child value.
  final Map<String, String> preferences;

  factory InterconnectServiceConfigSnapshot.fromPreferences(
    Map<String, String> allPreferences,
  ) {
    return InterconnectServiceConfigSnapshot._(
      <String, String>{
        for (final String key in sharedPreferenceKeys)
          key: allPreferences[key] ?? _defaultRawValues[key]!,
      },
    );
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
  /// Unknown/missing fields are ignored; a real host snapshot contains every
  /// allowlisted key (including encoded defaults for cleared values).
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
