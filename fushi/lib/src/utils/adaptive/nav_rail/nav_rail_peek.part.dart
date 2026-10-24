part of '../adaptive_navigation.dart';

/// 速览卡里的一个条目（继续项或最近项）。
@immutable
class AdaptiveNavPeekEntry {
  const AdaptiveNavPeekEntry({
    required this.title,
    required this.onOpen,
    this.cover,
    this.subtitle,
    this.progress,
  });

  final String title;

  /// 封面；null = 画模块图标占位。
  final ImageProvider? cover;

  /// 继续项的副标题（「第 3 卷 · 42%」之类），最近项不读。
  final String? subtitle;

  /// 0..1；null = 没有进度（游戏）。
  final double? progress;

  /// 点了直接打开这个条目（打开阅读器 / 播放器 / 切到对应库页）。
  final VoidCallback onOpen;
}

/// 一次速览加载的结果。
@immutable
class AdaptiveNavPeekData {
  const AdaptiveNavPeekData({
    this.resume,
    this.recent = const <AdaptiveNavPeekEntry>[],
  });

  final AdaptiveNavPeekEntry? resume;

  /// 最多画 4 个。
  final List<AdaptiveNavPeekEntry> recent;

  bool get isEmpty => resume == null && recent.isEmpty;
}

/// [AdaptiveNavItem.peek]：MD3 侧栏悬停速览卡的数据源。
@immutable
class AdaptiveNavPeek {
  const AdaptiveNavPeek({required this.load});

  /// 每次卡片对这一项打开时调用（同一项 30 秒内复用上次结果）。
  final Future<AdaptiveNavPeekData> Function() load;
}

/// 第一次悬停到速览卡弹出的延迟：鼠标只是路过侧栏不弹。卡已打开时在图标间
/// 移动零延迟跟随。
const Duration _kNavPeekOpenDelay = Duration(milliseconds: 220);

/// 鼠标离开侧栏与卡片后的宽限：斜着移向卡片时穿过两者之间的缝不会关掉。
const Duration _kNavPeekCloseGrace = Duration(milliseconds: 260);

/// 同一项的速览数据缓存多久。
const Duration _kNavPeekCacheTtl = Duration(seconds: 30);

const double _kNavPeekWidth = 320;
const double _kNavPeekGap = 10;

/// 收起 / 展开 rail 的格向速览卡登记自己：悬停进出与卡片定位都经它。
class _NavRailPeekRegistry extends InheritedWidget {
  const _NavRailPeekRegistry({required this.state, required super.child});

  final _NavRailPeekScopeState state;

  @override
  bool updateShouldNotify(_NavRailPeekRegistry oldWidget) =>
      !identical(oldWidget.state, state);
}

/// MD3 侧栏的悬停速览卡（M3E 组合方案，2026-10-23）：鼠标在某个目的地上停
/// [_kNavPeekOpenDelay] 后，侧栏右侧弹出一张卡——「继续」条目（封面 + 波浪
/// 进度）、最近 4 个条目、打开模块。卡片打开后在图标之间移动不关闭，只是
/// 弹簧滑到新图标旁、内容按移动方向上下交换。只认鼠标（触摸没有悬停）；
/// 墨水屏 / 减弱动态效果下没有滑动与形变，直接到位。
class _NavRailPeekScope extends StatefulWidget {
  const _NavRailPeekScope({required this.enabled, required this.child});

  /// false（Apple 设计系统）时整层透明：格不登记、卡不弹。
  final bool enabled;
  final Widget child;

  static _NavRailPeekScopeState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NavRailPeekRegistry>()?.state;

  @override
  State<_NavRailPeekScope> createState() => _NavRailPeekScopeState();
}

class _NavRailPeekTarget {
  const _NavRailPeekTarget({
    required this.id,
    required this.item,
    required this.anchor,
    required this.order,
    required this.onSelect,
    this.shape,
  });

  final FushiFocusId id;
  final AdaptiveNavItem item;
  final GlobalKey anchor;

