import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/cover_image.dart';
import 'package:transparent_image/transparent_image.dart';

/// 书架卡片 footer / 勾选圈 / 选中罩的共享实现。
///
/// 巡检（PR-3）发现 `series_shelf_card.dart` 与
/// `reader_history/card_widgets.part.dart` 各持一份逐行相同的 footer 与勾选圈
/// 手抄（两处 40px 标题 footer、三处圆形对勾、两处选中罩），本文件收口为共享
/// 组件；eink 主题的实心色替代（半透明 alpha 在墨水屏合成抖动灰）也只写在这里。

/// 书架卡片封面下方的固定高标题 footer（两行省略、居中、加粗 metadata 字号）。
///
/// 高度由调用方的 SizedBox 固定（书卡用 `kShelfTitleFooterHeight`，系列折叠卡
/// 用 [ShelfCardFooter.height]，二者同值），长书名换行不得撑动网格。
class ShelfCardFooter extends StatelessWidget {
  const ShelfCardFooter({required this.title, super.key});

  /// 与 `kShelfTitleFooterHeight` 同值的 footer 基准高（系列卡无法 import
  /// part-of 常量，挂在组件上共享）。这是**默认字号下的**高度，实际高度请用
  /// [heightFor]。
  static const double height = 40.0;

  /// 按当前文字缩放算出的 footer 高度，下限为基准的 [height]。
  ///
  /// BUG-1184：footer 高度原先是死的 40px，而里面要放两行 metadata 字号的书名。
  /// 默认字号下两行约 31px + 上内边距 4px 勉强塞得下；系统字号一放大（textScale
  /// ≥1.25，小屏用户很常见的设置）两行就要 43px 以上，第二行的下半截被 SizedBox
  /// 直接切掉——书名看起来像被咬了一口。卡片封面区是 [Expanded]，footer 变高只是
  /// 等量压缩封面、不会撑破网格，所以这里让高度跟着文字缩放走。
  static double heightFor(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double lineHeight = textLineHeight(context, tokens.type.metadata);
    final double topPad = tokens.spacing.gap / 2;
    return math.max(height, topPad + lineHeight * 2 + kTextBlockSlack);
  }

  final String title;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle style = tokens.type.metadata.copyWith(
      color: tokens.surfaces.onSurface,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.gap * 0.75,
        tokens.spacing.gap / 2,
        tokens.spacing.gap * 0.75,
        0,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        // TODO-2490：两行仍放不下的长书名，桌面悬停显示完整标题；触屏侧的全名
        // 兜底是长按菜单（MediaItemDialogFrame 标题已不限行）。
        child: ShelfTitleOverflowTooltip(
          title: title,
          style: style,
          maxLines: 2,
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            softWrap: true,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// 多选态的圆形对勾（书卡封面左上角 / 合集行头 / 系列折叠卡共用）。
///
/// 点击穿透由内建 [IgnorePointer] 保证（勾选切换走卡片/行头自身的 onTap）。
/// eink：未选中底色不再用 `page.withValues(alpha: 0.7)`（半透明在墨水屏合成
/// 抖动中间灰），改实心页面色 + 描边。
class ShelfSelectionCheck extends StatelessWidget {
  const ShelfSelectionCheck({required this.selected, super.key});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    final bool eink = isEinkTheme(context);
    final Color idleFill = eink
        ? tokens.surfaces.page
        : tokens.surfaces.page.withValues(alpha: 0.7);
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected ? selectionColor : idleFill,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? selectionColor : tokens.surfaces.outline,
            width: 1.5,
          ),
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: Icon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected ? theme.colorScheme.onPrimary : Colors.transparent,
        ),
      ),
    );
  }
}

/// 选中态整卡覆盖罩（书卡 / 系列折叠卡共用），配 `Positioned.fill` 使用。
///
/// 常规主题为 primary 12% 半透明罩；eink 半透明罩合成抖动灰且 primary 已塌缩，
/// 改 2px 实心描边作唯一选中信号（与 HibikiCard eink 选中态同语义）。
class ShelfSelectedOverlay extends StatelessWidget {
  const ShelfSelectedOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: eink
            ? BoxDecoration(
                border: Border.all(color: tokens.surfaces.outline, width: 2),
                borderRadius: tokens.radii.cardRadius,
              )
            : BoxDecoration(
                color: tokens.surfaces.primary.withValues(alpha: 0.12),
                borderRadius: tokens.radii.cardRadius,
              ),
      ),
    );
  }
}

