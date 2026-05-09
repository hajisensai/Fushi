import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
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

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    appModelNoUpdate.databaseCloseNotifier.addListener(refresh);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      appModel.populateDefaultMapping(appModel.targetLanguage);
      appModel.populateBookmarks();
      if (appModel.isFirstTimeSetup) {
        await appModel.showLanguageMenu();
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
        );
      }
    });
  }

  void refresh() {
    setState(() {});
  }

  @override
  void dispose() {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!appModel.isDatabaseOpen) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: buildAppBar(),
        body: SafeArea(child: buildBody()),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: const Border(),
          ),
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewPadding.bottom),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(0, Icons.menu_book, t.books),
              _buildNavItem(1, Icons.search, t.dictionaries),
              _buildNavItem(2, Icons.tune, t.settings),
            ],
          ),
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
        return const HomeDictionaryPage();
      case 2:
        return const DisplaySettingsPage();
      default:
        return const HomeReaderPage();
    }
  }

  Widget? buildLeading() {
    return ChangeNotifierBuilder(
      notifier: appModel.incognitoNotifier,
      builder: (context, notifier, _) {
        return Padding(
          padding: Spacing.of(context).insets.onlyLeft.normal,
          child: Image.asset('assets/meta/icon.png'),
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
        onTap: () => setState(() => _currentTab = index),
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
        final ReaderHoshiSource src = ReaderHoshiSource.instance;
        await showAppDialog(
          context: context,
          builder: (_) => BookImportDialog(
            repo: SrtBookRepository(appModel.database),
            audiobookRepo: AudiobookRepository(appModel.database),
            db: appModel.database,
            ttuMediaSourceIdentifier: src.uniqueKey,
          ),
        );
        ref.invalidate(hoshiBooksProvider(appModel.targetLanguage));
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
