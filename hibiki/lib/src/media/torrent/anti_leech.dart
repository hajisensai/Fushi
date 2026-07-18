import 'dart:math' as math;

/// 反吸血判定引擎的纯 Dart 核心（复刻 PeerBanHelper 的规则语义）。
///
/// 定位：将来内置 libtorrent 引擎的反吸血层的**纯逻辑核心**。本文件不碰
/// libtorrent、不碰网络、不执行封禁——只做判定：输入一批抽象 peer 快照
/// （[PeerSnapshot]）+ 种子上下文（[TorrentContext]），输出每个 peer 的
/// [BanVerdict]（该不该封 / 封哪个 CIDR 段 / 原因）。native 引擎负责把
/// libtorrent `peer_info` 映射成 [PeerSnapshot]，再把 [BanVerdict] 翻译成
/// libtorrent `ip_filter`。
///
/// 核心洞察（进度作弊检测，PCB）：「我实际喂给这个 peer 多少字节」
/// （[PeerSnapshot.totalUpload]，可信）对「peer 自报进度」
/// （[PeerSnapshot.reportedProgress]，可伪造），对不上就是吸血。
///
/// 零外部依赖；所有时间经 `nowMs` 参数注入，绝不内部调 `DateTime.now()`。

/// peer 快照（libtorrent `peer_info` 的中性子集；native 引擎映射后喂入）。
class PeerSnapshot {
  const PeerSnapshot({
    required this.ip,
    required this.peerId,
    required this.client,
    required this.reportedProgress,
    required this.totalUpload,
    this.uploadSpeed = 0,
    this.peerInterested = true,
  });

  /// 如 `'1.2.3.4'`（IPv4）或 `'2001:db8::1'`（IPv6）。
  final String ip;

  /// 20 字节 peer_id 的可读形式，如 `'-XL0012-abcdef...'`。
  final String peerId;

  /// 客户端名，如 `'Xunlei 0.0.1.2'` / `'qBittorrent 4.6.5'`。
  final String client;

  /// 0..1，peer 自报进度（可作弊）。
  final double reportedProgress;

  /// 本连接我实际上传给它的字节（可信，反吸血基准）。
  final int totalUpload;

  /// 当前上传速率 B/s（预留字段，当前规则未使用）。
  final int uploadSpeed;

  /// peer 是否 interested（在问我要数据；预留字段，当前规则未使用）。
  final bool peerInterested;
}

/// 种子上下文。
class TorrentContext {
  const TorrentContext({
    required this.infoHash,
    required this.totalSize,
    this.completedSize,
    this.isSeeding = false,
  });

  final String infoHash;

  /// 种子总字节。
  final int totalSize;

  /// 未完成任务时用它做 excessive 比较（null 用 [totalSize]）。
  final int? completedSize;

  final bool isSeeding;
}

/// 封禁原因。
enum BanReason {
  /// PCB differenceTest：实喂进度比自报进度高出阈值 = 谎报低进度骗上传。
  progressCheat,

  /// PCB：自报进度倒退超阈值。
  progressRewind,

  /// PCB：单 peer 从我这下走的量超种子数倍 = PCDN 回源/过量白嫖。
  excessiveDownload,

  /// peer_id 前缀黑名单命中。
  peerIdBlacklist,

  /// 客户端名关键词黑名单命中。
  clientBlacklist,

  /// 迅雷特例：做种时不让迅雷白嫖（不做种时迅雷可能是正常下载者，放行）。
  xunleiSeeding,

  /// 多拨/PCDN：同段同种子连接数超容忍值。
  multiDialing,

  /// 连坐：IP 落在已封 CIDR 段内。
  autoRangeBan,
}

/// 判定结果。[banned]=false 时其余字段忽略。
class BanVerdict {
  const BanVerdict.allow()
      : banned = false,
        reason = null,
        cidr = null,
        banDurationMs = null;

  const BanVerdict.ban(this.reason, {this.cidr, this.banDurationMs})
      : banned = true;

  final bool banned;
  final BanReason? reason;

  /// 连坐/多拨时要封的段（如 `'1.2.3.0/24'`）；单 IP 封时 null（=封该
  /// peer.ip）。
  final String? cidr;

  /// 封禁时长；null=用默认长封。
  final int? banDurationMs;
}

