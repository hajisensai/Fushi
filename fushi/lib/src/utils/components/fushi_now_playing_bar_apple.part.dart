part of 'fushi_now_playing_bar.dart';

// [FushiNowPlayingBar] 的 Apple 设计系统分支（Apple Music iOS 27 / macOS 27
// 迷你播放器）。由 [_FushiNowPlayingBarState.build] 按 `isGlassDesign` 分派，
// M3E 的取色色块 / 出血大字 / 饼干形封面圆环一概不用：
//
// - 外壳：中性栏玻璃（[fushiClearGlassSettings] bar 档 + 静止不画高光边的
//   [fushiGlassButtonRestSettings]），实色档是系统材质实色浮层；不取封面色。
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
//   全部额外动作平铺，底边一条细进度线；宿主往下滚时缩成「封面 + 标题 + 播放键」，
//   悬停 / 点一下展开（与 M3E 宽屏同一套 hover / pin / hold 规则）。

/// Apple 分支裸字形按钮的命中区（≥ 44，底部浮动条的触控下限）。额外动作里的
/// Apple 按钮也传这个值，与传输键同一行高。
const double kFushiNowPlayingAppleGlyphExtent = 44;

/// 封面连续曲率圆角半径（Apple Music 迷你播放器封面约 6–8）。
const double _kAppleCoverRadius = 7;

/// iOS 档封面边长。
const double _kAppleCoverIos = 40;

/// macOS 档封面边长（再乘 [fushiAppleMacScale]）。
const double _kAppleCoverMac = 38;

/// macOS 档条身圆角（再乘 [fushiAppleMacScale]）。
const double _kAppleMacRadius = 16;

class _AppleNowPlayingBar extends StatelessWidget {
  const _AppleNowPlayingBar({required this.bar});

  final FushiNowPlayingBar bar;

  @override
  Widget build(BuildContext context) => fushiAppleCompact(context)
      ? _AppleMacBar(bar: bar)
      : _AppleCapsuleBar(bar: bar);
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
    borderRadius: BorderRadius.circular(_kAppleCoverRadius),
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
    this.onLongPress,
    this.overlay,
  });

  final FushiNowPlayingBar bar;
  final OutlinedBorder shape;
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
    final Widget surface = glassMaterialOf(context) == FushiGlassMaterial.off
        ? DecoratedBox(
            decoration: fushiAppleSolidFloatingDecoration(
              context,
              shape: shape,
            ),
            child: content,
          )
        : GlassContainer(
            // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
            useOwnLayer: true,
            quality: fushiGlassQuality(context, prominent: true),
            shape: fushiLiquidShapeOf(shape),
            settings: fushiGlassButtonRestSettings(
              fushiClearGlassSettings(context, bar: true),
            ),
            platformViewBackdrop: fushiGlassOverPlatformView(context),
            child: content,
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
  const _AppleCapsuleBar({required this.bar});

  final FushiNowPlayingBar bar;

  @override
  Widget build(BuildContext context) => _CollapsePeek(
    builder: (BuildContext context, bool collapsed, VoidCallback peek) {
      final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
      final VoidCallback? more = bar.onMore;
      final FushiNowPlayingSkip? next = bar.next;
      final Widget card = _AppleBarSurface(
        bar: bar,
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
  const _AppleMacBar({required this.bar});

  final FushiNowPlayingBar bar;

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
    final Widget collapsedRow = Row(
      key: const ValueKey<String>('now-playing-docked-collapsed'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _AppleCover(bar: bar, size: cover),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 200 * s),
          child: _AppleTitleBlock(bar: bar, showSubtitle: false),
        ),
        const SizedBox(width: 6),
        _applePlay(bar),
      ],
    );
    final Widget openRow = Row(
      key: const ValueKey<String>('now-playing-docked-expanded'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _AppleCover(bar: bar, size: cover),
        const SizedBox(width: 10),
        // 窗口窄时标题让位，按钮不挤出界。
        Flexible(
          child: SizedBox(
            width: 220 * s,
            child: _AppleTitleBlock(bar: bar),
          ),
        ),
        const SizedBox(width: 8),
        if (prev != null) _appleSkip(prev, forward: false),
        _applePlay(bar),
        if (next != null) _appleSkip(next, forward: true),
        if (bar.actions.isNotEmpty) const SizedBox(width: 6),
        ...bar.actions,
      ],
    );
    final double radius = _kAppleMacRadius * s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: AnimatedAlign(
        duration: motion,
        curve: FushiSpringCurve.effects,
        heightFactor: 1,
        alignment: Alignment.center,
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
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
                padding: EdgeInsetsDirectional.fromSTEB(
                  6,
                  6,
                  expanded ? 8 : 4,
                  6,
                ),
                // 收起时第一下只展开（触屏没有悬停）；展开后点条身才是条身动作。
                onTap: expanded
                    ? bar.onTap
                    : () => setState(() => _pinned = true),
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

class _AppleProgressLineState extends State<_AppleProgressLine> {
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
      _ticker = Timer.periodic(kFushiNowPlayingProgressTick, (_) {
        if (mounted) setState(() {});
      });
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
          borderRadius: BorderRadius.circular(1),
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
