import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:fushi/src/media/video/video_apple_chrome.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// 视频播放器 chrome 的 MD3 形态：Material 3 Expressive（2025-05）。
//
// 与 Apple 分支（video_apple_chrome.dart）对称：控制条的结构、焦点链路、快捷键、
// 布局编辑器全部不动，这里只提供 MD3 下的**叶子**——
//
// - [VideoM3eIconButton]：tonal / 透明两档的圆形图标钮，按下弹簧形变成圆角方形；
// - [VideoM3ePlayPauseButton]：播放键。暂停态是圆、播放态弹成圆角方形（M3E 的
//   「形状即状态」），按下再收紧一点；有实色（底栏）与半透明模糊底（画面中央 96dp）
//   两种材质；
// - [VideoM3eSeekButton]：画面中央的 ±N 秒键，按下时箭头沿跳转方向转一下；
// - [VideoM3eSeekTrack]：进度条轨道（经 fork 的 `seekBarTrackBuilder` 接进 media_kit
//   的进度条，手势仍归 fork）——播放时已播段是流动的正弦波，暂停时波浪收平成直线，
//   竖条手柄、悬停 / 拖动时加粗、拖动时手柄上方出时间气泡，可选字幕密度刻度；
// - [VideoM3eChromeSlide]：控制条显隐时顶栏上滑 / 底栏下滑 + 轻微缩放，M3E spring
//   驱动（叠在 fork 的淡入淡出上）；
// - 浮动工具栏（2026-10-05）：控制条不再是贴边的整条实体栏 + 整屏暗化，而是悬浮
//   胶囊——底栏每簇一枚胶囊（[videoM3eFloatingBarStyle] → [VideoBarClusterStyle]），
//   顶栏返回 / 标题 / 右侧按钮组各是一枚胶囊（[VideoM3eFloatingSurface]）；进度条是
//   胶囊上方一条悬浮的轨道槽（[VideoM3eSeekTrack.lane]）。控件隐藏后画面上什么都
//   不剩。2026-10-06（shishamo「悬浮色彩有点怪」）：所有胶囊统一同一枚中性深色
//   半透明表面、前景统一 onSurface（近白）；强调色只给播放键、进度已播段 / 手柄与
//   开关的「开」态——传输簇不再是饱和的 primaryContainer 色块（压在画面上突兀、
//   与画面色调冲突，且让同一层控件出现三种配色）；
// - [VideoM3eTimeText]：等宽数字时间（点按切「已播 / 剩余」）。
//
// 播放器 chrome 永远压在画面（深色）上，所以前景 / 容器色一律取**深色**方案
// （[videoM3eChromeScheme]，由 app 主色生成），不跟随 app 的浅色主题。墨水屏：
// 实色 + 描边、不模糊、不形变；系统「减弱动态效果」：不形变、不流动，状态瞬间到位。

/// MD3 设计系统下的播放器 chrome 是否生效（Apple 分支走 video_apple_chrome.dart）。
bool videoM3eChrome(BuildContext context) => !isGlassDesign(context);

final Map<int, ColorScheme> _chromeSchemeCache = <int, ColorScheme>{};

/// 播放器 chrome 的深色配色：以 app 主色为种子的深色 [ColorScheme]（缓存）。
///
/// chrome 压在画面上、底下是固定深色 scrim，浅色主题下的 tonal 容器（偏白）会把
/// 白字吞掉，所以容器色恒取深色方案；强调色与 [videoChromeAccentColor] 同一亮 tone。
ColorScheme videoM3eChromeScheme(ColorScheme cs) {
  final int key = cs.primary.toARGB32();
  return _chromeSchemeCache[key] ??= ColorScheme.fromSeed(
    seedColor: cs.primary,
    brightness: Brightness.dark,
  );
}

/// 播放器悬浮表面的固定中性色：HCT chroma 0、tone ≈ 18（#2D2D2D）。**完全不带
/// 色相**——不从 app 主色生成的深色方案取 surfaceContainerHigh（那份灰带主色色相，
/// 绿主题下胶囊发绿、和暖色画面打架）。浮在画面上的控件是一层统一的中性表面，
/// 强调色只留给播放键、进度已播段 / 手柄与开关的「开」态（M3E 视频播放器）。
const Color kVideoM3eNeutralSurface = Color(0xFF2D2D2D);

/// 悬浮表面不透明度：画面颜色能隐约透出来，白字始终压在近实色上可读。
const double kVideoM3eNeutralSurfaceAlpha = 0.86;

/// 悬浮表面上的次要文字 / 字形（白 70%）。
const Color kVideoM3eSecondaryForeground = Color(0xB3FFFFFF);

/// tonal 圆钮的容器色：中性表面上再提一档的白 12%（不带色相）。
Color videoM3eTonalContainer() => Colors.white.withValues(alpha: 0.12);

/// 播放器上所有悬浮胶囊 / 面板（顶栏返回 / 标题 / 按钮组、底部面板、音量 / 倍速
/// 浮层）共用的底色。
Color videoM3eFloatingColor() =>
    kVideoM3eNeutralSurface.withValues(alpha: kVideoM3eNeutralSurfaceAlpha);

final Map<int, ColorScheme> _neutralChromeSchemeCache = <int, ColorScheme>{};

/// 播放器悬浮浮层（音量 / 倍速 popover）用的配色：表面族全换成无色相中性灰、前景
/// 纯白 / 白 70%，强调色族（primary / primaryContainer …）仍是以 app 主色为种子的
/// 深色方案。浮层内部的滑条 / 文字按钮读这份方案，浅色主题下也不会黑压黑。
ColorScheme videoM3eNeutralChromeScheme(ColorScheme cs) {
  final int key = cs.primary.toARGB32();
  return _neutralChromeSchemeCache[key] ??= videoM3eChromeScheme(cs).copyWith(
    surface: const Color(0xFF1F1F1F),
    onSurface: Colors.white,
    onSurfaceVariant: kVideoM3eSecondaryForeground,
    surfaceDim: const Color(0xFF1A1A1A),
    surfaceBright: const Color(0xFF454545),
    surfaceContainerLowest: const Color(0xFF141414),
    surfaceContainerLow: const Color(0xFF222222),
    surfaceContainer: const Color(0xFF262626),
    surfaceContainerHigh: const Color(0xFF2A2A2A),
    surfaceContainerHighest: kVideoM3eNeutralSurface,
    surfaceTint: Colors.transparent,
    outline: const Color(0x8AFFFFFF),
    outlineVariant: const Color(0x33FFFFFF),
    shadow: Colors.black,
    inverseSurface: const Color(0xFFE6E6E6),
    onInverseSurface: const Color(0xFF1F1F1F),
  );
}

