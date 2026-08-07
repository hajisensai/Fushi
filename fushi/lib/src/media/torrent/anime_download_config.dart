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
    this.category = 'fushi',
    this.downloadLimitKbps = 0,
    this.uploadLimitKbps = 0,
    this.limitLocalPeers = false,
    this.maxConnections = 0,
    this.uploadEnabled = false,
    this.seedTimeLimitMinutes = 0,
    this.seedRatioLimit = 0,
    this.memoryLimitMb = 0,
    this.listenPort = 0,
    this.enableDht = true,
    this.enableLsd = true,
    this.enableUpnp = true,
    this.enableNatpmp = true,
    this.encryptionMode = encryptionPrefer,
    this.anonymousMode = false,
    this.maxActiveDownloads = 0,
    this.maxActiveSeeds = 0,
    this.maxUploadSlots = 0,
    this.antiLeechEnabled = true,
    this.banProgressCheat = false,
    this.banRelativeProgressCheat = false,
    this.maxIpPortCount = 0,
    this.banTimeMinutes = 0,
  });

  /// 加密策略：首选（尝试加密，允许明文回退）。
  static const int encryptionPrefer = 0;

  /// 加密策略：强制（只连加密 peer）。
  static const int encryptionForced = 1;

  /// 加密策略：禁用（只明文）。
  static const int encryptionDisabled = 2;

  /// 本应用管理的下载在 qBittorrent 里归入的默认分类名。
  static const String defaultCategory = 'fushi';

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

  /// 把配置值解析成**本平台真实可用**的后端。
  ///
  /// [isDesktop] = 本平台是否具备内置引擎（调用方传 `_supportsEmbeddedTorrent()`）。
  ///
  /// BUG-1207：这里过去只规约 [backendAuto]，显式的 [backendEmbedded] 一律原样
  /// 放行——于是移动端（Android/iOS 从不构建也从不打包 `libfushi_torrent_ffi.so`：
  /// `native/fushi_torrent/CMakeLists.txt` 只有 WIN32/APPLE 分支，
  /// `hibiki/android/app/build.gradle` 的 externalNativeBuild 只含 fushidicts）
  /// 会解析出一个根本不存在的后端：`EmbeddedTorrentHost.open` 吞掉 `ArgumentError`
  /// 返回 null，`_torrentBackendFor` 静默造一个 `QbTorrentBackend`，而设置页仍显示
  /// 「内置引擎」选中、并把只有内置引擎才读的下载目录暴露给用户改（改了不被任何人
  /// 采用）。规约收在这一处，下游 UI 分支与运行时后端选择的特殊情况一并消失。
  String resolveBackend({required bool isDesktop}) {
    if (!isDesktop) return backendQbittorrent;
    if (backend == backendAuto) return backendEmbedded;
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

  /// 上面两个限速是否**同时作用于局域网 peer**（默认 false = 不作用）。
  ///
  /// libtorrent 的全局限速默认把局域网/回环 peer 放走（它们归 local peer
  /// class，该 class 不受 session 全局上限约束）。默认 false 就是这个原生行为；
  /// 置 true 时 native 会把同一组上限也写到 local peer class。
  final bool limitLocalPeers;

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

  /// 内置引擎内存占用上限（MB，0 = 自动按物理内存推导）。libtorrent 不设限会
  /// 「有多少内存吃多少」；据此推导连接数/磁盘缓冲/peer 列表等设置压住占用。
  /// 仅内置引擎生效。
  final int memoryLimitMb;

  // ---- 内置引擎会话设置（抄 qBittorrent 关键项；均仅内置引擎生效）----

  /// 监听端口（0 = 默认 6881）。
  final int listenPort;

  /// 启用 DHT（公网磁力找 peer 必需）。
  final bool enableDht;

  /// 启用本地服务发现 LSD（局域网找 peer）。
  final bool enableLsd;

  /// 启用 UPnP 端口映射。
  final bool enableUpnp;

  /// 启用 NAT-PMP 端口映射。
  final bool enableNatpmp;

  /// 传输加密策略（[encryptionPrefer] / [encryptionForced] / [encryptionDisabled]）。
  final int encryptionMode;

  /// 匿名模式（不在握手/tracker 暴露客户端指纹与本机 IP；会牺牲部分连通性）。
  final bool anonymousMode;

  /// 最大活跃下载数（0 = 引擎默认）。
  final int maxActiveDownloads;

  /// 最大活跃做种数（0 = 引擎默认）。
  final int maxActiveSeeds;

  /// 最大上传槽位（同时上传的 peer 数，0 = 引擎默认）。
  final int maxUploadSlots;

  /// 启用反吸血（默认开；关掉则不做任何 peer 封禁）。
  final bool antiLeechEnabled;

  /// 反吸血：进度作弊封禁（实喂字节远超自报进度应得量即封，opt-in）。
  final bool banProgressCheat;

  /// 反吸血：相对进度作弊封禁（采样间上传增量远超进度增量即封，opt-in）。
  final bool banRelativeProgressCheat;

  /// 反吸血：同 IP 多端口封禁阈值（超此端口数即封，0 = 关闭该检测）。
  final int maxIpPortCount;

  /// 反吸血：封禁时长（分钟，0 = 永久）。
  final int banTimeMinutes;

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
    bool? limitLocalPeers,
    int? maxConnections,
    bool? uploadEnabled,
    int? seedTimeLimitMinutes,
    double? seedRatioLimit,
    int? memoryLimitMb,
    int? listenPort,
    bool? enableDht,
    bool? enableLsd,
    bool? enableUpnp,
    bool? enableNatpmp,
    int? encryptionMode,
    bool? anonymousMode,
    int? maxActiveDownloads,
    int? maxActiveSeeds,
    int? maxUploadSlots,
    bool? antiLeechEnabled,
    bool? banProgressCheat,
    bool? banRelativeProgressCheat,
    int? maxIpPortCount,
    int? banTimeMinutes,
  }) {
    return QbConnectionConfig(
      backend: backend ?? this.backend,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      category: category ?? this.category,
      downloadLimitKbps: downloadLimitKbps ?? this.downloadLimitKbps,
      uploadLimitKbps: uploadLimitKbps ?? this.uploadLimitKbps,
      limitLocalPeers: limitLocalPeers ?? this.limitLocalPeers,
      maxConnections: maxConnections ?? this.maxConnections,
      uploadEnabled: uploadEnabled ?? this.uploadEnabled,
      seedTimeLimitMinutes: seedTimeLimitMinutes ?? this.seedTimeLimitMinutes,
      seedRatioLimit: seedRatioLimit ?? this.seedRatioLimit,
      memoryLimitMb: memoryLimitMb ?? this.memoryLimitMb,
      listenPort: listenPort ?? this.listenPort,
      enableDht: enableDht ?? this.enableDht,
      enableLsd: enableLsd ?? this.enableLsd,
      enableUpnp: enableUpnp ?? this.enableUpnp,
      enableNatpmp: enableNatpmp ?? this.enableNatpmp,
      encryptionMode: encryptionMode ?? this.encryptionMode,
      anonymousMode: anonymousMode ?? this.anonymousMode,
      maxActiveDownloads: maxActiveDownloads ?? this.maxActiveDownloads,
      maxActiveSeeds: maxActiveSeeds ?? this.maxActiveSeeds,
      maxUploadSlots: maxUploadSlots ?? this.maxUploadSlots,
      antiLeechEnabled: antiLeechEnabled ?? this.antiLeechEnabled,
      banProgressCheat: banProgressCheat ?? this.banProgressCheat,
      banRelativeProgressCheat:
          banRelativeProgressCheat ?? this.banRelativeProgressCheat,
      maxIpPortCount: maxIpPortCount ?? this.maxIpPortCount,
      banTimeMinutes: banTimeMinutes ?? this.banTimeMinutes,
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

/// 布尔字段容错：是 bool 用之，否则（缺字段/老配置）回落 [fallback]。
bool _boolOr(Object? value, bool fallback) => value is bool ? value : fallback;

/// 加密模式容错：0..2 之间用之，否则回落首选（0）。
int _encMode(Object? value) {
  final int n = value is num ? value.toInt() : 0;
  return (n >= 0 && n <= 2) ? n : 0;
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
      // 缺字段（老配置）→ false：保持限速不管局域网的历史行为。
      limitLocalPeers: json['limitLocalPeers'] == true,
      maxConnections: _nonNegInt(json['maxConnections']),
      // 缺字段（老配置）→ false：开箱即关上传，首次下载弹窗再征询开启。
      uploadEnabled: json['uploadEnabled'] == true,
      seedTimeLimitMinutes: _nonNegInt(json['seedTimeLimitMinutes']),
      seedRatioLimit: _nonNegDouble(json['seedRatioLimit']),
      memoryLimitMb: _nonNegInt(json['memoryLimitMb']),
      listenPort: _nonNegInt(json['listenPort']),
      // 网络发现开关缺字段（老配置）→ true（保持既有默认行为）。
      enableDht: _boolOr(json['enableDht'], true),
      enableLsd: _boolOr(json['enableLsd'], true),
      enableUpnp: _boolOr(json['enableUpnp'], true),
      enableNatpmp: _boolOr(json['enableNatpmp'], true),
      encryptionMode: _encMode(json['encryptionMode']),
      anonymousMode: json['anonymousMode'] == true,
      maxActiveDownloads: _nonNegInt(json['maxActiveDownloads']),
      maxActiveSeeds: _nonNegInt(json['maxActiveSeeds']),
      maxUploadSlots: _nonNegInt(json['maxUploadSlots']),
      antiLeechEnabled: _boolOr(json['antiLeechEnabled'], true),
      banProgressCheat: json['banProgressCheat'] == true,
      banRelativeProgressCheat: json['banRelativeProgressCheat'] == true,
      maxIpPortCount: _nonNegInt(json['maxIpPortCount']),
      banTimeMinutes: _nonNegInt(json['banTimeMinutes']),
    );
  } catch (_) {
    return null;
  }
}

