import 'dart:async' show FutureOr;
import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/widgets.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 装一个插件包：与安装按钮共用的「校验 → 展示清单 / 权限 / 签名 → 用户确认 →
/// 安装」流程（音乐插件 `installMusicPluginPackage`、追踪插件
/// `TrackingPluginsSection` 的安装）。[context] 是落点自己的、此刻挂载着的 context。
typedef PluginPackageInstaller =
    FutureOr<void> Function(BuildContext context, Uint8List bytes);

/// 插件管理类页面（插件音源管理、音乐来源、歌词来源、追踪插件）的文件拖放落点。
///
/// 拖入的插件包（[pluginPackagePathsOf]：`.fushiplug` / `.zip`，与安装按钮的文件
/// 选择器同一份扩展名）逐个读成字节交给 [install]——和按钮走同一条安装流程，拖放
/// 不另写一套校验 / 确认。拖进来的没有插件包时给明确提示，不静默（BUG-4712）。
///
/// 读文件失败等异常不在这里接：[FushiFileDropTarget.runDrop] 是所有拖放入口的唯一
/// 错误咽喉，会弹失败提示。移动端没有桌面拖放，[FushiFileDropTarget] 直接透传 child。
class PluginPackageDropTarget extends StatelessWidget {
  const PluginPackageDropTarget({
    required this.install,
    required this.child,
    this.debugLabel,
    super.key,
  });

  final PluginPackageInstaller install;
  final Widget child;
  final String? debugLabel;

  @override
  Widget build(BuildContext context) => FushiFileDropTarget(
    debugLabel: debugLabel ?? 'plugin-package',
    onDrop: (List<String> paths, Offset _) => _installDropped(context, paths),
    child: child,
  );

  Future<void> _installDropped(BuildContext context, List<String> paths) async {
    final List<String> packages = pluginPackagePathsOf(paths);
    if (packages.isEmpty) {
      FushiToast.show(
        msg: t.drag_drop_unsupported_on_plugins,
        severity: ToastSeverity.warning,
      );
      return;
    }
    for (final String path in packages) {
      final Uint8List bytes = await File(path).readAsBytes();
      if (!context.mounted) return;
      await install(context, bytes);
    }
  }
}
