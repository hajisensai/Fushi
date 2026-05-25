import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hibiki/utils.dart';

class HomePage extends BasePage {
  const HomePage({super.key});

  @override
  BasePageState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends BasePageState<HomePage>
    with WidgetsBindingObserver {
  String get appName => appModel.packageInfo.appName;
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
    } else if (AppLifecycleState.paused == state && appModel.lowMemoryMode) {
      PaintingBinding.instance.imageCache.clear();
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

    return Focus(
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
    );
  }

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: buildAppBar(),
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
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
      appBar: buildAppBar(),
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

  PreferredSizeWidget? buildAppBar() {
    switch (_currentTab) {
      case 1:
        return null;
      case 2:
        return adaptiveAppBar(
          context: context,
          leading: buildLeading(),
          title: buildTitle(),
          actions: buildSettingsActions(),
          titleSpacing: 8,
        );
      default:
        return adaptiveAppBar(
          context: context,
          leading: buildLeading(),
          title: buildTitle(),
          actions: buildActions(),
          titleSpacing: 8,
        );
    }
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

  Widget? buildLeading() {
    return ChangeNotifierBuilder(
      notifier: appModel.incognitoNotifier,
      builder: (context, notifier, _) {
        return Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Image.asset(
            _iconAsset,
            width: 32,
            height: 32,
          ),
        );
      },
    );
  }

  Widget buildTitle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(appName, style: textTheme.titleLarge),
        const Space.extraSmall(),
        Text(
          appVersion,
          style: textTheme.labelSmall!.copyWith(
            letterSpacing: 0,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  List<Widget> buildActions() {
    return [
      buildImportButton(),
      buildCollectionsButton(),
      buildStatisticsButton(),
    ];
  }

  List<Widget> buildSettingsActions() {
    return [
      IconButton(
        tooltip: t.options_language,
        icon: const Icon(Icons.translate_outlined),
        onPressed: appModel.showLanguageMenu,
      ),
      IconButton(
        tooltip: t.options_github,
        icon: const Icon(Icons.public_outlined),
        onPressed: () {
          launchUrl(
            Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
            mode: LaunchMode.externalApplication,
          );
        },
      ),
    ];
  }

  Widget buildImportButton() {
    return IconButton(
      tooltip: t.import_book,
      icon: const Icon(Icons.add),
      onPressed: () async {
        await showAppDialog(
          context: context,
          builder: (_) => BookImportDialog(
            repo: SrtBookRepository(appModel.database),
            audiobookRepo: AudiobookRepository(appModel.database),
            db: appModel.database,
          ),
        );
        ref.invalidate(hibikiBooksProvider(appModel.targetLanguage));
        ref.invalidate(srtBooksProvider);
      },
    );
  }

  Widget buildTagFilterButton() {
    return Consumer(
      builder: (context, ref, _) {
        final selectedIds = ref.watch(selectedTagIdsProvider);
        return HibikiIconButton(
          tooltip: t.tag_filter,
          icon: selectedIds.isEmpty ? Icons.filter_list : Icons.filter_list_off,
          onTap: () {
            if (isDesktopPlatform) {
              showAppDialog(
                context: context,
                builder: (_) => Dialog(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 480,
                      maxHeight: 600,
                    ),
                    child: const TagFilterSheet(),
                  ),
                ),
              );
            } else {
              adaptiveModalSheet(
                context: context,
                builder: (_) => const TagFilterSheet(),
              );
            }
          },
        );
      },
    );
  }

  Widget buildCollectionsButton() {
    return IconButton(
      tooltip: t.collections,
      icon: const Icon(Icons.collections_bookmark_outlined),
      onPressed: () {
        Navigator.push(
          context,
          adaptivePageRoute(builder: (_) => const CollectionsPage()),
        );
      },
    );
  }

  Widget buildStatisticsButton() {
    return IconButton(
      tooltip: t.reading_statistics,
      icon: const Icon(Icons.bar_chart_outlined),
      onPressed: () {
        Navigator.push(
          context,
          adaptivePageRoute(builder: (_) => const ReadingStatisticsPage()),
        );
      },
    );
  }
}
