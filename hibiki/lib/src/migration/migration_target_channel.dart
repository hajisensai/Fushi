import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  /// Fushi 是否已安装（Android 11+ 依赖 manifest `<queries>` 声明）。
  Future<bool> isFushiInstalled() async {
    if (!_supported) return false;
    final bool? installed = await HibikiChannels.migration
        .invokeMethod<bool>('isPackageInstalled', <String, Object?>{
      'package': kFushiPackageName,
    });
    return installed ?? false;
  }

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

  /// [path] 所在卷的可用字节；**测不出一律返回 null**。
  ///
  /// 调用方必须把 null 当「不知道」并硬拦，不得退化成「够用」——导出会把书 /
  /// 词典 / 有声书整份复制到中转目录（数据翻倍），赌一把的代价是导到一半炸、
  /// 中转目录留半截。非 Android 也返回 null（跨包名迁移只存在于 Android）。
  Future<int?> getFreeSpace(String path) async {
    if (!_supported) return null;
    try {
      return await HibikiChannels.migration.invokeMethod<int>(
        'getFreeSpace',
        <String, Object?>{'path': path},
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // 老宿主（未带 getFreeSpace 的 Java 侧）：同样按「测不出」处理。
      return null;
    }
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
