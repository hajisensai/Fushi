/// 普通页面（库页 / 二级页 / 工具页）的 **M3 Expressive 悬浮页头** 组件族。
///
/// 用户 2026-10-05「全部用浮动工具栏统一」：全应用的顶栏不再是整条实体栏，而是
/// 浮在内容上的几颗分离胶囊——返回键一枚圆胶囊、标题一枚胶囊、右侧动作收进一枚
/// 按钮组胶囊；页签条是一条分段胶囊轨道。沉浸式页面（阅读器 / 播放器）用的
/// [FushiFloatingTopBar] 只认「图标 + 文案」描述；本文件服务的是存量页面——
/// 它们的 leading / 标题 / actions 是任意 widget（菜单锚点、带 GlobalKey 的按钮、
/// 搜索框……），所以这里只提供「把任意子组件装进悬浮胶囊」的外壳，子组件原样
/// 挂进去，key / 焦点 / 语义 / 菜单锚点都不变。
///
/// 胶囊的形状与投影统一走 [FushiFloatingPill]（与阅读器悬浮工具栏同一份装饰），
/// 底色取 [fushiFloatingToolbarPalette] 的 standard 面：两边一眼就是同一套 chrome。
///
/// [FushiScrollAwayController] + [FushiScrollAwayChrome]：M3E 浮动工具栏「内容往下
/// 滚时收起、往回滚时出现」的行为——只认用户发起的滚动方向
/// （[UserScrollNotification]），不认程序滚动 / 视口尺寸变化，不会因为页头收起
/// 让视口变高而自激振荡。收起 / 出现走 M3E spatial 弹簧；墨水屏与「减弱动态
/// 效果」下瞬时切换。只服务 Material 设计系统；Apple 设计系统的页头保持既有的
/// 玻璃形态。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;

/// 悬浮页头胶囊的高：48 = M3E 小号图标按钮 40 + 上下 4（与
/// [kFushiFloatingToolbarCompactExtent] 一致）。
const double kFushiPageChromeExtent = kFushiFloatingToolbarCompactExtent;

/// 悬浮页头胶囊的底色（standard 面：surfaceContainer）。
Color fushiPageChromeColor(BuildContext context) =>
    fushiFloatingToolbarPalette(context).container;

/// 悬浮页头胶囊里的前景色。
Color fushiPageChromeForeground(BuildContext context) =>
    fushiFloatingToolbarPalette(context).foreground;

