import 'dart:convert';

/// qBittorrent WebUI 连接配置（偏好里存 JSON 字符串，codec 见
/// [decodeQbConnectionConfig] / [encodeQbConnectionConfig]）。
///
/// 范式对齐 `DandanplayConfig`（`preferences_repository.dart` 的
/// `videoDanmakuConfig`）：不可变数据类 + 纯函数 JSON codec，偏好仓库只存原始
/// 字符串，解析在消费端做。
class QbConnectionConfig {
  const QbConnectionConfig({
    this.backend = backendQbittorrent,
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.category = 'hibiki',
  });

  /// 本应用管理的下载在 qBittorrent 里归入的默认分类名。
  static const String defaultCategory = 'hibiki';

  /// 后端标识：外接 qBittorrent WebUI。
  static const String backendQbittorrent = 'qbittorrent';

  /// 后端标识：内置 libtorrent 引擎（桌面；见 EmbeddedTorrentHost）。
  static const String backendEmbedded = 'embedded';

  /// 下载后端（[backendQbittorrent] / [backendEmbedded]）。历史配置无此
  /// 字段时回退 qb（向后兼容：既有用户行为不变）。
  final String backend;

  /// WebUI 地址（如 `http://127.0.0.1:8080`）；空 = 未配置。
  final String baseUrl;

  /// WebUI 登录用户名。
  final String username;

  /// WebUI 登录密码。
  final String password;

  /// 下载归入的 qBittorrent 分类（列种子时也按此过滤，默认 [defaultCategory]）。
  final String category;

  /// 是否已配置（[baseUrl] 非空）；未配置时下载入队与完成监听均不动作。
  bool get isConfigured =>
      backend == backendEmbedded || baseUrl.trim().isNotEmpty;

  QbConnectionConfig copyWith({
    String? backend,
    String? baseUrl,
    String? username,
    String? password,
    String? category,
  }) {
    return QbConnectionConfig(
      backend: backend ?? this.backend,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      category: category ?? this.category,
    );
  }
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
    final dynamic backend = json['backend'];
    return QbConnectionConfig(
      backend: backend == QbConnectionConfig.backendEmbedded
          ? QbConnectionConfig.backendEmbedded
          : QbConnectionConfig.backendQbittorrent,
      baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
      username: json['username'] is String ? json['username'] as String : '',
      password: json['password'] is String ? json['password'] as String : '',
      category: category is String && category.isNotEmpty
          ? category
          : QbConnectionConfig.defaultCategory,
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
  });
}