/// 底部面板圆角上限（M3E extra-large 28）。
const double kVideoM3eBottomPanelRadius = 28;

/// M3E 底部面板（桌面 / full 与 compact 档）：进度条与底栏三簇按钮收进**同一块**
/// 大圆角中性面板——上半部是进度条，下半部是三组按钮；三簇不再各自画胶囊。
///
/// 只是背景：排在 media_kit 控制条**之前**（画在进度条 / 按钮下面、画面上面），
/// [IgnorePointer]——点击穿透规则与 Apple 玻璃胶囊同口径（按钮簇自身仍是实体，见
/// [VideoBarClusterStyle]；面板留白交还画面）。显隐跟控制条同一个 notifier、同速
/// 淡入淡出。[geometry] 为 null（mini 档 / Apple）时不画。墨水屏：纯黑 + 白描边。
class VideoM3eBottomPanel extends StatelessWidget {
  const VideoM3eBottomPanel({
    super.key,
    required this.visible,
    required this.duration,
    required this.geometry,
  });

  final ValueListenable<bool> visible;
  final Duration duration;
  final VideoAppleCapsuleGeometry? geometry;

  @override
  Widget build(BuildContext context) {
    final VideoAppleCapsuleGeometry? g = geometry;
    if (g == null || g.height <= 0) return const SizedBox.shrink();
    final bool eink = isEinkTheme(context);
    final double radius = math.min(g.height / 2, kVideoM3eBottomPanelRadius);
    final RoundedRectangleBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final ShapeDecoration decoration = eink
        ? ShapeDecoration(
            color: Colors.black,
            shape: shape.copyWith(
              side: const BorderSide(color: Colors.white, width: 1.5),
            ),
          )
        : fushiFloatingPillDecoration(
            context,
            color: videoM3eFloatingColor(),
            shape: shape,
          );
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (BuildContext context, bool shown, Widget? child) {
          return AnimatedOpacity(
            opacity: shown ? 1.0 : 0.0,
            duration: einkSafeDuration(context, duration),
            curve: Curves.easeInOut,
            child: child,
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              left: g.left,
              right: g.right,
              bottom: g.bottom,
              height: g.height,
              child: DecoratedBox(decoration: decoration),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按钮簇的浮动胶囊外形（[VideoControlBar.clusterStyle]）。[scale] = 界面缩放
/// × 密度档；墨水屏：纯黑 + 白描边、无阴影。胶囊贴条高底部（[verticalAlignment]
/// 1），让出上方给进度条。
///
/// [inPanel] = 底栏三簇已收进 [VideoM3eBottomPanel]：簇的几何（内边距 / 间距 / 实体
/// 命中区）照旧，但不再各自画底色与投影——面板就是它们共同的表面。
VideoBarClusterStyle videoM3eFloatingBarStyle(
  BuildContext context, {
  required double scale,
  double verticalAlignment = 1,
  bool inPanel = false,
}) {
  if (inPanel) {
    return VideoBarClusterStyle(
      color: Colors.transparent,
      padding: 4 * scale,
      verticalPadding: 2 * scale,
      gap: 8 * scale,
      verticalAlignment: verticalAlignment,
    );
  }
  if (isEinkTheme(context)) {
    return VideoBarClusterStyle(
      color: Colors.black,
      padding: 4 * scale,
      verticalPadding: 2 * scale,
      gap: 8 * scale,
      border: const BorderSide(color: Colors.white, width: 1.5),
      verticalAlignment: verticalAlignment,
    );
  }
  final Color standard = videoM3eFloatingColor();
  return VideoBarClusterStyle(
    // 各簇同一中性表面（传输簇不再单独上 primaryContainer 色块）。
    color: standard,
    padding: 4 * scale,
    verticalPadding: 2 * scale,
    gap: 8 * scale,
    // 投影与阅读器 / 漫画的浮动工具栏同一组（共享 fushiFloatingPillDecoration）。
    shadows:
        fushiFloatingPillDecoration(context, color: standard).shadows ??
        const <BoxShadow>[],
    verticalAlignment: verticalAlignment,
  );
}

/// 顶栏的一枚浮动胶囊（返回键、标题、右侧按钮组）。
///
/// 外层结构不随 [enabled] 增删（Apple 分支 / 关闭时只是透明、零内边距），按钮组
/// 的位置 / 约束 / 焦点链路不变。胶囊是实体：点在胶囊留白上不穿透到画面
/// （deferToChild 的空 onTap 先于 media_kit 的「点画面」胜出）。
class VideoM3eFloatingSurface extends StatelessWidget {
  const VideoM3eFloatingSurface({
    super.key,
    required this.enabled,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final bool enabled;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    // 外形 / 投影与阅读器、漫画的浮动工具栏同一份（共享
    // [fushiFloatingPillDecoration]）；底色取播放器 chrome 的深色方案（胶囊恒压在
    // 画面上，不随 app 的浅色主题变白）。墨水屏：纯黑 + 白描边。
    final ShapeDecoration decoration = !enabled
        ? const ShapeDecoration(
            color: Colors.transparent,
            shape: StadiumBorder(),
          )
        : eink
        ? const ShapeDecoration(
            color: Colors.black,
            shape: StadiumBorder(
              side: BorderSide(color: Colors.white, width: 1.5),
            ),
          )
        : fushiFloatingPillDecoration(context, color: videoM3eFloatingColor());
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: enabled ? () {} : null,
      excludeFromSemantics: true,
      child: DecoratedBox(
        decoration: decoration,
        child: Padding(
          padding: enabled ? padding : EdgeInsets.zero,
          child: child,
        ),
      ),
    );
  }
}

/// 时间格式：时长不足一小时 `m:ss`，否则 `h:mm:ss`。
String videoM3eFormatTime(Duration value, {Duration? reference}) {
  final Duration v = value.isNegative ? Duration.zero : value;
  final bool hours = (reference ?? v).inHours > 0 || v.inHours > 0;
  final int h = v.inHours;
  final int m = v.inMinutes.remainder(60);
  final int s = v.inSeconds.remainder(60);
  final String ss = s.toString().padLeft(2, '0');
  if (hours) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '${v.inMinutes}:$ss';
}

// ---------------------------------------------------------------------------
// 按钮
// ---------------------------------------------------------------------------

/// MD3 Expressive 的播放器图标钮。
///
/// [tonal] = 常驻 tonal 圆底（顶栏右侧按钮组）；false = 透明底，悬停 / 聚焦才出
/// 状态层（底栏）。按下弹簧形变到圆角方形（[FushiPressMorph]）。本体仍是 Material
/// [IconButton]：Tab 聚焦、Enter / 手柄 A 触发、语义、tooltip 链路与 media_kit 的
/// 按钮完全相同，只换外观。
class VideoM3eIconButton extends StatelessWidget {
  const VideoM3eIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.extent,
    this.iconSize,
    this.tonal = false,
    this.selected = false,
    this.foreground,
  });

  final Widget icon;
  final VoidCallback? onPressed;

  /// 圆钮直径（命中区）。
  final double extent;

  /// 字形尺寸；null = 直径的 0.5。
  final double? iconSize;

  final bool tonal;

  /// 开关类按钮的「开」态：常驻主色容器 + 方圆角（M3E toggle）。
  final bool selected;

  /// 字形颜色；null = 深色方案 onSurface（近白）。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final ColorScheme chrome = videoM3eChromeScheme(
      Theme.of(context).colorScheme,
    );
    final bool eink = isEinkTheme(context);
    final Color fg = selected
        ? chrome.onPrimaryContainer
        : foreground ?? Colors.white;
    final Color bg = selected
        ? chrome.primaryContainer
        : tonal
        ? (eink ? Colors.black : videoM3eTonalContainer())
        : Colors.transparent;
    final ButtonStyle style = IconButton.styleFrom(
      foregroundColor: fg,
      backgroundColor: bg,
      disabledForegroundColor: fg.withValues(alpha: 0.38),
      hoverColor: fg.withValues(alpha: 0.08),
      focusColor: fg.withValues(alpha: 0.12),
      highlightColor: fg.withValues(alpha: 0.12),
      fixedSize: Size.square(extent),
      minimumSize: Size.square(extent),
      maximumSize: Size.square(extent),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: eink && (tonal || selected)
          ? const BorderSide(color: Colors.white, width: 1.5)
          : null,
    );
    return FushiPressMorph(
      enabled: onPressed != null,
      style: eink
          ? style.copyWith(
              shape: const WidgetStatePropertyAll<OutlinedBorder>(
                CircleBorder(),
              ),
            )
          : style,
      trackPointer: true,
      pressedRadius: extent * 0.24,
      selected: selected,
      selectedRadius: extent * 0.3,
      builder: (BuildContext context, ButtonStyle? s, _) => IconButton(
        onPressed: onPressed,
        style: s,
        iconSize: iconSize ?? extent * 0.5,
        icon: icon,
      ),
    );
  }
}

