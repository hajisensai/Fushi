/// 互联 host 远程更新（反馈 Pp8XPyve0N）：已配对 client 查看 host 的 app 版本、
/// 让 host 自己去下载并安装更新。
///
/// 只有协议与 host 侧的门禁住在引擎里（纯 Dart，无 Flutter）；「怎么查更新 / 怎么
/// 下载安装」是各平台 app 的现有自更新流程，由装配方实现 [HostSelfUpdater] 注入
/// （app 侧见 `fushi/lib/src/updates/host_self_update_service.dart`）。无头服务端
/// 不接线——端点 404、能力位 `hostUpdate=false`。
///
/// 安全边界（端点在 `FushiSyncServer` 的 `/api/host/update`）：
///   * 只认**已配对 peer token**（共享 server token 一律拒，同 service-config）；
///   * 触发（POST）只接受局域网信任区：P2P 隧道 / 公网来源一律拒；
///   * 触发要带 GET 刚签发的一次性 nonce（绑定发起者的 token，单次消费、短 TTL），
///     捕获的请求不能重放，也没有「凭一条 URL / 表单就能触发」的 CSRF 面；
///   * host 用户开关「允许已配对设备远程更新本机」默认关，关着回 403 + 明确原因；
///   * 每次触发 / 拒绝都留痕（engineLog 诊断）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 端点路径（GET = 状态 + 一次性 nonce；POST = 触发更新）。
const String kHostUpdatePath = '/api/host/update';

/// host 侧更新流程所处的阶段（wire 值即枚举名）。
enum HostUpdatePhase {
  /// 没有在跑更新。
  idle,

  /// 正在下载更新包。
  downloading,

  /// 下载完成，正在交给平台安装器。
  installing,

  /// Android：安装器已在 host 设备上弹出（或需要先授予「安装未知应用」权限），
  /// 必须有人在 host 上确认；client 只能等。可以再触发一次（重新弹出安装确认，
  /// 已下载的安装包会被复用）。
  ///
  /// 桌面没有对应阶段：安装器接班后 host 进程直接退出，client 看到的是连接断开、
  /// 重连后版本号变了。
  awaitingHostConfirmation,

  /// 本轮更新失败（[HostUpdateStatus.error] 带原因）。
  failed;

  /// 这个阶段是否表示「更新正在进行、不能再触发一次」。
  bool get isBusy => this == downloading || this == installing;

  static HostUpdatePhase fromWire(Object? raw) {
    for (final HostUpdatePhase phase in HostUpdatePhase.values) {
      if (phase.name == raw) return phase;
    }
    return HostUpdatePhase.idle;
  }
}

/// host 拒绝远程更新请求的原因（wire 值见 [code]）。client 据此给出可读原因。
enum HostUpdateDenial {
  /// host 上「允许已配对设备远程更新本机」开关关着。
  disabled('remote_update_disabled'),

  /// host 平台不能应用内自更新（iOS / Linux 等）。
  unsupported('platform_unsupported'),

  /// 请求来自 P2P 隧道或公网，不在允许触发的信任区内。
  zone('zone_not_allowed'),

  /// 没有带已配对设备的专属 token（老的共享 token 不收）。
  peerTokenRequired('peer_token_required'),

  /// nonce 缺失 / 过期 / 已用过 / 不属于这个 peer。
  invalidNonce('invalid_nonce'),

  /// 已经有一轮更新在跑。
  busy('update_in_progress'),

  /// host 查过了，没有可装的新版本。
  noUpdate('no_update');

  const HostUpdateDenial(this.code);

  final String code;

  static HostUpdateDenial? fromCode(Object? raw) {
    for (final HostUpdateDenial d in HostUpdateDenial.values) {
      if (d.code == raw) return d;
    }
    return null;
  }

  /// 对应的 HTTP 状态码。
  int get httpStatus => switch (this) {
    HostUpdateDenial.busy || HostUpdateDenial.noUpdate => 409,
    HostUpdateDenial.invalidNonce => 400,
    _ => 403,
  };
}

/// host 回给 client 的版本与更新状态快照。
class HostUpdateStatus {
  const HostUpdateStatus({
    required this.currentVersion,
    required this.platform,
    required this.supported,
    required this.remoteUpdateAllowed,
    this.latestVersion,
    this.phase = HostUpdatePhase.idle,
    this.progress,
    this.error,
    this.nonce,
  });

  /// host 当前运行的 app 版本。
  final String currentVersion;

  /// host 平台（`Platform.operatingSystem` 口径：android / windows / macos ...）。
  final String platform;

  /// host 平台能否应用内自更新（平台门，判据只在 host 装配方写一次）。
  final bool supported;

  /// host 用户开关「允许已配对设备远程更新本机」。
  final bool remoteUpdateAllowed;

  /// host 查到的可装新版本；null = 已是最新或尚未查到。
  final String? latestVersion;

  final HostUpdatePhase phase;

  /// 下载进度 0..1（只在 [HostUpdatePhase.downloading] 有意义）。
  final double? progress;

  /// [HostUpdatePhase.failed] 时的原因；`install_permission` 表示 Android 需要先在
  /// host 上授予「安装未知应用」权限。
  final String? error;

  /// 本次 GET 签发的一次性触发 nonce（只出现在 GET 响应里）。
  final String? nonce;

  bool get updateAvailable => latestVersion != null;

  /// 「可以在 client 上点更新」：平台支持 + 开关开 + 有新版本 + 没在跑。
  bool get canTrigger =>
      supported && remoteUpdateAllowed && updateAvailable && !phase.isBusy;

