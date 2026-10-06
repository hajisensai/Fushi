import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 搜索的共享层（用户 2026-10-05「搜索框和输入框也统一成 m3e」）。
//
// - [FushiSearchBar]：M3 Expressive search bar——全圆角胶囊、leading 放大镜
//   或返回箭头、trailing 动作 / 头像。在 [FushiSearchField]（形态层：MD3 胶囊、
//   Apple UISearchBar 胶囊、macOS 原生）之上补齐行为层：查询防抖、IME 组字期间
//   不出查询、Esc 清空 / 失焦并归还焦点、聚焦时向两侧舒展（M3E docked bar 的
//   24→12 外边距）。
// - [showFushiSearchView] / [FushiSearchAnchor]：M3E search view——窄屏展开为
//   全屏搜索页、宽屏为挂在搜索栏下的 docked 面板，含最近搜索 / 建议 / 结果分区；
//   展开收起是从搜索栏出发的弹簧容器变换（[_FushiSearchSpringCurve]），减弱动态效果 /
//   墨水屏下退化为淡入淡出。
//
// 规范依据：m3.material.io/components/search（full-screen：container-low 底、
// container-high 56 头部、leading 变返回箭头 + 清空钮；docked：container-high、
// 外边距 24→12 舒展；打开 = 从 bar 出发的 container transform on spatial
// spring，Esc / 返回 / 点外部关闭）；material-components-android Search.md 的
// Expressive contained 样式（bar 在 view 里视觉上延续、bouncy 动效只给
// Expressive 主题）。Apple 设计系统对应 iOS UISearchBar（胶囊 + 「取消」）。

/// 搜索框 Esc 的处理方式。
enum FushiSearchEscapeBehavior {
  /// 不认领 Esc（交给页面 / 对话框，例如关闭对话框）。
  none,

  /// 有内容时清空并认领；空框时放行给页面（默认：页面级 Esc 语义不变）。
  clear,

  /// 有内容时清空；空框时失焦并把焦点还给之前的焦点（或 [FushiSearchBar.restoreFocusTo]）。
  clearThenUnfocus,
}

/// 查询驱动：监听 [controller]，把「用户确定下来的查询」交给 [onQuery]。
///
/// - IME 组字期间（composing 区间非空）不出查询：日文 / 中文输入法打到一半的
///   假名不会触发搜索，提交（选词 / 回车确认）后才出。
/// - [debounce] 为零时即时过滤，否则停止输入 [debounce] 后才出。
/// - 同一查询不重复出（组字结束但文本未变、程序化重设同值都不触发）。
class FushiSearchQueryDriver {
  FushiSearchQueryDriver({
    required this.controller,
    required this.onQuery,
    this.debounce = Duration.zero,
  }) : _last = controller.text {
    controller.addListener(_onValue);
  }

  final TextEditingController controller;
  final ValueChanged<String> onQuery;
  Duration debounce;
  String _last;
  Timer? _timer;

  /// 最近一次交出去的查询。
  String get lastQuery => _last;

  /// 当前是否在 IME 组字中。
  bool get composing {
    final TextRange range = controller.value.composing;
    return range.isValid && !range.isCollapsed;
  }

  void _onValue() {
    if (composing) {
      // 组字期间作废尚未出发的防抖：那是组字前的旧文本。
      _timer?.cancel();
      return;
    }
    final String text = controller.text;
    if (text == _last) {
      _timer?.cancel();
      return;
    }
    _timer?.cancel();
    if (debounce == Duration.zero) {
      _emit(text);
    } else {
      _timer = Timer(debounce, () => _emit(controller.text));
    }
  }

  void _emit(String text) {
    if (text == _last) return;
    _last = text;
    onQuery(text);
  }

  /// 立即交出当前文本（提交 / 清空时用，跳过防抖）。
  void flush() {
    _timer?.cancel();
    if (composing) return;
    _emit(controller.text);
  }

  void dispose() {
    _timer?.cancel();
    controller.removeListener(_onValue);
  }
}

