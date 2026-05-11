import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:collection/collection.dart';
import 'package:clipboard/clipboard.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:external_path/external_path.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_charset_detector/flutter_charset_detector.dart';
import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:drift/drift.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:remove_emoji/remove_emoji.dart';
import 'package:restart_app/restart_app.dart';
import 'package:wakelock/wakelock.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/dictionary/dictionary_utils.dart'
    show importDictionaryViaHoshidicts;
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';
import 'package:hibiki/src/media/audiobook/reading_statistic_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/epub/ttu_migration.dart';
import 'package:hibiki/src/epub/ttu_migration_server.dart';
import 'package:hibiki/i18n/strings.g.dart';

/// A list of fields that the app will support at runtime.
final List<Field> globalFields = List<Field>.unmodifiable(
  [
    SentenceField.instance,
    TermField.instance,
    ReadingField.instance,
    MeaningField.instance,
    NotesField.instance,
    ImageField.instance,
    AudioField.instance,
    AudioSentenceField.instance,
    PitchAccentField.instance,
    FuriganaField.instance,
    FrequencyField.instance,
    ContextField.instance,
    ClozeBeforeField.instance,
    ClozeInsideField.instance,
    ClozeAfterField.instance,
    ExpandedMeaningField.instance,
    CollapsedMeaningField.instance,
    HiddenMeaningField.instance,
    TagsField.instance,
  ],
);

/// A list of media types that the app will support at runtime.
final Map<String, Field> fieldsByKey = Map.unmodifiable(
  Map<String, Field>.fromEntries(
    globalFields.map(
      (field) => MapEntry(field.uniqueKey, field),
    ),
  ),
);

/// A global [Provider] for app-wide configuration and state management.
final appProvider = ChangeNotifierProvider<AppModel>((ref) {
  return AppModel();
});

/// Provides color for all quick actions.
final quickActionColorProvider =
    FutureProvider.family<Map<String, Color?>, DictionaryEntry>(
        (ref, entry) async {
  AppModel appModel = ref.watch(appProvider);
  List<Future<Color?>> futures = appModel.quickActions.values.map((e) async {
    return e.getIconColor(
      appModel: appModel,
      entry: entry,
    );
  }).toList();

  List<Color?> colors = await Future.wait(futures);
  return Map<String, Color?>.fromEntries(
      appModel.quickActions.values.mapIndexed((i, action) {
    return MapEntry(action.uniqueKey, colors[i]);
  }));
});

/// A global [Provider] for maintaining visible once state.
final visibleOnceProvider =
    StateProvider.family<bool, DictionaryEntry>((ref, entry) => false);

/// A global [Provider] for listening to search term changes in PIP mode.
final pipSearchTermProvider = StateProvider<String>((ref) => '');

/// A global [Provider] for listening to search term position changes in PIP mode.
final pipSearchPositionProvider = StateProvider<int>((ref) => 0);

Color _readableOnColor(Color color) {
  return ThemeData.estimateBrightnessForColor(color) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

Color _deriveContainer(Color role, Brightness brightness) {
  final Color target =
      brightness == Brightness.dark ? Colors.black : Colors.white;
  return Color.lerp(role, target, brightness == Brightness.dark ? 0.7 : 0.85)!;
}

ColorScheme buildHibikiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
}) {
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final Color? secContainer =
      secondary != null ? _deriveContainer(secondary, brightness) : null;
  final Color? terContainer =
      tertiary != null ? _deriveContainer(tertiary, brightness) : null;
  return base.copyWith(
    primary: primary ?? base.primary,
    onPrimary: primary != null ? _readableOnColor(primary) : base.onPrimary,
    secondary: secondary ?? base.secondary,
    onSecondary:
        secondary != null ? _readableOnColor(secondary) : base.onSecondary,
    secondaryContainer: secContainer ?? base.secondaryContainer,
    onSecondaryContainer: secContainer != null
        ? _readableOnColor(secContainer)
        : base.onSecondaryContainer,
    tertiary: tertiary ?? base.tertiary,
    onTertiary: tertiary != null ? _readableOnColor(tertiary) : base.onTertiary,
    tertiaryContainer: terContainer ?? base.tertiaryContainer,
    onTertiaryContainer: terContainer != null
        ? _readableOnColor(terContainer)
        : base.onTertiaryContainer,
    primaryContainer: primaryContainer ?? base.primaryContainer,
    onPrimaryContainer: primaryContainer != null
        ? _readableOnColor(primaryContainer)
        : base.onPrimaryContainer,
  );
}

/// A scoped model for parameters that affect the entire application.
/// RiverPod is used for global state management across multiple layers,
/// especially for preferences that persist across application restarts.
class AppModel with ChangeNotifier {
  /// Used for showing dialogs without needing to pass around a [BuildContext].
  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;
  late final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  /// Used to get the versioning metadata of the app. See [initialise].
  RouteObserver<PageRoute> get routeObserver => _routeObserver;
  final RouteObserver<PageRoute> _routeObserver = RouteObserver<PageRoute>();

  /// Persistent database (Drift/SQLite).
  late final HibikiDatabase _database;

  /// In-memory preference cache for synchronous reads.
  final Map<String, String> _prefCache = {};

  /// In-memory cache of search history items (historyKey → list of terms).
  final Map<String, List<String>> _searchHistoryCache = {};

  /// In-memory cache of media items for sync access.
  List<MediaItem> _mediaItemsCache = [];

  /// In-memory list of dictionary history results.
  final List<DictionarySearchResult> _dictionaryHistoryResults = [];

  /// Used to get the versioning metadata of the app. See [initialise].
  PackageInfo get packageInfo => _packageInfo;
  late final PackageInfo _packageInfo;

  /// Used to get information on the Android version of the device.
  AndroidDeviceInfo get androidDeviceInfo => _androidDeviceInfo;
  late final AndroidDeviceInfo _androidDeviceInfo;

  /// Whether [initialise] has completed successfully.
  bool get isInitialised => _isInitialised;
  bool _isInitialised = false;

  /// Non-null if [initialise] threw; UI should display this instead of spinning.
  String? get initError => _initError;
  String? _initError;

  /// Used for caching images and audio produced from media seeds.
  DefaultCacheManager get cacheManager => _cacheManager;
  final _cacheManager = DefaultCacheManager();

  /// Used to notify dictionary widgets to dictionary history additions.
  final ChangeNotifier dictionaryEntriesNotifier = ChangeNotifier();

  /// Used to notify dictionary widgets to dictionary import additions.
  final ChangeNotifier dictionarySearchAgainNotifier = ChangeNotifier();

  /// Used to notify dictionary widgets to dictionary menu changes.
  final ChangeNotifier dictionaryMenuNotifier = ChangeNotifier();

  /// For refreshing on dictionary result additions.
  void refreshDictionaryHistory() {
    dictionaryMenuNotifier.notifyListeners();
  }

  /// Used to strip emoji from search terms.
  final _removeEmoji = RemoveEmoji();

  /// Used to notify toggling incognito. Updates the app logo to and from
  /// grayscale.
  final ChangeNotifier incognitoNotifier = ChangeNotifier();

  /// Notifies app to stop showing any screens.
  final ChangeNotifier databaseCloseNotifier = ChangeNotifier();

  /// These directories are prepared at startup in order to reduce redundancy
  /// in actual runtime.
  /// Directory where data that may be dumped is stored.
  Directory get temporaryDirectory => _temporaryDirectory;
  late final Directory _temporaryDirectory;

  /// Directory where data may be persisted.
  Directory get appDirectory => _appDirectory;
  late final Directory _appDirectory;

  /// Directory where database data is persisted.
  Directory get databaseDirectory => _databaseDirectory;
  late final Directory _databaseDirectory;

  /// Directory where database data is persisted.
  Directory get dictionaryResourceDirectory => _dictionaryResourceDirectory;
  late final Directory _dictionaryResourceDirectory;

  /// Directory where browser cache data may be persisted.
  Directory get browserDirectory => _browserDirectory;
  late final Directory _browserDirectory;

  /// Directory where media source thumbnails may be persisted.
  Directory get thumbnailsDirectory => _thumbnailsDirectory;
  late final Directory _thumbnailsDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs.
  Directory get exportDirectory => _exportDirectory;
  late final Directory _exportDirectory;

  /// Directory where the browser media source saves web archives for offline
  /// use.
  Directory get webArchiveDirectory => _webArchiveDirectory;
  late final Directory _webArchiveDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs. Fallback for failure.
  Directory get alternateExportDirectory => _alternateExportDirectory;
  late final Directory _alternateExportDirectory;

  /// Directory used as a working directory for dictionary imports.
  Directory get dictionaryImportWorkingDirectory =>
      _dictionaryImportWorkingDirectory;
  late final Directory _dictionaryImportWorkingDirectory;

  /// Used to fetch a language by its locale tag with constant time performance.
  /// Initialised with [populateLanguages] at startup.
  late final Map<String, Language> languages;

  /// Used to fetch an app locale by its locale tag with constant time
  /// performance. Initialised with [populateLocales] at startup.
  late final Map<String, Locale> locales;

  /// Used to fetch a dictionary format by its unique key with constant time
  /// performance. Initialised with [populateDictionaryFormats] at startup.
  late final Map<String, DictionaryFormat> dictionaryFormats;

  /// Used to fetch a media type by its unique key with constant time
  /// performance. Initialised with [populateMediaTypes] at startup.
  late final Map<String, MediaType> mediaTypes;

  /// Used to fetch initialised fields by their unique key with constant
  /// time performance. Initialised with [populateEnhancements] at startup.
  late final Map<String, Field> fields;

  /// Used to fetch initialised enhancements by their unique key with constant
  /// time performance. Initialised with [populateEnhancements] at startup.
  late final Map<Field, Map<String, Enhancement>> enhancements;

  /// Used to fetch initialised actions by their unique key with constant
  /// time performance. Initialised with [populateQuickActions] at startup.
  late final Map<String, QuickAction> quickActions;

  /// Used to fetch initialised sources by their unique key with constant
  /// time performance. Initialised with [populateMediaSources] at startup.
  late final Map<MediaType, Map<String, MediaSource>> mediaSources;

  /// Maximum number of manual enhancements in a field.
  final int maximumFieldEnhancements = 5;

  /// Maximum number of quick actions.
  final int maximumQuickActions = 6;

  /// Maximum number of search history items.
  final int maximumSearchHistoryItems = 60;

  /// Maximum number of media history items.
  final int maximumMediaHistoryItems = 100;

  /// Maximum number of dictionary history items.
  final int maximumDictionaryHistoryItems = 10;

  /// Maximum number of dictionary search results stored in the database.
  final int maximumDictionarySearchResults = 200;

  /// Maximum number of headwords in a returned dictionary result for
  /// performance purposes.
  final int defaultMaximumDictionaryTermsInResult = 10;

  /// Used as the history key used for the Stash.
  final String stashKey = 'stash';

  /// Used to check if the dictionary tab should be refreshed on switching tabs.
  bool shouldRefreshTabs = false;

  /// In-memory cache of dictionaries, kept in sync with the database.
  List<Dictionary> _dictionariesCache = [];

  /// Returns all dictionaries imported into the database. Sorted by the
  /// user-defined order in the dictionary menu.
  List<Dictionary> get dictionaries => List.unmodifiable(_dictionariesCache);

