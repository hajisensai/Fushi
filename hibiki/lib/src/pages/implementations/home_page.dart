import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
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

class HomePage extends BasePage {
  const HomePage({super.key});

  @override
  BasePageState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends BasePageState<HomePage>
    with WidgetsBindingObserver {
  String get appVersion => appModel.packageInfo.version;

  int _currentTab = 0;

  /// 进入「设置」标签前的来源 tab，供设置全屏左上返回箭头切回。
  int _previousTab = 0;
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
        onReport: (SyncRunReport report, SyncBackend backend) {
          if (report.conflicts.isEmpty) return;
          appModel.syncConflictPrompter.present(
            navigatorKey: appModel.navigatorKey,
            db: appModel.database,
            backend: backend,
            conflicts: report.conflicts,
            source: ConflictSource.auto,
            inBook: appModel.isMediaOpen,
          );
        },
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

  /// 统一切换顶层 tab：进入「设置」(2) 前记录来源 tab。
  /// 所有切 tab 入口（侧栏 / 底栏 / 快捷键）都走这里，保证 _previousTab 一致。
  void _selectTab(int logicalIndex) {
    setState(() {
      if (logicalIndex == 2 && _currentTab != 2) {
        _previousTab = _currentTab;
      }
      _currentTab = logicalIndex;
    });
  }

  KeyEventResult _executeShortcutAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.homeTabBooks:
        _selectTab(0);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabDict:
        _selectTab(1);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabSettings:
        _selectTab(2);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabNext:
        _selectTab((_currentTab + 1) % 3);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabPrev:
        _selectTab((_currentTab + 2) % 3);
        return KeyEventResult.handled;
      case ShortcutAction.homeFocusSearch:
        _selectTab(1);
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

  /// The three top-level destinations, shared by the bottom bar and the side
  /// rail so both render the SAME labels and (selected) icons.
  List<AdaptiveNavItem> _navItems() => <AdaptiveNavItem>[
        AdaptiveNavItem(
          icon: Icons.menu_book_outlined,
          selectedIcon: Icons.menu_book,
          label: t.books,
        ),
        AdaptiveNavItem(
          icon: Icons.search_outlined,
          selectedIcon: Icons.search,
          label: t.dictionaries,
        ),
        AdaptiveNavItem(
          icon: Icons.tune_outlined,
          selectedIcon: Icons.tune,
          label: t.settings,
        ),
      ];

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    if (_currentTab == 2) {
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

    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems();
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int visualIndex =
        reversed ? (items.length - 1 - _currentTab) : _currentTab;

    void selectVisual(int index) {
      final int logicalIndex = reversed ? (items.length - 1 - index) : index;
      _selectTab(logicalIndex);
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
    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems();
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int visualIndex =
        reversed ? (items.length - 1 - _currentTab) : _currentTab;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(child: buildBody()),
      bottomNavigationBar: adaptiveBottomBar(
        context: context,
        currentIndex: visualIndex,
        onTap: (int index) {
          final int logicalIndex =
              reversed ? (items.length - 1 - index) : index;
          _selectTab(logicalIndex);
        },
        items: displayItems,
      ),
    );
  }

  Widget buildBody() {
    switch (_currentTab) {
      case 1:
        return HomeDictionaryPage(focusSignal: _dictFocusSignal);
      case 2:
        return const HibikiSettingsContent();
      default:
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
