import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// galgame 竖版卡盒卡（游戏库 / 合集折叠卡 / 合集详情 / 串流库 / 在途下载占位共用）。
///
/// 2026-10-25 库页材质定版：外形是透明卡盒——竖长 1:1.6
/// （[kShelfGameCaseAspectRatio]），方图 / 横图封面在内窗里居中裁切。材质本身
/// 由祖先 [ShelfCoverMaterialScope]（`ShelfCoverMaterial.gameCase`）交给共享的
/// [ShelfCoverFrame] 画（塑料外圈 + 盒面反光 + 悬停柔光 + 接触阴影）；没有材质
/// 作用域或墨水屏时退回描边封面框，形状不变。
///
/// 封面上**不压任何角标**（用户 2026-10-25：「全部都不用角标设计」）：游玩状态、
/// 排序值、运行中、下载进度一律进封面下的文字块（[ShelfCardMeta]：标题一行 +
/// 副行一行 + 进度条）。封面上只剩多选勾选圈 / 选中罩（[ShelfCoverSelection]）
/// 与调用方自己画在 [cover] 里的加载遮罩。
///
/// 交互壳是 [shelfCoverCard]（FushiCard：点击 / 长按 / 右键 / 焦点 /
/// ActivateIntent / 按压下沉），悬停抬升走 [FushiHoverLift]。
///
/// 刻意**不做文件 IO**：[cover] 由调用方传入（`ShelfFileCover` / 占位图 / 网络图
/// 都行），卡片本身是纯 widget、可 widget-test，也不与封面来源耦合。
///
/// 树结构恒定：选中 / 多选只换值，不按设计系统增删包装层。
class GalgamePosterCard extends StatelessWidget {
  const GalgamePosterCard({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.subtitleIcon,
    this.subtitleTone = ShelfMetaTone.normal,
    this.progress,
    this.completed = false,
    this.stackedCovers,
    this.selected = false,
    this.multiSelected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.semanticLabel,
    this.focusId,
  });

  /// 封面 widget（在卡盒内窗里按 1:1.6 裁剪；建议 `fit: BoxFit.cover`）。
  final Widget cover;

  /// 标题（封面下方左对齐，一行省略，悬停显示全名）。
  final String title;

  /// 副行：游玩时长 / 游玩状态 / 排序值 / 下载状态等原先压在封面上的信息。
  final String? subtitle;

  /// 副行前导图标（如在途下载的「外部来源」、串流的「运行中」）。
  final IconData? subtitleIcon;

  /// 副行语气（警示 / 错误换色）。
  final ShelfMetaTone subtitleTone;

  /// 文字块底部进度条（0–1）；null = 不画（仍占位，网格逐行对齐）。
  final double? progress;

  /// 进度条换完成色（已通关）。
  final bool completed;

  /// 合集折叠卡：[cover] 之后的成员封面（近 → 远，最多取 3 张）。材质下画成
  /// 扇形（[ShelfCoverPile]）；墨水屏退回共享叠层。null = 单张封面。
  final List<Widget>? stackedCovers;

  /// 选中态（当前详情 / 焦点）：封面上画选中罩（主色细环 + 淡色罩）。
  final bool selected;

  /// 批量多选态：封面左上角勾选圈（与书架 / 视频库同一枚）。
  final bool multiSelected;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右键（桌面）→ 一般用于打开详情菜单。
  final VoidCallback? onSecondaryTap;

  final String? semanticLabel;

  /// 焦点站点 id（手柄/键盘导航）。传入时注册到 [FushiFocusRoot]，`Enter`/A 键
  /// 触发 [onTap]。库页靠它保持 `game-card-<id>` 焦点站点可被 requestById 聚焦。
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    // 悬停抬升交给共享的 [FushiHoverLift]（书架 / 漫画 / 视频库同一套，自带墨水屏
    // 与「减弱动态效果」降级）；封面框经 [FushiHoverLift.liftedOf] 自己扫光 / 加深投影。
    final ShelfCoverMaterial? material = shelfCoverMaterialOf(context);
    final BorderRadius radius = material == null
        ? galgameCoverRadius(context)
        : shelfMaterialRadius(material);
    return ShelfCoverRadiusScope(
      radius: radius,
      child: FushiHoverLift(
        builder: (BuildContext context, bool _) => _buildCard(context, radius),
      ),
    );
  }

  Widget _buildCard(BuildContext context, BorderRadius radius) {
    final List<Widget>? behind = stackedCovers;
    final bool stacked = behind != null && behind.isNotEmpty;
    final Widget coverBox = AspectRatio(
      aspectRatio: kShelfGameCaseAspectRatio,
      child: ShelfCoverSelection(
        selectionMode: multiSelected,
        selected: selected || multiSelected,
        child: ShelfCoverFrame(
          // 材质下用成员封面排扇形；墨水屏（无材质）退回共享叠层，叠层只需要
          // 一张「后面那本」的图。
          stackedCovers: stacked ? behind.take(3).toList() : null,
          stackedBehind: stacked ? behind.first : null,
          child: cover,
        ),
      ),
    );

    final Widget card = shelfCoverCard(
      focusId: focusId,
      borderRadius: radius,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Flexible(child: coverBox),
          // BUG-1184：文字块随文字缩放变高（[ShelfCardMeta.heightFor]），与网格
          // 行高同一个公式；封面在 [Flexible] 里，放不下时等量压缩封面而不是裁字。
          SizedBox(
            height: ShelfCardMeta.heightFor(context),
            child: ShelfCardMeta(
              title: title,
              subtitle: subtitle,
              leadingIcon: subtitleIcon,
              tone: subtitleTone,
              progress: progress,
              completed: completed,
            ),
          ),
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
}

/// 游戏封面圆角（游戏海报卡 / 「继续游戏」横版卡 / 游戏库列表行缩略图共用）。
///
/// M3E：卡片档 20（[FushiM3eShape.cardRadius]）——游戏包装图是整块 key art，
/// 比书封 / 视频海报（12）大一档圆角读作「卡」而不是「图」。Apple 设计系统与
/// 墨水屏沿用共享封面规则（[shelfCoverRadius]：Apple 10 / 墨水屏 12）。
BorderRadius galgameCoverRadius(BuildContext context) {
  if (isEinkTheme(context) || isGlassDesign(context)) {
    final bool apple = isGlassDesign(context) && !isEinkTheme(context);
    return BorderRadius.all(Radius.circular(apple ? 10 : 12));
  }
  return FushiM3eShape.cardRadius;
}