  /// 在侧栏里的上下次序，决定内容交换的滑动方向。
  final int order;
  final VoidCallback onSelect;

  /// 这一项的专属形状（卡片标题前那枚小形状与侧栏选中形状一致）。
  final RoundedPolygon? shape;
}

class _NavRailPeekScopeState extends State<_NavRailPeekScope>
    with TickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  late final FushiSpring _open = FushiSpring(
    vsync: this,
    spring: _kNavExpressiveSpatial,
  );

  /// 卡片纵向锚点（图标中心，overlay 坐标）：[_move] 从 [_fromY] 走到 [_toY]。
  late final FushiSpring _move = FushiSpring(
    vsync: this,
    initial: 1,
    spring: _kNavExpressiveSpatial,
  );
  double _fromY = 0;
  double _toY = 0;
  double _left = 0;

  _NavRailPeekTarget? _target;

  /// 内容交换方向：1 = 往下移（新内容从下面进来）。
  int _direction = 1;

  Timer? _openTimer;
  Timer? _closeTimer;
  final Map<FushiFocusId, (DateTime, Future<AdaptiveNavPeekData>)> _cache =
      <FushiFocusId, (DateTime, Future<AdaptiveNavPeekData>)>{};

  bool get _motion => fushiExpressiveMotionEnabled(context);

  @override
  void initState() {
    super.initState();
    _open.animation.addStatusListener(_onOpenStatus);
  }

  void _onOpenStatus(AnimationStatus status) {
    if (!status.isAnimating && _open.target == 0 && _portal.isShowing) {
      _portal.hide();
    }
  }

  Future<AdaptiveNavPeekData> _dataFor(_NavRailPeekTarget target) {
    final (DateTime, Future<AdaptiveNavPeekData>)? hit = _cache[target.id];
    final DateTime now = DateTime.now();
    if (hit != null && now.difference(hit.$1) < _kNavPeekCacheTtl) {
      return hit.$2;
    }
    final Future<AdaptiveNavPeekData> future = target.item.peek!.load();
    _cache[target.id] = (now, future);
    return future;
  }

  /// 鼠标进入一个有速览的目的地。
  void enter(_NavRailPeekTarget target) {
    if (!widget.enabled) return;
    _closeTimer?.cancel();
    _openTimer?.cancel();
    if (_portal.isShowing && _open.target == 1) {
      _show(target);
    } else {
      _openTimer = Timer(_kNavPeekOpenDelay, () {
        if (mounted) _show(target);
      });
    }
  }

  /// 鼠标离开目的地或卡片：宽限后关。
  void leave() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _closeTimer = Timer(_kNavPeekCloseGrace, close);
  }

  void close() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (!_portal.isShowing) return;
    _open.animateTo(0, animate: _motion);
    if (!_motion) _portal.hide();
  }

  void _keepOpen() => _closeTimer?.cancel();

  ({double left, double centerY})? _anchorOf(_NavRailPeekTarget target) {
    final RenderObject? overlay = Overlay.maybeOf(
      context,
    )?.context.findRenderObject();
    final RenderObject? rail = context.findRenderObject();
    final RenderObject? anchor = target.anchor.currentContext
        ?.findRenderObject();
    if (overlay is! RenderBox ||
        rail is! RenderBox ||
        anchor is! RenderBox ||
        !anchor.attached ||
        !rail.hasSize ||
        !anchor.hasSize) {
      return null;
    }
    final Offset railTopRight = rail.localToGlobal(
      Offset(rail.size.width, 0),
      ancestor: overlay,
    );
    final Offset anchorCenter = anchor.localToGlobal(
      anchor.size.center(Offset.zero),
      ancestor: overlay,
    );
    return (left: railTopRight.dx + _kNavPeekGap, centerY: anchorCenter.dy);
  }

  void _show(_NavRailPeekTarget target) {
    final ({double left, double centerY})? anchor = _anchorOf(target);
    if (anchor == null) return;
    final bool wasOpen = _portal.isShowing && _open.target == 1;
    final _NavRailPeekTarget? previous = _target;
    setState(() {
      _direction = previous == null || target.order >= previous.order ? 1 : -1;
      _target = target;
      _left = anchor.left;
      if (wasOpen) {
        _fromY = _currentY;
        _toY = anchor.centerY;
        _move.animateTo(0, animate: false);
        _move.animateTo(1, animate: _motion);
      } else {
        _fromY = anchor.centerY;
        _toY = anchor.centerY;
        _move.animateTo(1, animate: false);
      }
    });
    _dataFor(target);
    if (!_portal.isShowing) _portal.show();
    _open.animateTo(1, animate: _motion);
  }

  double get _currentY => _fromY + (_toY - _fromY) * _move.value;

  void _openModule(_NavRailPeekTarget target) {
    close();
    target.onSelect();
  }

  void _openEntry(AdaptiveNavPeekEntry entry) {
    close();
    entry.onOpen();
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _open.animation.removeStatusListener(_onOpenStatus);
    _open.dispose();
    _move.dispose();
    super.dispose();
  }

  Widget _buildOverlay(BuildContext context) {
    final _NavRailPeekTarget? target = _target;
    if (target == null) return const SizedBox.shrink();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color surface = eink
        ? colors.surface
        : FushiDesignTokens.of(context).surfaces.search;
    final Widget content = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.topLeft,
        children: <Widget>[
          for (final Widget child in previous)
            Positioned(left: 0, right: 0, top: 0, child: child),
          ?current,
        ],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) {
        final bool incoming = child.key == ValueKey<FushiFocusId>(target.id);
        final double dy = 0.18 * _direction * (incoming ? 1 : -1);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, dy),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: _NavRailPeekContent(
        key: ValueKey<FushiFocusId>(target.id),
        item: target.item,
        shape: target.shape,
        data: _dataFor(target),
        onOpenModule: () => _openModule(target),
        onOpenEntry: _openEntry,
      ),
    );
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _open.animation,
        _move.animation,
      ]),
      builder: (BuildContext context, Widget? card) {
        final double t = _open.value.clamp(0.0, 1.2);
        final double centerY = _currentY;
        return Stack(
          children: <Widget>[
            CustomSingleChildLayout(
              delegate: _NavPeekLayout(left: _left, centerY: centerY),
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform(
                  alignment: Alignment.centerLeft,
                  transform: Matrix4.identity()
                    ..translateByDouble(-12 * (1 - t), 0, 0, 1)
                    ..scaleByDouble(0.9 + 0.1 * t, 0.9 + 0.1 * t, 1, 1),
                  child: card,
                ),
              ),
            ),
          ],
        );
      },
      child: MouseRegion(
        onEnter: (_) => _keepOpen(),
        onExit: (_) => leave(),
        child: TapRegion(
          onTapOutside: (_) => close(),
          child: Material(
            color: surface,
            elevation: eink ? 0 : 3,
            shadowColor: colors.shadow,
            shape: RoundedRectangleBorder(
              borderRadius: FushiM3eShape.containerLargeRadius,
              side: eink
                  ? BorderSide(color: colors.onSurface)
                  : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: _kNavPeekWidth,
              child: FushiAnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                alignment: Alignment.topCenter,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _NavRailPeekRegistry(
      state: this,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildOverlay,
        child: widget.child,
      ),
    );
  }
}

/// 卡片贴在侧栏右侧：左缘固定，纵向让卡片头部对齐图标（图标中心往上 56），
/// 再夹进窗口上下各 12 之内。
class _NavPeekLayout extends SingleChildLayoutDelegate {
  const _NavPeekLayout({required this.left, required this.centerY});

  final double left;
  final double centerY;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxTop = math.max(12, size.height - childSize.height - 12);
    return Offset(left, (centerY - 56).clamp(12.0, maxTop));
  }

  @override
  bool shouldRelayout(_NavPeekLayout oldDelegate) =>
      oldDelegate.left != left || oldDelegate.centerY != centerY;
}

