import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// A page template which assumes use of [BasePageState] by which all pages
/// in the app will conveniently share base functionality.
abstract class BasePage extends ConsumerStatefulWidget {
  /// Create an instance of this page.
  const BasePage({super.key});

  @override
  BasePageState<BasePage> createState() => BasePageState();
}

/// A base class for providing all pages in the app with a collection
/// of shared functions and variables. In large part, this was implemented to
/// define shortcuts for common lengthy methods across UI code.
class BasePageState<T extends BasePage> extends ConsumerState<T> {
  late final AppModel _cachedAppModel;
  late final CreatorModel _cachedCreatorModel;

  @override
  void initState() {
    super.initState();
    _cachedAppModel = ref.read(appProvider);
    _cachedCreatorModel = ref.read(creatorProvider);
  }

  /// Access the global model responsible for app-wide state management.
  /// Falls back to cached instance after dispose to prevent
  /// ProviderSubscription.read on closed subscription.
  AppModel get appModel {
    if (!mounted) return _cachedAppModel;
    return ref.watch(appProvider);
  }

  /// Access the global model responsible for creator state management.
  /// Falls back to cached instance after dispose.
  CreatorModel get creatorModel {
    if (!mounted) return _cachedCreatorModel;
    return ref.watch(creatorProvider);
  }

  /// Access the global model responsible for app-wide state management without
  /// listening to state updates. Safe to use in dispose().
  AppModel get appModelNoUpdate => _cachedAppModel;

  /// Access the global model responsible for creator state management without
  /// listening to state updates. Safe to use in dispose().
  CreatorModel get creatorModelNoUpdate => _cachedCreatorModel;

  /// Shortcut for accessing the app-wide theme-defined text theme.
  TextTheme get textTheme => Theme.of(context).textTheme;

  /// Shortcut for accessing the app-wide theme.
  ThemeData get theme => Theme.of(context);

  /// Get the selection controls for a [SelectableText].
  MaterialTextSelectionControls get selectionControls =>
      HibikiTextSelectionControls(
        searchAction: onSearch,
        stashAction: onStash,
        shareAction: onShare,
        allowCopy: true,
        allowSelectAll: true,
        allowCut: true,
        allowPaste: true,
      );

  /// Action to perform upon using the Search context option.
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    await appModel.openPopupDictionaryLookup(searchTerm: searchTerm);
  }

  /// Action to perform upon using the Share context option.
  void onShare(String searchTerm, {String? sentence = ''}) async {
    Share.share(searchTerm);
  }

  /// Action to perform upon using the Stash context option.
  void onStash(String searchTerm) {
    appModel.addToStash(terms: [searchTerm]);
  }

  @override
  Widget build(BuildContext context) {
    throw UnimplementedError();
  }

  /// Standard error message for use across the application.
  /// General widget for showing an error or a retry screen.
  Widget buildError({
    Object? error,
    StackTrace? stack,
    Function()? refresh,
  }) {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.error,
        message: '$error',
      ),
    );
  }

  /// Standard loading circle for use across the application.
  Widget buildLoading() {
    return Center(
      child: SizedBox(
        height: Spacing.of(context).spaces.big,
        width: Spacing.of(context).spaces.big,
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      ),
    );
  }
}
