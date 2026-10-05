/// 作品详情页的 **M3E 共享骨架**（视频系列 / 媒体服务器作品 / 发现页与在线源作品
/// ——书、漫画、视频、小说——同一套视觉）。
///
/// 只吃纯值与回调，不知道数据来自 Drift 行、远端 DTO 还是扩展运行时：
/// - [MediaDetailBackdrop]：大背景（fanart / 封面模糊 + 色晕 scrim，渐隐到页面底色）；
/// - [MediaDetailHero]：背景 + 2:3 封面卡 + Display 级标题 + 原名 + 元信息 chip 行 +
///   主操作按钮组 + 页脚（简介 / 进度）；宽屏封面在左，窄屏上下堆叠居中；
/// - [MediaDetailActionBar] / [MediaDetailPrimaryButton] / [MediaDetailSecondaryButton] /
///   [MediaDetailMoreButton]：主操作按钮组（filled 大号 + tonal + 「⋯」菜单），进行中
///   时主按钮换波浪进度；
/// - [MediaDetailSynopsis]：可展开简介（spring 展开，超出行数才出「展开」）；
/// - [MediaDetailSectionHeader]：区块标题 + 计数胶囊 + 行尾动作；
/// - [MediaDetailItemRow]：章节 / 分集的分段列表行（序号胶囊、观看进度、已看对勾、
///   续看高亮、下载状态、多选）；
/// - [MediaDetailCastStrip]：人物横滑圆形头像卡；
/// - [MediaDetailLayout]：宽屏两栏（左 hero 信息独立滚动 = sticky，右正文），窄屏
///   单列；
/// - [MediaDetailSkeleton]：加载骨架。
///
/// Material 设计系统一律 M3 Expressive（饱和 container 色块、形状分级、spring 动效）；
/// Apple 设计系统走系统语义色与胶囊；墨水屏去掉背景图与色晕、改描边。动效时长全部
/// 取 `context.fushiMotion`（墨水屏 / 减弱动态效果自动归零）。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 宽度 ≥ 它时 [MediaDetailLayout] 切两栏。
const double kMediaDetailTwoPaneMinWidth = 1080;

/// 两栏布局左栏（hero 信息）宽度。
const double kMediaDetailSidePaneWidth = 400;

/// [MediaDetailHero] 宽度 ≥ 它时封面在左、信息在右。
const double kMediaDetailHeroWideMinWidth = 640;

// ---------------------------------------------------------------------------
// 背景
// ---------------------------------------------------------------------------

/// 详情页大背景：图模糊铺满 + 色晕 scrim，自上而下渐隐到页面底色（surface），
/// 让压在上面的文字直接用 onSurface 系颜色、明暗主题都可读。
///
/// [image] 变化（多张 fanart 轮换）时交叉淡入；[imageKey] 给轮换下标之类的
/// 稳定身份（缺省用 [image] 本身）。墨水屏不画图与色晕。
class MediaDetailBackdrop extends StatelessWidget {
  const MediaDetailBackdrop({
    this.image,
    this.imageKey,
    this.blurSigma = 28,
    super.key,
  });

  final ImageProvider? image;
  final Object? imageKey;

  /// 模糊强度。横版 fanart 可以轻一点（保留画面），竖版封面垫底要重一点。
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final ImageProvider? image = eink ? null : this.image;
    final Color base = cs.surface;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: base),
          if (image != null)
            AnimatedSwitcher(
              duration: motion.effectsSlow.duration,
              child: KeyedSubtree(
                key: ValueKey<Object>(imageKey ?? image),
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                    tileMode: TileMode.decal,
                  ),
                  child: Image(
                    image: image,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          if (!eink) ...<Widget>[
            // 色晕：起始侧上角一团 primaryContainer（Apple 用强调色淡染），
            // 让没有图 / 图很暗时 hero 也带主题色气质。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: AlignmentDirectional.topStart,
                  radius: 1.25,
                  colors: <Color>[
                    (apple ? cs.primary : cs.primaryContainer).withValues(
                      alpha: apple ? 0.22 : 0.55,
                    ),
                    (apple ? cs.primary : cs.primaryContainer).withValues(
                      alpha: 0,
                    ),
                  ],
                ),
              ),
            ),
            // 可读性 scrim：上半透出画面，底部完全落到页面底色，与下方内容无缝。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const <double>[0, 0.55, 1],
                  colors: <Color>[
                    base.withValues(alpha: image == null ? 0 : 0.30),
                    base.withValues(alpha: image == null ? 0.2 : 0.72),
                    base,
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 元信息 chip
// ---------------------------------------------------------------------------

/// hero 元信息 chip 的语气：neutral = 事实（年份 / 集数 / 时长），primary /
/// secondary / tertiary = 需要被看见的状态（评分、连载中、已在书架）。
enum MediaDetailChipTone { neutral, primary, secondary, tertiary, error }

/// 一枚元信息 chip（纯值）。
@immutable
class MediaDetailChip {
  const MediaDetailChip(
    this.label, {
    this.icon,
    this.tone = MediaDetailChipTone.neutral,
    this.key,
  });

  final String label;
  final IconData? icon;
  final MediaDetailChipTone tone;
  final Key? key;
}

/// 元信息 chip 行（年份 · 集数 · 时长 · 评分 / 作者 · 来源 · 状态）。
class MediaDetailChipRow extends StatelessWidget {
  const MediaDetailChipRow({
    required this.chips,
    this.alignment = WrapAlignment.start,
    super.key,
  });

  final List<MediaDetailChip> chips;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: alignment,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final MediaDetailChip chip in chips)
          MediaDetailChipView(key: chip.key, chip: chip),
      ],
    );
  }
}

