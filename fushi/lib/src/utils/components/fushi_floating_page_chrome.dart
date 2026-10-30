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
/// （[UserScrollNotification]），不认程序滚动 / 视口尺寸变化；收起不改版面高度，
/// 页头收起 / 弹回不会改变正文视口而自激振荡。收起 / 出现走 M3E spatial 弹簧；墨水屏与「减弱动态
/// 效果」下瞬时切换。Apple 设计系统下收起 / 出现改走 `context.fushiMotion` 的
/// Apple 弹簧（临界阻尼，不过冲，见 [fushiAppleChromeSpatial]），标题不装胶囊
/// （iOS 26 / macOS 26 导航栏的内联标题是纯文字，玻璃只给栏上的控件）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/components/fushi_fill_slot.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show fushiAppleInlineSubtitleStyle, fushiAppleInlineTitleStyle;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart'
    show SmoothWheelScrollScope;

/// 悬浮页头胶囊的高：48 = M3E 小号图标按钮 40 + 上下 4（与
/// [kFushiFloatingToolbarCompactExtent] 一致）。
const double kFushiPageChromeExtent = kFushiFloatingToolbarCompactExtent;

/// Apple 设计系统里 chrome（栏 / 工具组）显隐与换组的位移弹簧：刚度取
/// `context.fushiMotion` 的 spatial default（SwiftUI `.snappy` 的感知时长），
/// 阻尼比钉 1——iOS 26 的导航栏 / 工具栏收起、弹回不过冲、不回弹。降级开关
/// 随方案一起带过来（[FushiSpringSpec.enabled]）。只在 [isGlassDesign] 为真时调用。
FushiSpringSpec fushiAppleChromeSpatial(BuildContext context) {
  final FushiSpringSpec spatial = context.fushiMotion.spatialDefault;
  return FushiSpringSpec(
    dampingRatio: 1,
    stiffness: spatial.stiffness,
    enabled: spatial.enabled,
  );
}

/// chrome 显隐的位移弹簧：MD3 用调用方给的 M3E 弹簧 [material]（保留轻微回弹
/// 落位），Apple 用 [fushiAppleChromeSpatial]。
SpringDescription fushiChromeRevealSpring(
  BuildContext context,
  SpringDescription material,
) => isGlassDesign(context)
    ? fushiAppleChromeSpatial(context).description
    : material;

/// chrome 显隐的透明度弹簧（effects，临界阻尼）：MD3 = M3E default effects，
/// Apple = Apple 方案的 effects default（SwiftUI `.smooth` 短档）。
SpringDescription fushiChromeRevealFadeSpring(BuildContext context) =>
    isGlassDesign(context)
    ? context.fushiMotion.effectsDefault.description
    : FushiSprings.effectsDefault.description;

/// 悬浮页头胶囊的底色（standard 面：surfaceContainer）。
Color fushiPageChromeColor(BuildContext context) =>
    fushiFloatingToolbarPalette(context).container;

/// 悬浮页头胶囊里的前景色。
Color fushiPageChromeForeground(BuildContext context) =>
    fushiFloatingToolbarPalette(context).foreground;

/// 返回 / 关闭 / 抽屉键的圆形悬浮胶囊（[kFushiPageChromeExtent] 直径）。子组件
/// 是一枚图标按钮，原样挂进去，经 [FushiFillSlot] 撑满整枚圆：悬停 / 按下的
/// state layer 与命中区就是这枚圆，不再是中间一枚更小的圆 / 方块。
class FushiPageChromeCircle extends StatelessWidget {
  const FushiPageChromeCircle({required this.child, super.key});

  final Widget child;

  // 顶部浮动胶囊统一按 [kFushiFloatingCapsuleScale] 缩（外层已缩过时不叠加）。
  @override
  Widget build(BuildContext context) =>
      FushiCapsuleScale(child: _buildChrome(context));

