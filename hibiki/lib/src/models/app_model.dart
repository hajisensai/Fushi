import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

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
import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:remove_emoji/remove_emoji.dart';
import 'package:restart_app/restart_app.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/epub/ttu_migration.dart';
import 'package:hibiki/src/epub/ttu_migration_server.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/media/floating_dict_channel.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';
import 'package:hibiki/src/models/media_history_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart' as theme_notifier;
import 'package:hibiki/src/models/theme_notifier.dart' show ThemeNotifier;

/// A list of fields that the app will support at runtime.
final List<Field> globalFields = List<Field>.unmodifiable(
  [
    SentenceField.instance,
    CueSentenceField.instance,
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

/// Represents a single local audio database entry with path and display name.
class LocalAudioDbEntry {
  const LocalAudioDbEntry({
    required this.path,
    required this.displayName,
    this.enabled = true,
  });

  factory LocalAudioDbEntry.fromJson(Map<String, dynamic> json) =>
      LocalAudioDbEntry(
        path: json['path'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );
  final String path;
  final String displayName;
  final bool enabled;

  LocalAudioDbEntry copyWith({bool? enabled}) => LocalAudioDbEntry(
        path: path,
        displayName: displayName,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'displayName': displayName,
        'enabled': enabled,
      };
}

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

// Theme helper functions moved to theme_notifier.dart.
// Re-export for backward compatibility.
ColorScheme buildHibikiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
}) =>
    theme_notifier.buildHibikiColorScheme(
      seedColor: seedColor,
      brightness: brightness,
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      primaryContainer: primaryContainer,
    );

/// A scoped model for parameters that affect the entire application.
/// RiverPod is used for global state management across multiple layers,
/// especially for preferences that persist across application restarts.
class AppModel with ChangeNotifier {
  /// Used for showing dialogs without needing to pass around a [BuildContext].
  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;
  late final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  BuildContext? get _ctx => _navigatorKey.currentContext;

  /// Used to get the versioning metadata of the app. See [initialise].
  RouteObserver<PageRoute> get routeObserver => _routeObserver;
  final RouteObserver<PageRoute> _routeObserver = RouteObserver<PageRoute>();

  /// Persistent database (Drift/SQLite).
  late final HibikiDatabase _database;

  /// Theme management, extracted from AppModel for testability.
  late final ThemeNotifier themeNotifier;

  /// Preference management, extracted from AppModel for testability.
  PreferencesRepository? _prefsRepo;
  PreferencesRepository get prefsRepo => _prefsRepo!;

  /// Media history and search history, extracted for testability.
  late final MediaHistoryRepository mediaHistoryRepo;

  /// Dictionary metadata, history, and search caches.
  late final DictionaryRepository dictRepo;

  Color? get systemPrimaryColor => themeNotifier.systemPrimaryColor;

  Future<void> refreshSystemPalette() => themeNotifier.refreshSystemPalette();

  /// Used to get the versioning metadata of the app. See [initialise].
  PackageInfo get packageInfo => _packageInfo;
  late final PackageInfo _packageInfo;

  /// Used to get information on the Android version of the device.
  AndroidDeviceInfo? get androidDeviceInfo => _androidDeviceInfo;
  AndroidDeviceInfo? _androidDeviceInfo;

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

  /// Pre-compiled regex from remove_emoji package (avoids per-call RegExp()).
  static final RegExp _emojiRegex = RegExp(RemoveEmoji().getRegexString());

  static final RegExp _punctuationRegex =
      RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);
  static final RegExp _loneSurrogateRegex = RegExp(
    '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
  );

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

  int get maximumSearchHistoryItems =>
      mediaHistoryRepo.maximumSearchHistoryItems;

  int get maximumMediaHistoryItems => mediaHistoryRepo.maximumMediaHistoryItems;

  /// Maximum number of dictionary history items.
  int get maximumDictionaryHistoryItems => lowMemoryMode ? 5 : 10;

  /// Maximum number of dictionary search results stored in the database.
  final int maximumDictionarySearchResults = 200;

  /// Maximum number of headwords in a returned dictionary result for
  /// performance purposes.
  final int defaultMaximumDictionaryTermsInResult = 10;

  String get stashKey => mediaHistoryRepo.stashKey;

  /// Used to check if the dictionary tab should be refreshed on switching tabs.
  bool shouldRefreshTabs = false;

  // ── dictionary delegates (DictionaryRepository) ────────────────────

  List<Dictionary> get dictionaries => dictRepo.dictionaries;
  List<Dictionary> get termDictionaries => dictRepo.termDictionaries;
  List<Dictionary> get freqDictionaries => dictRepo.freqDictionaries;
  List<Dictionary> get pitchDictionaries => dictRepo.pitchDictionaries;
  List<Dictionary> get kanjiDictionaries => dictRepo.kanjiDictionaries;

  bool _dictTypesMigrated = false;

  void _migrateDictionaryTypes() {
    if (_dictTypesMigrated) return;
    _dictTypesMigrated = true;
    final dicts = dictRepo.dictionaries;
    for (final d in dicts) {
      if (d.type != DictionaryType.term) continue;

      final blobsFile = File(
          path.join(dictionaryResourceDirectory.path, d.name, 'blobs.bin'));
      if (!blobsFile.existsSync()) continue;

      final raf = blobsFile.openSync();
      try {
        if (raf.lengthSync() < 4) continue;
        final header = raf.readSync(4);
        if (header[0] != 0x01) continue;

        final exprLen = header[1] | (header[2] << 8);
        raf.setPositionSync(3 + exprLen);
        final modeLenBuf = raf.readSync(1);
        if (modeLenBuf.isEmpty) continue;
        final modeLen = modeLenBuf[0];
        if (modeLen == 0) continue;
        final modeBytes = raf.readSync(modeLen);
        final mode = String.fromCharCodes(modeBytes);

        DictionaryType detected;
        if (mode == 'freq') {
          detected = DictionaryType.frequency;
        } else if (mode == 'pitch') {
          detected = DictionaryType.pitch;
        } else {
          continue;
        }

        final updated = Dictionary(
          name: d.name,
          formatKey: d.formatKey,
          order: d.order,
          type: detected,
          metadata: d.metadata,
          hiddenLanguages: d.hiddenLanguages,
          collapsedLanguages: d.collapsedLanguages,
        );
        dictRepo.persistDictionary(updated);
        debugPrint('[Hibiki] migrated dict type: ${d.name} → ${detected.name}');
      } catch (e, stack) {
        ErrorLogService.instance.log('AppModel.dictTypeMigration', e, stack);
        debugPrint('[Hibiki] dict type migration error for ${d.name}: $e');
      } finally {
        raf.closeSync();
      }
    }
  }

  void _rebuildDictPathsCache() {
    _migrateDictionaryTypes();
    final termPaths = <String>[];
    final freqPaths = <String>[];
    final pitchPaths = <String>[];
    for (final d in dictRepo.dictionaries) {
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

  List<DictionarySearchResult> get dictionaryHistory =>
      dictRepo.dictionaryHistory;

  /// For invoking pauses from media where needed.
  Stream<void> get currentMediaPauseStream =>
      _currentMediaPauseController.stream;
  final StreamController<void> _currentMediaPauseController =
      StreamController.broadcast();

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

  ThemeMode get themeMode => themeNotifier.themeMode;
  ThemeData get theme => themeNotifier.theme;
  ThemeData get darkTheme => themeNotifier.darkTheme;

  ColorScheme buildColorScheme(Brightness brightness) =>
      themeNotifier.buildColorScheme(brightness);

  /// Get the sentence to be used by the [SentenceField] upon card creation.
  HibikiTextSelection getCurrentSentence() {
    if (isMediaOpen) {
      return _currentMediaSource!.currentSentence;
    } else {
      MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
      if (mediaType is DictionaryMediaType) {
        return HibikiTextSelection(
          text: '',
        );
      } else {
        return (_currentMediaSource ??
                (getCurrentSourceForMediaType(mediaType: mediaType)))
            .currentSentence;
      }
    }
  }

  HibikiTextSelection getCurrentCueSentence() {
    if (isMediaOpen) {
      return _currentMediaSource!.currentCueSentence;
    } else {
      MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
      if (mediaType is DictionaryMediaType) {
        return HibikiTextSelection(text: '');
      } else {
        return (_currentMediaSource ??
                (getCurrentSourceForMediaType(mediaType: mediaType)))
            .currentCueSentence;
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

  void updateDictionaryOrder(List<Dictionary> newDictionaries) =>
      dictRepo.updateDictionaryOrder(newDictionaries);

  /// Populate maps for languages at startup to optimise performance.
  void populateLanguages() {
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
  void populateLocales() {
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
  void populateMediaTypes() {
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
  void populateMediaSources() {
    /// A list of media sources that the app will support at runtime.
    final Map<MediaType, List<MediaSource>> availableMediaSources = {
      ReaderMediaType.instance: [
        ReaderHibikiSource.instance,
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
  void populateDictionaryFormats() {
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
  void populateFields() {
    fields = Map<String, Field>.unmodifiable(
      Map<String, Field>.fromEntries(
        globalFields.map(
          (field) => MapEntry(field.uniqueKey, field),
        ),
      ),
    );
  }

  /// Populate maps for enhancements at startup to optimise performance.
  void populateEnhancements() {
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
      CueSentenceField.instance: [
        ClearFieldEnhancement(field: CueSentenceField.instance),
        TextSegmentationEnhancement(field: CueSentenceField.instance),
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
  void populateQuickActions() {
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
    if (!Platform.isAndroid) {
      return prepareFallbackHibikiDirectory();
    }
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
    } catch (e, stack) {
      ErrorLogService.instance.log('AppModel.prepareHibikiDirectory', e, stack);
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
      if (Platform.isAndroid) {
        _androidDeviceInfo = await DeviceInfoPlugin().androidInfo;
      }

      debugPrint('[Hibiki] init: directories (early, needed for DB)');
      _temporaryDirectory = await getTemporaryDirectory();
      _appDirectory = await getApplicationDocumentsDirectory();
      _databaseDirectory = await getApplicationSupportDirectory();

      debugPrint('[Hibiki] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);

      /// Load all preferences into memory for synchronous reads.
      _prefsRepo = PreferencesRepository(_database);
      await prefsRepo.loadFromDb();
      prefsRepo.addListener(notifyListeners);
      _applyMemoryPolicy();

      /// Create theme notifier (extracted subsystem).
      themeNotifier = ThemeNotifier(_database, () => textTheme);

      /// Ensure default profile exists on first launch.
      final BaseAnkiRepository ankiRepo =
          Platform.isAndroid ? AnkiRepository() : AnkiConnectRepository();
      final profileRepo = ProfileRepository(_database, ankiRepo);
      await profileRepo.ensureDefaultProfile();

      /// Load dictionary metadata + history caches.
      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache);
      await dictRepo.loadFromDb();

      /// Load media items and search history caches.
      mediaHistoryRepo = MediaHistoryRepository(_database);
      await mediaHistoryRepo.loadFromDb();

      /// Permission requests are deferred to the point of use (file import,
      /// Anki export) so they do not block startup.

      debugPrint('[Hibiki] init: system palette');
      await refreshSystemPalette();

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

      debugPrint('[Hibiki] init: populate maps');
      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      await _seedBuiltInTags();
      populateMediaTypes();
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();
      populateQuickActions();

      debugPrint('[Hibiki] init: targetLanguage + licenses (parallel)');
      await Future.wait(<Future<void>>[
        targetLanguage.initialise(),
        injectAssetLicenses(),
      ]);

      debugPrint(
          '[Hibiki] init: enhancements + quick actions + media sources (parallel)');
      MediaSource.setDatabase(_database);
      final readerSettings = ReaderSettings(_database);
      await readerSettings.ready;
      ReaderHibikiSource.readerSettings = readerSettings;

      await Future.wait(<Future<void>>[
        Future.wait(<Future<void>>[
          for (Field field in globalFields)
            for (Enhancement enhancement in enhancements[field]!.values)
              enhancement.initialise(),
        ]),
        Future.wait(<Future<void>>[
          for (QuickAction action in quickActions.values) action.initialise(),
        ]),
        Future.wait(<Future<void>>[
          for (MediaType type in mediaTypes.values)
            for (MediaSource source in mediaSources[type]!.values)
              source.initialise(),
        ]),
      ]);

      if (_shouldRunTtuMigration()) {
        debugPrint('[Hibiki] init: ttu → EpubBooks migration');
        try {
          final migServer = await TtuMigrationServer.start(targetLanguage);
          final int migCount = await TtuMigration.migrateIfNeeded(
            _database,
            migServer.boundPort!,
          );
          if (migCount > 0) {
            debugPrint('[Hibiki] ttu migration: $migCount books migrated');
          }
          final int blobCount = await TtuMigration.remediateMissingBlobs(
            _database,
            migServer.boundPort!,
          );
          if (blobCount > 0) {
            debugPrint('[Hibiki] ttu blob remediation: $blobCount books fixed');
          }
          final int tocCount = await TtuMigration.remediateMissingToc(
            _database,
            migServer.boundPort!,
          );
          if (tocCount > 0) {
            debugPrint('[Hibiki] ttu TOC remediation: $tocCount books fixed');
          }
          final int charCount = await TtuMigration.remediateMissingCharacters(
            _database,
          );
          if (charCount > 0) {
            debugPrint(
                '[Hibiki] characters remediation: $charCount books fixed');
          }
        } catch (e, stack) {
          ErrorLogService.instance.log('AppModel.ttuMigration', e, stack);
          debugPrint('[Hibiki] ttu migration failed (non-fatal): $e');
        }
      } else {
        debugPrint('[Hibiki] init: ttu migration skipped '
            '(desktop or version >= 0.5.0)');
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
      _setupFloatingDictHandlers();
      if (showFloatingDict) setShowFloatingDict(false);
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Hibiki] init FAILED: $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise', e, stack);
      _initError = '$e';
      notifyListeners();
    }
  }

  bool _shouldRunTtuMigration() {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final parts = _packageInfo.version.split('.');
    final int major = int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 0;
    final int minor = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0;
    // >= 0.5.0 → no TTU data ever existed, skip migration
    if (major > 0 || (major == 0 && minor >= 5)) return false;
    return true;
  }

  Future<void> initialiseForDictionaryPopup() async {
    if (_isInitialised) {
      debugPrint('[Hibiki-popup] init: already initialised, refreshing prefs');
      await refreshPrefCache();
      await _bindLocalAudioDbForNativeHandler();
      return;
    }
    try {
      debugPrint('[Hibiki-popup] init: PackageInfo + DeviceInfo');
      _packageInfo = await PackageInfo.fromPlatform();
      if (Platform.isAndroid) {
        _androidDeviceInfo = await DeviceInfoPlugin().androidInfo;
      }

      debugPrint('[Hibiki-popup] init: directories');
      _temporaryDirectory = await getTemporaryDirectory();
      _appDirectory = await getApplicationDocumentsDirectory();
      _databaseDirectory = await getApplicationSupportDirectory();

      debugPrint('[Hibiki-popup] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);

      _prefsRepo = PreferencesRepository(_database);
      await prefsRepo.loadFromDb();
      prefsRepo.addListener(notifyListeners);

      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache);
      await dictRepo.loadFromDb();

      mediaHistoryRepo = MediaHistoryRepository(_database);
      await mediaHistoryRepo.loadFromDb();

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
      ErrorLogService.instance.log('AppModel.popupInit', e, stack);
      debugPrint('[Hibiki-popup] init FAILED: $e\n$stack');
      _initError = '$e';
      notifyListeners();
    }
  }

  /// Reload the preference cache from the database, e.g. after a profile
  /// switch has written new values.
  Future<void> refreshPrefCache() async {
    await prefsRepo.refreshFromDb();
    for (final sourceMap in mediaSources.values) {
      for (final source in sourceMap.values) {
        await source.refreshPreferencesFromDb();
      }
    }
    await themeNotifier.refreshFromDb();
    notifyListeners();
  }

  // ── sync pref helpers (delegated to PreferencesRepository) ──────────

  dynamic _getPref(String key, {dynamic defaultValue}) =>
      prefsRepo.getPref(key, defaultValue: defaultValue);

  Future<void> _setPref(String key, dynamic value) =>
      prefsRepo.setPref(key, value);

  Future<void> _seedBuiltInTags() async {
    if (prefsRepo.containsKey('builtInTagsSeeded')) return;
    final existing = await _database.getAllTags();
    if (existing.isEmpty) {
      const int blue = 0xFF42A5F5;
      const int green = 0xFF66BB6A;
      await _database.createTag(t.tag_builtin_reading, blue);
      await _database.createTag(t.tag_builtin_finished, green);
    }
    await _setPref('builtInTagsSeeded', 'true');
  }

  Future<void> _bindLocalAudioDbForNativeHandler({
    bool clearMissingPath = false,
  }) async {
    if (!localAudioEnabled) return;
    final List<LocalAudioDbEntry> dbs = localAudioDbs;
    if (dbs.isEmpty) return;

    final List<String> validPaths = <String>[];
    for (final LocalAudioDbEntry entry in dbs) {
      if (!entry.enabled) continue;
      if (await File(entry.path).exists()) {
        validPaths.add(entry.path);
      } else {
        debugPrint('[hibiki-audio] DB missing, skipping: ${entry.path}');
      }
    }
    if (validPaths.isNotEmpty) {
      await TtsChannel.instance.setLocalAudioDbs(validPaths);
    }
  }

  // _rowToDictionary, _dictionaryToCompanion, _persistDictionary
  // moved to DictionaryRepository.

  // ── Theme delegates (logic moved to ThemeNotifier) ──────────────────

  static Map<String, ({Color seed, Brightness brightness})> get themePresets =>
      ThemeNotifier.themePresets;

  static String themeLabel(String key) => ThemeNotifier.themeLabel(key);

  String get appThemeKey => themeNotifier.appThemeKey;
  Future<void> setAppThemeKey(String key) => themeNotifier.setAppThemeKey(key);

  String get brightnessMode => themeNotifier.brightnessMode;
  Future<void> setBrightnessMode(String mode) =>
      themeNotifier.setBrightnessMode(mode);

  bool get isDarkMode => themeNotifier.isDarkMode;

  Color get customThemeSeed => themeNotifier.customThemeSeed;
  Future<void> setCustomThemeSeed(Color c) =>
      themeNotifier.setCustomThemeSeed(c);

  bool get customThemeDark => themeNotifier.customThemeDark;
  Future<void> setCustomThemeDark(bool v) =>
      themeNotifier.setCustomThemeDark(v);

  Color? get customThemeFontColor => themeNotifier.customThemeFontColor;
  Future<void> setCustomThemeFontColor(Color? c) =>
      themeNotifier.setCustomThemeFontColor(c);

  Color? get customThemeBackgroundColor =>
      themeNotifier.customThemeBackgroundColor;
  Future<void> setCustomThemeBackgroundColor(Color? c) =>
      themeNotifier.setCustomThemeBackgroundColor(c);

  Color? get customThemeSelectionColor =>
      themeNotifier.customThemeSelectionColor;
  Future<void> setCustomThemeSelectionColor(Color? c) =>
      themeNotifier.setCustomThemeSelectionColor(c);

  Color? get customThemePrimaryColor => themeNotifier.customThemePrimaryColor;
  Future<void> setCustomThemePrimaryColor(Color? c) =>
      themeNotifier.setCustomThemePrimaryColor(c);

  Color? get customThemeSecondaryColor =>
      themeNotifier.customThemeSecondaryColor;
  Future<void> setCustomThemeSecondaryColor(Color? c) =>
      themeNotifier.setCustomThemeSecondaryColor(c);

  Color? get customThemeTertiaryColor => themeNotifier.customThemeTertiaryColor;
  Future<void> setCustomThemeTertiaryColor(Color? c) =>
      themeNotifier.setCustomThemeTertiaryColor(c);

  Color? get customThemeContainerColor =>
      themeNotifier.customThemeContainerColor;
  Future<void> setCustomThemeContainerColor(Color? c) =>
      themeNotifier.setCustomThemeContainerColor(c);

  Color? get customThemeSasayakiColor => themeNotifier.customThemeSasayakiColor;
  Future<void> setCustomThemeSasayakiColor(Color? c) =>
      themeNotifier.setCustomThemeSasayakiColor(c);

  Color? get customThemeLinkColor => themeNotifier.customThemeLinkColor;
  Future<void> setCustomThemeLinkColor(Color? c) =>
      themeNotifier.setCustomThemeLinkColor(c);

  Future<void> applyCustomTheme({
    required Color seed,
    required String brightnessMode,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sasayakiColor,
    Color? linkColor,
  }) =>
      themeNotifier.applyCustomTheme(
        seed: seed,
        brightnessMode: brightnessMode,
        fontColor: fontColor,
        backgroundColor: backgroundColor,
        selectionColor: selectionColor,
        primaryColor: primaryColor,
        secondaryColor: secondaryColor,
        tertiaryColor: tertiaryColor,
        containerColor: containerColor,
        sasayakiColor: sasayakiColor,
        linkColor: linkColor,
      );

  /// Get the target language from persisted preferences.
  Language get targetLanguage {
    String defaultLocaleTag = languages.values.first.locale.toLanguageTag();
    String localeTag =
        _getPref('target_language', defaultValue: defaultLocaleTag);

    return languages[localeTag]!;
  }

  String get lastSelectedDeckName => prefsRepo.lastSelectedDeckName;

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

  String? get lastSelectedModel => prefsRepo.lastSelectedModel;

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
    if (Platform.isAndroid || Platform.isIOS) {
      Restart.restartApp();
    } else {
      notifyListeners();
    }
  }

  /// Persist a new last selected dictionary format. This is called when the
  /// user changes the import format in the dictionary menu.
  Future<void> setLastSelectedDictionaryFormat(
      DictionaryFormat dictionaryFormat) async {
    String lastDictionaryFormatName = dictionaryFormat.uniqueKey;
    await _setPref('last_selected_dictionary_format', lastDictionaryFormatName);
  }

  Future<void> setLastSelectedModelName(String modelName) =>
      prefsRepo.setLastSelectedModelName(modelName);

  Future<void> setLastSelectedDeck(String deckName) =>
      prefsRepo.setLastSelectedDeck(deckName);

  int get currentHomeTabIndex => prefsRepo.currentHomeTabIndex;

  Future<void> setCurrentHomeTabIndex(int index) =>
      prefsRepo.setCurrentHomeTabIndex(index);

  /// Show the dictionary menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showDictionaryMenu() async {
    final ctx = _ctx;
    if (ctx == null) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => const DictionaryDialogPage(),
    );

    notifyListeners();
    dictionaryMenuNotifier.notifyListeners();
  }

  /// Show the language menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showLanguageMenu() async {
    final ctx = _ctx;
    if (ctx == null) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => const LanguageDialogPage(),
    );
  }

  /// Show the profiles management page.
  Future<void> showProfilesMenu() async {
    final ctx = _ctx;
    if (ctx == null) return;
    await Navigator.push(
      ctx,
      adaptivePageRoute(
        builder: (context) => const ProfileManagementPage(),
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
    } catch (e, stack) {
      ErrorLogService.instance.log('AppModel.fontNamesFromZip', e, stack);
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
    VoidCallback? onMemoryError,
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
        } catch (e, stack) {
          ErrorLogService.instance.log('AppModel.scanFontDir', e, stack);
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
            onMemoryError: onMemoryError,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('AppModel.importDictZip', e, stack);
          HibikiToast.show(
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

        final name = _sanitizeDictionaryTitle(result.title);

        progressNotifier.value = t.import_name(name: name);

        if (dictRepo.hasDictionaryNamed(name)) {
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
        if (!path.isWithin(
            dictionaryResourceDirectory.path, finalResourceDirectory.path)) {
          throw Exception('Invalid dictionary title: path traversal detected');
        }
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

        dictRepo.persistDictionary(dictionary);

        progressNotifier.value = t.import_complete;
        onImportSuccess();
      } finally {
        if (tempZip.existsSync()) tempZip.deleteSync();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryImport(dir)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3), () {});
      if (_isMemoryError(e) && !lowMemoryMode) {
        progressNotifier.value = t.low_memory_mode_suggestion;
        await Future.delayed(const Duration(seconds: 3), () {});
        onMemoryError?.call();
      }
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

  static String _sanitizeDictionaryTitle(String raw) {
    final cleaned = path.basename(raw.trim()).replaceAll(RegExp(r'[/\\]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      throw Exception('Dictionary title is empty');
    }
    return cleaned;
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
    VoidCallback? onMemoryError,
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

      final name = _sanitizeDictionaryTitle(result.title);

      progressNotifier.value = t.import_name(name: name);

      if (dictRepo.hasDictionaryNamed(name)) {
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
      if (!path.isWithin(
          dictionaryResourceDirectory.path, finalResourceDirectory.path)) {
        throw Exception('Invalid dictionary title: path traversal detected');
      }
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

      dictRepo.persistDictionary(dictionary);

      progressNotifier.value = t.import_complete;
      onImportSuccess();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryImport(file)', e, stack);
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3), () {});
      if (_isMemoryError(e) && !lowMemoryMode) {
        progressNotifier.value = t.low_memory_mode_suggestion;
        await Future.delayed(const Duration(seconds: 3), () {});
        onMemoryError?.call();
      }
      progressNotifier.value = t.import_failed;
      await Future.delayed(const Duration(seconds: 1), () {});
    }
  }

  void toggleDictionaryCollapsed(Dictionary dictionary) => dictRepo
      .toggleDictionaryCollapsed(dictionary, targetLanguage.languageCode);

  void toggleDictionaryHidden(Dictionary dictionary) =>
      dictRepo.toggleDictionaryHidden(dictionary, targetLanguage.languageCode);

  Future<void> deleteDictionaries() async {
    try {
      await clearDictionaryHistory();
      await _database.clearAllDictionaryMeta();

      if (dictionaryResourceDirectory.existsSync()) {
        dictionaryResourceDirectory.deleteSync(recursive: true);
        dictionaryResourceDirectory.createSync(recursive: true);
      }

      dictRepo.clearDictionariesCache();
      dictRepo.clearDictionaryResultsCache();
    } catch (e, stack) {
      ErrorLogService.instance.log('deleteDictionaries', e, stack);
      HibikiToast.show(msg: 'Failed to delete dictionaries');
    } finally {
      dictionarySearchAgainNotifier.notifyListeners();
    }
  }

  Future<void> deleteDictionary(Dictionary dictionary) async {
    try {
      await clearDictionaryHistory();
      await _database.deleteDictionaryMeta(dictionary.name);

      final directory = Directory(
          path.join(dictionaryResourceDirectory.path, dictionary.name));

      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }

      dictRepo.removeDictionaryFromCache(dictionary.name);
      _rebuildDictPathsCache();
      dictRepo.clearDictionaryResultsCache();
    } catch (e, stack) {
      ErrorLogService.instance.log('deleteDictionary', e, stack);
      HibikiToast.show(msg: 'Failed to delete dictionary');
    } finally {
      dictionarySearchAgainNotifier.notifyListeners();
    }
  }

  void clearDictionaryResultsCache() => dictRepo.clearDictionaryResultsCache();

  /// Gets the raw unprocessed entries straight from a dictionary database
  /// given a search term. This will be processed later for user viewing.
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
  }) async {
    final swTotal = Stopwatch()..start();
    final swPreprocess = Stopwatch()..start();

    searchTerm = searchTerm.replaceAll('\n', ' ');

    final swEmoji = Stopwatch()..start();
    searchTerm = searchTerm.replaceAll(_emojiRegex, ' ');
    swEmoji.stop();

    final swPunct = Stopwatch()..start();
    searchTerm = searchTerm.replaceAll(_punctuationRegex, '');
    swPunct.stop();

    final swSurrogate = Stopwatch()..start();
    searchTerm = searchTerm.replaceAll(_loneSurrogateRegex, ' ');
    swSurrogate.stop();

    swPreprocess.stop();
    debugPrint('[dict-perf] preprocess: ${swPreprocess.elapsedMilliseconds}ms '
        '(emoji=${swEmoji.elapsedMicroseconds}µs '
        'punct=${swPunct.elapsedMicroseconds}µs '
        'surrogate=${swSurrogate.elapsedMicroseconds}µs) '
        '"$searchTerm"');

    if (searchTerm.trim().isEmpty) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    final int effectiveMaxTerms = overrideMaximumTerms ?? maximumTerms;
    final String cacheKey =
        '$searchTerm/$effectiveMaxTerms/$maximumDictionarySearchResults';

    final cached = dictRepo.getCachedSearch(cacheKey);
    if (useCache && cached != null) {
      swTotal.stop();
      debugPrint('[dict-perf] cache HIT: ${swTotal.elapsedMilliseconds}ms');
      return cached;
    }

    if (!HoshiDicts.isInitialized) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    List<HoshiLookupResult>? ffiResults =
        dictRepo.getCachedFfiLookup(searchTerm);
    DictionarySearchResult? result;

    if (ffiResults != null) {
      final swBuild = Stopwatch()..start();
      result = buildResultFromLookup(
        searchTerm: searchTerm,
        results: ffiResults,
        maximumTerms: effectiveMaxTerms,
      );
      swBuild.stop();
      debugPrint(
          '[dict-perf] FFI cache HIT, buildResultFromLookup: ${swBuild.elapsedMilliseconds}ms entries=${result.entries.length}');
    } else {
      final swLookup = Stopwatch()..start();
      ffiResults = HoshiDicts.instance.lookup(
        searchTerm,
        maxResults: maximumDictionarySearchResults,
      );
      if (ffiResults.isNotEmpty) {
        dictRepo.cacheFfiLookup(searchTerm, ffiResults);
        result = buildResultFromLookup(
          searchTerm: searchTerm,
          results: ffiResults,
          maximumTerms: effectiveMaxTerms,
        );
      }
      swLookup.stop();
      debugPrint(
          '[dict-perf] FFI lookup + build: ${swLookup.elapsedMilliseconds}ms entries=${result?.entries.length ?? 0}');
    }

    swTotal.stop();
    debugPrint(
        '[dict-perf] searchDictionary total: ${swTotal.elapsedMilliseconds}ms');

    if (result != null && result.entries.isNotEmpty) {
      dictRepo.cacheSearchResult(cacheKey, result);
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
    if (!Platform.isAndroid) return;
    if (isFirstTimeSetup) {
      HibikiToast.show(
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

    if ((_androidDeviceInfo?.version.sdkInt ?? 0) >= 30) {
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
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => adaptiveAlertDialog(
        context: context,
        title: Text(t.error_ankidroid_api),
        content: Text(
          t.error_ankidroid_api_content,
        ),
        actions: [
          adaptiveDialogAction(
            context: context,
            child: Text(t.dialog_launch_ankidroid),
            onPressed: () async {
              final navigator = Navigator.of(context);
              if (Platform.isAndroid) {
                await LaunchApp.openApp(
                  androidPackageName: 'com.ichi2.anki',
                  openStore: true,
                );
              }
              navigator.pop();
            },
          ),
          adaptiveDialogAction(
            context: context,
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
    if (!Platform.isAndroid) return;
    await methodChannel.invokeMethod('requestAnkidroidPermissions');
  }

  /// Adds the default 'hibiki Kinomoto' model to the list of Anki card types.
  Future<void> addDefaultModelIfMissing() async {
    if (!Platform.isAndroid) return;
    List<String> models = await getModelList();
    if (!models.contains('Lapis')) {
      methodChannel.invokeMethod('addDefaultModel');
      final ctx = _ctx;
      if (ctx == null || !ctx.mounted) return;
      await showAppDialog(
        context: ctx,
        builder: (context) => adaptiveAlertDialog(
          context: context,
          title: Text(t.info_standard_model),
          content: Text(
            t.info_standard_model_content,
          ),
          actions: [
            adaptiveDialogAction(
              context: context,
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

    if (ReaderHibikiSource.instance.keepScreenAwake) {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (item != null && mediaSource.implementsHistory) {
      addMediaItem(item);
    }

    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    if (pushReplacement) {
      await Navigator.pushReplacement(
        ctx,
        adaptivePageRoute(
          builder: (context) => mediaSource.buildLaunchPage(
              item: item, initialBookmarkJump: initialBookmarkJump),
        ),
      );
    } else {
      await Navigator.push(
        ctx,
        adaptivePageRoute(
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
    try {
      await WakelockPlus.disable();
    } catch (_) {}
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
    final ctx = _ctx;
    if (ctx == null) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => OpenStashDialogPage(
        onSelect: onSelect,
        onSearch: onSearch,
      ),
    );
  }

  Future<void> openPopupDictionaryLookup({
    required String searchTerm,
  }) async {
    final String trimmed = searchTerm.trim();
    if (trimmed.isEmpty) return;
    if (!Platform.isAndroid) {
      final ctx = _ctx;
      if (ctx == null || !ctx.mounted) return;
      await showAppDialog(
        context: ctx,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 520,
              maxHeight: 640,
            ),
            child: PopupDictionaryPage(
              searchTerm: trimmed,
              closeInApp: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
      );
      return;
    }
    final Uri uri = Uri(
      scheme: 'hibiki',
      host: 'lookup',
      queryParameters: {'word': trimmed},
    );
    final bool launched = await launchUrl(uri);
    if (!launched) {
      debugPrint('[hibiki] Failed to launch popup dictionary for: $trimmed');
    }
  }

  /// A helper function for opening a text segmentation dialog.
  Future<void> openTextSegmentationDialog({
    required String sourceText,
    List<String>? segmentedText,
    Function(HibikiTextSelection)? onSelect,
    Function(HibikiTextSelection)? onSearch,
  }) async {
    if (sourceText.trim().isEmpty) {
      return;
    }

    segmentedText ??= targetLanguage.textToWords(sourceText);
    final ctx = _ctx;
    if (ctx == null) return;
    await showAppDialog(
      context: ctx,
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
    final ctx = _ctx;
    if (ctx == null) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => ExampleSentencesDialogPage(
        exampleSentences: exampleSentences,
        onSelect: onSelect,
        onAppend: onAppend,
      ),
    );
  }

  // ── search history & stash (delegated to MediaHistoryRepository) ────

  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) =>
      mediaHistoryRepo.addToSearchHistory(
          historyKey: historyKey, searchTerm: searchTerm);

  Future<void> removeFromSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) =>
      mediaHistoryRepo.removeFromSearchHistory(
          historyKey: historyKey, searchTerm: searchTerm);

  void clearSearchHistory({required String historyKey}) =>
      mediaHistoryRepo.clearSearchHistory(historyKey: historyKey);

  List<String> getSearchHistory({required String historyKey}) =>
      mediaHistoryRepo.getSearchHistory(historyKey: historyKey);

  bool isTermInSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) =>
      mediaHistoryRepo.isTermInSearchHistory(
          historyKey: historyKey, searchTerm: searchTerm);

  void addToStash({required List<String> terms}) {
    if (terms.isEmpty) return;
    if (!terms.any((t) => t.trim().isNotEmpty)) return;

    mediaHistoryRepo.addToStashData(terms: terms);

    if (terms.length == 1) {
      HibikiToast.show(
        msg: t.stash_added_single(term: terms.first),
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    } else {
      HibikiToast.show(
        msg: t.stash_added_multiple,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    }
  }

  Future<void> removeFromStash({required String term}) async {
    await mediaHistoryRepo.removeFromStashData(term: term);
    HibikiToast.show(
      msg: t.stash_clear_single(term: term),
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }

  void clearStash() => mediaHistoryRepo.clearStash();
  List<String> getStash() => mediaHistoryRepo.getStash();
  bool isTermInStash(String searchTerm) =>
      mediaHistoryRepo.isTermInStash(searchTerm);

  /// Shown when a query fails to be made to an online service. For example,
  /// when there is no internet connection.
  void showFailedToCommunicateMessage() {
    HibikiToast.show(
      msg: t.failed_online_service,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }

  void updateDictionaryResultScrollIndex({
    required DictionarySearchResult result,
    required int newIndex,
  }) =>
      dictRepo.updateDictionaryResultScrollIndex(
          result: result, newIndex: newIndex);

  Future<void> clearDictionaryHistory() async {
    await dictRepo.clearDictionaryHistory();
    dictionaryEntriesNotifier.notifyListeners();
  }

  // ── media item CRUD (delegated to MediaHistoryRepository) ───────────

  void addMediaItem(MediaItem item) => mediaHistoryRepo.addMediaItem(item);

  void updateMediaItem(MediaItem item) =>
      mediaHistoryRepo.updateMediaItem(item);

  void removeFromReadingList(String mediaIdentifier) =>
      mediaHistoryRepo.removeFromReadingList(mediaIdentifier);

  Future<void> deleteMediaItem(MediaItem item) async {
    MediaSource mediaSource = item.getMediaSource(appModel: this);
    await mediaSource.clearOverrideValues(appModel: this, item: item);
    await mediaSource.onMediaItemClear(item);
    await mediaHistoryRepo.deleteMediaItemById(item);
  }

  /// Copies a [term] to clipboard and shows an appropriate toast.
  void copyToClipboard(String term) {
    FlutterClipboard.copy(term);

    /// Redundant to do this with the share notification on Android 33+
    if (!Platform.isAndroid || (_androidDeviceInfo?.version.sdkInt ?? 0) < 33) {
      HibikiToast.show(
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

  List<MediaItem> getMediaTypeHistory({required MediaType mediaType}) =>
      mediaHistoryRepo.getMediaTypeHistory(mediaTypeKey: mediaType.uniqueKey);

  List<MediaItem> getMediaSourceHistory({required MediaSource mediaSource}) =>
      mediaHistoryRepo.getMediaSourceHistory(
          mediaSourceKey: mediaSource.uniqueKey);

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

    if (Platform.isAndroid) {
      List<String> paths =
          (await ExternalPath.getExternalStorageDirectories()) ?? [];
      for (String path in paths) {
        Directory directory = Directory(path);
        if (!directories.contains(directory)) {
          directories.add(directory);
        }
      }
    }

    return directories;
  }

  // ── blur options & audio index (delegated) ───────────────────────────

  BlurOptions get blurOptions => prefsRepo.blurOptions;
  Future<void> setBlurOptions(BlurOptions options) =>
      prefsRepo.setBlurOptions(options);

  int getMediaItemPreferredAudioIndex(MediaItem item) =>
      prefsRepo.getMediaItemPreferredAudioIndex(item.uniqueKey);

  void setMediaItemPreferredAudioIndex(MediaItem item, int index) =>
      prefsRepo.setMediaItemPreferredAudioIndex(item.uniqueKey, index);

  // ── player preferences (delegated to PreferencesRepository) ─────────

  bool get isPlayerListeningComprehensionMode =>
      prefsRepo.isPlayerListeningComprehensionMode;
  void togglePlayerListeningComprehensionMode() =>
      prefsRepo.togglePlayerListeningComprehensionMode();

  bool get isPlayerOrientationPortrait => prefsRepo.isPlayerOrientationPortrait;
  void togglePlayerOrientationPortrait() =>
      prefsRepo.togglePlayerOrientationPortrait();

  bool get isStretchToFill => prefsRepo.isStretchToFill;
  void toggleStretchToFill() => prefsRepo.toggleStretchToFill();

  bool get playerHardwareAcceleration => prefsRepo.playerHardwareAcceleration;
  void setPlayerHardwareAcceleration({required bool value}) =>
      prefsRepo.setPlayerHardwareAcceleration(value: value);

  bool get playerBackgroundPlay => prefsRepo.playerBackgroundPlay;
  void setPlayerBackgroundPlay({required bool value}) =>
      prefsRepo.setPlayerBackgroundPlay(value: value);

  bool get showSubtitlesInNotification => prefsRepo.showSubtitlesInNotification;
  void setShowSubtitlesInNotification({required bool value}) =>
      prefsRepo.setShowSubtitlesInNotification(value: value);

  bool get playerUseOpenSLES => prefsRepo.playerUseOpenSLES;
  void setPlayerUseOpenSLES({required bool value}) =>
      prefsRepo.setPlayerUseOpenSLES(value: value);

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
  HibikiAudioHandler? get audioHandler => _audioHandler;
  HibikiAudioHandler? _audioHandler;

  /// Initialises the audio service.
  Future<void> initialiseAudioHandler() async {
    if (_audioHandler != null) {
      return;
    }

    try {
      _audioHandler = await ag.AudioService.init<HibikiAudioHandler>(
        builder: () => HibikiAudioHandler(
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
    } catch (e) {
      debugPrint('[Hibiki] AudioService.init failed (non-fatal): $e');
      _audioHandler = HibikiAudioHandler(
        onPlayPause: () => _playStreamController.add(null),
        onSeek: (position) => _seekStreamController.add(position),
        onRewind: () => _rewindStreamController.add(null),
        onFastForward: () => _fastForwardStreamController.add(null),
        onSkipToNext: () => _skipNextStreamController.add(null),
        onSkipToPrevious: () => _skipPreviousStreamController.add(null),
      );
    }
  }

  // ── search & dictionary display (delegated to PreferencesRepository) ─

  bool get autoSearchEnabled => prefsRepo.autoSearchEnabled;
  void toggleAutoSearchEnabled() => prefsRepo.toggleAutoSearchEnabled();

  int get defaultSearchDebounceDelay => prefsRepo.defaultSearchDebounceDelay;
  int get searchDebounceDelay => prefsRepo.searchDebounceDelay;
  void setSearchDebounceDelay(int debounceDelay) =>
      prefsRepo.setSearchDebounceDelay(debounceDelay);

  double get defaultDictionaryFontSize => prefsRepo.defaultDictionaryFontSize;
  double get dictionaryFontSize => prefsRepo.dictionaryFontSize;
  void setDictionaryFontSize(double fontSize) =>
      prefsRepo.setDictionaryFontSize(fontSize);

  double get defaultPopupMaxWidth => prefsRepo.defaultPopupMaxWidth;
  double get popupMaxWidth => prefsRepo.popupMaxWidth;
  void setPopupMaxWidth(double width) => prefsRepo.setPopupMaxWidth(width);

  int get defaultDoubleTapSeekDuration =>
      prefsRepo.defaultDoubleTapSeekDuration;
  int get doubleTapSeekDuration => prefsRepo.doubleTapSeekDuration;
  void setDoubleTapSeekDuration(int value) =>
      prefsRepo.setDoubleTapSeekDuration(value);

  bool get isFirstTimeSetup => prefsRepo.isFirstTimeSetup;
  void setFirstTimeSetupFlag() => prefsRepo.setFirstTimeSetupFlag();

  int get maximumTerms => prefsRepo.maximumTerms;
  void setMaximumTerms(int value) => prefsRepo.setMaximumTerms(value);

  void addToDictionaryHistory({required DictionarySearchResult result}) {
    MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
    if (mediaType != DictionaryMediaType.instance) {
      shouldRefreshTabs = true;
      ScrollController scrollController =
          DictionaryMediaType.instance.scrollController;
      if (scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
    }

    dictRepo.addHistoryResult(result, maximumDictionaryHistoryItems);
  }

  /// Check if the database is still open.
  bool get isDatabaseOpen => _isInitialised;

  /// Direct access to the Drift database instance.
  HibikiDatabase get database => _database;

  /// Safely shutdown and stop database operations.
  void shutdown() async {
    databaseCloseNotifier.notifyListeners();
    await _database.close();
    if (Platform.isAndroid || Platform.isIOS) {
      FlutterExitApp.exitApp();
    } else {
      exit(0);
    }
  }

  Future<void> closeForPopup() async {
    _prefsRepo?.removeListener(notifyListeners);
    databaseCloseNotifier.notifyListeners();
    await _database.close();
    HoshiDicts.disposeInstance();
  }

  @override
  void dispose() {
    _prefsRepo?.removeListener(notifyListeners);
    dictionaryEntriesNotifier.dispose();
    dictionarySearchAgainNotifier.dispose();
    dictionaryMenuNotifier.dispose();
    incognitoNotifier.dispose();
    databaseCloseNotifier.dispose();
    _currentMediaPauseController.close();
    _playPauseHeadsetActionStreamController.close();
    _creatorActiveController.close();
    _playStreamController.close();
    _seekStreamController.close();
    _rewindStreamController.close();
    _fastForwardStreamController.close();
    _skipNextStreamController.close();
    _skipPreviousStreamController.close();
    super.dispose();
  }

  static const _lifecycleChannel = HibikiChannels.lifecycle;

  Future<void> moveToBack() async {
    if (!Platform.isAndroid) return;
    try {
      await _lifecycleChannel.invokeMethod<void>('moveTaskToBack');
    } catch (e, stack) {
      ErrorLogService.instance.log('AppModel.moveToBack', e, stack);
      debugPrint('[Hibiki] moveToBack failed: $e');
    }
  }

  // ── transcript, tags, card export, CSS (delegated) ──────────────────

  bool get isTranscriptPlayerMode => prefsRepo.isTranscriptPlayerMode;
  void toggleTranscriptPlayerMode() => prefsRepo.toggleTranscriptPlayerMode();

  bool get isTranscriptOpaque => prefsRepo.isTranscriptOpaque;
  void toggleTranscriptOpaque() => prefsRepo.toggleTranscriptOpaque();

  bool get subtitleTimingsShown => prefsRepo.subtitleTimingsShown;
  void toggleSubtitleTimingsShown() => prefsRepo.toggleSubtitleTimingsShown();

  String get savedTags => prefsRepo.savedTags;
  void setSavedTags(String value) => prefsRepo.setSavedTags(value);

  bool get autoAddBookNameToTags => prefsRepo.autoAddBookNameToTags;
  void toggleAutoAddBookNameToTags() => prefsRepo.toggleAutoAddBookNameToTags();

  bool get deduplicatePitchAccents => prefsRepo.deduplicatePitchAccents;
  void toggleDeduplicatePitchAccents() =>
      prefsRepo.toggleDeduplicatePitchAccents();

  bool get harmonicFrequency => prefsRepo.harmonicFrequency;
  void toggleHarmonicFrequency() => prefsRepo.toggleHarmonicFrequency();

  bool get showExpressionTags => prefsRepo.showExpressionTags;
  void toggleShowExpressionTags() => prefsRepo.toggleShowExpressionTags();

  bool get collapseDictionaries => prefsRepo.collapseDictionaries;
  void toggleCollapseDictionaries() => prefsRepo.toggleCollapseDictionaries();

  Map<String, String> get customDictCSS => prefsRepo.customDictCSS;
  String getCustomCSSForDict(String dictName) =>
      prefsRepo.getCustomCSSForDict(dictName);
  Future<void> setCustomCSSForDict(String dictName, String css) =>
      prefsRepo.setCustomCSSForDict(dictName, css);

  String get globalDictCSS => prefsRepo.globalDictCSS;
  Future<void> setGlobalDictCSS(String css) => prefsRepo.setGlobalDictCSS(css);

  // ── audio sources (delegated) ────────────────────────────────────────

  static const List<String> defaultAudioSources =
      PreferencesRepository.defaultAudioSources;

  List<String> get audioSources => prefsRepo.audioSources;

  List<String> get enabledAudioSources {
    final List<String> sources = audioSources
        .where((source) => source != WordAudioResolver.localAudioUrl)
        .toList(growable: false);
    if (!localAudioEnabled) return sources;

    return <String>[
      WordAudioResolver.localAudioUrl,
      ...sources,
    ];
  }

  void setAudioSources(List<String> sources) =>
      prefsRepo.setAudioSources(sources);

  /// All local audio database entries (multi-DB support).
  List<LocalAudioDbEntry> get localAudioDbs {
    final String raw = _getPref('local_audio_dbs', defaultValue: '');
    if (raw.isEmpty) {
      // Migrate old single-DB preference
      final String oldPath = _getPref('local_audio_db_path', defaultValue: '');
      if (oldPath.isNotEmpty) {
        final String oldName =
            _getPref('local_audio_db_display_name', defaultValue: '');
        return [LocalAudioDbEntry(path: oldPath, displayName: oldName)];
      }
      return [];
    }
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((dynamic e) =>
              LocalAudioDbEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> setLocalAudioDbs(List<LocalAudioDbEntry> dbs) async {
    await _setPref(
        'local_audio_dbs', jsonEncode(dbs.map((e) => e.toJson()).toList()));
    // Clear legacy single-DB prefs after migration
    await _setPref('local_audio_db_path', '');
    await _setPref('local_audio_db_display_name', '');
    await TtsChannel.instance.setLocalAudioDbs(
        dbs.where((e) => e.enabled).map((e) => e.path).toList());
  }

  Future<void> toggleLocalAudioDbEnabled(int index) async {
    final List<LocalAudioDbEntry> dbs =
        List<LocalAudioDbEntry>.of(localAudioDbs);
    if (index < 0 || index >= dbs.length) return;
    dbs[index] = dbs[index].copyWith(enabled: !dbs[index].enabled);
    await setLocalAudioDbs(dbs);
  }

  Future<void> addLocalAudioDb(String sourcePath,
      {required String displayName}) async {
    final String internalName =
        'local_audio_${DateTime.now().millisecondsSinceEpoch}.db';
    final String internalPath =
        path.join(_databaseDirectory.path, internalName);
    final File sourceFile = File(sourcePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(internalPath);
    }
    final List<LocalAudioDbEntry> dbs =
        List<LocalAudioDbEntry>.of(localAudioDbs);
    dbs.add(LocalAudioDbEntry(path: internalPath, displayName: displayName));
    await setLocalAudioDbs(dbs);
  }

  Future<void> removeLocalAudioDb(int index) async {
    final List<LocalAudioDbEntry> dbs =
        List<LocalAudioDbEntry>.of(localAudioDbs);
    if (index < 0 || index >= dbs.length) return;
    final LocalAudioDbEntry entry = dbs.removeAt(index);
    for (final String suffix in ['', '-wal', '-shm']) {
      final File f = File('${entry.path}$suffix');
      if (await f.exists()) await f.delete();
    }
    await setLocalAudioDbs(dbs);
  }

  Future<void> reorderLocalAudioDbs(int oldIndex, int newIndex) async {
    final List<LocalAudioDbEntry> dbs =
        List<LocalAudioDbEntry>.of(localAudioDbs);
    if (newIndex > oldIndex) newIndex--;
    final LocalAudioDbEntry entry = dbs.removeAt(oldIndex);
    dbs.insert(newIndex, entry);
    await setLocalAudioDbs(dbs);
  }

  /// Backward-compatible getter for the first DB path.
  @Deprecated('Use localAudioDbs instead')
  String get localAudioDbPath {
    final List<LocalAudioDbEntry> dbs = localAudioDbs;
    return dbs.isNotEmpty ? dbs.first.path : '';
  }

  /// Backward-compatible getter for the first DB display name.
  @Deprecated('Use localAudioDbs instead')
  String get localAudioDbDisplayName {
    final List<LocalAudioDbEntry> dbs = localAudioDbs;
    return dbs.isNotEmpty ? dbs.first.displayName : '';
  }

  @Deprecated('Use addLocalAudioDb instead')
  Future<void> setLocalAudioDbPath(String sourcePath,
      {required String displayName}) async {
    await clearLocalAudioDb();
    await addLocalAudioDb(sourcePath, displayName: displayName);
  }

  @Deprecated('Use removeLocalAudioDb instead')
  Future<void> clearLocalAudioDb() async {
    final List<LocalAudioDbEntry> dbs = localAudioDbs;
    for (int i = dbs.length - 1; i >= 0; i--) {
      await removeLocalAudioDb(i);
    }
  }

  bool get localAudioEnabled {
    return _getPref('local_audio_enabled', defaultValue: false);
  }

  void toggleLocalAudio() async {
    await _setPref('local_audio_enabled', !localAudioEnabled);
    if (localAudioEnabled) {
      final List<String> paths =
          localAudioDbs.where((e) => e.enabled).map((e) => e.path).toList();
      if (paths.isNotEmpty) {
        TtsChannel.instance.setLocalAudioDbs(paths);
      }
    } else {
      TtsChannel.instance.setLocalAudioDbs(<String>[]);
    }
    notifyListeners();
  }

  // ── UI visibility (delegated) ────────────────────────────────────────

  bool get showPlayBar => prefsRepo.showPlayBar;
  void toggleShowPlayBar() => prefsRepo.toggleShowPlayBar();

  bool get showMediaNotification => prefsRepo.showMediaNotification;
  void toggleShowMediaNotification() => prefsRepo.toggleShowMediaNotification();
  Future<void> setShowMediaNotification(bool value) =>
      prefsRepo.setShowMediaNotification(value);

  bool get showFloatingLyric => prefsRepo.showFloatingLyric;
  Future<void> setShowFloatingLyric(bool value) =>
      prefsRepo.setShowFloatingLyric(value);

  double get floatingLyricFontSize => prefsRepo.floatingLyricFontSize;
  Future<void> setFloatingLyricFontSize(double value) =>
      prefsRepo.setFloatingLyricFontSize(value);

  bool get showFloatingDict => prefsRepo.showFloatingDict;

  Future<void> setShowFloatingDict(bool value) async {
    await prefsRepo.setPref('show_floating_dict', value);
    prefsRepo.notifyListeners();
  }

  void _setupFloatingDictHandlers() {
    FloatingDictChannel.setEventHandlers(
      onSearch: (String term) async {
        final DictionarySearchResult result = await searchDictionary(
          searchTerm: term,
          searchWithWildcards: false,
        );
        return result;
      },
      onAnkiExport: (String word, String reading, String meaning) async {
        debugPrint('[FloatingDict] Anki export: $word / $reading');
        HibikiToast.show(
          msg: t.anki_export_not_implemented,
          toastLength: Toast.LENGTH_SHORT,
        );
      },
    );
  }

  // ── update preferences (delegated) ───────────────────────────────────

  bool get updateNeverRemind => prefsRepo.updateNeverRemind;
  Future<void> setUpdateNeverRemind(bool value) =>
      prefsRepo.setUpdateNeverRemind(value);

  bool get updateAutoInstall => prefsRepo.updateAutoInstall;
  Future<void> setUpdateAutoInstall(bool value) =>
      prefsRepo.setUpdateAutoInstall(value);

  bool get updateBetaChannel => prefsRepo.updateBetaChannel;
  Future<void> setUpdateBetaChannel(bool value) =>
      prefsRepo.setUpdateBetaChannel(value);

  bool get updateDebugChannel => prefsRepo.updateDebugChannel;
  Future<void> setUpdateDebugChannel(bool value) =>
      prefsRepo.setUpdateDebugChannel(value);

  bool get populateBookmarksFlag => prefsRepo.populateBookmarksFlag;
  void setPopulateBookmarksFlag() => prefsRepo.setPopulateBookmarksFlag();

  // ── low memory mode (side effect stays here) ─────────────────────────

  bool get lowMemoryMode => prefsRepo.lowMemoryMode;

  Future<void> setLowMemoryMode(bool v) async {
    await prefsRepo.setPref('low_memory_mode', v);
    _applyMemoryPolicy();
    notifyListeners();
  }

  void _applyMemoryPolicy() {
    final imageCache = PaintingBinding.instance.imageCache;
    if (lowMemoryMode) {
      imageCache.maximumSize = 50;
      imageCache.maximumSizeBytes = 20 << 20; // 20 MB
    } else {
      imageCache.maximumSize = 1000;
      imageCache.maximumSizeBytes = 100 << 20; // 100 MB
    }
  }

  static bool _isMemoryError(Object e) {
    final msg = e.toString().toLowerCase();
    return e is OutOfMemoryError || msg.contains('out of memory');
  }
}
