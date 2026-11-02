import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout_editor.dart'
    show lyricsControlItemIcon, lyricsControlItemLabel;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiExpressiveShape, FushiExpressiveShapeBorder;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator, FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

part 'lyrics_player_md3_modern.part.dart';

// MD3（Material 3 Expressive）歌词播放页。
//
// 宽屏（横屏 / 桌面窗口）：左栏封面卡 + 书名 + 读数 chip + 波浪进度条 + 播放键组，
// 右栏是歌词 WebView（透明底），背后垫一块半透明大圆角底板；右上角关闭。
// 窄屏（手机竖屏）：不放封面（用户原话「显示封面的话手机可能放不下」），顶栏书名
// + 一行读数，中间全屏歌词，底部悬浮控制条。
//
// 配色全部读 Theme.of(context).colorScheme——覆盖层外壳已经用封面动态取色换掉了
// 整棵子树的 ColorScheme，所以这里拿到的就是封面色。
//
// 控件层只在画了东西的地方吃指针：根是不铺满的 Stack + Positioned，空白处让给
// 下面的歌词 WebView。歌词底板因此只能画在背景层里（WebView 在控件层下面）。

/// MD3 extra-large 圆角（28）：封面卡、歌词底板、窄屏控制条同一档。复用令牌
/// 里的 28（底部弹层同档），不另起一个数。
const double _kLargeRadius = FushiRadii.sheetValue;
const BorderRadius _kLargeBorderRadius = BorderRadius.all(
  Radius.circular(_kLargeRadius),
);

/// 窄屏顶栏的最小高度（实际高度见 [_NarrowGeometry]，随文字缩放增高）。
const double _kNarrowTopBarHeight = 56;

/// 窄屏播放卡：小封面边长、上下内边距、进度条波浪高度、播放键行高度。
const double _kMiniCoverSize = 44;
const double _kNarrowCardPadding = 14;
const double _kNarrowSeekBarHeight = 36;
const double _kNarrowTransportHeight = 64;

/// 窄屏头行里章名至少要留的宽度；不够时先省掉小封面，再不够连章名一起省。
const double _kNarrowMinTitleWidth = 56;

// ---------------------------------------------------------------------------
// 几何
// ---------------------------------------------------------------------------

/// 窄屏几何：顶栏与底部播放卡的高度按当前文字缩放下各行的真实行高和触控
/// 目标尺寸算出来（HBK048）。之前是写死的 56 / 210，200% 字号下顶栏底溢 24、
/// 卡片底溢 8；而头行的次要操作胶囊（触控平台 56 高）被 FittedBox 压进 44 高，
/// 按钮命中区跟着缩到 48 以下。歌词矩形与控件层共用同一份计算。
@immutable
class _NarrowGeometry {
  const _NarrowGeometry._({
    required this.tapDimension,
    required this.topBarHeight,
    required this.headerHeight,
    required this.seekRowHeight,
    required this.bar,
    required this.topBarBottom,
  });

  factory _NarrowGeometry.of(
    BuildContext context,
    Size size,
    EdgeInsets padding,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection dir = Directionality.of(context);
    final FushiTypography type = context.fushiType;
    final ThemeData theme = Theme.of(context);
    double line(TextStyle? style) {
      if (style == null) return 0;
      final TextPainter painter = TextPainter(
        text: TextSpan(text: 'Hg', style: style),
        textScaler: scaler,
        textDirection: dir,
        maxLines: 1,
      )..layout();
      final double height = painter.height;
      painter.dispose();
      return height.ceilToDouble();
    }

    final double tap = lyricsPlayerTapDimension(theme);
    // 次要操作胶囊 / 顶栏动作胶囊：按钮命中区 + 上下各 4 内边距。
    final double pill = tap + 8;
    final double topBar = <double>[
      _kNarrowTopBarHeight,
      pill,
      line(type.titleMediumEmphasized) + line(type.bodySmall),
    ].reduce(math.max);
    final double header = <double>[
      _kMiniCoverSize,
      pill,
      line(type.labelMediumEmphasized),
      line(type.titleSmallEmphasized),
    ].reduce(math.max);
    final double seekRow = math.max(
      _kNarrowSeekBarHeight + line(theme.textTheme.labelMedium),
      tap,
    );
    final double cardHeight =
        _kNarrowCardPadding +
        header +
        6 +
        seekRow +
        8 +
        _kNarrowTransportHeight +
        _kNarrowCardPadding;
    final double bottom = size.height - padding.bottom - 12;
    final Rect bar = Rect.fromLTRB(
      padding.left + 12,
      math.max(0, bottom - cardHeight),
      math.max(padding.left + 13, size.width - padding.right - 12),
      math.max(1, bottom),
    );
    return _NarrowGeometry._(
      tapDimension: tap,
      topBarHeight: topBar,
      headerHeight: header,
      seekRowHeight: seekRow,
      bar: bar,
      topBarBottom: padding.top + 8 + topBar,
    );
  }

  /// 触控目标边长（触控平台 48，桌面精确指针 40）。
  final double tapDimension;
  final double topBarHeight;
  final double headerHeight;
  final double seekRowHeight;

  /// 底部播放卡矩形（悬浮卡片：左右下各留 12 外边距）。
  final Rect bar;

  /// 卡片内容区宽度。
  double get innerWidth => math.max(0, bar.width - 2 * _kNarrowCardPadding);

  /// 标题上方插图卡的最大框：宽取卡片的 60%，高不超过 320、也不顶到顶栏
  /// （顶栏底到卡片顶之间再各留 12）。
  Size get popupSize => Size(
    bar.width * 0.6,
    math.max(0, math.min(320, bar.top - topBarBottom - 24)),
  );

  /// 顶栏底边（含系统顶 inset 与 8 外边距）。
  final double topBarBottom;
}

