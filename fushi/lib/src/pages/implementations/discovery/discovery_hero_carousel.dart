/// 发现页首屏 Hero 轮播：把若干 [DiscoveryHeroBanner] 排成可左右切换的一组。
///
/// 书 / 漫画 / 视频 / 游戏各域的发现页都只经这一件放 Hero，切页能力一处补齐：
///
/// - **指针**：桌面悬停时右下角页码指示器两侧展开圆形箭头（触屏没有悬停，不画，
///   靠横滑）；
///   右下角页码指示器（胶囊里一排圆点，当前页拉长成药丸），点哪颗跳哪页。
/// - **拖动**：桌面默认 `dragDevices` 不含鼠标，这里显式放开鼠标 / 触控板拖动
///   （[HorizontalDragScrollable]）；横向滚轮 / 倾斜滚轮的横向 delta 也翻页。
/// - **键盘 / 手柄**：焦点在 Hero 里（「详情」按钮）时 ← / → 与 D-pad 左右切页；
///   已到首 / 末页则不认领，按键照常交给全局方向导航（不把焦点困在 Hero 里，
///   左边的导航栏照样走得到）。切页后焦点跟到新一页的按钮上。
/// - **自动轮播**：每页停 [DiscoveryHeroCarousel.autoAdvanceInterval] 自动前进；
///   悬停 / 焦点在内 / 页面不在前台（TickerMode 关）/ 减弱动态效果时暂停；
///   任何一次翻页（手动或自动）都重新计时。
///
/// 动效统一走 [FushiMotion]，墨水屏与「减弱动态效果」下瞬间到位。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_layout.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/components/fushi_carousel.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiTopFadeScrim;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 首屏 Hero 轮播。只有一页时不画任何切页控件，外观与单张横幅一致。
class DiscoveryHeroCarousel extends StatefulWidget {
  const DiscoveryHeroCarousel({
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.autoAdvanceInterval = kDiscoveryHeroAutoAdvanceInterval,
    super.key,
  });

  /// 页数（> 0）。
  final int itemCount;

  /// 第 i 页的横幅（通常是 [DiscoveryHeroBanner]）。
  final IndexedWidgetBuilder itemBuilder;

  /// 当前页变化（手动 / 自动 / 拖动都报）。
  final ValueChanged<int>? onPageChanged;

  /// 自动轮播间隔；null 关闭自动轮播。
  final Duration? autoAdvanceInterval;

  @override
  State<DiscoveryHeroCarousel> createState() => _DiscoveryHeroCarouselState();
}

/// 默认自动轮播间隔：够读完标题 + 两行简介，又不至于让人以为它是静态横幅。
const Duration kDiscoveryHeroAutoAdvanceInterval = Duration(seconds: 8);

/// 横向滚轮累计到多少逻辑像素翻一页（触控板一次轻扫约 50–150）。
const double _kWheelPageThreshold = 48;