/// 返回 / 关闭 / 抽屉键的圆形悬浮胶囊（48 直径）。子组件是一枚图标按钮，
/// 原样挂进去。
class FushiPageChromeCircle extends StatelessWidget {
  const FushiPageChromeCircle({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: kFushiPageChromeExtent,
      child: FushiFloatingPill(
        color: fushiPageChromeColor(context),
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
        child: IconTheme.merge(
          data: IconThemeData(color: fushiPageChromeForeground(context)),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// 页头 leading 是图标按钮（返回 / 关闭 / 抽屉 / 自定义图标键）时装进
/// [FushiPageChromeCircle]；其它 leading（头像、品牌位……）原样返回。
Widget? fushiFloatingLeading(Widget? leading) {
  if (leading == null) return null;
  if (leading is FushiIconButton ||
      leading is FushiIconButtonControl ||
      leading is IconButton ||
      leading is BackButton ||
      leading is CloseButton) {
    return FushiPageChromeCircle(child: leading);
  }
  return leading;
}

/// 一枚悬浮胶囊：标题胶囊 / 动作按钮组胶囊共用。高至少
/// [kFushiPageChromeExtent]，内容竖向居中。
class FushiPageChromeCapsule extends StatelessWidget {
  const FushiPageChromeCapsule({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: kFushiPageChromeExtent,
        minWidth: kFushiPageChromeExtent,
      ),
      child: FushiFloatingPill(
        color: fushiPageChromeColor(context),
        padding: padding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kFushiPageChromeExtent),
          child: IconTheme.merge(
            data: IconThemeData(color: fushiPageChromeForeground(context)),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              alignment: AlignmentDirectional.centerStart,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面标题的悬浮胶囊：M3E Emphasized 字阶（titleLarge 加粗），可带一行副标题。
/// [title] 原样渲染（调用方给的 Text 照用），只经 [DefaultTextStyle] 供默认字阶。
class FushiPageChromeTitle extends StatelessWidget {
  const FushiPageChromeTitle({required this.title, super.key, this.subtitle});

  final Widget title;
  final Widget? subtitle;

  /// 标题胶囊里的标题字阶。
  static TextStyle titleStyleOf(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.onSurface,
      height: 1.2,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiPageChromeCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DefaultTextStyle.merge(
            style: titleStyleOf(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: title,
          ),
          if (subtitle != null)
            DefaultTextStyle.merge(
              style: (theme.textTheme.labelMedium ?? const TextStyle())
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: subtitle!,
            ),
        ],
      ),
    );
  }
}

/// 页头「随滚动收起」的状态：内容被用户往下滚（看后面的内容）时收起，往回滚或
/// 回到顶部时出现。焦点进入页头时由 [FushiScrollAwayChrome] 主动叫出。
class FushiScrollAwayController extends ChangeNotifier {
  /// 内容至少滚过这么多（逻辑 px）才允许收起：刚开始滚的一小段不收，避免
  /// 短页面一碰就把页头收掉。
  static const double revealZone = 56;

  bool _hidden = false;

  /// 页头当前是否收起。
  bool get hidden => _hidden;

  set hidden(bool value) {
    if (_hidden == value) return;
    _hidden = value;
    notifyListeners();
  }

  /// 叫出页头（焦点进入、页面主动要求时）。
  void show() => hidden = false;

  /// 喂滚动通知；永远返回 false（不拦截冒泡）。只认竖向滚动。
  bool handleNotification(Notification notification) {
    if (notification is UserScrollNotification) {
      if (notification.metrics.axis != Axis.vertical) return false;
      switch (notification.direction) {
        case ScrollDirection.reverse:
          if (notification.metrics.extentBefore > revealZone) hidden = true;
        case ScrollDirection.forward:
          hidden = false;
        case ScrollDirection.idle:
          break;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.metrics.axis == Axis.vertical &&
          notification.metrics.extentBefore <= 0) {
        hidden = false;
      }
    }
    return false;
  }
}

/// 把页头装进「随滚动收起」的外壳：收起 = 高度收到 0 + 上移淡出（M3E spatial
/// 弹簧），出现反之。收起时不吃指针；焦点仍可遍历进来，一进来就把页头叫出——
/// 键盘 / 手柄用户 Tab 到页头时不会落在一个看不见的按钮上。
class FushiScrollAwayChrome extends StatefulWidget {
  const FushiScrollAwayChrome({
    required this.controller,
    required this.child,
    super.key,
    this.enabled = true,
  });

  final FushiScrollAwayController controller;
  final Widget child;

  /// false 时恒显示（Apple 设计系统 / 调用方关掉收起）；树结构不变。
  final bool enabled;

  @override
  State<FushiScrollAwayChrome> createState() => _FushiScrollAwayChromeState();
}

class _FushiScrollAwayChromeState extends State<FushiScrollAwayChrome>
    with SingleTickerProviderStateMixin {
  // 1 = 完全可见，0 = 收起。出现带一点回弹落位（default spatial 偏软），收起
  // 同一弹簧。
  late final FushiSpring _shown = FushiSpring(
    vsync: this,
    initial: widget.controller.hidden ? 0 : 1,
    spring: SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: 520,
      ratio: 0.86,
    ),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void didUpdateWidget(FushiScrollAwayChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    if (!mounted) return;
    _shown.animateTo(
      widget.controller.hidden ? 0 : 1,
      animate:
          fushiExpressiveMotionEnabled(context) && fushiMotionEnabled(context),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool focused) {
        if (focused) widget.controller.show();
      },
      child: AnimatedBuilder(
        animation: _shown.animation,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          final double v = widget.enabled ? _shown.value : 1;
          final double factor = v.clamp(0.0, 1.0);
          final bool hidden = factor < 0.5;
          return ClipRect(
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: factor,
              child: IgnorePointer(
                ignoring: hidden,
                child: Opacity(
                  opacity: factor,
                  child: Transform.translate(
                    offset: Offset(0, (1 - v) * -12),
                    child: child,
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
