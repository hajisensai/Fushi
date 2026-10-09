/// 插图全屏缩放查看：阅读器正文点图 / 插图册点大图 / 书架端插图册三处共用的
/// 一条缩放路径（半透明遮罩路由 + [InteractiveViewer] + 点图关闭），以及围绕
/// 「一张磁盘图片文件」的复制 / 分享 / 右键菜单动作。宿主只负责解析出 [File]
/// 并决定要不要挂上下文菜单。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'package:fushi_engine/epub/epub_book.dart' show fallbackMimeType;
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 缩放看图的路由：非不透明、深色 scrim、点 scrim 关闭。[builder] 提供路由
/// 内容（通常是 [IllustrationZoomViewer]，宿主可在外面再包上下文菜单触发口）。
Route<void> illustrationZoomRoute(BuildContext context, WidgetBuilder builder) {
  return PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.87),
    barrierDismissible: true,
    pageBuilder: (BuildContext routeContext, _, __) => builder(routeContext),
  );
}

/// 一张图的缩放查看：点图关闭路由；[onLongPress]（移动端分享）由宿主决定挂不挂。
class IllustrationZoomViewer extends StatelessWidget {
  const IllustrationZoomViewer({
    super.key,
    required this.file,
    required this.diagnosticTag,
    this.onLongPress,
  });

  final File file;

  /// 坏图解码失败写诊断日志时的来源标签。
  final String diagnosticTag;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final Widget viewer = GestureDetector(
      onTap: () => Navigator.pop(context),
      onLongPress: onLongPress,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 10,
        child: Center(
          child: Image.file(
            file,
            fit: BoxFit.contain,
            // BUG-2496：坏图解码失败退回占位图标，不当致命 FlutterError。
            errorBuilder: (_, Object error, __) {
              ErrorLogService.instance.logDiagnostic(
                '$diagnosticTag.coverDecode',
                '${file.path}: $error',
              );
              return const FushiIcon(FushiIcons.brokenImage, size: 64);
            },
          ),
        ),
      ),
    );
    // M3E 图片查看器：图从 0.92 弹到原尺寸（expressive spatial），右上角一枚
    // 浮在 scrim 上的 tonal 关闭圆钮（点图 / 点遮罩关闭照旧，这枚给鼠标与
    // 不知道「点图关闭」的人一个明确出口）。减弱动态效果 / 墨水屏不弹。
    final Duration enter = fushiMotionDuration(
      context,
      const Duration(milliseconds: 420),
    );
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: enter == Duration.zero ? 1 : 0, end: 1),
          duration: enter,
          builder: (BuildContext context, double t, Widget? child) {
            final double pop = const Cubic(0.42, 1.67, 0.21, 0.90).transform(t);
            return Opacity(
              opacity: FushiMotion.enter.transform(t),
              child: Transform.scale(scale: 0.92 + 0.08 * pop, child: child),
            );
          },
          child: viewer,
        ),
        PositionedDirectional(
          top: 0,
          end: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FushiIconButton(
                icon: FushiIcons.close,
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                backgroundColor: isGlassDesign(context)
                    ? null
                    : cs.secondaryContainer.withValues(alpha: 0.92),
                enabledColor: isGlassDesign(context)
                    ? null
                    : cs.onSecondaryContainer,
                onTap: () => Navigator.pop(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 移动端：把图片文件交给系统分享面板。
Future<void> shareImageFile(File file) async {
  if (!file.existsSync()) {
    FushiToast.show(
      msg: t.reader_image_file_unavailable,
      severity: ToastSeverity.error,
    );
    return;
  }
  try {
    await FushiShare.shareFiles(<XFile>[
      XFile(file.path, mimeType: fallbackMimeType(file.path)),
    ], subject: p.basename(file.path));
  } catch (e) {
    FushiToast.show(
      msg: t.reader_image_share_failed(error: e),
      severity: ToastSeverity.error,
    );
  }
}

/// Windows：经原生 `copyImageFile` channel 把图片文件放进剪贴板（CF_DIB）。
Future<void> copyImageFileToClipboard(File file) async {
  if (!file.existsSync()) {
    FushiToast.show(
      msg: t.reader_image_file_unavailable,
      severity: ToastSeverity.error,
    );
    return;
  }
  try {
    await FushiChannels.clipboardImage.invokeMethod<void>(
      'copyImageFile',
      <String, String>{'path': file.path},
    );
    FushiToast.show(
      msg: t.copied_to_clipboard,
      severity: ToastSeverity.success,
    );
  } catch (e) {
    FushiToast.show(
      msg: t.reader_image_copy_failed(error: e),
      severity: ToastSeverity.error,
    );
  }
}

/// Windows 右键图片的「复制图片」菜单，锚在 [globalPosition]；选中后调 [onCopy]。
Future<void> showImageCopyContextMenu(
  BuildContext context,
  Offset globalPosition, {
  required Future<void> Function() onCopy,
}) async {
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  // BUG-381: [globalPosition] 是真实屏幕坐标（右键路径来自阅读器 State 的 RenderBox
  // localToGlobal，放大图路径来自 details.globalPosition；两者都在「净缩放=1 的真实
  // 视口空间」——阅读器被 FushiAppUiScaleNeutralizer 中和回 1.0）。但 showMenu 的
  // RelativeRect 落在它路由 Overlay 的坐标系，而该 Overlay 在全局 FushiAppUiScale 的
  // FittedBox 之内（缩放后的画布空间）。直接把真实屏幕坐标当画布坐标喂给 showMenu，
  // 界面大小≠100% 时菜单会偏离图片 factor≈scale（BUG-261 同型，视频右键已修）。
  //
  // 修法与 BUG-129/261 同范式：不读 scale 数值逆算（自动模式下生效 scale ≠
  // appModel.appUiScale），而用 Overlay 的 RenderBox 把锚点从真实屏幕坐标沿真实渲染
  // 变换链映射到 Overlay 本地坐标系——其间的 FittedBox 缩放被 render transform 自动
  // 吸收，对任意 scale（含自动模式）自洽无残差；scale=1 时变换为单位阵，逐像素等价
  // （向后兼容）。
  //
  // BUG-1438：菜单内容**不能**再乘界面缩放。菜单渲染在根 Overlay，也就是全局
  // FushiAppUiScale 的缩放画布内，画布→屏幕这一跳已经把它按 scale 放大了一次；
  // 阅读器 chrome 之所以要手动 ×_readerChromeScale，是因为 chrome 在
  // FushiAppUiScaleNeutralizer **之内**（净缩放=1，不跟随），而菜单在**之外**。
  // 旧代码把 chrome 的规则错套到菜单上 → 视觉尺寸是 scale²：实测同样写
  // `fontSize: 14 * menuScale`，chrome 渲染成 40 而菜单 80（scale=2）。所以这里
  // 写常量，让菜单与 app 其它右键菜单（视频 / 合集 / 标签管理）口径一致。
  final Offset anchor = overlay.globalToLocal(globalPosition);
  final String? action = await showFushiMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
      Offset.zero & overlay.size,
    ),
    constraints: const BoxConstraints(minWidth: 112.0, maxWidth: 280.0),
    menuPadding: const EdgeInsets.symmetric(vertical: 8.0),
    items: <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'copy',
        height: kMinInteractiveDimension,
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const FushiIcon(FushiIcons.copy, size: 18.0),
            const SizedBox(width: 12.0),
            Text(t.reader_copy_image, style: const TextStyle(fontSize: 14.0)),
          ],
        ),
      ),
    ],
  );
  if (action == 'copy') {
    await onCopy();
  }
}
