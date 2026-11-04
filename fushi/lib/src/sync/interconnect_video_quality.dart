/// 互联远端视频的画质档（弱网可用）。
///
/// host 侧按档把视频转码成 HLS 下发（`packages/fushi_engine/lib/media/video/
/// live_transcode.dart`）；这里是 client 侧的档位表与「自动」档的判据。
library;

import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart'
    show isInterconnectTunnelOrigin;

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

/// 链路带宽相对所需码率的富余倍数：实测带宽 ≥ 码率 × 1.5 才算「跑得动」。
///
/// 探测只有一两秒，测到的是这一刻的吞吐；视频码率本身也有起伏（BD 原盘的峰值远高于
/// 平均值）。留五成余量，宁可在边缘处多转一次码，也不要起播就卡。
const double kInterconnectLinkHeadroom = 1.5;

/// 链路探测最多读多少字节（8 MiB）。够把 TCP 慢启动跑过去，又不至于在慢链路上白耗流量。
const int kInterconnectLinkProbeMaxBytes = 8 * 1024 * 1024;

/// 链路探测从首字节起最多读多久。
const Duration kInterconnectLinkProbeWindow = Duration(milliseconds: 1500);

/// 样本至少要这么多字节才作数（除非整个文件就这么大、已经读完）：太少的样本里
/// 全是慢启动，测出来的数严重偏低。
const int kInterconnectLinkProbeMinBytes = 256 * 1024;

/// 纯函数：一次链路探测样本 → 吞吐（bps）；样本不作数返回 null。
///
/// [elapsed] 从**首字节**算起（不含建连与 host 打开文件的延迟——那是一次性的，
/// 不反映持续吞吐）。[reachedEnd] = 读到了文件末尾：小文件不够
/// [kInterconnectLinkProbeMinBytes] 也算数，因为整片都已经搬过来了。
int? interconnectLinkBitsPerSecond({
  required int bytes,
  required Duration elapsed,
  required bool reachedEnd,
}) {
  if (bytes <= 0) return null;
  if (bytes < kInterconnectLinkProbeMinBytes && !reachedEnd) return null;
  final int micros = elapsed.inMicroseconds < 1000
      ? 1000
      : elapsed.inMicroseconds;
  return (bytes * 8 * 1000000) ~/ micros;
}

/// 纯函数：「自动」档的起点下标（-1 = 原画直传），按**链路带宽对源码率**决定
/// （反馈 uaBRMzK_WM：内网应能看 BD 满码率）。
///
/// - [privateNetworkHost]：连的是字面量局域网地址，不用测，原画。
/// - [linkBitsPerSecond] 为 null（没测成：老 host、蓝光段表、探测失败）→ 退回旧的
///   保守起点 [kInterconnectAutoQualityPresetIndex]。
/// - 知道源码率且带宽 ≥ 源码率 × [kInterconnectLinkHeadroom] → 原画。经 DDNS 域名、
///   公网 IPv6、端口映射回家的局域网连接就是靠这一条拿到原画——它们的地址字面上
///   不是私网，旧判据一律当成公网压到 2 Mbps。
/// - 否则取带宽撑得住的最高一档（档位码率 × 富余倍数 ≤ 带宽）；一档都撑不住给最低档。
///
/// 源码率未知时**不**自动给原画：原片可能是 40 Mbps 的原盘，猜错了就是起播即卡。
int resolveInterconnectAutoStartIndex({
  required bool privateNetworkHost,
  required int? linkBitsPerSecond,
  required int? sourceBitrate,
  List<MediaServerQualityPreset> presets = kInterconnectQualityPresets,
}) {
  if (privateNetworkHost) return -1;
  final int? link = linkBitsPerSecond;
  if (link == null || link <= 0) return kInterconnectAutoQualityPresetIndex;
  final int? source = sourceBitrate;
  if (source != null &&
      source > 0 &&
      link >= source * kInterconnectLinkHeadroom) {
    return -1;
  }
  for (int i = 0; i < presets.length; i++) {
    if (presets[i].maxBitrate * kInterconnectLinkHeadroom <= link) return i;
  }
  return presets.length - 1;
}

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
  // P2P 隧道的本地转发口字面上是回环，背后却是跨公网（多半还经中继）——按局域网
  // 原画直传会把中继带宽打爆（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
  final Uri? parsed = Uri.tryParse(hostUrl!.trim());
  if (parsed != null &&
      parsed.hasPort &&
      isInterconnectTunnelOrigin(lower, parsed.port)) {
    return false;
  }
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
