part of 'fushi_now_playing_bar.dart';

// [FushiNowPlayingBar] 的 Apple 设计系统分支（Apple Music iOS 27 / macOS 27
// 迷你播放器）。由 [_FushiNowPlayingBarState.build] 按 `isGlassDesign` 分派，
// M3E 的取色色块 / 出血大字 / 饼干形封面圆环一概不用：
//
// - 外壳：栏玻璃（[fushiClearGlassSettings] bar 档 + 静止不画高光边的
//   [fushiGlassButtonRestSettings]），按封面取色着色（与 M3E 色块同一份
//   [coverColorSchemeCache] 结果，取主色压成低饱和、亮度钉在系统材质附近的色调，
//   见 [fushiNowPlayingAppleGlassTint] / [fushiNowPlayingAppleSolidTint]）；实色档
//   是取色调过的系统材质实色。无封面 / 取色失败回落中性玻璃；切歌时颜色按
//   [FushiMotion.medium] 平滑过渡。
// - 封面：连续曲率小圆角方图（[_kAppleCoverRadius]），无圆环、无描边。
// - 文字：标题 label 半粗、副标题 secondaryLabel，各一行省略。
// - 控件：一律 [FushiAppleGlyphButton] 裸字形（上一首 / 下一首 = backward.fill /
//   forward.fill，播放键走 [FushiExpressivePlayButton] 的 Apple 裸字形分支）。
//
// 两档（[fushiAppleCompact]：桌面宽窗 = macOS 档，触屏 / 桌面窄窗 = iOS 档）：
// - iOS 档 [_AppleCapsuleBar]：底栏上方的玻璃胶囊，只留播放 / 下一首；上一首、
//   循环、音量、进度在全屏播放页，队列 / 停止 / 音质等在长按 / 右键菜单
//   （[FushiNowPlayingBar.onMore]，没给菜单时额外动作照旧平铺）。宿主往下滚时缩成
//   贴末端的「封面 + 播放键」，点一下先展开。
// - macOS 档 [_AppleMacBar]：底部居中、按内容收宽的玻璃条，上一首 / 播放 / 下一首 +
//   额外动作平铺，底边一条细进度线；宿主往下滚时缩成「封面 + 标题 + 播放键」，
//   悬停 / 点一下展开（与 M3E 宽屏同一套 hover / pin / hold 规则）。
//
// 档位与按钮数都按**条实际拿到的宽度**定（[_AppleRowBudget]），不只看窗口：宿主
// 可能只占窗口的一栏（分栏详情页等），窗口够宽（macOS 档度量）而条所在的栏很窄
// 时，按 macOS 档平铺全部按钮会横向溢出。放不下时额外动作从末尾起依次收进长按 /
// 右键菜单（只在调用方给了 [FushiNowPlayingBar.onMore] 时收；没菜单的动作不收，
// 宽度不够就落到 iOS 档胶囊），标题弹性让位、单行省略。

/// Apple 分支裸字形按钮的命中区（≥ 44，底部浮动条的触控下限）。额外动作里的
/// Apple 按钮也传这个值，与传输键同一行高。
const double kFushiNowPlayingAppleGlyphExtent = 44;

/// iOS 档封面边长。
const double _kAppleCoverIos = 40;

/// macOS 档封面边长（再乘 [fushiAppleMacScale]）。
const double _kAppleCoverMac = 38;

/// macOS 档条身圆角（再乘 [fushiAppleMacScale]）。
const double _kAppleMacRadius = 16;

/// 着色色调的饱和度上限（Apple 着色玻璃是低饱和的氛围色，不是色块）。
const double _kAppleTintMaxSaturation = 0.32;

/// 玻璃着色：封面主色 [hue] 压成低饱和，亮度钉在系统材质附近（浅 0.90 / 深
/// 0.20），再按浅 58% / 深 52% 铺不透明度——label / secondaryLabel 对比度与中性
/// 玻璃同档（浅色底仍是近白、深色底仍是近黑），字形不必换色。
Color fushiNowPlayingAppleGlassTint(Color hue, {required bool dark}) {
  final HSLColor hsl = HSLColor.fromColor(hue);
  return hsl
      .withSaturation(math.min(hsl.saturation, _kAppleTintMaxSaturation))
      .withLightness(dark ? 0.20 : 0.90)
      .toColor()
      .withValues(alpha: dark ? 0.52 : 0.58);
}