/// 阈值配置。
///
/// 默认值是贴 PeerBanHelper 语义的合理默认，**非**从 PBH 源码逐字抄的官方
/// 精确值；默认值待真机调优/对齐 PBH 上游。
class AntiLeechConfig {
  const AntiLeechConfig({
    this.maxProgressDifference = 0.08,
    this.progressRewindThreshold = 0.05,
    this.excessiveThreshold = 3.0,
    this.handshakeGraceMs = 60000,
    this.minTorrentSizeForPcb = 20 * 1024 * 1024,
    this.ipv4PrefixLength = 24,
    this.ipv6PrefixLength = 60,
    this.multiDialTolerance = 8,
    this.peerIdBlacklistPrefixes = const <String>[
      '-XL',
      '-SD',
      '-XF',
      '-DL',
      '-BN',
      '-DT',
      '-QD',
    ],
    this.clientNameKeywords = const <String>[
      'xunlei',
      'thunder',
      'qqdownload',
      'xfplay',
      'dandanplay',
      'offline',
    ],
  });

  /// computedProgress 比自报高出这么多即作弊。
  final double maxProgressDifference;

  /// 进度倒退超此值即作弊。
  final double progressRewindThreshold;

  /// 单 peer 上传量超种子大小这么多倍即过量。
  final double excessiveThreshold;

  /// 首见后宽限窗口（毫秒），避 bitfield 未就绪误判。
  final int handshakeGraceMs;

  /// 小于此大小（字节）的种子不做 PCB（小文件噪声大）。
  final int minTorrentSizeForPcb;

  /// 连坐/多拨用的 IPv4 段前缀位数。
  final int ipv4PrefixLength;

  /// 连坐/多拨用的 IPv6 段前缀位数。
  final int ipv6PrefixLength;

  /// 同段同种子容忍的连接数，超即多拨。
  final int multiDialTolerance;

  /// peer_id 前缀黑名单。
  final List<String> peerIdBlacklistPrefixes;

  /// 客户端名关键词黑名单（小写子串匹配）。
  final List<String> clientNameKeywords;
}

/// 解析 IP 字符串为字节列表（IPv4 → 4 字节，IPv6 → 16 字节）。纯函数，
/// 容错：非法输入返回 null。
List<int>? _tryParseIpBytes(String ip) {
  if (ip.contains(':')) {
    try {
      return Uri.parseIPv6Address(ip);
    } on FormatException {
      return null;
    }
  }
  final List<String> parts = ip.split('.');
  if (parts.length != 4) return null;
  final List<int> bytes = <int>[];
  for (final String part in parts) {
    // 只接受 1~3 位纯数字（拒绝空段 / '+1' / 前置符号）。
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
    final int value = int.parse(part);
    if (value > 255) return null;
    bytes.add(value);
  }
  return bytes;
}

/// 把 [bytes] 保留前 [prefixBits] 位、其余清零（就地修改）。
void _maskBytes(List<int> bytes, int prefixBits) {
  final int fullBytes = prefixBits ~/ 8;
  final int remBits = prefixBits % 8;
  for (int i = fullBytes; i < bytes.length; i++) {
    if (i == fullBytes && remBits != 0) {
      bytes[i] &= (0xFF << (8 - remBits)) & 0xFF;
    } else {
      bytes[i] = 0;
    }
  }
}

/// 算 IP 所属 CIDR 段，如 `cidrOf('1.2.3.4')` → `'1.2.3.0/24'`。纯函数。
///
/// IPv4 用 [ipv4Prefix] 位掩码；IPv6 用 [ipv6Prefix] 位掩码（输出为不压缩的
/// 8 组十六进制形式，如 `'2001:db8:0:0:0:0:0:0/60'`）。容错：非法 IPv4
/// 返回 `'$ip/32'`；非法 IPv6（含 `:` 但解析失败）原样返回。
String cidrOf(String ip, {int ipv4Prefix = 24, int ipv6Prefix = 60}) {
  final List<int>? bytes = _tryParseIpBytes(ip);
  if (ip.contains(':')) {
    if (bytes == null || bytes.length != 16) return ip;
    final int prefix =
        ipv6Prefix < 0 ? 0 : (ipv6Prefix > 128 ? 128 : ipv6Prefix);
    _maskBytes(bytes, prefix);
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 8; i++) {
      if (i > 0) buffer.write(':');
      buffer.write(((bytes[i * 2] << 8) | bytes[i * 2 + 1]).toRadixString(16));
    }
    return '$buffer/$prefix';
  }
  if (bytes == null) return '$ip/32';
  final int prefix = ipv4Prefix < 0 ? 0 : (ipv4Prefix > 32 ? 32 : ipv4Prefix);
  _maskBytes(bytes, prefix);
  return '${bytes.join('.')}/$prefix';
}