/// IME 组字中的回车 / Esc 属于输入法（确认候选 / 取消组字），搜索层一律放行。
bool _isComposing(TextEditingController controller) {
  final TextRange range = controller.value.composing;
  return range.isValid && !range.isCollapsed;
}

bool _hasModifier() {
  final HardwareKeyboard k = HardwareKeyboard.instance;
  return k.isControlPressed ||
      k.isShiftPressed ||
      k.isAltPressed ||
      k.isMetaPressed;
}

/// M3 Expressive search bar。
///
/// 形态交给 [FushiSearchField]（两套设计系统 + macOS 原生），这里只加行为：
/// [onQueryChanged] 经 [FushiSearchQueryDriver]（防抖 + IME 组字门），
/// [onSubmitted] 立即交出当前文本，清空钮清空并交出空查询，Esc 见
/// [escapeBehavior]。[controller] / [focusNode] 可由调用方持有，否则自建。
class FushiSearchBar extends StatefulWidget {
  const FushiSearchBar({
    required this.hintText,
    super.key,
    this.controller,
    this.focusNode,
    this.onQueryChanged,
    this.onSubmitted,
    this.onClear,
    this.debounce = Duration.zero,
    this.size = FushiSearchFieldSize.regular,
    this.leading,
    this.onBack,
    this.trailing = const <Widget>[],
    this.avatar,
    this.showClear = true,
    this.escapeBehavior = FushiSearchEscapeBehavior.clear,
    this.restoreFocusTo,
    this.onEscape,
    this.expandOnFocus = false,
    this.autofocus = false,
    this.fieldKey,
    this.clearButtonKey,
    this.focusId,
  });

  final String hintText;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// 查询变化（防抖后、组字结束后）。即时过滤用默认零防抖。
  final ValueChanged<String>? onQueryChanged;

  /// 键盘提交（回车 / 软键盘「搜索」）：立即交出当前文本，不等防抖。
  final ValueChanged<String>? onSubmitted;

  /// 清空钮 / Esc 清空之后的额外回调（查询已经以空串交给 [onQueryChanged]）。
  final VoidCallback? onClear;
  final Duration debounce;
  final FushiSearchFieldSize size;

  /// 自定义 leading（替换放大镜）。与 [onBack] 二选一。
  final Widget? leading;

  /// 给了就把 leading 换成返回箭头（M3E：搜索页 / 嵌在顶栏里的搜索栏）。
  final VoidCallback? onBack;

  /// 尾部动作（排在清空 / 输入辅助钮之后）。
  final List<Widget> trailing;

  /// 尾部头像（M3E search bar 的 trailing avatar），排在最后。
  final Widget? avatar;
  final bool showClear;
  final FushiSearchEscapeBehavior escapeBehavior;

  /// [FushiSearchEscapeBehavior.clearThenUnfocus] 失焦后把焦点交给它；为空时
  /// 交还给所在焦点域之前的焦点。
  final FocusNode? restoreFocusTo;

  /// Esc 失焦后的回调（例如收起顶栏里的搜索态）。
  final VoidCallback? onEscape;

  /// 聚焦时左右各舒展 12（M3E docked search bar 的外边距 24→12）。只在搜索栏
  /// 左右有留白可让的布局里打开。
  final bool expandOnFocus;
  final bool autofocus;
  final Key? fieldKey;
  final Key? clearButtonKey;
  final FushiFocusId? focusId;

  @override
  State<FushiSearchBar> createState() => _FushiSearchBarState();
}

