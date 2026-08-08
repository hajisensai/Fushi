import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 迁移目标包名（Phase 0 身份对照表定值）。
const String kFushiPackageName = 'app.fushi.reader';

/// 老包自身包名（迁移代码对旧身份的**有意**引用，守卫白名单锚点）。
const String kHibikiPackageName = 'app.hibiki.reader';

/// P1-3/P1-4 平台能力的类型化封装。
///
/// 仅 Android 有真实实现（`MigrationChannelHandler.java`）；其余平台一律
/// 安全降级（查询返回 false、动作 no-op）——跨包名迁移只存在于 Android。
class MigrationTargetChannel {
  const MigrationTargetChannel();

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 指定包是否已安装（Android 11+ 依赖 manifest `<queries>` 声明该包）。
  Future<bool> isPackageInstalled(String packageName) async {
    if (!_supported) return false;
    final bool? installed = await FushiChannels.migration
        .invokeMethod<bool>('isPackageInstalled', <String, Object?>{
      'package': packageName,
    });
    return installed ?? false;
  }

  /// Fushi 是否已安装（老包导出引导用）。
  Future<bool> isFushiInstalled() => isPackageInstalled(kFushiPackageName);

  /// 前台拉起 Fushi（用户点按钮触发；带 `source=hibiki_migration` extra）。
  /// 返回是否成功发出启动 intent。
  Future<bool> launchFushi() async {
    if (!_supported) return false;
    final bool? ok = await FushiChannels.migration
        .invokeMethod<bool>('launchPackage', <String, Object?>{
      'package': kFushiPackageName,
    });
    return ok ?? false;
  }

  /// 弹系统卸载确认框（ACTION_DELETE）。用户可能点「取消」——调用方必须
  /// 事后用 [isFushiInstalled]/包探测复查，不得乐观标记成功（计划 P2-3）。
  Future<void> requestUninstall(String packageName) async {
    if (!_supported) return;
    await FushiChannels.migration
        .invokeMethod<void>('requestUninstall', <String, Object?>{
      'package': packageName,
    });
  }

  /// 是否持有「所有文件访问权限」（`MANAGE_EXTERNAL_STORAGE`）。
  ///
  /// 迁移中转目录在公共 `Documents/Hibiki/migration`，是**老包**创建的。分区存储
  /// 下本包读不了别的应用创建的非媒体文件，没有这个权限时连清单都会抛
  /// `PathAccessException`——那不是「清单损坏」，是没权限。
  ///
  /// 非 Android 恒 true：跨包名迁移只存在于 Android，其余平台没有这道门。
  Future<bool> hasAllFilesAccess() async {
    if (!_supported) return true;
    final bool? granted =
        await FushiChannels.migration.invokeMethod<bool>('hasAllFilesAccess');
    return granted ?? false;
  }

  /// 跳到系统的「所有文件访问权限」授权页。
  ///
  /// 这个权限**没有**运行时弹框授予的路径（Android 11+ 只允许跳设置页由用户手
  /// 动开）。所以调用方不能 await 到一个「授权结果」——必须在页面 resume 时用
  /// [hasAllFilesAccess] 复查，不得因为跳过设置页就当已授权。
  Future<void> requestAllFilesAccess() async {
    if (!_supported) return;
    await FushiChannels.migration.invokeMethod<void>('requestAllFilesAccess');
  }

  /// 启/停 PROCESS_TEXT 系统取词入口（组件级，系统菜单里真的少一项）。
  Future<void> setProcessTextEnabled(bool enabled) async {
    if (!_supported) return;
    await FushiChannels.migration
        .invokeMethod<void>('setProcessTextEnabled', <String, Object?>{
      'enabled': enabled,
    });
  }
}