/// 播放键的材质。
enum VideoM3ePlayButtonStyle {
  /// 实色主色容器（底栏）。
  filled,

  /// 半透明深色容器 + 背景模糊（画面中央大播放键）。
  translucent,
}

/// MD3 Expressive 播放 / 暂停键：暂停态圆形、播放态弹成圆角方形，按下再收紧；
/// 字形是 Material 的 play↔pause 形变图标，与外形同一根弹簧。
class VideoM3ePlayPauseButton extends StatefulWidget {
  const VideoM3ePlayPauseButton({
    super.key,
    required this.playing,
    required this.onPressed,
    required this.extent,
    this.style = VideoM3ePlayButtonStyle.filled,
    this.width,
    this.semanticLabel,
  });

  final bool playing;
  final VoidCallback onPressed;

  /// 高度（= 圆形时的直径）。
  final double extent;

  /// 宽度；null = [extent]（正圆）。底栏用略宽的胶囊（M3E「宽」按钮）。
  final double? width;

  final VideoM3ePlayButtonStyle style;
  final String? semanticLabel;

  @override
  State<VideoM3ePlayPauseButton> createState() =>
      _VideoM3ePlayPauseButtonState();
}

class _VideoM3ePlayPauseButtonState extends State<VideoM3ePlayPauseButton>
    with TickerProviderStateMixin {
  late final FushiSpring _shape = FushiSpring(
    vsync: this,
    initial: widget.playing ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );
  late final FushiSpring _press = FushiSpring(vsync: this);

  @override
  void initState() {
    super.initState();
    _shape;
    _press;
  }

  @override
  void didUpdateWidget(VideoM3ePlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      _shape.animateTo(
        widget.playing ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _shape.dispose();
    _press.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    _press.animateTo(
      value ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme chrome = videoM3eChromeScheme(
      Theme.of(context).colorScheme,
    );
    final bool eink = isEinkTheme(context);
    final bool translucent =
        widget.style == VideoM3ePlayButtonStyle.translucent;
    final Color bg = eink
        ? Colors.black
        : translucent
        ? kVideoM3eNeutralSurface.withValues(alpha: 0.5)
        : chrome.primary;
    final Color fg = eink
        ? Colors.white
        : translucent
        ? Colors.white
        : chrome.onPrimary;
    final double h = widget.extent;
    final double w = widget.width ?? h;
    final Widget body = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _shape.animation,
        _press.animation,
      ]),
      builder: (BuildContext context, Widget? _) {
        final double s = _shape.value;
        final double p = _press.value.clamp(0.0, 1.0);
        // 圆（短边一半）→ 播放态圆角 0.3h → 按下再收到 0.22h。
        final double half = math.min(w, h) / 2;
        final double radius = ui
            .lerpDouble(
              ui.lerpDouble(half, h * 0.3, s.clamp(0.0, 1.2))!,
              h * 0.22,
              p,
            )!
            .clamp(4.0, half);
        final double scale = 1 - 0.04 * p;
        final BorderRadius br = BorderRadius.circular(radius);
        Widget surface = DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: br,
            border: eink ? Border.all(color: Colors.white, width: 2) : null,
          ),
          child: Center(
            child: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _shape.animation.drive(
                Animatable<double>.fromCallback(
                  (double v) => v.clamp(0.0, 1.0),
                ),
              ),
              size: h * (translucent ? 0.46 : 0.5),
              color: fg,
            ),
          ),
        );
        if (translucent && !eink) {
          surface = ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: surface,
            ),
          );
        }
        return Transform.scale(scale: scale, child: surface);
      },
    );
    return SizedBox(
      width: w,
      height: h,
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: Semantics(
          button: true,
          label: widget.semanticLabel,
          child: _M3eInk(
            onPressed: widget.onPressed,
            radius: h * 0.3,
            color: fg,
            child: body,
          ),
        ),
      ),
    );
  }
}