class _FushiSearchBarState extends State<FushiSearchBar> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocusNode;
  late FushiSearchQueryDriver _driver;
  bool _focused = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'fushi-search-bar'));

  @override
  void initState() {
    super.initState();
    _driver = _createDriver();
    _focusNode.addListener(_onFocus);
  }

  FushiSearchQueryDriver _createDriver() => FushiSearchQueryDriver(
    controller: _controller,
    debounce: widget.debounce,
    onQuery: (String q) => widget.onQueryChanged?.call(q),
  );

  @override
  void didUpdateWidget(FushiSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _driver.dispose();
      _driver = _createDriver();
    } else {
      _driver.debounce = widget.debounce;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocusNode)?.removeListener(_onFocus);
      _focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _driver.dispose();
    _focusNode.removeListener(_onFocus);
    _ownedController?.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onFocus() {
    final bool focused = _focusNode.hasFocus;
    if (focused == _focused) return;
    setState(() => _focused = focused);
  }

  void _submit(String _) {
    _driver.flush();
    widget.onSubmitted?.call(_controller.text);
  }

  void _clear() {
    _controller.clear();
    _driver.flush();
    widget.onClear?.call();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (widget.escapeBehavior == FushiSearchEscapeBehavior.none) {
      return KeyEventResult.ignored;
    }
    if (!_focusNode.hasFocus || _hasModifier()) return KeyEventResult.ignored;
    if (_isComposing(_controller)) return KeyEventResult.ignored;
    if (_controller.text.isNotEmpty) {
      _clear();
      return KeyEventResult.handled;
    }
    if (widget.escapeBehavior != FushiSearchEscapeBehavior.clearThenUnfocus) {
      return KeyEventResult.ignored;
    }
    final FocusNode? restore = widget.restoreFocusTo;
    if (restore != null && restore.canRequestFocus) {
      restore.requestFocus();
    } else {
      _focusNode.unfocus(
        disposition: UnfocusDisposition.previouslyFocusedChild,
      );
    }
    widget.onEscape?.call();
    return KeyEventResult.handled;
  }

  Widget? _leading(BuildContext context) {
    if (widget.leading != null) return widget.leading;
    final VoidCallback? onBack = widget.onBack;
    if (onBack == null) return null;
    final bool large = widget.size == FushiSearchFieldSize.large;
    return FushiIconButton(
      icon: FushiIcons.back,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      size: large ? kFushiSearchFieldLargeIconSize : kFushiSearchFieldIconSize,
      padding: large ? const EdgeInsets.all(12) : const EdgeInsets.all(4),
      onTap: onBack,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? avatar = widget.avatar;
    Widget bar = FushiSearchField(
      fieldKey: widget.fieldKey,
      clearButtonKey: widget.clearButtonKey,
      focusId: widget.focusId,
      controller: _controller,
      focusNode: _focusNode,
      hintText: widget.hintText,
      size: widget.size,
      autofocus: widget.autofocus,
      leading: _leading(context),
      trailing: <Widget>[
        ...widget.trailing,
        if (avatar != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
            child: SizedBox.square(
              dimension: 32,
              child: ClipOval(child: avatar),
            ),
          ),
      ],
      // 查询由 [_driver] 统一交出（含组字门与防抖），这里不重复。
      onChanged: (_) {},
      onSubmitted: _submit,
      onClear: widget.showClear ? _clear : null,
    );
    bar = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: bar,
    );
    if (!widget.expandOnFocus) return bar;
    return AnimatedPadding(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: _focused ? FushiMotion.release : FushiMotion.standard,
      padding: EdgeInsets.symmetric(horizontal: _focused ? 0 : 12),
      child: bar,
    );
  }
}

/// 弹簧驱动的曲线：把 [spring] 从 0 到 1 的 [SpringSimulation] 映射到动画的
/// 0..1 时间轴上（时长 = [duration]），末端强制落在 1。阻尼比 < 1 时带一点
/// 过冲回弹——M3 Expressive 的 spatial spring 观感，而 route / 隐式动画仍可
/// 按固定时长驱动。
class _FushiSearchSpringCurve extends Curve {
  _FushiSearchSpringCurve({
    SpringDescription? spring,
  }) : _simulation = SpringSimulation(spring ?? fushiSearchViewSpring, 0, 1, 0);

  static const Duration _defaultDuration = Duration(milliseconds: 500);

  final Duration duration = _defaultDuration;
  final SpringSimulation _simulation;

