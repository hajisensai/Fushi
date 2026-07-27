/// mokuro.moe 卷下载事件 → 进度值/阶段文案的共享换算（「在线目录」对话框
/// 内联面板与「下载」页任务区同源渲染，避免两处各写一份漂移）。
library;

import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki/utils.dart';

/// 当前卷的确定性进度（0..1）；未知总量阶段回 null（转圈条）。
double? mokuroMoeProgressValue(MokuroMoeVolumeDownloadEvent? event) {
  if (event == null) return null;
  switch (event.stage) {
    case MokuroMoeDownloadStage.downloadingCbz:
      final int? total = event.totalBytes;
      if (total == null || total <= 0) return null;
      return (event.receivedBytes / total).clamp(0.0, 1.0);
    case MokuroMoeDownloadStage.importing:
      if (event.pagesTotal <= 0) return null;
      return (event.pagesDone / event.pagesTotal).clamp(0.0, 1.0);
    case MokuroMoeDownloadStage.done:
      return 1;
    case MokuroMoeDownloadStage.downloadingMokuro:
    case MokuroMoeDownloadStage.extracting:
      return null;
  }
}

/// 当前卷的阶段文案（含 CBZ 字节 / 导入页数进度）。
String mokuroMoeStageLabel(MokuroMoeVolumeDownloadEvent? event) {
  switch (event?.stage) {
    case null:
    case MokuroMoeDownloadStage.downloadingMokuro:
      return t.manga_online_stage_mokuro;
    case MokuroMoeDownloadStage.downloadingCbz:
      final int received = event!.receivedBytes;
      final int? total = event.totalBytes;
      final String bytes = total != null && total > 0
          ? '${_mb(received)} / ${_mb(total)} MB'
          : '${_mb(received)} MB';
      return '${t.manga_online_stage_cbz} $bytes';
    case MokuroMoeDownloadStage.extracting:
      return t.manga_online_stage_extract;
    case MokuroMoeDownloadStage.importing:
      return event!.pagesTotal > 0
          ? t.manga_ocr_wizard_page_progress(
              done: event.pagesDone, total: event.pagesTotal)
          : t.manga_ocr_wizard_importing;
    case MokuroMoeDownloadStage.done:
      return t.manga_ocr_wizard_done;
  }
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
