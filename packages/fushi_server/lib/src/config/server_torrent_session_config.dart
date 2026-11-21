/// `fushi_server.yaml` 的 `torrent:` 段里内置 libtorrent 引擎的会话设置（BUG-5071）。
///
/// ```yaml
/// torrent:
///   upload_enabled: false        # 关 = 会话级 unchoke 槽位清零 + 已完成种子暂停做种
///   upload_limit_kbps: 0         # 全局上传限速 KB/s（0 = 不限）
///   download_limit_kbps: 0       # 全局下载限速 KB/s（0 = 不限）
///   limit_local_peers: false     # 限速是否也管局域网 peer
///   max_active_downloads: -1     # 同时下载的种子数（-1 = 不限，0 = libtorrent 默认 3）
///   max_active_seeds: 0          # 同时做种的种子数（-1 = 不限，0 = libtorrent 默认 5）
///   max_connections: 0           # 全局连接数上限（0 = 按内存预算推导）
///   seed_ratio_limit: 0          # 分享率上限（0 = 不限；开上传时生效）
///   seed_time_limit_minutes: 0   # 做种时长上限（0 = 不限；开上传时生效）
/// ```
///
/// 全部保存即生效（WebUI / admin API 改完由 [ServerDownloadHost] 重新铺到常驻会话），
/// 不进重启集合。只对内置引擎有意义；外接 qBittorrent 由 qB 自己管。
library;

import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_server/src/server_language.dart';

class ServerTorrentSessionConfig {
  const ServerTorrentSessionConfig({
    this.uploadEnabled = false,
    this.uploadLimitKbps = 0,
    this.downloadLimitKbps = 0,
    this.limitLocalPeers = false,
    this.maxActiveDownloads = defaultMaxActiveDownloads,
    this.maxActiveSeeds = 0,
    this.maxConnections = 0,
    this.seedRatioLimit = 0,
    this.seedTimeLimitMinutes = 0,
  });

  /// 服务端默认不限同时下载数：它是已配对设备借用的 BT 引擎，远程任务交进来
  /// 就该跑；libtorrent 默认的 3 个名额会把其余未完成种子静默挂成 pausedDL
  /// （不连 peer，WebUI 与对端都看不出原因），BUG-5071 线上实测即此。
  static const int defaultMaxActiveDownloads =
      QbConnectionConfig.activeLimitUnlimited;

  /// 是否允许上传 / 做种（默认关）。
  final bool uploadEnabled;

  /// 全局上传限速（KB/s，0 = 不限）。
  final int uploadLimitKbps;

  /// 全局下载限速（KB/s，0 = 不限）。
  final int downloadLimitKbps;

  /// 两个限速是否也作用于局域网 peer（默认否 = libtorrent 原生行为）。
  final bool limitLocalPeers;

  /// 同时下载的种子数（-1 = 不限，0 = libtorrent 默认）。
  final int maxActiveDownloads;

  /// 同时做种的种子数（-1 = 不限，0 = libtorrent 默认）。
  final int maxActiveSeeds;

  /// 全局最大连接数（0 = 按内存预算推导）。
  final int maxConnections;

  /// 分享率上限（0 = 不限）。
  final double seedRatioLimit;

  /// 做种时长上限（分钟，0 = 不限）。
  final int seedTimeLimitMinutes;

