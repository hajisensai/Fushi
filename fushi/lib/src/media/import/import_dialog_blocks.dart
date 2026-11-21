/// 导入对话框里的拼贴色块（2026-11 导入对话框统一第二版）：对话框是外层导入面
/// （[ImportGuideBlock] / [ImportMethodBlock]）的缩小版，同一套取色表
/// （[importToneColors]）、多边形 glyph（[ImportGlyph]）、色块外形
/// （[fushiCoverBlockShape]）与悬停浮起（[FushiHoverLift]），不另立视觉语言。
///
/// - [ImportPickBlock]：主选择块（选书 / 漫画 / 视频文件…）。模块色反色大块
///   （与外层主方式块同一个配色），glyph + 粗标题 + 格式行；装了落点时内缩虚线
///   框、拖文件悬停时浮起 + 实线（同外层引导块）。已选后 glyph 换对勾、标题换成
///   文件名，尾部给清除。
/// - [ImportPickTile]：次要选择（封面 / 字幕 / 音频…）。按外层方式块的钉色上底
///   （音频 = 有声书酒红、文件夹 = 绿…），小 glyph（封面已选时是缩略图）+ 名称 +
///   副行 + 底部圆形动作钮；由 [ImportPickTileGrid] 排成等高网格。
/// - [ImportSectionBlock]：表单分组色块（网络来源的连接 / 认证 / 位置、视频的在线
///   流…），色块里放 M3E 填充式字段。
///
/// 墨水屏：取色表退成主题中性色，块靠 [FushiCard] / 描边分界，不做浮起与淡入。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/import_glyph.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 块内圆形动作钮（同外层方式块右下角的 → 钮：onContainer 16% 圆底）。只给
/// 意思一眼就懂的通用动作（清除）；有业务含义的来源 / 动作用带字的
/// [ImportTileActions]。
class ImportBlockIconButton extends StatelessWidget {
  const ImportBlockIconButton({
    required this.icon,
    required this.tooltip,
    required this.colors,
    this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final FushiCoverBlockColors colors;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? tap = onTap;
    return FushiIconButton(
      icon: icon,
      tooltip: tooltip,
      size: 18,
      isWideTapArea: true,
      enabled: enabled && tap != null,
      enabledColor: colors.onContainer,
      disabledColor: colors.onContainer.withValues(alpha: 0.38),
      backgroundColor: colors.onContainer.withValues(alpha: 0.16),
      onTap: tap == null ? null : () async => tap(),
    );
  }
}

/// 导入对话框正文的统一节奏：主块、格子网格、表单块、提示之间的竖向间距，
/// 也是网格的格间距（2026-11 用户「排版得改一下」：间距忽大忽小）。
const double importDialogRhythm = 12;

/// 块内带字动作的一项（见 [ImportTileActions]）。
class ImportTileAction {
  const ImportTileAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.actionKey,
  });

  final IconData icon;

  /// 常显文字（不是只进 tooltip）：触屏上看得见、一眼知道这一格能做什么。
  final String label;
  final VoidCallback? onTap;

  /// 当前文件来自这条来源（实心反色）；再点一次 = 重新走这条来源。
  final bool selected;
  final bool enabled;
  final Key? actionKey;
}

/// 块里的带字动作行（2026-11 用户「这样看不出能够转录」）：一格有不止一种
/// 来源（选文件 / 设备端转录 / 从服务器取…）时，每种来源是一枚带图标 + 文字的
/// 色调胶囊，取块色（onContainer 16% 底；当前来源实心反色），不再是右上角一枚
/// 只有 tooltip 的图标。[note] 是动作下方的说明行（如「请先选择音频文件」——
/// 某个来源暂不可用时把原因写出来，而不是把按钮藏掉）。
class ImportTileActions extends StatelessWidget {
  const ImportTileActions({
    required this.colors,
    required this.actions,
    this.note,
    super.key,
  });