/// 图标按钮实际命中区的边长：触控平台（padded）撑到 48，桌面精确指针保持 40
/// 的视觉尺寸。
double lyricsPlayerTapDimension(ThemeData theme) =>
    theme.materialTapTargetSize == MaterialTapTargetSize.padded
    ? kMinInteractiveDimension
    : 40;

/// −10 秒 / 上一句 / 播放 / 下一句 / +10 秒：公共 [FushiTransportGroup] 接上歌词
/// 页的回调。
class _TransportGroup extends StatelessWidget {
  const _TransportGroup({
    required this.isPlaying,
    required this.callbacks,
    required this.playSize,
    required this.sideSize,
    required this.sideWidth,
    this.spacing = 8,
    this.showRelativeSeek = true,
  });

  final bool isPlaying;
  final LyricsPlayerCallbacks callbacks;
  final double playSize;
  final ButtonSizeVariant sideSize;
  final IconButtonWidthVariant sideWidth;
  final double spacing;

  /// false = ±10 秒不在这一行（窄屏放不下时挪到进度条两侧，见
  /// [_NarrowControlBar]）。
  final bool showRelativeSeek;

  @override
  Widget build(BuildContext context) => FushiTransportGroup(
    isPlaying: isPlaying,
    onPlayPause: callbacks.onPlayPause,
    onPrevious: callbacks.onPreviousCue,
    onNext: callbacks.onNextCue,
    onSeekRelative: callbacks.onSeekRelative,
    playSize: playSize,
    sideSize: sideSize,
    sideWidth: sideWidth,
    spacing: spacing,
    showRelativeSeek: showRelativeSeek,
  );
}

/// ±10 秒小号 tonal 圆钮（窄屏挪到进度条两侧时用）。
Widget _relativeSeekButton(int seconds, ValueChanged<int> seekBy) =>
    fushiRelativeSeekButton(seconds, seekBy);

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

class Md3LyricsPlayerDesign extends LyricsPlayerDesign {
  const Md3LyricsPlayerDesign({this.mirrorProgress = 0});

  /// 宽屏左右互换进度（见 [LyricsPlayerData.sidesMirrored]）：0 = 封面栏在左、
  /// 1 = 封面栏在右，中间值 = 换位动画途中（由 `ReaderLyricsPlayerOverlay` 按
  /// `fushiMotionDuration` 驱动，墨水屏 / 减弱动态下直接跳到终值）。
  final double mirrorProgress;

  @override
  Rect lyricsRect(BuildContext context, Size size, EdgeInsets padding) {
    if (lyricsPlayerIsWide(size)) {
      return LyricsShellMd3WideGeometry.of(
        size,
        padding,
        mirror: mirrorProgress,
      ).lyrics;
    }
    final _NarrowGeometry geometry = _NarrowGeometry.of(context, size, padding);
    final double top = padding.top + 8 + geometry.topBarHeight + 8;
    final double bottom = geometry.bar.top - 8;
    return Rect.fromLTRB(
      padding.left,
      top,
      size.width - padding.right,
      math.max(top + 1, bottom),
    );
  }

  @override
  Widget buildBackground(BuildContext context, LyricsPlayerData data) =>
      FushiMeshBackdrop(
        plateRect: lyricsShellMd3PlateResolver(mirrorProgress),
        // 歌词模式背景静止（2026-10-31 用户拍板：原 30fps 常驻流动是发热源），
        // 只在配色变化时交叉过渡一次。
        animate: false,
        colorTransition: true,
      );

  @override
  Widget buildChrome(
    BuildContext context,
    LyricsPlayerData data,
    LyricsPlayerCallbacks callbacks, {
    required Size size,
    required EdgeInsets padding,
    required Rect lyricsRect,
  }) {
    if (lyricsPlayerIsWide(size)) {
      final LyricsShellMd3WideGeometry geometry = LyricsShellMd3WideGeometry.of(
        size,
        padding,
        mirror: mirrorProgress,
      );
      final VoidCallback? onExitBook = callbacks.onExitBook;
      final List<Widget> corner = _md3ControlButtons(
        data.wideControls.itemsIn(LyricsControlSlot.top),
        data,
        callbacks,
        wide: true,
        tonal: true,
      );
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fromRect(
            rect: geometry.panel,
            child: _WidePanel(data: data, callbacks: callbacks),
          ),
          // 底板右上角：布局「顶部」区的按钮（出厂 书籍模式 + 左右互换）+ 关闭
          // （M3E 按钮组，tonal 同一档）。有 [LyricsPlayerCallbacks.onExitBook] 时
          // × 直接退书回书架，回正文交给「书籍模式」键（反馈 QvYpZODImz）。
          Positioned(
            top: geometry.plate.top + 12,
            right: size.width - geometry.plate.right + 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final Widget button in corner) ...<Widget>[
                  button,
                  const SizedBox(width: 8),
                ],
                FushiIconButtonControl.filledTonal(
                  key: const ValueKey<String>('lyrics_close_button'),
                  tooltip: onExitBook != null
                      ? t.lyrics_exit_to_library
                      : MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: onExitBook ?? callbacks.onClose,
                  icon: const FushiIcon(FushiIcons.close),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final _NarrowGeometry geometry = _NarrowGeometry.of(context, size, padding);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          top: padding.top + 8,
          left: padding.left + 16,
          right: padding.right + 8,
          height: geometry.topBarHeight,
          child: _NarrowTopBar(data: data, callbacks: callbacks),
        ),
        // 播放走过插图：标题上方弹出插图卡（与宽屏封面位同一套弹出逻辑），
        // 贴播放卡左缘、底边停在卡片上方 12。
        Positioned(
          left: geometry.bar.left,
          bottom: size.height - geometry.bar.top + 12,
          width: geometry.popupSize.width,
          height: geometry.popupSize.height,
          child: LyricsIllustrationPopupCard(
            controller: data.illustrations,
            width: geometry.popupSize.width,
            height: geometry.popupSize.height,
            // 弹出插图是一张卡：走 M3E 卡片形状档，不另立圆角数值。
            borderRadius: FushiM3eShape.cardRadius,
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) => callbacks.onOpenIllustration!(
                    index,
                    returnToCover: false,
                  ),
          ),
        ),
        Positioned.fromRect(
          rect: geometry.bar,
          child: _NarrowControlBar(
            data: data,
            callbacks: callbacks,
            geometry: geometry,
          ),
        ),
      ],
    );
  }

  @override
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LyricsHtmlTheme(
      textColor: cs.onSurfaceVariant,
      currentColor: cs.primary,
      accentColor: cs.primaryContainer,
      selectionTextColor: cs.onPrimaryContainer,
      contextOpacities: const <double>[0.62, 0.48, 0.38, 0.3],
      browsingOpacity: 0.7,
      deselectedScale: 0.94,
      anchorY: 0.42,
      edgeFade: 0.06,
      alignStart: true,
      contextBlurPx: 0,
      rowRadius: 16,
      // 已读句再退一档（M3E：读过的退到背景、要读的更清楚）。
      pastOpacityFactor: 0.7,
    );
  }
}

