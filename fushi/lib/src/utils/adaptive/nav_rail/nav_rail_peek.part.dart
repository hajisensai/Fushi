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
    this.icon,
  });

  final String title;

  /// 没有封面时（以及列表式一行前面）画的图标；null = 模块图标。设置分类、
  /// 网页这类每行是不同东西的目的地用它区分。
  final IconData? icon;

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
    this.listLayout = false,
    this.resumeLabel,
    this.recentLabel,
  });

  final AdaptiveNavPeekEntry? resume;

  /// 最多画 4 个。
  final List<AdaptiveNavPeekEntry> recent;

  /// true = 没有封面的目的地（复习的牌组）：「继续」不画封面，[recent] 画成
  /// 「名称 + 副行」的列表，而不是一排只有图标占位、看不出是什么的封面。
  final bool listLayout;

  /// 「继续」卡上方的小字；null = 「继续」。
  final String? resumeLabel;

  /// [recent] 上方的小标题；null = 「最近」。
  final String? recentLabel;

  bool get isEmpty => resume == null && recent.isEmpty;
}

/// [AdaptiveNavItem.peek]：MD3 侧栏悬停速览卡的数据源。
@immutable
class AdaptiveNavPeek {
  const AdaptiveNavPeek({required this.load, this.coverMaterial});

  /// 每次卡片对这一项打开时调用（同一项 30 秒内复用上次结果）。
  final Future<AdaptiveNavPeekData> Function() load;

  /// 这一分区封面的库页条目材质（书 / 漫画光面书皮、视频光面海报、游戏卡盒；
  /// 用户 2026-10-26）。速览卡的封面都是小图，走材质简化档；null = 旧圆角框。
  final ShelfCoverMaterial? coverMaterial;
}

/// 第一次悬停到速览卡弹出的延迟：鼠标只是路过侧栏不弹。卡已打开时在图标间
/// 移动零延迟跟随。
const Duration _kNavPeekOpenDelay = Duration(milliseconds: 220);

/// 鼠标离开侧栏与卡片后的宽限：斜着移向卡片时穿过两者之间的缝不会关掉。
const Duration _kNavPeekCloseGrace = Duration(milliseconds: 260);

/// 同一项的速览数据缓存多久。
const Duration _kNavPeekCacheTtl = Duration(seconds: 30);

const double _kNavPeekWidth = 360;
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
                  final Widget body = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (value.resume case final AdaptiveNavPeekEntry entry)
                        _NavPeekResume(
                          entry: entry,
                          label: value.resumeLabel ?? t.home_continue,
                          showCover: !value.listLayout,
                          fallbackIcon: entry.icon ?? item.icon,
                          onOpen: () => onOpenEntry(entry),
                        ),
                      if (value.recent.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          value.recentLabel ?? t.nav_peek_recent,
                          style: text.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (value.listLayout)
                          for (final AdaptiveNavPeekEntry e in value.recent)
                            _NavPeekListRow(
                              entry: e,
                              fallbackIcon: e.icon ?? item.icon,
                              onOpen: () => onOpenEntry(e),
                            )
                        else
                          _NavPeekImageAspects(
                            images: <ImageProvider?>[
                              for (final AdaptiveNavPeekEntry e in value.recent)
                                e.cover,
                            ],
                            builder:
                                (
                                  BuildContext context,
                                  List<double> aspects,
                                ) => LayoutBuilder(
                                  builder: (BuildContext context, BoxConstraints box) {
                                    final List<List<double>> rows =
                                        navPeekRecentLayout(
                                          aspects: aspects,
                                          maxWidth: box.maxWidth,
                                        );
                                    final List<int> starts = <int>[0];
                                    for (final List<double> row in rows) {
                                      starts.add(starts.last + row.length);
                                    }
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      spacing: kNavPeekRecentGap,
                                      children: <Widget>[
                                        for (int r = 0; r < rows.length; r++)
                                          Row(
                                            spacing: kNavPeekRecentGap,
                                            children: <Widget>[
                                              for (
                                                int j = 0;
                                                j < rows[r].length;
                                                j++
                                              )
                                                SizedBox(
                                                  width: rows[r][j],
                                                  child: _NavPeekRecent(
                                                    entry: value
                                                        .recent[starts[r] + j],
                                                    aspectRatio:
                                                        aspects[starts[r] + j],
                                                    fallbackIcon:
                                                        value
                                                            .recent[starts[r] +
                                                                j]
                                                            .icon ??
                                                        item.icon,
                                                    onOpen: () => onOpenEntry(
                                                      value.recent[starts[r] +
                                                          j],
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                      ],
                                    );
                                  },
                                ),
                          ),
                      ],
                    ],
                  );
                  final ShelfCoverMaterial? material = item.peek?.coverMaterial;
                  return material == null
                      ? body
                      : ShelfCoverMaterialScope(
                          material: material,
                          child: body,
                        );
                },
          ),
        ],
      ),
    );
  }
}

