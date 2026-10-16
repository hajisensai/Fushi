/// 控制通道（`fushi_cli update …`）上的应用自更新：检查 → 后台下载 → 确认安装。
///
/// 与设置页「立即检查更新」→「发现新版本」对话框 → 应用内下载安装是同一条链路：
/// 查版本走 [HeadlessUpdateFlow.checkAvailableUpdate]（与 scheduleCheck 同一套拉取 /
/// 选包 / 比较，并写回同一个检查缓存），下载走 [HeadlessUpdateFlow.download]（同一个
/// 下载引擎、同一把版本级互斥锁、同一个下载浮层——本机的人看得见，也能点「取消」），
/// 安装走同一个 [PlatformUpdater.apply]（桌面：安装器接班，本进程退出并在装好后重启）。
///
/// 只是把对话框里的两次「点按钮」换成了两条命令：`update download` 起后台任务
/// （[SettingsCliTaskRegistry]，进度 / 取消走 `task get` / `update cancel`），
/// `update install --yes` 安装已下好的包。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_landing.dart';
import 'package:fushi/utils.dart';

/// 更新下载任务在 [SettingsCliTaskRegistry] 里的种类名。
const String kAppUpdateDownloadTaskKind = 'update-download';

/// 安装任务的种类名（安装要先把应答送出去再交给安装器，见 [installAppUpdateForCli]）。
const String kAppUpdateInstallTaskKind = 'update-install';

/// 已下载好、等 `update install` 的更新包。
class AppUpdateDownloaded {
  const AppUpdateDownloaded({required this.version, required this.file});

  final String version;
  final File file;
}

/// 测试缝：替换「查版本 / 下载 / 安装」三步（生产 = [HeadlessUpdateFlow] + 本平台
/// [PlatformUpdater]）。
class AppUpdateCliBackend {
  const AppUpdateCliBackend({
    required this.updater,
    required this.check,
    required this.download,
  });

  final PlatformUpdater updater;
  final Future<HeadlessUpdateCheck?> Function(AppModel appModel) check;
  final Future<File> Function(
    AppModel appModel,
    HeadlessUpdateCheck update,
    UpdateDownloadCancellation cancellation,
    void Function(double progress) onProgress,
  )
  download;
}

AppUpdateCliBackend _productionBackend() {
  final PlatformUpdater updater = updaterForCurrentPlatform();
  return AppUpdateCliBackend(
    updater: updater,
    check: (AppModel appModel) => HeadlessUpdateFlow.checkAvailableUpdate(
      currentVersion: resolveCurrentAppVersion(appModel.packageInfo.version),
      currentBuildNumber: appModel.packageInfo.buildNumber,
      channel: appUpdateChannelOf(appModel),
      customProxy: appModel.updateCustomProxy,
      updater: updater,
      cacheWriter: appModel.setUpdateCheckCache,
    ),
    download:
        (
          AppModel appModel,
          HeadlessUpdateCheck update,
          UpdateDownloadCancellation cancellation,
          void Function(double progress) onProgress,
        ) => HeadlessUpdateFlow.download(
          asset: update.asset!,
          version: update.version,
          updater: updater,
          customProxy: appModel.updateCustomProxy,
          overlay: appModel.navigatorKey.currentState?.overlay,
          cancellation: cancellation,
          onProgress: onProgress,
        ),
  );
}

/// 当前用的后端；测试用 [debugSetAppUpdateCliBackend] 换掉。
AppUpdateCliBackend? _backendOverride;
AppUpdateDownloaded? _downloaded;

AppUpdateCliBackend get _backend => _backendOverride ?? _productionBackend();

/// 测试缝：换掉后端并清掉「已下载」记录；传 null 还原。
void debugSetAppUpdateCliBackend(AppUpdateCliBackend? backend) {
  _backendOverride = backend;
  _downloaded = null;
}

/// 最近一次 `update download` 下好的包（还在磁盘上才算）。
AppUpdateDownloaded? get appUpdateDownloadedForCli {
  final AppUpdateDownloaded? done = _downloaded;
  if (done == null || !done.file.existsSync()) return null;
  return done;
}

String _channelName(AppModel appModel) => appUpdateChannelOf(appModel).name;

/// `update check`：查一次本平台可装的新版本（不弹对话框，写回检查缓存）。
Future<Map<String, Object?>> checkAppUpdateForCli(AppModel appModel) async {
  final AppUpdateCliBackend backend = _backend;
  final String current = resolveCurrentAppVersion(appModel.packageInfo.version);
  if (!backend.updater.supportsUpdateCheck) {
    throw StateError('本平台不支持检查更新');
  }
  final HeadlessUpdateCheck? update = await backend.check(appModel);
  if (update == null) {
    return <String, Object?>{
      'currentVersion': current,
      'channel': _channelName(appModel),
      'updateAvailable': false,
    };
  }
  final bool installable =
      backend.updater.supportsInAppInstall && update.asset != null;
  String? landing;
  if (!installable && update.htmlUrl != null) {
    final UpdateLanding target = await backend.updater.resolveDownloadLanding(
      update.htmlUrl!,
    );
    landing = target.url;
  }
  return <String, Object?>{
    'currentVersion': current,
    'channel': _channelName(appModel),
    'updateAvailable': true,
    'version': update.version,
    'releaseNotes': update.releaseNotes,
    if (update.htmlUrl != null) 'releaseUrl': update.htmlUrl,
    'installable': installable,
    if (update.asset != null) 'asset': update.asset!.name,
    if (update.asset?.sizeBytes != null) 'sizeBytes': update.asset!.sizeBytes,
    // 不能应用内安装的平台（iOS / Linux）只能去本平台分发入口装。
    if (landing != null) 'downloadPage': landing,
  };
}