class _DiscoveryHeroCarouselState extends State<DiscoveryHeroCarousel> {
  final PageController _controller = PageController();
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'discovery-hero-carousel',
    canRequestFocus: false,
    skipTraversal: true,
  );

  int _page = 0;
  bool _hovering = false;
  bool _focused = false;
  bool _animating = false;

  /// 程序化翻页（[_goTo]）的代次：新一次翻页打断旧动画时，旧调用的收尾不能把
  /// [_animating] 提前清掉、也不能再补报一次落点（由新调用负责）。
  int _goToSeq = 0;
  double _wheelAccumulated = 0;
  Timer? _autoTimer;

  bool get _multiPage => widget.itemCount > 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode / 减弱动态效果变化都会走到这里：重新判定要不要计时。
    _restartAutoAdvance();
  }

  @override
  void didUpdateWidget(covariant DiscoveryHeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != oldWidget.itemCount && _page >= widget.itemCount) {
      final int last = widget.itemCount - 1;
      _page = last < 0 ? 0 : last;
      if (_controller.hasClients) _controller.jumpToPage(_page);
    }
    if (widget.itemCount != oldWidget.itemCount ||
        widget.autoAdvanceInterval != oldWidget.autoAdvanceInterval) {
      _restartAutoAdvance();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _restartAutoAdvance() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final Duration? interval = widget.autoAdvanceInterval;
    if (interval == null ||
        !_multiPage ||
        _hovering ||
        _focused ||
        !TickerMode.of(context) ||
        !fushiMotionEnabled(context)) {
      return;
    }
    _autoTimer = Timer(interval, () {
      if (!mounted) return;
      unawaited(_goTo((_page + 1) % widget.itemCount));
    });
  }

  void _onPageChanged(int page) {
    // 程序化翻页途中 PageView 每越过一页都会报一次（0 → 3 回绕会报 1、2、3），
    // 中间页不是用户停留的页：不报给调用方（视频发现页会按它预取 Hero 详情）、
    // 不重置自动轮播，落点由 [_goTo] 收尾时补报。拖动 / 滚轮翻页不经此闸。
    if (_animating) return;
    if (page == _page) return;
    setState(() => _page = page);
    widget.onPageChanged?.call(page);
    _restartAutoAdvance();
  }

  /// 动画切到 [target]。[keepFocus]：焦点原本在 Hero 里（键盘 / 手柄翻页）时，
  /// 旧页的按钮随旧页卸载，切完把焦点交给新页的第一个可聚焦控件。
  Future<void> _goTo(int target, {bool keepFocus = false}) async {
    if (!_controller.hasClients || target == _page) return;
    if (target < 0 || target >= widget.itemCount) return;
    final bool hadFocus = keepFocus && _focusNode.hasFocus;
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    final int seq = ++_goToSeq;
    _animating = true;
    try {
      if (duration == Duration.zero) {
        _controller.jumpToPage(target);
      } else {
        await _controller.animateToPage(
          target,
          duration: duration,
          curve: FushiMotion.enter,
        );
      }
    } finally {
      if (seq == _goToSeq) _animating = false;
    }
    // 被更新的一次翻页打断：落点与焦点交给新调用收尾。
    if (!mounted || seq != _goToSeq) return;
    // 途中的越页通知被上面的闸挡掉了（被拖动打断时同理），这里按实际落点补报
    // 一次，_page 与调用方都只看到停下来的那一页。
    final double? position = _controller.page;
    if (position != null) _onPageChanged(position.round());
    if (!hadFocus) return;
    // 动画的最后一拍在帧的动画阶段结束，旧页要到同一帧的布局阶段才卸载：等这
    // 一帧走完再交接焦点，否则此刻焦点还挂在旧页按钮上、看起来「没丢」，随后
    // 旧页一卸载焦点就掉回外层作用域。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _focusCurrentPage();
  }

  /// 焦点不在当前页里时，交给当前页的第一个可聚焦控件（「详情」按钮）。
  void _focusCurrentPage() {
    final ValueKey<String> pageKey = _pageKey(_page);
    bool inCurrentPage(FocusNode node) {
      final BuildContext? context = node.context;
      if (context == null) return false;
      bool found = false;
      context.visitAncestorElements((Element ancestor) {
        found = ancestor.widget.key == pageKey;
        return !found;
      });
      return found;
    }

    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary != null && inCurrentPage(primary)) return;
    for (final FocusNode node in _focusNode.traversalDescendants) {
      if (node.canRequestFocus && inCurrentPage(node)) {
        node.requestFocus();
        return;
      }
    }
  }

  /// 第 [index] 页相对当前滚动位置的偏移（项序号 − 当前页，连续值）。
  double _offsetOf(int index) {
    if (_controller.hasClients && _controller.position.haveDimensions) {
      final double? page = _controller.page;
      if (page != null) return index - page;
    }
    return (index - _page).toDouble();
  }

  static ValueKey<String> _pageKey(int index) =>
      ValueKey<String>('discovery-hero-page-$index');

  /// 前进（+1）/ 后退（-1）一页，首尾回绕（箭头按钮用）。
  void _step(int delta) {
    final int count = widget.itemCount;
    if (count < 2) return;
    unawaited(_goTo((_page + delta + count) % count));
  }

  /// 逻辑方向（←/→ 在 RTL 下对调）换算成页号增量。
  int _deltaFor(bool towardRight) {
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return towardRight == rtl ? -1 : 1;
  }

  /// 键盘 / 手柄翻页：不回绕——到头不认领，按键交回全局方向导航。
  bool _canMove(int delta) {
    final int target = _page + delta;
    return _multiPage && target >= 0 && target < widget.itemCount;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final bool right = key == LogicalKeyboardKey.arrowRight;
    if (!right && key != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final int delta = _deltaFor(right);
    if (!_canMove(delta)) return KeyEventResult.ignored;
    unawaited(_goTo(_page + delta, keepFocus: true));
    return KeyEventResult.handled;
  }

  /// 横向滚轮 / 倾斜滚轮 / 发 scroll 信号的触控板：横向分量占优才认领，纵向
  /// 滚动照常交给外层页面。翻页动画期间吞掉后续惯性 delta，不连翻。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_multiPage) return;
    final Offset delta = event.scrollDelta;
    if (delta.dx == 0 || delta.dx.abs() <= delta.dy.abs()) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      PointerSignalEvent event,
    ) {
      if (_animating) {
        _wheelAccumulated = 0;
        return;
      }
      _wheelAccumulated += (event as PointerScrollEvent).scrollDelta.dx;
      if (_wheelAccumulated.abs() < _kWheelPageThreshold) return;
      final int delta = _deltaFor(_wheelAccumulated > 0);
      _wheelAccumulated = 0;
      if (_canMove(delta)) unawaited(_goTo(_page + delta));
    });
  }

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
    _restartAutoAdvance();
  }

  void _onFocusChange(bool focused) {
    if (_focused == focused) return;
    _focused = focused;
    _restartAutoAdvance();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = DiscoveryHeroBanner.heightFor(
          constraints.maxWidth,
        );
        final Widget pages = HorizontalDragScrollable(
          child: PageView.builder(
            key: const ValueKey<String>('discovery-hero-pages'),
            controller: _controller,
            itemCount: widget.itemCount,
            physics: _multiPage
                ? const PageScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            onPageChanged: _onPageChanged,
            itemBuilder: (BuildContext context, int index) => KeyedSubtree(
              key: _pageKey(index),
              child: Listener(
                onPointerSignal: _onPointerSignal,
                // M3E carousel：项按离当前页的距离收缩 / 压暗，背景图视差
                // （FushiParallax 在 DiscoveryHeroBackdrop 里读这份偏移）。
                child: AnimatedBuilder(
                  animation: _controller,
                  child: widget.itemBuilder(context, index),
                  builder: (BuildContext context, Widget? child) =>
                      FushiCarouselItemOffset(
                        offset: _offsetOf(index),
                        child: FushiCarouselItemTransform(child: child!),
                      ),
                ),
              ),
            ),
          ),
        );
        return Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: _HeroGamepadPageAction(this),
          },
          child: Focus(
            focusNode: _focusNode,
            onFocusChange: _onFocusChange,
            onKeyEvent: _onKeyEvent,
            child: MouseRegion(
              onEnter: (_) => _setHovering(true),
              onExit: (_) => _setHovering(false),
              child: SizedBox(
                height: height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: pages),
                    if (_multiPage)
                      // 与横幅卡片同一块区域（横幅外边距：两侧 page、顶 gap）。
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            tokens.spacing.page,
                            tokens.spacing.gap,
                            tokens.spacing.page,
                            0,
                          ),
                          child: _buildControls(context),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    // 箭头不压在横幅中部：宽屏横幅的标题 / 简介块从左侧 32 起排、纵向恰好跨过
    // 卡片中线，居中靠边的箭头会盖住「热门推荐」眉标（真实像素预览实测）。改为
    // 与页码指示器同一簇放在右下角：悬停时两枚箭头从指示器两侧展开，平时收起
    // 成零宽，指示器位置不变。
    Widget arrow({required bool next}) => ClipRect(
      child: AnimatedAlign(
        alignment: AlignmentDirectional.center,
        widthFactor: _hovering ? 1 : 0,
        duration: fade,
        curve: FushiMotion.standard,
        child: AnimatedOpacity(
          opacity: _hovering ? 1 : 0,
          duration: fade,
          curve: FushiMotion.standard,
          child: IgnorePointer(
            ignoring: !_hovering,
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: next ? 6 : 0,
                end: next ? 0 : 6,
              ),
              child: _HeroNavButton(
                key: ValueKey<String>(
                  next ? 'discovery-hero-next' : 'discovery-hero-previous',
                ),
                icon: next
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                label: next ? t.discovery_hero_next : t.discovery_hero_previous,
                onTap: () => _step(next ? 1 : -1),
              ),
            ),
          ),
        ),
      ),
    );
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 12, bottom: 6),
        child: SizedBox(
          height: _HeroNavButton.size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              arrow(next: false),
              _HeroPageIndicator(
                count: widget.itemCount,
                current: _page,
                onSelect: (int index) => unawaited(_goTo(index)),
              ),
              arrow(next: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面手柄轮询路径（`GamepadService._dispatchButton` 先向焦点处派发
/// [GamepadButtonIntent]）：D-pad 左右在 Hero 内切页。到头时 disabled，
/// [Actions.maybeInvoke] 继续往上找，最终落回通用方向焦点移动。
class _HeroGamepadPageAction extends Action<GamepadButtonIntent> {
  _HeroGamepadPageAction(this._state);

  final _DiscoveryHeroCarouselState _state;

  int? _deltaOf(GamepadButtonIntent intent) => switch (intent.button) {
    GamepadButton.dpadLeft => _state._deltaFor(false),
    GamepadButton.dpadRight => _state._deltaFor(true),
    _ => null,
  };

  @override
  bool isEnabled(GamepadButtonIntent intent) {
    final int? delta = _deltaOf(intent);
    return _state.mounted && delta != null && _state._canMove(delta);
  }

  @override
  Object? invoke(GamepadButtonIntent intent) {
    final int delta = _deltaOf(intent)!;
    unawaited(_state._goTo(_state._page + delta, keepFocus: true));
    return true;
  }
}

/// 页码指示器两侧的圆形切页箭头。不进焦点遍历（键盘 / 手柄用方向键切页，不再多
/// 占两个停靠点）。MD3：深色半透明圆底 + 白色图标（与 Hero 白字同一套）；
/// Apple：透明玻璃圆钮（与 Hero 上的 prominent 玻璃按钮同族）。
class _HeroNavButton extends StatelessWidget {
  const _HeroNavButton({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final Widget glyph = SizedBox.square(
      dimension: size,
      child: Center(child: FushiIcon(icon, color: Colors.white, size: 22)),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        waitDuration: kIconButtonTooltipHoverDelay,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: FushiPressScale(
              child: FushiHoverLift(
                builder: (BuildContext context, bool hovering) => apple
                    ? fushiClearGlassBezel(
                        context,
                        radius: size / 2,
                        lighter: hovering,
                        child: glyph,
                      )
                    : AnimatedContainer(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        curve: FushiMotion.standard,
                        decoration: ShapeDecoration(
                          shape: const CircleBorder(),
                          color: Colors.black.withValues(
                            alpha: hovering ? 0.55 : 0.4,
                          ),
                        ),
                        child: glyph,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页码指示器：半透明胶囊里一排圆点，当前页拉长成白色药丸；点哪颗跳哪页。
class _HeroPageIndicator extends StatelessWidget {
  const _HeroPageIndicator({
    required this.count,
    required this.current,
    required this.onSelect,
  });

  final int count;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: Colors.black.withValues(alpha: 0.32),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < count; i++)
              Semantics(
                button: true,
                selected: i == current,
                label: t.discovery_hero_page_indicator(
                  index: i + 1,
                  count: count,
                ),
                excludeSemantics: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: ValueKey<String>('discovery-hero-dot-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 5,
                      ),
                      child: AnimatedContainer(
                        duration: duration,
                        curve: FushiMotion.standard,
                        width: i == current ? 18 : 6,
                        height: 6,
                        decoration: ShapeDecoration(
                          shape: const StadiumBorder(),
                          color: Colors.white.withValues(
                            alpha: i == current ? 1 : 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 发现页内容区顶缘的滚动渐隐：内容滚上去之后，在搜索 / 筛选控件下沿铺一条
/// 页面底色 → 透明的短渐变，滚动内容在这里「淡出」而不是被一刀切齐。
///
/// 动机（2026-10-05 移动端截图）：Hero 大卡往上滚、只剩底边一窄条时，被视口
/// 硬裁成一条孤立的暗色圆角胶囊，读起来像筛选 chip 下面多出来的空壳。未滚动
/// 时不画（首屏没有东西被裁，渐变只会把首行压暗）；墨水屏不画（灰阶渐变 =
/// 抖动噪点）。只认直属滚动（depth 0 的纵向滚动），横滑行不触发。
class DiscoveryScrollTopFade extends StatefulWidget {
  const DiscoveryScrollTopFade({required this.child, super.key});

  /// 发现页内容区的纵向滚动视图。
  final Widget child;

  @override
  State<DiscoveryScrollTopFade> createState() => _DiscoveryScrollTopFadeState();
}

class _DiscoveryScrollTopFadeState extends State<DiscoveryScrollTopFade> {
  bool _scrolled = false;
  bool _updateScheduled = false;
  bool _pendingScrolled = false;

  void _track(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    _pendingScrolled = metrics.extentBefore > 0.5;
    if (_updateScheduled) return;
    _updateScheduled = true;
    // 滚动 metrics 通知可能在布局阶段发出（恢复滚动位置、内容高度变化）：
    // 延到帧末再 setState。这条路径恒处在一帧之中，帧末回调必然执行。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _updateScheduled = false;
      if (!mounted || _scrolled == _pendingScrolled) return;
      setState(() => _scrolled = _pendingScrolled);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final Color background = Theme.of(context).scaffoldBackgroundColor;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification notification) {
        _track(notification.metrics, notification.depth);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          _track(notification.metrics, notification.depth);
          return false;
        },
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: widget.child),
            if (!eink)
              Positioned(
                key: const ValueKey<String>('discovery-scroll-top-fade'),
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _scrolled ? 1 : 0,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.standard,
                    // 共享的平滑渐隐（smoothstep，无 Mach 带）：顶边紧贴搜索 /
                    // 筛选行下的不透明页面底色，从 1 起才看不出切线。
                    child: FushiTopFadeScrim(
                      solidHeight: 0,
                      topOpacity: 1,
                      color: background,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