/// 速览卡里的封面：没有封面时画模块图标占位。分区给了材质
/// （[AdaptiveNavPeek.coverMaterial]）时走材质简化档（圆角 + 内描边 + 轻
/// 光泽），否则 / 墨水屏下保留 [radius] 圆角框。
class _NavPeekCover extends StatelessWidget {
  const _NavPeekCover({
    required this.image,
    required this.fallbackIcon,
    required this.radius,
    this.aspectRatio = kNavPeekDefaultCoverAspect,
  });

  final ImageProvider? image;
  final IconData fallbackIcon;
  final double radius;

  /// 封面框的宽高比：取封面图自己的比例（[_NavPeekImageAspects]），横版视频
  /// 缩略图因此整张显示、不被裁成竖版。
  final double aspectRatio;

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
    final Widget cover = provider == null
        ? placeholder
        : Image(
            image: provider,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
    if (shelfCoverMaterialOf(context) != null) {
      return AspectRatio(
        aspectRatio: aspectRatio,
        child: ShelfCoverFrame(
          density: ShelfCoverDensity.compact,
          child: cover,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(aspectRatio: aspectRatio, child: cover),
    );
  }
}

class _NavPeekResume extends StatelessWidget {
  const _NavPeekResume({
    required this.entry,
    required this.label,
    required this.showCover,
    required this.fallbackIcon,
    required this.onOpen,
  });

  final AdaptiveNavPeekEntry entry;

  /// 卡片上方的小字（「继续」/「开始复习」）。
  final String label;

  /// false = 没有封面的目的地（牌组），只画文字。
  final bool showCover;
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
                  if (showCover) ...<Widget>[
                    _NavPeekImageAspects(
                      images: <ImageProvider?>[entry.cover],
                      builder: (BuildContext context, List<double> aspects) {
                        final double width = navPeekResumeCoverWidth(
                          aspects.single,
                        );
                        return SizedBox(
                          width: width,
                          height: kNavPeekResumeCoverHeight,
                          child: _NavPeekCover(
                            image: entry.cover,
                            fallbackIcon: fallbackIcon,
                            radius: 10,
                            aspectRatio: width / kNavPeekResumeCoverHeight,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          label,
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
    required this.aspectRatio,
    required this.fallbackIcon,
    required this.onOpen,
  });

  final AdaptiveNavPeekEntry entry;
  final double aspectRatio;
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
                // 封面下写上名字：只有封面时看不出最近看的是哪部（2026-10-25
                // 用户「媒体的话最近看的是什么」）。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _NavPeekCover(
                      image: entry.cover,
                      fallbackIcon: fallbackIcon,
                      radius: 10,
                      aspectRatio: aspectRatio,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表式速览（[AdaptiveNavPeekData.listLayout]）的一行：模块图标 + 名称 +
/// 副行（牌组的今日计数 / 「今日已完成」）。
class _NavPeekListRow extends StatelessWidget {
  const _NavPeekListRow({
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
    return FushiPressScale(
      child: Material(
        type: MaterialType.transparency,
        borderRadius: FushiM3eShape.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: <Widget>[
                FushiIcon(
                  fallbackIcon,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entry.subtitle case final String subtitle) ...<Widget>[
                  const SizedBox(width: 10),
                  Text(
                    subtitle,
                    maxLines: 1,
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 速览卡封面的默认宽高比（书封 2:3；封面图还没解出尺寸、或没有封面时用）。
const double kNavPeekDefaultCoverAspect = 2 / 3;

/// 「最近」一排封面之间的缝。
const double kNavPeekRecentGap = 8;

/// 「继续」条目封面的固定高度（宽度按封面比例算，见 [navPeekResumeCoverWidth]）。
const double kNavPeekResumeCoverHeight = 100;

/// 「继续」封面的宽度：固定高 [kNavPeekResumeCoverHeight] 乘封面比例，夹在
/// 56–180 之间（横版视频缩略图整张显示，又不至于把标题挤没）。
double navPeekResumeCoverWidth(double aspect) =>
    (kNavPeekResumeCoverHeight * aspect).clamp(56.0, 180.0).toDouble();

/// 「最近」封面的最低高度：一排挤下去低于它就换成两排（横版视频四张一排只有
/// 四十来像素高，2026-10-25 用户「预览有点小，视频横屏看着难受」）。
const double kNavPeekRecentMinHeight = 80;

/// 「最近」封面的排布：返回若干排、每排各封面的宽度（条目按顺序依次填）。
///
/// - 所有封面**同一高度**、按各自比例整张显示（横版视频与竖版书封混排也不裁）；
/// - 先试一排；一排铺满后高度低于 [kNavPeekRecentMinHeight] 就每排少放一张、
///   依次往下排，直到够高（四张横版视频 → 2 × 2）；
/// - 高度不超过「4 本竖版书封一排」的高度：条目少时不放大成巨图。
List<List<double>> navPeekRecentLayout({
  required List<double> aspects,
  required double maxWidth,
}) {
  if (aspects.isEmpty || maxWidth <= 0) return const <List<double>>[];
  final double cap =
      (maxWidth - kNavPeekRecentGap * 3) / 4 / kNavPeekDefaultCoverAspect;
  // 每排 perRow 张时，所有排共用的高度（各排铺满宽度时高度的最小值）。
  double heightFor(int perRow) {
    double height = cap;
    for (int start = 0; start < aspects.length; start += perRow) {
      final List<double> row = aspects.sublist(
        start,
        math.min(aspects.length, start + perRow),
      );
      final double sum = row.fold<double>(0, (double a, double b) => a + b);
      final double usable = maxWidth - kNavPeekRecentGap * (row.length - 1);
      height = math.min(height, usable / sum);
    }
    return height;
  }

  int perRow = aspects.length;
  while (perRow > 1 && heightFor(perRow) < kNavPeekRecentMinHeight) {
    perRow--;
  }
  final double height = heightFor(perRow);
  return <List<double>>[
    for (int start = 0; start < aspects.length; start += perRow)
      <double>[
        for (final double a in aspects.sublist(
          start,
          math.min(aspects.length, start + perRow),
        ))
          height * a,
      ],
  ];
}

/// 解出每张封面图自己的宽高比，交给 [builder]；没有封面、还没解出或解码失败
/// 的位置给 [kNavPeekDefaultCoverAspect]。图换了（数据刷新）就重新解。
class _NavPeekImageAspects extends StatefulWidget {
  const _NavPeekImageAspects({required this.images, required this.builder});

  final List<ImageProvider?> images;
  final Widget Function(BuildContext context, List<double> aspects) builder;

  @override
  State<_NavPeekImageAspects> createState() => _NavPeekImageAspectsState();
}

class _NavPeekImageAspectsState extends State<_NavPeekImageAspects> {
  final List<ImageStream?> _streams = <ImageStream?>[];
  final List<ImageStreamListener?> _listeners = <ImageStreamListener?>[];
  List<double> _aspects = const <double>[];
  bool _resolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_resolved) _resolve();
  }

  @override
  void didUpdateWidget(_NavPeekImageAspects oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.images, widget.images)) _resolve();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    for (int i = 0; i < _streams.length; i++) {
      final ImageStreamListener? listener = _listeners[i];
      if (listener != null) _streams[i]?.removeListener(listener);
    }
    _streams.clear();
    _listeners.clear();
  }

  void _resolve() {
    _resolved = true;
    _detach();
    _aspects = <double>[
      for (int i = 0; i < widget.images.length; i++) kNavPeekDefaultCoverAspect,
    ];
    final ImageConfiguration config = createLocalImageConfiguration(context);
    for (int i = 0; i < widget.images.length; i++) {
      final ImageProvider? image = widget.images[i];
      if (image == null) {
        _streams.add(null);
        _listeners.add(null);
        continue;
      }
      final int index = i;
      final ImageStream stream = image.resolve(config);
      final ImageStreamListener listener = ImageStreamListener((
        ImageInfo info,
        bool synchronousCall,
      ) {
        final double w = info.image.width.toDouble();
        final double h = info.image.height.toDouble();
        info.dispose();
        if (!mounted || w <= 0 || h <= 0) return;
        final double aspect = w / h;
        if ((_aspects[index] - aspect).abs() < 0.001) return;
        final List<double> next = List<double>.of(_aspects);
        next[index] = aspect;
        if (synchronousCall) {
          _aspects = next;
        } else {
          setState(() => _aspects = next);
        }
      }, onError: (Object error, StackTrace? stack) {});
      stream.addListener(listener);
      _streams.add(stream);
      _listeners.add(listener);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _aspects);
}
