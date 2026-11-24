import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiSheetHeaderActionScope;

/// 对话框 / sheet 动作的语义角色，由 [FushiSheetAction] 标在动作按钮上。
enum FushiSheetActionRole {
  /// 取消 / 关闭：iOS sheet 导航栏左端（`.cancellationAction`）。
  cancel,

  /// 主操作（导入 / 添加 / 开始）：iOS sheet 导航栏右端
  /// （`.confirmationAction`）。
  confirm,

  /// 其余动作：iOS sheet 里排进内容区底部（导航栏只放取消与主操作）。
  other,
}

/// 给一枚对话框动作按钮标上语义角色（[FushiSheetActionRole]），让外框按设计
/// 系统决定它排在哪里：MD3 / macOS 档仍是底部按钮区（本组件原样返回
/// [child]，像素与焦点一字不差），iOS 档 sheet 把取消放导航栏左端、主操作放
/// 右端、其余放内容区。纯标记，与设计系统无关——外观由 [child] 自己的
/// 设计系统分派决定。
class FushiSheetAction extends StatelessWidget {
  const FushiSheetAction({required this.role, required this.child, super.key});

  const FushiSheetAction.cancel({required this.child, super.key})
    : role = FushiSheetActionRole.cancel;

  const FushiSheetAction.confirm({required this.child, super.key})
    : role = FushiSheetActionRole.confirm;

  const FushiSheetAction.other({required this.child, super.key})
    : role = FushiSheetActionRole.other;

  final FushiSheetActionRole role;
  final Widget child;

  /// [widget] 标的角色；没标返回 null。
  static FushiSheetActionRole? roleOf(Widget widget) =>
      widget is FushiSheetAction ? widget.role : null;

  @override
  Widget build(BuildContext context) => child;
}

/// [FushiSheetAction] 排成 iOS sheet 导航栏的结果。
@immutable
class FushiSheetActionLayout {
  const FushiSheetActionLayout({
    required this.cancel,
    required this.confirm,
    required this.others,
  });

  /// 导航栏左端（取消 / 关闭）。
  final Widget? cancel;

  /// 导航栏右端（主操作）。
  final Widget? confirm;

  /// 排进内容区的其余动作（按原顺序）。
  final List<Widget> others;

  /// 按角色拆分 [actions]：第一个 cancel 进左端、最后一个 confirm 进右端，
  /// 其余（含多出来的 cancel / confirm）进 [others]。一个都没标角色时按
  /// 「取消在前、主操作在最右」的按钮区约定拆：只有一个动作时它是取消，
  /// 两个及以上时首个是取消、末个是主操作，中间的进 [others]。
  static FushiSheetActionLayout split(List<Widget> actions) {
    final bool anyRole = actions.any(
      (Widget w) => FushiSheetAction.roleOf(w) != null,
    );
    if (!anyRole) {
      if (actions.isEmpty) {
        return const FushiSheetActionLayout(
          cancel: null,
          confirm: null,
          others: <Widget>[],
        );
      }
      if (actions.length == 1) {
        return FushiSheetActionLayout(
          cancel: actions.first,
          confirm: null,
          others: const <Widget>[],
        );
      }
      return FushiSheetActionLayout(
        cancel: actions.first,
        confirm: actions.last,
        others: actions.sublist(1, actions.length - 1),
      );
    }
    final int cancelIndex = actions.indexWhere(
      (Widget w) => FushiSheetAction.roleOf(w) == FushiSheetActionRole.cancel,
    );
    final int confirmIndex = actions.lastIndexWhere(
      (Widget w) => FushiSheetAction.roleOf(w) == FushiSheetActionRole.confirm,
    );
    return FushiSheetActionLayout(
      cancel: cancelIndex < 0 ? null : actions[cancelIndex],
      confirm: confirmIndex < 0 ? null : actions[confirmIndex],
      others: <Widget>[
        for (int i = 0; i < actions.length; i++)
          if (i != cancelIndex && i != confirmIndex) actions[i],
      ],
    );
  }
}

/// iOS 27 sheet 的导航栏头部（Apple 设计系统 iOS 档专用）：左端取消 / 关闭、
/// 中间居中标题（17 semibold label）、右端主操作，两端按钮经
/// [FushiSheetHeaderActionScope] 画成导航栏玻璃胶囊（取消 = 无色玻璃，主操作
/// = 强调色 `.glassProminent`，禁用褪灰）。[subtitle] 是导航栏下方一行居中
/// 的 footnote 说明（iOS 不在导航栏里放长说明）。
///
/// 只给 Apple 设计系统的窄屏（`!fushiAppleUsesMacMetrics`）用；MD3 与 macOS
/// 档的对应物是 `FushiModalSheetFrame` 的左对齐标题 + 底部按钮区，不经本组件。
/// 焦点：两端按钮是普通可聚焦按钮（方向键 / Tab 可达，Enter / 手柄 A 激活），
/// 在遍历顺序上先于正文；Esc 关闭由所在路由处理。
class FushiAppleSheetHeader extends StatelessWidget {
  const FushiAppleSheetHeader({
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    super.key,
  });

  final String? title;
  final String? subtitle;

  /// 左端（取消 / 关闭）。
  final Widget? leading;

  /// 右端（主操作）。
  final Widget? trailing;

  /// 导航栏内容高（iOS 按钮 44）。
  static const double barHeight = 44;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextTheme tt = Theme.of(context).textTheme;
    final String? head = title;
    final String? sub = subtitle;
    final Widget? lead = leading;
    final Widget? trail = trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: barHeight,
            child: NavigationToolbar(
              middleSpacing: 12,
              leading: lead == null
                  ? null
                  : FushiSheetHeaderActionScope(child: lead),
              middle: head == null
                  ? null
                  : Semantics(
                      header: true,
                      child: Text(
                        head,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: (tt.titleMedium ?? const TextStyle()).copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                          height: 1.3,
                          color: apple.label,
                        ),
                      ),
                    ),
              trailing: trail == null
                  ? null
                  : FushiSheetHeaderActionScope(child: trail),
            ),
          ),
          if (sub != null && sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Text(
                sub,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: (tt.bodySmall ?? const TextStyle()).copyWith(
                  fontSize: 13,
                  height: 1.35,
                  color: apple.secondaryLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
