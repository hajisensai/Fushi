import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/pages.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent, gamepadMoveFocusInDirection;
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
  String _iconAsset = 'assets/meta/icon.png';
  final FocusNode _keyboardFocusNode = FocusNode();
  final ValueNotifier<int> _dictFocusSignal = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _loadIconPreset();

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

      triggerAutoSyncOnAppOpen(db: appModel.database);
    });
  }

  Future<void> _loadIconPreset() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(iconPresetKey) ?? 'default';
    if (mounted) {
      setState(() => _iconAsset = iconAssetMap[key] ?? 'assets/meta/icon.png');
    }
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
    // focused so the field's own cursor movement keeps working.
    final TraversalDirection? dir = _arrowDirection(event.logicalKey);
    if (dir != null && !_isEditableFocused()) {
      gamepadMoveFocusInDirection(context, dir);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static TraversalDirection? _arrowDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  static bool _isEditableFocused() {
    final BuildContext? c = FocusManager.instance.primaryFocus?.context;
    return c != null && c.widget is EditableText;
  }

  KeyEventResult _executeShortcutAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.homeTabBooks:
        setState(() => _currentTab = 0);
        _loadIconPreset();
        return KeyEventResult.handled;
      case ShortcutAction.homeTabDict:
        setState(() => _currentTab = 1);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabSettings:
        setState(() => _currentTab = 2);
        return KeyEventResult.handled;
      case ShortcutAction.homeFocusSearch:
        setState(() => _currentTab = 1);
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
                    if (sizeClass == WindowSizeClass.compact) {
                      return _buildMobileLayout();
                    }
                    if (!isDesktopPlatform &&
                        constraints.maxWidth <= constraints.maxHeight) {
                      return _buildMobileLayout();
                    }
                    return _buildDesktopLayout(sizeClass);
                  },
                ),
              ),
            )));
  }

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    final bool reversed = appModel.reverseNavigationBar;
    final List<NavigationRailDestination> destinations = [
      NavigationRailDestination(
        icon: const Icon(Icons.menu_book_outlined),
        label: Text(t.books),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.search),
        label: Text(t.dictionaries),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.tune_outlined),
        label: Text(t.settings),
      ),
    ];
    final List<NavigationRailDestination> displayDestinations =
        reversed ? destinations.reversed.toList() : destinations;
    final int visualIndex =
        reversed ? (destinations.length - 1 - _currentTab) : _currentTab;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // Two traversal groups so Tab / Shift+Tab walk each region as one block
        // in visual order (whole rail, then whole content) instead of zig-zagging
        // between the rail and the content pane row-by-row.
        child: Row(
          children: [
            FocusTraversalGroup(
              child: NavigationRail(
                leading: _buildRailLeading(),
                groupAlignment: 0.0,
                selectedIndex: visualIndex,
                onDestinationSelected: (int index) {
                  final int logicalIndex =
                      reversed ? (destinations.length - 1 - index) : index;
                  setState(() => _currentTab = logicalIndex);
                  if (logicalIndex == 0) _loadIconPreset();
                },
                labelType: NavigationRailLabelType.all,
                destinations: displayDestinations,
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
    final List<AdaptiveNavItem> items = [
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
          setState(() => _currentTab = logicalIndex);
          if (logicalIndex == 0) _loadIconPreset();
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

  Widget _buildRailLeading() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.card + tokens.spacing.gap,
      ),
      child: ChangeNotifierBuilder(
        notifier: appModel.incognitoNotifier,
        builder: (context, notifier, _) {
          return Image.asset(
            _iconAsset,
            width: 36,
            height: 36,
          );
        },
      ),
    );
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