// ---------------------------------------------------------------------------
// 宽屏左栏
// ---------------------------------------------------------------------------

class _WidePanel extends StatelessWidget {
  const _WidePanel({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 封面区与播放卡之间的间距。
  static const double _gap = 16;

  /// 封面区低于这个高度（横屏手机）就不放封面，免得挤成邮票。
  static const double _minCoverExtent = 120;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 播放卡按内容高度（紧凑排布），封面 / 插图吃掉剩下的全部高度：栏宽是
        // 固定几何（[LyricsShellMd3WideGeometry]），封面变大只往竖向长，歌词区不受影响。
        // 竖版书封 / 插图按原比例放进「栏宽 × 剩余高度」的框里，不再先裁成
        // 正方形——以前竖图被正方形的高卡住，左右空出一大截。
        final Widget card = _SpringEntrance(
          delay: 0.18,
          child: _PlayerCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _TitleBlock(
                  title: data.title,
                  chapterLabel: data.chapterLabel,
                  large: true,
                ),
                const SizedBox(height: 8),
                _StatsChips(clock: data.clock),
                const SizedBox(height: 6),
                FushiWavySeekBar(
                  debugLabel: 'lyrics-md3-seek',
                  clock: data.clock,
                  isPlaying: data.isPlaying,
                  onSeek: callbacks.onSeek,
                  strokeWidth: 5,
                  barHeight: 32,
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _TransportGroup(
                    isPlaying: data.isPlaying,
                    callbacks: callbacks,
                    playSize: 68,
                    sideSize: ButtonSizeVariant.small,
                    sideWidth: IconButtonWidthVariant.standard,
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _SecondaryActions(
                    data: data,
                    callbacks: callbacks,
                    items: data.wideControls.itemsIn(LyricsControlSlot.toolbar),
                    wide: true,
                  ),
                ),
              ],
            ),
          ),
        );
        return Column(
          children: <Widget>[
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints area) {
                  final double height = area.maxHeight - _gap;
                  if (height < _minCoverExtent) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: _gap),
                    child: _SpringEntrance(
                      // 封面（带大投影）自成一层：控件层别处重画时不连带它
                      // 重新栅格化。
                      child: RepaintBoundary(
                        child: Center(
                          // 播放走过书中插图时封面位换成插图（见
                          // lyrics_illustration_view）。
                          child: LyricsIllustrationArtworkSlot(
                            controller: data.illustrations,
                            side: width,
                            height: height,
                            borderRadius: _kLargeBorderRadius,
                            onOpen: callbacks.onOpenIllustration == null
                                ? null
                                : (int index) => callbacks.onOpenIllustration!(
                                    index,
                                    returnToCover: false,
                                  ),
                            cover: _CoverTile(
                              cover: data.cover,
                              width: width,
                              height: height,
                              isPlaying: data.isPlaying,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 极端窗口比例 / 大字号下的兜底：播放卡等比缩小而不是溢出。
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(width: width, child: card),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 播放器浮动卡：与底部浮动导航 / 浮动工具栏同一套悬浮外观
/// （[fushiFloatingPillDecoration]：同一 container 色、同一投影、墨水屏描边无影），
/// 圆角取 28 的 extra-large 大圆角卡。宽屏左栏与窄屏底部控制条共用。
class _PlayerCard extends StatelessWidget {
  const _PlayerCard({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    const OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: _kLargeBorderRadius,
    );
    return DecoratedBox(
      decoration: fushiFloatingPillDecoration(
        context,
        color: fushiFloatingToolbarPalette(context).container,
        shape: shape,
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 章名（强调色 overline）+ 书名（M3E Emphasized）。章名未知时只显示书名。
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.title,
    required this.chapterLabel,
    required this.large,
  });

  final String title;
  final String? chapterLabel;

  /// 宽屏大字（titleLarge Emphasized、两行）/ 窄屏紧凑（一行）。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final String chapter = (chapterLabel ?? '').trim();
    final TextStyle chapterStyle =
        (large ? type.labelLargeEmphasized : type.labelMediumEmphasized)
            .copyWith(color: cs.primary);
    final TextStyle titleStyle =
        (large ? type.titleLargeEmphasized : type.titleSmallEmphasized)
            .copyWith(color: cs.onSurface);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (chapter.isNotEmpty)
          // 换章：新章名从下方弹入（spatial 弹簧位移 + effects 淡入）。
          AnimatedSwitcher(
            duration: motion.spatialDefault.duration,
            switchInCurve: motion.effectsDefault.curve,
            switchOutCurve: motion.effectsFast.curve,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: AlignmentDirectional.centerStart,
              children: <Widget>[...previous, if (current != null) current],
            ),
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: motion.spatialDefault.curve,
                          ),
                        ),
                    child: child,
                  ),
                ),
            child: Text(
              chapter,
              key: ValueKey<String>('lyrics_chapter_$chapter'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: chapterStyle,
            ),
          ),
        if (title.isNotEmpty)
          Text(
            title,
            maxLines: large ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
      ],
    );
  }
}

/// 进场：spatial 弹簧从下方上移 + effects 淡入（墨水屏 / 减弱动态效果时长归零，
/// 直接落位）。[delay] 是占总时长的比例，做错峰。
class _SpringEntrance extends StatelessWidget {
  const _SpringEntrance({required this.child, this.delay = 0});

  final Widget child;
  final double delay;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double d = delay.clamp(0.0, 0.6);
    Duration total(Duration base) =>
        base == Duration.zero ? Duration.zero : base * (1 / (1 - d));
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total(motion.effectsSlow.duration),
      curve: Interval(d, 1, curve: motion.effectsSlow.curve),
      builder: (BuildContext context, double fade, Widget? child) =>
          Opacity(opacity: fade.clamp(0.0, 1.0), child: child),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: total(motion.spatialSlow.duration),
        curve: Interval(d, 1, curve: motion.spatialSlow.curve),
        builder: (BuildContext context, double v, Widget? child) =>
            Transform.translate(offset: Offset(0, 28 * (1 - v)), child: child),
        child: child,
      ),
    );
  }
}

