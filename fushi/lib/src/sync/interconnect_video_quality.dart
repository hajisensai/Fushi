/// 互联远端视频的画质档（弱网可用）。
///
/// host 侧按档把视频转码成 HLS 下发（`packages/fushi_engine/lib/media/video/
/// live_transcode.dart`）；这里是 client 侧的档位表与「自动」档的判据。
library;

import 'package:fushi/src/sync/remote_video_client.dart';

/// 互联的画质档。
///
/// 比 Jellyfin/Emby 那套（最高 20 Mbps）整体更低：那边的典型场景是家里电视盒子拉
/// 局域网服务器，这边要解决的恰恰是**人在外面用手机网络**——20 Mbps 那一档在移动网
/// 络上和不转码没有区别。
///
/// 档位**不进 i18n**（纯数字与单位），与 `MediaServerQualityPreset.label` 的既有约定
/// 一致。
const List<MediaServerQualityPreset> kInterconnectQualityPresets =
    <MediaServerQualityPreset>[
      MediaServerQualityPreset(
        label: '1080p · 8 Mbps',
        maxBitrate: 8000000,
        maxWidth: 1920,
      ),
      MediaServerQualityPreset(
        label: '720p · 4 Mbps',
        maxBitrate: 4000000,
        maxWidth: 1280,
      ),
      MediaServerQualityPreset(
        label: '720p · 2 Mbps',
        maxBitrate: 2000000,
        maxWidth: 1280,
      ),
      MediaServerQualityPreset(
        label: '480p · 1 Mbps',
        maxBitrate: 1000000,
        maxWidth: 854,
      ),
      MediaServerQualityPreset(
        label: '360p · 0.6 Mbps',
        maxBitrate: 600000,
        maxWidth: 640,
      ),
    ];

/// 「自动」档在**离开局域网**时用的那一档（720p · 2 Mbps）。
///
/// 选它而不是更低的：2 Mbps 的 720p 在手机屏上已经看不出多少损失，而 4G/5G 下
/// 2 Mbps 是绝大多数时候跑得动的水位。宁可让用户觉得「自动就够用」，也不要自动
/// 给出一个糊到需要手动调回去的画面。
const int kInterconnectAutoQualityPresetIndex = 2;

/// 「自动」档的**起点**：连的是局域网就原画直传，走公网就先压到
/// [kInterconnectAutoQualityPresetIndex]，之后交给
/// `AdaptiveQualityController` 按实测网况继续升降。
///
/// 起点不靠探测而靠「这条连接在不在局域网里」，是因为探测要先卡一阵子才学得到东西
/// ——而第一分钟恰恰是用户最容易直接退出去的那一分钟。局域网/公网这条线在这里几乎
/// 总是对的：在家就是原画，在外面就先给一个能跑的档，然后再调。
///
/// [hostUrl] 是当前连到的 host 基址（`http://192.168.1.8:15001` 形式）。解析不出
/// 主机名时按「不是局域网」处理——判错方向的代价不对称：在局域网里多转一次码只是
/// 浪费些 CPU，在外面不转码则是根本看不了。
MediaServerQualityPreset? resolveInterconnectAutoPreset(String? hostUrl) {
  if (isPrivateNetworkHost(hostUrl)) return null;
  return kInterconnectQualityPresets[kInterconnectAutoQualityPresetIndex];
}

/// [hostUrl] 是否指向局域网 / 本机。
///
/// 覆盖 RFC 1918 私有段、回环、链路本地、IPv6 ULA 与链路本地，以及 mDNS 名
/// （`.local` 与不带点的裸主机名）。
///
/// **不**把 CGNAT 段（100.64.0.0/10）算作局域网：那是 Tailscale 之类隧道的常用地址，
/// 流量实际还是走对端家里的上行带宽，正是最需要压码率的场景。
bool isPrivateNetworkHost(String? hostUrl) {
  final String? host = _hostOf(hostUrl);
  if (host == null || host.isEmpty) return false;

  final String lower = host.toLowerCase();
  if (lower == 'localhost') return true;
  // mDNS / 单标签主机名只可能在同一广播域里解析得到。
  if (lower.endsWith('.local') || !lower.contains('.')) {
    // 但纯 IPv6 字面量没有点，先排除掉它们再按主机名论。
    if (!lower.contains(':')) return true;
  }

  final List<int>? v4 = _parseIPv4(lower);
  if (v4 != null) {
    if (v4[0] == 127) return true; // 127.0.0.0/8
    if (v4[0] == 10) return true; // 10.0.0.0/8
    if (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31) return true; // 172.16/12
    if (v4[0] == 192 && v4[1] == 168) return true; // 192.168/16
    if (v4[0] == 169 && v4[1] == 254) return true; // 169.254/16 link-local
    return false;
  }

  if (lower.contains(':')) {
    if (lower == '::1') return true;
    // fc00::/7（ULA）与 fe80::/10（链路本地）。
    if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
    if (lower.startsWith('fe8') ||
        lower.startsWith('fe9') ||
        lower.startsWith('fea') ||
        lower.startsWith('feb')) {
      return true;
    }
    return false;
  }
  return false;
}

/// 从基址里抠出主机名（`http://192.168.1.8:15001/x` → `192.168.1.8`）。
///
/// IPv6 字面量在 URL 里带方括号（`http://[fe80::1]:15001`），[Uri.host] 会把它们
/// 去掉，所以这里拿到的就是裸地址。
String? _hostOf(String? url) {
  final String trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) return uri.host;
  // 没有 scheme 的裸地址。`192.168.1.8:15001` 连 parse 都过不去（scheme 不能以数字
  // 开头，tryParse 直接给 null），`example.com:15001` 则会被解析成 scheme=example.com
  // 而 host 为空——两种都靠补一个 scheme 再解。
  final Uri? withScheme = Uri.tryParse('http://$trimmed');
  final String? host = withScheme?.host;
  return host == null || host.isEmpty ? null : host;
}

List<int>? _parseIPv4(String host) {
  final List<String> parts = host.split('.');
  if (parts.length != 4) return null;
  final List<int> octets = <int>[];
  for (final String part in parts) {
    final int? value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    octets.add(value);
  }
  return octets;
}
