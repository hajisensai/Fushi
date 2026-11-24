part of '../../browse_page.dart';

/// 「浏览」页的 Apple（Cupertino，iOS 27 / macOS 27）外壳（2026-11-24 用户拍板：
/// 「cupertino 窄屏模式下窄屏用大标题菜单『发现 ⌄』。宽屏跟横滑货架那样吧」，
/// 设计稿 `build/browse_cupertino_design/index.html`）。业务状态、页签控制器与各页签
/// 的生产页面全在 [_BrowsePageState]（同一份），这里只换外壳画法：
///
/// - **一级（发现 / 在线源 / 下载）**：iOS 档（窄屏）大标题本身是 pull-down 菜单
///   （「发现 ⌄」，[AppleLibraryTitleMenu]，与库页同一个件）；macOS 档宽窗由侧栏把
///   「浏览」展开成三个子项（[AppleSidebarLibraryHost]，与库页方案 A 一致），大标题
///   写当前一级名；侧栏收成顶部标签栏时回到标题菜单。独立 push 进来（有返回键、
///   外壳不画大标题）时一级是导航栏里的 Apple 分段。
/// - **二级 scope bar**：大标题下一条 Apple 分段（内容域 / 任务·订阅），在线源的
///   「来源 / 扩展」分段仍在同一行右端（拍板点 5 未通过，位置不变）。
/// - **切换动效**：iOS 档保留横滑与越界接力（[_handOffFrom]）；macOS 档不横滑，
///   一级与 scope 切换都是交叉淡入 + 4pt 上移（[FushiMotion.medium]）。
/// - 动作（AI 找资源 / ⋯ / 添加任务 / 下载设置）照旧登记进 [_actionsSlot]，由
///   导航栏右侧玻璃按钮组画出。
extension _AppleBrowseLayout on _BrowsePageState {
  IconData _appleTabIcon(BrowseTab tab) => switch (tab) {
    BrowseTab.discover => FushiIcons.travelExplore,
    BrowseTab.sources || BrowseTab.extensions => FushiIcons.globe,
    BrowseTab.downloads => FushiIcons.download,
  };

  /// 下载页签的顶栏动作（添加任务 + 下载设置）：与 M3E 顶栏同一组动作。
  void _appleClaimActions(BrowseTab current, {required bool mac}) {
    if (current != BrowseTab.downloads) {
      _actionsSlot.release(this);
      return;
    }
    _actionsSlot.claim(
      this,
      visible: true,
      actions: FushiShellHeaderActions(
        actions: <Widget>[
          FushiIconButton(
            icon: Icons.add,
            tooltip: t.download_task_add,
            label: mac ? t.download_task_add : null,
            onTap: _openManualTaskDialog,
          ),
          FushiIconButton(
            key: const ValueKey<String>('browse-download-settings'),
            icon: Icons.settings_outlined,
            tooltip: t.download_settings,
            onTap: _openDownloadSettings,
          ),
        ],
      ),
    );
  }

  /// 侧栏子项（macOS 档）：每个一级一行。
  List<AppleSidebarLibraryRow> _appleSidebarRows(
    List<BrowseTab> tabs,
    TabController controller,
  ) => <AppleSidebarLibraryRow>[
    for (int i = 0; i < tabs.length; i++)
      AppleSidebarLibraryRow(
        id: 'browse-tab-${tabs[i].name}',
        label: _tabLabel(tabs[i]),
        icon: _appleTabIcon(tabs[i]),
        selected: controller.index == i,
        onTap: () => _appleSelectTab(controller, i),
      ),
  ];

  void _appleSelectTab(TabController controller, int index) {
    if (controller.index == index) return;
    _chrome.resetToTop();
    if (fushiAppleUsesMacMetrics(context) || !fushiMotionEnabled(context)) {
      controller.index = index;
    } else {
      controller.animateTo(index);
    }
  }

