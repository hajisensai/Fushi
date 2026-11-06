import 'dart:io';

/// Fushi API 服务器（浏览器扩展 / yomitan-api / AnkiConnect 兼容端点）的
/// 「允许谁连」。持久化值见 [FushiApiAccessMode.wireName]（偏好键
/// `fushi_api_access_mode`）。
enum FushiApiAccessMode {
  /// 只绑 127.0.0.1：别的设备连 TCP 都建立不了。
  localOnly('local'),

  /// 绑 0.0.0.0：同一网络里的设备都能连（仍受「非本机必须带密钥」约束）。
  lan('lan'),

  /// 绑 0.0.0.0，但只放行来源 IP 落在 [FushiApiAccessPolicy.allowedNetworks]
  /// 里的请求（本机恒放行）。
  allowList('allowlist');

  const FushiApiAccessMode(this.wireName);

  final String wireName;

  /// 未知 / 缺失值回落 [lan]——这是改造前「永远绑 0.0.0.0」的既有行为，
  /// 升级的老用户不会因为这次改造突然断开。
  static FushiApiAccessMode fromWireName(String? name) {
    for (final FushiApiAccessMode m in values) {
      if (m.wireName == name) return m;
    }
    return lan;
  }
}

/// 一段 IP 网段（CIDR）。单个地址按 /32（IPv6 为 /128）处理。
class FushiIpNetwork {
  FushiIpNetwork._(this._prefix, this.prefixLength, this.source);

  /// 解析 `192.168.1.0/24` / `10.0.0.5` / `fd00::/8`；非法返回 null。
  static FushiIpNetwork? tryParse(String input) {
    final String text = input.trim();
    if (text.isEmpty) return null;
    final int slash = text.indexOf('/');
    final String addressPart = slash < 0 ? text : text.substring(0, slash);
    final InternetAddress? address = InternetAddress.tryParse(addressPart);
    if (address == null) return null;
    final List<int> raw = address.rawAddress;
    final int maxBits = raw.length * 8;
    int bits = maxBits;
    if (slash >= 0) {
      final int? parsed = int.tryParse(text.substring(slash + 1));
      if (parsed == null || parsed < 0 || parsed > maxBits) return null;
      bits = parsed;
    }
    return FushiIpNetwork._(_mask(raw, bits), bits, text);
  }

  final List<int> _prefix;
  final int prefixLength;

  /// 用户输入的原文（去首尾空白），用于回显。
  final String source;

  bool contains(InternetAddress address) {
    List<int> raw = address.rawAddress;
    // IPv4 规则要能匹配 IPv4 映射的 IPv6 来源（::ffff:a.b.c.d）。
    if (_prefix.length == 4 && raw.length == 16 && _isV4Mapped(raw)) {
      raw = raw.sublist(12);
    }
    if (raw.length != _prefix.length) return false;
    final List<int> masked = _mask(raw, prefixLength);
    for (int i = 0; i < masked.length; i++) {
      if (masked[i] != _prefix[i]) return false;
    }
    return true;
  }

  static List<int> _mask(List<int> raw, int bits) {
    final List<int> out = List<int>.filled(raw.length, 0);
    for (int i = 0; i < raw.length; i++) {
      final int remaining = bits - i * 8;
      if (remaining >= 8) {
        out[i] = raw[i];
      } else if (remaining > 0) {
        out[i] = raw[i] & (0xff << (8 - remaining)) & 0xff;
      }
    }
    return out;
  }
}

bool _isV4Mapped(List<int> raw) =>
    raw.length == 16 &&
    raw.sublist(0, 10).every((int x) => x == 0) &&
    raw[10] == 0xff &&
    raw[11] == 0xff;

/// 来源地址是否是本机回环（含 IPv4 映射的 ::ffff:127.x.x.x）。
bool isFushiApiLoopback(InternetAddress address) {
  if (address.isLoopback) return true;
  final List<int> raw = address.rawAddress;
  return _isV4Mapped(raw) && raw[12] == 127;
}

/// 解析白名单文本（逗号 / 空白 / 换行分隔）。返回解析结果与非法条目。
({List<FushiIpNetwork> networks, List<String> invalid}) parseFushiIpNetworks(
  String text,
) {
  final List<FushiIpNetwork> networks = <FushiIpNetwork>[];
  final List<String> invalid = <String>[];
  for (final String token in text.split(RegExp(r'[\s,;，；]+'))) {
    if (token.isEmpty) continue;
    final FushiIpNetwork? n = FushiIpNetwork.tryParse(token);
    if (n == null) {
      invalid.add(token);
    } else {
      networks.add(n);
    }
  }
  return (networks: networks, invalid: invalid);
}

/// 一次请求的放行判定结果。
enum FushiApiAccessDecision {
  allow,

  /// 拿不到来源地址（非 dart:io 连接）：失败即关闭。
  denyUnknownPeer,

  /// 「仅本机」模式下的非本机请求。
  denyLocalOnly,

  /// 非本机请求但没有设置 API 密钥。
  denyNoKey,

  /// 白名单模式下来源不在任何允许网段。
  denyNotInAllowList,
}

/// 网络层访问策略：先于密钥校验执行，作用于 Fushi API 的**全部**路径
/// （包括免密钥的单词音频与「试一试」页、AnkiConnect 兼容端点）。
///
/// 硬规则：**没设密钥时只接受本机请求**。改造前服务恒绑 0.0.0.0 且空密钥一律放行，
/// 同一网络里的任何设备都能不带密钥查词、制卡、读历史；这里与 AnkiConnect 端点既有的
/// 「无 key 只收回环」规则统一成一条，作用到整台服务器。
class FushiApiAccessPolicy {
  const FushiApiAccessPolicy({
    required this.mode,
    this.allowedNetworks = const <FushiIpNetwork>[],
  });

  static const FushiApiAccessPolicy localOnly = FushiApiAccessPolicy(
    mode: FushiApiAccessMode.localOnly,
  );

  final FushiApiAccessMode mode;
  final List<FushiIpNetwork> allowedNetworks;

  /// 监听地址：仅本机绑回环，其余绑全部 IPv4 网卡。
  InternetAddress get bindAddress => mode == FushiApiAccessMode.localOnly
      ? InternetAddress.loopbackIPv4
      : InternetAddress.anyIPv4;

  FushiApiAccessDecision decide({
    required InternetAddress? remote,
    required bool keyConfigured,
  }) {
    if (remote == null) return FushiApiAccessDecision.denyUnknownPeer;
    if (isFushiApiLoopback(remote)) return FushiApiAccessDecision.allow;
    switch (mode) {
      case FushiApiAccessMode.localOnly:
        return FushiApiAccessDecision.denyLocalOnly;
      case FushiApiAccessMode.lan:
        break;
      case FushiApiAccessMode.allowList:
        if (!allowedNetworks.any((FushiIpNetwork n) => n.contains(remote))) {
          return FushiApiAccessDecision.denyNotInAllowList;
        }
    }
    if (!keyConfigured) return FushiApiAccessDecision.denyNoKey;
    return FushiApiAccessDecision.allow;
  }
}
