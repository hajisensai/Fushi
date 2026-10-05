import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/media/video/video_m3e_panel_theme.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 面板内容（视频页各 part 的字幕轨 / 音轨 / 画质 / 章节）经本文件拿到面板中性
// 主题的判据与配色 helper。
export 'package:fushi/src/media/video/video_m3e_panel_theme.dart';

/// 视频页浮层面板（设置 / 倍速 / 章节 / 画质 / 字幕抽屉）的统一表面。
///
/// - Apple：浮在画面上的液态玻璃厚档（iOS 26 播放器设置面板 / macOS 26
///   检查器）——深色 #262626 @84%、浅色白 @74%、blur 16，压得住任何亮暗画面，
///   字始终可读；系统降低透明度（[FushiGlassMaterial.off]）时由
///   [fushiGlassSettings] 回落实色。圆角桌面 18、触屏 28（超椭圆）。面板里的
///   分组卡换成一层半透明系统灰（[videoPanelAppleColors]），在玻璃上浮起而不是
///   挖出一块实色黑洞。
/// - MD3（M3 Expressive）：与播放器悬浮胶囊 / 音量倍速浮层同一层无色相中性
///   深色表面（[videoM3eFloatingColor]，#2D2D2D @86%），圆角 28、轻阴影；面板
///   内部读中性主题（[videoM3ePanelTheme]：灰阶容器、白字、强调色仍是 app 主色），
///   浅色主题下也不再是一块白板压在画面上。墨水屏仍是实色 surfaceContainerLow +
///   一圈 outline 描边（不半透明、不换配色）。
class VideoFloatingPanelSurface extends StatelessWidget {
  const VideoFloatingPanelSurface({
    required this.child,
    this.surfaceKey,
    super.key,
  });

  final Widget child;

  /// 挂在表面本体上的 key（测试 / 几何断言按它取面板矩形）。
  final Key? surfaceKey;

  /// 当前设计系统下的面板圆角。
  static double radiusOf(BuildContext context) {
    if (isGlassDesign(context)) return fushiAppleCompact(context) ? 18 : 28;
    return 28;
  }