/// 实色档的取色系统材质：同一色调、不透明，亮度贴系统材质实色（浅 0.94 /
/// 深 0.14，系统 #F9F9F9 / #1C1C1E 附近）。
Color fushiNowPlayingAppleSolidTint(Color hue, {required bool dark}) {
  final HSLColor hsl = HSLColor.fromColor(hue);
  return hsl
      .withSaturation(math.min(hsl.saturation, _kAppleTintMaxSaturation))
      .withLightness(dark ? 0.14 : 0.94)
      .toColor();
}

class _AppleNowPlayingBar extends StatelessWidget {
  const _AppleNowPlayingBar({required this.bar, required this.tint});

  final FushiNowPlayingBar bar;

  /// 封面取色主色；null = 中性玻璃。
  final Color? tint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final _AppleRowBudget budget = _AppleRowBudget(context, bar);
      if (fushiAppleCompact(context) && budget.fitsMac(c.maxWidth)) {
        return _AppleMacBar(
          bar: bar,
          tint: tint,
          visibleActions: budget.visibleActions(c.maxWidth),
        );
      }
      return _AppleCapsuleBar(bar: bar, tint: tint);
    },
  );
}

/// macOS 档条外边距（条与宿主边缘之间）。
const EdgeInsets _kAppleMacOuter = EdgeInsets.fromLTRB(16, 4, 16, 14);

/// macOS 档条内边距（展开态；收起态末端收到 [_kAppleMacPaddingCollapsedEnd]）。
const EdgeInsetsDirectional _kAppleMacPadding = EdgeInsetsDirectional.fromSTEB(
  6,
  6,
  8,
  6,
);
const double _kAppleMacPaddingCollapsedEnd = 4;

/// 封面与标题、标题与按钮组、按钮组与额外动作之间的间距。
const double _kAppleMacCoverGap = 10;
const double _kAppleMacTitleGap = 8;
const double _kAppleMacActionsGap = 6;

/// 标题列宽：理想 [_kAppleTitleWidth]（× [fushiAppleMacScale]），栏窄时弹性让位；
/// 至少保住 [_kAppleMinTitleWidth]（约 6–8 个字，再窄就只剩省略号），保不住就先
/// 收额外动作、再不行换 iOS 档胶囊。
const double _kAppleTitleWidth = 220;
const double _kAppleMinTitleWidth = 120;

/// 收起态标题封顶宽（× [fushiAppleMacScale]）。
const double _kAppleCollapsedTitleMax = 200;

/// macOS 档一行的横向预算：除标题外全是固定尺寸件（封面、间距、命中区
/// [kFushiNowPlayingAppleGlyphExtent] 的裸字形键；额外动作按约定每个一枚同尺寸
/// 字形键），只有标题弹性。
class _AppleRowBudget {
  _AppleRowBudget(BuildContext context, this.bar)
    : scale = fushiAppleMacScale(context);

  final FushiNowPlayingBar bar;
  final double scale;

  int get _transportCount =>
      1 + (bar.previous == null ? 0 : 1) + (bar.next == null ? 0 : 1);

  /// 平铺 [actions] 个额外动作时，除标题外占的宽度（含条外边距）。
  double fixedWidth(int actions) =>
      _kAppleMacOuter.horizontal +
      _kAppleMacPadding.horizontal +
      _kAppleCoverMac * scale +
      _kAppleMacCoverGap +
      _kAppleMacTitleGap +
      (_transportCount + actions) * kFushiNowPlayingAppleGlyphExtent +
      (actions > 0 ? _kAppleMacActionsGap : 0);

  bool _fits(int actions, double maxWidth) =>
      fixedWidth(actions) + _kAppleMinTitleWidth * scale <= maxWidth;

  /// 不能收进菜单的额外动作个数（没有 [FushiNowPlayingBar.onMore] 时全部）。
  int get _mandatory => bar.onMore == null ? bar.actions.length : 0;

  /// 这个宽度下能不能走 macOS 档（传输键 + 必须平铺的动作 + 最窄标题放得下）。
  bool fitsMac(double maxWidth) => _fits(_mandatory, maxWidth);

  /// 这个宽度下平铺几个额外动作（其余从末尾起收进长按菜单）。
  int visibleActions(double maxWidth) {
    for (int n = bar.actions.length; n > _mandatory; n--) {
      if (_fits(n, maxWidth)) return n;
    }
    return _mandatory;
  }
}

/// 上一首 / 下一首（Apple Music 的 backward.fill / forward.fill 实心字形）。
Widget _appleSkip(FushiNowPlayingSkip skip, {required bool forward}) =>
    FushiAppleGlyphButton(
      key: skip.key,
      icon: forward ? FushiIcons.fastForward : FushiIcons.fastRewind,
      tooltip: skip.tooltip,
      prominent: true,
      extent: kFushiNowPlayingAppleGlyphExtent,
      onPressed: skip.onPressed,
    );

