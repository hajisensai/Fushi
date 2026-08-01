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
