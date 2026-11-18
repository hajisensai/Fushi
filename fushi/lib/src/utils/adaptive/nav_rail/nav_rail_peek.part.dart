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
    this.status,
    this.statusTone = AdaptiveNavPeekStatusTone.neutral,
    this.blurCover = false,
  });

  final String title;

  /// 封面要按「模糊 NSFW 封面」打模糊（拍板台 w04vrhUAaX；判定由加载方按快照
  /// 算好，速览卡本身不认识数据库）。
  final bool blurCover;

  /// 没有封面时（以及列表式一行前面）画的图标；null = 模块图标。设置分类、
  /// 网页这类每行是不同东西的目的地用它区分。
  final IconData? icon;

  /// 封面；null = 画模块图标占位。
  final ImageProvider? cover;

  /// 继续项的副标题（「第 3 卷 · 42%」之类），最近项不读。
  final String? subtitle;

  /// 0..1；null = 没有进度（游戏）。
  final double? progress;

  /// 列表行尾部的状态小签（「42%」「已完成」「需要处理」）；null = 不画。
  final String? status;

  /// [status] 的语义色。
  final AdaptiveNavPeekStatusTone statusTone;

  /// 点了直接打开这个条目（打开阅读器 / 播放器 / 切到对应库页）。
  final VoidCallback onOpen;
}

/// 速览条目状态小签的语义色。
enum AdaptiveNavPeekStatusTone { neutral, active, done, attention, error }

/// 一次速览加载的结果。
@immutable
class AdaptiveNavPeekData {
  const AdaptiveNavPeekData({
    this.resume,
    this.recent = const <AdaptiveNavPeekEntry>[],
    this.listLayout = false,
    this.resumeLabel,
    this.recentLabel,
    this.summary,
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

  /// 页头标题下的一行概况（「2 个进行中 · 5 个已完成」）；null = 不画。
  final String? summary;

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
    return FutureBuilder<AdaptiveNavPeekData>(
      future: data,
      builder:
          (BuildContext context, AsyncSnapshot<AdaptiveNavPeekData> snapshot) {
            final AdaptiveNavPeekData? value = snapshot.data;
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(context, value?.summary),
                  _body(context, snapshot),
                ],
              ),
            );
          },
    );
  }

  /// 页头：模块形状徽记 + 名称（+ 一行概况）+ 「打开 →」。
  Widget _header(BuildContext context, String? summary) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 12),
      child: Row(
        children: <Widget>[
          SizedBox.square(
            dimension: 36,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.primaryContainer,
                shape: MaterialShapeBorder(
                  shape: shape ?? MaterialShapes.cookie9Sided,
                ),
              ),
              child: Center(
                child: FushiIcon(
                  item.icon,
                  size: 18,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                FushiAnimatedSize(
                  duration: context.fushiMotion.spatialDefault.duration,
                  curve: context.fushiMotion.spatialDefault.curve,
                  alignment: AlignmentDirectional.topStart,
                  child: summary == null
                      ? const SizedBox(width: double.infinity)
                      : Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FushiFilledButton.tonal(
            onPressed: onOpenModule,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: <Widget>[
                Text(t.nav_peek_open),
                const FushiIcon(FushiIcons.forward, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncSnapshot<AdaptiveNavPeekData> snapshot,
  ) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final AdaptiveNavPeekData? value = snapshot.data;
    if (value == null) {
      return snapshot.hasError
          ? const SizedBox(height: 4)
          : const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 6),
              child: FushiLinearProgressIndicator(),
            );
    }
    if (value.isEmpty) {
      return _NavPeekEmpty(icon: item.icon, label: t.home_continue_empty);
    }
    // 主块：「继续」项；没有时把最近的第一项提上来当主块（有封面的目的地），
    // 卡片总有一个视觉焦点，而不是一格格一样大的小块。
    final bool promote = value.resume == null && !value.listLayout;
    final AdaptiveNavPeekEntry? hero =
        value.resume ?? (promote ? value.recent.first : null);
    final String heroLabel = value.resume != null
        ? value.resumeLabel ?? t.home_continue
        : value.recentLabel ?? t.nav_peek_recent;
    final List<AdaptiveNavPeekEntry> rest = promote
        ? value.recent.skip(1).toList()
        : value.recent;
    final Widget body = FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hero != null)
            FushiStaggeredEntrance(
              index: 0,
              child: _NavPeekResume(
                entry: hero,
                label: heroLabel,
                showCover: !value.listLayout,
                fallbackIcon: hero.icon ?? item.icon,
                onOpen: () => onOpenEntry(hero),
              ),
            ),
          if (rest.isNotEmpty) ...<Widget>[
            if (!promote)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                child: Text(
                  value.recentLabel ?? t.nav_peek_recent,
                  style: text.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              const SizedBox(height: 8),
            if (value.listLayout)
              for (int i = 0; i < rest.length; i++)
                FushiStaggeredEntrance(
                  index: i + 1,
                  child: _NavPeekListRow(
                    entry: rest[i],
                    fallbackIcon: rest[i].icon ?? item.icon,
                    onOpen: () => onOpenEntry(rest[i]),
                  ),
                )
            else
              _NavPeekCoverList(
                entries: rest,
                fallbackIcon: item.icon,
                onOpen: onOpenEntry,
              ),
          ],
        ],
      ),
    );
    final ShelfCoverMaterial? material = item.peek?.coverMaterial;
    return material == null
        ? body
        : ShelfCoverMaterialScope(material: material, child: body);
  }
}