Widget _applePlay(FushiNowPlayingBar bar) => FushiExpressivePlayButton(
  key: bar.playButtonKey,
  isPlaying: bar.isPlaying,
  size: kFushiNowPlayingAppleGlyphExtent,
  onPressed: bar.onPlayPause,
);

/// 连续曲率小圆角方形封面。
class _AppleCover extends StatelessWidget {
  const _AppleCover({required this.bar, required this.size});

  final FushiNowPlayingBar bar;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRSuperellipse(
    key: const ValueKey<String>('now-playing-apple-cover'),
    borderRadius: FushiAppleRadii.of(context).coverRadius,
    child: SizedBox.square(
      dimension: size,
      child: bar.coverBuilder(context, size),
    ),
  );
}

/// 标题（label 半粗）+ 副标题（secondaryLabel），各一行省略。
class _AppleTitleBlock extends StatelessWidget {
  const _AppleTitleBlock({required this.bar, this.showSubtitle = true});

  final FushiNowPlayingBar bar;
  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool mac = fushiAppleCompact(context);
    final double s = fushiAppleMacScale(context);
    final TextStyle base = context.fushiType.bodyMedium;
    final String? subtitle = bar.subtitle;
    final Widget? trailing = bar.titleTrailing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                bar.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontSize: mac ? 13 * s : 15,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: apple.label,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (showSubtitle && subtitle != null && subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(
              fontSize: mac ? 12 * s : 13,
              height: 1.25,
              fontWeight: FontWeight.w400,
              color: apple.secondaryLabel,
            ),
          ),
      ],
    );
  }
}

/// 中性玻璃外壳 + 条身点按 / 长按 / 焦点（Enter = 点条身）+ 按压缩放。
/// 玻璃画质 off（实色档）时是系统材质实色浮层；任何档都不取封面色。
class _AppleBarSurface extends StatefulWidget {
  const _AppleBarSurface({
    required this.bar,
    required this.shape,
    required this.padding,
    required this.onTap,
    required this.child,
    required this.tint,
    this.onLongPress,
    this.overlay,
  });

  final FushiNowPlayingBar bar;
  final OutlinedBorder shape;

  /// 封面取色主色；null = 中性。
  final Color? tint;
  final EdgeInsetsGeometry padding;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  /// 压在内容上、在玻璃里的装饰层（macOS 档底边进度线）。
  final Widget? overlay;

  @override
  State<_AppleBarSurface> createState() => _AppleBarSurfaceState();
}

class _AppleBarSurfaceState extends State<_AppleBarSurface> {
  bool _focusHighlight = false;

  @override
  Widget build(BuildContext context) {
    final OutlinedBorder shape = widget.shape;
    final Widget? overlay = widget.overlay;
    final Widget content = Stack(
      children: <Widget>[
        Padding(padding: widget.padding, child: widget.child),
        ?overlay,
      ],
    );
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    final Color? hue = widget.tint;
    final LiquidGlassSettings? glass = solid
        ? null
        : fushiGlassButtonRestSettings(
            fushiClearGlassSettings(context, bar: true),
          );
    // 目标色恒非空（中性 = 原本的玻璃填充 / 系统材质实色），切歌 / 失去封面时
    // 两端都是实色，插值不会经过「透明」。
    final Color target = solid
        ? (hue == null
              ? fushiGlassPlatformViewFallback(context)
              : fushiNowPlayingAppleSolidTint(hue, dark: dark))
        : (hue == null
              ? glass!.glassColor
              : fushiNowPlayingAppleGlassTint(hue, dark: dark));
    final Widget surface = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      child: content,
      builder: (BuildContext context, Color? color, Widget? child) => solid
          ? DecoratedBox(
              key: const ValueKey<String>('now-playing-apple-surface'),
              decoration: fushiAppleSolidFloatingDecoration(
                context,
                shape: shape,
                tint: color,
              ),
              child: child,
            )
          : GlassContainer(
              key: const ValueKey<String>('now-playing-apple-surface'),
              // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
              useOwnLayer: true,
              quality: fushiGlassQuality(context, prominent: true),
              shape: fushiLiquidShapeOf(shape),
              settings: glass!.copyWith(glassColor: color),
              platformViewBackdrop: fushiGlassOverPlatformView(context),
              child: child,
            ),
    );
    final Widget focused = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: shape.copyWith(
          side: _focusHighlight
              ? BorderSide(color: appleColorsOf(context).accent, width: 2)
              : BorderSide.none,
        ),
      ),
      child: surface,
    );
    return FocusableActionDetector(
      onShowFocusHighlight: (bool value) {
        if (value != _focusHighlight) setState(() => _focusHighlight = value);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        key: widget.bar.barKey,
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: FushiPressScale(scale: 0.98, child: focused),
      ),
    );
  }
}