  Widget _buildApple(List<BrowseTab> tabs, TabController controller) {
    final bool mac = fushiAppleUsesMacMetrics(context);
    final AppleSidebarLibraryHost? host = AppleSidebarLibraryScope.maybeOf(
      context,
    );
    final bool sidebarHosts = appleSidebarHostsLibrarySections(
      host: host,
      macMetrics: mac,
      groupCount: 1,
    );
    if (_appleSidebarHost != host) _appleSidebarHost?.publish(this, null);
    _appleSidebarHost = host;
    final bool showBackButton = ModalRoute.of(context)?.isFirst == false;
    return FushiFileDropTarget(
      debugLabel: 'downloads',
      onDrop: _handleDownloadsDrop,
      child: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? _) {
          final BrowseTab current =
              tabs[controller.index.clamp(0, tabs.length - 1)];
          _appleClaimActions(current, mac: mac);
          host?.publish(
            this,
            SectionVisibility.of(context)
                ? _appleSidebarRows(tabs, controller)
                : null,
          );
          final bool titleMenu = !showBackButton && !sidebarHosts;
          Widget wrapTitle(
            BuildContext context,
            Widget title,
            TextStyle style,
          ) => AppleLibraryTitleMenu(
            title: title,
            titleStyle: style,
            focusIdPrefix: 'browse',
            entries: <AppleLibraryTitleMenuEntry>[
              for (int i = 0; i < tabs.length; i++)
                AppleLibraryTitleMenuEntry(
                  label: _tabLabel(tabs[i]),
                  icon: _appleTabIcon(tabs[i]),
                  selected: i == controller.index,
                  onSelect: () => _appleSelectTab(controller, i),
                ),
            ],
          );
          final Widget chrome = FushiShellTitleScope(
            title: _tabLabel(current),
            actionsSlot: _actionsSlot,
            child: FushiFloatingChromeBar(
              slot: _actionsSlot,
              titleWrapper: titleMenu && tabs.length > 1 ? wrapTitle : null,
              leading: showBackButton
                  ? FushiRouteBackButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  : null,
              // 独立 push 进来（外壳不画大标题）时一级是导航栏里的分段。
              tabs: showBackButton && tabs.length > 1
                  ? _appleTierSegmented(tabs, controller)
                  : const SizedBox.shrink(),
              secondary: _appleScopeBar(current),
            ),
          );
          return Scaffold(
            resizeToAvoidBottomInset: current != BrowseTab.downloads,
            body: SafeArea(
              bottom: false,
              child: FushiFloatingChromeScope(
                controller: _chrome,
                child: FushiFloatingChromeOverlay(
                  masthead: true,
                  chrome: chrome,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: mac
                        ? _AppleBrowseFadeStack<BrowseTab>(
                            values: tabs,
                            selected: current,
                            builder: (BrowseTab tab) => _appleTabBody(tab),
                          )
                        : TabBarView(
                            key: ValueKey<String>(
                              tabs.map((BrowseTab tab) => tab.name).join(','),
                            ),
                            controller: controller,
                            children: <Widget>[
                              for (final BrowseTab tab in tabs)
                                _BrowseTabKeepAlive(
                                  key: ValueKey<BrowseTab>(tab),
                                  active: current == tab,
                                  child: _appleTabBody(tab),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 独立 push 时导航栏里的一级分段。
  Widget _appleTierSegmented(
    List<BrowseTab> tabs,
    TabController controller,
  ) => KeyedSubtree(
    key: const ValueKey<String>('browse-tier-segmented'),
    child: IntrinsicWidth(
      child: adaptiveSegmentedButton<BrowseTab>(
        context: context,
        segments: <ButtonSegment<BrowseTab>>[
          for (final BrowseTab tab in tabs)
            ButtonSegment<BrowseTab>(value: tab, label: Text(_tabLabel(tab))),
        ],
        selected: <BrowseTab>{tabs[controller.index.clamp(0, tabs.length - 1)]},
        onSelectionChanged: (Set<BrowseTab> next) {
          if (next.isEmpty) return;
          final int index = tabs.indexOf(next.first);
          if (index >= 0) _appleSelectTab(controller, index);
        },
      ),
    ),
  );

  /// 大标题下的 scope bar：当前一级的二级分段（+ 在线源的「来源 / 扩展」）。
  Widget? _appleScopeBar(BrowseTab current) {
    final AppModel appModel = ref.read(appProvider);
    final (
      List<LibrarySectionTab<Object>> tabs,
      Object? selected,
    ) = switch (current) {
      BrowseTab.discover => () {
        final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
          appModel.moduleVisibility,
          gamesForm: appModel.gamesModuleForm,
        );
        return (
          <LibrarySectionTab<Object>>[
            for (final _DownloadsResourceDomain d in domains)
              LibrarySectionTab<Object>(
                value: d,
                label: _resourceDomainLabel(d),
              ),
          ],
          domains.contains(_resourceDomain)
              ? _resourceDomain
              : (domains.isEmpty ? null : domains.first),
        );
      }(),
      BrowseTab.sources || BrowseTab.extensions => () {
        final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
          appModel.moduleVisibility,
        );
        return (
          <LibrarySectionTab<Object>>[
            for (final OnlineSourcesDomain d in domains)
              LibrarySectionTab<Object>(
                value: d,
                label: onlineSourcesDomainLabel(d),
              ),
          ],
          domains.contains(_onlineDomain)
              ? _onlineDomain
              : (domains.isEmpty ? null : domains.first),
        );
      }(),
      BrowseTab.downloads => (
        <LibrarySectionTab<Object>>[
          LibrarySectionTab<Object>(
            value: BrowseDownloadsSection.tasks,
            label: t.download_tasks_tab,
          ),
          LibrarySectionTab<Object>(
            value: BrowseDownloadsSection.subscriptions,
            label: t.download_subscriptions_tab,
          ),
        ],
        _downloadsSection,
      ),
    };
    final Widget? trailing =
        current == BrowseTab.sources || current == BrowseTab.extensions
        ? _buildOnlineSectionSegmented()
        : null;
    if ((tabs.length < 2 || selected == null) && trailing == null) return null;
    final bool mac = fushiAppleUsesMacMetrics(context);
    final Widget? segmented = tabs.length < 2 || selected == null
        ? null
        : KeyedSubtree(
            key: ValueKey<String>(switch (current) {
              BrowseTab.discover => 'downloads-resource-type-picker',
              BrowseTab.downloads => 'browse-downloads-section-picker',
              _ => 'browse-sources-domain-picker',
            }),
            child: adaptiveSegmentedButton<Object>(
              context: context,
              segments: <ButtonSegment<Object>>[
                for (final LibrarySectionTab<Object> tab in tabs)
                  ButtonSegment<Object>(
                    value: tab.value,
                    label: Text(tab.label),
                  ),
              ],
              selected: <Object>{selected},
              onSelectionChanged: (Set<Object> next) {
                if (next.isEmpty) return;
                _appleSelectScope(next.first);
              },
            ),
          );
    return Row(
      key: const ValueKey<String>('browse-apple-scope-bar'),
      children: <Widget>[
        if (segmented != null)
          if (mac)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 120.0 * tabs.length * fushiAppleMacScale(context),
              ),
              child: IntrinsicWidth(child: segmented),
            )
          else
            Expanded(child: segmented),
        if (trailing != null) ...<Widget>[
          if (segmented != null) const SizedBox(width: 8) else const Spacer(),
          if (mac && segmented != null) const Spacer(),
          trailing,
        ],
      ],
    );
  }

  void _appleSelectScope(Object value) {
    switch (value) {
      case final _DownloadsResourceDomain domain:
        _selectResourceDomain(domain);
      case final OnlineSourcesDomain domain:
        _selectOnlineDomain(domain);
      case final BrowseDownloadsSection section:
        if (section == _downloadsSection) return;
        _chrome.resetToTop();
        _updateState(() => _downloadsSection = section);
    }
  }

  /// 一个一级页签的正文：二级页面（iOS 档横滑 / macOS 档交叉淡入）。
  Widget _appleTabBody(BrowseTab tab) {
    final AppModel appModel = ref.watch(appProvider);
    return switch (tab) {
      BrowseTab.discover => () {
        final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
          appModel.moduleVisibility,
          gamesForm: appModel.gamesModuleForm,
        );
        if (domains.isEmpty) return const SizedBox.shrink();
        return _AppleBrowseSections<_DownloadsResourceDomain>(
          values: domains,
          selected: domains.contains(_resourceDomain)
              ? _resourceDomain
              : domains.first,
          onChanged: _selectResourceDomain,
          onEdgeOverscroll: (int delta) =>
              _handOffFrom(BrowseTab.discover, delta),
          pageBuilder: _buildResourceDomainPage,
        );
      }(),
      BrowseTab.sources || BrowseTab.extensions => () {
        final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
          appModel.moduleVisibility,
        );
        if (domains.isEmpty) return const SizedBox.shrink();
        return _AppleBrowseSections<OnlineSourcesDomain>(
          values: domains,
          selected: domains.contains(_onlineDomain)
              ? _onlineDomain
              : domains.first,
          onChanged: _selectOnlineDomain,
          onEdgeOverscroll: (int delta) =>
              _handOffFrom(BrowseTab.sources, delta),
          pageBuilder: _buildOnlineDomainPage,
        );
      }(),
      BrowseTab.downloads => _AppleBrowseSections<BrowseDownloadsSection>(
        values: BrowseDownloadsSection.values,
        selected: _downloadsSection,
        onChanged: (BrowseDownloadsSection value) {
          _chrome.resetToTop();
          _updateState(() => _downloadsSection = value);
        },
        onEdgeOverscroll: (int delta) =>
            _handOffFrom(BrowseTab.downloads, delta),
        pageBuilder: (BrowseDownloadsSection section) => switch (section) {
          BrowseDownloadsSection.tasks => _buildTasks(),
          BrowseDownloadsSection.subscriptions =>
            const VideoDownloadSubscriptionsPanel(),
        },
      ),
    };
  }
}

/// Apple 二级页面：iOS 档 = 可横滑的 [TabBarView]（越过首 / 末段把手势交给一级，
/// 与 M3E [_BrowseSwipeSections] 同一条接力规则）；macOS 档 = 交叉淡入
/// （[_AppleBrowseFadeStack]）。分段控件不在这里——画在大标题下的 scope bar。
/// 选中值的真相在宿主（[selected] / [onChanged]）。
class _AppleBrowseSections<T extends Object> extends StatefulWidget {
  const _AppleBrowseSections({
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.onEdgeOverscroll,
    required this.pageBuilder,
    super.key,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final ValueChanged<int> onEdgeOverscroll;
  final Widget Function(T value) pageBuilder;

  @override
  State<_AppleBrowseSections<T>> createState() =>
      _AppleBrowseSectionsState<T>();
}

class _AppleBrowseSectionsState<T extends Object>
    extends State<_AppleBrowseSections<T>>
    with TickerProviderStateMixin {
  TabController? _controller;
  List<T> _controllerValues = <T>[];
  double _edgeOverscroll = 0;
  bool _handedOff = false;

  int get _selectedIndex {
    final int index = widget.values.indexOf(widget.selected);
    return index < 0 ? 0 : index;
  }

  TabController _syncController() {
    final TabController? current = _controller;
    if (current != null && listEquals(widget.values, _controllerValues)) {
      final int index = _selectedIndex;
      if (!current.indexIsChanging && current.index != index) {
        // scope bar 点选：跟手滑过去（减弱动效 / 墨水屏下直接到位）。
        if (fushiMotionEnabled(context)) {
          current.animateTo(index);
        } else {
          current.index = index;
        }
      }
      return current;
    }
    final TabController next = TabController(
      length: widget.values.length,
      initialIndex: _selectedIndex,
      animationDuration: einkSafeDuration(context, kTabScrollDuration),
      vsync: this,
    );
    next.addListener(() {
      if (!identical(next, _controller)) return;
      final T value = _controllerValues[next.index];
      if (value != widget.selected) widget.onChanged(value);
    });
    _controller = next;
    _controllerValues = List<T>.unmodifiable(widget.values);
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _edgeOverscroll = 0;
      _handedOff = false;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_handedOff) {
      _edgeOverscroll += notification.overscroll;
      if (_edgeOverscroll.abs() >= _kSectionEdgeHandOffDistance) {
        _handedOff = true;
        widget.onEdgeOverscroll(_edgeOverscroll > 0 ? 1 : -1);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (fushiAppleUsesMacMetrics(context)) {
      return _AppleBrowseFadeStack<T>(
        values: widget.values,
        selected: widget.selected,
        builder: widget.pageBuilder,
      );
    }
    final TabController controller = _syncController();
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? _) => TabBarView(
          key: ValueKey<String>(_controllerValues.join(',')),
          controller: controller,
          children: <Widget>[
            for (final T value in _controllerValues)
              _BrowseTabKeepAlive(
                key: ValueKey<T>(value),
                active: _controllerValues[controller.index] == value,
                child: widget.pageBuilder(value),
              ),
          ],
        ),
      ),
    );
  }
}

/// macOS 档的切换：访问过的页面保活叠放（离屏的关焦点 / ticker、各给一份主滚动
/// 控制器，同 [_BrowseTabKeepAlive]），选中页交叉淡入 + 4pt 上移
/// （[FushiMotion.medium]；减弱动效下瞬间到位）。
class _AppleBrowseFadeStack<T extends Object> extends StatefulWidget {
  const _AppleBrowseFadeStack({
    required this.values,
    required this.selected,
    required this.builder,
  });

  final List<T> values;
  final T selected;
  final Widget Function(T value) builder;

  @override
  State<_AppleBrowseFadeStack<T>> createState() =>
      _AppleBrowseFadeStackState<T>();
}

class _AppleBrowseFadeStackState<T extends Object>
    extends State<_AppleBrowseFadeStack<T>> {
  final Set<T> _visited = <T>{};

  @override
  Widget build(BuildContext context) {
    _visited
      ..removeWhere((T v) => !widget.values.contains(v))
      ..add(widget.selected);
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final T value in widget.values)
          if (_visited.contains(value))
            KeyedSubtree(
              key: ValueKey<T>(value),
              child: Offstage(
                offstage: value != widget.selected,
                child: TickerMode(
                  enabled: value == widget.selected,
                  child: ExcludeFocus(
                    excluding: value != widget.selected,
                    child: SectionVisibilityScope(
                      visible: value == widget.selected,
                      child: SectionPrimaryScrollScope(
                        child: _AppleFadeIn(
                          active: value == widget.selected,
                          duration: duration,
                          child: widget.builder(value),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// 由不选中变为选中时播一次淡入 + 4pt 上移；子树结构恒定（不按选中态增删包装层，
/// 保活页面的状态不丢）。纯动效层，与设计系统无关。
class _AppleFadeIn extends StatefulWidget {
  const _AppleFadeIn({
    required this.active,
    required this.duration,
    required this.child,
  });

  final bool active;
  final Duration duration;
  final Widget child;

  @override
  State<_AppleFadeIn> createState() => _AppleFadeInState();
}

class _AppleFadeInState extends State<_AppleFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  @override
  void didUpdateWidget(_AppleFadeIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.active && !oldWidget.active) {
      if (widget.duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = FushiMotion.standard.transform(_controller.value);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 4 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}