/// 判 IP 是否落在 CIDR 段内（前缀位比较，IPv4/IPv6 都支持）。纯函数，
/// 容错：cidr 无 `/`（[cidrOf] 的 IPv6 非法回退产物）退化为精确串比较；
/// 前缀非法、地址非法或地址族不匹配返回 false。
bool ipInCidr(String ip, String cidr) {
  final int slash = cidr.lastIndexOf('/');
  if (slash < 0) return ip == cidr;
  final int? prefix = int.tryParse(cidr.substring(slash + 1));
  if (prefix == null || prefix < 0) return false;
  final List<int>? ipBytes = _tryParseIpBytes(ip);
  final List<int>? netBytes = _tryParseIpBytes(cidr.substring(0, slash));
  if (ipBytes == null || netBytes == null) return false;
  if (ipBytes.length != netBytes.length) return false;
  if (prefix > ipBytes.length * 8) return false;
  final int fullBytes = prefix ~/ 8;
  for (int i = 0; i < fullBytes; i++) {
    if (ipBytes[i] != netBytes[i]) return false;
  }
  final int remBits = prefix % 8;
  if (remBits != 0) {
    final int mask = (0xFF << (8 - remBits)) & 0xFF;
    if ((ipBytes[fullBytes] & mask) != (netBytes[fullBytes] & mask)) {
      return false;
    }
  }
  return true;
}

/// 反吸血判定引擎（有状态：跨 [evaluate] 调用累积峰值/首见/进度/封段）。
///
/// 规则顺序（每 peer 走一遍，第一个命中就 ban 并短路）：
/// ① AutoRangeBan 连坐 → ② PeerId/ClientName 黑名单（含迅雷做种特例）→
/// ③ MultiDialing 多拨 → ④ ProgressCheatBlocker（PCB，最后做：最贵且要过
/// 宽限窗口）。任何新 ban 都把该 IP 的 CIDR 段登记进连坐源。
class AntiLeechEngine {
  AntiLeechEngine({this.config = const AntiLeechConfig()});

  final AntiLeechConfig config;

  /// 每 IP 见过的 `totalUpload` 峰值（抗断连重置——peer 断连重连后
  /// totalUpload 归零，但我们记得峰值）。
  final Map<String, int> _peakUpload = <String, int>{};

  /// 每 IP 首见时刻（宽限窗口基准）。
  final Map<String, int> _firstSeenMs = <String, int>{};

  /// 每 IP 上次自报进度（progressRewind 基准）。
  final Map<String, double> _lastProgress = <String, double>{};

  /// 已封段（AutoRangeBan 连坐源）。
  final Set<String> _bannedCidrs = <String>{};

  /// `infoHash@cidr` → 该段该种子见过的 IP 集（MultiDialing 计数）。
  final Map<String, Set<String>> _torrentSegmentIps = <String, Set<String>>{};

  /// 当前已封段的只读视图（native 层可据此重建 ip_filter）。
  Set<String> get bannedCidrs => Set<String>.unmodifiable(_bannedCidrs);

  /// 对一批 peer 快照做判定，返回 `ip → 判定` 映射。
  ///
  /// [nowMs] 由调用方注入（单调毫秒时钟），引擎内部绝不取真实时间。
  /// 每个新 ban 的 IP 的 CIDR 段立即加入连坐源，因此同一批里排在后面的
  /// 同段 peer 会直接命中 AutoRangeBan。
  Map<String, BanVerdict> evaluate(
    List<PeerSnapshot> peers,
    TorrentContext ctx, {
    required int nowMs,
  }) {
    final Map<String, BanVerdict> out = <String, BanVerdict>{};
    for (final PeerSnapshot peer in peers) {
      final BanVerdict verdict = _evaluatePeer(peer, ctx, nowMs);
      if (verdict.banned) {
        _bannedCidrs.add(verdict.cidr ?? _segmentOf(peer.ip));
      }
      out[peer.ip] = verdict;
    }
    return out;
  }

