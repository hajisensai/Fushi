/// 「唤出上下文菜单（右键菜单）」这件事的**唯一**触发口。
///
/// 改造前的形状：二十余处 `GestureDetector.onSecondaryTap*` 各自硬绑鼠标右键，
/// 而鼠标绑定通道（`mouse_binding_dispatch.dart`）是另一条完全不知情的路。于是右键
/// 这个物理按钮有**两个**互不知情的消费者：用户在设置里把任意动作绑到右键，一次按下
/// 会同时触发那个动作**和**右键菜单——这不是某一个页面的 bug，是「按钮归属没有唯一
/// 仲裁者」这个数据结构缺陷在每个表面上的同一次显形。
///
/// 修法不是在每个入口加一条「右键被占用了吗」的判断（那是把同一个特殊情况抄二十遍），
/// 而是把菜单本身**纳入绑定表**：[ShortcutAction.globalContextMenu] 默认绑鼠标右键，
/// 各表面按自己的解析阶梯问一句「这次按下解析出来的是不是它」。于是：
///
///   · 谁都没改键 → 右键解析到 globalContextMenu → 菜单照弹（与改造前逐字一致）；
///   · 用户把右键绑给页面动作 → 阶梯里页面 scope 先命中 → 解析结果不是它 → 菜单
///     **自动让位**，用户不必先去解绑菜单（"快捷键可以共用，不强制取消另一个"）；
///   · 用户把菜单改绑到中键 / 侧键 → 那个键解析到 globalContextMenu → 菜单跟着走。
///
/// 让位由**解析阶梯的先后**决定，不是新引入的第二套优先级规则：阶梯就是键盘那条
/// 「页面专属优先、页面没接才轮到全局」在指针侧的既有同构（见 mouse_binding_dispatch）。
library;

import 'package:flutter/widgets.dart';

import 'package:fushi/src/shortcuts/input_binding.dart'
    show domMouseButtonFromPointerButtons;
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 拿不到绑定表时的回退按钮 = 右键（DOM `MouseEvent.button` 2）。
///
/// 「拿不到」只发生在没有 [ShortcutBindingScope] 的子树里：widget 测试直接挂卡片、
/// 或某个还没接线的宿主。此时行为退回改造前的硬绑右键——**默认行为免费**，不需要每个
/// 测试都去搭一份注册表，也不会出现「忘了挂 scope 就整片右键菜单失灵」。
const int kContextMenuFallbackButton = 2;

/// 非媒体表面（首页 / 书架 / 媒体库 / 设置 / 统计页…）的默认解析阶梯。
///
/// 与 `home_page` 的鼠标阶梯同源：页面 scope 在前、[ShortcutScope.global] 兜底
/// （[ShortcutAction.globalContextMenu] 就住在 global）。媒体页请显式传自己那条
/// （`kVideoMouseLadder` / `kReaderMouseLadder` / manga 的那条），否则「页面动作
/// 优先」这一半就丢了。
///
/// 为什么独立路由页（统计 / 标签 / 合集…）也带 [ShortcutScope.home]：那些页面确实
/// 不派发 home 动作，带上它属于**保守让位**——用户把右键绑给某个 home 动作后，这些
/// 页面会跟着不弹菜单。选这一侧是因为两类错误不对称：少弹一次菜单只是不便，而漏判
/// 让位就是本 bug 的原样复发（一次按下做两件事）。home scope 默认没有任何鼠标绑定，
/// 所以这条保守分支只在用户主动绑过之后才可能生效。
const List<ShortcutScope> kDefaultContextMenuLadder = <ShortcutScope>[
  ShortcutScope.home,
  ShortcutScope.global,
];

/// 把当前的快捷键注册表递给子树里的 [ContextMenuTrigger]。
///
/// 用 `getInheritedWidgetOfExactType` 读取（见 [maybeOf]）：**不建立依赖**，注册表
/// 变化不会让二十余处卡片跟着重建。判据只在指针按下的那一瞬间读一次，读的永远是当时
/// 的最新值，这与键盘 / 手柄两条通道的 press-time 解析（不冻结绑定表）完全同构。
class ShortcutBindingScope extends InheritedWidget {
  const ShortcutBindingScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final FushiShortcutRegistry registry;

  /// 子树里最近的一份注册表；没有就是 null（回退到 [kContextMenuFallbackButton]）。
  static FushiShortcutRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShortcutBindingScope>()?.registry;

  @override
  bool updateShouldNotify(ShortcutBindingScope oldWidget) =>
      !identical(oldWidget.registry, registry);
}

