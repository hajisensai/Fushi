/// 新手引导「系统权限」一步（仅 Android）要处理的权限，及其查询 / 申请。
///
/// 每个权限的真相源都是**既有**入口，这里只做薄转发，不另写一套权限逻辑：
/// - 通知：`UpdateFeedService.enableSystemNotifications`（与设置页「系统通知」开关
///   同一条路径，偏好与系统授权一起开）；
/// - 悬浮窗：悬浮球通道的 `canDrawOverlays` / `requestOverlayPermission`；
/// - 所有文件访问：`PlatformPermissionService` 的外部存储权限（按 SDK 选权限）。
library;

import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi_platform/fushi_platform.dart';

/// 引导里列出的系统权限，按出现顺序。
enum OnboardingSystemPermission {
  /// 通知（Android 13+ 默认关）：下载进度、新章节 / 新剧集、更新提醒。
  notifications,

  /// 悬浮窗（「显示在其他应用上层」，默认关）：悬浮球、悬浮词典、悬浮歌词。
  overlay,

  /// 所有文件访问：按真实路径扫描本地媒体文件夹。
  storage,
}

/// 查询 / 申请的端口。生产实现见 [AppOnboardingSystemPermissions]；测试注入假实现。
abstract class OnboardingSystemPermissions {
  /// 只查询，不弹任何系统界面。
  Future<bool> isGranted(OnboardingSystemPermission permission);

  /// 申请（弹系统对话框或跳系统设置页）。**只能由用户的显式点击触发**
  /// （BUG-2498：启动期申请会被 MIUI 权限界面的崩溃连坐）。返回后状态不一定已变
  /// ——跳设置页的权限要等用户回到应用，调用方在回到前台时重新 [isGranted]。
  Future<void> request(OnboardingSystemPermission permission);
}

class AppOnboardingSystemPermissions implements OnboardingSystemPermissions {
  AppOnboardingSystemPermissions({
    required UpdateFeedService updateFeed,
    required PlatformPermissionService permissionService,
  }) : _updateFeed = updateFeed,
       _permissionService = permissionService;

  final UpdateFeedService _updateFeed;
  final PlatformPermissionService _permissionService;

  @override
  Future<bool> isGranted(OnboardingSystemPermission permission) {
    switch (permission) {
      case OnboardingSystemPermission.notifications:
        return _updateFeed.refreshSystemNotificationsGranted();
      case OnboardingSystemPermission.overlay:
        return FloatingBallChannel.canDrawOverlays();
      case OnboardingSystemPermission.storage:
        return _permissionService.hasExternalStoragePermission();
    }
  }

  @override
  Future<void> request(OnboardingSystemPermission permission) async {
    switch (permission) {
      case OnboardingSystemPermission.notifications:
        await _updateFeed.enableSystemNotifications();
      case OnboardingSystemPermission.overlay:
        await FloatingBallChannel.requestOverlayPermission();
      case OnboardingSystemPermission.storage:
        await _permissionService.requestExternalStoragePermission();
    }
  }
}
