/// 一次捐赠：导出脱敏包到临时文件 → PUT 上传 → 记偏好。界面只管展示阶段与进度。
///
/// 导出与普通「导出 .apkg」同一条路（`openSrsExport` → `exportAnkiPackageFile`）：在主
/// isolate 上 await [exportSrsDonationFile]（流式写盘，不整包进内存）。[SrsDbStore] 持有原生
/// 连接与缓存，不能整个发到别的 isolate；要真正搬进后台 isolate 得先让导出器能在后台按
/// 路径自开一份只读连接，那是导出器（引擎侧）的改动，普通导出也一并受益。
library;

import 'dart:io';

import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/srs/donation/srs_donation_client.dart';

/// 捐赠进行到哪一步。
enum SrsDonationPhase { exporting, uploading }

/// 导出并上传。成功返回服务端状态；失败抛异常（[SrsDonationHttpException] 或导出错误），
/// 临时文件一律删掉。
Future<SrsDonationStatus> runSrsDonation({
  required SrsDbStore store,
  required SrsDonationClient client,
  required SrsDonationPreview preview,
  required String appVersion,
  required bool includeWords,
  required Set<String> excludedNoteIds,
  required void Function(SrsDonationPhase phase) onPhase,
  SrsDonationProgress? onProgress,
  Future<Directory> Function()? tempRoot,
}) async {
  final ({String donorId, String donorKey}) id = srsDonationIdentity(
    store.profileUid,
  );
  final Directory root = await (tempRoot ?? getTemporaryDirectory)();
  final Directory staging = await root.createTemp('fushi_srs_donation_');
  try {
    onPhase(SrsDonationPhase.exporting);
    final File file = File(
      '${staging.path}${Platform.pathSeparator}${id.donorId}.apkg',
    );
    await exportSrsDonationFile(
      store: store,
      file: file,
      donorId: id.donorId,
      appVersion: appVersion,
      includeWords: includeWords,
      excludedNoteIds: excludedNoteIds,
    );
    onPhase(SrsDonationPhase.uploading);
    return await client.upload(
      donorId: id.donorId,
      donorKey: id.donorKey,
      file: file,
      reviews: preview.reviewCount,
      cards: preview.cardCount,
      appVersion: appVersion,
      onProgress: onProgress,
    );
  } finally {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // 临时目录由系统回收。
    }
  }
}