  Widget _buildChrome(BuildContext context) {
    return SizedBox.square(
      dimension: kFushiPageChromeExtent,
      child: FushiFloatingPill(
        color: fushiPageChromeColor(context),
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
        child: IconTheme.merge(
          data: IconThemeData(color: fushiPageChromeForeground(context)),
          child: FushiFillSlot.wrap(
            extent: const Size.square(kFushiPageChromeExtent),
            shape: const CircleBorder(),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// [child] 是否是一颗「只有图标」的按钮（可装进 [FushiPageChromeCircle]）。
bool fushiIsChromeIconButton(Widget child) =>
    child is FushiIconButtonControl ||
    child is IconButton ||
    child is BackButton ||
    child is CloseButton ||
    child is PopupMenuButton ||
    child is FushiIconButton;

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

/// 一枚悬浮胶囊：标题胶囊 / 动作按钮组胶囊共用。高恒为
/// [kFushiPageChromeExtent]（与返回圆、库页页签胶囊、按钮组同高），内容竖向居中。
///
/// 高度是**定值**而不是「至少」：页头槽位（AppBar toolbar 56、收起标题行、页头
/// 工具条）都按 [kFushiPageChromeExtent] 排，胶囊一旦比它高就会被槽位的
/// ClipRect 截掉下半截（下圆角消失、底边成一条直线）。[padding] 只取横向；
/// 竖向空间由定高 + 居中给出，不叠加在高度上。
class FushiPageChromeCapsule extends StatelessWidget {
  const FushiPageChromeCapsule({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  // 顶部浮动胶囊统一按 [kFushiFloatingCapsuleScale] 缩（外层已缩过时不叠加）。
  @override
  Widget build(BuildContext context) =>
      FushiCapsuleScale(child: _buildChrome(context));

  Widget _buildChrome(BuildContext context) {
    final EdgeInsets resolved = padding.resolve(Directionality.of(context));
    return SizedBox(
      height: kFushiPageChromeExtent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: kFushiPageChromeExtent),
        child: FushiFloatingPill(
          color: fushiPageChromeColor(context),
          padding: EdgeInsets.only(left: resolved.left, right: resolved.right),
          child: IconTheme.merge(
            data: IconThemeData(color: fushiPageChromeForeground(context)),
            child: Align(
              widthFactor: 1,
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
/// Apple 设计系统下不装胶囊：iOS 26 / macOS 26 导航栏的内联标题是纯文字
/// （移动 17 / 桌面 15 semibold，label 色；副标题 secondaryLabel），高
/// [fushiAppleFloatingExtent]（不超过 [kFushiPageChromeExtent]，页头槽位照旧放得下）。
/// [title] 原样渲染（调用方给的 Text 照用），只经 [DefaultTextStyle] 供默认字阶。
/// 单行省略、竖向居中；行高固定（[_kTitleLineHeight] + 强制 strut），字阶 /
/// 调用方 TextStyle 的行高都撑不高胶囊。
class FushiPageChromeTitle extends StatelessWidget {
  const FushiPageChromeTitle({required this.title, super.key, this.subtitle});

  final Widget title;
  final Widget? subtitle;

  /// 标题行的固定行高倍数（字号 × 1.2）。
  static const double _kTitleLineHeight = 1.2;

  /// 标题胶囊里的标题字阶。
  static TextStyle titleStyleOf(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.onSurface,
      height: _kTitleLineHeight,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// 把一行文字的行盒钉死在 `fontSize × height`：[forceStrutHeight] 让调用方
  /// Text 自带的 height / 字体度量都不再改变行盒高度。
  static Widget _fixedLine(Widget child, TextStyle style) {
    return DefaultTextStyle.merge(
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textHeightBehavior: const TextHeightBehavior(
        leadingDistribution: TextLeadingDistribution.even,
      ),
      child: _StrutScope(
        strut: StrutStyle.fromTextStyle(
          style,
          height: style.height ?? _kTitleLineHeight,
          leadingDistribution: TextLeadingDistribution.even,
          forceStrutHeight: true,
        ),
        child: child,
      ),
    );
  }

  /// 胶囊内留给文字行的竖向空间：定高减 2px 余量（描边 / 抗锯齿取整）。
  static const double _kTextBudget = kFushiPageChromeExtent - 2;

  /// 副标题行的固定行高倍数。
  static const double _kSubtitleLineHeight = 1.25;

  /// 副标题能否与标题同在定高胶囊里排两行。
  ///
  /// HBK-AUDIT-007：两行都跟随系统字体缩放，默认约 41px，1.3 倍时约 54px，
  /// 超出 [kFushiPageChromeExtent]。胶囊不能长高（BUG-2977：页头槽位按定高排，
  /// 长高就被 ClipRect 截掉下半截），所以空间不足时副标题降级成标题的 tooltip /
  /// 语义补充，而不是溢出。
  @visibleForTesting
  static bool subtitleFits({
    required TextScaler textScaler,
    required double titleFontSize,
    required double subtitleFontSize,
  }) {
    final double needed =
        textScaler.scale(titleFontSize) * _kTitleLineHeight +
        textScaler.scale(subtitleFontSize) * _kSubtitleLineHeight;
    return needed <= _kTextBudget;
  }

  /// 标题单行在定高胶囊里能承受的最大缩放倍数。
  ///
  /// 与 Material [AppBar] 给标题夹紧字体缩放（`_kMaxTitleTextScaleFactor`）同一
  /// 做法，但上限按胶囊实际空间算（titleLarge 约 1.8 倍），远高于 AppBar 的
  /// 1.34；系统字体缩放照常生效，只是在定高页头里封顶到不溢出为止。
  @visibleForTesting
  static double maxTitleScaleFactor(double titleFontSize) =>
      _kTextBudget / (titleFontSize * _kTitleLineHeight);

  /// Apple 内联标题的字阶（iOS 26 bar title 17 / macOS 26 窗口标题 15，semibold）。
  static TextStyle _appleTitleStyle(BuildContext context) {
    return fushiAppleInlineTitleStyle(context).copyWith(
      height: _kTitleLineHeight,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  // 顶部浮动胶囊统一按 [kFushiFloatingCapsuleScale] 缩（外层已缩过时不叠加）。
  @override
  Widget build(BuildContext context) =>
      FushiCapsuleScale(child: _buildChrome(context));

  Widget _buildChrome(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final TextStyle subtitleStyle = apple
        ? fushiAppleInlineSubtitleStyle(context).copyWith(
            height: _kSubtitleLineHeight,
            leadingDistribution: TextLeadingDistribution.even,
          )
        : (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: _kSubtitleLineHeight,
            leadingDistribution: TextLeadingDistribution.even,
          );
    final TextStyle titleStyle = apple
        ? _appleTitleStyle(context)
        : titleStyleOf(context);
    final double titleFontSize = titleStyle.fontSize ?? 14;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final bool showSubtitle =
        subtitle != null &&
        subtitleFits(
          textScaler: scaler,
          titleFontSize: titleFontSize,
          subtitleFontSize: subtitleStyle.fontSize ?? 12,
        );
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fixedLine(title, titleStyle),
        if (showSubtitle) _fixedLine(subtitle!, subtitleStyle),
      ],
    );
    final Widget? demoted = showSubtitle ? null : subtitle;
    if (demoted != null) {
      // 副标题放不下：信息不丢——悬停 / 长按看完整副标题，读屏仍读到它。
      final String? text = demoted is Text ? demoted.data : null;
      final InlineSpan? span = demoted is Text ? demoted.textSpan : null;
      content = FushiTooltip(
        message: text,
        richMessage: text == null ? (span ?? WidgetSpan(child: demoted)) : null,
        child: content,
      );
    }
    final Widget scaled = MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxTitleScaleFactor(titleFontSize),
      child: content,
    );
    if (apple) {
      return SizedBox(
        height: fushiAppleFloatingExtent(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Align(
            widthFactor: 1,
            alignment: AlignmentDirectional.centerStart,
            child: scaled,
          ),
        ),
      );
    }
    return FushiPageChromeCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: scaled,
    );
  }
}

/// 给子树里没显式写 strutStyle 的 [Text] 下发固定行盒：[Text] 不读继承的
/// strut，所以这里把子 [Text] 换成带 [strut] 的同一份 [Text]；其它 widget
/// 原样返回（它们自己负责行高）。
class _StrutScope extends StatelessWidget {
  const _StrutScope({required this.strut, required this.child});

  final StrutStyle strut;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Widget current = child;
    if (current is! Text || current.strutStyle != null) return current;
    if (current.textSpan != null) {
      return Text.rich(
        current.textSpan!,
        key: current.key,
        style: current.style,
        strutStyle: strut,
        textAlign: current.textAlign,
        textDirection: current.textDirection,
        locale: current.locale,
        softWrap: current.softWrap,
        overflow: current.overflow,
        textScaler: current.textScaler,
        maxLines: current.maxLines,
        semanticsLabel: current.semanticsLabel,
        semanticsIdentifier: current.semanticsIdentifier,
        textWidthBasis: current.textWidthBasis,
        textHeightBehavior: current.textHeightBehavior,
        selectionColor: current.selectionColor,
      );
    }
    return Text(
      current.data!,
      key: current.key,
      style: current.style,
      strutStyle: strut,
      textAlign: current.textAlign,
      textDirection: current.textDirection,
      locale: current.locale,
      softWrap: current.softWrap,
      overflow: current.overflow,
      textScaler: current.textScaler,
      maxLines: current.maxLines,
      semanticsLabel: current.semanticsLabel,
      semanticsIdentifier: current.semanticsIdentifier,
      textWidthBasis: current.textWidthBasis,
      textHeightBehavior: current.textHeightBehavior,
      selectionColor: current.selectionColor,
    );
  }
}

/// 驱动页头的「主滚动区」深度：见过的最浅竖向 [ScrollUpdateNotification] 所在的
/// [Notification] 深度（同首页浮动栏 [FushiFloatingChromeController] 的 `_ownerDepth`）。
///
/// 只拿来过滤 [ScrollMetricsNotification]：嵌套的竖向小列表（shrinkWrap + 禁止滚动）
/// 第一次布局也发它，且自身位置恒为 0。不按深度过滤，用户往下滚、懒加载出这样一个
/// 嵌套列表的那一帧就被当成「主列表回到了顶部」，页头 / 遮罩 / 标题跟着弹回。
class FushiScrollOwnerDepth {
  int? _depth;

  /// 记下一条竖向滚动更新的深度（只往浅处改）。
  void claim(ScrollUpdateNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return;
    final int? depth = _depth;
    if (depth == null || notification.depth < depth) {
      _depth = notification.depth;
    }
  }

  /// 这条版面修正通知来自主滚动区（或更外层）。还没见过滚动时只认最外层。
  bool owns(ScrollMetricsNotification notification) =>
      notification.depth <= (_depth ?? 0);
}

/// 子树里的滚动区不驱动页头收起：并排各自滚动的多栏正文（宽窗表单两栏）用。
///
/// 页头只有一条，却有两个互不相干的滚动位置：长的那栏滚下去把页头收掉，短的
/// 那栏停在顶部、没有「往回滚」可做，页头（含返回键）就再也叫不回来。
/// 遮罩 / 标题淡入等其它滚动监听不受影响。
class FushiPinnedPageChromeScope extends InheritedWidget {
  const FushiPinnedPageChromeScope({super.key, required super.child});

  /// [context] 是否在钉住页头的作用域里（不建立依赖，滚动通知路径上调用）。
  static bool pins(BuildContext? context) =>
      context?.getInheritedWidgetOfExactType<FushiPinnedPageChromeScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiPinnedPageChromeScope oldWidget) => false;
}

/// 页头「随滚动收起」的状态：内容被用户往下滚（看后面的内容）时收起，往回滚或
/// 回到顶部时出现。焦点进入页头时由 [FushiScrollAwayChrome] 主动叫出。
/// [FushiPinnedPageChromeScope] 里的滚动区不参与。
class FushiScrollAwayController extends ChangeNotifier {
  /// 内容至少滚过这么多（逻辑 px）才允许收起：刚开始滚的一小段不收，避免
  /// 短页面一碰就把页头收掉。
  static const double revealZone = 56;

  /// 收起 / 叫出所需的**同向累计**滚动距离（滞回）。手指拖动时总带几 px 的
  /// 来回抖动，旧实现按方向一变就切换，Android 上页头在一次滑动里来回跳
  /// （2026-10-09 用户反馈「顶栏来回跳、太容易触发」）。与首页外壳的
  /// [FushiFloatingChromeController] 同一阈值。
  static const double toggleDistance = 24;

  bool _hidden = false;
  ScrollDirection _userDirection = ScrollDirection.idle;
  final FushiScrollOwnerDepth _owner = FushiScrollOwnerDepth();

  /// 当前方向上累计的用户滚动位移：正 = 往下看（内容上移），负 = 往回。
  /// 方向一反就清零重新攒。
  double _travel = 0;

  /// 页头当前是否收起。
  bool get hidden => _hidden;

  set hidden(bool value) {
    _travel = 0;
    if (_hidden == value) return;
    _hidden = value;
    notifyListeners();
  }

  /// 叫出页头（焦点进入、页面主动要求时）。
  void show() => hidden = false;

  /// 喂滚动通知；永远返回 false（不拦截冒泡）。只认竖向滚动。
  ///
  /// 只累计**用户发起**的位移：拖动（带 dragDetails 的更新，含松手后的惯性）
  /// 与滚轮（[UserScrollNotification] 标了方向的那一段，到 [ScrollEndNotification]
  /// 为止）。程序滚动（jumpTo / animateTo / 平滑滚轮的补间）不动页头。
  bool handleNotification(Notification notification) {
    // 平滑滚轮补间的「拉回起点」不是用户滚动（[SmoothWheelScrollScope.isRewinding]）。
    if (SmoothWheelScrollScope.isRewinding) return false;
    // 版面修正（列表缩短 / 视口变高把位置夹回顶部）只发 ScrollMetricsNotification、
    // 不发 ScrollUpdate：不在这里叫出页头，它会停在收起态而正文已滚不动，用户
    // 再也唤不回来（同库页 BUG-3133）。
    if (notification is ScrollMetricsNotification) {
      final ScrollMetrics metrics = notification.metrics;
      if (metrics.axis == Axis.vertical &&
          _owner.owns(notification) &&
          metrics.extentBefore <= 0) {
        hidden = false;
      }
      return false;
    }
    if (notification is! ScrollNotification) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (FushiPinnedPageChromeScope.pins(notification.context)) {
      hidden = false;
      return false;
    }
    if (notification is UserScrollNotification) {
      if (notification.direction != _userDirection) _travel = 0;
      _userDirection = notification.direction;
      return false;
    }
    if (notification is ScrollEndNotification) {
      _userDirection = ScrollDirection.idle;
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    _owner.claim(notification);
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.extentBefore <= 0) {
      hidden = false;
      return false;
    }
    final bool userDriven =
        notification.dragDetails != null ||
        _userDirection != ScrollDirection.idle;
    if (!userDriven || metrics.outOfRange) return false;
    final double delta = notification.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (_travel != 0 && delta.sign != _travel.sign) _travel = 0;
    _travel += delta;
    if (_travel >= toggleDistance && metrics.extentBefore > revealZone) {
      hidden = true;
    } else if (_travel <= -toggleDistance) {
      hidden = false;
    }
    return false;
  }
}

/// 把页头装进「随滚动收起」的外壳：收起 = 上移淡出（M3E spatial 弹簧），出现
/// 反之；占位高度不变（不改正文视口，见 build 注释）。收起时不吃指针；焦点仍可遍历进来，一进来就把页头叫出——
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
    with TickerProviderStateMixin {
  // 1 = 完全可见，0 = 收起。MD3 出现带一点回弹落位（default spatial 偏软），
  // 收起同一弹簧；Apple 走临界阻尼的 Apple 弹簧（[fushiChromeRevealSpring]）。
  // 首次访问在 build 里（可读设计系统）。
  late final FushiSpring _shown = FushiSpring(
    vsync: this,
    initial: widget.controller.hidden ? 0 : 1,
    spring: fushiChromeRevealSpring(
      context,
      SpringDescription.withDampingRatio(mass: 1, stiffness: 520, ratio: 0.86),
    ),
  );

  /// 透明度：effects 弹簧（临界阻尼、不过冲）。透明度是 effects 属性，不跟位移
  /// 共用上面的 spatial 弹簧（HBK-AUDIT-023）；同目标、同一降级开关。
  late final FushiSpring _fade = FushiSpring(
    vsync: this,
    initial: widget.controller.hidden ? 0 : 1,
    spring: fushiChromeRevealFadeSpring(context),
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
    final bool animate =
        fushiExpressiveMotionEnabled(context) && fushiMotionEnabled(context);
    final double target = widget.controller.hidden ? 0 : 1;
    _shown.animateTo(target, animate: animate);
    _fade.animateTo(target, animate: animate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _shown.dispose();
    _fade.dispose();
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
        animation: Listenable.merge(<Listenable>[
          _shown.animation,
          _fade.animation,
        ]),
        child: FushiCapsuleScale(child: widget.child),
        builder: (BuildContext context, Widget? child) {
          final double v = widget.enabled ? _shown.value : 1;
          final double factor = v.clamp(0.0, 1.0);
          final double opacity = widget.enabled
              ? _fade.value.clamp(0.0, 1.0)
              : 1;
          final bool hidden = factor < 0.5;
          // 只做位移 + 淡出，**版面高度恒定**：曾经用 heightFactor 把高度收到 0，
          // 页头在 [FushiPageScaffold] 里与正文竖排，收起 / 弹回改变正文视口
          // 高度 → 滚动位置被夹紧（内容只比视口略长时直接夹回顶部）、内容跳动 →
          // 又触发弹回 / 收起，滚轮上下都「回弹、滚不动」。
          return ExcludeSemantics(
            excluding: factor <= 0.001,
            child: IgnorePointer(
              ignoring: hidden,
              child: Opacity(
                opacity: opacity,
                child: Transform.translate(
                  offset: Offset(0, (1 - v) * -12),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