/// 单枚元信息 chip：M3E 小件圆角 8 的饱和色块（neutral = surfaceContainerHighest），
/// Apple 系统填充色胶囊，墨水屏描边。
class MediaDetailChipView extends StatelessWidget {
  const MediaDetailChipView({required this.chip, super.key});

  final MediaDetailChip chip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final (Color fill, Color fg) = _colors(context, cs, apple, eink);
    final IconData? icon = chip.icon;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(apple ? 999 : 8),
        border: eink ? Border.all(color: cs.outline) : null,
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          icon == null ? 12 : 8,
          6,
          12,
          6,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              FushiIcon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                chip.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLargeEmphasized.tabular.copyWith(
                  color: fg,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (Color, Color) _colors(
    BuildContext context,
    ColorScheme cs,
    bool apple,
    bool eink,
  ) {
    if (eink) return (cs.surface, cs.onSurface);
    if (apple) {
      final FushiAppleColors palette = appleColorsOf(context);
      return switch (chip.tone) {
        MediaDetailChipTone.neutral => (palette.tertiaryFill, palette.label),
        MediaDetailChipTone.error => (
          cs.error.withValues(alpha: 0.16),
          cs.error,
        ),
        _ => (cs.primary.withValues(alpha: 0.16), cs.primary),
      };
    }
    return switch (chip.tone) {
      MediaDetailChipTone.neutral => (
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
      MediaDetailChipTone.primary => (
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      MediaDetailChipTone.secondary => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      MediaDetailChipTone.tertiary => (
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      MediaDetailChipTone.error => (cs.errorContainer, cs.onErrorContainer),
    };
  }
}

// ---------------------------------------------------------------------------
// hero
// ---------------------------------------------------------------------------

/// 2:3 封面卡：M3E 卡档圆角 20 + level2 投影（Apple 12 圆角、柔投影；墨水屏描边）。
class MediaDetailCoverFrame extends StatelessWidget {
  const MediaDetailCoverFrame({
    required this.child,
    required this.width,
    this.aspectRatio = 2 / 3,
    super.key,
  });

  final Widget child;
  final double width;

  /// 宽 / 高；视频横版缩略图可传 16 / 9。
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? const BorderRadius.all(Radius.circular(12))
        : FushiM3eShape.cardRadius;
    return SizedBox(
      width: width,
      height: width / aspectRatio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: cs.surfaceContainerHighest,
          border: eink ? Border.all(color: cs.outline) : null,
          boxShadow: eink
              ? null
              : <BoxShadow>[
                  BoxShadow(
                    color: cs.shadow.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// 封面缺失时的占位：secondaryContainer 色块 + 域图标。
class MediaDetailCoverPlaceholder extends StatelessWidget {
  const MediaDetailCoverPlaceholder({this.icon = FushiIcons.image, super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.secondaryContainer,
      child: Center(
        child: FushiIcon(icon, size: 40, color: cs.onSecondaryContainer),
      ),
    );
  }
}

/// 作品详情 hero（M3E）：[MediaDetailBackdrop] 大背景 + 封面卡 + 标题区 + 主操作 +
/// 页脚。高度随内容（不再钳死），长标题 / 长简介不会撑爆。
///
/// - 宽（≥ [kMediaDetailHeroWideMinWidth]）：封面在起始侧、信息靠底对齐；
/// - 窄：封面居中在上，信息居中；
/// - 在 [MediaDetailLayout] 的两栏左栏里：恒为窄式堆叠，且不画自己的背景（整页背景
///   由布局画在两栏后面）。
///
/// 进场：封面 / 标题区 / 操作区三段错峰（[FushiStaggeredEntrance]）。
class MediaDetailHero extends StatelessWidget {
  const MediaDetailHero({
    required this.title,
    super.key,
    this.cover,
    this.coverAspectRatio = 2 / 3,
    this.backdrop,
    this.backdropKey,
    this.backdropBlur = 28,
    this.titleWidget,
    this.overline,
    this.originalTitle,
    this.chips = const <MediaDetailChip>[],
    this.actions,
    this.footer,
    this.titleKey,
  });

  final String title;

  /// 封面内容（各域自己的取图组件）；null = 不放封面卡。
  final Widget? cover;
  final double coverAspectRatio;

  /// 背景图（fanart 优先，没有就传封面——模糊后垫底）。
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final double backdropBlur;

  /// 替代文字标题的组件（如标题 logo）；null = Display 级文字标题。
  final Widget? titleWidget;

  /// 标题上方的小字（放送日期 / 来源名）。
  final String? overline;

  /// 原名；与 [title] 相同或为空时不占行。
  final String? originalTitle;

  final List<MediaDetailChip> chips;

  /// 主操作区（通常是 [MediaDetailActionBar]）。
  final Widget? actions;

  /// 操作区下方（简介 / 进度 / 标签）。
  final Widget? footer;

  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    final bool inSidePane = MediaDetailLayout.isSidePane(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            !inSidePane &&
            constraints.maxWidth * FushiAppUiScale.of(context) >=
                kMediaDetailHeroWideMinWidth;
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final double page = tokens.spacing.page;
        final Widget content = Padding(
          padding: EdgeInsets.fromLTRB(
            page,
            MediaDetailLayout.heroTopInset(context) +
                (wide ? tokens.spacing.section * 1.5 : tokens.spacing.section),
            page,
            tokens.spacing.section,
          ),
          child: wide ? _buildWide(context) : _buildNarrow(context),
        );
        if (inSidePane) return content;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: MediaDetailBackdrop(
                image: backdrop,
                imageKey: backdropKey,
                blurSigma: backdropBlur,
              ),
            ),
            content,
          ],
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final Widget? cover = this.cover;
    final Widget info = _buildInfo(context, centered: false, wide: true);
    if (cover == null) return info;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 0,
          child: MediaDetailCoverFrame(
            key: const ValueKey<String>('media-detail-cover'),
            width: coverAspectRatio < 1 ? 208 : 320,
            aspectRatio: coverAspectRatio,
            child: cover,
          ),
        ),
        const SizedBox(width: 28),
        Expanded(child: info),
      ],
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final Widget? cover = this.cover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (cover != null) ...<Widget>[
          Center(
            child: FushiStaggeredEntrance(
              index: 0,
              child: MediaDetailCoverFrame(
                key: const ValueKey<String>('media-detail-cover'),
                width: coverAspectRatio < 1 ? 168 : 280,
                aspectRatio: coverAspectRatio,
                child: cover,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        _buildInfo(context, centered: true, wide: false),
      ],
    );
  }

  Widget _buildInfo(
    BuildContext context, {
    required bool centered,
    required bool wide,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String? overline = this.overline?.trim();
    final String? originalTitle = this.originalTitle?.trim();
    final TextAlign align = centered ? TextAlign.center : TextAlign.start;
    final CrossAxisAlignment cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final Widget titleText = Text(
      title,
      key: titleKey,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style:
          (wide ? type.displaySmallEmphasized : type.headlineMediumEmphasized)
              .copyWith(color: cs.onSurface, height: 1.1),
    );
    return Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 1,
          child: Column(
            crossAxisAlignment: cross,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (overline != null && overline.isNotEmpty) ...<Widget>[
                Text(
                  overline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: type.labelLargeEmphasized.copyWith(color: cs.primary),
                ),
                const SizedBox(height: 6),
              ],
              titleWidget ?? titleText,
              if (originalTitle != null &&
                  originalTitle.isNotEmpty &&
                  originalTitle != title) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  originalTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: type.titleMedium.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (chips.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                MediaDetailChipRow(
                  chips: chips,
                  alignment: centered
                      ? WrapAlignment.center
                      : WrapAlignment.start,
                ),
              ],
            ],
          ),
        ),
        if (actions != null) ...<Widget>[
          const SizedBox(height: 20),
          FushiStaggeredEntrance(
            index: 2,
            child: _MediaDetailHeroAlignScope(
              centered: centered,
              child: actions!,
            ),
          ),
        ],
        if (footer != null) ...<Widget>[
          const SizedBox(height: 20),
          FushiStaggeredEntrance(
            index: 3,
            child: Align(
              alignment: centered
                  ? Alignment.topCenter
                  : AlignmentDirectional.topStart,
              child: footer,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 主操作按钮组
// ---------------------------------------------------------------------------

/// 主操作按钮组：主按钮（filled 大号）+ 次按钮（tonal）+ 「⋯」。窄屏换行；
/// [alignment] 让窄式 hero 居中。
class MediaDetailActionBar extends StatelessWidget {
  const MediaDetailActionBar({
    required this.primary,
    this.secondary = const <Widget>[],
    this.more,
    this.alignment,
    super.key,
  });

  final Widget primary;
  final List<Widget> secondary;
  final Widget? more;

  /// null = 跟随所在 hero（窄式居中、宽式起始侧；不在 hero 里时起始侧）。
  final WrapAlignment? alignment;

  @override
  Widget build(BuildContext context) {
    final WrapAlignment resolved =
        alignment ??
        (_MediaDetailHeroAlignScope.centeredOf(context)
            ? WrapAlignment.center
            : WrapAlignment.start);
    return Wrap(
      key: const ValueKey<String>('media-detail-actions'),
      alignment: resolved,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[primary, ...secondary, ?more],
    );
  }
}

/// hero 信息区的对齐（窄式居中 / 宽式起始侧），让操作区跟着对齐。
class _MediaDetailHeroAlignScope extends InheritedWidget {
  const _MediaDetailHeroAlignScope({
    required this.centered,
    required super.child,
  });

  final bool centered;

  static bool centeredOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaDetailHeroAlignScope>()
          ?.centered ??
      false;

  @override
  bool updateShouldNotify(_MediaDetailHeroAlignScope oldWidget) =>
      centered != oldWidget.centered;
}

/// 主按钮（「继续观看」「开始阅读」「在线阅读」）：M3E filled M 档（56 高）+
/// 按压回弹；[busy] 时图标位换成转圈、按钮禁用；[progress] 非 null 时按钮下方挂
/// 一条波浪进度（下载 / 准备中）。
class MediaDetailPrimaryButton extends StatelessWidget {
  const MediaDetailPrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.buttonKey,
    this.busy = false,
    this.progress,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 落在内部按钮本体上的 key（测试按 key 取 FilledButton / 点按）。
  final Key? buttonKey;
  final bool busy;

  /// 0..1 确定进度；-1 = 不确定进度；null = 不挂进度条。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final Widget button = FushiPressScale(
      scale: 0.96,
      child: FushiFilledButton.icon(
        key: buttonKey,
        onPressed: busy ? null : onPressed,
        size: FushiButtonSize.m,
        icon: busy
            ? const SizedBox.square(
                dimension: 20,
                child: FushiCircularProgressIndicator(strokeWidth: 2.5),
              )
            : FushiIcon(icon),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final double? progress = this.progress;
    if (progress == null) return button;
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          button,
          const SizedBox(height: 8),
          FushiLinearProgressIndicator(value: progress < 0 ? null : progress),
        ],
      ),
    );
  }
}

/// 次按钮（加入书架 / 下载 / 收藏 / 标记已看）：M3E tonal M 档；[selected] 时
/// 图标换实心（「已在书架」）。[iconOnly] = 方形图标按钮 + tooltip。
class MediaDetailSecondaryButton extends StatelessWidget {
  const MediaDetailSecondaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.buttonKey,
    this.selected = false,
    this.iconOnly = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;
  final bool selected;
  final bool iconOnly;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = busy
        ? const SizedBox.square(
            dimension: 18,
            child: FushiCircularProgressIndicator(strokeWidth: 2.5),
          )
        : FushiIcon(FushiIcons.resolve(icon, filled: selected));
    if (iconOnly) {
      return FushiIconButtonControl.filledTonal(
        key: buttonKey,
        tooltip: label,
        size: FushiIconButtonSize.m,
        isSelected: selected,
        onPressed: busy ? null : onPressed,
        icon: glyph,
      );
    }
    return FushiPressScale(
      scale: 0.96,
      child: FushiFilledButton.tonalIcon(
        key: buttonKey,
        onPressed: busy ? null : onPressed,
        size: FushiButtonSize.m,
        icon: glyph,
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// 「⋯」菜单里的一项。
@immutable
class MediaDetailMenuItem {
  const MediaDetailMenuItem({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool enabled;
  final Key? key;
}

/// 「⋯」更多操作：tonal 图标按钮，点开锚定菜单（在网站打开 / 刷新 / 换源…）。
class MediaDetailMoreButton extends StatelessWidget {
  const MediaDetailMoreButton({
    required this.items,
    super.key,
    this.buttonKey,
    this.tooltip,
  });

  final List<MediaDetailMenuItem> items;
  final Key? buttonKey;
  final String? tooltip;

  Future<void> _open(BuildContext context) async {
    final RenderObject? box = context.findRenderObject();
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final Rect anchor = Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final int? index = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            key: items[i].key,
            value: i,
            enabled: items[i].enabled,
            child: Row(
              children: <Widget>[
                FushiIcon(items[i].icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(items[i].label)),
              ],
            ),
          ),
      ],
    );
    if (index == null || index < 0 || index >= items.length) return;
    items[index].onSelected();
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Builder(
      builder: (BuildContext context) => FushiIconButtonControl.filledTonal(
        key: buttonKey,
        tooltip: tooltip ?? t.common_more_actions,
        size: FushiIconButtonSize.m,
        onPressed: () => unawaited(_open(context)),
        icon: const FushiIcon(FushiIcons.moreHoriz),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 简介
// ---------------------------------------------------------------------------

/// 可展开简介：收起时 [collapsedLines] 行，超出才出「展开 / 收起」；展开用
/// spring（[AnimatedSize]）。点正文本身也能切换（[selectable] 时只能点按钮，
/// 正文要留给选词）。
class MediaDetailSynopsis extends StatefulWidget {
  const MediaDetailSynopsis({
    required this.text,
    super.key,
    this.collapsedLines = 4,
    this.selectable = false,
    this.textAlign = TextAlign.start,
    this.initiallyExpanded = false,
  });

  final String text;
  final int collapsedLines;
  final bool selectable;
  final TextAlign textAlign;
  final bool initiallyExpanded;

  @override
  State<MediaDetailSynopsis> createState() => _MediaDetailSynopsisState();
}

class _MediaDetailSynopsisState extends State<MediaDetailSynopsis> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final String text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final TextStyle style = context.fushiType.bodyLarge.copyWith(
      color: cs.onSurfaceVariant,
      height: 1.55,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool overflows = painter.didExceedMaxLines;
        painter.dispose();
        final int? maxLines = overflows && !_expanded
            ? widget.collapsedLines
            : null;
        final Widget body = widget.selectable
            ? SelectableText(
                text,
                key: const ValueKey<String>('media-detail-synopsis-text'),
                maxLines: maxLines,
                textAlign: widget.textAlign,
                style: style,
              )
            : Text(
                text,
                key: const ValueKey<String>('media-detail-synopsis-text'),
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
                textAlign: widget.textAlign,
                style: style,
              );
        return Column(
          crossAxisAlignment: widget.textAlign == TextAlign.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: overflows && !widget.selectable
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggle,
                      child: body,
                    )
                  : body,
            ),
            if (overflows)
              FushiTextButton.icon(
                key: const ValueKey<String>('media-detail-synopsis-toggle'),
                onPressed: _toggle,
                icon: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: motion.spatialFast.duration,
                  curve: motion.spatialFast.curve,
                  child: const FushiIcon(FushiIcons.expandMore),
                ),
                label: Text(
                  _expanded ? t.collection_collapse : t.collection_expand,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 区块标题
// ---------------------------------------------------------------------------

/// 区块标题（「选集」「章节」「演职人员」）：titleLarge Emphasized + 计数胶囊 +
/// 行尾动作（排序 / 多选 / 全部下载）。
class MediaDetailSectionHeader extends StatelessWidget {
  const MediaDetailSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(0, 24, 0, 8),
  });

  final String title;
  final int? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final int? count = this.count;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.titleLargeEmphasized,
            ),
          ),
          if (count != null) ...<Widget>[
            const SizedBox(width: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: apple
                    ? appleColorsOf(context).tertiaryFill
                    : cs.secondaryContainer,
                borderRadius: const BorderRadius.all(Radius.circular(999)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Text(
                  '$count',
                  style: context.fushiType.labelLargeEmphasized.tabular
                      .copyWith(color: apple ? null : cs.onSecondaryContainer),
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 章节 / 分集行
// ---------------------------------------------------------------------------

/// 条目（章节 / 分集）的下载状态。
enum MediaDetailDownloadState { none, queued, downloading, downloaded, failed }

/// 章节 / 分集的分段列表行（M3E segmented list，组首尾大圆角、行间 2px 缝）：
///
/// - 行首：[leading]（缩略图）或 [number] 序号胶囊（续看那条用 primary 实色）；
/// - 标题 + 副标题 + 元信息（播出日 · 时长）；已看完的标题降为 onSurfaceVariant；
/// - 观看进度（[progress]）：底部 primary 细条（M3E 波浪）；
/// - 状态：已看 = tertiary 实心对勾；下载 = 排队 / 转圈 / 已下载 / 失败图标；
/// - [current]：续看的那条整行 primaryContainer 高亮；
/// - [selected] 非 null = 多选模式（行首对勾圆，点行切换选择）。
class MediaDetailItemRow extends StatelessWidget {
  const MediaDetailItemRow({
    required this.title,
    required this.index,
    required this.count,
    super.key,
    this.leading,
    this.number,
    this.subtitle,
    this.meta = const <String>[],
    this.progress,
    this.completed = false,
    this.current = false,
    this.downloadState = MediaDetailDownloadState.none,
    this.downloadProgress,
    this.trailing,
    this.selected,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusId,
    this.margin = EdgeInsets.zero,
    this.titleMaxLines = 2,
  });

  final String title;

  /// 组内位置与总数（决定分段圆角）。
  final int index;
  final int count;
  final Widget? leading;
  final String? number;
  final String? subtitle;
  final List<String> meta;
  final double? progress;
  final bool completed;
  final bool current;
  final MediaDetailDownloadState downloadState;
  final double? downloadProgress;
  final Widget? trailing;
  final bool? selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final FushiFocusId? focusId;
  final EdgeInsetsGeometry margin;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiTypography type = context.fushiType;
    final bool highlight = current && !eink;
    final Color fg = highlight && !apple ? cs.onPrimaryContainer : cs.onSurface;
    final Color fgVariant = highlight && !apple
        ? cs.onPrimaryContainer.withValues(alpha: 0.78)
        : cs.onSurfaceVariant;
    final String? subtitle = this.subtitle?.trim();
    final List<String> meta = <String>[
      for (final String part in this.meta)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final double? progress = this.progress;
    final bool? selected = this.selected;
    final Widget? leadingSlot = selected != null
        ? _SelectionMark(selected: selected)
        : leading ??
              (number == null
                  ? null
                  : _NumberPill(number: number!, current: current));
    final Widget? status = _buildStatus(context, cs);
    return FushiGroupedListItem(
      index: index,
      count: count,
      margin: margin,
      color: highlight
          ? (apple ? cs.primary.withValues(alpha: 0.14) : cs.primaryContainer)
          : null,
      selected: selected ?? false,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      focusId: focusId,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
        child: Row(
          children: <Widget>[
            if (leadingSlot != null) ...<Widget>[
              leadingSlot,
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (current
                                ? type.titleMediumEmphasized
                                : type.titleMedium)
                            .copyWith(
                              color: completed && !current ? fgVariant : fg,
                            ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: fgVariant),
                    ),
                  ],
                  if (meta.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      meta.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.labelMedium.tabular.copyWith(
                        color: fgVariant,
                      ),
                    ),
                  ],
                  if (progress != null && progress > 0 && !completed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: FushiLinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: cs.primary,
                      ),
                    ),
                ],
              ),
            ),
            if (status != null) ...<Widget>[const SizedBox(width: 8), status],
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 4),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }

  Widget? _buildStatus(BuildContext context, ColorScheme cs) {
    final List<Widget> icons = <Widget>[
      if (completed)
        FushiIcon(
          FushiIcons.filled(FushiIcons.success),
          key: const ValueKey<String>('media-detail-item-completed'),
          size: 20,
          color: isGlassDesign(context) ? cs.primary : cs.tertiary,
        ),
      ...switch (downloadState) {
        MediaDetailDownloadState.none => const <Widget>[],
        MediaDetailDownloadState.queued => <Widget>[
          FushiIcon(FushiIcons.pending, size: 20, color: cs.onSurfaceVariant),
        ],
        MediaDetailDownloadState.downloading => <Widget>[
          SizedBox.square(
            dimension: 20,
            child: FushiCircularProgressIndicator(
              value: downloadProgress,
              strokeWidth: 2.5,
            ),
          ),
        ],
        MediaDetailDownloadState.downloaded => <Widget>[
          FushiIcon(
            FushiIcons.filled(FushiIcons.downloadDone),
            size: 20,
            color: cs.primary,
          ),
        ],
        MediaDetailDownloadState.failed => <Widget>[
          FushiIcon(FushiIcons.error, size: 20, color: cs.error),
        ],
      },
    ];
    if (icons.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < icons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          icons[i],
        ],
      ],
    );
  }
}

/// 序号胶囊：常态 secondaryContainer，续看那条 primary 实色。
class _NumberPill extends StatelessWidget {
  const _NumberPill({required this.number, required this.current});

  final String number;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color fill = current
        ? cs.primary
        : (apple ? appleColorsOf(context).tertiaryFill : cs.secondaryContainer);
    final Color fg = current
        ? cs.onPrimary
        : (apple ? cs.onSurface : cs.onSecondaryContainer);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: const BorderRadius.all(Radius.circular(999)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            number,
            textAlign: TextAlign.center,
            style: context.fushiType.labelLargeEmphasized.tabular.copyWith(
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选模式的行首选择标记（spring 缩放切换实心对勾）。
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSwitcher(
      duration: motion.spatialFast.duration,
      switchInCurve: motion.spatialFast.curve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          ScaleTransition(scale: animation, child: child),
      child: FushiIcon(
        selected ? FushiIcons.filled(FushiIcons.success) : FushiIcons.addCircle,
        key: ValueKey<bool>(selected),
        size: 24,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 人物表
// ---------------------------------------------------------------------------

/// 人物表里的一个人（纯值）。
@immutable
class MediaDetailPerson {
  const MediaDetailPerson({
    required this.name,
    this.role,
    this.image,
    this.key,
    this.onImageError,
  });

  final String name;

  /// 角色名 / 职位。
  final String? role;
  final ImageProvider? image;
  final Key? key;

  /// 头像解码失败（诊断日志用）。
  final void Function(Object error)? onImageError;
}

/// 人物表横滑：圆形头像卡（照片 + 姓名 + 角色），错峰进场。
class MediaDetailCastStrip extends StatelessWidget {
  const MediaDetailCastStrip({
    required this.people,
    super.key,
    this.title,
    this.padding = EdgeInsets.zero,
    this.avatarSize = 76,
  });

  final List<MediaDetailPerson> people;
  final String? title;

  /// 标题与横滑轨道的左右页边距。
  final EdgeInsets padding;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final String? title = this.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null)
          MediaDetailSectionHeader(
            title,
            count: people.length,
            padding: EdgeInsets.fromLTRB(padding.left, 24, padding.right, 12),
          ),
        SizedBox(
          height: avatarSize + 62,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                    index: index,
                    child: _CastAvatar(
                      key: people[index].key,
                      person: people[index],
                      size: avatarSize,
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastAvatar extends StatelessWidget {
  const _CastAvatar({required this.person, required this.size, super.key});

  final MediaDetailPerson person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiTypography type = context.fushiType;
    final ImageProvider? image = person.image;
    final Widget placeholder = ColoredBox(
      color: cs.secondaryContainer,
      child: Center(
        child: FushiIcon(
          FushiIcons.person,
          size: size * 0.42,
          color: cs.onSecondaryContainer,
        ),
      ),
    );
    final String? role = person.role?.trim();
    return SizedBox(
      width: size + 28,
      child: Column(
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: eink ? cs.outline : cs.surfaceContainerHighest,
                width: 3,
              ),
            ),
            child: ClipOval(
              child: SizedBox.square(
                dimension: size,
                child: image == null
                    ? placeholder
                    : Image(
                        image: image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, Object error, _) {
                          person.onImageError?.call(error);
                          return placeholder;
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: type.labelLargeEmphasized,
          ),
          if (role != null && role.isNotEmpty)
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------

/// 详情页整体布局：宽屏（≥ [twoPaneMinWidth]）两栏——左栏 [header]（hero 信息，
/// 独立滚动，相当于 sticky）、右栏 [slivers]（分集 / 章节 / 人物…）；整页背景
/// 画在两栏之后。窄屏单列：[header] 在顶、[slivers] 跟随。
///
/// [header] 里的 [MediaDetailHero] 在左栏时自动改成窄式堆叠、不重复画背景。
class MediaDetailLayout extends StatelessWidget {
  const MediaDetailLayout({
    required this.header,
    required this.slivers,
    super.key,
    this.backdrop,
    this.backdropKey,
    this.backdropBlur = 28,
    this.twoPaneMinWidth = kMediaDetailTwoPaneMinWidth,
    this.sidePaneWidth = kMediaDetailSidePaneWidth,
    this.controller,
    this.bottomPadding = 24,
  });

  final Widget header;
  final List<Widget> slivers;

  /// 两栏时整页背景（与 hero 的背景同一张）。
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final double backdropBlur;
  final double twoPaneMinWidth;
  final double sidePaneWidth;

  /// 正文（单列时整页 / 两栏时右栏）的滚动控制器。
  final ScrollController? controller;
  final double bottomPadding;

  /// [context] 是否在两栏布局的左栏里。
  static bool isSidePane(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MediaDetailSidePaneScope>() !=
      null;

  /// 当前是否两栏（供页面决定右栏的列数等）。
  static bool isTwoPane(BuildContext context, double maxWidth) =>
      maxWidth * FushiAppUiScale.of(context) >= kMediaDetailTwoPaneMinWidth;

  /// 顶栏（浮动胶囊，[Scaffold.extendBodyBehindAppBar]）+ 状态栏占掉的高度：
  /// 背景铺满到窗口顶端，hero 内容从这条线下开始排。由布局按
  /// `MediaQuery.paddingOf(context).top` 下发，不在两栏左栏 / 单列 hero 之外生效。
  static double heroTopInset(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaDetailTopInsetScope>()
          ?.top ??
      0;

  @override
  Widget build(BuildContext context) {
    // 页面以 extendBodyBehindAppBar 挂在浮动顶栏之下时，Scaffold 把顶栏高度折进
    // MediaQuery 顶部 padding。背景必须从窗口顶端画起（顶栏只是几颗悬浮胶囊，
    // 不画任何整宽底带），内容自己让开这段——所以这里读出来、往下自己用，并从
    // 子树里摘掉，免得滚动视图 / hero 再让一次。
    final double topInset = MediaQuery.paddingOf(context).top;
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool twoPane =
              constraints.maxWidth * FushiAppUiScale.of(context) >=
              twoPaneMinWidth;
          final Widget bottom = SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
          );
          // 顶部柔和 scrim：内容滚到浮动顶栏之下时渐隐，无硬边（不是实色底带）。
          final Widget topScrim = Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _MediaDetailTopScrim(height: topInset),
          );
          if (!twoPane) {
            return Stack(
              children: <Widget>[
                CustomScrollView(
                  controller: controller,
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _MediaDetailTopInsetScope(
                        top: topInset,
                        child: header,
                      ),
                    ),
                    ...slivers,
                    bottom,
                  ],
                ),
                if (topInset > 0) topScrim,
              ],
            );
          }
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: MediaDetailBackdrop(
                  image: backdrop,
                  imageKey: backdropKey,
                  blurSigma: backdropBlur,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: sidePaneWidth,
                    child: _MediaDetailSidePaneScope(
                      child: SingleChildScrollView(
                        key: const ValueKey<String>('media-detail-side-pane'),
                        // 左栏不接 PrimaryScrollController：右栏是主滚动视图，两个
                        // 都挂上会撞「controller attached to multiple scroll views」。
                        primary: false,
                        padding: EdgeInsets.only(
                          top: topInset,
                          bottom:
                              bottomPadding +
                              MediaQuery.paddingOf(context).bottom,
                        ),
                        child: header,
                      ),
                    ),
                  ),
                  Expanded(
                    child: CustomScrollView(
                      key: const ValueKey<String>('media-detail-main-pane'),
                      controller: controller,
                      slivers: <Widget>[
                        SliverToBoxAdapter(
                          child: SizedBox(height: topInset + 8),
                        ),
                        ...slivers,
                        bottom,
                      ],
                    ),
                  ),
                ],
              ),
              if (topInset > 0) topScrim,
            ],
          );
        },
      ),
    );
  }
}

/// 布局下发给单列 hero 的顶部让位高度（见 [MediaDetailLayout.heroTopInset]）。
class _MediaDetailTopInsetScope extends InheritedWidget {
  const _MediaDetailTopInsetScope({required this.top, required super.child});

  final double top;

  @override
  bool updateShouldNotify(_MediaDetailTopInsetScope oldWidget) =>
      top != oldWidget.top;
}

/// 浮动顶栏背后的柔和渐隐：页面底色自顶 55% 渐到全透明，长度 = 顶栏让位 + 24。
/// 不接指针、不参与语义；墨水屏不画（底色本来就是实色，渐变在墨水屏上是脏点）。
class _MediaDetailTopScrim extends StatelessWidget {
  const _MediaDetailTopScrim({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (height <= 0 || isEinkTheme(context)) return const SizedBox.shrink();
    final Color base = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height + 24,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  base.withValues(alpha: 0.55),
                  base.withValues(alpha: 0.28),
                  base.withValues(alpha: 0),
                ],
                stops: const <double>[0, 0.6, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaDetailSidePaneScope extends InheritedWidget {
  const _MediaDetailSidePaneScope({required super.child});

  @override
  bool updateShouldNotify(_MediaDetailSidePaneScope oldWidget) => false;
}

// ---------------------------------------------------------------------------
// 加载骨架
// ---------------------------------------------------------------------------

/// 详情页加载骨架：hero（封面块 + 标题条 + chip 条 + 按钮条）+ [rows] 行条目。
class MediaDetailSkeleton extends StatelessWidget {
  const MediaDetailSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    return FushiSkeletonShimmer(
      child: ListView(
        key: const ValueKey<String>('media-detail-skeleton'),
        physics: const NeverScrollableScrollPhysics(),
        // 页面以 extendBodyBehindAppBar 挂在浮动顶栏下时，让开顶栏。
        padding: EdgeInsets.fromLTRB(
          page,
          tokens.spacing.section + MediaQuery.paddingOf(context).top,
          page,
          page,
        ),
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              FushiSkeleton(
                width: 132,
                height: 198,
                borderRadius: FushiM3eShape.cardRadius,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiSkeleton.line(widthFactor: 0.8, height: 28),
                    const SizedBox(height: 12),
                    FushiSkeleton.line(widthFactor: 0.5, height: 16),
                    const SizedBox(height: 16),
                    FushiSkeleton.line(widthFactor: 0.65, height: 28),
                    const SizedBox(height: 20),
                    FushiSkeleton.line(widthFactor: 0.4, height: 48),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          FushiSkeleton.line(height: 14),
          const SizedBox(height: 8),
          FushiSkeleton.line(widthFactor: 0.9, height: 14),
          const SizedBox(height: 8),
          FushiSkeleton.line(widthFactor: 0.7, height: 14),
          const SizedBox(height: 28),
          for (int i = 0; i < rows; i++) ...<Widget>[
            FushiSkeleton(
              height: 64,
              borderRadius: fushiGroupedItemRadius(context, i, rows),
            ),
            const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }
}
