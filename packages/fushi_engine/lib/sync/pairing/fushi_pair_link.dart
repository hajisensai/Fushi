import 'package:fushi_engine/sync/interconnect_host_addresses.dart';

/// 扫码 / 深链 / NFC 配对载荷（docs/specs/2026-09-28-interconnect-remote-reach.md §4）：
///
/// ```
/// fushi://pair?v=1&h=<hostId>&n=<展示名>&fp=<证书指纹>&k=<ticketId>.<secret>&a=<kind>~<url>...
/// ```
///
/// - 二维码 / 复制链接带 `k`（一次性票据）：client 用 secret 代替 PIN 算 HMAC，
///   host 屏上主动打开二维码即视为已批准。
/// - NFC 贴纸是长期物，**绝不带 `k`**：碰贴纸只省掉输地址与核指纹，仍需 host 审批
///   （非 LAN 还要 PIN）。
/// - 指纹经带外通道到达，client 不必先 TOFU 信任首次握手看到的证书。
class FushiPairLink {
  const FushiPairLink({
    required this.hostId,
    required this.addresses,
    this.deviceName,
    this.fingerprint,
    this.ticketId,
    this.ticketSecret,
  });

  static const String scheme = 'fushi';
  static const String host = 'pair';
  static const String version = '1';

  final String hostId;
  final List<InterconnectHostAddress> addresses;
  final String? deviceName;
  final String? fingerprint;
  final String? ticketId;
  final String? ticketSecret;

  /// 带一次性票据（扫码 / 复制链接）；false = 贴纸类长期链接，走审批 + PIN。
  bool get hasTicket =>
      ticketId != null &&
      ticketId!.isNotEmpty &&
      ticketSecret != null &&
      ticketSecret!.isNotEmpty;

  /// 去掉票据（写 NFC 贴纸用）。
  FushiPairLink withoutTicket() => FushiPairLink(
    hostId: hostId,
    addresses: addresses,
    deviceName: deviceName,
    fingerprint: fingerprint,
  );

  String toUri() {
    final List<String> parts = <String>[
      'v=$version',
      'h=${Uri.encodeQueryComponent(hostId)}',
      if (deviceName != null && deviceName!.isNotEmpty)
        'n=${Uri.encodeQueryComponent(deviceName!)}',
      if (fingerprint != null && fingerprint!.isNotEmpty)
        'fp=${Uri.encodeQueryComponent(fingerprint!)}',
      if (hasTicket) 'k=${Uri.encodeQueryComponent('$ticketId.$ticketSecret')}',
      for (final InterconnectHostAddress a in addresses)
        'a=${Uri.encodeQueryComponent('${a.kind.name}~${a.url}')}',
    ];
    return '$scheme://$host?${parts.join('&')}';
  }

  /// 解析；不是配对链接 / 缺 hostId / 没有任何可用地址 → null。未知的地址种类
  /// 丢弃（更新的 host 多报一种），不让整条链接作废。
  static FushiPairLink? tryParse(String? raw) {
    if (raw == null) return null;
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != scheme ||
        uri.host.toLowerCase() != host) {
      return null;
    }
    final Map<String, List<String>> q = uri.queryParametersAll;
    String? one(String key) {
      final List<String>? v = q[key];
      if (v == null || v.isEmpty) return null;
      final String s = v.first.trim();
      return s.isEmpty ? null : s;
    }

    final String? hostId = one('h');
    if (hostId == null) return null;
    final List<InterconnectHostAddress> addresses = <InterconnectHostAddress>[];
    for (final String entry in q['a'] ?? const <String>[]) {
      final int sep = entry.indexOf('~');
      if (sep <= 0) continue;
      final InterconnectHostAddress? a = InterconnectHostAddress.fromJson(
        <String, Object?>{
          'kind': entry.substring(0, sep),
          'url': entry.substring(sep + 1),
        },
      );
      if (a != null) addresses.add(a);
    }
    if (addresses.isEmpty) return null;

    String? ticketId;
    String? ticketSecret;
    final String? k = one('k');
    if (k != null) {
      final int dot = k.indexOf('.');
      if (dot > 0 && dot < k.length - 1) {
        ticketId = k.substring(0, dot);
        ticketSecret = k.substring(dot + 1);
      }
    }
    return FushiPairLink(
      hostId: hostId,
      addresses: addresses,
      deviceName: one('n'),
      fingerprint: one('fp'),
      ticketId: ticketId,
      ticketSecret: ticketSecret,
    );
  }
}

/// host 签发的一次性配对票据：屏上显示二维码 = 用户已批准；[secret] 代替 PIN 进
/// HMAC（128+ bit，不可爆破），过期或配对成功即作废。
class FushiPairTicket {
  const FushiPairTicket({
    required this.id,
    required this.secret,
    required this.expiresAt,
  });

  final String id;
  final String secret;
  final DateTime expiresAt;

  bool isValidAt(DateTime now) => now.isBefore(expiresAt);
}
