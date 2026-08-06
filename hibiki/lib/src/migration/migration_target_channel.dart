import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

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
    final bool? installed = await HibikiChannels.migration
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
    final bool? ok = await HibikiChannels.migration
        .invokeMethod<bool>('launchPackage', <String, Object?>{
      'package': kFushiPackageName,
    });
    return ok ?? false;
  }

  /// 弹系统卸载确认框（ACTION_DELETE）。用户可能点「取消」——调用方必须
  /// 事后用 [isFushiInstalled]/包探测复查，不得乐观标记成功（计划 P2-3）。
  Future<void> requestUninstall(String packageName) async {
    if (!_supported) return;
    await HibikiChannels.migration
        .invokeMethod<void>('requestUninstall', <String, Object?>{
      'package': packageName,
    });
  }

  /// 启/停 PROCESS_TEXT 系统取词入口（组件级，系统菜单里真的少一项）。
  Future<void> setProcessTextEnabled(bool enabled) async {
    if (!_supported) return;
    await HibikiChannels.migration
        .invokeMethod<void>('setProcessTextEnabled', <String, Object?>{
      'enabled': enabled,
    });
  }
}
