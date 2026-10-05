import 'package:flutter/material.dart';

import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/utils.dart';

/// TODO-616 A2 series folded card: one card stands for a whole series (cover =
/// first volume, count badge = members, name footer). Same slot aspect ratio as
/// a normal book card so it mixes inline with loose books. Tap -> series detail.
///
/// 2026-10 书架重设计：形态改成与视频库「系列」卡同一套**叠层封面**——共享
/// [ShelfCoverFrame] 的 `stackedBehind`（MD3 两层色块 / Apple 两层模糊封面 /
/// 墨水屏描边空层），左上角「N 册」、右上角「系列」角标（共享 [CoverBadge]），
/// 标签 chip 接在册数下面，底边可选合集阅读进度条（共享 [CoverProgressStrip]）。
/// 不再自绘 2x2 文件夹拼图（那份 [SeriesFolderCover] 仍给「组合成系列」命名弹窗
/// 预览用）。悬停抬升 / 按压下沉走共享 [FushiHoverLift]（内含 [FushiPressScale]），
/// 多选勾选圈与选中罩由 [ShelfCoverSelection] 画在封面上，与散书卡逐像素同规格。
class SeriesShelfCard extends StatelessWidget {
  const SeriesShelfCard({
    required this.name,
    required this.itemCount,
    required this.covers,
    required this.onTap,
    required this.slotAspectRatio,
    this.focusId,
    this.selectionKey,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionToggle,
    this.onLongPress,
    this.onSecondaryTap,
    this.countLabel,
    this.kindLabel,
    this.tagLabels,
    this.progress,
    super.key,
  });

  final String name;
  final int itemCount;

  /// 合集封面（[covers].first 为最前层主封面，也作 Apple 叠层的模糊底图）。
  /// 为空则不渲染封面（防御性，调用方保证非空）。
  final List<Widget> covers;
  final VoidCallback onTap;
  final double slotAspectRatio;

  /// Gamepad/keyboard focus id. When non-null and a [FushiFocusRoot] is present
  /// the card becomes a directional-focus target that opens on Enter / gamepad A,
  /// mirroring the loose book cards ([_bookCardShell]). Without it (or outside a
  /// focus root) the card stays a plain, tap-only InkWell as before.
  final FushiFocusId? focusId;

  /// Optional selection wiring (so a series card is selectable in batch mode
  /// just like a normal card). When [selectionMode] is on, tap toggles
  /// selection instead of opening the detail page.
  final String? selectionKey;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionToggle;

  /// 长按 / 桌面右键（与散书卡 onLongPress/onSecondaryTap 同语义，巡检 PR-3 补齐
  /// 交互对称性）。null 时保持纯点击（零破坏）；多选态下自动禁用（与散卡一致）。
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// 左上角成员数文案；null = `series_item_count`（「N 项」）。书架传「N 册」。
  final String? countLabel;

  /// 右上角类型角标文案（书架「系列」）；null = 不画。
  final String? kindLabel;

  /// 合集标签 chip 列（接在册数角标下面）；null = 无标签。
  final Widget? tagLabels;

  /// 合集阅读进度 0–1（封面底边进度条）；null / 0 = 不画。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    final VoidCallback effectiveTap =
        selectionMode && onSelectionToggle != null ? onSelectionToggle! : onTap;
    final Widget? front = covers.isEmpty ? null : covers.first;
    final double? progressValue = progress;

