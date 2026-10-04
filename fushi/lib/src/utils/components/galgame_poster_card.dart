import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// galgame 竖版海报卡（游戏库 / 合集行 / 合集详情 / 串流库 / 在途下载占位共用）。
///
/// 2026-10 游戏模块重设计：并入「封面即卡片」体系——交互壳是 [shelfCoverCard]
/// （FushiCard：点击 / 长按 / 右键 / 焦点 / ActivateIntent / 按压下沉 / 状态层），
/// 视觉是 [ShelfCoverFrame]（MD3 Expressive 12 圆角、悬停加一档柔和投影；Apple
/// 10 圆角 + 0.5px 内描边 + Apple Arcade 式柔和投影；墨水屏 1px 描边无投影），
/// 悬停抬升走 [FushiHoverLift]。标题直接落在页面底上（不再有整卡色块），封面下方
/// 左对齐两行标题 + 可选一行元信息（游玩时长 / 最近游玩）。
///
/// 刻意**不做文件 IO**：[cover] 由调用方传入（`ShelfFileCover` / 占位图 / 网络图
/// 都行），卡片本身是纯 widget、可 widget-test，也不与封面来源耦合。
///
/// 树结构恒定：选中 / 多选 / 角标只换值或在封面 Stack 内增删叶子，不按设计系统
/// 增删包装层。
class GalgamePosterCard extends StatelessWidget {
  const GalgamePosterCard({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.badge,
    this.overlayText,
    this.selected = false,
    this.multiSelected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.trailing,
    this.semanticLabel,
    this.focusId,
  });

  /// 封面 widget（3:4 会被封面框裁剪；建议 `fit: BoxFit.cover`）。
  final Widget cover;

  /// 标题（封面下方左对齐，两行省略，悬停显示全名）。
  final String title;

  /// 标题下方一行元信息（游玩时长 / 最近游玩等）；null 不占行。
  final String? subtitle;

  /// 封面左上角状态角标（如 [CoverBadge] 的「在玩 / 玩过 / 搁置」）；多选态让位
  /// 给勾选圈。
  final Widget? badge;

  /// 封面底部「排序信息」浮层文本；null / 空则不显示浮层。
  final String? overlayText;

  /// 选中态（当前详情 / 焦点）：封面上画选中罩（主色细环 + 淡色罩），标题染主色。
  final bool selected;

  /// 批量多选态：封面左上角勾选圈（与书架 / 视频库同一枚）。
  final bool multiSelected;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右键（桌面）→ 一般用于打开详情菜单。
  final VoidCallback? onSecondaryTap;

  /// 右上角悬浮控件（如更多菜单按钮）。
  final Widget? trailing;

  final String? semanticLabel;

  /// 焦点站点 id（手柄/键盘导航）。传入时注册到 [FushiFocusRoot]，`Enter`/A 键
  /// 触发 [onTap]。库页靠它保持 `game-card-<id>` 焦点站点可被 requestById 聚焦。
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    // 悬停抬升交给共享的 [FushiHoverLift]（书架 / 漫画 / 视频库同一套，自带墨水屏
    // 与「减弱动态效果」降级）；封面框经 [FushiHoverLift.liftedOf] 自己加深投影。
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle titleStyle = shelfCardTitleStyle(context).copyWith(
      color: selected ? theme.colorScheme.primary : null,
    );
    final String? meta = subtitle;

    final Widget coverBox = AspectRatio(
      aspectRatio: 3 / 4,
      child: ShelfCoverSelection(
        selectionMode: multiSelected,
        selected: selected || multiSelected,
        child: ShelfCoverFrame(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              cover,
              if (overlayText != null && overlayText!.isNotEmpty)
                _buildSortOverlay(context),
              if (badge != null && !multiSelected)
                Positioned(top: 6, left: 6, child: badge!),
              if (trailing != null)
                Positioned(top: 4, right: 4, child: trailing!),
            ],
          ),
        ),
      ),
    );

    final Widget footer = Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // TODO-2490：两行仍放不下的长游戏名，桌面悬停显示完整标题；触屏走卡片
          // 长按菜单（标题不限行）看全名。
          ShelfTitleOverflowTooltip(
            title: title,
            style: titleStyle,
            maxLines: 2,
            child: Text(
              title,
              // BUG-1184：galgame 名普遍 20 字以上，窄屏卡宽只有约 136px，单行只看
              // 得到开头六七个字。封面在 [Flexible] 里，标题变高只是等量压缩封面。
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          if (meta != null && meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata,
              ),
            ),
        ],
      ),
    );

    final Widget card = shelfCoverCard(
      focusId: focusId,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Flexible(child: coverBox),
          footer,
        ],
      ),
    );

    // 手柄重设计 P4：长按 A = 鼠标长按 / 右键同一入口（onLongPress，游戏卡上是上下文
    // 菜单）。[GamepadLongPressActions] 对 null onLongPress 透明（intent 继续上溯）。
    return GamepadLongPressActions(
      onLongPress: onLongPress,
      child: Semantics(
        label: semanticLabel ?? title,
        button: onTap != null,
        selected: selected,
        child: MouseRegion(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: card,
        ),
      ),
    );
  }

  /// 封面底部的排序信息渐变浮层：白字、单行、左对齐，底部深色渐变托底（压在任意
  /// 亮度的封面上都可读；两套设计系统同一份，墨水屏由封面框的实色描边兜底）。
  Widget _buildSortOverlay(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 22, 10, 6),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x00000000),
                Color(0x52000000),
                Color(0xC8000000),
              ],
              stops: <double>[0.0, 0.55, 1.0],
            ),
          ),
          child: Text(
            overlayText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: const <Shadow>[
                    Shadow(color: Color(0x99000000), blurRadius: 2),
                  ],
                ),
          ),
        ),
      ),
    );
  }
}
