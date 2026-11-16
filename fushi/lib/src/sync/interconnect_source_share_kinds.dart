/// 互联「来源共享」能共享哪些来源、在本机怎么读写（设计见
/// `docs/specs/2026-11-16-interconnect-source-share.md`）。
///
/// 两类：
/// - **服务器来源**（[kSharedServerListKinds]）：用户自配、整份清单存在一个偏好键里的
///   服务器（OPDS / AList·OpenList / Kavita / OpenSubsonic / Jellyfin·Emby·Plex）。共享的
///   是**一条配置**（含账号密码 / API key），按配置 id 合并进对端的清单。
/// - **插件**（[SharedPluginStore]）：已安装的音乐 / 歌词插件与追踪插件包。共享的是
///   **安装包**，不是插件的登录凭据与存储（在包目录之外）。
///
/// 刻意不在内的：Audiobookshelf（refresh token 会轮换，两台设备共用一枚只会互相把对方
/// 挤下线）；SFTP / FTP 网络来源库（Drift 行 + 本机扫描索引，不是一条可移植配置）；
/// 云同步后端自身的凭据（`sync_*`，设备本地）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_registry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_engine/sync/interconnect_source_share.dart';
import 'package:fushi_music/fushi_music.dart';

/// 一条服务器配置规范化后的样子：typed 解码再 `toJson()`，两端对同一份配置得到逐字节相同
/// 的 JSON（摘要据此比较）。
typedef SharedServerEntry = ({
  String id,
  String label,
  Map<String, Object?> json,
});

/// 一类「整份清单存在一个偏好键里」的服务器来源。
final class SharedServerListKind {
  const SharedServerListKind({
    required this.kind,
    required this.prefKey,
    required this.prefCodec,
    required this.decode,
    this.deviceLocalFields = const <String>{},
  });

  /// wire 上的种类名（冻结）。
  final String kind;

  /// 存清单的偏好键（冻结的持久化名，照用不改）。
  final String prefKey;

  /// 值是 [PrefCodec] 编码的字符串（`PreferencesRepository.setPref` 写的）；false =
  /// 原样 JSON（`SyncRepository` 写的媒体服务器清单）。
  final bool prefCodec;

  /// 坏条目返回 null（逐条丢弃，与各清单自己的解码同一口径）。
  final SharedServerEntry? Function(Map<String, Object?> raw) decode;

  /// 只对这台设备成立的字段（例如媒体服务器当前走哪条线路）：不出境、不进摘要，
  /// 用 host 的配置更新本机条目时保留本机的值。
  final Set<String> deviceLocalFields;

