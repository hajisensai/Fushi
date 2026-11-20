import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_state.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show BackupImportMode, BackupImportPreset, runBackupImportFlowForFile;

/// 推荐包在 app 内导入时确认框**预选**的导入方式：合并。
///
/// BUG-4698（推荐包覆盖书库）：推荐包本身是一份净化过的 Fushi 备份 zip，里面只有
/// 词典元数据、音频来源注册项与对应的资源文件（见
/// `tool/pack/recommended_pack_database.dart`）。早先 app 内发起点弹的是通用备份导入
/// 确认框，而那个框默认选「覆盖」——用户照默认点下去，整库被包里的库替换，漫画 /
/// 小说 / 进度 / 统计全没了。合并只「补缺」不删不改，推荐包需要的资源合并全都装得上
/// （音频来源注册项的并集见 `BackupMergeEngine._mergeAudioSourcePrefs`）。
///
/// 拍板台 pr3449（维护者：「要弹就得弹吧，默认合并」）：确认框照弹——用户在导入前
/// 仍能看到包的内容摘要、按分类取舍、或取消——只是打开时预选合并。
const BackupImportMode kRecommendedPackImportMode = BackupImportMode.merge;

/// 把 [filePath] 处的推荐包走备份导入的共享编排（校验 → 确认框 → 导入 → 重启）导入；
/// 确认框打开时预选 [kRecommendedPackImportMode]（合并）。
///
/// 所有 app 内的推荐包入口（新手引导那一步的「现在导入」与「选择本地包文件」、
/// 设置 → 系统那一行、首页迷你条）都必须经这里，不得直接调
/// [runBackupImportFlowForFile]——那条路径缺省预选的是「覆盖」。
///
/// [preset] 只给控制通道 `dict pack-import --merge|--replace` 用：那里调用方已显式
/// 选了模式并带 `confirm=true`，是知情选择，跳过确认框；app 内入口一律不传。
///
/// [onImportSucceeded] 仅在恢复成功后、重启前回调（语义同
/// [runBackupImportFlowForFile]）。
Future<void> importRecommendedPackFile(
  AppModel appModel, {
  required String filePath,
  required Future<void> Function() onImportSucceeded,
  BackupImportPreset? preset,
}) async {
  await runBackupImportFlowForFile(
    appModel: appModel,
    filePath: filePath,
    preset: preset,
    confirmInitialMode: kRecommendedPackImportMode,
    onImportSucceeded: onImportSucceeded,
  );
}

/// 就地导入已下好的推荐包（[importRecommendedPackFile] 的下载器版本）。
///
/// 提成库级函数是因为发起点已经有三个（新手引导那一步、设置 → 系统那一行、首页
/// 迷你条），而 [RecommendedPackDownloadController.markImportSucceeded] 这个配对
/// 动作漏一处就意味着重启后那 9.5 GB 残包永远留在盘上（BUG-2109 的形状）。
/// controller 自己**不发起**导入——导入会重启进程，它不能替用户按。
///
/// [preset] 缺省 null（弹确认框、预选合并）；控制通道传它显式选的模式。
/// 成功后的待办教程与残包清理回调不变。
Future<void> importDownloadedRecommendedPack(
  AppModel appModel, {
  BackupImportPreset? preset,
}) async {
  final RecommendedPackDownloadController controller =
      appModel.recommendedPackDownloadController;
  await importRecommendedPackFile(
    appModel,
    filePath: controller.packFile.path,
    preset: preset,
    onImportSucceeded: () async {
      await RecommendedPackTutorialState(
        appModel.appDirectory,
      ).markImportSucceeded();
      await controller.markImportSucceeded();
    },
  );
}
