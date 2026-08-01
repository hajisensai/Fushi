/// TODO-2481：下载任务行的显示格式化 —— 全部纯函数，UI 与后端都不 import
/// 这里以外的东西（无 Flutter 依赖，单测直跑）。
///
/// 后端 state 词汇不统一（qb：`downloading`/`stalledDL`/`pausedUP`…；
/// 内置引擎：`metadata`/`checking`/`downloading`/`finished`/`seeding`/`error`
/// + 快照层合成的 `pausedDL`/`pausedUP`），UI 一律先经 [torrentDisplayStatusFor]
/// 折叠成 [TorrentDisplayStatus] 再挑 i18n 文案，绝不裸比较字符串。
library;

/// 任务行状态文本的后端无关值域。
enum TorrentDisplayStatus {
  /// 正在下载（含强制下载）。
  downloading,

  /// 做种/上传中（数据已完整）。
  seeding,

  /// 已完成（内置引擎 `finished`：下载完但未在做种）。
  completed,

  /// 已暂停/停止（qb 4.x paused* / qb 5.x stopped* / 合成 paused*）。
  paused,

  /// 排队等待（下载或做种队列）。
  queued,

  /// 等待资源（连不上可用 peer，qb stalled*）。
  stalled,

  /// 校验文件中（含分配磁盘空间）。
  checking,

  /// 拉取元数据中（磁力链接起步阶段）。
  fetchingMetadata,

  /// 移动存储中（qb moving）。
  moving,

  /// 出错（含文件丢失）。
  error,

  /// 未知状态（新版本后端的新词）——UI 不显示状态段。
  unknown,
}

/// 后端 state 字符串 → 显示状态。未知词返回 [TorrentDisplayStatus.unknown]。
TorrentDisplayStatus torrentDisplayStatusFor(String state) {
  switch (state) {
    // 下载中：qb + 内置引擎共用 `downloading`。
    case 'downloading':
    case 'forcedDL':
      return TorrentDisplayStatus.downloading;
    // 做种：qb uploading/stalledUP 数据已完整、正在（或随时可）上传；
    // 内置引擎 seeding。
    case 'uploading':
    case 'forcedUP':
    case 'stalledUP':
    case 'seeding':
      return TorrentDisplayStatus.seeding;
    case 'finished':
      return TorrentDisplayStatus.completed;
    // 暂停：qb 4.x paused* / qb 5.x stopped* / 内置引擎快照层合成 paused*。
    case 'pausedDL':
    case 'pausedUP':
    case 'stoppedDL':
    case 'stoppedUP':
      return TorrentDisplayStatus.paused;
    case 'queuedDL':
    case 'queuedUP':
      return TorrentDisplayStatus.queued;
    case 'stalledDL':
      return TorrentDisplayStatus.stalled;
    // 校验：qb checking* / allocating（磁盘准备）与内置引擎 checking。
    case 'checkingDL':
    case 'checkingUP':
    case 'checkingResumeData':
    case 'allocating':
    case 'checking':
      return TorrentDisplayStatus.checking;
    // 元数据：qb metaDL / forcedMetaDL 与内置引擎 metadata。
    case 'metaDL':
    case 'forcedMetaDL':
    case 'metadata':
      return TorrentDisplayStatus.fetchingMetadata;
    case 'moving':
      return TorrentDisplayStatus.moving;
    case 'error':
    case 'missingFiles':
      return TorrentDisplayStatus.error;
    default:
      return TorrentDisplayStatus.unknown;
  }
}

/// ETA 上限：超过 100 天的估算只剩噪声（qb 同类场景显示 ∞），不显示。
const Duration kTorrentEtaDisplayCap = Duration(days: 100);

/// 剩余时间估算：`amountLeft / downRateBps`，返回 `12m34s` 一类紧凑串。
///
/// 不可估算一律返回 null（调用方整段不渲染）：
/// - [amountLeft] < 0 = 未知、== 0 = 已完成；
/// - [downRateBps] <= 0 = 速度为 0（除零且「卡住」本身由速度段表达）；
/// - 估值超过 [kTorrentEtaDisplayCap]。
String? formatTorrentEta({required int amountLeft, required int downRateBps}) {
  if (amountLeft <= 0 || downRateBps <= 0) return null;
  final int seconds = (amountLeft / downRateBps).ceil();
  if (seconds > kTorrentEtaDisplayCap.inSeconds) return null;
  return formatCompactDuration(Duration(seconds: seconds));
}

