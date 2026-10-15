import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show VelocityTracker;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_m3e_panel_theme.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show
        kReaderPanelBottomSheetMaxWidth,
        kReaderPanelCompactWidth,
        ReaderPanelSwitcher,
        ReaderPanelSwitcherRail;
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

// 面板内容（视频页各 part 的字幕轨 / 音轨 / 画质 / 章节）经本文件拿到面板中性
// 主题的判据与配色 helper。
export 'package:fushi/src/media/video/video_m3e_panel_theme.dart';

/// 视频页浮层面板（设置 / 倍速 / 章节 / 画质 / 字幕抽屉）的统一表面。
///
/// - Apple：与播放器其它悬浮胶囊 / 迷你条 / 圆钮同一块原生 Cupertino 实色
///   悬浮面（[fushiAppleSolidFloatingDecoration]：系统材质实色 + 发丝描边 +
///   柔和投影），不开玻璃、不逐块 `useOwnLayer` 实时模糊（用户 2026-10-12
///   实测掉帧、白边）。圆角桌面 18、触屏 28（超椭圆）；[glassRadius] 给定时
///   （小药丸取半高）用普通圆角矩形，保证矮表面仍是胶囊。面板里的分组卡用
///   [videoPanelAppleColors] 的上一级实色，在实色面上浮起。
/// - MD3（M3 Expressive）：以 app 主色为种子、与 app 同亮度的着色方案
///   surfaceContainerLow（[videoM3ePanelSurfaceColor]，半透明档与播放器悬浮
///   胶囊同一不透明度），圆角 28、轻阴影；面板内部读面板主题
///   （[videoM3ePanelTheme]）。日间模式浅色、深色模式深色，旁边的面板切换竖条
///   套同一份主题，二者恒同色。墨水屏仍是实色 surfaceContainerLow + 一圈
///   outline 描边（不半透明、不换配色）。
class VideoFloatingPanelSurface extends StatelessWidget {
  const VideoFloatingPanelSurface({
    required this.child,
    this.surfaceKey,
    this.borderRadius,
    this.opaque = false,
    this.glassRadius,
    super.key,
  });

  /// Apple 实色悬浮面的圆角；null = [radiusOf]（超椭圆）。小尺寸浮层（如胶囊
  /// 药丸）用它取半高，否则 18 / 28 的面板圆角在矮表面上不成胶囊。
  final double? glassRadius;

  /// MD3：true 时表面用不透明底色（不透出下面的画面 / 字幕）。设置面板与调轴浮条
  /// 用它——面板里是成片的文字与控件，背后透出字幕会和面板文字叠在一起难读。
  /// Apple 不受影响（实色悬浮面本就不透明）。
  final bool opaque;

  final Widget child;

  /// MD3 / 墨水屏表面的圆角；null = 四角 [radiusOf]。贴底面板只圆上两角。
  /// Apple 恒为四角（[glassRadius] / [radiusOf]），与其它 Apple 悬浮面一致。
  final BorderRadius? borderRadius;

  /// 挂在表面本体上的 key（测试 / 几何断言按它取面板矩形）。
  final Key? surfaceKey;

  /// 当前设计系统下的面板圆角。
  static double radiusOf(BuildContext context) {
    if (isGlassDesign(context)) return fushiAppleCompact(context) ? 18 : 28;
    return 28;
  }

