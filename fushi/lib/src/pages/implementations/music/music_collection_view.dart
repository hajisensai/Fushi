/// 音乐列表 / 网格类视图的「色块 / 列表」两种样式的通用件（2026-11-13 用户：「专辑
/// 好像都没有两种布局，一种卡片一种列表」「艺人也是」「全部都用上」）：
///
/// - [MusicViewStyleBuilder]：读这一类视图（[MusicViewKind]）当前的样式并跟着切换
///   重建；墨水屏（非重设计外壳）恒给调用页的原有画法，不出切换键；
/// - [musicViewStyleToggle] / [musicViewStyleToggleButton]：页头动作组里的切换键，
///   图标与文案是「点了会换成的那一种」；
/// - [MusicStyledCollection]：同一份条目按样式排成封面色块（封面网格布局下是调用页
///   原有的封面网格卡）或单列行，惰性构建、错峰进场；
/// - [MusicCollectionBlock] / [MusicCollectionRow]：专辑 / 艺人 / 歌单通用的封面色块
///   与单列行（行基于 [MusicTrackRowSurface]：悬停 / 焦点 / 按下铺封面取色底）。
///
/// 记忆本身（按种类分键持久化）在 `media/music/music_view_style.dart`。本文件不接
/// AppModel（不进 import 大环）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/media/music/music_view_style.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show
        MusicCover,
        MusicCoverTintSource,
        kMusicHoverLiftScale,
        musicMaterialCover;
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart'
    show MusicTrackRowSurface;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout, shellContentLayoutOf, shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show
        FushiCoverBlock,
        FushiCoverBlockArt,
        FushiCoverBlockSize,
        fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show FushiCoverBlockItemBuilder, SliverFushiCoverBlocks;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarItem;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;
import 'package:fushi/src/utils/components/shelf_cover_material.dart'
    show ShelfCoverMaterial, ShelfCoverMaterialScope;
import 'package:fushi/src/utils/fushi_icons.dart';

export 'package:fushi/src/media/music/music_view_style.dart'
    show MusicViewKind, MusicViewStyle, MusicViewStyleStore;

/// 这一页能不能切样式：重设计外壳生效（非墨水屏）。墨水屏保持原有画法、不出切换键。
bool musicViewStyleSwitchable(BuildContext context) =>
    shellRedesignActive(context);

/// [kind] 在本页生效的样式（不监听：调用方自己在 [MusicViewStyleStore.instance]
/// 变化时重建，或用 [MusicViewStyleBuilder]）。墨水屏恒为 [fallback]。
MusicViewStyle musicViewStyleOf(
  BuildContext context,
  MusicViewKind kind,
  MusicViewStyle fallback,
) => musicViewStyleSwitchable(context)
    ? MusicViewStyleStore.instance.effective(kind, fallback)
    : fallback;

/// 读 [kind] 当前的样式并跟着切换重建。[fallback] 是调用页的原有画法：用户没选过
/// 时用它；墨水屏恒用它。
class MusicViewStyleBuilder extends StatelessWidget {
  const MusicViewStyleBuilder({
    required this.kind,
    required this.fallback,
    required this.builder,
    super.key,
  });

  final MusicViewKind kind;
  final MusicViewStyle fallback;
  final Widget Function(BuildContext context, MusicViewStyle style) builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicViewStyleStore.instance,
    builder: (BuildContext context, Widget? _) =>
        builder(context, musicViewStyleOf(context, kind, fallback)),
  );
}

/// 切换键的 key（每类一个，测试与焦点驱动用）。
ValueKey<String> musicViewStyleToggleKey(MusicViewKind kind) =>
    ValueKey<String>('music-view-style-toggle-${kind.prefSuffix}');

IconData _toggleIcon(MusicViewStyle current) => current == MusicViewStyle.blocks
    ? FushiIcons.listView
    : FushiIcons.gridView;

String _toggleLabel(MusicViewStyle current) => current == MusicViewStyle.blocks
    ? t.music_detail_view_list
    : t.music_detail_view_blocks;

void _toggle(MusicViewKind kind, MusicViewStyle current) =>
    unawaited(MusicViewStyleStore.instance.set(kind, current.other));

/// 页头动作组（[FushiToolbarItem]）里的样式切换键：图标与文案是「点了会换成的那
/// 一种」。[current] 是本页生效的样式（[MusicViewStyleBuilder] 给的）。
FushiToolbarItem musicViewStyleToggle(
  MusicViewKind kind,
  MusicViewStyle current,
) => FushiToolbarItem(
  key: musicViewStyleToggleKey(kind),
  icon: _toggleIcon(current),
  label: _toggleLabel(current),
  onPressed: () => _toggle(kind, current),
);

/// 同一个切换键的图标按钮形（页头动作组是 widget 列表的页面用，如曲库页的
/// `FushiShellHeaderActions`）。
Widget musicViewStyleToggleButton(
  MusicViewKind kind,
  MusicViewStyle current, {
  bool padTouchTarget = false,
}) => FushiIconButton(
  key: musicViewStyleToggleKey(kind),
  icon: _toggleIcon(current),
  tooltip: _toggleLabel(current),
  label: _toggleLabel(current),
  padTouchTarget: padTouchTarget,
  onTap: () => _toggle(kind, current),
);