  List<Dictionary> get termDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.term).toList();
  List<Dictionary> get freqDictionaries => _dictionariesCache
      .where((d) => d.type == DictionaryType.frequency)
      .toList();
  List<Dictionary> get pitchDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.pitch).toList();
  List<Dictionary> get kanjiDictionaries =>
      _dictionariesCache.where((d) => d.type == DictionaryType.kanji).toList();

  void _rebuildDictPathsCache() {
    final termPaths = <String>[];
    final freqPaths = <String>[];
    final pitchPaths = <String>[];
    for (final d in _dictionariesCache) {
      final p = path.join(dictionaryResourceDirectory.path, d.name);
      if (!Directory(p).existsSync()) continue;
      switch (d.type) {
        case DictionaryType.term:
        case DictionaryType.kanji:
          termPaths.add(p);
        case DictionaryType.frequency:
          freqPaths.add(p);
        case DictionaryType.pitch:
          pitchPaths.add(p);
      }
    }
    if (termPaths.isNotEmpty || freqPaths.isNotEmpty || pitchPaths.isNotEmpty) {
      HoshiDicts.initializeTyped(
        termPaths: termPaths,
        freqPaths: freqPaths,
        pitchPaths: pitchPaths,
      );
    }
  }

  /// Returns all dictionary history results. Oldest is first.
  List<DictionarySearchResult> get dictionaryHistory =>
      List.unmodifiable(_dictionaryHistoryResults);

  /// For invoking pauses from media where needed.
  Stream<void> get currentMediaPauseStream =>
      _currentMediaPauseController.stream;
  final StreamController<void> _currentMediaPauseController =
      StreamController.broadcast();

  /// For listening to searches made inside the Card Creator.
  Stream<void> get cardCreatorRecursiveSearchStream =>
      _cardCreatorRecursiveSearchStreamController.stream;
  final StreamController<void> _cardCreatorRecursiveSearchStreamController =
      StreamController.broadcast();

  /// Broadcast that a search was made in the Card Creator
  void notifyRecursiveSearch() {
    _cardCreatorRecursiveSearchStreamController.add(null);
  }

  /// Allows actions to be performed upon Play/Pause on headset buttons.
  Stream<void> get playPauseHeadsetActionStream =>
      _playPauseHeadsetActionStreamController.stream;
  final StreamController<void> _playPauseHeadsetActionStreamController =
      StreamController.broadcast();

  /// For listening to changes for whether or not the Card Creator is open.
  Stream<bool> get creatorActiveStream => _creatorActiveController.stream;
  final StreamController<bool> _creatorActiveController =
      StreamController.broadcast();

  /// Used to check whether or not the app is currently using a media source.
  bool get isMediaOpen => _currentMediaSource != null;

  /// Current active media source.
  MediaSource? get currentMediaSource => _currentMediaSource;
  MediaSource? _currentMediaSource;

  /// Current active media item.
  MediaItem? get currentMediaItem => _currentMediaItem;
  MediaItem? _currentMediaItem;

  /// Blocks creator from processing initial media while player controller is not ready.
  bool blockCreatorInitialMedia = false;

  /// Get the app-wide text style.
  TextStyle get textStyle => TextStyle(
        fontFamily: targetLanguage.defaultFontFamily,
        fontFeatures: const [FontFeature('liga', 0)],
        locale: targetLanguage.locale,
        textBaseline: targetLanguage.textBaseline,
      );

  /// This override is a workaround required to theme the app-wide [TextTheme]
  /// based on the [Locale] and [TextBaseline] of the active target language.
  TextTheme get textTheme => TextTheme(
        displayLarge: textStyle,
        displayMedium: textStyle,
        displaySmall: textStyle,
        headlineLarge: textStyle,
        headlineMedium: textStyle,
        headlineSmall: textStyle,
        titleLarge: textStyle,
        titleMedium: textStyle,
        titleSmall: textStyle,
        bodyLarge: textStyle,
        bodyMedium: textStyle,
        bodySmall: textStyle,
        labelLarge: textStyle,
        labelMedium: textStyle,
        labelSmall: textStyle,
      );

  /// Material 3 主色种子 —— 深青 / 夜空蓝，贴近 Hoshi Reader iOS 的
  /// 日式沉浸阅读调性。所有 surface / primary / secondary / 对比色都由
  /// [ColorScheme.fromSeed] 推导出来，后续 PR 在组件级替换硬编码色时
  /// 统一走 `colorScheme.*` token。
  Color get _seedColor {
    if (appThemeKey == 'custom-theme') return customThemeSeed;
    return themePresets[appThemeKey]?.seed ?? const Color(0xFF1F4959);
  }

  ThemeData get theme {
    final bool useCustomRoles = appThemeKey == 'custom-theme';
    final cs = buildHibikiColorScheme(
      seedColor: _seedColor,
      brightness: Brightness.light,
      primary: useCustomRoles ? customThemePrimaryColor : null,
      secondary: useCustomRoles ? customThemeSecondaryColor : null,
      tertiary: useCustomRoles ? customThemeTertiaryColor : null,
      primaryContainer: useCustomRoles ? customThemeContainerColor : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateColor.resolveWith((states) {
          return states.contains(MaterialState.selected)
              ? cs.primary
              : Colors.white;
        }),
        trackColor: MaterialStateColor.resolveWith((states) {
          return states.contains(MaterialState.selected)
              ? cs.primaryContainer
              : Colors.grey;
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: textTheme.labelSmall,
        unselectedLabelStyle: textTheme.labelSmall,
        showSelectedLabels: true,
        showUnselectedLabels: true,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        shape: RoundedRectangleBorder(),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        horizontalTitleGap: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(
            color: Colors.black54,
          ),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: cs.primary),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: MaterialStateProperty.all(3),
        thumbVisibility: MaterialStateProperty.all(true),
      ),
      sliderTheme: SliderThemeData(
        thumbColor: cs.primary,
        activeTrackColor: cs.primary,
        inactiveTrackColor: Colors.grey,
        trackShape: const RectangularSliderTrackShape(),
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
    );
  }

  ThemeData get darkTheme {
    final bool useCustomRoles = appThemeKey == 'custom-theme';
    final cs = buildHibikiColorScheme(
      seedColor: _seedColor,
      brightness: Brightness.dark,
      primary: useCustomRoles ? customThemePrimaryColor : null,
      secondary: useCustomRoles ? customThemeSecondaryColor : null,
      tertiary: useCustomRoles ? customThemeTertiaryColor : null,
      primaryContainer: useCustomRoles ? customThemeContainerColor : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateColor.resolveWith((states) {
          return states.contains(MaterialState.selected)
              ? cs.primary
              : Colors.grey;
        }),
        trackColor: MaterialStateColor.resolveWith((states) {
          return states.contains(MaterialState.selected)
              ? cs.primaryContainer
              : Colors.grey;
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: textTheme.labelSmall,
        unselectedLabelStyle: textTheme.labelSmall,
        showSelectedLabels: true,
        showUnselectedLabels: true,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        shape: RoundedRectangleBorder(),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        horizontalTitleGap: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(
            color: Colors.white70,
          ),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: cs.primary),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: MaterialStateProperty.all(true),
      ),
      sliderTheme: SliderThemeData(
        thumbColor: cs.primary,
        activeTrackColor: cs.primary,
        inactiveTrackColor: Colors.grey,
        trackShape: const RectangularSliderTrackShape(),
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
    );
  }

  /// Get the sentence to be used by the [SentenceField] upon card creation.
  JidoujishoTextSelection getCurrentSentence() {
    if (isMediaOpen) {
      return _currentMediaSource!.currentSentence;
    } else {
      MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
      if (mediaType is DictionaryMediaType) {
        return JidoujishoTextSelection(
          text: '',
        );
      } else {
        return (_currentMediaSource ??
                (getCurrentSourceForMediaType(mediaType: mediaType)))
            .currentSentence;
      }
    }
  }

  /// This should all be refactored as part of [MediaItem] if possible. No
  /// reason to expose it here if not for card export functions. This is super
  /// cursed. Need to extract this to its own Provider at some point.

  /// Override color for the dictionary widget.
  Color? get overrideDictionaryColor => _overrideDictionaryColor;
  Color? _overrideDictionaryColor;

  /// Override theme for the dictionary widget.
  ThemeData? get overrideDictionaryTheme => _overrideDictionaryTheme;
  ThemeData? _overrideDictionaryTheme;

  /// Override color for the dictionary widget.
  void setOverrideDictionaryColor(Color? color) {
    _overrideDictionaryColor = color;
  }

  /// Override theme for the dictionary widget.
  void setOverrideDictionaryTheme(ThemeData? themeData) {
    _overrideDictionaryTheme = themeData;
  }

  /// Get the current media item for use in tracking history and generating
  /// media for card creation based on media progress.
  MediaItem? getCurrentMediaItem() {
    if (_currentMediaSource == null) {
      return null;
    } else {
      return _currentMediaItem;
    }
  }

  /// Manually flag that the app is now using a media item. Prefer [openMedia]
  /// instead of this.
  void setCurrentMediaItem(MediaItem mediaItem) {
    _currentMediaItem = mediaItem;
    _currentMediaSource = mediaItem.getMediaSource(appModel: this);
  }

  /// Update the user-defined order of a given dictionary in the database.
  /// See the dictionary dialog's [ReorderableListView] for usage.
  void updateDictionaryOrder(List<Dictionary> newDictionaries) async {
    final updatedNames = newDictionaries.map((d) => d.name).toSet();
    final others =
        _dictionariesCache.where((d) => !updatedNames.contains(d.name));
    _dictionariesCache = [...others, ...newDictionaries]
      ..sort((a, b) => a.order.compareTo(b.order));
    _rebuildDictPathsCache();
    for (final dictionary in newDictionaries) {
      await _database.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
    }
  }

  /// Populate maps for languages at startup to optimise performance.
  void populateLanguages() async {
    /// A list of languages that the app will support at runtime.
    final List<Language> availableLanguages = List<Language>.unmodifiable(
      [
        JapaneseLanguage.instance,
        EnglishLanguage.instance,
        ChineseLanguage.instance,
      ],
    );

    languages = Map<String, Language>.unmodifiable(
      Map<String, Language>.fromEntries(
        availableLanguages.map(
          (language) => MapEntry(language.locale.toLanguageTag(), language),
        ),
      ),
    );
  }

  /// Populate maps for locales at startup to optimise performance.
  void populateLocales() async {
    /// A list of locales that the app will support at runtime. This is not
    /// related to supported target languages.
    final List<Locale> availableLocales = List<Locale>.unmodifiable(
      [
        const Locale('en', 'US'),
        const Locale('zh', 'CN'),
        const Locale('zh', 'HK'),
        const Locale('ja'),
        const Locale('ko'),
        const Locale('es'),
        const Locale('fr'),
        const Locale('de'),
        const Locale('pt', 'BR'),
        const Locale('ru'),
        const Locale('vi'),
        const Locale('th'),
        const Locale('id'),
        const Locale('ar'),
        const Locale('nl'),
        const Locale('it'),
        const Locale('tr'),
      ],
    );

    locales = Map<String, Locale>.unmodifiable(
      Map<String, Locale>.fromEntries(
        availableLocales.map(
          (locale) => MapEntry(locale.toLanguageTag(), locale),
        ),
      ),
    );
  }

  /// Populate maps for media types at startup to optimise performance.
  void populateMediaTypes() async {
    /// A list of media types that the app will support at runtime.
    final List<MediaType> availableMediaTypes = List<MediaType>.unmodifiable(
      [
        ReaderMediaType.instance,
        DictionaryMediaType.instance,
      ],
    );

    mediaTypes = Map<String, MediaType>.unmodifiable(
      Map<String, MediaType>.fromEntries(
        availableMediaTypes.map(
          (mediaType) => MapEntry(mediaType.uniqueKey, mediaType),
        ),
      ),
    );
  }

  /// Populate maps for media sources at startup to optimise performance.
  void populateMediaSources() async {
    /// A list of media sources that the app will support at runtime.
    final Map<MediaType, List<MediaSource>> availableMediaSources = {
      ReaderMediaType.instance: [
        ReaderHoshiSource.instance,
      ],
      DictionaryMediaType.instance: [],
    };

    mediaSources = Map<MediaType, Map<String, MediaSource>>.unmodifiable(
      availableMediaSources.map(
        (type, sources) => MapEntry(
          type,
          Map<String, MediaSource>.unmodifiable(
            Map<String, MediaSource>.fromEntries(
              sources.map(
                (source) => MapEntry(source.uniqueKey, source),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Populate maps for dictionary formats at startup to optimise performance.
  void populateDictionaryFormats() async {
    /// A list of dictionary formats that the app will support at runtime.
    final List<DictionaryFormat> availableDictionaryFormats =
        List<DictionaryFormat>.unmodifiable(
      [
        YomichanFormat.instance,
        MigakuFormat.instance,
        AbbyyLingvoFormat.instance,
        MdictFormat.instance,
      ],
    );

    dictionaryFormats = Map<String, DictionaryFormat>.unmodifiable(
      Map<String, DictionaryFormat>.fromEntries(
        availableDictionaryFormats.map(
          (dictionaryFormat) => MapEntry(
            dictionaryFormat.uniqueKey,
            dictionaryFormat,
          ),
        ),
      ),
    );
  }

  /// Populate maps for fields at startup to optimise performance.
  void populateFields() async {
    fields = Map<String, Field>.unmodifiable(
      Map<String, Field>.fromEntries(
        globalFields.map(
          (field) => MapEntry(field.uniqueKey, field),
        ),
      ),
    );
  }

  /// Populate maps for enhancements at startup to optimise performance.
  void populateEnhancements() async {
    /// A list of enhancements that the app will support at runtime.
    final Map<Field, List<Enhancement>> availableEnhancements = {
      AudioField.instance: [
        ClearFieldEnhancement(field: AudioField.instance),
        LocalAudioEnhancement(field: AudioField.instance),
        PickAudioEnhancement(field: AudioField.instance),
        AudioRecorderEnhancement(field: AudioField.instance),
      ],
      AudioSentenceField.instance: [
        ClearFieldEnhancement(field: AudioSentenceField.instance),
        PickAudioEnhancement(field: AudioSentenceField.instance),
        AudioRecorderEnhancement(field: AudioSentenceField.instance),
      ],
      NotesField.instance: [
        ClearFieldEnhancement(field: NotesField.instance),
        OpenStashEnhancement(field: NotesField.instance),
        PopFromStashEnhancement(field: NotesField.instance),
        TextSegmentationEnhancement(field: NotesField.instance),
      ],
      ImageField.instance: [
        ClearFieldEnhancement(field: ImageField.instance),
        CropImageEnhancement(),
        PickImageEnhancement(),
        CameraEnhancement(),
      ],
      MeaningField.instance: [
        ClearFieldEnhancement(field: MeaningField.instance),
        SentencePickerEnhancement(field: MeaningField.instance),
        TextSegmentationEnhancement(field: MeaningField.instance),
      ],
      ReadingField.instance: [
        ClearFieldEnhancement(field: ReadingField.instance),
      ],
      SentenceField.instance: [
        ClearFieldEnhancement(field: SentenceField.instance),
        TextSegmentationEnhancement(field: SentenceField.instance),
        SentencePickerEnhancement(field: SentenceField.instance),
        OpenStashEnhancement(field: SentenceField.instance),
        PopFromStashEnhancement(field: SentenceField.instance),
      ],
      TermField.instance: [
        ClearFieldEnhancement(field: TermField.instance),
        SearchDictionaryEnhancement(),
        OpenStashEnhancement(field: TermField.instance),
        PopFromStashEnhancement(field: TermField.instance),
      ],
      ContextField.instance: [
        ClearFieldEnhancement(field: ContextField.instance),
        OpenStashEnhancement(field: ContextField.instance),
        PopFromStashEnhancement(field: ContextField.instance),
      ],
      PitchAccentField.instance: [
        ClearFieldEnhancement(field: PitchAccentField.instance),
      ],
      FuriganaField.instance: [
        ClearFieldEnhancement(field: FuriganaField.instance),
      ],
      FrequencyField.instance: [
        ClearFieldEnhancement(field: FrequencyField.instance),
      ],
      CollapsedMeaningField.instance: [
        ClearFieldEnhancement(field: CollapsedMeaningField.instance),
        SentencePickerEnhancement(field: CollapsedMeaningField.instance),
        TextSegmentationEnhancement(field: CollapsedMeaningField.instance),
      ],
      ExpandedMeaningField.instance: [
        ClearFieldEnhancement(field: ExpandedMeaningField.instance),
        SentencePickerEnhancement(field: ExpandedMeaningField.instance),
        TextSegmentationEnhancement(field: ExpandedMeaningField.instance),
      ],
      HiddenMeaningField.instance: [
        ClearFieldEnhancement(field: HiddenMeaningField.instance),
        SentencePickerEnhancement(field: HiddenMeaningField.instance),
        TextSegmentationEnhancement(field: HiddenMeaningField.instance),
      ],
      TagsField.instance: [
        ClearFieldEnhancement(field: TagsField.instance),
        SaveTagsEnhancement(),
      ],
      ClozeBeforeField.instance: [
        ClearFieldEnhancement(field: ClozeBeforeField.instance),
      ],
      ClozeAfterField.instance: [
        ClearFieldEnhancement(field: ClozeAfterField.instance),
      ],
      ClozeInsideField.instance: [
        ClearFieldEnhancement(field: ClozeInsideField.instance),
      ],
    };

    enhancements = Map<Field, Map<String, Enhancement>>.unmodifiable(
      availableEnhancements.map(
        (field, enhancements) => MapEntry(
          field,
          Map<String, Enhancement>.unmodifiable(
            Map<String, Enhancement>.fromEntries(
              enhancements.map(
                (enhancement) => MapEntry(enhancement.uniqueKey, enhancement),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Populate maps for actions at startup to optimise performance.
  void populateQuickActions() async {
    /// A list of actions that the app will support at runtime.
    final List<QuickAction> availableQuickActions = [
      AddToStashAction(),
      CopyToClipboardAction(),
      ShareAction(),
      PlayAudioAction(),
    ];

    quickActions = Map<String, QuickAction>.unmodifiable(
      Map<String, QuickAction>.fromEntries(
        availableQuickActions.map(
          (quickAction) => MapEntry(quickAction.uniqueKey, quickAction),
        ),
      ),
    );
  }

  /// Stub — old mapping system removed; new Anki export lives in lib/src/anki/.
  void populateDefaultMapping(Language language) async {}

  /// Stub kept for call-site compatibility.
  void populateBookmarks() {}

  /// Return the app external directory found in the public DCIM directory.
  /// This path also initialises the folder if it does not exist, and includes
  /// a .nomedia file within the folder.
  Future<Directory> prepareHibikiDirectory() async {
    String publicDirectory =
        await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DCIM);
    try {
      String directoryPath = path.join(publicDirectory, 'hibiki');
      String noMediaFilePath = path.join(publicDirectory, 'hibiki', '.nomedia');

      Directory hibikiDirectory = Directory(directoryPath);
      File noMediaFile = File(noMediaFilePath);

      if (!hibikiDirectory.existsSync()) {
        hibikiDirectory.createSync(recursive: true);
      }
      if (!noMediaFile.existsSync()) {
        noMediaFile.createSync();
      }

      return hibikiDirectory;
    } catch (e) {
      debugPrint('DCIM unavailable, using fallback directory.');
      return prepareFallbackHibikiDirectory();
    }
  }

  /// Return the app external directory found in the internal app directory.
  /// This path also initialises the folder if it does not exist, and includes
  /// a .nomedia file within the folder.
  Future<Directory> prepareFallbackHibikiDirectory() async {
    String directoryPath = path.join(appDirectory.path, 'hibikiExport');
    String noMediaFilePath =
        path.join(appDirectory.path, 'hibikiExport', '.nomedia');

    Directory hibikiDirectory = Directory(directoryPath);
    File noMediaFile = File(noMediaFilePath);

    if (!hibikiDirectory.existsSync()) {
      hibikiDirectory.createSync(recursive: true);
    }
    if (!noMediaFile.existsSync()) {
      noMediaFile.createSync();
    }

    return hibikiDirectory;
  }

  /// Preloads the app icon so that there is no pop-in.
  final Image appIcon = Image.asset(
    'assets/meta/icon.png',
  );

  /// Injects licenses to be displayed in the licenses page that aren't
  /// pre-included by Flutter upon compilation but are included as assets.
  Future<void> injectAssetLicenses() async {
    final packageNames = [
      'ebook-reader',
    ];

    for (String packageName in packageNames) {
      String licenseText =
          await rootBundle.loadString('assets/licenses/$packageName.txt');
      LicenseRegistry.addLicense(
        () => Stream<LicenseEntry>.value(
          LicenseEntryWithLineBreaks(<String>[packageName], licenseText),
        ),
      );
    }
  }

  /// Prepare application data and state to be ready of use upon starting up
  /// the application. [AppModel] is initialised in the main function before
  /// [runApp] is executed.
  Future<void> initialise() async {
    try {
      debugPrint('[Hibiki] init: PackageInfo + DeviceInfo');

      /// Prepare entities that may be repeatedly used at runtime.
      _packageInfo = await PackageInfo.fromPlatform();
      _androidDeviceInfo = await DeviceInfoPlugin().androidInfo;

      debugPrint('[Hibiki] init: directories (early, needed for DB)');
      _temporaryDirectory = await getTemporaryDirectory();
      _appDirectory = await getApplicationDocumentsDirectory();
      _databaseDirectory = await getApplicationSupportDirectory();

      debugPrint('[Hibiki] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);

      /// Load all preferences into memory for synchronous reads.
      _prefCache.addAll(await _database.getAllPrefs());

      /// Load dictionary metadata cache.
      final dictRows = await _database.getAllDictionaryMetadata();
      _dictionariesCache = dictRows.map(_rowToDictionary).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

      /// Load media items cache.
      final miRows = await _database.getAllMediaItems();
      _mediaItemsCache = miRows.map(_rowToMediaItem).toList();

      /// Load search history cache (grouped by historyKey).
      _searchHistoryCache.clear();
      final shRows = await _database.getAllSearchHistoryItems();
      for (final row in shRows) {
        _searchHistoryCache
            .putIfAbsent(row.historyKey, () => [])
            .add(row.searchTerm);
      }

      /// Restore dictionary history from DB into memory.
      _dictionaryHistoryResults.clear();
      final histRows = await _database.getAllDictionaryHistory();
      for (final row in histRows) {
        try {
          _dictionaryHistoryResults
              .add(DictionarySearchResult.fromJson(row.resultJson));
        } catch (e) {
          debugPrint('[Hibiki] skipping corrupted dictionary history: $e');
        }
      }

      /// Permission requests are deferred to the point of use (file import,
      /// Anki export) so they do not block startup.

      debugPrint('[Hibiki] init: directories');
      _browserDirectory = Directory(path.join(appDirectory.path, 'browser'));
      _thumbnailsDirectory =
          Directory(path.join(appDirectory.path, 'thumbnails'));

      _dictionaryResourceDirectory =
          Directory(path.join(appDirectory.path, 'dictionaryResources'));

      _dictionaryImportWorkingDirectory = Directory(
          path.join(appDirectory.path, 'dictionaryImportWorkingDirectory'));
      _exportDirectory = await prepareFallbackHibikiDirectory();
      _alternateExportDirectory = _exportDirectory;
      _webArchiveDirectory =
          Directory(path.join(appDirectory.path, 'webArchive'));

      thumbnailsDirectory.createSync();
      dictionaryImportWorkingDirectory.createSync();
      dictionaryResourceDirectory.createSync();
      _rebuildDictPathsCache();

      await _bindLocalAudioDbForNativeHandler(clearMissingPath: true);

      debugPrint('[Hibiki] init: licenses');

      /// Inject open source licenses for non-Flutter dependencies that are
      /// included as assets.
      await injectAssetLicenses();

      debugPrint('[Hibiki] init: populate maps');

      /// Populate entities with key-value maps for constant time performance.
      /// This is not the initialisation step, which occurs below.
      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();
      populateQuickActions();

      debugPrint('[Hibiki] init: targetLanguage');

      /// Get the current target language and prepare its resources for use. This
      /// will not re-run if the target language is already initialised, as
      /// a [Language] should always have a singleton instance and will not
      /// re-prepare its resources if already initialised. See
      /// [Language.initialise] for more details.
      await targetLanguage.initialise();

      debugPrint('[Hibiki] init: enhancements');

      /// Ready all enhancements sources for use.
      for (Field field in globalFields) {
        for (Enhancement enhancement in enhancements[field]!.values) {
          await enhancement.initialise();
        }
      }

      debugPrint('[Hibiki] init: quick actions');

      /// Ready all quick actions for use.
      for (QuickAction action in quickActions.values) {
        await action.initialise();
      }

      debugPrint('[Hibiki] init: media sources');
      MediaSource.setDatabase(_database);

      /// Ready all media sources for use.
      for (MediaType type in mediaTypes.values) {
        for (MediaSource source in mediaSources[type]!.values) {
          await source.initialise();
        }
      }

      debugPrint('[Hibiki] init: ttu → EpubBooks migration');
      try {
        final migServer =
            await TtuMigrationServer.start(targetLanguage);
        final int migCount = await TtuMigration.migrateIfNeeded(
          _database,
          migServer.boundPort!,
        );
        if (migCount > 0) {
          debugPrint('[Hibiki] ttu migration: $migCount books migrated');
        }
      } catch (e) {
        debugPrint('[Hibiki] ttu migration failed (non-fatal): $e');
      }

      debugPrint('[Hibiki] init: search preload');

      /// Preloads the search database in memory.
      searchDictionary(
        searchTerm: targetLanguage.helloWorld,
        searchWithWildcards: false,
        useCache: false,
      ).then((_) {
        /// Preloads for wildcard searches.
        searchDictionary(
          searchTerm: '${targetLanguage.helloWorld.substring(0, 1)}?',
          searchWithWildcards: true,
          useCache: false,
        ).then((_) {
          searchDictionary(
            searchTerm: '${targetLanguage.helloWorld.substring(0, 1)}*',
            searchWithWildcards: true,
            useCache: false,
          );
        });
      });

      debugPrint('[Hibiki] init: DONE');
      _isInitialised = true;
      _persistSplashColor();
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Hibiki] init FAILED: $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise', e, stack);
      _initError = '$e';
      notifyListeners();
    }
  }

  Future<void> initialiseForDictionaryPopup() async {
    if (_isInitialised) {
      debugPrint('[Hibiki-popup] init: already initialised, skipping');
      await _bindLocalAudioDbForNativeHandler();
      return;
    }
    try {
      debugPrint('[Hibiki-popup] init: PackageInfo + DeviceInfo');
      _packageInfo = await PackageInfo.fromPlatform();
      _androidDeviceInfo = await DeviceInfoPlugin().androidInfo;

      debugPrint('[Hibiki-popup] init: directories');
      _temporaryDirectory = await getTemporaryDirectory();
      _appDirectory = await getApplicationDocumentsDirectory();
      _databaseDirectory = await getApplicationSupportDirectory();

      debugPrint('[Hibiki-popup] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);

      _prefCache.addAll(await _database.getAllPrefs());

      final dictRows = await _database.getAllDictionaryMetadata();
      _dictionariesCache = dictRows.map(_rowToDictionary).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

      _searchHistoryCache.clear();
      final shRows = await _database.getAllSearchHistoryItems();
      for (final row in shRows) {
        _searchHistoryCache
            .putIfAbsent(row.historyKey, () => [])
            .add(row.searchTerm);
      }

      _dictionaryHistoryResults.clear();
      final histRows = await _database.getAllDictionaryHistory();
      for (final row in histRows) {
        try {
          _dictionaryHistoryResults
              .add(DictionarySearchResult.fromJson(row.resultJson));
        } catch (e) {
          debugPrint(
              '[Hibiki-popup] skipping corrupted dictionary history: $e');
        }
      }

      _browserDirectory = Directory(path.join(appDirectory.path, 'browser'));
      _thumbnailsDirectory =
          Directory(path.join(appDirectory.path, 'thumbnails'));
      _dictionaryResourceDirectory =
          Directory(path.join(appDirectory.path, 'dictionaryResources'));
      _dictionaryImportWorkingDirectory = Directory(
          path.join(appDirectory.path, 'dictionaryImportWorkingDirectory'));
      _exportDirectory = await prepareFallbackHibikiDirectory();
      _alternateExportDirectory = _exportDirectory;
      _webArchiveDirectory =
          Directory(path.join(appDirectory.path, 'webArchive'));

      thumbnailsDirectory.createSync();
      dictionaryImportWorkingDirectory.createSync();
      dictionaryResourceDirectory.createSync();
      _rebuildDictPathsCache();

      await _bindLocalAudioDbForNativeHandler();

      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();

      await targetLanguage.initialise();

      for (Field field in globalFields) {
        for (Enhancement enhancement in enhancements[field]!.values) {
          await enhancement.initialise();
        }
      }

      debugPrint('[Hibiki-popup] init: DONE');
      _isInitialised = true;
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Hibiki-popup] init FAILED: $e\n$stack');
      _initError = '$e';
      notifyListeners();
    }
  }

  // ── sync pref helpers (backed by in-memory cache) ───────────────────

  dynamic _getPref(String key, {dynamic defaultValue}) {
    final raw = _prefCache[key];
    if (raw == null) return defaultValue;
    if (defaultValue is int) return int.tryParse(raw) ?? defaultValue;
    if (defaultValue is double) return double.tryParse(raw) ?? defaultValue;
    if (defaultValue is bool) return raw == 'true';
    if (defaultValue is List) {
      try {
        return List<String>.from(jsonDecode(raw));
      } catch (_) {
        return defaultValue;
      }
    }
    return raw;
  }

  Future<void> _setPref(String key, dynamic value) async {
    String strVal;
    if (value is List) {
      strVal = jsonEncode(value);
    } else {
      strVal = value.toString();
    }
    _prefCache[key] = strVal;
    await _database.setPref(key, strVal);
  }

  Future<void> _bindLocalAudioDbForNativeHandler({
    bool clearMissingPath = false,
  }) async {
    if (!localAudioEnabled || localAudioDbPath.isEmpty) {
      return;
    }

    final String storedPath = localAudioDbPath;
    final String internalPath =
        path.join(_databaseDirectory.path, 'local_audio.db');
    final bool storedExists = await File(storedPath).exists();
    final bool internalExists = await File(internalPath).exists();

    if (storedExists) {
      await TtsChannel.instance.setLocalAudioDb(storedPath);
    } else if (internalExists) {
      if (storedPath != internalPath) {
        await _setPref('local_audio_db_path', internalPath);
      }
      await TtsChannel.instance.setLocalAudioDb(internalPath);
    } else if (clearMissingPath) {
      await _setPref('local_audio_db_path', '');
    }
  }

  // ── model / Drift row conversion helpers ──────────────────────────

  static Dictionary _rowToDictionary(DictionaryMetaRow r) {
    return Dictionary(
      name: r.name,
      formatKey: r.formatKey,
      order: r.order,
      type: DictionaryType.values.firstWhere(
        (e) => e.name == r.type,
        orElse: () => DictionaryType.term,
      ),
      metadata: Map<String, String>.from(jsonDecode(r.metadataJson)),
      hiddenLanguages: List<String>.from(jsonDecode(r.hiddenLanguagesJson)),
      collapsedLanguages:
          List<String>.from(jsonDecode(r.collapsedLanguagesJson)),
    );
  }

  static DictionaryMetadataCompanion _dictionaryToCompanion(Dictionary d) {
    return DictionaryMetadataCompanion(
      name: Value(d.name),
      formatKey: Value(d.formatKey),
      order: Value(d.order),
      type: Value(d.type.name),
      metadataJson: Value(jsonEncode(d.metadata)),
      hiddenLanguagesJson: Value(jsonEncode(d.hiddenLanguages)),
      collapsedLanguagesJson: Value(jsonEncode(d.collapsedLanguages)),
    );
  }

  static MediaItem _rowToMediaItem(MediaItemRow r) {
    return MediaItem(
      id: r.id,
      mediaIdentifier: r.mediaIdentifier,
      title: r.title,
      mediaTypeIdentifier: r.mediaTypeIdentifier,
      mediaSourceIdentifier: r.mediaSourceIdentifier,
      position: r.position,
      duration: r.duration,
      canDelete: r.canDelete,
      canEdit: r.canEdit,
      base64Image: r.base64Image,
      imageUrl: r.imageUrl,
      audioUrl: r.audioUrl,
      author: r.author,
      authorIdentifier: r.authorIdentifier,
      extraUrl: r.extraUrl,
      extra: r.extra,
      sourceMetadata: r.sourceMetadata,
    );
  }

  static MediaItemsCompanion _mediaItemToCompanion(MediaItem item) {
    return MediaItemsCompanion(
      uniqueKey: Value(item.uniqueKey),
      mediaIdentifier: Value(item.mediaIdentifier),
      title: Value(item.title),
      mediaTypeIdentifier: Value(item.mediaTypeIdentifier),
      mediaSourceIdentifier: Value(item.mediaSourceIdentifier),
      position: Value(item.position),
      duration: Value(item.duration),
      canDelete: Value(item.canDelete),
      canEdit: Value(item.canEdit),
      base64Image: Value(item.base64Image),
      imageUrl: Value(item.imageUrl),
      audioUrl: Value(item.audioUrl),
      author: Value(item.author),
      authorIdentifier: Value(item.authorIdentifier),
      extraUrl: Value(item.extraUrl),
      extra: Value(item.extra),
      sourceMetadata: Value(item.sourceMetadata),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
  }

  void _persistDictionary(Dictionary dictionary) async {
    final idx = _dictionariesCache.indexWhere((d) => d.name == dictionary.name);
    if (idx >= 0) {
      _dictionariesCache[idx] = dictionary;
    } else {
      _dictionariesCache.add(dictionary);
      _dictionariesCache.sort((a, b) => a.order.compareTo(b.order));
    }
    _rebuildDictPathsCache();
    await _database.upsertDictionaryMeta(_dictionaryToCompanion(dictionary));
  }

  // ── App-wide theme (6 presets matching ttu reader themes) ──────────────

  static const Map<String, ({Color seed, Brightness brightness})> themePresets =
      {
    'light-theme': (seed: Color(0xFF1F4959), brightness: Brightness.light),
    'ecru-theme': (seed: Color(0xFF8B7355), brightness: Brightness.light),
    'water-theme': (seed: Color(0xFF4A7C8F), brightness: Brightness.light),
    'gray-theme': (seed: Color(0xFF5C6B73), brightness: Brightness.dark),
    'dark-theme': (seed: Color(0xFF1F4959), brightness: Brightness.dark),
    'black-theme': (seed: Color(0xFF263238), brightness: Brightness.dark),
  };

  static const _themeLabelKeys = {
    'light-theme': 'theme_light',
    'ecru-theme': 'theme_ecru',
    'water-theme': 'theme_water',
    'gray-theme': 'theme_gray',
    'dark-theme': 'theme_dark',
    'black-theme': 'theme_black',
  };

  static String themeLabel(String key) {
    switch (_themeLabelKeys[key]) {
      case 'theme_light':
        return t.theme_light;
      case 'theme_ecru':
        return t.theme_ecru;
      case 'theme_water':
        return t.theme_water;
      case 'theme_gray':
        return t.theme_gray;
      case 'theme_dark':
        return t.theme_dark;
      case 'theme_black':
        return t.theme_black;
      default:
        return key;
    }
  }

  String get appThemeKey {
    final String key = _getPref('app_theme_key', defaultValue: '');
    if (key.isEmpty ||
        (!themePresets.containsKey(key) && key != 'custom-theme')) {
      final bool sysDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      return sysDark ? 'dark-theme' : 'light-theme';
    }
    return key;
  }

  Future<void> setAppThemeKey(String key) async {
    await _setPref('app_theme_key', key);
    notifyListeners();
    _persistSplashColor();
  }

  Color get customThemeSeed {
    final int v = _getPref('custom_theme_seed', defaultValue: 0xFF1F4959);
    return Color(v);
  }

  Future<void> setCustomThemeSeed(Color color) async {
    await _setPref('custom_theme_seed', color.toARGB32());
  }

  bool get customThemeDark {
    return _getPref('custom_theme_dark', defaultValue: false);
  }

  Future<void> setCustomThemeDark(bool dark) async {
    await _setPref('custom_theme_dark', dark);
  }

  Color? get customThemeFontColor {
    final int v = _getPref('custom_theme_font_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeFontColor(Color? color) async {
    await _setPref('custom_theme_font_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeBackgroundColor {
    final int v = _getPref('custom_theme_bg_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeBackgroundColor(Color? color) async {
    await _setPref('custom_theme_bg_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeSelectionColor {
    final int v = _getPref('custom_theme_selection_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeSelectionColor(Color? color) async {
    await _setPref('custom_theme_selection_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemePrimaryColor {
    final int v = _getPref('custom_theme_primary_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemePrimaryColor(Color? color) async {
    await _setPref('custom_theme_primary_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeSecondaryColor {
    final int v = _getPref('custom_theme_secondary_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeSecondaryColor(Color? color) async {
    await _setPref('custom_theme_secondary_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeTertiaryColor {
    final int v = _getPref('custom_theme_tertiary_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeTertiaryColor(Color? color) async {
    await _setPref('custom_theme_tertiary_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeContainerColor {
    final int v = _getPref('custom_theme_container_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeContainerColor(Color? color) async {
    await _setPref('custom_theme_container_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeSasayakiColor {
    final int v = _getPref('custom_theme_sasayaki_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeSasayakiColor(Color? color) async {
    await _setPref('custom_theme_sasayaki_color', color?.toARGB32() ?? 0);
  }

  Color? get customThemeLinkColor {
    final int v = _getPref('custom_theme_link_color', defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> setCustomThemeLinkColor(Color? color) async {
    await _setPref('custom_theme_link_color', color?.toARGB32() ?? 0);
  }

  Future<void> applyCustomTheme({
    required Color seed,
    required bool dark,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sasayakiColor,
    Color? linkColor,
  }) async {
    await setCustomThemeSeed(seed);
    await setCustomThemeDark(dark);
    await setCustomThemeFontColor(fontColor);
    await setCustomThemeBackgroundColor(backgroundColor);
    await setCustomThemeSelectionColor(selectionColor);
    await setCustomThemePrimaryColor(primaryColor);
    await setCustomThemeSecondaryColor(secondaryColor);
    await setCustomThemeTertiaryColor(tertiaryColor);
    await setCustomThemeContainerColor(containerColor);
    await setCustomThemeSasayakiColor(sasayakiColor);
    await setCustomThemeLinkColor(linkColor);
    await _setPref('app_theme_key', 'custom-theme');
    notifyListeners();
    _persistSplashColor();
  }

  bool get isDarkMode {
    if (appThemeKey == 'custom-theme') return customThemeDark;
    return themePresets[appThemeKey]?.brightness == Brightness.dark;
  }

  static const _splashChannel = HibikiChannels.splash;

  void _persistSplashColor() {
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    final bool useCustomRoles = appThemeKey == 'custom-theme';
    final surface = buildHibikiColorScheme(
      seedColor: _seedColor,
      brightness: brightness,
      primary: useCustomRoles ? customThemePrimaryColor : null,
      secondary: useCustomRoles ? customThemeSecondaryColor : null,
      tertiary: useCustomRoles ? customThemeTertiaryColor : null,
      primaryContainer: useCustomRoles ? customThemeContainerColor : null,
    ).surface;
    _splashChannel.invokeMethod('setSplashColor', {
      'color': surface.toARGB32(),
      'isDark': isDarkMode,
    }).catchError((_) {});
  }

  /// Get the target language from persisted preferences.
  Language get targetLanguage {
    String defaultLocaleTag = languages.values.first.locale.toLanguageTag();
    String localeTag =
        _getPref('target_language', defaultValue: defaultLocaleTag);

    return languages[localeTag]!;
  }

  /// Get the last selected deck from persisted preferences.
  String get lastSelectedDeckName {
    String deckName = _getPref('last_selected_deck', defaultValue: 'Default');
    return deckName;
  }

  /// Get the target language from persisted preferences.
  DictionaryFormat get lastSelectedDictionaryFormat {
    String firstDictionaryFormatName = dictionaryFormats.values.first.uniqueKey;
    String lastDictionaryFormatName = _getPref(
      'last_selected_dictionary_format',
      defaultValue: firstDictionaryFormatName,
    );

    return dictionaryFormats[lastDictionaryFormatName]!;
  }

  /// Get the current app locale from persisted preferences.
  /// Defaults to system locale if supported, otherwise en-US.
  Locale get appLocale {
    String? saved = _getPref('app_locale');
    if (saved != null && saved.isNotEmpty && locales.containsKey(saved)) {
      return locales[saved]!;
    }

    // Match system locale to available locales.
    final systemLocale = PlatformDispatcher.instance.locale;
    final systemTag = systemLocale.toLanguageTag();
    if (locales.containsKey(systemTag)) {
      return locales[systemTag]!;
    }
    // Try language-only match (e.g. "zh" matches "zh-CN").
    for (final entry in locales.entries) {
      if (entry.value.languageCode == systemLocale.languageCode) {
        return entry.value;
      }
    }

    return locales.values.first;
  }

  /// Get the last selected model from persisted preferences.
  String? get lastSelectedModel {
    String? modelName = _getPref('last_selected_model');
    return modelName;
  }

  /// Persist a new target language in preferences.
  Future<void> setTargetLanguage(Language language) async {
    String localeTag = language.locale.toLanguageTag();
    await _setPref('target_language', localeTag);

    language.initialise();

    notifyListeners();
  }

  /// Persist a new app locale in preferences. Restarts the app so every
  /// widget re-resolves [t] with the new locale (Method A lookups don't
  /// automatically rebuild on locale change).
  Future<void> setAppLocale(String localeTag) async {
    await _setPref('app_locale', localeTag);
    LocaleSettings.setLocaleRaw(localeTag);
    Restart.restartApp();
  }

  /// Persist a new last selected dictionary format. This is called when the
  /// user changes the import format in the dictionary menu.
  Future<void> setLastSelectedDictionaryFormat(
      DictionaryFormat dictionaryFormat) async {
    String lastDictionaryFormatName = dictionaryFormat.uniqueKey;
    await _setPref('last_selected_dictionary_format', lastDictionaryFormatName);
  }

  /// Persist a new last selected model name. This is called when the user
  /// changes the selected model to map in the profiles menu.
  Future<void> setLastSelectedModelName(String modelName) async {
    await _setPref('last_selected_model', modelName);
    notifyListeners();
  }

  /// Persist a new last selected deck name. This is called when the user
  /// changes the selected deck to map in the creator.
  Future<void> setLastSelectedDeck(String deckName) async {
    await _setPref('last_selected_deck', deckName);
  }

  /// Get the current home tab index. The order of the tab indexes are based on
  /// the ordering in [mediaTypes].
  int get currentHomeTabIndex =>
      _getPref('current_home_tab_index', defaultValue: 0);

  /// Persist the new tab after switching home tabs.
  Future<void> setCurrentHomeTabIndex(int index) async {
    await _setPref('current_home_tab_index', index);
  }

  /// Show the dictionary menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showDictionaryMenu() async {
    await showAppDialog(
      barrierDismissible: true,
      context: navigatorKey.currentContext!,
      builder: (context) => const DictionaryDialogPage(),
    );

    notifyListeners();
    dictionaryMenuNotifier.notifyListeners();
  }

  /// Show the language menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showLanguageMenu() async {
    await showAppDialog(
      barrierDismissible: true,
      context: navigatorKey.currentContext!,
      builder: (context) => LanguageDialogPage(
        isFirstTimeSetup: isFirstTimeSetup,
      ),
    );
  }

  /// Show the language menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showProfilesMenu() async {
    List<String> models = await getModelList();
    String initialModel = lastSelectedModel ?? models.first;

    await Navigator.push(
      navigatorKey.currentContext!,
      MaterialPageRoute(
        builder: (context) => ProfilesDialogPage(
          models: models,
          initialModel: initialModel,
        ),
      ),
    );

    notifyListeners();
  }

  DictionaryFormat _detectDictionaryFormat(File file) {
    final ext = path.extension(file.path).toLowerCase();
    if (ext == '.dsl') {
      return dictionaryFormats['abbyy_lingvo']!;
    }
    if (ext == '.mdx') {
      return dictionaryFormats['mdict']!;
    }
    if (ext == '.zip') {
      final fileNames = _readZipFileNames(file);

      if (fileNames.isEmpty) {
        // zip64 or unreadable central directory — default to yomichan
        return dictionaryFormats['yomichan']!;
      }

      if (fileNames
          .any((f) => f == 'index.json' || f.endsWith('/index.json'))) {
        return dictionaryFormats['yomichan']!;
      }

      final hasMdx =
          fileNames.any((f) => f.endsWith('.mdx') || f.endsWith('.mdd'));
      if (hasMdx) {
        return dictionaryFormats['mdict']!;
      }

      final hasJson = fileNames.any((f) => f.endsWith('.json'));
      if (hasJson) {
        return dictionaryFormats['migaku']!;
      }

      // fallback: try yomichan
      return dictionaryFormats['yomichan']!;
    }
    throw Exception(t.import_unsupported_file_format(ext: ext));
  }

  List<String> _readZipFileNames(File file) {
    try {
      final input = InputFileStream(file.path);
      final dir = ZipDirectory.read(input);
      final names = dir.fileHeaders
          .map((h) => h.filename)
          .where((n) => n.isNotEmpty)
          .map((n) => n.toLowerCase())
          .toList();
      input.closeSync();
      return names;
    } catch (_) {
      return [];
    }
  }

  DictionaryFormat _detectDictionaryFormatFromDirectory(Directory dir) {
    final indexFile = File(path.join(dir.path, 'index.json'));
    if (indexFile.existsSync()) {
      return dictionaryFormats['yomichan']!;
    }
    final hasJson = dir
        .listSync()
        .whereType<File>()
        .any((f) => f.path.toLowerCase().endsWith('.json'));
    if (hasJson) {
      return dictionaryFormats['migaku']!;
    }
    throw Exception(t.dictionary_unrecognized_format);
  }

  /// Import a dictionary from a folder.
  ///
  /// Supports two layouts:
  /// 1. Folder containing zip/dsl/mdx + optional CSS + optional font dirs
  /// 2. Folder that IS the extracted dictionary (has index.json / *.json)
  Future<void> importDictionaryFromDirectory({
    required Directory directory,
    required ValueNotifier<String> progressNotifier,
    required ValueNotifier<int?> countNotifier,
    required ValueNotifier<int?> totalNotifier,
    required Function() onImportSuccess,
  }) async {
    final entities = directory.listSync();
    final zipFiles = entities.whereType<File>().where((f) {
      final ext = path.extension(f.path).toLowerCase();
      return ext == '.zip' || ext == '.dsl' || ext == '.mdx';
    }).toList();

    if (zipFiles.isNotEmpty) {
      final cssFiles = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.css'))
          .toList();
      final fontDirs = <Directory>[];
      for (final d in entities.whereType<Directory>()) {
        try {
          final hasFont = d.listSync().whereType<File>().any((f) {
            final ext = path.extension(f.path).toLowerCase();
            return ext == '.otf' ||
                ext == '.ttf' ||
                ext == '.woff' ||
                ext == '.woff2';
          });
          if (hasFont) fontDirs.add(d);
        } catch (e) {
          debugPrint('[Hibiki] error scanning font dir ${d.path}: $e');
        }
      }

      totalNotifier.value = zipFiles.length;
      for (int i = 0; i < zipFiles.length; i++) {
        countNotifier.value = i + 1;
        try {
          await importDictionary(
            file: zipFiles[i],
            progressNotifier: progressNotifier,
            cssFiles: cssFiles,
            fontDirs: fontDirs,
            onImportSuccess: onImportSuccess,
          );
        } catch (e) {
          Fluttertoast.showToast(
            msg: '${path.basenameWithoutExtension(zipFiles[i].path)}: $e',
            toastLength: Toast.LENGTH_LONG,
          );
        }
      }
      return;
    }

    clearDictionaryResultsCache();

    try {
      progressNotifier.value = t.import_extract;

      final tempZipPath =
          path.join(dictionaryResourceDirectory.path, 'import_temp_dir.zip');
      final tempZip = File(tempZipPath);

      final archive = Archive();
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File) {
          final relativePath = path.relative(entity.path, from: directory.path);
          archive.addFile(ArchiveFile(
              relativePath, entity.lengthSync(), entity.readAsBytesSync()));
        }
      }
      tempZip.writeAsBytesSync(ZipEncoder().encode(archive)!);

      try {
        final tempOutputDir = Directory(
            path.join(dictionaryResourceDirectory.path, 'import_temp'));
        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }
        tempOutputDir.createSync(recursive: true);

        final result = await importDictionaryViaHoshidicts(
          zipPath: tempZipPath,
          outputDir: tempOutputDir.path,
        );

        if (!result.success) {
          throw Exception(
              result.error.isNotEmpty ? result.error : t.import_failed);
        }

        final name = result.title.trim();
        if (name.isEmpty) {
          throw Exception('Dictionary title is empty');
        }

        progressNotifier.value = t.import_name(name: name);

        if (_dictionariesCache.any((d) => d.name == name)) {
          throw Exception(t.import_duplicate(name: name));
        }

        final currentDictionaries = dictionaries;
        int order = currentDictionaries.isEmpty
            ? 1
            : currentDictionaries
                    .map((d) => d.order)
                    .reduce((a, b) => a > b ? a : b) +
                1;

        final innerDataDir = Directory(path.join(tempOutputDir.path, name));
        final finalResourceDirectory =
            Directory(path.join(dictionaryResourceDirectory.path, name));
        if (finalResourceDirectory.existsSync()) {
          finalResourceDirectory.deleteSync(recursive: true);
        }

        if (innerDataDir.existsSync()) {
          innerDataDir.renameSync(finalResourceDirectory.path);
        } else {
          tempOutputDir.renameSync(finalResourceDirectory.path);
        }

        if (tempOutputDir.existsSync()) {
          tempOutputDir.deleteSync(recursive: true);
        }

        final detectedType = _parseDictionaryType(result.detectedType);

        Dictionary dictionary = Dictionary(
          order: order,
          name: name,
          formatKey: 'yomichan',
          type: detectedType,
        );

        _persistDictionary(dictionary);

        progressNotifier.value = t.import_complete;
        onImportSuccess();
      } finally {
        if (tempZip.existsSync()) tempZip.deleteSync();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryImport(dir)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3), () {});
      progressNotifier.value = t.import_failed;
      await Future.delayed(const Duration(seconds: 1), () {});
    }
  }

  void _copyDirectory(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync()) {
      final newPath = path.join(destination.path, path.basename(entity.path));
      if (entity is File) {
        entity.copySync(newPath);
      } else if (entity is Directory) {
        _copyDirectory(entity, Directory(newPath));
      }
    }
  }

  static DictionaryType _parseDictionaryType(String type) {
    switch (type) {
      case 'frequency':
        return DictionaryType.frequency;
      case 'pitch':
        return DictionaryType.pitch;
      case 'kanji':
        return DictionaryType.kanji;
      default:
        return DictionaryType.term;
    }
  }

  Future<void> importDictionary({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    List<File> cssFiles = const [],
    List<Directory> fontDirs = const [],
  }) async {
    clearDictionaryResultsCache();

    try {
      progressNotifier.value = t.import_extract;
      await Future<void>.delayed(Duration.zero);

      final tempOutputDir =
          Directory(path.join(dictionaryResourceDirectory.path, 'import_temp'));
      if (tempOutputDir.existsSync()) {
        tempOutputDir.deleteSync(recursive: true);
      }
      tempOutputDir.createSync(recursive: true);

      final result = await importDictionaryViaHoshidicts(
        zipPath: file.path,
        outputDir: tempOutputDir.path,
      );

      if (!result.success) {
        throw Exception(
            result.error.isNotEmpty ? result.error : t.import_failed);
      }

      final name = result.title.trim();
      if (name.isEmpty) {
        throw Exception('Dictionary title is empty');
      }

      progressNotifier.value = t.import_name(name: name);

      if (_dictionariesCache.any((d) => d.name == name)) {
        throw Exception(t.import_duplicate(name: name));
      }

      final currentDictionaries = dictionaries;
      int order = currentDictionaries.isEmpty
          ? 1
          : currentDictionaries
                  .map((d) => d.order)
                  .reduce((a, b) => a > b ? a : b) +
              1;

      // hoshidicts writes data into outputDir/title/, so the actual data
      // directory is the inner subdirectory named after the title.
      final innerDataDir = Directory(path.join(tempOutputDir.path, name));
      final finalResourceDirectory =
          Directory(path.join(dictionaryResourceDirectory.path, name));
      if (finalResourceDirectory.existsSync()) {
        finalResourceDirectory.deleteSync(recursive: true);
      }

      if (innerDataDir.existsSync()) {
        innerDataDir.renameSync(finalResourceDirectory.path);
      } else {
        tempOutputDir.renameSync(finalResourceDirectory.path);
      }

      // Clean up the now-empty temp dir if it still exists
      if (tempOutputDir.existsSync()) {
        tempOutputDir.deleteSync(recursive: true);
      }

      for (final css in cssFiles) {
        if (css.existsSync()) {
          css.copySync(
              path.join(finalResourceDirectory.path, path.basename(css.path)));
        }
      }
      for (final fontDir in fontDirs) {
        if (fontDir.existsSync()) {
          _copyDirectory(
              fontDir,
              Directory(path.join(
                  finalResourceDirectory.path, path.basename(fontDir.path))));
        }
      }

      final detectedType = _parseDictionaryType(result.detectedType);

      Dictionary dictionary = Dictionary(
        order: order,
        name: name,
        formatKey: 'yomichan',
        type: detectedType,
      );

      _persistDictionary(dictionary);

      progressNotifier.value = t.import_complete;
      onImportSuccess();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryImport(file)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3), () {});
      progressNotifier.value = t.import_failed;
      await Future.delayed(const Duration(seconds: 1), () {});
    }
  }

  /// Toggle a dictionary's between collapsed and expanded state. This will
  /// affect how a dictionary's search results are shown by default.
  void toggleDictionaryCollapsed(Dictionary dictionary) {
    if (dictionary.isCollapsed(targetLanguage)) {
      dictionary.collapsedLanguages = [...dictionary.collapsedLanguages]
        ..remove(targetLanguage.languageCode);
    } else {
      dictionary.collapsedLanguages = [
        ...dictionary.collapsedLanguages,
        targetLanguage.languageCode
      ];
    }
    _persistDictionary(dictionary);
  }

  /// Toggle a dictionary's between hidden and shown state. This will
  /// affect how a dictionary's search results are shown by default.
  void toggleDictionaryHidden(Dictionary dictionary) {
    if (dictionary.isHidden(targetLanguage)) {
      dictionary.hiddenLanguages = [...dictionary.hiddenLanguages]
        ..remove(targetLanguage.languageCode);
    } else {
      dictionary.hiddenLanguages = [
        ...dictionary.hiddenLanguages,
        targetLanguage.languageCode
      ];
    }
    _persistDictionary(dictionary);
  }

  Future<void> deleteDictionaries() async {
    clearDictionaryResultsCache();

    await clearDictionaryHistory();
    _dictionariesCache.clear();
    await _database.clearAllDictionaryMeta();

    if (dictionaryResourceDirectory.existsSync()) {
      dictionaryResourceDirectory.deleteSync(recursive: true);
      dictionaryResourceDirectory.createSync(recursive: true);
    }

    dictionarySearchAgainNotifier.notifyListeners();
  }

  Future<void> deleteDictionary(Dictionary dictionary) async {
    clearDictionaryResultsCache();

    await clearDictionaryHistory();

    _dictionariesCache.removeWhere((d) => d.name == dictionary.name);
    _rebuildDictPathsCache();
    await _database.deleteDictionaryMeta(dictionary.name);

    final directory =
        Directory(path.join(dictionaryResourceDirectory.path, dictionary.name));

    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }

    dictionarySearchAgainNotifier.notifyListeners();
  }

  /// Used for caching search results. Cleared when a dictionary is added or
  /// deleted.
  final Map<String, DictionarySearchResult> _dictionarySearchCache = {};

  /// Used when a dictionary is added or removed as those results may now be
  /// wrong.
  void clearDictionaryResultsCache() {
    _dictionarySearchCache.clear();
  }

  /// Gets the raw unprocessed entries straight from a dictionary database
  /// given a search term. This will be processed later for user viewing.
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
  }) async {
    if (_dictionarySearchCache['$searchTerm/$overrideMaximumTerms'] != null &&
        useCache) {
      return _dictionarySearchCache['$searchTerm/$overrideMaximumTerms']!;
    }

    searchTerm = searchTerm.replaceAll('\n', ' ');
    searchTerm = _removeEmoji.clean(searchTerm, ' ', false);

    /// Strip lone surrogates that may crash the search.
    RegExp loneSurrogate = RegExp(
      '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
    );
    searchTerm = searchTerm.replaceAll(loneSurrogate, ' ');

    if (searchTerm.trim().isEmpty) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    if (!HoshiDicts.isInitialized) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    final result = targetLanguage.prepareSearchResultsDirect(
      searchTerm: searchTerm,
      maximumDictionarySearchResults: maximumDictionarySearchResults,
      maximumDictionaryTermsInResult: overrideMaximumTerms ?? maximumTerms,
    );

    if (result != null && result.entries.isNotEmpty) {
      _dictionarySearchCache['$searchTerm/$overrideMaximumTerms'] = result;
      return result;
    } else {
      return DictionarySearchResult(searchTerm: searchTerm);
    }
  }

  /// Override flag for when [isMediaOpen] is true but the status bar should
  /// be kept open instead of closed.
  bool get shouldHideStatusBarWhenInMedia => _shouldHideStatusBarWhenInMedia;
  bool _shouldHideStatusBarWhenInMedia = true;

  /// Override the flag for automatically disabling the status bar. Necessary
  /// for some very specific edge cases and byproduct of letting global state
  /// run its course. This is a band-aid solution.
  Future<void> temporarilyDisableStatusBarHiding(
      {required Future Function() action}) async {
    _shouldHideStatusBarWhenInMedia = false;
    await action.call();
    _shouldHideStatusBarWhenInMedia = true;
  }

  /// Requests for full external storage permissions. Required to handle video
  /// files and their subtitle files in the same directory.
  Future<void> requestExternalStoragePermissions() async {
    if (isFirstTimeSetup) {
      Fluttertoast.showToast(
        msg: t.storage_permissions,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    }

    final cameraGranted = await Permission.camera.isGranted;
    if (!cameraGranted) {
      await Permission.camera.request();
    }

    final storageGranted = await Permission.storage.isGranted;
    if (!storageGranted) {
      await Permission.storage.request();
    }

    if (_androidDeviceInfo.version.sdkInt >= 30) {
      final manageStorageGranted =
          await Permission.manageExternalStorage.isGranted;
      if (!manageStorageGranted) {
        await Permission.manageExternalStorage.request();
      }
    }
  }

  /// Used to communicate back and forth with Dart and native code.
  static const MethodChannel methodChannel = HibikiChannels.anki;

  /// Shows the AnkiDroid API message. Called when an Anki-related API get call
  /// fails.
  Future<void> showAnkidroidApiMessage() async {
    await requestAnkidroidPermissions();

    await showAppDialog(
      barrierDismissible: true,
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(t.error_ankidroid_api),
        content: Text(
          t.error_ankidroid_api_content,
        ),
        actions: [
          TextButton(
            child: Text(t.dialog_launch_ankidroid),
            onPressed: () async {
              final navigator = Navigator.of(context);
              await LaunchApp.openApp(
                androidPackageName: 'com.ichi2.anki',
                openStore: true,
              );
              navigator.pop();
            },
          ),
          TextButton(
            child: Text(t.dialog_close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  /// Used to ask for AnkiDroid database permissions. Should be called at
  /// startup.
  Future<void> requestAnkidroidPermissions() async {
    await methodChannel.invokeMethod('requestAnkidroidPermissions');
  }

  /// Adds the default 'hibiki Kinomoto' model to the list of Anki card types.
  Future<void> addDefaultModelIfMissing() async {
    List<String> models = await getModelList();
    if (!models.contains('Lapis')) {
      methodChannel.invokeMethod('addDefaultModel');

      await showAppDialog(
        barrierDismissible: true,
        context: _navigatorKey.currentContext!,
        builder: (context) => AlertDialog(
          title: Text(t.info_standard_model),
          content: Text(
            t.info_standard_model_content,
          ),
          actions: [
            TextButton(
              child: Text(t.dialog_close),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      );
    }
  }

  /// Get the file to be written to for image export.
  File getImageExportFile({bool fallback = false}) {
    String imagePath = path.join(
        (fallback ? alternateExportDirectory : exportDirectory).path,
        'exportImage.jpg');
    return File(imagePath);
  }

  /// Get the placeholder file to compress for image export.
  File getImageCompressedFile({bool fallback = false}) {
    String imagePath = path.join(
        (fallback ? alternateExportDirectory : exportDirectory).path,
        'compressedImage.jpg');
    return File(imagePath);
  }

  /// Get the file to be written to for audio export.
  File getAudioExportFile({bool fallback = false, String ext = 'mp3'}) {
    String audioPath = path.join(
        (fallback ? alternateExportDirectory : exportDirectory).path,
        'exportAudio.$ext');
    return File(audioPath);
  }

  /// Get the file to be written to for image export.
  File getPreviewImageFile(Directory directory, int index) {
    String imagePath = path.join(directory.path, 'previewImage$index.jpg');
    return File(imagePath);
  }

  /// Get the file to be written to for audio export.
  File getAudioPreviewFile(Directory directory, {String ext = 'mp3'}) {
    String audioPath = path.join(directory.path, 'previewAudio.$ext');
    return File(audioPath);
  }

  /// Get the file to be written to for thumbnail export.
  File getThumbnailFile() {
    String imagePath = path.join(exportDirectory.path, 'thumbnail.jpg');
    return File(imagePath);
  }

  /// Get a list of decks from the Anki background service that can be used
  /// for export.
  Future<List<String>> getDecks() async {
    try {
      Map<dynamic, dynamic> result =
          await methodChannel.invokeMethod('getDecks');
      List<String> decks = result.values.toList().cast<String>();

      decks.sort((a, b) => a.compareTo(b));
      return decks;
    } catch (e) {
      await showAnkidroidApiMessage();
      rethrow;
    }
  }

  /// Get a list of models from the Anki background service that can be used
  /// for export.
  Future<List<String>> getModelList() async {
    try {
      Map<dynamic, dynamic> result =
          await methodChannel.invokeMethod('getModelList');
      List<String> models = result.values.toList().cast<String>();

      models.sort((a, b) => a.compareTo(b));
      return models;
    } catch (e) {
      await showAnkidroidApiMessage();
      rethrow;
    }
  }

  /// Get the target language from persisted preferences.
  DictionaryFormat getDictionaryFormat(Dictionary dictionary) {
    return dictionaryFormats[dictionary.formatKey]!;
  }

  /// Get a list of field names for a given [model] name in Anki. This function
  /// assumes that the model name can be found in [getDecks] and is valid.
  Future<List<String>> getFieldList(String model) async {
    try {
      List<String> fields = List<String>.from(
        await methodChannel.invokeMethod(
          'getFieldList',
          <String, dynamic>{
            'model': model,
          },
        ),
      );

      return fields;
    } catch (e) {
      showAnkidroidApiMessage();
      rethrow;
    }
  }

  /// Refresh all screens and have them respond to new variables.
  Future<void> refresh() async {
    notifyListeners();
  }

  /// Whether or not the media item should be killed upon exit.
  bool _shouldKillMediaOnPop = false;

  /// A helper function for launching a media source.
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
  }) async {
    if (killOnPop) {
      _shouldKillMediaOnPop = true;
    }

    mediaSource.clearCurrentSentence();
    mediaSource.clearExtraData();
    await initialiseAudioHandler();

    _currentMediaSource = mediaSource;
    if (item != null) {
      _currentMediaItem = item;
    }

    _overrideDictionaryColor = null;
    _overrideDictionaryTheme = null;

    if (ReaderHoshiSource.instance.keepScreenAwake) {
      await Wakelock.enable();
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (item != null && mediaSource.implementsHistory) {
      addMediaItem(item);
    }

    if (pushReplacement) {
      await Navigator.pushReplacement(
        _navigatorKey.currentContext!,
        MaterialPageRoute(
          builder: (context) => mediaSource.buildLaunchPage(
              item: item, initialBookmarkJump: initialBookmarkJump),
        ),
      );
    } else {
      await Navigator.push(
        _navigatorKey.currentContext!,
        MaterialPageRoute(
          builder: (context) => mediaSource.buildLaunchPage(
              item: item, initialBookmarkJump: initialBookmarkJump),
        ),
      );
    }
  }

  /// Ends a media session and ensures that values are reset.
  Future<void> closeMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    MediaItem? item,
  }) async {
    _audioHandler?.mediaItem.add(null);

    mediaSource.setShouldGenerateImage(value: true);
    mediaSource.setShouldGenerateAudio(value: true);
    mediaSource.clearCurrentSentence();
    mediaSource.clearExtraData();
    _currentMediaSource = null;
    _currentMediaItem = null;
    _overrideDictionaryColor = null;
    _overrideDictionaryTheme = null;
    blockCreatorInitialMedia = false;
    await Wakelock.disable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await mediaSource.onSourceExit(
      appModel: this,
      ref: ref,
    );

    await _audioHandler?.stop();

    mediaSource.mediaType.refreshTab();
    DictionaryMediaType.instance.refreshTab();

    if (_shouldKillMediaOnPop) {
      shutdown();
    }
  }

  /// A helper function for opening the creator from any page in the
  /// application for editing purposes.
  Future<void> openStash({
    required Function(String) onSelect,
    required Function(String) onSearch,
  }) async {
    await showAppDialog(
      context: _navigatorKey.currentContext!,
      builder: (context) => OpenStashDialogPage(
        onSelect: onSelect,
        onSearch: onSearch,
      ),
    );
  }

  /// A helper function for doing a recursive dictionary search.
  Future<void> openRecursiveDictionarySearch({
    required String searchTerm,
    required bool killOnPop,
    Function(String)? onUpdateQuery,
  }) async {
    _currentMediaPauseController.add(null);

    if (searchTerm.trim().isEmpty) {
      return;
    }

    await Navigator.push(
      _navigatorKey.currentContext!,
      PageRouteBuilder(
        pageBuilder: (context, animation1, animation2) =>
            RecursiveDictionaryPage(
          searchTerm: searchTerm,
          killOnPop: killOnPop,
          onUpdateQuery: onUpdateQuery,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    refreshDictionaryHistory();
  }

  /// A helper function for showing a result already in dictionary history.
  Future<void> openResultFromHistory({
    required DictionarySearchResult result,
  }) async {
    await openRecursiveDictionarySearch(
      searchTerm: result.searchTerm,
      killOnPop: false,
    );
  }

  /// A helper function for opening a text segmentation dialog.
  Future<void> openTextSegmentationDialog({
    required String sourceText,
    List<String>? segmentedText,
    Function(JidoujishoTextSelection)? onSelect,
    Function(JidoujishoTextSelection)? onSearch,
  }) async {
    if (sourceText.trim().isEmpty) {
      return;
    }

    segmentedText ??= targetLanguage.textToWords(sourceText);

    await showAppDialog(
      context: _navigatorKey.currentContext!,
      builder: (context) => TextSegmentationDialogPage(
        sourceText: sourceText,
        segmentedText: segmentedText!,
        onSelect: onSelect,
        onSearch: onSearch,
      ),
    );
  }

  /// A helper function for opening an example sentence dialog.
  Future<void> openExampleSentenceDialog({
    required List<String> exampleSentences,
    required Function(List<String>) onSelect,
    Function(List<String>)? onAppend,
  }) async {
    await showAppDialog(
      context: _navigatorKey.currentContext!,
      builder: (context) => ExampleSentencesDialogPage(
        exampleSentences: exampleSentences,
        onSelect: onSelect,
        onAppend: onAppend,
      ),
    );
  }

  /// Add the [searchTerm] to a search history with the given [historyKey]. If
  /// there are already a maximum number of items in history, this will be
  /// capped. Oldest items will be discarded in that scenario.
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) async {
    if (searchTerm.trim().isEmpty) {
      return;
    }

    final uk = '$historyKey/$searchTerm';

    // Update cache: remove existing, add to end
    final list = _searchHistoryCache.putIfAbsent(historyKey, () => []);
    list.remove(searchTerm);
    list.add(searchTerm);

    // Trim cache
    while (list.length > maximumSearchHistoryItems) {
      list.removeAt(0);
    }

    // Persist (upsert targets unique_key, no need to delete first)
    await _database.upsertSearchHistoryItem(SearchHistoryItemsCompanion.insert(
      historyKey: historyKey,
      searchTerm: searchTerm,
      uniqueKey: uk,
    ));
    await _database.trimSearchHistory(historyKey, maximumSearchHistoryItems);
  }

  /// Remove the [searchTerm] from a search history with the given [historyKey].
  Future<void> removeFromSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) async {
    _searchHistoryCache[historyKey]?.remove(searchTerm);
    final uk = '$historyKey/$searchTerm';
    await _database.deleteSearchHistoryByUniqueKey(uk);
  }

  /// Clear the search history with the given [historyKey].
  void clearSearchHistory({
    required String historyKey,
  }) async {
    _searchHistoryCache.remove(historyKey);
    await _database.clearSearchHistory(historyKey);
  }

  /// Get the search history for a given collection named [historyKey].
  List<String> getSearchHistory({required String historyKey}) {
    return List.unmodifiable(_searchHistoryCache[historyKey] ?? []);
  }

  /// Get whether or not a certain [searchTerm] is in a certain history.
  bool isTermInSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {
    return _searchHistoryCache[historyKey]?.contains(searchTerm) ?? false;
  }

  /// Adds the [terms] to the Stash and shows a message indicating the addition.
  void addToStash({
    required List<String> terms,
  }) async {
    if (terms.isEmpty) {
      return;
    }

    bool hasNonEmpty = false;
    for (String term in terms) {
      if (term.trim().isNotEmpty) {
        hasNonEmpty = true;
      }
    }
    if (!hasNonEmpty) {
      return;
    }

    for (String term in terms) {
      addToSearchHistory(
        historyKey: stashKey,
        searchTerm: term,
      );
    }

    if (terms.length == 1) {
      Fluttertoast.showToast(
        msg: t.stash_added_single(term: terms.first),
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    } else {
      Fluttertoast.showToast(
        msg: t.stash_added_multiple,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    }
  }

  /// Remove a certain [term] from the Stash.
  Future<void> removeFromStash({
    required String term,
  }) async {
    removeFromSearchHistory(
      historyKey: stashKey,
      searchTerm: term,
    );

    Fluttertoast.showToast(
      msg: t.stash_clear_single(term: term),
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }

  /// Clear the contents of the Stash.
  void clearStash() {
    clearSearchHistory(historyKey: stashKey);
  }

  /// Get the contents of the Stash.
  List<String> getStash() {
    return getSearchHistory(historyKey: stashKey);
  }

  /// Get the contents of the Stash.
  bool isTermInStash(String searchTerm) {
    return isTermInSearchHistory(historyKey: stashKey, searchTerm: searchTerm);
  }

  /// Shown when a query fails to be made to an online service. For example,
  /// when there is no internet connection.
  void showFailedToCommunicateMessage() {
    Fluttertoast.showToast(
      msg: t.failed_online_service,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }

  /// Update the scroll index of a given [DictionarySearchResult] in memory.
  void updateDictionaryResultScrollIndex({
    required DictionarySearchResult result,
    required int newIndex,
  }) {
    result.scrollPosition = newIndex;
    _persistDictionaryHistory();
  }

  /// Clear the entire dictionary history. This must be performed when a
  /// dictionary is deleted, otherwise history data cannot be viewed without
  /// the necessary dictionary metadata.
  Future<void> clearDictionaryHistory() async {
    _dictionaryHistoryResults.clear();
    await _database.clearDictionaryHistory();

    dictionaryEntriesNotifier.notifyListeners();
  }

  void _persistDictionaryHistory() async {
    final items = <DictionaryHistoryCompanion>[];
    for (int i = 0; i < _dictionaryHistoryResults.length; i++) {
      items.add(DictionaryHistoryCompanion.insert(
        position: i,
        resultJson: _dictionaryHistoryResults[i].toJson(),
      ));
    }
    await _database.replaceAllDictionaryHistory(items);
  }

  /// Add a [MediaItem] to history. This should be called at startup
  /// when the media item is launched.
  void addMediaItem(MediaItem item) async {
    _mediaItemsCache.removeWhere((m) => m.uniqueKey == item.uniqueKey);
    item.id = null;
    _mediaItemsCache.insert(0, item);

    await _database.deleteMediaItemByUniqueKey(item.uniqueKey);
    await _database.upsertMediaItem(_mediaItemToCompanion(item));
    await _database.trimMediaHistory(
        item.mediaTypeIdentifier, maximumMediaHistoryItems);

    // Refresh cache with DB-assigned IDs
    final rows = await _database.getAllMediaItems();
    _mediaItemsCache = rows.map(_rowToMediaItem).toList();
  }

  /// Update a media item, without performing any deletion or mutation
  /// operations. This is useful when updating constantly, for example,
  /// with the player where the position needs to be constantly updated.
  void updateMediaItem(MediaItem item) async {
    final idx =
        _mediaItemsCache.indexWhere((m) => m.uniqueKey == item.uniqueKey);
    if (idx >= 0) _mediaItemsCache[idx] = item;
    await _database.upsertMediaItem(_mediaItemToCompanion(item));
  }

  /// Deletes a [MediaItem] from the reading list by media identifier.
  void removeFromReadingList(String mediaIdentifier) async {
    _mediaItemsCache.removeWhere((m) => m.mediaIdentifier == mediaIdentifier);
    await _database.deleteMediaItemsByIdentifier(mediaIdentifier);
  }

  /// Deletes a [MediaItem] from history and also rids of override values.
  Future<void> deleteMediaItem(MediaItem item) async {
    MediaSource mediaSource = item.getMediaSource(appModel: this);
    await mediaSource.clearOverrideValues(appModel: this, item: item);
    await mediaSource.onMediaItemClear(item);

    _mediaItemsCache.removeWhere((m) => m.id == item.id);
    if (item.id != null) {
      await _database.deleteMediaItemById(item.id!);
    }
  }

  /// Copies a [term] to clipboard and shows an appropriate toast.
  void copyToClipboard(String term) {
    FlutterClipboard.copy(term);

    /// Redundant to do this with the share notification on Android
    if (_androidDeviceInfo.version.sdkInt < 33) {
      Fluttertoast.showToast(
        msg: t.copied_to_clipboard,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    }
  }

  /// For a given [MediaType], return the selected media source. If there is
  /// no persisted media source, use the first source in the list.
  MediaSource getCurrentSourceForMediaType({
    required MediaType mediaType,
  }) {
    MediaSource fallbackSource = mediaSources[mediaType]!.values.first;
    String uniqueKey = _getPref('current_source/${mediaType.uniqueKey}',
        defaultValue: fallbackSource.uniqueKey);

    return mediaSources[mediaType]![uniqueKey] ?? fallbackSource;
  }

  /// For a given [MediaType], set the selected media source.
  void setCurrentSourceForMediaType({
    required MediaType mediaType,
    required MediaSource mediaSource,
  }) {
    _setPref('current_source/${mediaType.uniqueKey}', mediaSource.uniqueKey);
  }

  /// Get the history of [MediaItem] for a particular [MediaType].
  List<MediaItem> getMediaTypeHistory({required MediaType mediaType}) {
    return _mediaItemsCache
        .where((m) => m.mediaTypeIdentifier == mediaType.uniqueKey)
        .toList();
  }

  /// Get the history of [MediaItem] for a particular [MediaSource].
  List<MediaItem> getMediaSourceHistory({required MediaSource mediaSource}) {
    return _mediaItemsCache
        .where((m) => m.mediaSourceIdentifier == mediaSource.uniqueKey)
        .toList();
  }

  /// Returns the last navigated directory the user used for picking a file for a
  /// certain media type.
  Directory? getLastPickedDirectory(MediaType type) {
    String path =
        _getPref('${type.uniqueKey}/last_picked_file', defaultValue: '');
    if (path.isEmpty) {
      return null;
    }

    Directory directory = Directory(path);
    if (!directory.existsSync()) {
      return null;
    }
    return directory;
  }

  /// Returns the last navigated directory the user used for picking a file for a
  /// certain media type.
  void setLastPickedDirectory({
    required MediaType type,
    required Directory directory,
  }) {
    _setPref('${type.uniqueKey}/last_picked_file', directory.path);
  }

  /// Returns valid file picker directories. If there is a last picked directory for
  /// a media type, this will be included as first on the list. Otherwise, external
  /// root directories will be included.
  Future<List<Directory>> getFilePickerDirectoriesForMediaType(
      MediaType type) async {
    List<Directory> directories = [];
    Directory? lastPickedDirectory = getLastPickedDirectory(type);
    if (lastPickedDirectory != null) {
      directories.add(lastPickedDirectory);
    }

    List<String> paths =
        (await ExternalPath.getExternalStorageDirectories()) ?? [];
    for (String path in paths) {
      Directory directory = Directory(path);
      if (!directories.contains(directory)) {
        directories.add(directory);
      }
    }

    return directories;
  }

  /// Get the blur options used in the player.
  BlurOptions get blurOptions {
    double width = _getPref('blur_width', defaultValue: 200.0);
    double height = _getPref('blur_height', defaultValue: 200.0);
    double left = _getPref('blur_left', defaultValue: -1.0);
    double top = _getPref('blur_top', defaultValue: -1.0);

    int red =
        _getPref('blur_red', defaultValue: Colors.black.withOpacity(0).red);
    int green =
        _getPref('blur_green', defaultValue: Colors.black.withOpacity(0).green);
    int blue =
        _getPref('blur_blue', defaultValue: Colors.black.withOpacity(0).blue);
    double opacity = _getPref('blur_opacity',
        defaultValue: Colors.black.withOpacity(0).opacity);

    Color color = Color.fromRGBO(red, green, blue, opacity);

    double blurRadius = _getPref('blur_radius', defaultValue: 5.0);
    bool visible = _getPref('blur_visible', defaultValue: false);

    return BlurOptions(
      width: width,
      height: height,
      left: left,
      top: top,
      color: color,
      blurRadius: blurRadius,
      visible: visible,
    );
  }

  /// Set the blur options used in the player.
  void setBlurOptions(BlurOptions options) {
    _setPref('blur_width', options.width);
    _setPref('blur_height', options.height);
    _setPref('blur_left', options.left);
    _setPref('blur_top', options.top);

    _setPref('blur_red', options.color.red);
    _setPref('blur_green', options.color.green);
    _setPref('blur_blue', options.color.blue);
    _setPref('blur_opacity', options.color.opacity);

    _setPref('blur_radius', options.blurRadius);
    _setPref('blur_visible', options.visible);
  }

  /// Gets the last used audio index of a given media item.
  int getMediaItemPreferredAudioIndex(MediaItem item) {
    return _getPref('audio_index/${item.uniqueKey}', defaultValue: 0);
  }

  /// Sets the last used audio index of a given media item.
  void setMediaItemPreferredAudioIndex(MediaItem item, int index) {
    _setPref('audio_index/${item.uniqueKey}', index);
  }

  /// Get definition focus mode for player.
  bool get isPlayerListeningComprehensionMode {
    return _getPref('player_listening_comprehension_mode', defaultValue: false);
  }

  /// Toggle definition focus mode for player.
  void togglePlayerListeningComprehensionMode() async {
    await _setPref('player_listening_comprehension_mode',
        !isPlayerListeningComprehensionMode);
  }

  /// Get orientation for player.
  bool get isPlayerOrientationPortrait {
    return _getPref('player_orientation_portrait', defaultValue: false);
  }

  /// Toggle orientation for player.
  void togglePlayerOrientationPortrait() async {
    await _setPref('player_orientation_portrait', !isPlayerOrientationPortrait);
  }

  /// Get whether or not to stretch to fill screen.
  bool get isStretchToFill {
    return _getPref('stretch_to_fill_screen', defaultValue: false);
  }

  /// Toggle stretch to fill screen.
  void toggleStretchToFill() async {
    await _setPref('stretch_to_fill_screen', !isStretchToFill);
  }

  /// Whether or not the player should use hardware acceleration.
  bool get playerHardwareAcceleration {
    return _getPref('player_hardware_acceleration', defaultValue: true);
  }

  /// Set whether or not the player should use hardware acceleration.
  void setPlayerHardwareAcceleration({required bool value}) async {
    await _setPref('player_hardware_acceleration', value);
  }

  /// Whether or not the player should allow background play.
  bool get playerBackgroundPlay {
    return _getPref('player_background_play', defaultValue: true);
  }

  /// Set whether or not the player should allow background play.
  void setPlayerBackgroundPlay({required bool value}) async {
    await _setPref('player_background_play', value);
  }

  /// Whether or not the player should show subtitles in notifications.
  bool get showSubtitlesInNotification {
    return _getPref('player_subtitle_notification', defaultValue: true);
  }

  /// Set whether or not the player should show subtitles in notifications.
  void setShowSubtitlesInNotification({required bool value}) async {
    await _setPref('player_subtitle_notification', value);
  }

  /// Whether or not the player should use hardware acceleration.
  bool get playerUseOpenSLES {
    return _getPref('player_use_opensles', defaultValue: true);
  }

  /// Set whether or not the player should use hardware acceleration.
  void setPlayerUseOpenSLES({required bool value}) async {
    await _setPref('player_use_opensles', value);
  }

  /// Allows the player screen to listen to play/pause changes.
  Stream<void> get playStream => _playStreamController.stream;
  final StreamController<void> _playStreamController =
      StreamController.broadcast();

  /// Allows the player screen to listen to seek changes.
  Stream<Duration> get seekStream => _seekStreamController.stream;
  final StreamController<Duration> _seekStreamController =
      StreamController.broadcast();

  /// Allows the player screen to listen to seek backward changes.
  Stream<void> get rewindStream => _rewindStreamController.stream;
  final StreamController<void> _rewindStreamController =
      StreamController.broadcast();

  /// Allows the player screen to listen to seek forward changes.
  Stream<void> get fastForwardStream => _fastForwardStreamController.stream;
  final StreamController<void> _fastForwardStreamController =
      StreamController.broadcast();

  Stream<void> get skipNextStream => _skipNextStreamController.stream;
  final StreamController<void> _skipNextStreamController =
      StreamController.broadcast();

  Stream<void> get skipPreviousStream => _skipPreviousStreamController.stream;
  final StreamController<void> _skipPreviousStreamController =
      StreamController.broadcast();

  /// For managing audio session events.
  JidoujishoAudioHandler? get audioHandler => _audioHandler;
  JidoujishoAudioHandler? _audioHandler;

  /// Initialises the audio service.
  Future<void> initialiseAudioHandler() async {
    if (_audioHandler != null) {
      return;
    }

    _audioHandler = await ag.AudioService.init<JidoujishoAudioHandler>(
      builder: () => JidoujishoAudioHandler(
        onPlayPause: () {
          _playStreamController.add(null);
        },
        onSeek: (position) {
          _seekStreamController.add(position);
        },
        onRewind: () {
          _rewindStreamController.add(null);
        },
        onFastForward: () {
          _fastForwardStreamController.add(null);
        },
        onSkipToNext: () {
          _skipNextStreamController.add(null);
        },
        onSkipToPrevious: () {
          _skipPreviousStreamController.add(null);
        },
      ),
      config: const ag.AudioServiceConfig(
        androidNotificationChannelId: 'app.hibiki.reader.channel.audio',
        androidNotificationChannelName: 'hibiki',
        androidNotificationIcon: 'drawable/ic_stat_hibiki',
        notificationColor: Colors.black,
        fastForwardInterval: Duration(seconds: 5),
        rewindInterval: Duration(seconds: 5),
      ),
    );
  }

  /// Whether or not searching in the app is performed without hitting the
  /// submit button.
  bool get autoSearchEnabled {
    return _getPref('auto_search', defaultValue: true);
  }

  /// Toggle auto search option.
  void toggleAutoSearchEnabled() async {
    await _setPref('auto_search', !autoSearchEnabled);
  }

  /// Search debounce delay in milliseconds by default.
  final int defaultSearchDebounceDelay = 100;

  /// The search debounce delay in milliseconds for searching in the app..
  int get searchDebounceDelay {
    return _getPref('auto_search_debounce_delay',
        defaultValue: defaultSearchDebounceDelay);
  }

  /// Sets the debounce delay in milliseconds for searching in the app..
  void setSearchDebounceDelay(int debounceDelay) async {
    await _setPref('auto_search_debounce_delay', debounceDelay);
  }

  /// Default dictionary font size for meanings.
  final double defaultDictionaryFontSize = 16;

  /// The search debounce delay in milliseconds for searching in the app..
  double get dictionaryFontSize {
    return _getPref('dictionary_entry_font_size',
        defaultValue: defaultDictionaryFontSize);
  }

  /// Sets the debounce delay in milliseconds for searching in the app..
  void setDictionaryFontSize(double fontSize) async {
    await _setPref('dictionary_entry_font_size', fontSize);
  }

  /// Default popup max width in dp.
  final double defaultPopupMaxWidth = 400;

  /// The popup max width in dp.
  double get popupMaxWidth {
    return _getPref('popup_max_width', defaultValue: defaultPopupMaxWidth);
  }

  /// Sets the popup max width in dp.
  void setPopupMaxWidth(double width) async {
    await _setPref('popup_max_width', width);
    notifyListeners();
  }

  /// Default value of [doubleTapSeekDuration].
  final int defaultDoubleTapSeekDuration = 5000;

  /// The default duration that the video player will seek forward or backward
  /// when double tapped by the user.
  int get doubleTapSeekDuration {
    return _getPref('double_tap_seek_duration',
        defaultValue: defaultDoubleTapSeekDuration);
  }

  /// Sets the default duration that the video player will seek forward or
  /// backward when double tapped by the user.
  void setDoubleTapSeekDuration(int value) async {
    await _setPref('double_tap_seek_duration', value);
  }

  /// Whether or not it is the app's first time setup to show the languages
  /// dialog.
  bool get isFirstTimeSetup {
    return _getPref('first_time_setup', defaultValue: true);
  }

  /// Sets the first time setup flag so the first time message does not show
  /// again.
  void setFirstTimeSetupFlag() async {
    await _setPref('first_time_setup', false);
  }

  /// The maximum dictionary terms in a result.
  int get maximumTerms {
    return _getPref('maximum_terms',
        defaultValue: defaultMaximumDictionaryTermsInResult);
  }

  /// Sets the maximum dictionary terms in a result.
  void setMaximumTerms(int value) async {
    await _setPref('maximum_terms', value);
  }

  /// Adds a [DictionarySearchResult] to dictionary history.
  void addToDictionaryHistory({required DictionarySearchResult result}) async {
    MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
    if (mediaType != DictionaryMediaType.instance) {
      shouldRefreshTabs = true;
      ScrollController scrollController =
          DictionaryMediaType.instance.scrollController;
      if (scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
    }

    if (result.entries.isEmpty || result.searchTerm.isEmpty) {
      return;
    }

    /// Remove any existing entry with the same search term.
    _dictionaryHistoryResults
        .removeWhere((r) => r.searchTerm == result.searchTerm);

    _dictionaryHistoryResults.add(result);

    /// Cap the history to the maximum number of items.
    while (_dictionaryHistoryResults.length > maximumDictionaryHistoryItems) {
      _dictionaryHistoryResults.removeAt(0);
    }

    _persistDictionaryHistory();
  }

  /// Check if the database is still open.
  bool get isDatabaseOpen => _isInitialised;

  /// Direct access to the Drift database instance.
  HibikiDatabase get database => _database;

  /// Safely shutdown and stop database operations.
  void shutdown() async {
    databaseCloseNotifier.notifyListeners();
    await _database.close();
    FlutterExitApp.exitApp();
  }

  Future<void> closeForPopup() async {
    databaseCloseNotifier.notifyListeners();
    await _database.close();
    HoshiDicts.disposeInstance();
  }

  static const _lifecycleChannel = HibikiChannels.lifecycle;

  Future<void> moveToBack() async {
    try {
      await _lifecycleChannel.invokeMethod<void>('moveTaskToBack');
    } catch (e) {
      debugPrint('[Hibiki] moveToBack failed: $e');
    }
  }

  /// Get whether or not the transcript should show play/pause.
  bool get isTranscriptPlayerMode {
    return _getPref('is_transcript_player_mode', defaultValue: false);
  }

  /// Toggle transcript player mode.
  void toggleTranscriptPlayerMode() async {
    await _setPref(
      'is_transcript_player_mode',
      !isTranscriptPlayerMode,
    );
  }

  /// Get whether or not the transcript should have a background.
  bool get isTranscriptOpaque {
    return _getPref('is_transcript_opaque', defaultValue: false);
  }

  /// Toggle transcript background.
  void toggleTranscriptOpaque() async {
    await _setPref(
      'is_transcript_opaque',
      !isTranscriptOpaque,
    );
  }

  /// Get whether or not subtitle timings are shown.
  bool get subtitleTimingsShown {
    return _getPref('subtitle_timings_shown', defaultValue: true);
  }

  /// Toggle subtitle timings shown.
  void toggleSubtitleTimingsShown() async {
    await _setPref(
      'subtitle_timings_shown',
      !subtitleTimingsShown,
    );
  }

  /// Get the saved value that the user has set for the [TagsField].
  String get savedTags {
    return _getPref('saved_tags', defaultValue: '');
  }

  /// Set the saved value that the user has set for the [TagsField].
  void setSavedTags(String value) async {
    await _setPref('saved_tags', value);
  }

  /// Whether to automatically add the current book name to the Tags field
  /// when creating cards.
  bool get autoAddBookNameToTags {
    return _getPref('auto_add_book_name_to_tags', defaultValue: true);
  }

  /// Toggle auto-adding of book name to tags.
  void toggleAutoAddBookNameToTags() async {
    await _setPref('auto_add_book_name_to_tags', !autoAddBookNameToTags);
  }

  /// Whether to deduplicate pitch accent values across dictionaries.
  bool get deduplicatePitchAccents {
    return _getPref('deduplicate_pitch_accents', defaultValue: true);
  }

  /// Toggle pitch accent deduplication.
  void toggleDeduplicatePitchAccents() async {
    await _setPref('deduplicate_pitch_accents', !deduplicatePitchAccents);
  }

  /// Whether to show harmonic mean frequency aggregation.
  bool get harmonicFrequency {
    return _getPref('harmonic_frequency', defaultValue: true);
  }

  /// Toggle harmonic frequency aggregation.
  void toggleHarmonicFrequency() async {
    await _setPref('harmonic_frequency', !harmonicFrequency);
  }

  /// Whether to auto-collapse dictionaries (only expand the first one).
  bool get collapseDictionaries {
    return _getPref('collapse_dictionaries', defaultValue: true);
  }

  /// Toggle dictionary auto-collapse.
  void toggleCollapseDictionaries() async {
    await _setPref('collapse_dictionaries', !collapseDictionaries);
  }

  /// Default audio source templates for word pronunciation.
  static const List<String> defaultAudioSources = [
    'https://hoshi-reader.manhhaoo-do.workers.dev/?term={term}&reading={reading}',
  ];

  /// Get the list of audio source URL templates.
  List<String> get audioSources {
    return _getPref('audio_sources', defaultValue: defaultAudioSources);
  }

  /// Hoshi-compatible enabled audio sources. Local audio is represented as the
  /// first source instead of a separate fallback path.
  List<String> get enabledAudioSources {
    final List<String> sources = audioSources
        .where((String source) => source != WordAudioResolver.localAudioUrl)
        .toList(growable: false);
    if (!localAudioEnabled) return sources;

    return <String>[
      WordAudioResolver.localAudioUrl,
      ...sources,
    ];
  }

  /// Set the list of audio source URL templates.
  void setAudioSources(List<String> sources) async {
    await _setPref('audio_sources', sources);
  }

  /// Path to local audio SQLite database (android.db from Yomitan Local Audio).
  String get localAudioDbPath {
    return _getPref('local_audio_db_path', defaultValue: '');
  }

  String get localAudioDbDisplayName {
    return _getPref('local_audio_db_display_name', defaultValue: '');
  }

  Future<void> setLocalAudioDbPath(
    String sourcePath, {
    required String displayName,
  }) async {
    final internalPath = path.join(_databaseDirectory.path, 'local_audio.db');
    final sourceFile = File(sourcePath);
    if (sourcePath != internalPath && await sourceFile.exists()) {
      await sourceFile.copy(internalPath);
    }
    await _setPref('local_audio_db_path', internalPath);
    await _setPref('local_audio_db_display_name', displayName);
    TtsChannel.instance.setLocalAudioDb(internalPath);
  }

  Future<void> clearLocalAudioDb() async {
    final internalPath = path.join(_databaseDirectory.path, 'local_audio.db');
    await TtsChannel.instance.setLocalAudioDb('');
    await _setPref('local_audio_db_path', '');
    await _setPref('local_audio_db_display_name', '');
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$internalPath$suffix');
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  bool get localAudioEnabled {
    return _getPref('local_audio_enabled', defaultValue: false);
  }

  void toggleLocalAudio() async {
    await _setPref('local_audio_enabled', !localAudioEnabled);
    if (localAudioEnabled && localAudioDbPath.isNotEmpty) {
      TtsChannel.instance.setLocalAudioDb(localAudioDbPath);
    }
  }

  bool get showPlayBar {
    return _getPref('show_play_bar', defaultValue: true);
  }

  void toggleShowPlayBar() async {
    await _setPref('show_play_bar', !showPlayBar);
    notifyListeners();
  }

  bool get showMediaNotification {
    return _getPref('show_media_notification', defaultValue: true);
  }

  void toggleShowMediaNotification() async {
    await _setPref('show_media_notification', !showMediaNotification);
    notifyListeners();
  }

  Future<void> setShowMediaNotification(bool value) async {
    await _setPref('show_media_notification', value);
    notifyListeners();
  }

  bool get showFloatingLyric {
    return _getPref('show_floating_lyric', defaultValue: false);
  }

  Future<void> setShowFloatingLyric(bool value) async {
    await _setPref('show_floating_lyric', value);
    notifyListeners();
  }

  double get floatingLyricFontSize {
    return _getPref('floating_lyric_font_size', defaultValue: 20.0);
  }

  Future<void> setFloatingLyricFontSize(double value) async {
    await _setPref('floating_lyric_font_size', value.clamp(8, 64).toDouble());
    notifyListeners();
  }

  bool get updateNeverRemind {
    return _getPref('update_never_remind', defaultValue: false);
  }

  Future<void> setUpdateNeverRemind(bool value) async {
    await _setPref('update_never_remind', value);
    notifyListeners();
  }

  bool get updateAutoInstall {
    return _getPref('update_auto_install', defaultValue: false);
  }

  Future<void> setUpdateAutoInstall(bool value) async {
    await _setPref('update_auto_install', value);
    notifyListeners();
  }

  bool get updateBetaChannel {
    return _getPref('update_beta_channel', defaultValue: false);
  }

  Future<void> setUpdateBetaChannel(bool value) async {
    await _setPref('update_beta_channel', value);
    notifyListeners();
  }

  bool get disableDialogScrim {
    return _getPref('disable_dialog_scrim', defaultValue: false);
  }

  Future<void> setDisableDialogScrim(bool value) async {
    await _setPref('disable_dialog_scrim', value);
    notifyListeners();
  }

  /// Get whether or not bookmarks have been populated.
  bool get populateBookmarksFlag {
    return _getPref('populate_bookmarks', defaultValue: false);
  }

  /// Sets the populate bookmarks flag so bookmarks don't get added again.
  void setPopulateBookmarksFlag() async {
    await _setPref('populate_bookmarks', true);
  }
}