  HostUpdateStatus copyWith({
    String? latestVersion,
    bool clearLatestVersion = false,
    HostUpdatePhase? phase,
    double? progress,
    bool clearProgress = false,
    String? error,
    bool clearError = false,
    String? nonce,
    bool? remoteUpdateAllowed,
  }) {
    return HostUpdateStatus(
      currentVersion: currentVersion,
      platform: platform,
      supported: supported,
      remoteUpdateAllowed: remoteUpdateAllowed ?? this.remoteUpdateAllowed,
      latestVersion: clearLatestVersion
          ? null
          : (latestVersion ?? this.latestVersion),
      phase: phase ?? this.phase,
      progress: clearProgress ? null : (progress ?? this.progress),
      error: clearError ? null : (error ?? this.error),
      nonce: nonce ?? this.nonce,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'currentVersion': currentVersion,
    'platform': platform,
    'supported': supported,
    'remoteUpdateAllowed': remoteUpdateAllowed,
    if (latestVersion != null) 'latestVersion': latestVersion,
    'phase': phase.name,
    if (progress != null) 'progress': progress,
    if (error != null) 'error': error,
    if (nonce != null) 'nonce': nonce,
  };

  /// 解析 host 响应；结构不对抛 [FormatException]。
  static HostUpdateStatus fromJson(Map<String, Object?> json) {
    final Object? version = json['currentVersion'];
    if (version is! String) {
      throw const FormatException('host update status: missing version');
    }
    final Object? progress = json['progress'];
    final Object? latest = json['latestVersion'];
    final Object? error = json['error'];
    final Object? nonce = json['nonce'];
    return HostUpdateStatus(
      currentVersion: version,
      platform: json['platform'] is String ? json['platform']! as String : '',
      supported: json['supported'] == true,
      remoteUpdateAllowed: json['remoteUpdateAllowed'] == true,
      latestVersion: latest is String && latest.isNotEmpty ? latest : null,
      phase: HostUpdatePhase.fromWire(json['phase']),
      progress: progress is num ? progress.toDouble() : null,
      error: error is String ? error : null,
      nonce: nonce is String && nonce.isNotEmpty ? nonce : null,
    );
  }
}

/// host 拒绝触发时抛出（[startUpdate] 用它报 busy / noUpdate；client 解析错误响应
/// 时也用它承载原因）。
class HostUpdateRejected implements Exception {
  const HostUpdateRejected(this.denial, {this.statusCode});

  final HostUpdateDenial denial;
  final int? statusCode;

  @override
  String toString() => 'HostUpdateRejected(${denial.code})';
}

/// host 侧自更新的装配点：查状态、触发更新。实现方是各平台 app 的现有自更新流程。
abstract interface class HostSelfUpdater {
  /// 平台门：本机能否应用内自更新。
  bool get platformSupported;

  /// host 用户开关「允许已配对设备远程更新本机」。
  Future<bool> isRemoteUpdateAllowed();

  /// 当前状态；[refresh] 为 true 时先（节流地）去更新源查一次最新版本。
  Future<HostUpdateStatus> status({bool refresh = false});

  /// 开始一轮更新（立即返回，下载 / 安装在后台继续，进度经 [status] 读）。
  /// 已在跑 → [HostUpdateDenial.busy]；查不到新版本 → [HostUpdateDenial.noUpdate]，
  /// 两者都以 [HostUpdateRejected] 抛出。
  Future<HostUpdateStatus> startUpdate();
}

/// 一次性触发 nonce 的签发与核销。纯内存，server 重启即清空（半截请求作废，安全侧）。
///
/// nonce 绑定发起 GET 的 peer（[peerKey] = 它 token 的摘要），别的 peer 拿到也用不了；
/// 核销即作废（无论后续是否成功），过期的不收；同时在途数有上限，超了先淘汰最旧的。
class HostUpdateNonceStore {
  HostUpdateNonceStore({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 2),
    this.capacity = 32,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final DateTime Function() _now;
  final Random _random;
  final Duration ttl;
  final int capacity;

  final Map<String, ({String peerKey, DateTime expiresAt})> _issued =
      <String, ({String peerKey, DateTime expiresAt})>{};

  /// 给 [peerKey] 签发一个新 nonce。
  String issue(String peerKey) {
    _prune();
    while (_issued.length >= capacity) {
      _issued.remove(_issued.keys.first);
    }
    final String nonce = base64Url
        .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _issued[nonce] = (peerKey: peerKey, expiresAt: _now().add(ttl));
    return nonce;
  }

  /// 核销：nonce 存在、未过期、属于 [peerKey] 才返回 true。不论结果，命中的条目都作废。
  bool consume(String? nonce, String peerKey) {
    if (nonce == null || nonce.isEmpty) return false;
    final ({String peerKey, DateTime expiresAt})? entry = _issued.remove(nonce);
    if (entry == null) return false;
    if (!_now().isBefore(entry.expiresAt)) return false;
    return entry.peerKey == peerKey;
  }

  void _prune() {
    final DateTime now = _now();
    _issued.removeWhere(
      (String _, ({String peerKey, DateTime expiresAt}) e) =>
          !now.isBefore(e.expiresAt),
    );
  }
}

/// peer 身份键：token 的 SHA-256（不在内存里另存一份明文 token）。
String hostUpdatePeerKey(String token) =>
    sha256.convert(utf8.encode(token)).toString();

/// 拒绝响应的 JSON 正文：`{"error": "<code>"}`。
String hostUpdateDenialBody(HostUpdateDenial denial) =>
    jsonEncode(<String, String>{'error': denial.code});

/// 从错误响应正文里取拒绝原因（不是 JSON / 没有 error 字段 → null）。
HostUpdateDenial? parseHostUpdateDenialBody(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map) return HostUpdateDenial.fromCode(decoded['error']);
  } on FormatException {
    return null;
  }
  return null;
}