/// `update download`：后台下载本平台可装的新版本，立即返回任务快照。
SettingsCliTask startAppUpdateDownloadForCli(
  AppModel appModel, {
  SettingsCliTaskRegistry? registry,
}) {
  final SettingsCliTaskRegistry tasks =
      registry ?? SettingsCliTaskRegistry.instance;
  final AppUpdateCliBackend backend = _backend;
  if (!backend.updater.supportsInAppInstall) {
    throw StateError('本平台不能应用内安装更新；用 update check 拿到本平台的下载页');
  }
  final SettingsCliTask? active = tasks.activeOf(kAppUpdateDownloadTaskKind);
  if (active != null) {
    throw StateError('已有更新下载在进行（任务 ${active.id}）');
  }
  return tasks.start(
    kind: kAppUpdateDownloadTaskKind,
    isCancellation: (Object e) => e is UpdateDownloadCancelledException,
    describe: describeUpdateNetworkFailureReason,
    run: (SettingsCliTask task) async {
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();
      task
        ..onCancel = cancellation.cancel
        ..report(phase: 'checking');
      final HeadlessUpdateCheck? update = await backend.check(appModel);
      if (cancellation.isCancelled) throw const SettingsCliTaskCancelled();
      if (update == null) {
        return <String, Object?>{'updateAvailable': false};
      }
      if (update.asset == null) {
        throw StateError('新版本 ${update.version} 没有本平台可应用内安装的包');
      }
      task.detail['version'] = update.version;
      task.report(phase: 'downloading', progress: 0);
      final File file = await backend.download(
        appModel,
        update,
        cancellation,
        (double value) => task.report(progress: value),
      );
      _downloaded = AppUpdateDownloaded(version: update.version, file: file);
      return <String, Object?>{
        'updateAvailable': true,
        'version': update.version,
        'file': file.path,
        'sizeBytes': file.lengthSync(),
      };
    },
  );
}

/// `update cancel`：取消进行中的更新下载（与下载浮层「取消」同一个令牌）。
Map<String, Object?> cancelAppUpdateDownloadForCli({
  SettingsCliTaskRegistry? registry,
}) {
  final SettingsCliTaskRegistry tasks =
      registry ?? SettingsCliTaskRegistry.instance;
  final SettingsCliTask? active = tasks.activeOf(kAppUpdateDownloadTaskKind);
  if (active == null) throw StateError('没有进行中的更新下载');
  final SettingsCliCancelOutcome outcome = tasks.cancel(active);
  return <String, Object?>{'outcome': outcome.name, 'task': active.toJson()};
}

/// `update install --yes`：安装 `update download` 下好的包。
///
/// 立即返回安装任务快照：桌面上 [PlatformUpdater.apply] 交给安装器后**本进程会退出**
/// （装好后自动重启），所以安装要排在应答送出之后才开始（同控制通道 quit：先回
/// 202 再退出）——否则终端只能看到连接断开。安装器启动前就失败（被占用 / 目录不可写）
/// 的，任务以 failed 结束，`task get` 看得到原因。
SettingsCliTask installAppUpdateForCli(
  AppModel appModel, {
  SettingsCliTaskRegistry? registry,
}) {
  final SettingsCliTaskRegistry tasks =
      registry ?? SettingsCliTaskRegistry.instance;
  final AppUpdateCliBackend backend = _backend;
  if (!backend.updater.supportsInAppInstall) {
    throw StateError('本平台不能应用内安装更新');
  }
  if (tasks.activeOf(kAppUpdateDownloadTaskKind) != null) {
    throw StateError('更新还在下载，等下载完成（task get <id> --wait）再安装');
  }
  final AppUpdateDownloaded? done = appUpdateDownloadedForCli;
  if (done == null) {
    throw StateError('没有已下载好的更新包；先 update download');
  }
  if (HeadlessUpdateFlow.isActive(done.version)) {
    throw StateError('${done.version} 的更新流程已在进行（app 里的对话框或下载）');
  }
  final bool restarts = !Platform.isAndroid;
  return tasks.start(
    kind: kAppUpdateInstallTaskKind,
    run: (SettingsCliTask task) async {
      task
        ..detail['version'] = done.version
        ..detail['restartRequired'] = restarts
        ..detail['note'] = restarts
            ? '安装器接班后 app 会退出，装好后自动重启；控制通道会随之断开'
            : '系统安装确认已在设备上弹出，需要在设备上点「安装」'
        ..report(phase: 'installing')
        ..markCommitting();
      // 先让控制通道把本次应答送出去（同 ctl_server 的 quit），再交给安装器。
      await Future<void>(() {});
      FushiToast.show(msg: t.update_installing, severity: ToastSeverity.info);
      await backend.updater.apply(done.file, done.version);
      return <String, Object?>{
        'version': done.version,
        'restartRequired': restarts,
      };
    },
  );
}