    final Widget coverStack = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (front != null) ClipRect(child: front),
        if (progressValue != null && progressValue > 0)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 0,
            child: CoverProgressStrip(value: progressValue.clamp(0.0, 1.0)),
          ),
        // 多选态左上让位给勾选圈（[ShelfCoverFrame] 画），册数挪到左下。
        if (!selectionMode)
          PositionedDirectional(
            start: overlayInset,
            top: overlayInset,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _countBadge(),
                if (tagLabels != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: tokens.spacing.gap * 9,
                      maxHeight: tokens.spacing.gap * 3.5,
                    ),
                    child: ClipRect(child: tagLabels),
                  ),
                ],
              ],
            ),
          )
        else
          PositionedDirectional(
            start: overlayInset,
            bottom: overlayInset + 4,
            child: _countBadge(),
          ),
        if (kindLabel != null)
          PositionedDirectional(
            end: overlayInset,
            top: overlayInset,
            child: CoverBadge(
              icon: Icons.collections_bookmark_outlined,
              iconSize: 13,
              label: kindLabel,
            ),
          ),
      ],
    );

    final Widget card = ContextMenuTrigger(
      onInvoke: contextMenuInvoker(selectionMode ? null : onSecondaryTap),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.rowVertical),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: shelfCoverRadius(context),
            onTap: effectiveTap,
            onLongPress: selectionMode ? null : onLongPress,
            child: AspectRatio(
              aspectRatio: slotAspectRatio,
              child: ShelfCoverSelection(
                selectionMode: selectionMode && selectionKey != null,
                selected: selected,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: ShelfCoverFrame(
                        // 与视频库「系列」卡同一个叠层：后面露出两层「下一本」。
                        stackedBehind: front ?? const SizedBox.shrink(),
                        child: coverStack,
                      ),
                    ),
                    SizedBox(
                      // BUG-1184：与散书卡同步，随文字缩放变高，防止系列名第二行被裁。
                      height: ShelfCardFooter.heightFor(context),
                      child: ShelfCardFooter(title: name),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Loose book cards are gamepad/keyboard focusable via _bookCardShell; a
    // folded series card must be too, else a shelf with series can't be entered
    // by D-pad. Only wrap when a focusId is supplied AND a FushiFocusRoot exists
    // (plain tests / no-controller contexts keep the bare InkWell). Enter /
    // gamepad A activate the same tap as a mouse; in selection mode that tap
    // toggles selection (effectiveTap), matching the InkWell.
    Widget result = card;
    if (focusId != null && FushiFocusRoot.maybeControllerOf(context) != null) {
      result = Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              effectiveTap();
              return null;
            },
          ),
        },
        child: FushiFocusTarget(id: focusId!, child: card),
      );
    }
    // 悬停抬升 + 按压下沉（与散书卡同一个壳；多选态关掉，卡片此时是勾选目标）。
    final Widget lifted = result;
    return FushiHoverLift(
      enabled: !selectionMode,
      builder: (BuildContext _, bool __) => lifted,
    );
  }

  /// 成员数角标：走共享 [CoverBadge]（2026-10-04 角标统一——MD3
  /// inverseSurface@0.85 / Apple 磨砂黑，圆角 6）。
  Widget _countBadge() {
    return CoverBadge(label: countLabel ?? t.series_item_count(n: itemCount));
  }
}

/// TODO-947：手机文件夹式合集封面——把前 N 张成员封面（[covers]，首卷在 first）铺成
/// 2x2 网格缩略（像 iOS/安卓桌面文件夹图标），让用户一眼看出合集里合并了哪几本书。
///
/// [SeriesShelfCard] 折叠卡与「组合成系列」命名弹窗预览共用本组件（同一视觉语言）。
/// 成员不足 2 张优雅降级为整封面（无网格，never break 单成员）；成员多于 4 张只取前
/// 4 张（配角标显示真实总数）。空 [covers] 渲染占位空盒（防御性，调用方保证非空）。
class SeriesFolderCover extends StatelessWidget {
  const SeriesFolderCover({
    required this.covers,
    this.cellRadius = 4,
    super.key,
  });

  /// 系列前 N 张成员封面（N 由调用方裁到 ≤4），[covers].first 为主封面（首卷）。
  final List<Widget> covers;

  /// 每个网格单元的圆角半径（文件夹内小缩略图的描边圆角）。
  final double cellRadius;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 单张成员：整封面填满（与散书卡视觉一致，never break 单成员合集）。
    if (covers.length <= 1) {
      return covers.isEmpty ? const SizedBox.shrink() : covers.first;
    }
    final double gap = tokens.spacing.gap / 2;
    final double pad = tokens.spacing.gap / 2;
    // 文件夹底：微着色圆角容器 + 内边距，内嵌 2x2 成员封面网格。
    // Apple：文件夹底是叠在卡面上的系统灰 secondaryFill（iOS 桌面文件夹
    // 观感），不用 MD3 色阶里最重的 surfaceContainerHighest。
    final bool glass = isGlassDesign(context);
    // 空槽：成员不足 4 本时补齐网格的占位底（更浅一档，视觉平衡）；Apple 下
    // 是再浅一档的 tertiaryFill（与文件夹底同属系统灰阶）。
    final Color emptyFill = glass
        ? appleColorsOf(context).tertiaryFill
        : theme.colorScheme.surfaceContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: glass
            ? appleColorsOf(context).secondaryFill
            : theme.colorScheme.surfaceContainerHighest,
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          children: <Widget>[
            Expanded(child: _mosaicRow(emptyFill, gap, 0, 1)),
            SizedBox(height: gap),
            Expanded(child: _mosaicRow(emptyFill, gap, 2, 3)),
          ],
        ),
      ),
    );
  }

  Widget _mosaicRow(Color emptyFill, double gap, int a, int b) {
    return Row(
      children: <Widget>[
        Expanded(child: _mosaicCell(emptyFill, a)),
        SizedBox(width: gap),
        Expanded(child: _mosaicCell(emptyFill, b)),
      ],
    );
  }

  Widget _mosaicCell(Color emptyFill, int i) {
    final BorderRadius radius = BorderRadius.circular(cellRadius);
    if (i >= covers.length) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: emptyFill,
          borderRadius: radius,
        ),
      );
    }
    // 成员封面填满该单元并按各自 BoxFit 呈现，超出用圆角裁掉（center-crop 观感）。
    return ClipRRect(
      key: ValueKey<String>('series-folder-cell-$i'),
      borderRadius: radius,
      child: SizedBox.expand(child: covers[i]),
    );
  }
}
