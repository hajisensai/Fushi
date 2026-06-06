import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show
        GamepadButtonIntent,
        arrowTraversalDirection,
        dispatchNativeGamepadButtonIntent,
        focusedEditableText,
        gamepadMoveFocusInDirection;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

/// 顶层 tab 的逻辑身份（取代写死的整数索引 0/1/2）。视频 tab 仅在实验开关开启时
/// 进入 [_HomePageState._activeTabs]，故用枚举身份而非位置来切换/路由——插入这个
/// 条件 tab 不会再打乱「设置/词典」的索引（消除 `==2` / `case 1/2` / `%3` 这类特殊
/// 情况）。底栏/侧栏只在渲染层把身份映射成位置。
enum HomeTab { books, video, dictionaries, settings }

/// 纯函数：给定实验视频开关，返回可见顶层 tab 的**视觉顺序**——视频固定插在书架与
/// 词典之间（用户要求「在书架和词典管理中间」）。提取成顶层函数便于单测条件插入与
/// 顺序，不必实例化整个 [HomePage]。底栏/侧栏的位置索引由此列表导出。
List<HomeTab> homeActiveTabs({required bool videoEnabled}) => <HomeTab>[
      HomeTab.books,
      if (videoEnabled) HomeTab.video,
      HomeTab.dictionaries,
      HomeTab.settings,
    ];

class HomePage extends BasePage {
  const HomePage({super.key});