  /// 单 peer 判定（规则顺序见类 doc）。
  BanVerdict _evaluatePeer(PeerSnapshot peer, TorrentContext ctx, int nowMs) {
    // ① AutoRangeBan（连坐，先查）：IP 落在任一已封段直接 ban。
    for (final String cidr in _bannedCidrs) {
      if (ipInCidr(peer.ip, cidr)) {
        return BanVerdict.ban(BanReason.autoRangeBan, cidr: cidr);
      }
    }

    // ② PeerId/ClientName 黑名单 + 迅雷特例。
    final String clientLower = peer.client.toLowerCase();
    final bool isXunlei = peer.peerId.startsWith('-XL') ||
        clientLower.startsWith('xunlei') ||
        clientLower.startsWith('thunder');
    if (isXunlei) {
      // 迅雷特例：仅做种时 ban（不做种时迅雷可能是正常下载者），不做种
      // 则跳过黑名单继续走后续规则。
      if (ctx.isSeeding) {
        return const BanVerdict.ban(BanReason.xunleiSeeding);
      }
    } else {
      for (final String prefix in config.peerIdBlacklistPrefixes) {
        if (peer.peerId.startsWith(prefix)) {
          return const BanVerdict.ban(BanReason.peerIdBlacklist);
        }
      }
      for (final String keyword in config.clientNameKeywords) {
        if (clientLower.contains(keyword)) {
          return const BanVerdict.ban(BanReason.clientBlacklist);
        }
      }
    }

    // ③ MultiDialingBlocker（多拨/PCDN）：同段同种子 IP 数超容忍值封段。
    final String segment = _segmentOf(peer.ip);
    final Set<String> segmentIps = _torrentSegmentIps.putIfAbsent(
        '${ctx.infoHash}@$segment', () => <String>{})
      ..add(peer.ip);
    if (segmentIps.length > config.multiDialTolerance) {
      return BanVerdict.ban(BanReason.multiDialing, cidr: segment);
    }

    // ④ ProgressCheatBlocker（PCB 核心）。
    return _evaluatePcb(peer, ctx, nowMs);
  }

  /// PCB：differenceTest → progressRewind → excessiveDownload。
  BanVerdict _evaluatePcb(PeerSnapshot peer, TorrentContext ctx, int nowMs) {
    final int firstSeen = _firstSeenMs.putIfAbsent(peer.ip, () => nowMs);
    // 峰值抗断连：断连重连后 totalUpload 归零，按历史峰值判。
    final int computedUploaded =
        math.max(peer.totalUpload, _peakUpload[peer.ip] ?? 0);
    _peakUpload[peer.ip] = computedUploaded;

    // 宽限窗口：只更新状态不判定，避 bitfield 未就绪误封。
    if (nowMs - firstSeen < config.handshakeGraceMs) {
      _lastProgress[peer.ip] = peer.reportedProgress;
      return const BanVerdict.allow();
    }
    // 小种子噪声大，跳过 PCB。
    if (ctx.totalSize <= 0 || ctx.totalSize < config.minTorrentSizeForPcb) {
      return const BanVerdict.allow();
    }
    // 没喂出过任何字节（含峰值）就无从判「喂了却自报低」。
    if (computedUploaded == 0) {
      _lastProgress[peer.ip] = peer.reportedProgress;
      return const BanVerdict.allow();
    }

    // differenceTest：我喂给你的量对应的进度，比你自报的高出一大截 =
    // 你谎报低进度骗我持续上传。
    final double computedProgress =
        math.min(1.0, computedUploaded / ctx.totalSize);
    if (computedProgress - peer.reportedProgress >
        config.maxProgressDifference) {
      return const BanVerdict.ban(BanReason.progressCheat);
    }

    // progressRewind：自报进度倒退超阈值。
    final double? lastProgress = _lastProgress[peer.ip];
    _lastProgress[peer.ip] = peer.reportedProgress;
    if (lastProgress != null &&
        lastProgress - peer.reportedProgress > config.progressRewindThreshold) {
      return const BanVerdict.ban(BanReason.progressRewind);
    }

    // excessiveDownload：单 peer 下走的量超整个种子数倍 = PCDN 回源。
    final int refSize = ctx.completedSize ?? ctx.totalSize;
    if (refSize > 0 && computedUploaded > refSize * config.excessiveThreshold) {
      return const BanVerdict.ban(BanReason.excessiveDownload);
    }
    return const BanVerdict.allow();
  }

  /// 按配置前缀算 IP 所属段。
  String _segmentOf(String ip) => cidrOf(
        ip,
        ipv4Prefix: config.ipv4PrefixLength,
        ipv6Prefix: config.ipv6PrefixLength,
      );
}