/// iOS 档：底栏上方的玻璃胶囊（见文件头）。
class _AppleCapsuleBar extends StatelessWidget {
  const _AppleCapsuleBar({required this.bar, required this.tint});

  final FushiNowPlayingBar bar;
  final Color? tint;

  @override
  Widget build(BuildContext context) => _CollapsePeek(
    builder: (BuildContext context, bool collapsed, VoidCallback peek) {
      final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
      final VoidCallback? more = bar.onMore;
      final FushiNowPlayingSkip? next = bar.next;
      final Widget card = _AppleBarSurface(
        bar: bar,
        tint: tint,
        shape: const StadiumBorder(),
        padding: EdgeInsetsDirectional.fromSTEB(6, 6, collapsed ? 4 : 8, 6),
        // 收起时点一下先展开，展开后再点才是条身动作。
        onTap: collapsed ? peek : bar.onTap,
        onLongPress: collapsed ? null : more,
        child: FushiAnimatedSize(
          duration: motion,
          curve: FushiSpringCurve.spatial,
          alignment: AlignmentDirectional.centerEnd,
          child: Row(
            mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
            children: <Widget>[
              _AppleCover(bar: bar, size: _kAppleCoverIos),
              if (collapsed) ...<Widget>[
                const SizedBox(width: 4),
                _applePlay(bar),
              ] else ...<Widget>[
                const SizedBox(width: 10),
                Expanded(child: _AppleTitleBlock(bar: bar)),
                const SizedBox(width: 4),
                _applePlay(bar),
                if (next != null) _appleSkip(next, forward: true),
                // 有长按菜单时额外动作全收进菜单 / 全屏播放页；没菜单（正在听书
                // 条）就平铺，一个功能都不丢。
                if (more == null) ...bar.actions,
              ],
            ],
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          kFushiFloatingToolbarEdgeMargin,
          4,
          kFushiFloatingToolbarEdgeMargin,
          8,
        ),
        child: AnimatedAlign(
          duration: motion,
          curve: FushiSpringCurve.effects,
          heightFactor: 1,
          alignment: collapsed
              ? AlignmentDirectional.centerEnd.resolve(
                  Directionality.of(context),
                )
              : Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kFushiNowPlayingCompactMaxWidth,
            ),
            child: more == null
                ? card
                : ContextMenuTrigger(
                    onInvoke: contextMenuInvoker(more),
                    child: card,
                  ),
          ),
        ),
      );
    },
  );
}

/// macOS 档：底部居中的玻璃条（见文件头）。
class _AppleMacBar extends StatefulWidget {
  const _AppleMacBar({
    required this.bar,
    required this.tint,
    required this.visibleActions,
  });

  final FushiNowPlayingBar bar;
  final Color? tint;

  /// 平铺的额外动作个数（[_AppleRowBudget.visibleActions]）；其余在长按菜单。
  final int visibleActions;

  @override
  State<_AppleMacBar> createState() => _AppleMacBarState();
}

class _AppleMacBarState extends State<_AppleMacBar> {
  bool _hovered = false;

  /// 触屏点开的展开态；点到条外或鼠标离开时收起。
  bool _pinned = false;

  /// 额外动作的浮层开着（[FushiNowPlayingBar.holdExpandedOf]）时不许收起。
  bool _held = false;

  void _hold(bool held) {
    if (held != _held && mounted) setState(() => _held = held);
  }