  @override
  double transformInternal(double t) {
    final double seconds = t * duration.inMicroseconds / 1e6;
    return _simulation.x(seconds);
  }
}

/// 搜索视图容器变换的弹簧：M3E「default spatial」刚度、阻尼比 0.8（展开时一点
/// 弹性，对应 contained search view 的 bouncy 动效）。
final SpringDescription fushiSearchViewSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);

/// 搜索视图形态。
enum FushiSearchViewMode {
  /// 宽度 < [kFushiSearchViewDockedBreakpoint] 全屏，否则 docked。
  auto,
  fullScreen,
  docked,
}

/// [FushiSearchViewMode.auto] 的分界宽度（M3 compact / medium 窗口分界）。
const double kFushiSearchViewDockedBreakpoint = 600;

/// 解析搜索视图形态。
FushiSearchViewMode resolveFushiSearchViewMode(
  FushiSearchViewMode mode,
  double width,
) {
  if (mode != FushiSearchViewMode.auto) return mode;
  return width < kFushiSearchViewDockedBreakpoint
      ? FushiSearchViewMode.fullScreen
      : FushiSearchViewMode.docked;
}

/// 结果区构建：[query] 非空时调用（为空时显示最近搜索 / 建议）。返回的控件
/// 应自带滚动。
typedef FushiSearchResultsBuilder =
    Widget Function(BuildContext context, String query);

/// 建议构建：按当前查询给出建议词（同步、轻量）。
typedef FushiSearchSuggestionsBuilder = List<String> Function(String query);