  /// 规范化 + 去掉设备本地字段后的条目；坏条目 null。
  SharedServerEntry? normalize(Map<String, Object?> raw) {
    final SharedServerEntry? entry = decode(raw);
    if (entry == null) return null;
    return (
      id: entry.id,
      label: entry.label,
      json: <String, Object?>{
        for (final MapEntry<String, Object?> e in entry.json.entries)
          if (!deviceLocalFields.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// 本机清单的原始条目（保留顺序；不是数组 / 解析失败 = 空）。
  Future<List<Map<String, Object?>>> read(FushiDatabase db) async {
    final String? stored = await db.getPref(prefKey);
    if (stored == null || stored.isEmpty) return const <Map<String, Object?>>[];
    final String raw = prefCodec
        ? PrefCodec.decode<String>(stored, '')
        : stored;
    if (raw.trim().isEmpty) return const <Map<String, Object?>>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <Map<String, Object?>>[];
    }
    if (decoded is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in decoded)
        if (item is Map) item.cast<String, Object?>(),
    ];
  }

  /// 整份写回（与各清单自己的写入同一形状：媒体服务器空清单 = 删键）。
  ///
  /// [cachedWriter] 非 null 时 [prefCodec] 清单经它写（AppModel 装的是
  /// `PreferencesRepository` 的写入：内存缓存与库同一步更新）。这几份清单的设置页
  /// setter 拿内存缓存整表写回；只写库、等整轮同步跑完才刷新缓存的话，这段时间里
  /// 用户改任何一台服务器都会把刚收下的条目抹掉，下一轮还会被当成「本机删了」永久退订。
  Future<void> write(
    FushiDatabase db,
    List<Map<String, Object?>> items, {
    SourceSharePrefWriter? cachedWriter,
  }) async {
    final String json = jsonEncode(items);
    if (prefCodec && cachedWriter != null) {
      await cachedWriter(prefKey, json);
    } else if (prefCodec) {
      await db.setPref(prefKey, PrefCodec.encode(json));
    } else if (items.isEmpty) {
      await db.deletePref(prefKey);
    } else {
      await db.setPref(prefKey, json);
    }
  }
}

String _labelOr(String name, Uri url) =>
    name.trim().isNotEmpty ? name.trim() : url.host;

SharedServerEntry? _tryDecode(SharedServerEntry Function() decode) {
  try {
    return decode();
  } on Object {
    return null;
  }
}

/// 共享的服务器来源（顺序 = 同步摘要里的顺序）。
final List<SharedServerListKind> kSharedServerListKinds =
    List<SharedServerListKind>.unmodifiable(<SharedServerListKind>[
      SharedServerListKind(
        kind: 'opds',
        prefKey: 'discovery_opds_servers',
        prefCodec: true,
        decode: (Map<String, Object?> raw) => _tryDecode(() {
          final OpdsServerConfig c = OpdsServerConfig.fromJson(raw);
          return (
            id: c.id,
            label: _labelOr(c.name, c.catalogUrl),
            json: c.toJson(),
          );
        }),
      ),
      SharedServerListKind(
        kind: 'alist',
        prefKey: 'discovery_alist_sites',
        prefCodec: true,
        decode: (Map<String, Object?> raw) => _tryDecode(() {
          final AListSiteConfig c = AListSiteConfig.fromJson(raw);
          return (
            id: c.id,
            label: _labelOr(c.name, c.baseUrl),
            json: c.toJson(),
          );
        }),
      ),
      SharedServerListKind(
        kind: 'kavita',
        prefKey: kKavitaServersPref,
        prefCodec: true,
        decode: (Map<String, Object?> raw) => _tryDecode(() {
          final KavitaServerConfig c = KavitaServerConfig.fromJson(raw);
          return (
            id: c.id,
            label: _labelOr(c.name, c.serverUrl),
            json: c.toJson(),
          );
        }),
      ),
      SharedServerListKind(
        kind: 'subsonic',
        prefKey: 'music_subsonic_servers',
        prefCodec: true,
        decode: (Map<String, Object?> raw) => _tryDecode(() {
          final SubsonicServerConfig c = SubsonicServerConfig.fromJson(raw);
          return (
            id: c.id,
            label: _labelOr(c.name, c.serverUrl),
            json: c.toJson(),
          );
        }),
      ),
      SharedServerListKind(
        kind: 'mediaServer',
        // 键名带 sync_ / jellyfin 都是历史名（冻结）：Plex 也落在这个数组里。
        prefKey: 'sync_jellyfin_servers',
        prefCodec: false,
        // 当前线路是这台设备连得上哪条地址的选择，换台设备不一定成立。
        deviceLocalFields: const <String>{'activeServerUrl'},
        decode: (Map<String, Object?> raw) {
          final SharedServerEntry? entry = _tryDecode(() {
            final MediaServerConfig? c = decodeMediaServerConfig(raw);
            if (c == null) throw const FormatException('unknown media server');
            final String host =
                Uri.tryParse(c.routeUrls.firstOrNull ?? '')?.host ?? '';
            return (
              id: c.sourceId,
              label: c.accountName.isEmpty ? host : '$host (${c.accountName})',
              json: c.toJson(),
            );
          });
          return entry;
        },
      ),
    ]);

/// 经偏好缓存写一个 [PrefCodec] 偏好（值是未编码的字符串）。
typedef SourceSharePrefWriter = Future<void> Function(String key, String value);

/// 一个已安装插件包在本机的样子。
final class SharedPluginPackage {
  const SharedPluginPackage({
    required this.id,
    required this.label,
    required this.digest,
    required this.signer,
    this.bundled = false,
  }) : available = true;

  /// 目录在、但此刻校验不过（文件正被更新 / 被杀软锁住 / 被改过）：列不出摘要与签名者。
  /// 来源共享对它一律不动——host 侧发 unavailable 条目、client 侧不更新也不删，
  /// 「列不出」不等于「卸载了」。
  const SharedPluginPackage.unavailable({required this.id, required this.label})
    : digest = '',
      signer = null,
      bundled = false,
      available = false;

  final String id;
  final String label;

  /// 包摘要（`files.json` 的 sha256）。
  final String digest;

  /// 签名公钥；未签名 null。
  final String? signer;

  /// 随 app 自带的包（内置 / 预装）：每台设备各有一份，不共享、也不被共享覆盖或卸载。
  final bool bundled;

  final bool available;
}

/// 一类插件在本机的读写面（音乐 / 追踪各一个实现）。
abstract interface class SharedPluginStore {
  /// wire 上的种类名（冻结）。
  String get kind;

  /// 已安装的插件（含 [SharedPluginPackage.bundled] 的；校验不过的以
  /// [SharedPluginPackage.unavailable] 列出，不能漏掉——漏掉会被对端当成卸载）。
  Future<List<SharedPluginPackage>> installed();

  Future<Uint8List?> exportPackage(String id);

  /// 校验待装包（不写盘）；坏包抛。
  Future<SharedPluginPackage> inspect(Uint8List zip);

  Future<void> install(Uint8List zip, String digest);

  Future<void> uninstall(String id);
}

/// 音乐 / 歌词插件（`MusicPluginManager`，`<数据库目录>/music_plugins/`）。
final class MusicSharedPluginStore implements SharedPluginStore {
  const MusicSharedPluginStore(this._manager);

  final MusicPluginManager _manager;

  @override
  String get kind => 'musicPlugin';

  @override
  Future<List<SharedPluginPackage>> installed() async => <SharedPluginPackage>[
    // 只共享本机真装着的包：经互联中继用的插件不在本机，没有包可给。
    for (final InstalledMusicPlugin p in await _manager.listInstalled())
      if (p.info case final MusicPluginPackageInfo info)
        SharedPluginPackage(
          id: p.id,
          label: info.manifest.name,
          digest: info.digest,
          signer: info.signer,
        )
      else
        SharedPluginPackage.unavailable(id: p.id, label: p.id),
  ];

  @override
  Future<Uint8List?> exportPackage(String id) => _manager.exportPackage(id);

  @override
  Future<SharedPluginPackage> inspect(Uint8List zip) async {
    final MusicPluginPackageInfo info = await _manager.inspect(zip);
    return SharedPluginPackage(
      id: info.manifest.id,
      label: info.manifest.name,
      digest: info.digest,
      signer: info.signer,
    );
  }

  @override
  Future<void> install(Uint8List zip, String digest) async {
    await _manager.install(zip, digest);
  }

  @override
  Future<void> uninstall(String id) => _manager.uninstall(id);
}

/// 追踪插件（`TrackingPluginManager`，`<数据库目录>/tracking_plugins/`）。随 app 自带的
/// Bangumi（内置）与 AniList / MangaBaka（预装）标为 bundled。
final class TrackingSharedPluginStore implements SharedPluginStore {
  const TrackingSharedPluginStore(this._manager);

  final TrackingPluginManager _manager;

  @override
  String get kind => 'trackingPlugin';

  @override
  Future<List<SharedPluginPackage>> installed() async => <SharedPluginPackage>[
    for (final InstalledTrackingPlugin p in await _manager.list())
      if (p.info case final TrackingPluginInfo info)
        SharedPluginPackage(
          id: p.id,
          label: info.name,
          digest: info.digest,
          signer: info.signer,
          bundled:
              p.builtIn ||
              p.included ||
              _manager.isBundled(p.id) ||
              _manager.isIncluded(p.id),
        )
      else if (!p.builtIn &&
          !p.included &&
          !_manager.isBundled(p.id) &&
          !_manager.isIncluded(p.id))
        SharedPluginPackage.unavailable(id: p.id, label: p.id),
  ];

  @override
  Future<Uint8List?> exportPackage(String id) => _manager.exportPackage(id);

  @override
  Future<SharedPluginPackage> inspect(Uint8List zip) async {
    final TrackingPluginInfo info = await _manager.inspect(zip);
    return SharedPluginPackage(
      id: info.id,
      label: info.name,
      digest: info.digest,
      signer: info.signer,
      bundled: _manager.isBundled(info.id) || _manager.isIncluded(info.id),
    );
  }

  @override
  Future<void> install(Uint8List zip, String digest) async {
    await _manager.install(zip, digest);
  }

  @override
  Future<void> uninstall(String id) => _manager.uninstall(id);
}

/// 全局装配点：本机此刻可用的插件体系（AppModel 在插件管理器建好后装上；iOS / 原生库不带
/// 插件运行时时对应体系不在列表里——那边经互联中继用对端的插件，不装包）。null = 没有。
List<SharedPluginStore> Function()? sourceSharePluginStores;

/// 全局装配点：服务器来源清单经偏好缓存写回（AppModel 装 `PreferencesRepository`
/// 的写入）。null（单测 / 偏好仓库还没建）= 直接写库。
SourceSharePrefWriter? sourceSharePrefWriter;

/// 一条共享来源的 wire 表示。
InterconnectSharedSource sharedServerSource(
  SharedServerListKind kind,
  SharedServerEntry entry,
) => InterconnectSharedSource(
  kind: kind.kind,
  id: entry.id,
  label: entry.label,
  digest: sourceShareConfigDigest(entry.json),
  config: entry.json,
);