class _NavRailPeekContent extends StatelessWidget {
  const _NavRailPeekContent({
    super.key,
    required this.item,
    required this.shape,
    required this.data,
    required this.onOpenModule,
    required this.onOpenEntry,
  });

  final AdaptiveNavItem item;
  final RoundedPolygon? shape;
  final Future<AdaptiveNavPeekData> data;
  final VoidCallback onOpenModule;
  final ValueChanged<AdaptiveNavPeekEntry> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 22,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.primary,
                    shape: MaterialShapeBorder(
                      shape: shape ?? MaterialShapes.cookie9Sided,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FushiFilledButton.tonal(
                onPressed: onOpenModule,
                child: Text(t.nav_peek_open),
              ),
            ],
          ),
          FutureBuilder<AdaptiveNavPeekData>(
            future: data,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<AdaptiveNavPeekData> snapshot,
                ) {
                  final AdaptiveNavPeekData? value = snapshot.data;
                  if (value == null) {
                    return snapshot.hasError
                        ? const SizedBox(height: 8)
                        : const Padding(
                            padding: EdgeInsets.only(top: 16, bottom: 8),
                            child: FushiLinearProgressIndicator(),
                          );
                  }
                  if (value.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        t.home_continue_empty,
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (value.resume case final AdaptiveNavPeekEntry entry)
                        _NavPeekResume(
                          entry: entry,
                          fallbackIcon: item.icon,
                          onOpen: () => onOpenEntry(entry),
                        ),
                      if (value.recent.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          t.nav_peek_recent,
                          style: text.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            for (int i = 0; i < 4; i++) ...<Widget>[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(
                                child: i < value.recent.length
                                    ? _NavPeekRecent(
                                        entry: value.recent[i],
                                        fallbackIcon: item.icon,
                                        onOpen: () =>
                                            onOpenEntry(value.recent[i]),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  );
                },
          ),
        ],
      ),
    );
  }
}

