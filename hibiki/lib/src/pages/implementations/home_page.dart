import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/sources/reader_ttu_source.dart';
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

      // Fire-and-forget update check after startup completes.
      if (mounted) {
        UpdateChecker.scheduleCheck(context, appVersion);
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
        bottomNavigationBar: Builder(
          builder: (context) {
            debugPrint('[hibiki-nav] building NavigationBar, _currentTab=$_currentTab');
            return NavigationBar(
              selectedIndex: _currentTab,
              onDestinationSelected: (i) {
                debugPrint('[hibiki-nav] tab tapped: $i');
                setState(() => _currentTab = i);
              },
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.menu_book),
                  label: t.books,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.search),
                  label: t.dictionaries,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.tune),
                  label: t.settings,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  PreferredSizeWidget? buildAppBar() {
    return AppBar(
      leading: buildLeading(),
      title: buildTitle(),
      actions: buildActions(),
      titleSpacing: 8,
    );
  }

  Widget buildBody() {
    switch (_currentTab) {
      case 1:
        return const HomeDictionaryPage();
      case 2:
        return const TtuSettingsDialogContent();
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
      buildStatisticsButton(),
    ];
  }

  Widget buildImportButton() {
    return JidoujishoIconButton(
      tooltip: t.import_book,
      icon: Icons.add,
      onTap: () async {
        final src = ReaderTtuSource.instance;
        final int port = src.getPortForLanguage(appModel.targetLanguage);
        await showDialog(
          context: context,
          builder: (_) => BookImportDialog(
            repo: SrtBookRepository(appModel.database),
            audiobookRepo: AudiobookRepository(appModel.database),
            serverPort: port,
            ttuMediaSourceIdentifier: src.uniqueKey,
          ),
        );
        ref.invalidate(ttuBooksProvider(appModel.targetLanguage));
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