/// 无封面占位（书架 / 视频库 / 游戏库共用）。
///
/// 巡检 B11：深色主题下无封面占位（卡面色 ≈ 页面背景）与背景零对比，占位卡读作
/// 一块空洞——统一补 1px 描边（tokens.surfaces.outline，全主题恒有；eink 的卡级
/// 描边另由 HibikiCard 兜，叠加无害）。[backgroundColor] 供视频/游戏库保留各自的
/// 高阶容器底色，书架传 null 维持无底色原样。
class ShelfCoverPlaceholder extends StatelessWidget {
  const ShelfCoverPlaceholder({
    required this.icon,
    this.iconSize = 40,
    this.backgroundColor,
    super.key,
  });

  final IconData icon;
  final double iconSize;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    // 全走 tokens（tokens.surfaces.outline 即 scheme 的 outlineVariant、onVariant
    // 即 onSurfaceVariant）：本文件被 MD3 静态守卫盯着，不许直读 scheme 的描边角色。
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: tokens.surfaces.outline),
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Center(
        child: Icon(
          icon,
          size: iconSize,
          color: tokens.surfaces.onVariant,
        ),
      ),
    );
  }
}

/// 本地文件封面的统一加载（书架 / 视频库 / 游戏库共用）。
///
/// BUG-959：一律经 [resizedFileImage] 降采样解码，避免原始封面（EPUB 常
/// 1600×2400、游戏包装图更大）整帧解码撑爆 ImageCache；FadeInImage 提供淡入与
/// 解码失败回退 [placeholder]。文件是否存在由调用方判定（各页对缺失文件的
/// 短路语义不同，不在此处吞）。
class ShelfFileCover extends StatelessWidget {
  const ShelfFileCover({
    required this.path,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    super.key,
  });

  final String path;
  final Widget placeholder;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return FadeInImage(
      imageErrorBuilder: (_, __, ___) => placeholder,
      placeholder: MemoryImage(kTransparentImage),
      image: resizedFileImage(File(path)),
      alignment: alignment,
      fit: fit,
    );
  }
}

/// 卡片标题溢出提示（TODO-2490）：三库页卡片标题统一「最多两行 + 省略号」
/// （BUG-1184），但两行仍放不下的长名此前没有任何看全名的途径。本组件用与
/// 内部 [Text] 相同的 [style] / [maxLines] 先测量
/// （[TextPainter.didExceedMaxLines]，与 `hibiki_marquee.dart` 的溢出探测同
/// 范式），**仅溢出时**才包 [Tooltip]：
///
/// - 桌面：鼠标悬停气泡显示完整标题；
/// - 触屏：不新造交互——`triggerMode: manual` 不注册点按/长按识别器，不与
///   卡片自身的长按菜单抢手势竞技场；长按菜单（`MediaItemDialogFrame`）标题
///   不限行，是触屏侧的看全名路径；
/// - 读屏：[Text] 语义本就携带完整字符串，`excludeFromSemantics` 避免重复播报。
class ShelfTitleOverflowTooltip extends StatelessWidget {
  const ShelfTitleOverflowTooltip({
    required this.title,
    required this.style,
    required this.maxLines,
    required this.child,
    super.key,
  });

  /// 完整标题（Tooltip 消息），与 [child] 里 Text 的 data 同源。
  final String title;

  /// 与 [child] 里 Text 相同的样式——测量必须同参，否则溢出判定失真。
  final TextStyle? style;

  /// 与 [child] 里 Text 相同的行数上限。
  final int maxLines;

  /// 实际渲染的标题 [Text]（省略号截断的那份）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth) return child;
        // 与 [Text] 相同的样式合成路径（inherit 时并入 DefaultTextStyle）。
        final TextStyle effective =
            DefaultTextStyle.of(context).style.merge(style);
        final TextPainter painter = TextPainter(
          text: TextSpan(text: title, style: effective),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool overflowed = painter.didExceedMaxLines;
        painter.dispose();
        if (!overflowed) return child;
        return Tooltip(
          message: title,
          triggerMode: TooltipTriggerMode.manual,
          excludeFromSemantics: true,
          child: child,
        );
      },
    );
  }
}
