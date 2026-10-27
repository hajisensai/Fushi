import 'package:fushi_engine/media/torrent/anime_download_config.dart';

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
/// （BUG-1293：总开关走会话级 `setUnchokeSlots`；做种阶段截停走
/// `pauseTorrent`；下载阶段截停走单种子 `setTorrentUploadBlocked`；
/// **绝不用 upload_mode**——那个 flag 是「停止下载」，与关上传正好相反）。
/// 语义（用户诉求：默认关上传、开启后可设做种时长/分享率）：
///
/// - 总开关 [QbConnectionConfig.uploadEnabled] 关 → 一律不上传（返回 false）；
/// - 开启后，分享率（uploaded/downloaded，**整个生命周期累计**）达到
///   [QbConnectionConfig.seedRatioLimit]（>0 生效，需 downloaded>0）→ 停止
///   上传——**下载途中也算**（fRmEhU4XIK：所有者 2026-10-27 拍板，旧版只在
///   做种阶段截停，下载期间上传不受限，用户设 1.3 最终远超 1.3）；
/// - 开启后，做种时长超过 [QbConnectionConfig.seedTimeLimitMinutes]（>0 生效）
///   → 停止上传；时长只从进入做种起算（[TorrentUploadMetrics.seedingElapsedMs]），
///   下载阶段不适用；
/// - 其余情况允许上传（返回 true）。
bool shouldAllowUpload(
  QbConnectionConfig config,
  TorrentUploadMetrics metrics,
) {
  if (!config.uploadEnabled) return false;

  final double ratioLimit = config.seedRatioLimit;
  if (ratioLimit > 0 && metrics.downloaded > 0) {
    final double ratio = metrics.uploaded / metrics.downloaded;
    if (ratio >= ratioLimit) return false;
  }

  if (!metrics.isSeeding) return true;

  final int limitMinutes = config.seedTimeLimitMinutes;
  if (limitMinutes > 0 &&
      metrics.seedingElapsedMs >= limitMinutes * 60 * 1000) {
    return false;
  }

  return true;
}