/// 圆形头像（艺人）：有封面（或内嵌封面）裁成圆，都没有画人像图标占位。
class MusicAvatar extends StatelessWidget {
  const MusicAvatar({
    super.key,
    this.coverPath,
    this.embeddedFromPath,
    this.size,
  });

  final String? coverPath;

  /// 没有 [coverPath] 时从这个音频文件取内嵌封面（本地艺人用其专辑的封面）。
  final String? embeddedFromPath;

  /// null = 撑满父级给的方形。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? cover = coverPath;
    final String? embedded = embeddedFromPath;
    final Widget child = (cover == null || cover.isEmpty) && embedded == null
        ? ColoredBox(
            color: scheme.secondaryContainer,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) => Center(
                child: FushiIcon(
                  FushiIcons.person,
                  color: scheme.onSecondaryContainer,
                  size:
                      (c.biggest.shortestSide.isFinite
                          ? c.biggest.shortestSide
                          : 40) *
                      0.45,
                ),
              ),
            ),
          )
        : MusicCover(
            coverPath: cover,
            embeddedFromPath: embedded,
            borderRadius: BorderRadius.zero,
          );
    return SizedBox(
      width: size,
      height: size,
      child: AspectRatio(aspectRatio: 1, child: ClipOval(child: child)),
    );
  }
}

/// 专辑 / 艺人 / 歌单的封面色块（重设计外壳「色块」样式）：方形专辑摆法、封面取色
/// 底、标题水印大字；与曲库专辑色块卡同一套外壳（[FushiHoverLift] + 卡壳点按 /
/// 长按 / 右键 / 焦点）。[circular] 的封面画成圆形头像（艺人）。
class MusicCollectionBlock extends StatelessWidget {
  const MusicCollectionBlock({
    required this.title,
    required this.size,
    super.key,
    this.subtitle,
    this.coverPath,
    this.embeddedFromPath,
    this.circular = false,
    this.eyebrow,
    this.chip,
    this.leadingIcon,
    this.trailing,
    this.metaKey,
    this.focusId,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  final String title;
  final FushiCoverBlockSize size;
  final String? subtitle;
  final String? coverPath;

  /// 没有 [coverPath] 时从这个音频文件取内嵌封面（本地专辑）。
  final String? embeddedFromPath;
  final bool circular;
  final String? eyebrow;
  final String? chip;
  final IconData? leadingIcon;
  final Widget? trailing;
  final Key? metaKey;
  final FushiFocusId? focusId;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      shape: fushiCoverBlockShape(context, size),
      focusId: focusId,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      child: MusicCoverTintSource(
        coverPath: coverPath,
        embeddedFromPath: embeddedFromPath,
        builder: (BuildContext context, ImageProvider? tint) => FushiCoverBlock(
          size: size,
          art: FushiCoverBlockArt.square,
          metaKey: metaKey,
          title: title,
          subtitle: _nonEmpty(subtitle),
          eyebrow: eyebrow,
          chip: _nonEmpty(chip),
          leadingIcon: leadingIcon,
          trailing: trailing,
          covers: <Widget>[
            if (circular)
              MusicAvatar(
                coverPath: coverPath,
                embeddedFromPath: embeddedFromPath,
              )
            else
              MusicCover(
                coverPath: coverPath,
                embeddedFromPath: embeddedFromPath,
                borderRadius: BorderRadius.zero,
              ),
          ],
          tintImage: tint,
        ),
      ),
    ),
  );
}

