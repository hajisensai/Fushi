import 'dart:convert';

/// qBittorrent WebUI 连接配置（偏好里存 JSON 字符串，codec 见
/// [decodeQbConnectionConfig] / [encodeQbConnectionConfig]）。
///
/// 范式对齐 `DandanplayConfig`（`preferences_repository.dart` 的
/// `videoDanmakuConfig`）：不可变数据类 + 纯函数 JSON codec，偏好仓库只存原始
/// 字符串，解析在消费端做。
class QbConnectionConfig {
  const QbConnectionConfig({
    this.backend = backendAuto,
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.category = 'hibiki',
    this.downloadLimitKbps = 0,
    this.uploadLimitKbps = 0,
    this.maxConnections = 0,
    this.uploadEnabled = false,
    this.seedTimeLimitMinutes = 0,
    this.seedRatioLimit = 0,
  });

  /// 本应用管理的下载在 qBittorrent 里归入的默认分类名。
  static const String defaultCategory = 'hibiki';

  /// 后端标识：外接 qBittorrent WebUI。
  static const String backendQbittorrent = 'qbittorrent';

  /// 后端标识：内置 libtorrent 引擎（桌面；见 EmbeddedTorrentHost）。
  static const String backendEmbedded = 'embedded';

  /// 后端标识：自动（默认，开箱即用）——桌面用内置引擎、移动端外接 qb。
  /// 用户没显式选过后端时的值。
  static const String backendAuto = 'auto';

  /// 下载后端（[backendAuto] / [backendQbittorrent] / [backendEmbedded]）。
  /// 默认 [backendAuto]，按平台解析（见 [resolveBackend]）。历史配置无此字段
  /// 但配过 qb 地址的，decode 时回退 qb（向后兼容：老用户行为不变）。
  final String backend;

  /// 把 [backendAuto] 解析成具体后端：桌面 → 内置引擎、移动端 → 外接 qb。
  /// 已显式选定（embedded/qbittorrent）的原样返回。
  String resolveBackend({required bool isDesktop}) {
    if (backend == backendAuto) {
      return isDesktop ? backendEmbedded : backendQbittorrent;
    }
    return backend;
  }

  /// WebUI 地址（如 `http://127.0.0.1:8080`）；空 = 未配置。
  final String baseUrl;

  /// WebUI 登录用户名。
  final String username;

  /// WebUI 登录密码。
  final String password;

  /// 下载归入的 qBittorrent 分类（列种子时也按此过滤，默认 [defaultCategory]）。
  final String category;

  /// 内置引擎全局下载限速（KB/s，0 = 不限）。外接 qb 忽略（qb 自有设置）。
  final int downloadLimitKbps;

  /// 内置引擎全局上传限速（KB/s，0 = 不限）。
  final int uploadLimitKbps;

  /// 内置引擎全局最大连接数（0 = 引擎默认）。
  final int maxConnections;

  /// 是否允许上传/做种（默认 [false]，开箱即关，尊重用户带宽/隐私）。首次下载
  /// 时弹窗询问是否开启（见 preferences `torrent_upload_intro_shown`）。仅内置
  /// 引擎生效；外接 qb 由 qb 自身管理上传。
  final bool uploadEnabled;

  /// 做种时长上限（分钟，0 = 不限）。开启上传后，单个种子做种超过该时长即停止
  /// 上传（host tick 在 Dart 侧执行）。仅内置引擎生效。
  final int seedTimeLimitMinutes;

  /// 做种分享率上限（uploaded/downloaded，0 = 不限）。开启上传后，单个种子分享
  /// 率达到该值即停止上传（host tick 在 Dart 侧执行）。仅内置引擎生效。
  final double seedRatioLimit;

  /// 是否已配置：内置引擎/自动无需连接参数恒为真（桌面开箱即用）；外接 qb
  /// 要求 [baseUrl] 非空。未配置时下载入队与完成监听均不动作。
  bool get isConfigured =>
      backend != backendQbittorrent || baseUrl.trim().isNotEmpty;