  /// 读 `torrent:` 段（[raw] 是整段映射；缺项取默认，非法值拒绝启动并点名键）。
  factory ServerTorrentSessionConfig.fromYaml(Map<dynamic, dynamic> raw) {
    const ServerTorrentSessionConfig d = ServerTorrentSessionConfig();
    return ServerTorrentSessionConfig(
      uploadEnabled:
          _yamlBool(raw['upload_enabled'], 'torrent.upload_enabled') ??
          d.uploadEnabled,
      uploadLimitKbps:
          _yamlInt(raw['upload_limit_kbps'], 'torrent.upload_limit_kbps') ??
          d.uploadLimitKbps,
      downloadLimitKbps:
          _yamlInt(raw['download_limit_kbps'], 'torrent.download_limit_kbps') ??
          d.downloadLimitKbps,
      limitLocalPeers:
          _yamlBool(raw['limit_local_peers'], 'torrent.limit_local_peers') ??
          d.limitLocalPeers,
      maxActiveDownloads:
          _yamlInt(
            raw['max_active_downloads'],
            'torrent.max_active_downloads',
            min: -1,
          ) ??
          d.maxActiveDownloads,
      maxActiveSeeds:
          _yamlInt(
            raw['max_active_seeds'],
            'torrent.max_active_seeds',
            min: -1,
          ) ??
          d.maxActiveSeeds,
      maxConnections:
          _yamlInt(raw['max_connections'], 'torrent.max_connections') ??
          d.maxConnections,
      seedRatioLimit:
          _yamlDouble(raw['seed_ratio_limit'], 'torrent.seed_ratio_limit') ??
          d.seedRatioLimit,
      seedTimeLimitMinutes:
          _yamlInt(
            raw['seed_time_limit_minutes'],
            'torrent.seed_time_limit_minutes',
          ) ??
          d.seedTimeLimitMinutes,
    );
  }

  /// 写进 `torrent:` 段（两格缩进，调用方已写出 `torrent:` 行）。全部键都写出，
  /// 管理员打开配置文件就能看到可调项。
  void writeYaml(StringBuffer b) {
    b.writeln('  upload_enabled: $uploadEnabled');
    b.writeln('  upload_limit_kbps: $uploadLimitKbps');
    b.writeln('  download_limit_kbps: $downloadLimitKbps');
    b.writeln('  limit_local_peers: $limitLocalPeers');
    b.writeln('  max_active_downloads: $maxActiveDownloads');
    b.writeln('  max_active_seeds: $maxActiveSeeds');
    b.writeln('  max_connections: $maxConnections');
    b.writeln('  seed_ratio_limit: $seedRatioLimit');
    b.writeln('  seed_time_limit_minutes: $seedTimeLimitMinutes');
  }

  /// admin API `settings.torrent` 里的会话设置部分（camelCase，与 WebUI 字段键同名）。
  Map<String, Object?> toAdminJson() => <String, Object?>{
    'uploadEnabled': uploadEnabled,
    'uploadLimitKbps': uploadLimitKbps,
    'downloadLimitKbps': downloadLimitKbps,
    'limitLocalPeers': limitLocalPeers,
    'maxActiveDownloads': maxActiveDownloads,
    'maxActiveSeeds': maxActiveSeeds,
    'maxConnections': maxConnections,
    'seedRatioLimit': seedRatioLimit,
    'seedTimeLimitMinutes': seedTimeLimitMinutes,
  };

  /// admin API PUT `settings.torrent` 的增量更新：缺省 / null 的键不改；类型或
  /// 取值不对整个请求 400（[FormatException]），不落半截。
  ServerTorrentSessionConfig mergeAdminJson(
    Map<String, dynamic> body,
  ) => ServerTorrentSessionConfig(
    uploadEnabled: _jsonBool(body, 'uploadEnabled') ?? uploadEnabled,
    uploadLimitKbps: _jsonInt(body, 'uploadLimitKbps') ?? uploadLimitKbps,
    downloadLimitKbps: _jsonInt(body, 'downloadLimitKbps') ?? downloadLimitKbps,
    limitLocalPeers: _jsonBool(body, 'limitLocalPeers') ?? limitLocalPeers,
    maxActiveDownloads:
        _jsonInt(body, 'maxActiveDownloads', min: -1) ?? maxActiveDownloads,
    maxActiveSeeds: _jsonInt(body, 'maxActiveSeeds', min: -1) ?? maxActiveSeeds,
    maxConnections: _jsonInt(body, 'maxConnections') ?? maxConnections,
    seedRatioLimit: _jsonDouble(body, 'seedRatioLimit') ?? seedRatioLimit,
    seedTimeLimitMinutes:
        _jsonInt(body, 'seedTimeLimitMinutes') ?? seedTimeLimitMinutes,
  );