/// 专辑 / 艺人 / 歌单的单列行（「列表」样式）：基于 [MusicTrackRowSurface]——悬停 /
/// 键盘焦点 / 按下整条铺封面取色底、小封面抬起偏转。起始侧是方形封面（专辑 /
/// 歌单）或圆形头像（[circular]，艺人）；副行由调用方拼好（专辑：艺人 · 年份 ·
/// 曲目数；艺人：专辑数）；行尾默认一枚「进入」箭头。
class MusicCollectionRow extends StatelessWidget {
  const MusicCollectionRow({
    required this.title,
    super.key,
    this.subtitle,
    this.coverPath,
    this.embeddedFromPath,
    this.circular = false,
    this.badges = const <Widget>[],
    this.trailing,
    this.focusId,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  /// 起始侧封面边长。
  static const double coverSize = 48;

  final String title;
  final String? subtitle;
  final String? coverPath;
  final String? embeddedFromPath;
  final bool circular;

  /// 紧跟标题的小标记（试听来源 / 光盘规格……）。
  final List<Widget> badges;

  /// 行尾控件；null = 一枚「进入」箭头（随阅读方向镜像）。
  final List<Widget>? trailing;
  final FushiFocusId? focusId;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) => MusicTrackRowSurface(
    title: title,
    subtitle: subtitle,
    leading: circular
        ? MusicAvatar(
            coverPath: coverPath,
            embeddedFromPath: embeddedFromPath,
            size: coverSize,
          )
        : musicMaterialCover(
            MusicCover(
              coverPath: coverPath,
              embeddedFromPath: embeddedFromPath,
              size: coverSize,
            ),
            size: coverSize,
            compact: true,
          ),
    coverPath: coverPath,
    embeddedFromPath: embeddedFromPath,
    badges: badges,
    trailing: trailing ?? const <Widget>[FushiIcon(FushiIcons.chevronRight)],
    focusId: focusId,
    onTap: onTap,
    onLongPress: onLongPress,
    onSecondaryTap: onSecondaryTap,
  );
}

/// 封面网格布局下的网格几何（[MusicStyledCollection.gridDelegate]）：[width] 是滚动
/// 视口宽（含左右页边）。
typedef MusicGridDelegateBuilder =
    SliverGridDelegate Function(BuildContext context, double width);

/// 同一份条目按 [style] 排成封面色块 / 单列行的滚动视图：
///
/// - [MusicViewStyle.list]：单列行（[rowBuilder]），惰性、错峰进场；
/// - [MusicViewStyle.blocks]：库页布局是封面网格（[ShellContentLayout.grid]，含
///   墨水屏）且调用页有原有封面网格卡（[gridCardBuilder] + [gridDelegate]）时排原有
///   网格卡；否则排封面色块（[SliverFushiCoverBlocks]，拼贴 / 规整按库页布局）。
///
/// [header] 排在条目前、随列表一起滚（详情页的头部色块），与条目隔 [headerGap]；
/// [footer] 排在最后（分页加载的转圈）。[shrinkWrap] 时不自己滚（嵌在外层滚动里）。
class MusicStyledCollection extends StatelessWidget {
  const MusicStyledCollection({
    required this.style,
    required this.itemCount,
    required this.rowBuilder,
    required this.blockBuilder,
    super.key,
    this.gridCardBuilder,
    this.gridDelegate,
    this.gridMaterial,
    this.padding = EdgeInsets.zero,
    this.header,
    this.headerGap = 0,
    this.footer,
    this.shrinkWrap = false,
    this.controller,
    this.scrollKey,
  });

  final MusicViewStyle style;
  final int itemCount;
  final IndexedWidgetBuilder rowBuilder;
  final FushiCoverBlockItemBuilder blockBuilder;

  /// 封面网格布局下的原有网格卡；null = 网格布局下也排色块。
  final IndexedWidgetBuilder? gridCardBuilder;
  final MusicGridDelegateBuilder? gridDelegate;

  /// 原有网格卡的封面材质（专辑 = 方形「唱片」）。
  final ShelfCoverMaterial? gridMaterial;
  final EdgeInsetsGeometry padding;
  final Widget? header;
  final double headerGap;
  final Widget? footer;
  final bool shrinkWrap;
  final ScrollController? controller;

  /// 滚动视图的 key（调用页原有列表的 key 原样传进来）。
  final Key? scrollKey;

  bool _useGridCards(BuildContext context) =>
      style == MusicViewStyle.blocks &&
      gridCardBuilder != null &&
      gridDelegate != null &&
      shellContentLayoutOf(context) == ShellContentLayout.grid;

  Widget _body(BuildContext context, double viewportWidth) {
    if (style == MusicViewStyle.list) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          fushiStaggeredItemBuilder(rowBuilder),
          childCount: itemCount,
        ),
      );
    }
    if (_useGridCards(context)) {
      final Widget grid = SliverGrid(
        gridDelegate: gridDelegate!(context, viewportWidth),
        delegate: SliverChildBuilderDelegate(
          fushiStaggeredItemBuilder(gridCardBuilder!),
          childCount: itemCount,
        ),
      );
      final ShelfCoverMaterial? material = gridMaterial;
      return material == null
          ? grid
          : ShelfCoverMaterialScope(material: material, child: grid);
    }
    return SliverFushiCoverBlocks(
      layout: shellContentLayoutOf(context),
      itemCount: itemCount,
      itemBuilder: blockBuilder,
    );
  }

  Widget _scroll(BuildContext context, double viewportWidth) {
    final Widget? header = this.header;
    final Widget? footer = this.footer;
    return CustomScrollView(
      key: scrollKey,
      controller: controller,
      shrinkWrap: shrinkWrap,
      primary: shrinkWrap ? false : null,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      slivers: <Widget>[
        SliverPadding(
          padding: padding,
          sliver: SliverMainAxisGroup(
            slivers: <Widget>[
              if (header != null) ...<Widget>[
                SliverToBoxAdapter(
                  child: FushiStaggeredEntrance(index: 0, child: header),
                ),
                SliverToBoxAdapter(child: SizedBox(height: headerGap)),
              ],
              _body(context, viewportWidth),
              if (footer != null) SliverToBoxAdapter(child: footer),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    child: _useGridCards(context)
        ? LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) =>
                _scroll(context, c.maxWidth),
          )
        : _scroll(context, double.infinity),
  );
}
