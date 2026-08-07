import 'package:fushi/src/media/torrent/anime_download_config.dart';

/// 单个种子的上传/做种度量（内置引擎 `FtTorrentStatus` 投影，纯数据）。
class TorrentUploadMetrics {
  const TorrentUploadMetrics({
    required this.isSeeding,
    required this.uploaded,
    required this.downloaded,
    required this.seedingElapsedMs,
  });

  /// 是否已进入做种阶段（下载完成）。
  final bool isSeeding;

  /// 累计上传字节。
  final int uploaded;

  /// 累计下载字节（分享率分母）。
  final int downloaded;

  /// 进入做种以来经过的毫秒数（未开始做种时应传 0）。
  final int seedingElapsedMs;
}

/// 判定某种子当前是否应允许上传/做种。纯函数，无副作用，便于单测——
/// 内置引擎宿主 tick 用它算出每个种子的期望上传状态，再落到正确原语
/// （BUG-1293：总开关走会话级 `setUnchokeSlots`，做种停止走 `pauseTorrent`；
/// **绝不用 upload_mode**——那个 flag 是「停止下载」，与关上传正好相反）。
/// 语义（用户诉求：默认关上传、开启后可设做种时长/分享率）：
///
/// - 总开关 [QbConnectionConfig.uploadEnabled] 关 → 一律不上传（返回 false）；
/// - 开启后，做种时长超过 [QbConnectionConfig.seedTimeLimitMinutes]（>0 生效）
///   → 停止上传；
/// - 开启后，分享率（uploaded/downloaded）达到
///   [QbConnectionConfig.seedRatioLimit]（>0 生效，需 downloaded>0）→ 停止上传；
/// - 其余情况允许上传（返回 true）。
///
/// 上限只在做种阶段截停：下载途中即便触碰阈值也保持上传（否则会拖慢
/// tit-for-tat 下载）。做种时长以 [TorrentUploadMetrics.seedingElapsedMs] 计。
bool shouldAllowUpload(
  QbConnectionConfig config,
  TorrentUploadMetrics metrics,
) {
  if (!config.uploadEnabled) return false;
  // 下载阶段（未做种）：允许上传以换取下载速度，不套用做种上限。
  if (!metrics.isSeeding) return true;

  final int limitMinutes = config.seedTimeLimitMinutes;
  if (limitMinutes > 0 &&
      metrics.seedingElapsedMs >= limitMinutes * 60 * 1000) {
    return false;
  }

  final double ratioLimit = config.seedRatioLimit;
  if (ratioLimit > 0 && metrics.downloaded > 0) {
    final double ratio = metrics.uploaded / metrics.downloaded;
    if (ratio >= ratioLimit) return false;
  }

  return true;
}
