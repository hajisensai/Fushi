import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/pages.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hibiki/utils.dart';

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
    final bool ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.digit1:
          setState(() => _currentTab = 0);
          _loadIconPreset();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit2:
          setState(() => _currentTab = 1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit3:
          setState(() => _currentTab = 2);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyF:
          setState(() => _currentTab = 1);
          _dictFocusSignal.value++;
          return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(t.sync_exit_warning_title),
                    content: Text(t.sync_exit_warning),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.dialog_cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.dialog_exit),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  SystemNavigator.pop();
                }
              },
              child: child!,
            ),
        child: Focus(
          autofocus: isDesktopPlatform,
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
        ));
  }

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              leading: _buildRailLeading(),
              groupAlignment: 0.0,
              selectedIndex: _currentTab,
              onDestinationSelected: (int index) {
                setState(() => _currentTab = index);
                if (index == 0) _loadIconPreset();
              },
              labelType: NavigationRailLabelType.all,
              destinations: [
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
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(child: buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(child: buildBody()),
      bottomNavigationBar: adaptiveBottomBar(
        context: context,
        currentIndex: _currentTab,
        onTap: (int index) {
          setState(() => _currentTab = index);
          if (index == 0) _loadIconPreset();
        },
        items: [
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
        ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
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