/// 大封面卡：按封面原比例放进 [width]×[height] 的框。M3E 形状变形：播放中圆角 28、
/// 暂停时圆角弹到 48 并略缩小（与播放键「播放圆 / 暂停圆角方」同一根弹簧节奏）。
/// 桌面悬停时朝指针轻微 3D 倾斜并上浮（阴影加深）。无封面画 9 瓣饼干形徽标。
class _CoverTile extends StatefulWidget {
  const _CoverTile({
    required this.cover,
    required this.width,
    required this.height,
    required this.isPlaying,
  });

  final ImageProvider? cover;
  final double width;
  final double height;
  final bool isPlaying;

  @override
  State<_CoverTile> createState() => _CoverTileState();
}

class _CoverTileState extends State<_CoverTile> with TickerProviderStateMixin {
  late final FushiSpring _playScale = FushiSpring(
    vsync: this,
    initial: widget.isPlaying ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  /// 指针在卡片上的归一化位置（-1–1）；null = 没悬停。
  Offset? _hover;

  /// 封面宽高比（宽 / 高）；解码前按常见书封 0.72。
  double _aspect = 0.72;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspect();
  }

  @override
  void didUpdateWidget(covariant _CoverTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) _resolveAspect();
    if (oldWidget.isPlaying != widget.isPlaying) {
      _playScale.animateTo(
        widget.isPlaying ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  /// 读封面真实尺寸：方形的有声书封面和竖长的书封都按原比例放，不硬裁。
  void _resolveAspect() {
    final ImageProvider? cover = widget.cover;
    final ImageStream? next = cover?.resolve(
      createLocalImageConfiguration(context),
    );
    if (next?.key == _stream?.key && next != null) return;
    _detach();
    if (next == null) return;
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      final double w = info.image.width.toDouble();
      final double h = info.image.height.toDouble();
      info.dispose();
      if (!mounted || w <= 0 || h <= 0) return;
      final double aspect = (w / h).clamp(0.5, 1.5);
      if ((aspect - _aspect).abs() > 0.001) setState(() => _aspect = aspect);
    });
    _stream = next..addListener(listener);
    _listener = listener;
  }

