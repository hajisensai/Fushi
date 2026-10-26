import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/utils.dart';

/// TODO-616 A2 series folded card: one card stands for a whole series. Same
/// slot aspect ratio as a normal book card so it mixes inline with loose books.
/// Tap -> series detail.
///
/// 2026-10-25 库页定版：封面是共享 [ShelfCoverFrame] 的多本排列——材质库页
/// （[ShelfCoverMaterialScope]）下是**扇形**（[covers] 最多 4 本，首个最前，悬停
/// 展开），没有材质时（墨水屏 / 测试）退回叠层。封面上**不压任何角标**（用户：
/// 「全部都不用角标设计」）：原左上「N 册」、右上「系列」、标签 chip、底边进度条
/// 全部进封面下的 [ShelfCardMeta]——标题一行 + 副行 [subtitle]（调用方拼「N 卷 ·
/// 读到第 X 卷」，标签在副行尾部）+ 合集阅读进度条。悬停抬升 / 按压下沉走共享
/// [FushiHoverLift]（内含 [FushiPressScale]），多选勾选圈与选中罩由
/// [ShelfCoverSelection] 画在最前那本封面上，与散书卡同规格。
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
    this.subtitle,
    this.tags = const <ShelfMetaTag>[],
    this.progress,
    super.key,
  });

  final String name;
  final int itemCount;

  /// 成员封面（首个 = 最前那本，其后近 → 远；材质下最多画 4 本）。为空则不渲染
  /// 封面（防御性，调用方保证非空）。
  final List<Widget> covers;
  final VoidCallback onTap;
  final double slotAspectRatio;

  /// Gamepad/keyboard focus id. When non-null and a [FushiFocusRoot] is present
  /// the card becomes a directional-focus target that opens on Enter / gamepad A,
  /// mirroring the loose book cards. Without it (or outside a focus root) the
  /// card stays a plain, tap-only InkWell as before.
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

  /// 封面下副行；null = `series_item_count`（「N 项」）。书架传「N 卷 · 读到第
  /// X 卷」。
  final String? subtitle;

  /// 合集的用户标签，排在副行尾部（[ShelfMetaTags]）。
  final List<ShelfMetaTag> tags;

  /// 合集阅读进度 0–1（副行下的进度条）；null = 不画进度条（仍占位）。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VoidCallback effectiveTap = selectionMode && onSelectionToggle != null
        ? onSelectionToggle!
        : onTap;
    final Widget? front = covers.isEmpty ? null : covers.first;
    final double? progressValue = progress?.clamp(0.0, 1.0);

    final Widget card = ContextMenuTrigger(
      onInvoke: contextMenuInvoker(selectionMode ? null : onSecondaryTap),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.rowVertical),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: shelfCoverRadius(context),
            // 封面卡不画状态层 / 水波（2026-10-25）：悬停 / 按下的灰底会在
            // 封面后面露出一块底板，反馈由 FushiHoverLift 与材质扫光负责。
            overlayColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
            splashFactory: NoSplash.splashFactory,
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
                        // 无材质时的叠层兜底：后面露出两层「下一本」。
                        stackedBehind: front ?? const SizedBox.shrink(),
                        // 材质下的扇形：最前那本之后的成员封面（近 → 远）。
                        stackedCovers: covers.length > 1
                            ? covers.sublist(1)
                            : null,
                        child: front == null
                            ? const SizedBox.shrink()
                            : ClipRect(child: front),
                      ),
                    ),
                    SizedBox(
                      // 随文字缩放变高（BUG-1184 同一诉求）。
                      height: ShelfCardMeta.heightFor(context),
                      child: ShelfCardMeta(
                        title: name,
                        subtitle: subtitle ?? t.series_item_count(n: itemCount),
                        progress: progressValue,
                        completed: progressValue != null && progressValue >= 1,
                        trailing: tags.isEmpty
                            ? null
                            : ShelfMetaTags(tags: tags),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Loose book cards are gamepad/keyboard focusable; a folded series card
    // must be too, else a shelf with series can't be entered by D-pad. Only
    // wrap when a focusId is supplied AND a FushiFocusRoot exists (plain tests /
    // no-controller contexts keep the bare InkWell). Enter / gamepad A activate
    // the same tap as a mouse; in selection mode that tap toggles selection
    // (effectiveTap), matching the InkWell.
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
    // 扇形在材质下读 [FushiHoverLift.liftedOf] 展开。
    final Widget lifted = result;
    return FushiHoverLift(
      enabled: !selectionMode,
      builder: (BuildContext _, bool __) => lifted,
    );
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
        decoration: BoxDecoration(color: emptyFill, borderRadius: radius),
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