/// 序列化 [QbConnectionConfig] 为 JSON 字符串（与 [decodeQbConnectionConfig]

/// Returns the configuration that is actually used by both download UI and
/// background services.
///
/// A missing preference means "use built-in defaults", not "downloads are
/// disabled". Centralising this keeps fresh installs from pushing through the
/// default embedded backend while the completion watcher stays idle.
QbConnectionConfig effectiveTorrentConfig(QbConnectionConfig? stored) =>
    stored ?? const QbConnectionConfig();

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
    'limitLocalPeers': config.limitLocalPeers,
    'maxConnections': config.maxConnections,
    'uploadEnabled': config.uploadEnabled,
    'seedTimeLimitMinutes': config.seedTimeLimitMinutes,
    'seedRatioLimit': config.seedRatioLimit,
    'memoryLimitMb': config.memoryLimitMb,
    'listenPort': config.listenPort,
    'enableDht': config.enableDht,
    'enableLsd': config.enableLsd,
    'enableUpnp': config.enableUpnp,
    'enableNatpmp': config.enableNatpmp,
    'encryptionMode': config.encryptionMode,
    'anonymousMode': config.anonymousMode,
    'maxActiveDownloads': config.maxActiveDownloads,
    'maxActiveSeeds': config.maxActiveSeeds,
    'maxUploadSlots': config.maxUploadSlots,
    'antiLeechEnabled': config.antiLeechEnabled,
    'banProgressCheat': config.banProgressCheat,
    'banRelativeProgressCheat': config.banRelativeProgressCheat,
    'maxIpPortCount': config.maxIpPortCount,
    'banTimeMinutes': config.banTimeMinutes,
  });
}