/// 速览卡空态：模块图标浅底 + 一句话（不是一行孤零零的灰字）。
class _NavPeekEmpty extends StatelessWidget {
  const _NavPeekEmpty({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FushiDesignTokens.of(context).surfaces.search,
        borderRadius: FushiM3eShape.cardRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: <Widget>[
            FushiIcon(icon, size: 22, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
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
    if (showCover) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SizedBox(
          height: kNavPeekResumeBlockHeight,
          child: _NavPeekBlock(
            entry: entry,
            eyebrow: label,
            fallbackIcon: fallbackIcon,
            onOpen: onOpen,
          ),
        ),
      );
    }
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

/// 速览卡「继续」色块的高（拼贴半高卡的口径）。
const double kNavPeekResumeBlockHeight = 128;

/// 速览卡里的一块拼贴色块（与首页 / 库页同一个 [FushiCoverBlock]）：封面按自身
/// 朝向摆（竖封面立在起始侧、横版缩略图铺在尾侧），底色取封面色相，标题 /
/// 副行 / 进度画在块里（用户 2026-11-16「侧边栏预览重新设计一下」——原来的
/// 「灰底列表行 + 一排裸封面」与拼贴改版后的页面不是一套语言）。
class _NavPeekBlock extends StatelessWidget {
  const _NavPeekBlock({
    required this.entry,
    required this.fallbackIcon,
    required this.onOpen,
    this.eyebrow,
  });

  final AdaptiveNavPeekEntry entry;
  final IconData fallbackIcon;
  final VoidCallback onOpen;

  /// 块内标题上方的小字（「继续」）；null = 不画。
  final String? eyebrow;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? cover = entry.cover;
    return _NavPeekImageAspects(
      images: <ImageProvider?>[cover],
      builder: (BuildContext context, List<double> aspects) {
        final FushiCoverBlockArt art = cover != null && aspects.single > 1.1
            ? FushiCoverBlockArt.landscape
            : FushiCoverBlockArt.portrait;
        final Widget block = FushiCoverBlock(
          size: FushiCoverBlockSize.half,
          art: art,
          title: entry.title,
          eyebrow: eyebrow,
          subtitle: entry.subtitle,
          progress: entry.progress,
          watermark: true,
          tintImage: cover,
          covers: cover == null
              ? <Widget>[
                  ColoredBox(
                    color: FushiDesignTokens.of(context).surfaces.overlay,
                    child: Center(child: FushiIcon(fallbackIcon)),
                  ),
                ]
              : <Widget>[
                  NsfwCoverBlur(
                    blur: entry.blurCover,
                    showIcon: false,
                    child: Image(
                      image: cover,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ],
        );
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) => FushiHoverLift(
            builder: (BuildContext _, bool _) => Semantics(
              button: true,
              label: entry.title,
              excludeSemantics: true,
              child: shelfCoverCard(
                borderRadius: BorderRadius.circular(
                  fushiCoverBlockRadius(FushiCoverBlockSize.half, c.maxHeight),
                ),
                onTap: onOpen,
                child: block,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 速览卡主块之下的其余条目：M3E 分段分组列表（整行标题、副行、细进度、尾部
/// 状态签），每行前面是按自身朝向摆的完整封面缩略图——不再是两列只剩封面一角
/// 与半截标题的小色块（用户 2026-11-16「预览还是有点简陋」：同一部作品的两个
/// 下载任务在小块里只看得出两张一样的封面）。
class _NavPeekCoverList extends StatelessWidget {
  const _NavPeekCoverList({
    required this.entries,
    required this.fallbackIcon,
    required this.onOpen,
  });

  final List<AdaptiveNavPeekEntry> entries;
  final IconData fallbackIcon;
  final ValueChanged<AdaptiveNavPeekEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final List<AdaptiveNavPeekEntry> shown = entries
        .take(kNavPeekMaxListRows)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < shown.length; i++)
          FushiStaggeredEntrance(
            index: i + 1,
            child: FushiGroupedListItem(
              index: i,
              count: shown.length,
              onTap: () => onOpen(shown[i]),
              child: _NavPeekCoverRow(
                entry: shown[i],
                fallbackIcon: shown[i].icon ?? fallbackIcon,
              ),
            ),
          ),
      ],
    );
  }
}

/// 速览卡列表最多几行（主块之外）。
const int kNavPeekMaxListRows = 4;

/// 列表行缩略图的高。
const double kNavPeekThumbHeight = 52;

class _NavPeekCoverRow extends StatelessWidget {
  const _NavPeekCoverRow({required this.entry, required this.fallbackIcon});

  final AdaptiveNavPeekEntry entry;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final double? progress = entry.progress;
    final bool showProgress = progress != null && progress > 0 && progress < 1;
    return Semantics(
      button: true,
      label: entry.title,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        child: Row(
          children: <Widget>[
            _NavPeekThumb(
              cover: entry.cover,
              fallbackIcon: fallbackIcon,
              blur: entry.blurCover,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 1,
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
                  if (showProgress)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FushiWavyLinearProgress(
                        value: progress.clamp(0.0, 1.0),
                        color: colors.primary,
                        trackColor: FushiDesignTokens.of(
                          context,
                        ).surfaces.overlay,
                      ),
                    ),
                ],
              ),
            ),
            if (entry.status case final String status) ...<Widget>[
              const SizedBox(width: 10),
              _NavPeekStatusChip(label: status, tone: entry.statusTone),
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表行的封面缩略图：按图自己的朝向（竖海报 2:3 / 横版缩略图 16:9）完整
/// 显示，不裁成方块。
class _NavPeekThumb extends StatelessWidget {
  const _NavPeekThumb({
    required this.cover,
    required this.fallbackIcon,
    this.blur = false,
  });

  final ImageProvider? cover;
  final IconData fallbackIcon;

  /// NSFW 封面打模糊（[AdaptiveNavPeekEntry.blurCover]）。
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = cover;
    final Color placeholder = FushiDesignTokens.of(context).surfaces.overlay;
    if (image == null) {
      return SizedBox(
        width: kNavPeekThumbHeight * kNavPeekDefaultCoverAspect,
        height: kNavPeekThumbHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: placeholder,
            borderRadius: FushiM3eShape.smallRadius,
          ),
          child: Center(child: FushiIcon(fallbackIcon, size: 18)),
        ),
      );
    }
    return _NavPeekImageAspects(
      images: <ImageProvider?>[image],
      builder: (BuildContext context, List<double> aspects) {
        final double aspect = aspects.single.clamp(0.5, 16 / 9);
        return AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          width: kNavPeekThumbHeight * aspect,
          height: kNavPeekThumbHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: placeholder,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: NsfwCoverBlur(
            blur: blur,
            showIcon: false,
            child: Image(
              image: image,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) =>
                  Center(child: FushiIcon(fallbackIcon, size: 18)),
            ),
          ),
        );
      },
    );
  }
}

/// 列表行尾部的状态小签（「42%」「已完成」「需要处理」）。
class _NavPeekStatusChip extends StatelessWidget {
  const _NavPeekStatusChip({required this.label, required this.tone});

  final String label;
  final AdaptiveNavPeekStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (tone) {
      AdaptiveNavPeekStatusTone.active => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      AdaptiveNavPeekStatusTone.done => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      AdaptiveNavPeekStatusTone.attention => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      AdaptiveNavPeekStatusTone.error => (
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      AdaptiveNavPeekStatusTone.neutral => (
        FushiDesignTokens.of(context).surfaces.overlay,
        colors.onSurfaceVariant,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
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