/// 可聚焦、Enter 触发的透明命中层（自绘外形的按钮用，状态层跟随外形近似圆角）。
class _M3eInk extends StatelessWidget {
  const _M3eInk({
    required this.onPressed,
    required this.radius,
    required this.color,
    required this.child,
  });

  final VoidCallback? onPressed;
  final double radius;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(radius),
        hoverColor: color.withValues(alpha: 0.08),
        focusColor: color.withValues(alpha: 0.16),
        highlightColor: color.withValues(alpha: 0.10),
        splashColor: color.withValues(alpha: 0.12),
        child: child,
      ),
    );
  }
}

/// 触屏暂停时画面中央的最小续播提示：无底板、低不透明度的小号播放图标（只靠一圈
/// 柔和阴影在亮画面上可辨），点它续播。刻意不做大圆块——中央控件以不遮挡画面为
/// 原则，暂停 / 快退快进的主力入口是双击与底栏。
class VideoCenterPausedHint extends StatelessWidget {
  const VideoCenterPausedHint({
    super.key,
    required this.extent,
    required this.onPressed,
    this.semanticLabel,
  });

  /// 图标边长（逻辑像素）；命中区按 [extent] 外扩到不小于 48dp。
  final double extent;
  final VoidCallback onPressed;
  final String? semanticLabel;

  /// 图标不透明度：够看清「已暂停」，又不和画面抢眼。
  static const double opacity = 0.72;