/// 紧凑时长串：取最高两级单位，次级补零两位（`45s` / `12m34s` / `1h02m` /
/// `2d07h`）。[duration] 为负按 0 处理。
String formatCompactDuration(Duration duration) {
  final int total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final int days = total ~/ 86400;
  final int hours = (total % 86400) ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int seconds = total % 60;
  if (days > 0) return '${days}d${hours.toString().padLeft(2, '0')}h';
  if (hours > 0) return '${hours}h${minutes.toString().padLeft(2, '0')}m';
  if (minutes > 0) return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
  return '${seconds}s';
}

/// 分享率：`uploadedBytes / downloadedBytes`，两位小数（qb 同款）。
/// 分母 <= 0（尚未下到任何字节）返回 null，不显示。
String? formatShareRatio({
  required int uploadedBytes,
  required int downloadedBytes,
}) {
  if (downloadedBytes <= 0) return null;
  final double ratio = uploadedBytes / downloadedBytes;
  return ratio.toStringAsFixed(2);
}

/// TODO-2482：内置引擎 peer flags 稳定位掩码的位定义（与
/// `native/hibiki_torrent/hibiki_torrent_include/hibiki_torrent.h` 的
/// ht_torrent_peers 契约逐位对齐，改一处必须改两处）。
class TorrentPeerFlagBits {
  TorrentPeerFlagBits._();

  /// 我们对该 peer 的数据感兴趣。
  static const int interesting = 1 << 0;

  /// 我们 choke 了该 peer（不给它上传）。
  static const int choked = 1 << 1;

  /// 该 peer 对我们的数据感兴趣。
  static const int remoteInterested = 1 << 2;

  /// 该 peer choke 了我们（不给我们下载）。
  static const int remoteChoked = 1 << 3;

  static const int supportsExtensions = 1 << 4;
  static const int outgoingConnection = 1 << 5;
  static const int handshake = 1 << 6;
  static const int connecting = 1 << 7;
  static const int onParole = 1 << 8;
  static const int seed = 1 << 9;
  static const int optimisticUnchoke = 1 << 10;
  static const int snubbed = 1 << 11;
  static const int uploadOnly = 1 << 12;
  static const int endgameMode = 1 << 13;
  static const int holepunched = 1 << 14;
  static const int utpSocket = 1 << 15;
  static const int sslSocket = 1 << 16;
  static const int rc4Encrypted = 1 << 17;
  static const int plaintextEncrypted = 1 << 18;
}

/// 内置引擎的 peer flags 位掩码 → qb WebUI 风格字母串（空格分隔）。
///
/// 字母表对齐 qBittorrent（用户已有的认知模型）：
/// `D`/`d` 在下载/想下但被对端 choke、`U`/`u` 在上传/对端想要但被我们
/// choke、`K` 对端没 choke 我们但我们不感兴趣、`?` 我们没 choke 对端但
/// 对端不感兴趣、`O` 乐观解锁、`S` snubbed、`I` 入站连接、`E` RC4 加密、
/// `e` 明文加密、`P` uTP、`H` 洞穿。全 0（老 DLL 无该字段）返回空串。
String formatTorrentPeerFlags(int flagsBits) {
  if (flagsBits == 0) return '';
  bool has(int bit) => (flagsBits & bit) != 0;
  final bool interesting = has(TorrentPeerFlagBits.interesting);
  final bool choked = has(TorrentPeerFlagBits.choked);
  final bool remoteInterested = has(TorrentPeerFlagBits.remoteInterested);
  final bool remoteChoked = has(TorrentPeerFlagBits.remoteChoked);
  final List<String> out = <String>[
    if (interesting && !remoteChoked) 'D',
    if (interesting && remoteChoked) 'd',
    if (remoteInterested && !choked) 'U',
    if (remoteInterested && choked) 'u',
    if (!interesting && !remoteChoked) 'K',
    if (!remoteInterested && !choked) '?',
    if (has(TorrentPeerFlagBits.optimisticUnchoke)) 'O',
    if (has(TorrentPeerFlagBits.snubbed)) 'S',
    if (!has(TorrentPeerFlagBits.outgoingConnection)) 'I',
    if (has(TorrentPeerFlagBits.rc4Encrypted)) 'E',
    if (has(TorrentPeerFlagBits.plaintextEncrypted)) 'e',
    if (has(TorrentPeerFlagBits.utpSocket)) 'P',
    if (has(TorrentPeerFlagBits.holepunched)) 'H',
  ];
  return out.join(' ');
}