  @override
  Widget build(BuildContext context) {
    final FushiNowPlayingBar bar = widget.bar;
    final double s = fushiAppleMacScale(context);
    final bool expanded =
        _hovered || _pinned || _held || !FushiNowPlayingCollapse.of(context);
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
    final double cover = _kAppleCoverMac * s;
    final FushiNowPlayingSkip? prev = bar.previous;
    final FushiNowPlayingSkip? next = bar.next;
    final List<Widget> actions = bar.actions
        .take(widget.visibleActions)
        .toList(growable: false);
    // 有动作收进了菜单：长按 / 右键条身打开（与 iOS 档同一个菜单）。
    final VoidCallback? more = actions.length < bar.actions.length
        ? bar.onMore
        : null;
    final Widget collapsedRow = Row(
      key: const ValueKey<String>('now-playing-docked-collapsed'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _AppleCover(bar: bar, size: cover),
        const SizedBox(width: _kAppleMacCoverGap),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _kAppleCollapsedTitleMax * s),
            child: _AppleTitleBlock(bar: bar, showSubtitle: false),
          ),
        ),
        const SizedBox(width: _kAppleMacActionsGap),
        _applePlay(bar),
      ],
    );
    final Widget openRow = Row(
      key: const ValueKey<String>('now-playing-docked-expanded'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _AppleCover(bar: bar, size: cover),
        const SizedBox(width: _kAppleMacCoverGap),
        // 栏窄时标题弹性让位（单行省略）；按钮数已按 [_AppleRowBudget] 收过。
        Flexible(
          child: SizedBox(
            width: _kAppleTitleWidth * s,
            child: _AppleTitleBlock(bar: bar),
          ),
        ),
        const SizedBox(width: _kAppleMacTitleGap),
        if (prev != null) _appleSkip(prev, forward: false),
        _applePlay(bar),
        if (next != null) _appleSkip(next, forward: true),
        if (actions.isNotEmpty) const SizedBox(width: _kAppleMacActionsGap),
        ...actions,
      ],
    );
    final double radius = _kAppleMacRadius * s;
    return Padding(
      padding: _kAppleMacOuter,
      child: AnimatedAlign(
        duration: motion,
        curve: FushiSpringCurve.effects,
        heightFactor: 1,
        alignment: Alignment.center,
        child: ContextMenuTrigger(
          onInvoke: contextMenuInvoker(expanded ? more : null),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pinned = false;
            }),
            child: TapRegion(
              onTapOutside: (_) {
                if (_pinned) setState(() => _pinned = false);
              },
              child: _HoldScope(
                onHold: _hold,
                child: _AppleBarSurface(
                  bar: bar,
                  tint: widget.tint,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  padding: expanded
                      ? _kAppleMacPadding
                      : _kAppleMacPadding.copyWith(
                          end: _kAppleMacPaddingCollapsedEnd,
                        ),
                  // 收起时第一下只展开（触屏没有悬停）；展开后点条身才是条身动作。
                  onTap: expanded
                      ? bar.onTap
                      : () => setState(() => _pinned = true),
                  onLongPress: expanded ? more : null,
                  overlay: bar.clock == null
                      ? null
                      : PositionedDirectional(
                          start: radius,
                          end: radius,
                          bottom: 2,
                          height: 2,
                          child: _AppleProgressLine(bar: bar),
                        ),
                  child: FushiAnimatedSize(
                    duration: motion,
                    curve: FushiSpringCurve.spatial,
                    child: AnimatedSwitcher(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      layoutBuilder: (Widget? current, List<Widget> previous) =>
                          Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: <Widget>[
                              for (final Widget w in previous)
                                Positioned(child: w),
                              ?current,
                            ],
                          ),
                      child: expanded ? openRow : collapsedRow,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS 档底边细进度线（读 [FushiPlaybackClock]，与 M3E 封面圆环同一刷新规则：
/// 播放中按 [kFushiNowPlayingProgressTick] 刷新，暂停 / [TickerMode] 关时不计时）。
/// 纯装饰：不进语义、不参与命中。
class _AppleProgressLine extends StatefulWidget {
  const _AppleProgressLine({required this.bar});

  final FushiNowPlayingBar bar;

  @override
  State<_AppleProgressLine> createState() => _AppleProgressLineState();
}

class _AppleProgressLineState extends State<_AppleProgressLine>
    with StateResourceScope<_AppleProgressLine> {
  Timer? _ticker;
  bool _tickerModeEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(_AppleProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _sync() {
    final bool run =
        widget.bar.isPlaying && widget.bar.clock != null && _tickerModeEnabled;
    if (run && _ticker == null) {
      _ticker = ownTimer(
        Timer.periodic(kFushiNowPlayingProgressTick, (_) {
          if (mounted) setState(() {});
        }),
        slot: #ticker,
      );
    } else if (!run) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  double _progress() {
    final FushiPlaybackClock? clock = widget.bar.clock;
    if (clock == null) return 0;
    final int total = clock.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (clock.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: FushiAppleRadii.of(context).markRadius,
          child: ColoredBox(
            color: apple.label.withValues(alpha: 0.10),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: _progress(),
                heightFactor: 1,
                child: ColoredBox(color: apple.secondaryLabel),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