  @override
  Widget build(BuildContext context) {
    final double radius = radiusOf(context);
    if (isGlassDesign(context)) {
      final ThemeData theme = Theme.of(context);
      final FushiAppleColors apple = videoPanelAppleColors(context);
      return GlassContainer(
        key: surfaceKey,
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: videoPanelGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: theme.copyWith(
            // 只换掉 Apple 色板这一项，其余主题扩展原样保留。
            // 只换掉 Apple 色板这一项，其余主题扩展原样保留。不写元素类型注解：
            // 前端编译器把 `ThemeExtension<dynamic>` 按上界展开，与 analyzer
            // 的推断不一致，显式注解会在热重载时报类型不符。
            extensions: theme.extensions.values
                .where((Object e) => e is! FushiAppleColors)
                .followedBy(<FushiAppleColors>[apple]),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (isEinkTheme(context)) {
      return Material(
        key: surfaceKey,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shadowColor: scheme.shadow,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outline),
        ),
        child: child,
      );
    }
    // M3E：中性深色悬浮表面 + 面板中性主题（Theme 包在表面外，表面的
    // DefaultTextStyle / 图标色同样读白前景）。
    return Theme(
      data: videoM3ePanelTheme(Theme.of(context)),
      child: Material(
        key: surfaceKey,
        color: videoM3eFloatingColor(),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black,
        elevation: kFushiFloatingElevation,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

/// 视频浮层面板的玻璃参数：在作用域玻璃之上加厚（理由见
/// [VideoFloatingPanelSurface]）。磨砂 / 关闭档直接用作用域值（已是厚实底）。
LiquidGlassSettings videoPanelGlassSettings(BuildContext context) {
  final LiquidGlassSettings base = fushiGlassSettings(context);
  if (glassMaterialOf(context) != FushiGlassMaterial.liquid) return base;
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return base.copyWith(
    glassColor: dark
        ? const Color(0xFF262626).withValues(alpha: 0.84)
        : Colors.white.withValues(alpha: 0.74),
    blur: 16,
    thickness: dark ? 25 : 18,
  );
}

/// 玻璃面板内的 Apple 色板：分组卡底（secondaryGroupedBackground）换成半透明
/// 系统灰，其余照旧。降低透明度时面板是实色 #1C1C1E / #F9F9F9，卡片随之用
/// 实色的上一级（#2C2C2E / 白）。
FushiAppleColors videoPanelAppleColors(BuildContext context) {
  final FushiAppleColors a = appleColorsOf(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
  final Color card = solid
      ? (dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF))
      : (dark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.72));
  return FushiAppleColors(
    accent: a.accent,
    onAccent: a.onAccent,
    groupedBackground: a.groupedBackground,
    secondaryGroupedBackground: card,
    tertiaryGroupedBackground: a.tertiaryGroupedBackground,
    label: a.label,
    secondaryLabel: a.secondaryLabel,
    tertiaryLabel: a.tertiaryLabel,
    separator: a.separator,
    opaqueSeparator: a.opaqueSeparator,
    fill: a.fill,
    secondaryFill: a.secondaryFill,
    tertiaryFill: a.tertiaryFill,
    destructive: a.destructive,
    success: a.success,
    warning: a.warning,
  );
}

/// 浮层面板的标题：Apple = 17 / 15 号 semibold（iOS sheet 导航标题 / macOS
/// 检查器标题），MD3 = titleLarge 加粗（M3E 侧边面板标题，强调层级）。
///
/// 读的是 [context] 的主题——M3E 面板内容在 [VideoFloatingPanelSurface] 的中性
/// 主题里，所以调用点要用表面**内部**的 context（否则浅色主题下标题是黑字）。
TextStyle? videoPanelTitleStyle(BuildContext context) {
  if (isGlassDesign(context)) {
    return TextStyle(
      fontSize: fushiAppleCompact(context) ? 15 : 17,
      fontWeight: FontWeight.w600,
      height: 1.25,
      color: appleColorsOf(context).label,
    );
  }
  return Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      );
}

/// 底部半透明**抽屉**：与 [VideoTranslucentSidePanel] 同一套配色/圆角/焦点纪律，只是
/// 贴底而不是贴边——视频全幅可见、继续播放，字幕在真实位置实时预览（字幕调整专用，
/// 2026-08 字幕工作台 PR-C）。
///
/// 两个交互：头部拖拽条上下拖改高度（[minHeightFraction]..[maxHeightFraction]）、
/// 「收起」把抽屉缩成只剩头部一条。关闭走页面层的点外 barrier（BUG-254：浮层一律
/// 不渲染 X）。高度是本 widget 的瞬时状态，不持久化——每次打开回到 [initialHeightFraction]。
class VideoTranslucentBottomDrawer extends StatefulWidget {
  const VideoTranslucentBottomDrawer({
    required this.title,
    required this.child,
    this.initialHeightFraction = 0.42,
    this.minHeightFraction = 0.2,
    this.maxHeightFraction = 0.9,
    this.maxWidth = 1100,
    super.key,
  });

  final String title;
  final Widget child;

  /// 打开时的高度（占屏高比例）。
  final double initialHeightFraction;
  final double minHeightFraction;
  final double maxHeightFraction;

  /// 桌面大窗口下的宽度上限（抽屉居中）；窄窗吃满宽度减边距。
  final double maxWidth;

  @override
  State<VideoTranslucentBottomDrawer> createState() =>
      _VideoTranslucentBottomDrawerState();
}

class _VideoTranslucentBottomDrawerState
    extends State<VideoTranslucentBottomDrawer> {
  late double _fraction = widget.initialHeightFraction;
  bool _collapsed = false;

  void _onDrag(DragUpdateDetails details, double screenHeight) {
    if (screenHeight <= 0) return;
    setState(() {
      _collapsed = false;
      _fraction = (_fraction - details.delta.dy / screenHeight)
          .clamp(widget.minHeightFraction, widget.maxHeightFraction)
          .toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    const double margin = 10.0;
    final double width = (screen.width - margin * 2)
        .clamp(0.0, widget.maxWidth)
        .toDouble();
    final double height = (screen.height * _fraction)
        .clamp(0.0, screen.height - margin * 2)
        .toDouble();
    const BorderRadius borderRadius = BorderRadius.all(Radius.circular(12));
    final bool glass = isGlassDesign(context);

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
          child: SizedBox(
            width: width,
            height: _collapsed ? null : height,
            child: VideoFloatingPanelSurface(
              surfaceKey: const ValueKey<String>('video-subtitle-drawer'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  GestureDetector(
                    key: const ValueKey<String>('video-subtitle-drawer-handle'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (DragUpdateDetails d) =>
                        _onDrag(d, screen.height),
                    onTap: () => setState(() => _collapsed = !_collapsed),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                // 拖拽条 / 标题读表面内部的主题（M3E 中性
                                // 深色面板上是白 / 半透明白，而不是 app 主题色）。
                                Builder(
                                  builder: (BuildContext inner) => Center(
                                    child: Container(
                                      width: 36,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: glass
                                            ? appleColorsOf(inner).tertiaryLabel
                                            : Theme.of(inner)
                                                .colorScheme
                                                .outline,
                                        borderRadius: borderRadius,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Builder(
                                  builder: (BuildContext inner) => Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: videoPanelTitleStyle(inner),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FushiIconButtonControl(
                            key: const ValueKey<String>(
                              'video-subtitle-drawer-collapse',
                            ),
                            tooltip: _collapsed
                                ? t.video_subtitle_adjust_expand
                                : t.video_subtitle_adjust_collapse,
                            onPressed: () =>
                                setState(() => _collapsed = !_collapsed),
                            icon: FushiIcon(
                              _collapsed
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                            ),
                          ),
                          // BUG-254：浮层不渲染 X，点抽屉外任意位置关闭（页面层 barrier）。
                        ],
                      ),
                    ),
                  ),
                  if (!_collapsed) ...<Widget>[
                    // 头部与内容之间不压分隔线：Apple（iOS 26 sheet）与 M3E
                    // （侧边面板标题直接坐在表面上）都靠留白分区；只有墨水屏
                    // （表面层次塌成同色）保留一条细线。
                    if (!glass && isEinkTheme(context))
                      const FushiDividerControl(height: 1),
                    Expanded(child: widget.child),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VideoTranslucentSidePanel extends StatelessWidget {
  const VideoTranslucentSidePanel({
    required this.title,
    required this.child,
    this.onClose,
    this.alignment = Alignment.centerRight,
    this.width = 400,
    this.icon,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final Alignment alignment;
  final double width;

  /// 页头图标：M3E 下画成标题前的饼干形徽标（primaryContainer 底）；Apple /
  /// 墨水屏不画（保持原来的纯标题页头）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final Size screen = MediaQuery.sizeOf(context);
    const double horizontalMargin = 10.0;
    final double availableWidth =
        (screen.width - horizontalMargin * 2).clamp(0.0, double.infinity);
    final double maxPanelWidth = availableWidth * 0.94;
    final double minPanelWidth = maxPanelWidth < 280.0 ? maxPanelWidth : 280.0;
    final double panelWidth =
        width.clamp(minPanelWidth, maxPanelWidth).toDouble();
    // 面板四边都离窗口留安全间距、四角全圆（浮动面板，不是贴边抽屉）；表面与
    // 圆角按设计系统见 [VideoFloatingPanelSurface]。
    final EdgeInsets headerPadding = glass
        ? (fushiAppleCompact(context)
              ? const EdgeInsets.fromLTRB(18, 14, 18, 4)
              : const EdgeInsets.fromLTRB(20, 18, 20, 6))
        // MD3：左右 28 = 面板内容的 page + gap 水平缩进（设置面板分类栏 /
        // 详情都按它排），标题与下方内容同一左缘。
        : const EdgeInsets.fromLTRB(28, 20, 28, 8);

    return Align(
      alignment: alignment,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalMargin,
            vertical: 10,
          ),
          child: SizedBox(
            width: panelWidth,
            child: VideoFloatingPanelSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // BUG-254：去掉右上角 X 关闭按钮，改为点击面板外的空白区域关闭
                  // （由页面层的全屏透明 barrier 承载，见 video_fushi_page 的
                  // [_buildVideoSidePanelOverlay]）。[onClose] 仍保留供 barrier / 其他
                  // 调用方复用，header 不再渲染关闭按钮。
                  Padding(
                    padding: headerPadding,
                    // 页头读表面内部的主题（M3E 中性深色面板上是白字）。
                    child: Builder(
                      builder: (BuildContext inner) {
                        final Widget text = Text(
                          title,
                          maxLines: 2,
                          softWrap: true,
                          style: videoPanelTitleStyle(inner),
                        );
                        final IconData? headerIcon = icon;
                        if (headerIcon == null ||
                            !videoM3ePanelNeutral(inner)) {
                          return text;
                        }
                        final ColorScheme cs = Theme.of(inner).colorScheme;
                        return Row(
                          children: <Widget>[
                            ReaderShapeBadge(
                              icon: headerIcon,
                              size: 40,
                              shape: ReaderBadgeShape.cookie9,
                              color: cs.primaryContainer,
                              iconColor: cs.onPrimaryContainer,
                              iconSize: 22,
                            ),
                            const SizedBox(width: 14),
                            Expanded(child: text),
                          ],
                        );
                      },
                    ),
                  ),
                  // 标题与内容之间：Apple 不压线（留白分区），MD3 也不压
                  // （Expressive 侧边面板标题直接坐在面板上）；墨水屏保留细线。
                  if (isEinkTheme(context)) const FushiDividerControl(height: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