  QbConnectionConfig copyWith({
    String? backend,
    String? baseUrl,
    String? username,
    String? password,
    String? category,
    int? downloadLimitKbps,
    int? uploadLimitKbps,
    int? maxConnections,
    bool? uploadEnabled,
    int? seedTimeLimitMinutes,
    double? seedRatioLimit,
  }) {
    return QbConnectionConfig(
      backend: backend ?? this.backend,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      category: category ?? this.category,
      downloadLimitKbps: downloadLimitKbps ?? this.downloadLimitKbps,
      uploadLimitKbps: uploadLimitKbps ?? this.uploadLimitKbps,
      maxConnections: maxConnections ?? this.maxConnections,
      uploadEnabled: uploadEnabled ?? this.uploadEnabled,
      seedTimeLimitMinutes: seedTimeLimitMinutes ?? this.seedTimeLimitMinutes,
      seedRatioLimit: seedRatioLimit ?? this.seedRatioLimit,
    );
  }
}

/// 解析 backend 字段（向后兼容）：
/// - 显式 `embedded`/`qbittorrent`/`auto` → 原样
/// - 无字段/未知值：配过 qb 地址（[baseUrl] 非空）→ qbittorrent（老用户不变）；
///   否则 → auto（新用户默认，按平台解析）。
String _decodeBackend(Object? raw, String baseUrl) {
  if (raw == QbConnectionConfig.backendEmbedded) {
    return QbConnectionConfig.backendEmbedded;
  }
  if (raw == QbConnectionConfig.backendQbittorrent) {
    return QbConnectionConfig.backendQbittorrent;
  }
  if (raw == QbConnectionConfig.backendAuto) {
    return QbConnectionConfig.backendAuto;
  }
  return baseUrl.trim().isNotEmpty
      ? QbConnectionConfig.backendQbittorrent
      : QbConnectionConfig.backendAuto;
}

/// JSON 数字字段容错解析为非负 int（null/非数/负数 → 0）。
int _nonNegInt(Object? value) {
  final int n = value is num ? value.toInt() : 0;
  return n < 0 ? 0 : n;
}

/// JSON 数字字段容错解析为非负 double（null/非数/负数/非有限 → 0）。
double _nonNegDouble(Object? value) {
  final double n = value is num ? value.toDouble() : 0;
  return (n.isFinite && n > 0) ? n : 0;
}

/// 解析偏好里存的 JSON 字符串为 [QbConnectionConfig]。纯函数，容错：
/// 空串 / 坏 JSON / 非对象一律返回 null（= 未配置）；`category` 缺失或为空
/// 回退默认分类 [QbConnectionConfig.defaultCategory]。
QbConnectionConfig? decodeQbConnectionConfig(String raw) {
  if (raw.trim().isEmpty) return null;
  try {
    final dynamic json = jsonDecode(raw);
    if (json is! Map) return null;
    final dynamic category = json['category'];
    final String baseUrl =
        json['baseUrl'] is String ? json['baseUrl'] as String : '';
    return QbConnectionConfig(
      backend: _decodeBackend(json['backend'], baseUrl),
      baseUrl: baseUrl,
      username: json['username'] is String ? json['username'] as String : '',
      password: json['password'] is String ? json['password'] as String : '',
      category: category is String && category.isNotEmpty
          ? category
          : QbConnectionConfig.defaultCategory,
      downloadLimitKbps: _nonNegInt(json['downloadLimitKbps']),
      uploadLimitKbps: _nonNegInt(json['uploadLimitKbps']),
      maxConnections: _nonNegInt(json['maxConnections']),
      // 缺字段（老配置）→ false：开箱即关上传，首次下载弹窗再征询开启。
      uploadEnabled: json['uploadEnabled'] == true,
      seedTimeLimitMinutes: _nonNegInt(json['seedTimeLimitMinutes']),
      seedRatioLimit: _nonNegDouble(json['seedRatioLimit']),
    );
  } catch (_) {
    return null;
  }
}

/// 序列化 [QbConnectionConfig] 为 JSON 字符串（与 [decodeQbConnectionConfig]
/// 互逆）。纯函数。
String encodeQbConnectionConfig(QbConnectionConfig config) {
  return jsonEncode(<String, dynamic>{
    'backend': config.backend,
    'baseUrl': config.baseUrl,
    'username': config.username,
    'password': config.password,
    'category': config.category,
    'downloadLimitKbps': config.downloadLimitKbps,
    'uploadLimitKbps': config.uploadLimitKbps,
    'maxConnections': config.maxConnections,
    'uploadEnabled': config.uploadEnabled,
    'seedTimeLimitMinutes': config.seedTimeLimitMinutes,
    'seedRatioLimit': config.seedRatioLimit,
  });
}