  /// Apple 实色悬浮面的形状：[glassRadius] 给定时是普通圆角矩形（取半高即
  /// 精确胶囊），否则是 [radiusOf] 的超椭圆。
  static OutlinedBorder appleShapeOf(
    BuildContext context, {
    double? glassRadius,
  }) {
    final double? pill = glassRadius;
    if (pill != null) {
      return RoundedRectangleBorder(borderRadius: BorderRadius.circular(pill));
    }
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radiusOf(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double radius = radiusOf(context);
    if (isGlassDesign(context)) {
      final ThemeData theme = Theme.of(context);
      final FushiAppleColors apple = videoPanelAppleColors(context);
      final OutlinedBorder shape = appleShapeOf(
        context,
        glassRadius: glassRadius,
      );
      return DecoratedBox(
        key: surfaceKey,
        decoration: fushiAppleSolidFloatingDecoration(context, shape: shape),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: Theme(
            data: theme.copyWith(
              // 只换掉 Apple 色板这一项，其余主题扩展原样保留。不写元素类型
              // 注解：前端编译器把 `ThemeExtension<dynamic>` 按上界展开，与
              // analyzer 的推断不一致，显式注解会在热重载时报类型不符。
              extensions: theme.extensions.values
                  .where((Object e) => e is! FushiAppleColors)
                  .followedBy(<FushiAppleColors>[apple]),
            ),
            child: child,
          ),
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
          borderRadius: borderRadius ?? BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outline),
        ),
        child: child,
      );
    }
    // M3E：与 app 同亮度的着色悬浮表面 + 面板主题（Theme 包在表面外，表面的
    // DefaultTextStyle / 图标色同样读面板前景）。
    return Theme(
      data: videoM3ePanelTheme(Theme.of(context)),
      child: Material(
        key: surfaceKey,
        color: videoM3ePanelSurfaceColor(
          Theme.of(context).colorScheme,
          opaque: opaque,
        ),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black,
        elevation: kFushiFloatingElevation,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius ?? BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

/// 浮层面板内的 Apple 色板：分组卡底（secondaryGroupedBackground）换成半透明
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
  return Theme.of(
    context,
  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700);
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
                                            : Theme.of(
                                                inner,
                                              ).colorScheme.outline,
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

/// 视频页浮层面板（设置 / 倍速 / 章节 / 画质 / 弹幕匹配）的外壳。
///
/// 两种形态（2026-10 视频设置面板重设计，与阅读器设置面板同一判据
/// [kReaderPanelCompactWidth]）：
/// - **侧板**：浮在画面一侧、四边留安全间距、四角全圆；
/// - **贴底面板**（[bottomSheetWhenCompact] 且窗口窄于 600，即手机竖屏）：从底部
///   升起、只圆上两角、顶端一条拖动把手（向下甩 / 点按关闭），高度半屏——竖屏
///   画面在屏幕中部，面板不再从上到下整列盖住它。
///
/// 进场：侧板从所在一侧滑入 + 淡入，贴底面板从底部升起（[FushiMotion.long] +
/// [FushiMotion.enter]；墨水屏 / 系统「减弱动态效果」下瞬时出现）。
class VideoTranslucentSidePanel extends StatelessWidget {
  const VideoTranslucentSidePanel({
    required this.child,
    this.title,
    this.onClose,
    this.alignment = Alignment.centerRight,
    this.width = 400,
    this.icon,
    this.bottomSheetWhenCompact = false,
    this.opaque = false,
    this.switcher,
    super.key,
  });

  /// 面板切换条（字幕 / 音频 / 章节 / 画质 / 设置原地互换，与阅读器侧板同一个
  /// 组件）：侧板时纵向挂在朝画面的一侧，贴底面板时横向一排放在把手下面。
  /// null 或只有一项时不画。
  final ReaderPanelSwitcher? switcher;

  /// 表面不透明（见 [VideoFloatingPanelSurface.opaque]）。
  final bool opaque;

  /// 页头标题；null = 不画页头（内容自带顶行，如视频设置面板的分类页签——反馈
  /// nGxUGtYot9：一打开最上面一整行「视频设置」大标题没用、占空间）。
  final String? title;
  final Widget child;
  final VoidCallback? onClose;
  final Alignment alignment;
  final double width;

  /// 页头图标：M3E 下画成标题前的饼干形徽标（primaryContainer 底）；Apple /
  /// 墨水屏不画（保持原来的纯标题页头）。
  final IconData? icon;

  /// 窄窗（手机竖屏）时改为贴底面板，见类注释。
  final bool bottomSheetWhenCompact;

  /// 贴底面板占屏高的比例：半屏。竖屏画面居中，面板只压到画面下半截，上半截
  /// 照常可见（要看字幕实时效果的调轴走浮条，见 `VideoSubtitleSyncRow.floatBar`）。
  static const double bottomSheetHeightFraction = 0.5;

  /// 贴底面板上拉后的展开档（与阅读器底部 sheet 的满高档同为 86%）。
  static const double bottomSheetExpandedFraction = 0.86;

  /// 本次是否以贴底面板呈现（页面与测试共用的判据）。
  static bool presentsAsBottomSheet(
    Size screen, {
    required bool bottomSheetWhenCompact,
  }) => bottomSheetWhenCompact && screen.width < kReaderPanelCompactWidth;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    if (presentsAsBottomSheet(
      screen,
      bottomSheetWhenCompact: bottomSheetWhenCompact,
    )) {
      return _buildBottomSheet(context, screen);
    }
    return _buildSidePanel(context, screen);
  }

  /// 页头（标题 + 可选饼干徽标）；[title] 为 null 时不画。
  Widget? _buildHeader(BuildContext context, {required bool compact}) {
    final String? text = title;
    if (text == null) return null;
    final bool glass = isGlassDesign(context);
    final EdgeInsets headerPadding = glass
        ? (fushiAppleCompact(context) || compact
              ? const EdgeInsets.fromLTRB(18, 14, 18, 4)
              : const EdgeInsets.fromLTRB(20, 18, 20, 6))
        // MD3：左右 28 = 面板内容的 page + gap 水平缩进，标题与下方内容同一左缘；
        // 贴底面板顶上已有把手，页头收紧。
        : (compact
              ? const EdgeInsets.fromLTRB(20, 4, 20, 4)
              : const EdgeInsets.fromLTRB(28, 20, 28, 8));
    return Padding(
      padding: headerPadding,
      // 页头读表面内部的主题（M3E 中性深色面板上是白字）。
      child: Builder(
        builder: (BuildContext inner) {
          final Widget label = Text(
            text,
            maxLines: 2,
            softWrap: true,
            style: videoPanelTitleStyle(inner),
          );
          final IconData? headerIcon = icon;
          if (headerIcon == null || !videoM3ePanelNeutral(inner)) {
            return label;
          }
          final ColorScheme cs = Theme.of(inner).colorScheme;
          return Row(
            children: <Widget>[
              ReaderShapeBadge(
                icon: headerIcon,
                size: compact ? 32 : 40,
                shape: ReaderBadgeShape.cookie9,
                color: cs.primaryContainer,
                iconColor: cs.onPrimaryContainer,
                iconSize: compact ? 18 : 22,
              ),
              const SizedBox(width: 14),
              Expanded(child: label),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSidePanel(BuildContext context, Size screen) {
    const double horizontalMargin = 10.0;
    final double availableWidth = (screen.width - horizontalMargin * 2).clamp(
      0.0,
      double.infinity,
    );
    final double maxPanelWidth = availableWidth * 0.94;
    final double minPanelWidth = maxPanelWidth < 280.0 ? maxPanelWidth : 280.0;
    final double panelWidth = width
        .clamp(minPanelWidth, maxPanelWidth)
        .toDouble();
    final Widget? header = _buildHeader(context, compact: false);
    // 面板四边都离窗口留安全间距、四角全圆（浮动面板，不是贴边抽屉）；表面与
    // 圆角按设计系统见 [VideoFloatingPanelSurface]。
    // BUG-254：不渲染 X 关闭按钮，点面板外的空白区域关闭（页面层的全屏透明
    // barrier，见 video_fushi_page 的 [_buildVideoSidePanelOverlay]）。
    final bool fromLeft = alignment.x < 0;
    final ReaderPanelSwitcher? sw = switcher;
    final bool withRail = sw != null && sw.items.length > 1;
    Widget framed(Widget panel) {
      if (!withRail) return panel;
      // 切换条挂在面板朝画面的一侧、与面板顶对齐（同阅读器侧板）。M3E 下套面板
      // 主题（[VideoM3ePanelTheme]）：竖条与面板读同一份与 app 同亮度的着色方案，
      // 不会出现「面板一种颜色、竖条另一种颜色」（2026-10-14 用户：日间模式下面板
      // 深、竖条浅）。Apple / 墨水屏原样。
      final Widget rail = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.topCenter,
          child: VideoM3ePanelTheme(
            child: ReaderPanelSwitcherRail(
              switcher: sw,
              keyPrefix: 'video_panel',
            ),
          ),
        ),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: fromLeft ? <Widget>[panel, rail] : <Widget>[rail, panel],
      );
    }

    return Align(
      alignment: alignment,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalMargin,
            vertical: 10,
          ),
          child: _VideoPanelEntrance(
            from: Offset(fromLeft ? -0.12 : 0.12, 0),
            child: framed(
              SizedBox(
                width: panelWidth,
                child: VideoFloatingPanelSurface(
                  opaque: opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (header != null) header,
                      // 标题与内容之间：Apple / MD3 都不压线（留白分区）；墨水屏
                      // 保留细线。
                      if (header != null && isEinkTheme(context))
                        const FushiDividerControl(height: 1),
                      Expanded(
                        child: VideoPanelSwipeSwitch(
                          switcher: switcher,
                          child: child,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomSheet(BuildContext context, Size screen) {
    return _VideoBottomSheetFrame(
      opaque: opaque,
      onClose: onClose,
      header: _buildHeader(context, compact: true),
      switcher: switcher,
      child: child,
    );
  }
}

/// 贴底面板（手机竖屏）：两档停靠高度——半屏（画面上半截照常可见，边调边看）
/// 与 [VideoTranslucentSidePanel.bottomSheetExpandedFraction]（长时间改设置）。
/// 拖把手在两档间切换，向下甩 / 拖到很低关闭；点把手关闭。切换条在把手下面
/// 横向一排（纯图标，文案进 tooltip 与语义），代替页头标题。
class _VideoBottomSheetFrame extends StatefulWidget {
  const _VideoBottomSheetFrame({
    required this.opaque,
    required this.onClose,
    required this.header,
    required this.switcher,
    required this.child,
  });

  final bool opaque;
  final VoidCallback? onClose;
  final Widget? header;
  final ReaderPanelSwitcher? switcher;
  final Widget child;

  @override
  State<_VideoBottomSheetFrame> createState() => _VideoBottomSheetFrameState();
}

class _VideoBottomSheetFrameState extends State<_VideoBottomSheetFrame> {
  double _fraction = VideoTranslucentSidePanel.bottomSheetHeightFraction;

  /// 拖动中的实时高度比例（null = 停在某一档，变化走动画）。
  double? _dragFraction;

  void _onDragUpdate(DragUpdateDetails details, double screenHeight) {
    if (screenHeight <= 0) return;
    final double base = _dragFraction ?? _fraction;
    setState(() {
      _dragFraction = (base - details.delta.dy / screenHeight).clamp(
        0.15,
        VideoTranslucentSidePanel.bottomSheetExpandedFraction,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    final double current = _dragFraction ?? _fraction;
    const double half = VideoTranslucentSidePanel.bottomSheetHeightFraction;
    const double full = VideoTranslucentSidePanel.bottomSheetExpandedFraction;
    // 半屏档向下甩、或拖到半屏以下一大截：关闭。
    if ((velocity > 700 && current <= half) || current < half * 0.6) {
      widget.onClose?.call();
      return;
    }
    final double next;
    if (velocity < -300) {
      next = full;
    } else if (velocity > 300) {
      next = half;
    } else {
      next = (current - half).abs() < (current - full).abs() ? half : full;
    }
    setState(() {
      _fraction = next;
      _dragFraction = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final double maxHeight = (screen.height - padding.top - 24).clamp(
      0.0,
      double.infinity,
    );
    final double height = (screen.height * (_dragFraction ?? _fraction))
        .clamp(0.0, maxHeight)
        .toDouble();
    final double sheetWidth = screen.width < kReaderPanelBottomSheetMaxWidth
        ? screen.width
        : kReaderPanelBottomSheetMaxWidth;
    final double radius = VideoFloatingPanelSurface.radiusOf(context);
    final ReaderPanelSwitcher? sw = widget.switcher;
    final bool withSwitcher = sw != null && sw.items.length > 1;
    final Widget? header = widget.header;
    return Align(
      alignment: Alignment.bottomCenter,
      child: _VideoPanelEntrance(
        from: const Offset(0, 1),
        child: AnimatedContainer(
          key: const ValueKey<String>('video-side-panel-bottom-sheet'),
          duration: _dragFraction != null
              ? Duration.zero
              : fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          width: sheetWidth,
          height: height,
          child: VideoFloatingPanelSurface(
            opaque: widget.opaque,
            borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _VideoPanelDragHandle(
                    onClose: widget.onClose,
                    onDragUpdate: (DragUpdateDetails d) =>
                        _onDragUpdate(d, screen.height),
                    onDragEnd: _onDragEnd,
                  ),
                  if (withSwitcher)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Center(
                        child: ReaderPanelSwitcherRail(
                          switcher: sw,
                          axis: Axis.horizontal,
                          keyPrefix: 'video_panel',
                        ),
                      ),
                    )
                  else if (header != null)
                    header,
                  if (!withSwitcher && header != null && isEinkTheme(context))
                    const FushiDividerControl(height: 1),
                  Expanded(
                    child: VideoPanelSwipeSwitch(
                      switcher: widget.switcher,
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 触屏左右滑动切换面板（切换条的手势版）：左滑到切换条上的下一个面板、右滑到
/// 上一个，到头不循环。只认触摸 / 触控笔——桌面鼠标拖动不误切。
///
/// 滑条、横向滚动的页签等子控件自己也认横向拖动，手势竞技场里它们在命中链更深处、
/// 先过触发阈值，按在它们上面横拖仍是调值 / 滚动；只有在空白处与普通行上横滑才
/// 切面板。判据按松手速度（甩动），慢慢拖不切，避免读文字时手指微移误触。
///
/// 面板内容自带左右分页（设置面板的分类 [TabBarView]）时，分页在竞技场里赢下横拖，
/// 外层手势收不到松手。分页已在首页再往右甩、已在末页再往左甩时它翻不动，这一甩
/// 交还给外层切面板（[edgeHandoffTarget]）；中间页的横甩仍只翻分页。
class VideoPanelSwipeSwitch extends StatefulWidget {
  const VideoPanelSwipeSwitch({
    required this.switcher,
    required this.child,
    super.key,
  });

  /// 松手横向速度超过它（逻辑像素 / 秒）才算一次切换甩动。
  static const double flingVelocity = 400;

  final ReaderPanelSwitcher? switcher;
  final Widget child;

  /// 甩动后应切到的面板 id；null = 不切（到头 / 速度不够 / 找不到当前项）。
  static String? targetFor(ReaderPanelSwitcher switcher, double velocity) {
    if (velocity.abs() < flingVelocity) return null;
    final List<String> ids = <String>[
      for (final ({String id, IconData icon, String label}) item
          in switcher.items)
        item.id,
    ];
    final int index = ids.indexOf(switcher.current.value);
    if (index < 0) return null;
    final int next = velocity < 0 ? index + 1 : index - 1;
    if (next < 0 || next >= ids.length) return null;
    return ids[next];
  }

  /// 内层分页赢下横拖后，松手时这一甩是否越过分页边界、该交给外层切面板。
  ///
  /// [startedAtMin] / [startedAtMax]：拖动开始时分页是否已在首 / 末页；
  /// [endedAtMin] / [endedAtMax]：松手时是否仍停在该边界（中途拖回中间页再甩不算）。
  /// [axisDirection] 决定哪个手指方向是在往 min 推（RTL 下分页方向镜像）。
  static String? edgeHandoffTarget(
    ReaderPanelSwitcher switcher, {
    required bool startedAtMin,
    required bool startedAtMax,
    required bool endedAtMin,
    required bool endedAtMax,
    required AxisDirection axisDirection,
    required double velocityDx,
  }) {
    if (velocityDx == 0) return null;
    final bool pushingTowardMin = axisDirection == AxisDirection.left
        ? velocityDx < 0
        : velocityDx > 0;
    final bool pastEdge = pushingTowardMin
        ? startedAtMin && endedAtMin
        : startedAtMax && endedAtMax;
    if (!pastEdge) return null;
    return targetFor(switcher, velocityDx);
  }

  @override
  State<VideoPanelSwipeSwitch> createState() => _VideoPanelSwipeSwitchState();
}

class _VideoPanelSwipeSwitchState extends State<VideoPanelSwipeSwitch> {
  /// 边界判定的容差（逻辑像素）：弹性回弹物理下越界是负值，夹紧物理下恰为 0。
  static const double _edgeTolerance = 1;

  static const Set<PointerDeviceKind> _swipeDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
  };

  int? _pointer;
  VelocityTracker? _tracker;

  /// 本次触摸里内层分页开始拖动时的边界状态；null = 分页没被拖动（外层手势自己处理）。
  ({bool atMin, bool atMax})? _pageDragStart;
  PageMetrics? _lastPageMetrics;

  void _reset() {
    _pointer = null;
    _tracker = null;
    _pageDragStart = null;
    _lastPageMetrics = null;
  }

  static bool _atMin(ScrollMetrics m) =>
      m.pixels <= m.minScrollExtent + _edgeTolerance;

  static bool _atMax(ScrollMetrics m) =>
      m.pixels >= m.maxScrollExtent - _edgeTolerance;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null || !_swipeDevices.contains(event.kind)) return;
    _reset();
    _pointer = event.pointer;
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _tracker?.addPosition(event.timeStamp, event.position);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final ReaderPanelSwitcher? sw = widget.switcher;
    final ({bool atMin, bool atMax})? start = _pageDragStart;
    final PageMetrics? last = _lastPageMetrics;
    final VelocityTracker? tracker = _tracker;
    _reset();
    if (sw == null || start == null || last == null || tracker == null) return;
    tracker.addPosition(event.timeStamp, event.position);
    final String? target = VideoPanelSwipeSwitch.edgeHandoffTarget(
      sw,
      startedAtMin: start.atMin,
      startedAtMax: start.atMax,
      endedAtMin: _atMin(last),
      endedAtMax: _atMax(last),
      axisDirection: last.axisDirection,
      velocityDx: tracker.getVelocity().pixelsPerSecond.dx,
    );
    if (target != null) sw.onSelect(target);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _reset();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    // 只认横向分页（TabBarView / PageView）；横向滚动的页签条不是分页，不接管。
    if (_pointer == null ||
        metrics is! PageMetrics ||
        metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _pageDragStart = (atMin: _atMin(metrics), atMax: _atMax(metrics));
    }
    if (_pageDragStart != null) _lastPageMetrics = metrics;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPanelSwitcher? sw = widget.switcher;
    if (sw == null || sw.items.length < 2) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: GestureDetector(
          key: const ValueKey<String>('video-panel-swipe-switch'),
          // 只占用横向拖动；纵向滚动照常交给内容。
          behavior: HitTestBehavior.translucent,
          supportedDevices: _swipeDevices,
          onHorizontalDragEnd: (DragEndDetails details) {
            final String? target = VideoPanelSwipeSwitch.targetFor(
              sw,
              details.primaryVelocity ?? 0,
            );
            if (target != null) sw.onSelect(target);
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// 贴底面板顶端的拖动把手（MD3 drag handle 32×4）：向下甩 / 点按关闭面板（语义
/// 按钮，键盘焦点不停在这里）。
class _VideoPanelDragHandle extends StatelessWidget {
  const _VideoPanelDragHandle({
    required this.onClose,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final VoidCallback? onClose;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final Color color = isGlassDesign(context)
        ? appleColorsOf(context).tertiaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    return ExcludeFocus(
      child: Semantics(
        button: true,
        label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        onTap: onClose,
        child: GestureDetector(
          key: const ValueKey<String>('video-side-panel-drag-handle'),
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          onVerticalDragUpdate: onDragUpdate,
          onVerticalDragEnd:
              onDragEnd ??
              (DragEndDetails details) {
                if ((details.primaryVelocity ?? 0) > 300) onClose?.call();
              },
          child: SizedBox(
            height: 22,
            child: Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮层面板的进场：从 [from]（面板自身尺寸的比例偏移）滑到原位并淡入。
class _VideoPanelEntrance extends StatelessWidget {
  const _VideoPanelEntrance({required this.from, required this.child});

  final Offset from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.enter,
      child: child,
      builder: (BuildContext context, double t, Widget? child) {
        return FractionalTranslation(
          translation: from * (1 - t),
          child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
        );
      },
    );
  }
}