/// 打开 M3E 搜索视图。返回用户提交的查询（选中最近搜索 / 建议也算提交）；
/// 关闭（返回、Esc、点外部）返回 null。
///
/// [anchorContext] 给出搜索栏所在的控件（通常是 [FushiSearchAnchor] 自己），
/// 容器变换从它的矩形出发；docked 面板也挂在它下面。为空时从顶部居中出发。
/// 关闭后焦点交还 [returnFocusTo]（为空时由 Navigator 交还给打开前的焦点）。
Future<String?> showFushiSearchView({
  required BuildContext context,
  required String hintText,
  BuildContext? anchorContext,
  String initialQuery = '',
  FushiSearchResultsBuilder? resultsBuilder,
  FushiSearchSuggestionsBuilder? suggestionsBuilder,
  List<String> recentSearches = const <String>[],
  ValueChanged<String>? onRemoveRecent,
  ValueChanged<String>? onQueryChanged,
  ValueChanged<String>? onSubmitted,
  Duration debounce = Duration.zero,
  List<Widget> trailing = const <Widget>[],
  FushiSearchViewMode mode = FushiSearchViewMode.auto,
  FocusNode? returnFocusTo,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  Rect? anchor;
  final RenderObject? box = (anchorContext ?? context).findRenderObject();
  final RenderObject? overlay = navigator.overlay?.context.findRenderObject();
  if (anchorContext != null &&
      box is RenderBox &&
      box.hasSize &&
      overlay is RenderBox) {
    anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  }
  final String? result = await navigator.push<String>(
    _FushiSearchViewRoute(
      motionEnabled: fushiMotionEnabled(context),
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      config: _FushiSearchViewConfig(
        hintText: hintText,
        initialQuery: initialQuery,
        resultsBuilder: resultsBuilder,
        suggestionsBuilder: suggestionsBuilder,
        recentSearches: recentSearches,
        onRemoveRecent: onRemoveRecent,
        onQueryChanged: onQueryChanged,
        onSubmitted: onSubmitted,
        debounce: debounce,
        trailing: trailing,
        mode: mode,
      ),
      anchorRect: anchor,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
  if (returnFocusTo != null && returnFocusTo.canRequestFocus) {
    returnFocusTo.requestFocus();
  }
  return result;
}

class _FushiSearchViewConfig {
  const _FushiSearchViewConfig({
    required this.hintText,
    required this.initialQuery,
    required this.resultsBuilder,
    required this.suggestionsBuilder,
    required this.recentSearches,
    required this.onRemoveRecent,
    required this.onQueryChanged,
    required this.onSubmitted,
    required this.debounce,
    required this.trailing,
    required this.mode,
  });

  final String hintText;
  final String initialQuery;
  final FushiSearchResultsBuilder? resultsBuilder;
  final FushiSearchSuggestionsBuilder? suggestionsBuilder;
  final List<String> recentSearches;
  final ValueChanged<String>? onRemoveRecent;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSubmitted;
  final Duration debounce;
  final List<Widget> trailing;
  final FushiSearchViewMode mode;
}

class _FushiSearchViewRoute extends PopupRoute<String> {
  _FushiSearchViewRoute({
    required this.capturedThemes,
    required this.config,
    required this.anchorRect,
    required this.barrierLabel,
    required this.motionEnabled,
  });

  /// 打开时的动效资格（墨水屏 / 系统减弱动效 → false，路由瞬开瞬关）。
  final bool motionEnabled;

  final CapturedThemes capturedThemes;
  final _FushiSearchViewConfig config;
  final Rect? anchorRect;

  @override
  final String? barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration =>
      motionEnabled ? const Duration(milliseconds: 500) : Duration.zero;

  @override
  Duration get reverseTransitionDuration =>
      motionEnabled ? FushiMotion.longReverse : Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return capturedThemes.wrap(
      _FushiSearchViewFrame(
        animation: animation,
        anchorRect: anchorRect,
        config: config,
      ),
    );
  }
}

/// 容器变换外框：表面矩形从搜索栏插值到目标（全屏 / docked），圆角从胶囊
/// 插值到目标圆角，内容在后半程淡入；关闭时反向。
class _FushiSearchViewFrame extends StatefulWidget {
  const _FushiSearchViewFrame({
    required this.animation,
    required this.anchorRect,
    required this.config,
  });

  final Animation<double> animation;
  final Rect? anchorRect;
  final _FushiSearchViewConfig config;

  @override
  State<_FushiSearchViewFrame> createState() => _FushiSearchViewFrameState();
}

class _FushiSearchViewFrameState extends State<_FushiSearchViewFrame> {
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: widget.animation,
    curve: _FushiSearchSpringCurve(),
    reverseCurve: FushiMotion.exit,
  );

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  static const double _dockedMaxHeight = 520;
  static const double _dockedMinWidth = 360;
  static const double _dockedMaxWidth = 720;

  Rect _dockedTarget(Rect anchor, Size screen) {
    double width = (anchor.width + 24).clamp(_dockedMinWidth, _dockedMaxWidth);
    width = width.clamp(0, screen.width - 16);
    double left = anchor.center.dx - width / 2;
    left = left.clamp(8, screen.width - width - 8);
    final double top = anchor.top;
    final double maxHeight = (screen.height - top - 16).clamp(
      120,
      _dockedMaxHeight,
    );
    return Rect.fromLTWH(left, top, width, maxHeight);
  }

  @override
  Widget build(BuildContext context) {
    final bool motion = fushiMotionEnabled(context);
    final bool apple = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size screen = constraints.biggest;
        final FushiSearchViewMode mode = resolveFushiSearchViewMode(
          widget.config.mode,
          screen.width,
        );
        final bool full = mode == FushiSearchViewMode.fullScreen;
        final double barHeight = apple ? 36 : kFushiSearchFieldLargeHeight;
        final Rect anchor =
            widget.anchorRect ??
            Rect.fromCenter(
              center: Offset(
                screen.width / 2,
                MediaQuery.paddingOf(context).top + 8 + barHeight / 2,
              ),
              width: (screen.width - 32).clamp(0, _dockedMaxWidth),
              height: barHeight,
            );
        final Rect target = full
            ? Offset.zero & screen
            : _dockedTarget(anchor, screen);
        final double targetRadius = full ? 0 : (apple ? 14 : 28);
        final Color surface = apple
            ? appleColorsOf(context).secondaryGroupedBackground
            : (full ? cs.surfaceContainerLow : cs.surfaceContainerHigh);
        final Widget body = _FushiSearchViewBody(
          config: widget.config,
          fullScreen: full,
        );
        return AnimatedBuilder(
          animation: _curve,
          child: body,
          builder: (BuildContext context, Widget? child) {
            final double raw = widget.animation.value;
            final double t = motion ? _curve.value : 1;
            final Rect rect = Rect.lerp(anchor, target, t)!;
            final double radius = lerpDouble(
              anchor.height / 2,
              targetRadius,
              t.clamp(0.0, 1.0),
            )!.clamp(0.0, double.infinity);
            final double contentOpacity = motion
                ? const Interval(0.3, 1).transform(raw)
                : 1;
            final double surfaceOpacity = motion ? 1 : raw;
            return Stack(
              children: <Widget>[
                Positioned.fromRect(
                  rect: rect,
                  child: Opacity(
                    opacity: surfaceOpacity,
                    child: Material(
                      color: surface,
                      elevation: full ? 0 : 3,
                      shadowColor: cs.shadow,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(radius),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Opacity(
                        opacity: contentOpacity,
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: target.width,
                          maxWidth: target.width,
                          minHeight: target.height,
                          maxHeight: target.height,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _FushiSearchViewBody extends StatefulWidget {
  const _FushiSearchViewBody({required this.config, required this.fullScreen});

  final _FushiSearchViewConfig config;
  final bool fullScreen;

  @override
  State<_FushiSearchViewBody> createState() => _FushiSearchViewBodyState();
}

class _FushiSearchViewBodyState extends State<_FushiSearchViewBody> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.config.initialQuery,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'fushi-search-view');
  late final FushiSearchQueryDriver _driver;
  late String _query = widget.config.initialQuery;
  late final List<String> _recent = List<String>.of(
    widget.config.recentSearches,
  );

  @override
  void initState() {
    super.initState();
    _driver = FushiSearchQueryDriver(
      controller: _controller,
      debounce: widget.config.debounce,
      onQuery: _onQuery,
    );
  }

  @override
  void dispose() {
    _driver.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQuery(String query) {
    setState(() => _query = query);
    widget.config.onQueryChanged?.call(query);
  }

  void _submit(String text) {
    _driver.flush();
    final String query = text.trim();
    if (query.isEmpty) return;
    widget.config.onSubmitted?.call(query);
    Navigator.of(context).pop(query);
  }

  void _clear() {
    _controller.clear();
    _driver.flush();
    _focusNode.requestFocus();
  }

  void _close() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape || _hasModifier()) {
      return KeyEventResult.ignored;
    }
    if (_isComposing(_controller)) return KeyEventResult.ignored;
    _close();
    return KeyEventResult.handled;
  }

  void _removeRecent(String entry) {
    setState(() => _recent.remove(entry));
    widget.config.onRemoveRecent?.call(entry);
  }

  Widget _buildHeader(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    if (apple) {
      // iOS UISearchBar：搜索胶囊 + 「取消」。
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (BuildContext context, TextEditingValue value, _) {
                  return FushiTextFieldControl(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: widget.config.hintText,
                      prefixIcon: const FushiIcon(
                        FushiIcons.search,
                        size: kFushiSearchFieldIconSize,
                      ),
                      suffixIcon: value.text.isEmpty
                          ? null
                          : FushiIconButton(
                              icon: FushiIcons.cancel,
                              tooltip: t.clear,
                              size: kFushiSearchFieldIconSize,
                              padding: const EdgeInsets.all(4),
                              onTap: _clear,
                            ),
                    ),
                    onSubmitted: _submit,
                  );
                },
              ),
            ),
            ...widget.config.trailing,
            FushiTextButton(onPressed: _close, child: Text(t.cancel)),
          ],
        ),
      );
    }
    final TextStyle text = (theme.textTheme.bodyLarge ?? const TextStyle())
        .copyWith(
          color: cs.onSurface,
          height: 1.25,
          leadingDistribution: TextLeadingDistribution.even,
        );
    return Container(
      height: kFushiSearchFieldLargeHeight,
      color: widget.fullScreen ? cs.surfaceContainerHigh : null,
      padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
      child: Row(
        children: <Widget>[
          FushiIconButton(
            icon: FushiIcons.back,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            size: kFushiSearchFieldLargeIconSize,
            padding: const EdgeInsets.all(12),
            onTap: _close,
          ),
          Expanded(
            child: FushiTextFieldControl(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: text,
              textAlignVertical: TextAlignVertical.center,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.config.hintText,
                hintStyle: text.copyWith(color: cs.onSurfaceVariant),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onSubmitted: _submit,
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (BuildContext context, TextEditingValue value, _) {
              return AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                transitionBuilder: (Widget child, Animation<double> a) =>
                    ScaleTransition(
                      scale: a,
                      child: FadeTransition(opacity: a, child: child),
                    ),
                child: value.text.isEmpty
                    ? const SizedBox.shrink()
                    : FushiIconButton(
                        key: const ValueKey<String>('fushi-search-view-clear'),
                        icon: FushiIcons.close,
                        tooltip: t.clear,
                        size: kFushiSearchFieldLargeIconSize,
                        padding: const EdgeInsets.all(12),
                        onTap: _clear,
                      ),
              );
            },
          ),
          ...widget.config.trailing,
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return FushiListItem(
      leading: FushiIcon(icon),
      title: Text(text),
      trailing: trailing,
      onTap: onTap,
    );
  }

  void _pick(String entry) {
    _controller.value = TextEditingValue(
      text: entry,
      selection: TextSelection.collapsed(offset: entry.length),
    );
    _submit(entry);
  }

  Widget _buildDefaultSections(BuildContext context) {
    final List<String> suggestions =
        widget.config.suggestionsBuilder?.call(_query) ?? const <String>[];
    final bool showRecent = _query.isEmpty && _recent.isNotEmpty;
    if (!showRecent && suggestions.isEmpty) {
      final FushiSearchResultsBuilder? results = widget.config.resultsBuilder;
      return results == null ? const SizedBox.shrink() : results(context, '');
    }
    final List<Widget> children = <Widget>[
      if (showRecent) ...<Widget>[
        FushiSectionTitle.group(t.search_view_recent_title),
        for (final String entry in _recent)
          _row(
            icon: FushiIcons.history,
            text: entry,
            onTap: () => _pick(entry),
            trailing: widget.config.onRemoveRecent == null
                ? null
                : FushiIconButton(
                    icon: FushiIcons.close,
                    tooltip: t.search_view_recent_remove,
                    size: 18,
                    onTap: () => _removeRecent(entry),
                  ),
          ),
      ],
      if (suggestions.isNotEmpty) ...<Widget>[
        FushiSectionTitle.group(t.search_view_suggestions_title),
        for (final String entry in suggestions)
          _row(icon: FushiIcons.search, text: entry, onTap: () => _pick(entry)),
      ],
    ];
    return FushiEntranceScope(
      replayKey: _query.isEmpty,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: children.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => children[index],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final FushiSearchResultsBuilder? results = widget.config.resultsBuilder;
    if (_query.isEmpty || results == null) {
      return _buildDefaultSections(context);
    }
    return results(context, _query);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget header = _buildHeader(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.fullScreen)
            ColoredBox(
              color: isGlassDesign(context)
                  ? Colors.transparent
                  : Theme.of(context).colorScheme.surfaceContainerHigh,
              child: SafeArea(bottom: false, child: header),
            )
          else
            header,
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: _buildContent(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 打开 [showFushiSearchView] 的搜索栏（M3E SearchAnchor）：静止时是一枚
/// 胶囊（放大镜 + 当前查询或占位 + 尾部动作），点按 / 回车展开搜索视图，
/// 容器变换从这枚胶囊出发；收起后焦点回到它。
class FushiSearchAnchor extends StatefulWidget {
  const FushiSearchAnchor({
    required this.hintText,
    super.key,
    this.query = '',
    this.resultsBuilder,
    this.suggestionsBuilder,
    this.recentSearches = const <String>[],
    this.onRemoveRecent,
    this.onQueryChanged,
    this.onSubmitted,
    this.debounce = Duration.zero,
    this.size = FushiSearchFieldSize.large,
    this.trailing = const <Widget>[],
    this.avatar,
    this.mode = FushiSearchViewMode.auto,
  });

  final String hintText;

  /// 当前查询（显示在胶囊里，并作为展开时的初始文本）。
  final String query;
  final FushiSearchResultsBuilder? resultsBuilder;
  final FushiSearchSuggestionsBuilder? suggestionsBuilder;
  final List<String> recentSearches;
  final ValueChanged<String>? onRemoveRecent;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSubmitted;
  final Duration debounce;
  final FushiSearchFieldSize size;
  final List<Widget> trailing;
  final Widget? avatar;
  final FushiSearchViewMode mode;

  @override
  State<FushiSearchAnchor> createState() => _FushiSearchAnchorState();
}

class _FushiSearchAnchorState extends State<FushiSearchAnchor> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'fushi-search-anchor');
  bool _open = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _openView() async {
    if (_open) return;
    setState(() => _open = true);
    await showFushiSearchView(
      context: context,
      anchorContext: context,
      hintText: widget.hintText,
      initialQuery: widget.query,
      resultsBuilder: widget.resultsBuilder,
      suggestionsBuilder: widget.suggestionsBuilder,
      recentSearches: widget.recentSearches,
      onRemoveRecent: widget.onRemoveRecent,
      onQueryChanged: widget.onQueryChanged,
      onSubmitted: widget.onSubmitted,
      debounce: widget.debounce,
      mode: widget.mode,
      returnFocusTo: _focusNode,
    );
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool large = !apple && widget.size == FushiSearchFieldSize.large;
    final double height = apple
        ? 36
        : (large ? kFushiSearchFieldLargeHeight : kFushiSearchFieldHeight);
    final double iconSize = large
        ? kFushiSearchFieldLargeIconSize
        : kFushiSearchFieldIconSize;
    final Color fill = apple
        ? appleColorsOf(context).tertiaryFill
        : cs.surfaceContainerHigh;
    final Color hintColor = apple
        ? appleColorsOf(context).secondaryLabel
        : cs.onSurfaceVariant;
    final TextStyle base =
        (large ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium) ??
        const TextStyle();
    final bool hasQuery = widget.query.isNotEmpty;
    final Widget? avatar = widget.avatar;
    final Widget content = Row(
      children: <Widget>[
        SizedBox(width: large ? 16 : 12),
        FushiIcon(FushiIcons.search, size: iconSize, color: hintColor),
        SizedBox(width: large ? 12 : 8),
        Expanded(
          child: Text(
            hasQuery ? widget.query : widget.hintText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(
              color: hasQuery ? cs.onSurface : hintColor,
              height: 1.25,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
        ...widget.trailing,
        if (avatar != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: SizedBox.square(
              dimension: 32,
              child: ClipOval(child: avatar),
            ),
          ),
        SizedBox(width: large ? 8 : 4),
      ],
    );
    // 展开期间把胶囊藏起来：容器变换的表面从这里「长」出去，原位留空。
    return Opacity(
      opacity: _open ? 0 : 1,
      child: FushiPressScale(
        child: Material(
          color: fill,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: _focusNode,
            onTap: _openView,
            hoverColor: cs.onSurface.withValues(
              alpha: kFushiFieldHoverStateOpacity,
            ),
            focusColor: cs.onSurface.withValues(alpha: 0.10),
            child: Semantics(
              button: true,
              label: widget.hintText,
              child: SizedBox(height: height, child: content),
            ),
          ),
        ),
      ),
    );
  }
}
