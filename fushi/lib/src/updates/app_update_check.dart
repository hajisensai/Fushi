/// 手动「立即检查更新」的唯一编排入口。
///
/// 设置页的按钮与更新中心里的「app 新版本」条目都落到这里：检查 → 弹「发现新
/// 版本」对话框 → 应用内下载 + 安装（能自装的平台）/ 前往本平台分发入口（iOS /
/// Linux）。app 版本更新**不再有**任何「打开发布页」的裸跳转——那条链路把用户
/// 丢到浏览器手动下载，而 UpdateChecker 早就有完整的应用内安装。
library;

import 'package:flutter/widgets.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/utils.dart';

/// TODO-898：手动「立即检查更新」防连点旗标（模块级）。UI 重入保护真正靠它——
/// UpdateChecker 内部的 `_activeCheckCancellation` 是「中断」语义、不挡重入。
bool _manualCheckInFlight = false;

/// 手动「立即检查更新」编排（TODO-898）。
///
/// 手动语义：`neverRemind: false`（无视用户「免提醒」偏好，主动点就要看到结果）+
/// `autoInstall: false`（发现新版只弹确认对话框，不沿用自动安装偏好静默装）。
/// 三种反馈走 toast：点击即时「检查中」、已是最新、检查失败；发现新版复用
/// UpdateChecker 既有对话框 → 应用内下载安装。
Future<void> checkAppUpdateNow(BuildContext context, AppModel appModel) async {
  if (_manualCheckInFlight) return;
  _manualCheckInFlight = true;
  // TODO-1024 / BUG-479：缓存优先即时反馈——先读上次检查结果（按当前通道），据它立刻给
  // 「已是最新已知 vX」/「发现新版 vY」（校验中…）的乐观提示，不等网络；网络刷新随后
  // 在后台校验，结果以既有 onUpToDate / 对话框收口。无缓存（首检/畸形/换通道）才退回
  // 原「正在检查…」提示。
  // BUG-1836：同 home_page，半更新态下 exe 版本资源谎报新版本，
  // 据它比较会永判「已是最新」，用户困在旧代码里没有出路。
  final String currentVersion = resolveCurrentAppVersion(
    appModel.packageInfo.version,
  );
  final String currentBuildNumber = appModel.packageInfo.buildNumber;
  final UpdateChannel channel = appUpdateChannelOf(appModel);
  // BUG-846「谁后用谁」：缓存乐观比较用本机 release sequence（无后缀 `X.Y.Z` 正式版包 /
  // beta/debug 包都能取到），与网络路径 scheduleCheck 同源。远端 seq 从缓存的 latestTag 串
  // 自取（beta/debug 带尾号；正式版无 → 保守走基版本比较，网络刷新随后收口）。
  final int? currentReleaseSeq = currentReleaseSequence(
    version: currentVersion,
    buildNumber: currentBuildNumber,
  );
  final UpdateCheckCacheEntry? cached = cachedEntryForChannel(
    appModel.updateCheckCache,
    channel,
  );
  if (cached != null) {
    final bool newer = updateTagIsNewerThanCurrent(
      cached.latestTag,
      currentVersion,
      channel,
      localSeq: currentReleaseSeq,
    );
    FushiToast.show(
      msg: newer
          ? t.update_cached_newer(version: cached.latestTag)
          : t.update_cached_up_to_date(version: cached.latestTag),
      severity: ToastSeverity.info,
    );
  } else {
    FushiToast.show(msg: t.update_checking_now, severity: ToastSeverity.info);
  }
  try {
    await UpdateChecker.scheduleCheck(
      context,
      currentVersion,
      currentBuildNumber: currentBuildNumber,
      neverRemind: false,
      autoInstall: false,
      betaChannel: appModel.updateBetaChannel,
      debugChannel: appModel.updateDebugChannel,
      customProxy: appModel.updateCustomProxy,
      // 网络刷新跑完写回缓存，下次手动检查直接乐观显示（恒快）。
      cacheWriter: appModel.setUpdateCheckCache,
      onUpToDate: () => FushiToast.show(
        msg: t.update_already_latest,
        severity: ToastSeverity.info,
      ),
      onError: (Object _) => FushiToast.show(
        msg: t.update_check_failed,
        severity: ToastSeverity.error,
      ),
    );
  } finally {
    _manualCheckInFlight = false;
  }
}

/// 当前设置选中的更新通道（与 [UpdateChecker.scheduleCheck] 内的
/// debug > beta > stable 优先级一致）。
UpdateChannel appUpdateChannelOf(AppModel appModel) {
  if (appModel.updateDebugChannel) return UpdateChannel.debug;
  if (appModel.updateBetaChannel) return UpdateChannel.beta;
  return UpdateChannel.stable;
}