  /// 叠到引擎配置上（[ServerDownloadHost] 的 `_qbConfig` 用）：只覆盖本类管的项，
  /// 端口 / 发现协议 / 加密 / 反吸血等照旧取 [QbConnectionConfig] 默认。
  QbConnectionConfig applyTo(QbConnectionConfig base) => base.copyWith(
    uploadEnabled: uploadEnabled,
    uploadLimitKbps: uploadLimitKbps,
    downloadLimitKbps: downloadLimitKbps,
    limitLocalPeers: limitLocalPeers,
    maxActiveDownloads: maxActiveDownloads,
    maxActiveSeeds: maxActiveSeeds,
    maxConnections: maxConnections,
    seedRatioLimit: seedRatioLimit,
    seedTimeLimitMinutes: seedTimeLimitMinutes,
  );

  @override
  bool operator ==(Object other) =>
      other is ServerTorrentSessionConfig &&
      other.uploadEnabled == uploadEnabled &&
      other.uploadLimitKbps == uploadLimitKbps &&
      other.downloadLimitKbps == downloadLimitKbps &&
      other.limitLocalPeers == limitLocalPeers &&
      other.maxActiveDownloads == maxActiveDownloads &&
      other.maxActiveSeeds == maxActiveSeeds &&
      other.maxConnections == maxConnections &&
      other.seedRatioLimit == seedRatioLimit &&
      other.seedTimeLimitMinutes == seedTimeLimitMinutes;

  @override
  int get hashCode => Object.hash(
    uploadEnabled,
    uploadLimitKbps,
    downloadLimitKbps,
    limitLocalPeers,
    maxActiveDownloads,
    maxActiveSeeds,
    maxConnections,
    seedRatioLimit,
    seedTimeLimitMinutes,
  );

  static Never _bad(String key, Object? value, String zhRule, String enRule) =>
      throw FormatException(
        tr('$key $zhRule，实际 "$value"', '$key $enRule, got "$value"'),
      );

  static bool? _yamlBool(Object? v, String key) {
    if (v == null) return null;
    if (v is bool) return v;
    final String s = '$v'.trim().toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
    _bad(key, v, '只能是 true / false', 'must be true / false');
  }

  static int? _yamlInt(Object? v, String key, {int min = 0}) {
    if (v == null) return null;
    final int? n = v is int ? v : int.tryParse('$v'.trim());
    if (n == null || n < min) {
      _bad(key, v, '必须是 ≥ $min 的整数', 'must be an integer >= $min');
    }
    return n;
  }

  static double? _yamlDouble(Object? v, String key) {
    if (v == null) return null;
    final double? n = v is num ? v.toDouble() : double.tryParse('$v'.trim());
    if (n == null || !n.isFinite || n < 0) {
      _bad(key, v, '必须是 ≥ 0 的数', 'must be a number >= 0');
    }
    return n;
  }

  static bool? _jsonBool(Map<String, dynamic> body, String key) {
    final Object? v = body[key];
    if (v == null) return null;
    if (v is! bool) throw FormatException('torrent.$key must be a boolean');
    return v;
  }

  static int? _jsonInt(Map<String, dynamic> body, String key, {int min = 0}) {
    final Object? v = body[key];
    if (v == null) return null;
    if (v is! num || v != v.roundToDouble() || v < min) {
      throw FormatException('torrent.$key must be an integer >= $min');
    }
    return v.toInt();
  }

  static double? _jsonDouble(Map<String, dynamic> body, String key) {
    final Object? v = body[key];
    if (v == null) return null;
    if (v is! num || !v.isFinite || v < 0) {
      throw FormatException('torrent.$key must be a number >= 0');
    }
    return v.toDouble();
  }
}