/// 速览卡里的封面：没有封面时画模块图标占位。
class _NavPeekCover extends StatelessWidget {
  const _NavPeekCover({
    required this.image,
    required this.fallbackIcon,
    required this.radius,
  });

  final ImageProvider? image;
  final IconData fallbackIcon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget placeholder = ColoredBox(
      color: FushiDesignTokens.of(context).surfaces.overlay,
      child: Center(
        child: FushiIcon(fallbackIcon, color: colors.onSurfaceVariant),
      ),
    );
    final ImageProvider? provider = image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: provider == null
            ? placeholder
            : Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _NavPeekResume extends StatelessWidget {
  const _NavPeekResume({
    required this.entry,
    required this.fallbackIcon,
    required this.onOpen,
  });

  final AdaptiveNavPeekEntry entry;
  final IconData fallbackIcon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final double? progress = entry.progress;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: FushiPressScale(
        child: Material(
          color: colors.surfaceContainer,
          borderRadius: FushiM3eShape.cardRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 56,
                    child: _NavPeekCover(
                      image: entry.cover,
                      fallbackIcon: fallbackIcon,
                      radius: 10,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.home_continue,
                          style: text.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.subtitle case final String subtitle)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (progress != null) ...<Widget>[
                          const SizedBox(height: 10),
                          FushiWavyLinearProgress(
                            value: progress.clamp(0.0, 1.0),
                            color: colors.primary,
                            trackColor: FushiDesignTokens.of(
                              context,
                            ).surfaces.overlay,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavPeekRecent extends StatelessWidget {
  const _NavPeekRecent({
    required this.entry,
    required this.fallbackIcon,
    required this.onOpen,
  });

  final AdaptiveNavPeekEntry entry;
  final IconData fallbackIcon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return FushiTooltip(
      message: entry.title,
      child: FushiHoverLift(
        builder: (BuildContext context, bool _) => FushiPressScale(
          child: Semantics(
            button: true,
            label: entry.title,
            child: GestureDetector(
              onTap: onOpen,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: _NavPeekCover(
                  image: entry.cover,
                  fallbackIcon: fallbackIcon,
                  radius: 10,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