  @override
  BasePageState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends BasePageState<HomePage>
    with WidgetsBindingObserver {
  String get appVersion => appModel.packageInfo.version;

  HomeTab _currentTab = HomeTab.books;

  /// 进入「设置」标签前的来源 tab，供设置全屏左上返回箭头切回。
  HomeTab _previousTab = HomeTab.books;
  final FocusNode _keyboardFocusNode = FocusNode();
  final ValueNotifier<int> _dictFocusSignal = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    appModelNoUpdate.databaseCloseNotifier.addListener(refresh);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      appModel.populateDefaultMapping(appModel.targetLanguage);
      appModel.populateBookmarks();
      if (appModel.isFirstTimeSetup) {
        appModel.setLastSelectedDictionaryFormat(
            appModel.targetLanguage.standardFormat);
        appModel.setFirstTimeSetupFlag();
      }

      if (mounted) {
        UpdateChecker.scheduleCheck(
          context,
          appVersion,
          neverRemind: appModel.updateNeverRemind,
          autoInstall: appModel.updateAutoInstall,
          betaChannel: appModel.updateBetaChannel,
          debugChannel: appModel.updateDebugChannel,
        );
      }

      triggerAutoSyncOnAppOpen(
        db: appModel.database,
        dictionaryResourceRoot: appModel.dictionaryResourceDirectory,
        audioDatabaseRoot:
            Directory('${appModel.appDirectory.path}/audiobooks'),
        tempDir: appModel.temporaryDirectory,
        localAudioEntries: appModel.localAudioDbs,
        onLocalAudioImported: appModel.importSyncedLocalAudioDb,
        onReport: appModel.presentAutoConflicts,
      );
    });
  }

  void refresh() {
    setState(() {});
  }

  @override
  void dispose() {
    _dictFocusSignal.dispose();
    _keyboardFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    appModelNoUpdate.databaseCloseNotifier.removeListener(refresh);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (AppLifecycleState.resumed == state) {
      debugPrint('Lifecycle Resumed');
      appModel.searchDictionary(
        searchTerm: appModel.targetLanguage.helloWorld,
        searchWithWildcards: false,
        useCache: false,
      );
    } else if (AppLifecycleState.paused == state) {
      if (appModel.lowMemoryMode) {
        PaintingBinding.instance.imageCache.clear();
      }
      final item = appModel.currentMediaItem;
      if (item != null) {
        triggerAutoSyncOnBackground(
          db: appModel.database,
          mediaIdentifier: item.mediaIdentifier,
        );
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final KeyEventResult focusedGamepadAction =
        dispatchNativeGamepadButtonIntent(event);
    if (focusedGamepadAction == KeyEventResult.handled) {
      return focusedGamepadAction;
    }

    final modifiers = <ModifierKey>{};
    if (HardwareKeyboard.instance.isControlPressed) {
      modifiers.add(ModifierKey.ctrl);
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      modifiers.add(ModifierKey.shift);
    }
    if (HardwareKeyboard.instance.isAltPressed) {
      modifiers.add(ModifierKey.alt);
    }
    if (HardwareKeyboard.instance.isMetaPressed) {
      modifiers.add(ModifierKey.meta);
    }

    ShortcutAction? action = appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.home,
        ) ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.global,
        );

    if (action == null) {
      final gamepad = GamepadButton.fromLogicalKey(event.logicalKey);
      if (gamepad != null) {
        action = appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.home,
            ) ??
            appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.global,
            );
      }
    }

    if (action != null) return _executeShortcutAction(action);

    // Arrow keys are unbound on home, so drive robust directional focus
    // navigation through the SAME helper the gamepad D-pad/stick uses — keyboard
    // and gamepad therefore behave identically. Skipped while a text field is
    // focused so the field's own cursor movement keeps working (up/down then
    // bubble to wrapWithGlobalNavigation, which lets them escape a single-line
    // field). Uses the shared arrow/editable helpers so home and the app-wide
    // wrapper read arrows and "is a text field focused" the same way — the old
    // private `is EditableText` check missed every field (the primary focus is
    // EditableText's inner Focus, not the EditableText), so it never actually
    // guarded the search field's caret.
    final TraversalDirection? dir = arrowTraversalDirection(event.logicalKey);
    if (dir != null && focusedEditableText() == null) {
      gamepadMoveFocusInDirection(context, dir);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 当前可见的顶层 tab，按视觉顺序：书架 →（视频）→ 词典 → 设置。视频仅在
  /// 实验开关开启时插入（位于书架与词典之间）。底栏/侧栏的位置索引由此列表导出。
  List<HomeTab> _activeTabs() =>
      homeActiveTabs(videoEnabled: appModel.experimentalVideoEnabled);

  /// 渲染用的当前 tab：若 `_currentTab` 已不在可见列表（例如刚关掉实验开关时仍停在
  /// 视频 tab），回落到书架，避免渲染一个不存在的 tab。`_currentTab` 自身保持不变，
  /// 下一次 [_selectTab] 会纠正它。
  HomeTab get _visibleTab {
    final List<HomeTab> tabs = _activeTabs();
    return tabs.contains(_currentTab) ? _currentTab : HomeTab.books;
  }

  /// 统一切换顶层 tab：进入「设置」前记录来源 tab，供设置全屏返回箭头切回。
  /// 所有切 tab 入口（侧栏 / 底栏 / 快捷键）都走这里，保证 _previousTab 一致。
  void _selectTab(HomeTab tab) {
    setState(() {
      if (tab == HomeTab.settings && _currentTab != HomeTab.settings) {
        _previousTab = _currentTab;
      }
      _currentTab = tab;
    });
  }

  /// next/prev 快捷键：在当前可见 tab 列表里环形步进（视频开关变化时自动适配长度）。
  void _cycleTab(int delta) {
    final List<HomeTab> tabs = _activeTabs();
    final int current = tabs.indexOf(_visibleTab);
    final int next = (current + delta) % tabs.length;
    _selectTab(tabs[(next + tabs.length) % tabs.length]);
  }

  KeyEventResult _executeShortcutAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.homeTabBooks:
        _selectTab(HomeTab.books);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabDict:
        _selectTab(HomeTab.dictionaries);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabSettings:
        _selectTab(HomeTab.settings);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabNext:
        _cycleTab(1);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabPrev:
        _cycleTab(-1);
        return KeyEventResult.handled;
      case ShortcutAction.homeFocusSearch:
        _selectTab(HomeTab.dictionaries);
        _dictFocusSignal.value++;
        return KeyEventResult.handled;
      case ShortcutAction.globalBack:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Handles a gamepad button delivered via [GamepadButtonIntent] (desktop
  /// polled path), routing it through the same actions as the key-event path.
  /// Returns true when consumed; false lets the GamepadService fall back to
  /// directional focus / activate / global back.
  bool _handleGamepadButton(GamepadButton button) {
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.home,
        ) ??
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.global,
        );
    if (action == null) return false;
    return _executeShortcutAction(action) == KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!appModel.isDatabaseOpen) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<bool>(
        valueListenable: syncInProgress,
        builder: (context, syncing, child) => PopScope(
              canPop: !syncing,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop) return;
                final bool? confirmed = await showAppDialog<bool>(
                  context: context,
                  builder: (BuildContext ctx) => _SyncExitWarningDialog(
                    onCancel: () => Navigator.pop(ctx, false),
                    onExit: () => Navigator.pop(ctx, true),
                  ),
                );
                if (confirmed == true) {
                  SystemNavigator.pop();
                }
              },
              child: child!,
            ),
        child: Actions(
            // Desktop gamepad path: the GamepadService dispatches
            // GamepadButtonIntent here (no gameButton* key events on desktop).
            // Resolving it against home/global routes polled controller input
            // through the same actions as the key-event path.
            actions: <Type, Action<Intent>>{
              GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
                onInvoke: (GamepadButtonIntent intent) =>
                    _handleGamepadButton(intent.button),
              ),
            },
            child: Focus(
              // Autofocus on every platform: on mobile no field on the home tabs
              // grabs focus at mount, so without this the FocusManager has no
              // primary focus and hardware-keyboard / gamepad shortcuts never
              // reach _handleKeyEvent until the user taps something. The home
              // search field focuses on demand, so this never fights an editable.
              autofocus: true,
              // But this wrapper spans the whole page, so it must NOT be a
              // traversal target: otherwise directional (keyboard arrow /
              // gamepad) navigation lands on it and the focus ring covers the
              // entire window. skipTraversal keeps it as a key-event sink only;
              // Tab/arrow/D-pad traversal moves between the real controls and
              // the ring follows them. Shortcut keys still bubble up here.
              skipTraversal: true,
              focusNode: _keyboardFocusNode,
              onKeyEvent: _handleKeyEvent,
              child: GestureDetector(
                onTap: () {
                  final FocusNode? current = FocusManager.instance.primaryFocus;
                  if (current != null && current != _keyboardFocusNode) {
                    current.unfocus();
                  }
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final sizeClass = windowSizeClassOf(constraints);
                    // compact(<600) → 底栏；medium/expanded(≥600，含竖屏平板) → 侧边布局。
                    if (sizeClass == WindowSizeClass.compact) {
                      return _buildMobileLayout();
                    }
                    return _buildDesktopLayout(sizeClass);
                  },
                ),
              ),
            )));
  }

  /// 单个 [HomeTab] 的导航项（图标 + 标签）。底栏与侧栏共用，保证两者标签/选中图标一致。
  AdaptiveNavItem _navItemFor(HomeTab tab) {
    switch (tab) {
      case HomeTab.books:
        return AdaptiveNavItem(
          icon: Icons.menu_book_outlined,
          selectedIcon: Icons.menu_book,
          label: t.books,
        );
      case HomeTab.video:
        return AdaptiveNavItem(
          icon: Icons.movie_outlined,
          selectedIcon: Icons.movie,
          label: t.nav_video,
          // 视频已毕业为常驻 tab，但功能仍为实验性：图标右上角小圆点徽标标记。
          experimentalBadge: true,
        );
      case HomeTab.dictionaries:
        return AdaptiveNavItem(
          icon: Icons.search_outlined,
          selectedIcon: Icons.search,
          label: t.nav_lookup,
        );
      case HomeTab.settings:
        return AdaptiveNavItem(
          icon: Icons.tune_outlined,
          selectedIcon: Icons.tune,
          label: t.settings,
        );
    }
  }

  /// 可见 tab 列表对应的导航项（与 [_activeTabs] 顺序一致）。
  List<AdaptiveNavItem> _navItems(List<HomeTab> tabs) =>
      tabs.map(_navItemFor).toList();

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    if (_visibleTab == HomeTab.settings) {
      // 设置标签（全部设计系统）：隐藏 3 图标侧栏，全屏二栏（内部
      // MaterialSupportingPaneLayout），左上返回箭头切回来源 tab（参考 Mihon
      // 宽屏设置）。Cupertino 桌面也走这里——叶子控件保持 Cupertino 皮肤，但外壳
      // 复用同一 Material 架构；返回出口由 SettingsHomePage 的嵌入页头提供
      // （BUG-009 R2）。否则会退化成「3 图标 rail + 嵌入式 Cupertino 设置」三栏
      // 混排、无返回出口、且详情面板溢出。
      return Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: FocusTraversalGroup(
            child: HibikiSettingsContent(
              onBack: () => _selectTab(_previousTab),
            ),
          ),
        ),
      );
    }

    final List<HomeTab> tabs = _activeTabs();
    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems(tabs);
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int logical = tabs.indexOf(_visibleTab);
    final int visualIndex = reversed ? (tabs.length - 1 - logical) : logical;

    void selectVisual(int index) {
      final int logicalIndex = reversed ? (tabs.length - 1 - index) : index;
      _selectTab(tabs[logicalIndex]);
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // Two traversal groups so Tab / Shift+Tab walk each region as one block
        // in visual order (whole rail, then whole content) instead of zig-zagging
        // between the rail and the content pane row-by-row.
        child: Row(
          children: [
            FocusTraversalGroup(
              // Each rail destination is its own gamepad/keyboard focus target,
              // so the app focus ring hugs the single selected item; D-pad
              // Up/Down steps between them and Left/Right leaves to the content.
              child: adaptiveNavRail(
                context: context,
                currentIndex: visualIndex,
                onTap: selectVisual,
                items: displayItems,
              ),
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(child: FocusTraversalGroup(child: buildBody())),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    final List<HomeTab> tabs = _activeTabs();
    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems(tabs);
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int logical = tabs.indexOf(_visibleTab);
    final int visualIndex = reversed ? (tabs.length - 1 - logical) : logical;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(child: buildBody()),
      bottomNavigationBar: adaptiveBottomBar(
        context: context,
        currentIndex: visualIndex,
        onTap: (int index) {
          final int logicalIndex = reversed ? (tabs.length - 1 - index) : index;
          _selectTab(tabs[logicalIndex]);
        },
        items: displayItems,
      ),
    );
  }

  Widget buildBody() {
    switch (_visibleTab) {
      case HomeTab.video:
        return HomeVideoPage(repo: VideoBookRepository(appModel.database));
      case HomeTab.dictionaries:
        return HomeDictionaryPage(focusSignal: _dictFocusSignal);
      case HomeTab.settings:
        return const HibikiSettingsContent();
      case HomeTab.books:
        return const HomeReaderPage();
    }
  }
}

class _SyncExitWarningDialog extends StatelessWidget {
  const _SyncExitWarningDialog({
    required this.onCancel,
    required this.onExit,
  });

  final VoidCallback onCancel;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return HibikiDialogFrame(
      maxWidth: 380,
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.sync_exit_warning_title,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap + 4),
          Text(
            t.sync_exit_warning,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              adaptiveDialogAction(
                context: context,
                onPressed: onCancel,
                child: Text(t.dialog_cancel),
              ),
              SizedBox(width: tokens.spacing.gap),
              adaptiveDialogAction(
                context: context,
                isDestructiveAction: true,
                onPressed: onExit,
                child: Text(t.dialog_exit),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