  @override
  Widget build(BuildContext context) {
    final double hit = math.max(48, extent);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: hit,
          child: Center(
            child: Icon(
              Icons.play_arrow_rounded,
              size: extent,
              color: Colors.white.withValues(alpha: opacity),
              shadows: const <Shadow>[
                Shadow(color: Color(0x66000000), blurRadius: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 画面中央的 ±N 秒键：圆形半透明底，弧形箭头 + 秒数；按下时箭头沿跳转方向
/// 转 40°（弹簧回位），手感上「拧」了一下。
class VideoM3eSeekButton extends StatefulWidget {
  const VideoM3eSeekButton({
    super.key,
    required this.forward,
    required this.seconds,
    required this.onPressed,
    required this.extent,
    this.semanticLabel,
  });

  final bool forward;
  final int seconds;
  final VoidCallback onPressed;
  final double extent;
  final String? semanticLabel;

  @override
  State<VideoM3eSeekButton> createState() => _VideoM3eSeekButtonState();
}

class _VideoM3eSeekButtonState extends State<VideoM3eSeekButton>
    with SingleTickerProviderStateMixin {
  late final FushiSpring _turn = FushiSpring(
    vsync: this,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void initState() {
    super.initState();
    _turn;
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  void _onPressed() {
    final bool motion = fushiExpressiveMotionEnabled(context);
    if (motion) {
      // 先拧到 1 再弹回 0：两段弹簧，回位那段带着上一段的速度。
      _turn.animateTo(1, animate: true);
      Future<void>.delayed(FushiMotion.short, () {
        if (mounted) _turn.animateTo(0, animate: true);
      });
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final double e = widget.extent;
    const Color fg = Colors.white;
    final double dir = widget.forward ? 1 : -1;
    return SizedBox.square(
      dimension: e,
      child: Semantics(
        button: true,
        label: widget.semanticLabel,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: eink
                ? Colors.black
                : kVideoM3eNeutralSurface.withValues(alpha: 0.38),
            border: eink ? Border.all(color: Colors.white, width: 1.5) : null,
          ),
          child: _M3eInk(
            onPressed: _onPressed,
            radius: e / 2,
            color: fg,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                AnimatedBuilder(
                  animation: _turn.animation,
                  builder: (BuildContext _, Widget? child) => Transform.rotate(
                    angle: dir * _turn.value * 40 * math.pi / 180,
                    child: child,
                  ),
                  child: Transform.flip(
                    flipX: widget.forward,
                    child: Icon(
                      Icons.replay_rounded,
                      size: e * 0.62,
                      color: fg,
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(top: e * 0.05),
                  child: Text(
                    '${widget.seconds}',
                    style: TextStyle(
                      color: fg,
                      fontSize: e * 0.2,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 显隐位移
// ---------------------------------------------------------------------------

/// 控制条显隐时的位移 + 缩放：显示时从 [hiddenOffset]（逻辑像素）、[hiddenScale]
/// 弹回原位，隐藏时收回（M3E spatial spring，与共享 [FushiChromeReveal] 同参）。
///
/// fork 在控制条隐藏淡出结束后会**卸载**整排按钮，所以「出现」只能靠挂载时自己
/// 从偏移处起步（initState 里正向播一次）；「隐藏」跟随 [visible] 反向播。
/// [enabled] false（Apple 分支）时恒在原位——结构不随设计系统增删包装层。
class VideoM3eChromeSlide extends StatefulWidget {
  const VideoM3eChromeSlide({
    super.key,
    required this.enabled,
    required this.visible,
    required this.hiddenOffset,
    required this.child,
    this.hiddenScale = 0.92,
  });

  final bool enabled;
  final ValueListenable<bool> visible;
  final Offset hiddenOffset;

  /// 隐藏态的缩放（以朝 [hiddenOffset] 的那条边为锚点）。
  final double hiddenScale;
  final Widget child;

  @override
  State<VideoM3eChromeSlide> createState() => _VideoM3eChromeSlideState();
}

/// 浮动工具栏显隐弹簧：与共享 [FushiChromeReveal]（阅读器 / 漫画工具栏）同一组
/// 参数（刚度 520、阻尼比 0.82，带一点回弹的落位），三处显隐手感一致。
final SpringDescription _videoChromeSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 520,
  ratio: 0.82,
);

class _VideoM3eChromeSlideState extends State<VideoM3eChromeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
  );
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.visible.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.enabled || !fushiMotionEnabled(context)) {
      _c.value = 1;
    } else if (widget.visible.value) {
      _c.value = 0;
      _springTo(1);
    }
  }

  @override
  void didUpdateWidget(VideoM3eChromeSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible.removeListener(_sync);
      widget.visible.addListener(_sync);
    }
    if (!widget.enabled) {
      _c
        ..stop()
        ..value = 1;
    }
  }

  void _springTo(double target) {
    _c.animateWith(
      SpringSimulation(_videoChromeSpring, _c.value, target, _c.velocity),
    );
  }

  void _sync() {
    if (!mounted) return;
    if (!widget.enabled || !fushiMotionEnabled(context)) {
      _c
        ..stop()
        ..value = 1;
      return;
    }
    _springTo(widget.visible.value ? 1 : 0);
  }

  @override
  void dispose() {
    widget.visible.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Alignment anchor = widget.hiddenOffset.dy < 0
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext _, Widget? child) {
        final double t = _c.value;
        final double scale = widget.hiddenScale + (1 - widget.hiddenScale) * t;
        return Transform.translate(
          offset: widget.hiddenOffset * (1 - t),
          child: Transform.scale(
            scale: scale.clamp(0.0, 1.2),
            alignment: anchor,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// 进度条轨道
// ---------------------------------------------------------------------------

/// 字幕密度刻度：把 cue 覆盖时间按 [buckets] 个桶统计成 0..1 的密度（纯函数）。
/// 空 / 时长未知时返回空表。
List<double> videoCueDensity(
  Iterable<({int startMs, int endMs})> cues,
  int durationMs, {
  int buckets = 160,
}) {
  if (durationMs <= 0 || buckets <= 0) return const <double>[];
  final List<double> out = List<double>.filled(buckets, 0);
  final double bucketMs = durationMs / buckets;
  bool any = false;
  for (final ({int startMs, int endMs}) cue in cues) {
    final int s = cue.startMs.clamp(0, durationMs);
    final int e = cue.endMs.clamp(0, durationMs);
    if (e <= s) continue;
    any = true;
    int b = (s / bucketMs).floor().clamp(0, buckets - 1);
    final int last = ((e - 1) / bucketMs).floor().clamp(0, buckets - 1);
    for (; b <= last; b++) {
      final double bs = b * bucketMs;
      final double be = bs + bucketMs;
      final double overlap = math.min(be, e.toDouble()) - math.max(bs, s);
      if (overlap > 0) out[b] += overlap / bucketMs;
    }
  }
  if (!any) return const <double>[];
  for (int i = 0; i < out.length; i++) {
    out[i] = out[i].clamp(0.0, 1.0);
  }
  return out;
}

/// MD3 Expressive 进度条轨道（fork `seekBarTrackBuilder` 的产物，填满进度条热区）。
///
/// - 已播段：播放中是流动的正弦波（振幅 3、波长 32，随界面缩放），暂停 / 拖动时
///   振幅弹簧收平成直线；
/// - 手柄：竖条（4 宽），与两侧轨道留缝；悬停 / 拖动时轨道加粗、手柄拉高；
/// - 未播段：直线，缓冲段浅一档，尾端一个停止点；
/// - 拖动（以及 [hoverBubble] 时的悬停）在手柄上方出时间气泡；
/// - [cueDensity] 非空时在轨道上方画淡淡的字幕密度刻度。
class VideoM3eSeekTrack extends StatefulWidget {
  const VideoM3eSeekTrack({
    super.key,
    required this.visual,
    required this.color,
    required this.scale,
    this.hoverBubble = false,
    this.cueDensity = const <double>[],
    this.lane,
  });

  final VideoSeekBarVisual visual;

  /// 悬浮轨道槽的底色（浮动工具栏上方那条胶囊槽，左右探出轨道一点）；null = 不画，
  /// 轨道直接压在画面上。槽只是装饰，seek 命中与落点仍归 fork 的整条热区。
  final Color? lane;

  /// 已播段 / 手柄颜色（chrome 强调色）。
  final Color color;

  /// 界面缩放 × 密度档缩放。
  final double scale;

  /// 桌面悬停时也出时间气泡（没有缩略图预览时；有缩略图预览时它自带时间戳）。
  final bool hoverBubble;

  /// 见 [videoCueDensity]。
  final List<double> cueDensity;

  @override
  State<VideoM3eSeekTrack> createState() => _VideoM3eSeekTrackState();
}

class _VideoM3eSeekTrackState extends State<VideoM3eSeekTrack>
    with TickerProviderStateMixin {
  /// 波形相位：一轮流过一个波长。
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// 振幅：1 = 波浪，0 = 直线。
  late final AnimationController _amp = AnimationController(
    vsync: this,
    duration: FushiMotion.medium,
    value: _wantsWave ? 1 : 0,
  );

  /// 激活（悬停 / 拖动）：轨道加粗、手柄拉高。
  late final AnimationController _active = AnimationController(
    vsync: this,
    duration: FushiMotion.short,
    value: _isActive ? 1 : 0,
  );

  bool get _wantsWave => widget.visual.playing && !widget.visual.dragging;
  bool get _isActive => widget.visual.hovering || widget.visual.dragging;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(animate: false);
  }

  @override
  void didUpdateWidget(VideoM3eSeekTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(animate: true);
  }

  void _sync({required bool animate}) {
    final bool motion = fushiMotionEnabled(context);
    final double ampTarget = motion && _wantsWave ? 1 : 0;
    final double activeTarget = _isActive ? 1 : 0;
    if (!motion || !animate) {
      _amp.value = ampTarget;
      _active.value = activeTarget;
    } else {
      _amp.animateTo(ampTarget, curve: FushiMotion.standard);
      _active.animateTo(activeTarget, curve: FushiMotion.standard);
    }
    if (motion && _wantsWave) {
      if (!_phase.isAnimating) _phase.repeat();
    } else {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    _amp.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoSeekBarVisual v = widget.visual;
    final bool eink = isEinkTheme(context);
    final bool bubble =
        v.duration > Duration.zero &&
        (v.dragging || (widget.hoverBubble && v.hovering && v.hover != null));
    final double fraction = (v.dragging ? v.position : (v.hover ?? v.position))
        .clamp(0.0, 1.0);
    final ColorScheme chrome = videoM3eChromeScheme(
      Theme.of(context).colorScheme,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final double s = widget.scale;
        final double centerY = v.alignment.y >= 0.5
            ? h - (6 + 4) * s
            : h * (v.alignment.y + 1) / 2;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _M3eTrackPainter(
                  phase: _phase,
                  amp: _amp,
                  active: _active,
                  position: v.position.clamp(0.0, 1.0),
                  buffer: v.buffer.clamp(0.0, 1.0),
                  color: widget.color,
                  // 未播 / 缓冲段是中性半透明白（与胶囊的中性表面同一层级），
                  // 强调色只留给已播段与手柄。
                  trackColor: eink
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.2),
                  bufferColor: eink
                      ? Colors.white.withValues(alpha: 0.75)
                      : Colors.white.withValues(alpha: 0.36),
                  // 字幕密度刻度只是背景信息：更淡、更短、更稀（见 painter）。
                  cueColor: Colors.white.withValues(alpha: 0.22),
                  cueDensity: widget.cueDensity,
                  scale: s,
                  centerY: centerY,
                  rtl: Directionality.of(context) == TextDirection.rtl,
                  lane: widget.lane,
                ),
              ),
            ),
            if (bubble)
              Positioned(
                left: (w * fraction).clamp(0.0, w),
                top: centerY - 14 * s,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -1),
                  child: _M3eTimeBubble(
                    label: videoM3eFormatTime(
                      v.duration * fraction,
                      reference: v.duration,
                    ),
                    background: eink ? Colors.black : chrome.inverseSurface,
                    foreground: eink ? Colors.white : chrome.onInverseSurface,
                    outlined: eink,
                    scale: s,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _M3eTimeBubble extends StatelessWidget {
  const _M3eTimeBubble({
    required this.label,
    required this.background,
    required this.foreground,
    required this.outlined,
    required this.scale,
  });

  final String label;
  final Color background;
  final Color foreground;
  final bool outlined;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 5 * scale,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: outlined ? Border.all(color: foreground, width: 1.5) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 13 * scale,
          height: 1.1,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _M3eTrackPainter extends CustomPainter {
  _M3eTrackPainter({
    required this.phase,
    required this.amp,
    required this.active,
    required this.position,
    required this.buffer,
    required this.color,
    required this.trackColor,
    required this.bufferColor,
    required this.cueColor,
    required this.cueDensity,
    required this.scale,
    required this.centerY,
    required this.rtl,
    this.lane,
  }) : super(repaint: Listenable.merge(<Listenable>[phase, amp, active]));

  final Animation<double> phase;
  final Animation<double> amp;
  final Animation<double> active;
  final double position;
  final double buffer;
  final Color color;
  final Color trackColor;
  final Color bufferColor;
  final Color cueColor;
  final List<double> cueDensity;
  final double scale;
  final double centerY;
  final bool rtl;
  final Color? lane;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    if (w <= 0) return;
    if (rtl) {
      canvas
        ..save()
        ..translate(w, 0)
        ..scale(-1, 1);
    }
    final double a = active.value;
    final double s = scale;
    final double stroke = (4 + 2 * a) * s;
    final double gap = 4 * s;
    final double handleW = 4 * s;
    final double handleH = (16 + 8 * a) * s;
    final double y = centerY;
    final double x = w * position;
    final double amplitude = 3 * s * amp.value;
    final double wavelength = 32 * s;

    // 悬浮轨道槽：一条浅槽，左右各探出 12（外缘与底栏胶囊外缘对齐），竖直包住
    // 波浪与手柄的静止高度。只带一层很轻的投影——它是托住轨道的浅底，不是一条压在
    // 画面上的实体深色条。
    final Color? laneColor = lane;
    if (laneColor != null) {
      final double laneHalf = (6 + 2 * a) * s;
      final RRect laneRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(-12 * s, y - laneHalf, w + 12 * s, y + laneHalf),
        Radius.circular(laneHalf),
      );
      canvas
        ..drawShadow(
          Path()..addRRect(laneRect),
          const Color(0x40000000),
          1,
          false,
        )
        ..drawRRect(laneRect, Paint()..color = laneColor);
    }

    // 字幕密度刻度：轨道上方一排细竖线，高度与透明度随密度。相邻刻度至少隔
    // 5 * scale（按组取最大密度合并），极稀的桶不画——刻度是背景信息，不该密成
    // 一排栅栏。
    if (cueDensity.isNotEmpty) {
      final Paint cue = Paint()
        ..strokeWidth = math.max(1, 1.2 * s)
        ..strokeCap = StrokeCap.round;
      final double bucket = w / cueDensity.length;
      final int stride = math.max(1, (5 * s / bucket).ceil());
      final double step = bucket * stride;
      for (int i = 0; i < cueDensity.length; i += stride) {
        double d = 0;
        for (int j = i; j < math.min(i + stride, cueDensity.length); j++) {
          d = math.max(d, cueDensity[j]);
        }
        if (d <= 0.08) continue;
        final double cx = bucket * i + math.min(step, w - bucket * i) / 2;
        if ((cx - x).abs() < handleW + gap) continue;
        cue.color = cueColor.withValues(alpha: cueColor.a * (0.3 + 0.7 * d));
        final double base = y - stroke / 2 - 3 * s - amplitude;
        canvas.drawLine(
          Offset(cx, base - 1.5 * s - 2 * s * d),
          Offset(cx, base),
          cue,
        );
      }
    }

    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // 未播段（含缓冲段）：手柄右侧留缝起画。
    final double restStart = x + handleW / 2 + gap + stroke / 2;
    final double restEnd = w - stroke / 2;
    if (restEnd > restStart) {
      line.color = trackColor;
      canvas.drawLine(Offset(restStart, y), Offset(restEnd, y), line);
      final double bufEnd = math.min(w * buffer, restEnd);
      if (bufEnd > restStart) {
        line.color = bufferColor;
        canvas.drawLine(Offset(restStart, y), Offset(bufEnd, y), line);
      }
    }
    // 停止点（M3E 轨道尾端）。
    canvas.drawCircle(
      Offset(w - stroke / 2, y),
      stroke / 2 * 0.6,
      Paint()..color = color,
    );

    // 已播段：手柄左侧留缝止画。
    final double playedEnd = x - handleW / 2 - gap - stroke / 2;
    final double playedStart = stroke / 2;
    if (playedEnd > playedStart) {
      line.color = color;
      if (amplitude <= 0.05) {
        canvas.drawLine(Offset(playedStart, y), Offset(playedEnd, y), line);
      } else {
        final Path path = Path();
        final double shift = phase.value * wavelength;
        const double step = 2;
        // 起步一个波长内振幅渐入，避免左端翘起。
        for (double px = playedStart; px <= playedEnd; px += step) {
          final double ramp = ((px - playedStart) / wavelength).clamp(0.0, 1.0);
          final double tail = ((playedEnd - px) / (wavelength / 2)).clamp(
            0.0,
            1.0,
          );
          final double py =
              y +
              amplitude *
                  math.min(ramp, tail) *
                  math.sin((px - shift) / wavelength * 2 * math.pi);
          if (px == playedStart) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        path.lineTo(playedEnd, y);
        canvas.drawPath(path, line);
      }
    }

    // 手柄：竖条。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y), width: handleW, height: handleH),
        Radius.circular(handleW / 2),
      ),
      Paint()..color = color,
    );
    if (rtl) canvas.restore();
  }

  @override
  bool shouldRepaint(_M3eTrackPainter old) =>
      old.position != position ||
      old.buffer != buffer ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.bufferColor != bufferColor ||
      !identical(old.cueDensity, cueDensity) ||
      old.scale != scale ||
      old.centerY != centerY ||
      old.rtl != rtl ||
      old.lane != lane;
}

// ---------------------------------------------------------------------------
// 时间
// ---------------------------------------------------------------------------

/// 底栏时间：`已播 / 总长`，等宽数字。[showRemaining] 时显示 `-剩余 / 总长`。
/// [onToggle] 非 null 时可点按切换（键盘 Enter 同样生效）。
class VideoM3eTimeText extends StatelessWidget {
  const VideoM3eTimeText({
    super.key,
    required this.position,
    required this.duration,
    required this.style,
    this.showRemaining = false,
    this.onToggle,
    this.tooltip,
  });

  final Duration position;
  final Duration duration;
  final TextStyle style;
  final bool showRemaining;
  final VoidCallback? onToggle;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final String head = showRemaining
        ? '-${videoM3eFormatTime(duration - position, reference: duration)}'
        : videoM3eFormatTime(position, reference: duration);
    final String total = videoM3eFormatTime(duration, reference: duration);
    final Widget text = Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(text: head),
          TextSpan(
            text: ' / $total',
            style: TextStyle(color: style.color?.withValues(alpha: 0.7)),
          ),
        ],
      ),
      maxLines: 1,
      style: style.copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
    final VoidCallback? toggle = onToggle;
    if (toggle == null) return text;
    final Widget button = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: toggle,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: text,
        ),
      ),
    );
    final String? tip = tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}

/// [VideoM3eTimeText] 接 media_kit [Player] 的位置 / 时长流；只在显示的秒数变化时
/// 重建（位置流是逐帧的，整秒节流后一秒最多一次 setState）。
class VideoM3ePositionIndicator extends StatefulWidget {
  const VideoM3ePositionIndicator({
    super.key,
    required this.player,
    required this.style,
    this.showRemaining = false,
    this.onToggle,
    this.tooltip,
  });

  final Player player;
  final TextStyle style;
  final bool showRemaining;
  final VoidCallback? onToggle;
  final String? tooltip;

  @override
  State<VideoM3ePositionIndicator> createState() =>
      _VideoM3ePositionIndicatorState();
}

class _VideoM3ePositionIndicatorState extends State<VideoM3ePositionIndicator> {
  late Duration _position = _floor(widget.player.state.position);
  late Duration _duration = widget.player.state.duration;
  final List<StreamSubscription<Duration>> _subs =
      <StreamSubscription<Duration>>[];

  static Duration _floor(Duration d) => Duration(seconds: d.inSeconds);

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _subs
      ..add(
        widget.player.stream.position.listen((Duration p) {
          final Duration next = _floor(p);
          if (next != _position && mounted) setState(() => _position = next);
        }),
      )
      ..add(
        widget.player.stream.duration.listen((Duration d) {
          if (d != _duration && mounted) setState(() => _duration = d);
        }),
      );
  }

  void _cancel() {
    for (final StreamSubscription<Duration> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  @override
  void didUpdateWidget(VideoM3ePositionIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _cancel();
      _position = _floor(widget.player.state.position);
      _duration = widget.player.state.duration;
      _listen();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VideoM3eTimeText(
      position: _position,
      duration: _duration,
      style: widget.style,
      showRemaining: widget.showRemaining,
      onToggle: widget.onToggle,
      tooltip: widget.tooltip,
    );
  }
}

// ---------------------------------------------------------------------------
// 双击快进 / 快退涟漪
// ---------------------------------------------------------------------------

/// 一次双击跳转的提示事件（[VideoM3eDoubleTapRipple] 的输入）。[serial] 每次自增，
/// 同侧连按也能重播动画。
@immutable
class VideoM3eRippleEvent {
  const VideoM3eRippleEvent({
    required this.forward,
    required this.label,
    required this.origin,
    required this.serial,
  });

  final bool forward;
  final String label;

  /// 双击点（叠加层本地坐标）。
  final Offset origin;
  final int serial;
}

/// MD3 Expressive 双击快进 / 快退提示：被点那一侧铺一块半椭圆浅色涟漪（从双击点
/// 扩散），中间是三枚依次点亮的箭头 + 「+10s」。纯视觉，[IgnorePointer]；墨水屏 /
/// 减弱动效下只静态显示一小会儿。
class VideoM3eDoubleTapRipple extends StatefulWidget {
  const VideoM3eDoubleTapRipple({super.key, required this.events});

  final ValueListenable<VideoM3eRippleEvent?> events;

  @override
  State<VideoM3eDoubleTapRipple> createState() =>
      _VideoM3eDoubleTapRippleState();
}

class _VideoM3eDoubleTapRippleState extends State<VideoM3eDoubleTapRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  VideoM3eRippleEvent? _event;

  @override
  void initState() {
    super.initState();
    widget.events.addListener(_onEvent);
  }

  @override
  void didUpdateWidget(VideoM3eDoubleTapRipple oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events != widget.events) {
      oldWidget.events.removeListener(_onEvent);
      widget.events.addListener(_onEvent);
    }
  }

  void _onEvent() {
    final VideoM3eRippleEvent? e = widget.events.value;
    if (e == null || !mounted) return;
    setState(() => _event = e);
    if (fushiMotionEnabled(context)) {
      _c.forward(from: 0);
    } else {
      // 静态：停在扩散完成的一帧，700ms 后清掉。
      _c.value = 0.6;
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted && identical(_event, e)) setState(() => _event = null);
      });
    }
  }

  @override
  void dispose() {
    widget.events.removeListener(_onEvent);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoM3eRippleEvent? e = _event;
    if (e == null) return const SizedBox.shrink();
    final bool eink = isEinkTheme(context);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? _) {
          final double t = _c.value;
          if (t >= 1) return const SizedBox.shrink();
          // 前 70% 扩散，后 30% 淡出。
          final double fade = t < 0.7 ? 1 : (1 - (t - 0.7) / 0.3);
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double w = c.maxWidth;
              final double h = c.maxHeight;
              final double sideW = w * 0.36;
              return Stack(
                children: <Widget>[
                  Positioned(
                    left: e.forward ? null : 0,
                    right: e.forward ? 0 : null,
                    top: 0,
                    bottom: 0,
                    width: sideW,
                    child: Opacity(
                      opacity: fade.clamp(0.0, 1.0),
                      child: ClipPath(
                        clipper: _SideEllipseClipper(right: e.forward),
                        child: CustomPaint(
                          painter: _RipplePainter(
                            origin: Offset(
                              e.forward
                                  ? e.origin.dx - (w - sideW)
                                  : e.origin.dx,
                              e.origin.dy,
                            ),
                            progress: Curves.easeOutCubic.transform(
                              (t / 0.7).clamp(0.0, 1.0),
                            ),
                            maxRadius: math.max(sideW, h),
                            eink: eink,
                          ),
                          child: Center(
                            child: _RippleLabel(
                              forward: e.forward,
                              label: e.label,
                              t: t,
                              eink: eink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _SideEllipseClipper extends CustomClipper<Path> {
  const _SideEllipseClipper({required this.right});

  final bool right;

  @override
  Path getClip(Size size) {
    // 半椭圆：贴屏幕边一侧是直边，朝内一侧鼓出。
    final Rect oval = right
        ? Rect.fromLTWH(
            0,
            -size.height * 0.15,
            size.width * 2,
            size.height * 1.3,
          )
        : Rect.fromLTWH(
            -size.width,
            -size.height * 0.15,
            size.width * 2,
            size.height * 1.3,
          );
    return Path()..addOval(oval);
  }

  @override
  bool shouldReclip(_SideEllipseClipper oldClipper) =>
      oldClipper.right != right;
}

class _RipplePainter extends CustomPainter {
  const _RipplePainter({
    required this.origin,
    required this.progress,
    required this.maxRadius,
    required this.eink,
  });

  final Offset origin;
  final double progress;
  final double maxRadius;
  final bool eink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = eink
            ? const Color(0xCC000000)
            : Colors.white.withValues(alpha: 0.10),
    );
    if (eink) return;
    canvas.drawCircle(
      origin,
      maxRadius * progress,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16 * (1 - progress * 0.6)),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.origin != origin || old.eink != eink;
}

class _RippleLabel extends StatelessWidget {
  const _RippleLabel({
    required this.forward,
    required this.label,
    required this.t,
    required this.eink,
  });

  final bool forward;
  final String label;
  final double t;
  final bool eink;

  @override
  Widget build(BuildContext context) {
    Widget arrow(int i) {
      // 三枚箭头依次点亮（方向感节拍）。
      final double phase = ((t * 3) - i * 0.5).clamp(0.0, 1.0);
      final double a = eink ? 1 : 0.35 + 0.65 * math.sin(phase * math.pi);
      return Icon(
        Icons.play_arrow_rounded,
        size: 22,
        color: Colors.white.withValues(alpha: a),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Transform.flip(
          flipX: !forward,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[for (int i = 0; i < 3; i++) arrow(i)],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 跳过片头 / 片尾
// ---------------------------------------------------------------------------

/// 「跳过片头 / 片尾」按钮本体（播放页 `_buildSkipChapterButton` 负责出现时机与
/// 位置）。MD3：主色容器 Expressive 胶囊，按下形变（[FushiPressMorph]）；墨水屏
/// 实色描边；Apple（[apple]）：深色玻璃胶囊。都是可聚焦按钮（Tab / 手柄可达，
/// Enter 触发）。
class VideoSkipChapterButton extends StatelessWidget {
  const VideoSkipChapterButton({
    super.key,
    required this.label,
    required this.scale,
    required this.apple,
    required this.onPressed,
  });

  final String label;
  final double scale;
  final bool apple;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 18 * scale,
        vertical: 12 * scale,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(Icons.double_arrow_rounded, size: 20 * scale),
          SizedBox(width: 8 * scale),
          Text(
            label,
            style: TextStyle(
              fontSize: 14 * scale,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
    if (apple) {
      return VideoGlassHud(
        padding: EdgeInsets.zero,
        child: FushiPlainButton(
          onPressed: onPressed,
          semanticLabel: label,
          borderRadius: BorderRadius.circular(999),
          child: content,
        ),
      );
    }
    final ColorScheme chrome = videoM3eChromeScheme(
      Theme.of(context).colorScheme,
    );
    final bool eink = isEinkTheme(context);
    final ButtonStyle style = FilledButton.styleFrom(
      backgroundColor: eink ? Colors.black : chrome.primaryContainer,
      foregroundColor: eink
          ? videoChromeNeutralForeground
          : chrome.onPrimaryContainer,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: eink
          ? const BorderSide(color: videoChromeNeutralForeground, width: 1.5)
          : null,
    );
    return FushiPressMorph(
      enabled: true,
      style: style,
      builder: (BuildContext _, ButtonStyle? s, WidgetStatesController? c) =>
          FilledButton(
            onPressed: onPressed,
            style: s,
            statesController: c,
            child: content,
          ),
    );
  }
}
