import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show runBackupImportFlowForFile;

/// 就地导入已下好的推荐包，走备份导入的共享编排（确认覆盖/合并 → 导入 → 重启）。
///
/// 推荐包本身就是一份 Fushi 备份 zip，所以导入没有第二条路：与设置页「导入备份」
/// 和新手引导「导入推荐包」都是同一个 [runBackupImportFlowForFile]。
///
/// 提成库级函数是因为发起点已经有三个（新手引导那一步、设置 → 系统那一行、首页
/// 迷你条），而 [RecommendedPackDownloadController.markImportStarted] 这个配对
/// 动作漏一处就意味着重启后那 9.5 GB 残包永远留在盘上（BUG-2109 的形状）。
/// controller 自己**不发起**导入——导入要用户确认覆盖/合并并重启进程，它不能替
/// 用户按。
Future<void> importDownloadedRecommendedPack(AppModel appModel) async {
  final RecommendedPackDownloadController controller =
      appModel.recommendedPackDownloadController;
  await runBackupImportFlowForFile(
    appModel: appModel,
    filePath: controller.packFile.path,
    onImportConfirmed: controller.markImportStarted,
  );
}