/// 这次按下是不是「唤出上下文菜单」。
///
/// [registry] 为 null 时回退成硬绑右键（见 [kContextMenuFallbackButton]）。按钮号折叠
/// 恒用 [domMouseButtonFromPointerButtons]——与设置页的按键录制、与其余鼠标绑定入口
/// **同一个函数**，否则会出现「设置里录到侧键、运行时按另一个号解析」的错位。左键在那里
/// 恒折不出按钮号，故菜单永远不可能被绑到左键，正常点击 / 划词 / 拖拽零影响。
bool contextMenuButtonMatches({
  required FushiShortcutRegistry? registry,
  required int buttons,
  required List<ShortcutScope> ladder,
}) {
  final int? button = domMouseButtonFromPointerButtons(buttons);
  if (button == null) return false;
  return contextMenuButtonNumberMatches(
    registry: registry,
    button: button,
    ladder: ladder,
  );
}

/// 与 [contextMenuButtonMatches] 同义，但入参是**已经折好的** DOM
/// `MouseEvent.button`（1=中键 / 2=右键 / 3=后退 / 4=前进）。
///
/// 供 WebView 宿主使用：漫画页那条路的按钮号是页内 JS 直接给的 `e.button`，本来就不是
/// Flutter 的 `buttons` 位掩码，再折一次会把 1 当成 `kPrimaryMouseButton` 折错——与
/// `mouse_binding_dispatch.dart` 里那对函数完全同因、同形。
bool contextMenuButtonNumberMatches({
  required FushiShortcutRegistry? registry,
  required int button,
  required List<ShortcutScope> ladder,
}) {
  if (button <= 0) return false;
  if (registry == null) return button == kContextMenuFallbackButton;
  return resolveMouseBindingActionForButton(
        registry: registry,
        button: button,
        ladder: ladder,
      ) ==
      ShortcutAction.globalContextMenu;
}

/// 把「不关心锚点坐标」的无参回调适配成 [ContextMenuTrigger.onInvoke]。
///
/// 多数卡片的菜单是长按菜单的同一份执行体（`showModalBottomSheet` / 对话框，自己居中
/// 定位），不需要按下处的坐标；需要锚点的表面（阅读器选区菜单、视频画面菜单、插图页）
/// 直接写 `(Offset p) => …` 即可。null 原样透传 = 此刻不提供菜单。
void Function(Offset)? contextMenuInvoker(VoidCallback? callback) =>
    callback == null ? null : (Offset _) => callback();

/// 包住任何「右键要弹菜单」的子树，替代硬绑右键的 `GestureDetector.onSecondaryTap*`。
///
/// [onInvoke] 传 null = 本表面此刻不提供菜单（多选模式等），整个触发器让路、连
/// [Listener] 都不挂（与旧代码 `onSecondaryTap: _selectionMode ? null : …` 同语义）。
///
/// 为什么是 [Listener] 而不是 [GestureDetector]：菜单现在可以绑到中键 / 侧键，而
/// `GestureDetector` 只有「次按钮（右键）」这一个非主键入口，绑到中键就永远收不到。
/// 代价是不进手势竞技场，故按下即触发（不等抬起）——app 内四个媒体表面里已有三个
/// （阅读器 / 漫画 / 字幕）用的就是 `onSecondaryTapDown`，这一步反而把剩下那个不一致
/// 也抹平了。右键不用于拖拽，按下即弹不会与滚动 / 框选竞争。
///
/// 认领走 [dispatchClaimedMouseAction]：与页面根、app 根的鼠标入口共用**同一个**单槽
/// 仲裁。卡片是更内层的 [Listener]，Flutter 的指针派发次序是 innermost → outermost，
/// 所以卡片先认领、外层看到已认领就让路——同一次按下绝不会既弹菜单又跑外层绑定。
class ContextMenuTrigger extends StatelessWidget {
  const ContextMenuTrigger({
    super.key,
    required this.onInvoke,
    required this.child,
    this.ladder = kDefaultContextMenuLadder,
    this.behavior = HitTestBehavior.translucent,
  });

  /// 弹菜单的执行体，入参是按下处的 global 坐标（`showMenu` 的锚点）。不需要锚点的
  /// 调用方忽略它即可。null = 此刻不提供菜单。
  final void Function(Offset globalPosition)? onInvoke;

  /// 本表面的鼠标解析阶梯。页面 scope 在前、global 兜底。
  final List<ShortcutScope> ladder;

  final HitTestBehavior behavior;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final void Function(Offset globalPosition)? invoke = onInvoke;
    if (invoke == null) return child;
    return Listener(
      behavior: behavior,
      onPointerDown: (PointerDownEvent event) {
        if (!contextMenuButtonMatches(
          registry: ShortcutBindingScope.maybeOf(context),
          buttons: event.buttons,
          ladder: ladder,
        )) {
          return;
        }
        dispatchClaimedMouseAction(event, () {
          invoke(event.position);
          return true;
        });
      },
      child: child,
    );
  }
}
