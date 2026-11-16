/// 互联「来源共享」：已配对、且被 host 主人标为「我的设备」的设备，自动接收 host 上
/// 用户自配的服务器来源（OPDS / AList / Kavita / OpenSubsonic / Jellyfin·Emby·Plex）
/// 与已安装的插件包（音乐 / 歌词插件、追踪插件），设计见
/// `docs/specs/2026-11-16-interconnect-source-share.md`（拍板台 wOMR4_Er7s 方案 a）。
///
/// 本文件只放 wire 形状与 host 侧接口；条目从哪来、怎么落到本机都在 app
/// （`fushi/lib/src/sync/interconnect_source_share_*.dart`）：各来源清单的类型与解码器
/// 住在 app，插件管理器也在 app，引擎只认不透明的条目。
///
/// 路由（安全门与 `service-config` 同级并更严一档，见 `sync_state.part.dart`）：
///
/// ```
/// GET /api/interconnect/source-share                      → InterconnectSourceShareCatalog
/// GET /api/interconnect/source-share/package?kind=&id=    → 插件包 zip（application/zip）
/// ```
///
/// 门：必须 HTTPS、必须 per-peer token、必须是 host 主人标过「我的设备」的 peer
/// （配对审批时选「这是我的设备」或之后在已配对设备里标记）、host 侧开关开着。
/// 载荷带服务器密码 / API key，这几道门缺一不可。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 目录端点。
const String kInterconnectSourceSharePath = '/api/interconnect/source-share';

/// 插件包端点。
const String kInterconnectSourceSharePackagePath =
    '/api/interconnect/source-share/package';

/// `/api/capabilities` 的 `features` 能力位名。
const String kInterconnectSourceShareFeature = 'sourceShare';

/// 插件包大小上限（字节）：插件是几十 KB 的 JS 包，给足余量也拦住异常大的响应。
const int kInterconnectSourceSharePackageMaxBytes = 16 * 1024 * 1024;

/// 一条可共享的来源。
///
/// - 服务器来源：[config] 是这条配置的规范化 JSON（含凭据），[digest] 是它的
///   [sourceShareConfigDigest]；
/// - 插件：[config] 为 null，包另走 [kInterconnectSourceSharePackagePath]；[digest] 是
///   插件包摘要（`files.json` 的 sha256，安装确认时用户确认的就是它），[signer] 是
///   签名公钥（未签名为 null）。
class InterconnectSharedSource {
  const InterconnectSharedSource({
    required this.kind,
    required this.id,
    required this.label,
    required this.digest,
    this.config,
    this.signer,
  });

  /// 来源种类（app 侧登记表的键，例如 `opds`、`musicPlugin`）。
  final String kind;

  /// 种类内的稳定身份（服务器配置的 id / 插件 id）。
  final String id;

  /// 给人看的名字（同步摘要与日志用）。
  final String label;

  final String digest;
  final Map<String, Object?>? config;
  final String? signer;

  /// 账本键：`<kind>/<id>`。
  String get key => '$kind/$id';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'id': id,
    'label': label,
    'digest': digest,
    'config': ?config,
    'signer': ?signer,
  };

  /// 坏条目返回 null（逐条容错：一条坏掉不连累整份目录）。
  static InterconnectSharedSource? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final Object? kind = json['kind'];
    final Object? id = json['id'];
    final Object? label = json['label'];
    final Object? digest = json['digest'];
    final Object? config = json['config'];
    final Object? signer = json['signer'];
    if (kind is! String || kind.isEmpty) return null;
    if (id is! String || id.isEmpty) return null;
    if (digest is! String || digest.isEmpty) return null;
    if (config != null && config is! Map) return null;
    if (signer != null && signer is! String) return null;
    return InterconnectSharedSource(
      kind: kind,
      id: id,
      label: label is String ? label : id,
      digest: digest,
      config: config is Map ? config.cast<String, Object?>() : null,
      signer: signer as String?,
    );
  }
}

/// host 此刻愿意共享的全部来源。
class InterconnectSourceShareCatalog {
  const InterconnectSourceShareCatalog(this.sources);

  static const int schemaVersion = 1;

  final List<InterconnectSharedSource> sources;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'sources': <Map<String, Object?>>[
      for (final InterconnectSharedSource s in sources) s.toJson(),
    ],
  };

  /// 版本不认识抛 [FormatException]；同一 `kind/id` 重复时后来者丢弃。
  factory InterconnectSourceShareCatalog.fromJson(Map<String, Object?> json) {
    final Object? raw = json['sources'];
    if (json['schemaVersion'] != schemaVersion || raw is! List) {
      throw const FormatException('Unsupported source share catalog');
    }
    final Set<String> seen = <String>{};
    return InterconnectSourceShareCatalog(<InterconnectSharedSource>[
      for (final Object? item in raw)
        if (InterconnectSharedSource.tryFromJson(item)
            case final InterconnectSharedSource s when seen.add(s.key))
          s,
    ]);
  }
}

/// host 侧能力（app 装配；无头服务端不装配 → 端点 404）。
abstract interface class InterconnectSourceShareHost {
  /// host 侧开关「把来源共享给我的设备」。
  Future<bool> isSourceShareEnabled();

  /// [peerToken] 是否是 host 主人标过「我的设备」的已配对 peer。
  Future<bool> isOwnerDevicePeer(String peerToken);

  Future<InterconnectSourceShareCatalog> sourceShareCatalog();

  /// 插件 [kind] / [id] 的安装包；不共享 / 不存在为 null。
  Future<Uint8List?> sourceSharePackage(String kind, String id);
}

/// 服务器配置的摘要：键排序后的规范 JSON 的 sha256（两端对同一份配置算出同一个值）。
String sourceShareConfigDigest(Map<String, Object?> config) =>
    sha256.convert(utf8.encode(_canonicalJson(config))).toString();

String _canonicalJson(Object? value) {
  if (value is Map) {
    final List<String> keys = <String>[
      for (final Object? k in value.keys) k.toString(),
    ]..sort();
    return '{${<String>[for (final String k in keys) '${jsonEncode(k)}:${_canonicalJson(value[k])}'].join(',')}}';
  }
  if (value is List) {
    return '[${<String>[for (final Object? v in value) _canonicalJson(v)].join(',')}]';
  }
  return jsonEncode(value);
}
