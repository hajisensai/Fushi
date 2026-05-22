import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
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
                  icon: const Icon(Icons.menu_book),
                  label: Text(t.books),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.search),
                  label: Text(t.dictionaries),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.tune),
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
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: const Border(),
        ),
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewPadding.bottom),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(0, Icons.menu_book, t.books),
            _buildNavItem(1, Icons.search, t.dictionaries),
            _buildNavItem(2, Icons.tune, t.settings),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget? buildAppBar() {
    switch (_currentTab) {
      case 1:
        return null;
      case 2:
        return AppBar(
          leading: buildLeading(),
          title: buildTitle(),
          actions: buildSettingsActions(),
          titleSpacing: 8,
        );
      default:
        return AppBar(
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
        return const HoshiSettingsContent();
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

  Widget _buildNavItem(int index, IconData icon, String label) {
    final selected = _currentTab == index;
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() => _currentTab = index);
          if (index == 0) _loadIconPreset();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(label, style: textTheme.labelSmall?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> buildSettingsActions() {
    return [
      JidoujishoIconButton(
        tooltip: t.options_language,
        icon: Icons.translate,
        onTap: appModel.showLanguageMenu,
      ),
      JidoujishoIconButton(
        tooltip: t.options_github,
        icon: Icons.public,
        onTap: () {
          launchUrl(
            Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
            mode: LaunchMode.externalApplication,
          );
        },
      ),
    ];
  }

  Widget buildImportButton() {
    return JidoujishoIconButton(
      tooltip: t.import_book,
      icon: Icons.add,
      onTap: () async {
        await showAppDialog(
          context: context,
          builder: (_) => BookImportDialog(
            repo: SrtBookRepository(appModel.database),
            audiobookRepo: AudiobookRepository(appModel.database),
            db: appModel.database,
          ),
        );
        ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
        ref.invalidate(srtBooksProvider);
      },
    );
  }

  Widget buildTagFilterButton() {
    return Consumer(
      builder: (context, ref, _) {
        final selectedIds = ref.watch(selectedTagIdsProvider);
        return JidoujishoIconButton(
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
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const TagFilterSheet(),
              );
            }
          },
        );
      },
    );
  }

  Widget buildCollectionsButton() {
    return JidoujishoIconButton(
      tooltip: t.collections,
      icon: Icons.collections_bookmark,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CollectionsPage()),
        );
      },
    );
  }

  Widget buildStatisticsButton() {
    return JidoujishoIconButton(
      tooltip: t.reading_statistics,
      icon: Icons.bar_chart,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ReadingStatisticsPage()),
        );
      },
    );
  }
}