  final FushiCoverBlockColors colors;
  final List<ImportTileAction> actions;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final String? hint = note;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 一行紧凑小片，放不下才折行（块真的太窄时）。
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final ImportTileAction a in actions) _pill(context, a),
          ],
        ),
        // 说明只占一行小字（不再自成一大行把整排格子撑高）。
        if (hint != null && hint.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.labelSmall.copyWith(
              color: colors.onContainer.withValues(alpha: 0.8),
            ),
          ),
        ],
      ],
    );
  }

  Widget _pill(BuildContext context, ImportTileAction a) {
    final VoidCallback? tap = a.onTap;
    final Color fill = a.selected
        ? colors.onContainer
        : colors.onContainer.withValues(alpha: 0.16);
    final Color ink = a.selected ? colors.container : colors.onContainer;
    return FushiFilledButton.tonalIcon(
      key: a.actionKey,
      onPressed: a.enabled ? tap : null,
      style: FilledButton.styleFrom(
        backgroundColor: fill,
        foregroundColor: ink,
        disabledBackgroundColor: colors.onContainer.withValues(alpha: 0.08),
        disabledForegroundColor: colors.onContainer.withValues(alpha: 0.45),
        // 紧凑小片（32 高）：格子里的次要来源，不是对话框主按钮。
        minimumSize: const Size(0, 32),
        padding: const EdgeInsetsDirectional.only(start: 10, end: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        iconSize: 16,
        textStyle: context.fushiType.labelMedium.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      icon: FushiIcon(a.icon, size: 16),
      label: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// glyph 槽：已选时弹簧换成对勾（同 seed，形状不变）。
class _PickGlyph extends StatelessWidget {
  const _PickGlyph({
    required this.icon,
    required this.colors,
    required this.seed,
    required this.size,
    required this.selected,
    required this.turns,
  });

  final IconData icon;
  final FushiCoverBlockColors colors;
  final String seed;
  final double size;
  final bool selected;
  final double turns;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSwitcher(
      duration: motion.spatialDefault.duration,
      switchInCurve: motion.spatialDefault.curve,
      switchOutCurve: motion.effectsFast.curve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          ScaleTransition(
            scale: animation,
            child: FadeTransition(
              opacity: fushiUnitClamped(animation),
              child: child,
            ),
          ),
      child: ImportGlyph(
        key: ValueKey<bool>(selected),
        icon: selected ? FushiIcons.success : icon,
        colors: colors,
        seed: seed,
        size: size,
        turns: turns,
      ),
    );
  }
}

/// 主选择块（见文件头）。
class ImportPickBlock extends StatelessWidget {
  const ImportPickBlock({
    required this.tone,
    required this.icon,
    required this.title,
    this.subtitle,
    this.dropHint,
    this.selected = false,
    this.busy = false,
    this.enabled = true,
    this.onTap,
    this.onClear,
    this.actions = const <Widget>[],
    this.below,
    this.focusId,
    super.key,
  });

  /// 模块色（书 coral / 漫画 violet / 视频 cyan…），取反色上底。
  final ImportTone tone;
  final IconData icon;

  /// 未选 = 动作名（「选择书籍文件」）；已选 = 文件名。
  final String title;

  /// 未选 = 格式行；已选 = 动作名 / 格式。
  final String? subtitle;

  /// 拖放说明；null = 本块不是落点（不画虚线）。只在桌面显示。
  final String? dropHint;
  final bool selected;

  /// 选中的东西还在后台定性（如漫画框读包判断是不是图片型 EPUB）：副标题前加一个
  /// 小转圈，表示「收到了、正在处理」，不是没选上。
  final bool busy;
  final bool enabled;
  final VoidCallback? onTap;

  /// 已选时的清除；null = 不给清除钮。
  final VoidCallback? onClear;

  /// 尾部额外动作（[ImportBlockIconButton]，如漫画的「选文件夹 / 选文件」）。
  final List<Widget> actions;

  /// 文字列下方的附加控件（带字动作行 [ImportTileActions]）。
  final Widget? below;
  final FushiFocusId? focusId;

  /// 块的配色（调用方给 actions 里的 [ImportBlockIconButton] 取色用）。
  static FushiCoverBlockColors colorsOf(
    BuildContext context,
    ImportTone tone,
  ) => importToneColors(context, tone, inverse: true);

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = colorsOf(context, tone);
    final bool eink = isEinkTheme(context);
    final bool motion = fushiMotionEnabled(context);
    final String? hint = dropHint;
    final bool droppable = hint != null && isDesktopPlatform;
    final bool dragging =
        droppable && FushiFileDropTarget.dragHoveringOf(context);
    final double radius = fushiCoverBlockRadius(
      FushiCoverBlockSize.regular,
      120,
    );
    final VoidCallback? clear = onClear;
    final String? sub = subtitle;
    final Widget? extra = below;
    return FushiBlockColorScope(
      colors: colors,
      child: FushiHoverLift(
        enabled: enabled && onTap != null,
        forceLifted: dragging && motion,
        builder: (BuildContext context, bool hovering) {
          final List<Widget> trailing = <Widget>[
            ...actions,
            if (selected && clear != null)
              ImportBlockIconButton(
                icon: FushiIcons.close,
                tooltip: t.dialog_clear,
                colors: colors,
                enabled: enabled,
                onTap: clear,
              )
            else if (!selected && actions.isEmpty && below == null)
              ExcludeSemantics(
                child: ImportGoArrow(colors: colors, nudge: hovering),
              ),
          ];
          final Widget text = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                dragging ? t.import_drop_release_title : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleLarge.copyWith(
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: colors.onContainer,
                ),
              ),
              if (sub != null && sub.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    if (busy) ...<Widget>[
                      SizedBox.square(
                        dimension: 14,
                        child: adaptiveIndicator(
                          context: context,
                          strokeWidth: 2,
                          color: colors.onContainer,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.fushiType.bodySmall.copyWith(
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: colors.onContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (droppable && !selected) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  hint,
                  style: context.fushiType.bodySmall.copyWith(
                    height: 1.45,
                    color: colors.onContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
              if (extra != null) ...<Widget>[const SizedBox(height: 12), extra],
            ],
          );
          return AnimatedOpacity(
            opacity: enabled ? 1 : 0.6,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: Semantics(
              selected: selected,
              child: FushiCard(
                focusId: focusId,
                onTap: enabled ? onTap : null,
                color: colors.container,
                shape: fushiCoverBlockShape(
                  context,
                  FushiCoverBlockSize.regular,
                ),
                borderRadius: BorderRadius.circular(radius),
                padding: EdgeInsets.zero,
                child: CustomPaint(
                  foregroundPainter: droppable
                      ? ImportDashedBorderPainter(
                          color: dragging
                              ? colors.onContainer
                              : colors.onContainer.withValues(alpha: 0.3),
                          radius: radius,
                          dashed: !dragging && !eink,
                          strokeWidth: dragging ? 3 : 2,
                          inset: dragging ? 4 : 8,
                        )
                      : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 112),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: <Widget>[
                          _PickGlyph(
                            icon: icon,
                            colors: colors,
                            seed: 'import-pick-$icon',
                            size: 60,
                            selected: selected,
                            turns: (hovering || dragging) && motion
                                ? 14 / 360
                                : 0,
                          ),
                          const SizedBox(width: 18),
                          Expanded(child: text),
                          if (trailing.isNotEmpty) ...<Widget>[
                            const SizedBox(width: 12),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: trailing,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 外层方式块右下角的 → 圆钮（悬停右移 4）；装饰性，调用方自己包
/// [ExcludeSemantics]。
class ImportGoArrow extends StatelessWidget {
  const ImportGoArrow({required this.colors, this.nudge = false, super.key});

  final FushiCoverBlockColors colors;
  final bool nudge;

  static const double _size = 34;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.release,
      offset: Offset(nudge && fushiMotionEnabled(context) ? 4 / _size : 0, 0),
      child: SizedBox.square(
        dimension: _size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.onContainer.withValues(alpha: 0.16),
          ),
          child: Center(
            child: FushiIcon(
              FushiIcons.forward,
              size: 18,
              color: colors.onContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// 次要选择块（见文件头）。
class ImportPickTile extends StatelessWidget {
  const ImportPickTile({
    required this.tone,
    required this.icon,
    required this.title,
    this.subtitle,
    this.thumbnail,
    this.below,
    this.selected = false,
    this.enabled = true,
    this.droppable = false,
    this.showGo = false,
    this.onTap,
    this.onClear,
    this.actions = const <Widget>[],
    this.focusId,
    super.key,
  });

  /// 外层方式块的钉色（[importMethodTone]）：音频 rose、文件夹 green…
  final ImportTone tone;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// 代替 glyph 的预览（封面缩略图）。
  final Widget? thumbnail;

  /// 副行下的附加控件（如对齐文件格的「选文件 / 转录」分段）。
  final Widget? below;
  final bool selected;
  final bool enabled;

  /// 拖文件悬停在对话框上时描一圈实线（这一格也收拖进来的文件）。
  final bool droppable;

  /// 底部画外层方式块的 → 圆钮（选项块：点下去就走）。
  final bool showGo;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final List<Widget> actions;
  final FushiFocusId? focusId;

  /// 块的配色（给 actions 取色）。
  static FushiCoverBlockColors colorsOf(
    BuildContext context,
    ImportTone tone,
  ) => importToneColors(context, tone);

  /// 头部格高：封面缩略图（34×48）与 48 触控区的清除钮都放得下。
  static const double _headerHeight = 48;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = colorsOf(context, tone);
    final bool motion = fushiMotionEnabled(context);
    final bool dragging =
        droppable &&
        isDesktopPlatform &&
        FushiFileDropTarget.dragHoveringOf(context);
    final double radius = fushiCoverBlockRadius(FushiCoverBlockSize.half, 0);
    final VoidCallback? clear = onClear;
    final String? sub = subtitle;
    final Widget? thumb = thumbnail;
    final Widget? extra = below;
    return FushiBlockColorScope(
      colors: colors,
      child: FushiHoverLift(
        enabled: enabled && onTap != null,
        builder: (BuildContext context, bool hovering) {
          final List<Widget> trailing = <Widget>[
            ...actions,
            if (selected && clear != null)
              ImportBlockIconButton(
                icon: FushiIcons.close,
                tooltip: t.dialog_clear,
                colors: colors,
                enabled: enabled,
                onTap: clear,
              ),
          ];
          final Widget lead =
              thumb ??
              _PickGlyph(
                icon: icon,
                colors: colors,
                seed: 'import-tile-$icon',
                size: 38,
                selected: selected,
                turns: hovering && motion ? -10 / 360 : 0,
              );
          return AnimatedOpacity(
            opacity: enabled ? 1 : 0.6,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: Semantics(
              selected: selected,
              child: FushiCard(
                focusId: focusId,
                onTap: enabled ? onTap : null,
                color: colors.container,
                shape: fushiCoverBlockShape(context, FushiCoverBlockSize.half),
                borderRadius: BorderRadius.circular(radius),
                padding: EdgeInsets.zero,
                child: CustomPaint(
                  foregroundPainter: dragging
                      ? ImportDashedBorderPainter(
                          color: colors.onContainer,
                          radius: radius,
                          dashed: false,
                          strokeWidth: 3,
                          inset: 4,
                        )
                      : null,
                  // 高度由紧凑内容决定（头部 48 + 标题 + 副行 + 可选动作行），
                  // 同一行各格由 [ImportPickTileGrid] 拉成等高。
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 头部定高（= 封面缩略图高）：图标 / 缩略图贴左、动作钮
                          // 贴右，都在这一格里居中——有没有动作钮、是不是缩略图，
                          // 同一行各格的标题与副行都对齐。
                          SizedBox(
                            height: _headerHeight,
                            child: Row(
                              children: <Widget>[
                                lead,
                                const Spacer(),
                                ...trailing,
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.fushiType.titleSmall.copyWith(
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                              color: colors.onContainer,
                            ),
                          ),
                          if (sub != null && sub.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              sub,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.fushiType.bodySmall.copyWith(
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                                color: colors.onContainer,
                              ),
                            ),
                          ],
                          if (extra != null) ...<Widget>[
                            const SizedBox(height: 10),
                            extra,
                          ],
                          if (showGo) ...<Widget>[
                            const SizedBox(height: 12),
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: ExcludeSemantics(
                                child: ImportGoArrow(
                                  colors: colors,
                                  nudge: hovering,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// [ImportPickTile] 的等高网格：宽 ≥ 480 时一行最多 3 格，否则 2 格；只有一格
/// 时占满一行。每格等宽（末行不满时留空位，不拉宽）、同一行等高。格间
/// [importDialogRhythm]，与对话框里块与块的竖向间距同一个值。
class ImportPickTileGrid extends StatelessWidget {
  const ImportPickTileGrid({required this.children, super.key});

  final List<Widget> children;

  static const double _gap = importDialogRhythm;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int perRow = constraints.maxWidth >= 480 ? 3 : 2;
        final int columns = children.length < perRow ? children.length : perRow;
        final List<Widget> rows = <Widget>[];
        for (int start = 0; start < children.length; start += columns) {
          final int end = start + columns > children.length
              ? children.length
              : start + columns;
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = start; i < start + columns; i++) ...<Widget>[
                    if (i > start) const SizedBox(width: _gap),
                    Expanded(
                      child: i < end ? children[i] : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: _gap),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

/// 表单分组色块（见文件头）：块头是小 glyph + 粗标题，下面一列字段
/// （[FushiFormSection] 的节奏）。
class ImportSectionBlock extends StatelessWidget {
  const ImportSectionBlock({
    required this.tone,
    required this.children,
    this.icon,
    this.title,
    this.trailing,
    super.key,
  });

  final ImportTone tone;
  final IconData? icon;
  final String? title;
  final List<Widget> children;

  /// 字段列之后、不加字段间距的尾部（如可折叠的高级字段，收起时不留空隙）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = importToneColors(context, tone);
    final bool eink = isEinkTheme(context);
    final IconData? glyph = icon;
    final String? head = title;
    final Widget? tail = trailing;
    // 色块里的填充式字段（灰底压在彩色块上发脏）：经 FushiFieldFillScope 只改
    // 字段 / 下拉的配色。墨水屏块本身就是中性色。
    Widget fields = FushiFormSection(children: children);
    if (!eink) {
      fields = FushiFieldFillScope(
        // 块色上叠 8% 块前景：同一色相里高一级的填充，静止指示线 / 标题 /
        // 尾部钮取块前景（见 fushiMd3FieldDecoration）。
        color: Color.alphaBlend(
          colors.onContainer.withValues(alpha: 0.08),
          colors.container,
        ),
        foreground: colors.onContainer,
        child: fields,
      );
    }
    // 块里的字段 / 下拉 / 分段钮读主题色：不下发块配色就拿外层配色（从深色主
    // 方式块弹出的对话框里，浅色表单块上的输入字、下拉值、未选分段成了浅色字，
    // 看不见）。与 [ImportPickBlock] / [ImportPickTile] 同样包局部配色。
    final Widget block = DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.container,
        shape: fushiCoverBlockShape(
          context,
          FushiCoverBlockSize.half,
        ).copyWith(side: eink ? BorderSide(color: colors.onContainer) : null),
      ),
      child: Padding(
        // 与 [ImportPickTile] 同内边距 / 同外形（half 档色块）。
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (head != null) ...<Widget>[
              Row(
                children: <Widget>[
                  if (glyph != null) ...<Widget>[
                    ExcludeSemantics(
                      child: ImportGlyph(
                        icon: glyph,
                        colors: colors,
                        seed: 'import-section-$head',
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        head,
                        style: context.fushiType.titleSmall.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colors.onContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            fields,
            ?tail,
          ],
        ),
      ),
    );
    return FushiBlockColorScope(colors: colors, child: block);
  }
}