  void _detach() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    _playScale.dispose();
    super.dispose();
  }

  void _onHover(PointerHoverEvent event) {
    if (!fushiExpressiveMotionEnabled(context)) return;
    final Size? size = context.size;
    if (size == null || size.isEmpty) return;
    setState(() {
      _hover = Offset(
        (event.localPosition.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
        (event.localPosition.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double boxW = widget.width;
    final double boxH = widget.height;
    // contain：宽高比比框更宽就贴宽，否则贴高。
    final bool fitWidth = _aspect >= boxW / math.max(1, boxH);
    final double w = fitWidth ? boxW : boxH * _aspect;
    final double h = fitWidth ? boxW / _aspect : boxH;
    final ImageProvider? cover = widget.cover;
    final double badge = math.min(w, h) * 0.46;
    final Widget face = SizedBox(
      width: w,
      height: h,
      child: cover == null
          ? ColoredBox(
              color: FushiDesignTokens.of(context).surfaces.overlay,
              child: Center(
                child: AnimatedBuilder(
                  animation: _playScale.animation,
                  builder: (BuildContext context, Widget? child) =>
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          color: cs.primaryContainer,
                          shape: FushiExpressiveShapeBorder(
                            FushiExpressiveShape.cookie9,
                            rotation: _playScale.value * math.pi / 9,
                          ),
                        ),
                        child: child,
                      ),
                  child: SizedBox.square(
                    dimension: badge,
                    child: Center(
                      child: FushiIcon(
                        FushiIcons.books,
                        size: badge * 0.46,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : Image(
              image: cover,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
    );
    final Offset tilt = _hover ?? Offset.zero;
    final double liftTarget = _hover == null ? 0 : 1;
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => setState(() => _hover = null),
      child: SizedBox(
        width: boxW,
        height: boxH,
        child: Center(
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(end: tilt),
            duration: FushiMotion.medium,
            curve: FushiSpringCurve.spatial,
            builder: (BuildContext context, Offset tiltValue, Widget? _) {
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: liftTarget),
                duration: FushiMotion.medium,
                curve: FushiSpringCurve.spatial,
                builder: (BuildContext context, double lift, Widget? _) {
                  return AnimatedBuilder(
                    animation: _playScale.animation,
                    builder: (BuildContext context, Widget? child) {
                      // 播放 1.0、暂停 0.92；悬停再放大 2%。
                      final double scale =
                          0.92 + 0.08 * _playScale.value + 0.02 * lift;
                      // 形状变形：播放 28、暂停 48（弹簧过冲时不让圆角为负）。
                      final BorderRadius radius = BorderRadius.circular(
                        math.max(4.0, 48 - 20 * _playScale.value),
                      );
                      // 约 ±3.5°：指针在右边，卡片右侧朝里压（rotateY 正）。
                      final Matrix4 transform = Matrix4.identity()
                        ..setEntry(3, 2, 0.0012)
                        ..translateByDouble(0, -6 * lift, 0, 1)
                        ..rotateX(-tiltValue.dy * 0.06)
                        ..rotateY(tiltValue.dx * 0.06)
                        ..scaleByDouble(scale, scale, 1, 1);
                      return Transform(
                        alignment: Alignment.center,
                        transform: transform,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: radius,
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: cs.shadow.withValues(
                                  alpha: 0.22 + 0.12 * lift,
                                ),
                                blurRadius: 24 + 16 * lift,
                                offset: Offset(0, 12 + 8 * lift),
                              ),
                            ],
                          ),
                          child: ClipRRect(borderRadius: radius, child: child),
                        ),
                      );
                    },
                    child: face,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 读数
// ---------------------------------------------------------------------------

/// 千分位（读数 chip 用；与统计侧栏同口径的 1,234 写法）。
String _grouped(int n) {
  final String digits = n.abs().toString();
  final StringBuffer out = StringBuffer(n < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// 全书进度文案：`当前 / 总 · xx.xx%`；未就绪为 null。
String? _progressText(LyricsPlayerStats stats) {
  final int? cur = stats.currentChars;
  final int? total = stats.totalChars;
  final double? percent = stats.percent;
  if (cur == null || total == null || percent == null) return null;
  return '${_grouped(cur)} / ${_grouped(total)} · '
      '${percent.toStringAsFixed(2)}%';
}

String _sessionText(LyricsPlayerStats stats) =>
    formatLyricsPlayerTime(Duration(milliseconds: stats.sessionDurationMs));

String _speedText(LyricsPlayerStats stats) =>
    t.reader_stats_chars_per_hour(n: _grouped(stats.charsPerHour));

/// 每秒读一次 [LyricsPlayerClock.stats]（只读），变了才重建这一小块。
class _StatsBuilder extends StatefulWidget {
  const _StatsBuilder({required this.clock, required this.builder});

  final LyricsPlayerClock clock;
  final Widget Function(BuildContext context, LyricsPlayerStats stats) builder;

  @override
  State<_StatsBuilder> createState() => _StatsBuilderState();
}

class _StatsBuilderState extends State<_StatsBuilder> {
  late LyricsPlayerStats _stats = widget.clock.stats;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant _StatsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) _stats = widget.clock.stats;
  }

  void _poll() {
    if (!mounted) return;
    final LyricsPlayerStats next = widget.clock.stats;
    if (next != _stats) setState(() => _stats = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // 自带重绘边界：读数每秒一变只重录这一小块，不连带播放卡投影与封面。
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: widget.builder(context, _stats));
}

/// 宽屏读数：tonal 标签一行（阅读速度 / 全书进度 / 会话时长）。
class _StatsChips extends StatelessWidget {
  const _StatsChips({required this.clock});

  final LyricsPlayerClock clock;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget chip(IconData icon, String text) => FushiTag(
      text: text,
      icon: icon,
      dense: true,
      backgroundColor: cs.secondaryContainer.withValues(alpha: 0.8),
      foregroundColor: cs.onSecondaryContainer,
    );
    return _StatsBuilder(
      clock: clock,
      builder: (BuildContext context, LyricsPlayerStats stats) {
        final String? progress = _progressText(stats);
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            chip(FushiIcons.speed, _speedText(stats)),
            if (progress != null) chip(FushiIcons.books, progress),
            chip(
              stats.tracking ? FushiIcons.timer : FushiIcons.timerOff,
              _sessionText(stats),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 次要操作
// ---------------------------------------------------------------------------

/// tonal 倍速键：显示当前倍速，点开含拖动条的倍速面板（与普通阅读模式快捷
/// 设置同一条 `AudiobookSpeedSlider`），拖动实时生效。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({
    required this.speed,
    required this.onSpeedChanged,
    this.onSpeedPanel,
  });

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  /// 页面弹面板（面板开着期间停表）；null 时按钮自己弹。
  final ValueChanged<LyricsMenuAnchor>? onSpeedPanel;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Tooltip(
      message: t.playback_speed,
      child: Builder(
        builder: (BuildContext anchor) => FushiPressScale(
          child: FushiFilledButton.tonal(
            key: const ValueKey<String>('lyrics_speed_button'),
            onPressed: () {
              final ValueChanged<LyricsMenuAnchor>? viaPage = onSpeedPanel;
              final LyricsMenuAnchor? at = _anchorOf(anchor);
              if (viaPage != null && at != null) {
                viaPage(at);
                return;
              }
              unawaited(
                showLyricsSpeedPanel(
                  anchorContext: anchor,
                  speed: speed,
                  onChanged: onSpeedChanged,
                ),
              );
            },
            // 邻居被按下时本键按 M3E 设计让出宽度：标签缩一点而不是折成两行。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(formatLyricsSpeed(speed), style: style, maxLines: 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 次要操作工具条：一颗 surfaceContainerHighest 胶囊里的 M3E 标准按钮组（按下
/// 变宽、邻居让出）——布局「播放卡工具条」区的按钮（[LyricsControlLayout]，出厂
/// 宽屏 倍速 / 计时 / 重播 / 遮罩 / Aa / 统计，窄屏 倍速 / 计时 / 重播），⋯ 恒在末尾。
class _SecondaryActions extends StatelessWidget {
  const _SecondaryActions({
    required this.data,
    required this.callbacks,
    required this.items,
    required this.wide,
    this.padding = const EdgeInsets.all(4),
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final List<LyricsControlItem> items;
  final bool wide;

  /// 胶囊内边距。新版窄屏展开卡传 0：胶囊外高 = 48（按钮命中区），设计稿 v2。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: FushiDesignTokens.of(context).surfaces.overlay,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: padding,
        child: FushiButtonGroup(
          spacing: 2,
          children: <Widget>[
            ..._md3ControlButtons(
              items,
              data,
              callbacks,
              wide: wide,
              tonal: false,
            ),
            _MoreButton(onMore: callbacks.onMore),
          ],
        ),
      ),
    );
  }
}

/// 按钮在全局坐标里的矩形 + 它自己的 context（菜单 / 面板从它取歌词模式主题）。
LyricsMenuAnchor? _anchorOf(BuildContext anchor) {
  final RenderObject? box = anchor.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return LyricsMenuAnchor(
    rect: box.localToGlobal(Offset.zero) & box.size,
    context: anchor,
  );
}

/// 布局里一个区的按钮，按顺序渲染。页面没给回调的按钮（如没有 Aa 回调）与当前
/// 形态下无意义的按钮（左右互换只在宽屏）不画。[tonal] = 宽屏右上角那组
/// filledTonal 外观。
List<Widget> _md3ControlButtons(
  List<LyricsControlItem> items,
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required bool wide,
  required bool tonal,
}) => <Widget>[
  for (final LyricsControlItem item in items)
    ?_md3ControlButton(item, data, callbacks, wide: wide, tonal: tonal),
];

Widget? _md3ControlButton(
  LyricsControlItem item,
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required bool wide,
  required bool tonal,
}) {
  Widget iconButton({
    required Key key,
    required String tooltip,
    required VoidCallback onPressed,
    required IconData icon,
  }) => tonal
      ? FushiIconButtonControl.filledTonal(
          key: key,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: FushiIcon(icon),
        )
      : FushiIconButtonControl(
          key: key,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: FushiIcon(icon),
        );
  switch (item) {
    case LyricsControlItem.speed:
      return _SpeedButton(
        speed: data.speed,
        onSpeedChanged: callbacks.onSpeedChanged,
        onSpeedPanel: callbacks.onSpeedPanel,
      );
    case LyricsControlItem.studyTimer:
      final VoidCallback? onToggle = callbacks.onToggleStatsTimer;
      if (onToggle == null) return null;
      // 文案是「按下去会怎样」（与阅读器顶栏计时键同口径）；停着时换划掉的图标。
      final bool paused = data.statsTimerPaused;
      return iconButton(
        key: const ValueKey<String>('lyrics_study_timer_button'),
        tooltip: paused
            ? t.reader_stats_clock_resume
            : t.reader_stats_clock_pause,
        onPressed: onToggle,
        icon: paused ? FushiIcons.timerOff : FushiIcons.timer,
      );
    case LyricsControlItem.replayCue:
      final VoidCallback? onReplay = callbacks.onReplayCue;
      if (onReplay == null) return null;
      return iconButton(
        key: const ValueKey<String>('lyrics_replay_cue_button'),
        tooltip: t.lyrics_sentence_replay,
        onPressed: onReplay,
        icon: FushiIcons.replay,
      );
    case LyricsControlItem.mask:
      return _MaskButton(
        masked: data.lyricsMasked,
        onPressed: callbacks.onToggleMask,
      );
    case LyricsControlItem.typography:
      final ValueChanged<LyricsMenuAnchor>? onTypography =
          callbacks.onTypography;
      if (onTypography == null) return null;
      return _TypographyButton(onTypography: onTypography, tonal: tonal);
    case LyricsControlItem.statistics:
      return iconButton(
        key: const ValueKey<String>('lyrics_statistics_button'),
        tooltip: t.reading_statistics,
        onPressed: callbacks.onOpenStatistics,
        icon: FushiIcons.statistics,
      );
    case LyricsControlItem.bookMode:
      // 没有退书回调时 × 本身就是「回正文」，再摆一颗同义键只是重复。
      if (callbacks.onExitBook == null) return null;
      return iconButton(
        key: const ValueKey<String>('lyrics_return_to_book_button'),
        tooltip: t.book_mode,
        onPressed: callbacks.onClose,
        icon: FushiIcons.readingMode,
      );
    case LyricsControlItem.swapSides:
      final VoidCallback? onSwap = callbacks.onSwapSides;
      if (onSwap == null || !wide) return null;
      return iconButton(
        key: const ValueKey<String>('lyrics_swap_sides_button'),
        tooltip: t.lyrics_layout_swap_sides,
        onPressed: onSwap,
        icon: FushiIcons.swap,
      );
  }
}

// 遮罩（听力沉浸模糊）切换：toggle 图标键，开着时是选中态。
class _MaskButton extends StatelessWidget {
  const _MaskButton({required this.masked, required this.onPressed});

  final bool masked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FushiIconButtonControl.filledTonal(
      tooltip: t.lyrics_blur,
      isSelected: masked,
      onPressed: onPressed,
      icon: const FushiIcon(FushiIcons.visibility),
      selectedIcon: const FushiIcon(FushiIcons.visibilityOff),
    );
  }
}

/// Aa：歌词文字快捷面板（字号 / 竖排 / 更多歌词设置）。
class _TypographyButton extends StatelessWidget {
  const _TypographyButton({required this.onTypography, this.tonal = false});

  final ValueChanged<LyricsMenuAnchor> onTypography;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext anchor) {
        void open() {
          final LyricsMenuAnchor? at = _anchorOf(anchor);
          if (at != null) onTypography(at);
        }

        const Key key = ValueKey<String>('lyrics_typography_button');
        const Widget icon = FushiIcon(FushiIcons.textFields);
        return tonal
            ? FushiIconButtonControl.filledTonal(
                key: key,
                tooltip: t.lyrics_typography_title,
                onPressed: open,
                icon: icon,
              )
            : FushiIconButtonControl(
                key: key,
                tooltip: t.lyrics_typography_title,
                onPressed: open,
                icon: icon,
              );
      },
    );
  }
}

/// ⋯ 更多：把按钮的全局矩形与 context 交给页面锚定菜单（菜单从它取主题）。
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.onMore,
    this.collapsedItems = const <LyricsControlItem>[],
  });

  final ValueChanged<LyricsMenuAnchor> onMore;

  /// 新版宽屏右岛收进 ⋯ 的按钮（交给页面排在菜单最前）。
  final List<LyricsControlItem> collapsedItems;

  @override
  Widget build(BuildContext context) {
    return Builder(
      key: const ValueKey<String>('lyrics_more_button'),
      builder: (BuildContext anchor) => FushiIconButtonControl(
        tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
        onPressed: () {
          final LyricsMenuAnchor? at = _anchorOf(anchor);
          if (at == null) return;
          onMore(
            collapsedItems.isEmpty
                ? at
                : LyricsMenuAnchor(
                    rect: at.rect,
                    context: at.context,
                    collapsedItems: collapsedItems,
                  ),
          );
        },
        icon: const FushiIcon(FushiIcons.moreHoriz),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 窄屏
// ---------------------------------------------------------------------------

/// 窄屏顶栏：书名 + 一行读数小字；右侧遮罩 / Aa / 统计 / 关闭（悬浮胶囊）。
class _NarrowTopBar extends StatelessWidget {
  const _NarrowTopBar({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    return Row(
      children: <Widget>[
        // 窄屏（手机）左上角的返回键：退出歌词模式回到书页。此前唯一的出口是
        // 右侧动作胶囊最末一枚 ×，与遮罩 / 排版 / 统计挤在一起，用户找不到
        // 「返回」（2026-10-09 反馈：有声阅读界面没有返回键）；iOS 又没有系统
        // 返回键兜底。
        FushiIconButtonControl(
          key: const ValueKey<String>('lyrics_player_back'),
          tooltip: t.back,
          onPressed: callbacks.onClose,
          icon: const FushiIcon(FushiIcons.back),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                data.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.titleMediumEmphasized.copyWith(color: cs.onSurface),
              ),
              _StatsBuilder(
                clock: data.clock,
                builder: (BuildContext context, LyricsPlayerStats stats) {
                  final String? progress = _progressText(stats);
                  return Text(
                    <String>[
                      _speedText(stats),
                      if (progress != null) progress,
                      _sessionText(stats),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodySmall.tabular.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        // 动作组收进一颗悬浮胶囊（与 FushiFloatingTopBar 右侧按钮组同一外观）。
        FushiFloatingPill(
          color: fushiFloatingToolbarPalette(context).container,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 布局「顶部」区的按钮（出厂 遮罩 / Aa / 统计）。
              ..._md3ControlButtons(
                data.compactControls.itemsIn(LyricsControlSlot.top),
                data,
                callbacks,
                wide: false,
                tonal: false,
              ),
              // 左上角返回键回正文；× 直接退书回书架（反馈 QvYpZODImz）。
              if (callbacks.onExitBook != null)
                FushiIconButtonControl(
                  key: const ValueKey<String>('lyrics_close_button'),
                  tooltip: t.lyrics_exit_to_library,
                  onPressed: callbacks.onExitBook!,
                  icon: const FushiIcon(FushiIcons.close),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 窄屏底部浮动播放卡（与宽屏左栏同一张 [_PlayerCard]）：第一行小封面（形状
/// 变形）+ 章名 / 书名 + 倍速·睡眠定时·⋯ 工具条；下面波浪进度 + 时间；最下一行
/// −10 秒 / 上一句 / 播放 / 下一句 / +10 秒。
class _NarrowControlBar extends StatelessWidget {
  const _NarrowControlBar({
    required this.data,
    required this.callbacks,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _NarrowGeometry geometry;

  /// 头行：小封面 + 章名（让位）+ 倍速·睡眠·⋯ 胶囊（自然尺寸，不被压扁）。
  /// 宽度不够时先省掉小封面，再不够连章名一起省；胶囊本身比整行还宽的极端
  /// 宽度才等比缩小兜底，不溢出（HBK048：280 宽右溢 2.9px）。
  /// 播放键行怎么排（HBK049）：之前五颗键整组 FittedBox，320 宽时连 ±10 秒
  /// 一起缩到 44.67，触控平台偏中心点按落空。现在按命中区的真实宽度（触控
  /// 平台每颗至少 48）挑一档：放得下就原样；放不下先收间距、播放键 64→56；
  /// 再放不下把 ±10 秒挪到进度条两侧，播放键行只留上一句 / 播放 / 下一句。
  ({double playSize, double spacing, bool inlineSeek}) _transportLayout() {
    if (callbacks.onSeekRelative == null) {
      return (playSize: 64, spacing: 8, inlineSeek: false);
    }
    final double tap = geometry.tapDimension;
    final double seekWidth = math.max(40, tap);
    final double sideWidth = math.max(48, tap);
    double width(double play, double spacing) =>
        2 * seekWidth + 2 * sideWidth + play + 4 * spacing;
    final double inner = geometry.innerWidth;
    if (width(64, 8) <= inner) {
      return (playSize: 64, spacing: 8, inlineSeek: true);
    }
    if (width(56, 4) <= inner) {
      return (playSize: 56, spacing: 4, inlineSeek: true);
    }
    return (playSize: 64, spacing: 8, inlineSeek: false);
  }

  Widget _buildHeader(String chapter) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double rowWidth = constraints.maxWidth;
        return Row(
          children: <Widget>[
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints lead) {
                  final double room = lead.maxWidth;
                  // 本书有插图时小封面是窄屏唯一的插图入口：宽度不够先省章名
                  // （章名只是提示信息），封面留到最后。
                  final bool hasIllustrations =
                      data.illustrations?.items.isNotEmpty ?? false;
                  final bool showTitle = hasIllustrations
                      ? room >= _kMiniCoverSize + 12 + _kNarrowMinTitleWidth
                      : room >= _kNarrowMinTitleWidth;
                  final bool showCover = hasIllustrations
                      ? room >= _kMiniCoverSize
                      : room >= _kMiniCoverSize + 12 + _kNarrowMinTitleWidth;
                  if (!showTitle && !showCover) {
                    return const SizedBox.shrink();
                  }
                  return Row(
                    children: <Widget>[
                      if (showCover) ...<Widget>[
                        // 小封面兼插图入口：有新插图时换成插图缩略图，点它看
                        // 插图大图，看完回封面。
                        LyricsIllustrationCompactArtwork(
                          controller: data.illustrations,
                          onOpen: callbacks.onOpenIllustration == null
                              ? null
                              : (int index) => callbacks.onOpenIllustration!(
                                  index,
                                  returnToCover: true,
                                ),
                          builder:
                              (
                                BuildContext context,
                                ImageProvider? illustration,
                              ) => _MiniCover(
                                cover: illustration ?? data.cover,
                                isPlaying: data.isPlaying,
                                size: _kMiniCoverSize,
                              ),
                        ),
                        if (showTitle) const SizedBox(width: 12),
                      ],
                      if (showTitle)
                        Expanded(
                          // 章名也是插图入口（与小封面同一动作）。
                          child: LyricsIllustrationTapTarget(
                            controller: data.illustrations,
                            onOpen: callbacks.onOpenIllustration == null
                                ? null
                                : (int index) => callbacks.onOpenIllustration!(
                                    index,
                                    returnToCover: true,
                                  ),
                            child: _TitleBlock(
                              // 书名已在顶栏：这里有章名就只放章名（强调色），
                              // 没有才放书名。
                              title: chapter.isEmpty ? data.title : '',
                              chapterLabel: chapter.isEmpty ? null : chapter,
                              large: false,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: math.max(0, rowWidth - 8)),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _SecondaryActions(
                  data: data,
                  callbacks: callbacks,
                  items: data.compactControls.itemsIn(
                    LyricsControlSlot.toolbar,
                  ),
                  wide: false,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String chapter = (data.chapterLabel ?? '').trim();
    final ({double playSize, double spacing, bool inlineSeek}) transport =
        _transportLayout();
    final ValueChanged<int>? seekAside = transport.inlineSeek
        ? null
        : callbacks.onSeekRelative;
    return _SpringEntrance(
      child: _PlayerCard(
        padding: const EdgeInsets.all(_kNarrowCardPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: geometry.headerHeight,
              child: _buildHeader(chapter),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: geometry.seekRowHeight,
              child: Row(
                children: <Widget>[
                  if (seekAside != null) ...<Widget>[
                    _relativeSeekButton(-10, seekAside),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: FushiWavySeekBar(
                          debugLabel: 'lyrics-md3-seek',
                          clock: data.clock,
                          isPlaying: data.isPlaying,
                          onSeek: callbacks.onSeek,
                          strokeWidth: 5,
                          barHeight: _kNarrowSeekBarHeight,
                        ),
                      ),
                    ),
                  ),
                  if (seekAside != null) ...<Widget>[
                    const SizedBox(width: 4),
                    _relativeSeekButton(10, seekAside),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: _kNarrowTransportHeight,
              // 正常宽度下各键自然尺寸；只有连 ±10 秒挪走后都放不下的极端宽度
              // 才等比缩小兜底。
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _TransportGroup(
                  isPlaying: data.isPlaying,
                  callbacks: callbacks,
                  playSize: transport.playSize,
                  spacing: transport.spacing,
                  showRelativeSeek: transport.inlineSeek,
                  sideSize: ButtonSizeVariant.medium,
                  sideWidth: IconButtonWidthVariant.narrow,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 窄屏小封面：播放中圆角方（圆角 = 边长 28%）、暂停时弹成正圆（spatial 弹簧，
/// 降级时直接落值）。无封面画 primaryContainer 底 + 书本图标。
class _MiniCover extends StatelessWidget {
  const _MiniCover({
    required this.cover,
    required this.isPlaying,
    required this.size,
  });

  final ImageProvider? cover;
  final bool isPlaying;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final ImageProvider? image = cover;
    final int cache = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: isPlaying ? size * 0.28 : size / 2),
      duration: motion.spatialDefault.duration,
      curve: motion.spatialDefault.curve,
      builder: (BuildContext context, double radius, Widget? child) =>
          ClipRRect(
            borderRadius: BorderRadius.circular(radius.clamp(2.0, size / 2)),
            child: child,
          ),
      child: SizedBox.square(
        dimension: size,
        child: image == null
            ? ColoredBox(
                color: cs.primaryContainer,
                child: Center(
                  child: FushiIcon(
                    FushiIcons.books,
                    size: size * 0.5,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              )
            : Image(
                image: ResizeImage.resizeIfNeeded(cache, null, image),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
      ),
    );
  }
}
