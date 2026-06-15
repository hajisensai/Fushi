import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_to_file_image/network_to_file_image.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as path;

/// 一个 [MediaSource] 偏好在 Drift `preferences` 表里的命名空间化 key：
/// `src:<sourceId>:<key>`。这是该格式的**单一真相源**——`MediaSource._dbPrefKey`
/// 与跨层重建旧 reader 源偏好的 [ProfileRepository.applyProfile] 都调它，避免上层
/// 服务硬编码 `src:reader_ttu:...` 字符串来猜下层私有 key 格式（历史耦合）。
///
/// ⚠️ 这是持久化 key 编码：格式绝不能变（变了即丢用户偏好，never break userspace），
/// `reader_ttu` 等历史 sourceId 是冻结值。守卫测试断言其输出逐字节等于旧字符串。
String dbSourcePrefKey(String sourceId, String key) => 'src:$sourceId:$key';

/// A source for a [MediaType] that will appear on the list of sources when
/// set as active. Handles sourcing and delivery of arguments such that the
/// [MediaType] is able to execute and launch with the proper arguments.
abstract class MediaSource {
  /// Initialise a media source.
  MediaSource({
    required this.uniqueKey,
    required this.sourceName,
    required this.description,
    required this.mediaType,
    required this.icon,
    required this.implementsSearch,
    required this.implementsHistory,
    this.overridesAutoImage = false,
    this.overridesAutoAudio = false,
  });

  /// A unique name that allows distinguishing this type from others,
  /// particularly for the purposes of differentiating between persistent
  /// settings keys.
  final String uniqueKey;

  /// Name of the source that very shortly describes what it does.
  final String sourceName;

  /// The media type that this source is for.
  final MediaType mediaType;

  /// A longer description of what the source can do, or details left by or
  /// regarding the developer.
  final String description;

  /// An icon that will show the enhancement if activated by the user in the
  /// quick menu.
  final IconData icon;

  /// Localisations for this source, where the key is a locale tag and
  /// the value is the [sourceName] of the source. If the value for the current
  /// locale is non-null, it will be used instead of [sourceName].
  final Map<String, String> sourceNameLocalisatiton = const {};

  /// Localisations for this source, where the key is a locale tag and
  /// the value is the [description] of the enhancement. If the value for the
  /// current locale is non-null, it will be used instead of [description].
  final Map<String, String> descriptionLocalisation = const {};

  /// Whether or not this media source has a search function. If false, this
  /// media source will have an action executed by [onSearchBarTap].
  final bool implementsSearch;

  /// Whether or not this media source allows adding items to media history.
  /// Note that some media sources produce a history of media items but do
  /// not require this to be set true. For example, the reader fetches its
  /// history from a source other than the actual internal media history
  /// system provided by the media source framework. In such cases, this
  /// should be set as false. Setting this as true results to a media item
  /// being added to history when media is opened.
  final bool implementsHistory;

  /// Whether or not a media source overrides the auto image enhancement.
  /// See [generateImages].
  final bool overridesAutoImage;

  /// Whether or not a media source overrides the auto audio enhancement.
  /// See [generateAudio].
  final bool overridesAutoAudio;

  /// Shared database reference, set once by [AppModel.initialise] before
  /// any source is initialised.
  static HibikiDatabase? _sharedDb;

  /// Call from [AppModel.initialise] before initialising media sources.
  static void setDatabase(HibikiDatabase db) => _sharedDb = db;

  /// Shared database for subclasses that persist beyond the preference cache
  /// (e.g. ReaderHibikiSource writing back epubBooks.author for BUG-220). Null
  /// until [setDatabase] runs in [AppModel.initialise].
  @protected
  HibikiDatabase? get sharedDatabase => _sharedDb;

  /// In-memory preference cache for this source. Loaded from the Drift
  /// database on [initialise] and written through on [setPreference].
  final Map<String, dynamic> _preferences = {};

  /// Whether or not [initialise] has been called for this source.
  bool _initialised = false;

  String _dbPrefKey(String key) => dbSourcePrefKey(uniqueKey, key);

  /// This function is run at startup. It is not called again if already run.
  Future<void> initialise() async {
    if (_initialised) {
      return;
    } else {
      await _loadPreferencesFromDb();
      await prepareResources();
      _initialised = true;
    }
  }

  Future<void> _loadPreferencesFromDb() async {
    final db = _sharedDb;
    if (db == null) return;
    // Clear first so keys deleted by a profile switch (applyProfile deletes
    // pref rows absent from the new profile) don't survive as stale cache
    // entries. Every in-memory pref is written through to the DB on set, so
    // nothing is lost by reloading from the authoritative DB state.
    _preferences.clear();
    final prefix = dbSourcePrefKey(uniqueKey, '');
    final all = await db.getAllPrefs();
    for (final entry in all.entries) {
      if (entry.key.startsWith(prefix)) {
        final shortKey = entry.key.substring(prefix.length);
        _preferences[shortKey] = PrefCodec.decodeUntyped(entry.value);
      }
    }
  }

  /// Reload preferences from the database, e.g. after a profile switch.
  Future<void> refreshPreferencesFromDb() async {
    await _loadPreferencesFromDb();
  }

  /// Get the preference value for a certain parameter [key] for this source.
  T getPreference<T>({required String key, required T defaultValue}) {
    final value = _preferences[key];
    if (value is T) return value;
    if (T == double && value is int) return value.toDouble() as T;
    setPreference(key: key, value: defaultValue);
    return defaultValue;
  }

  /// Set the preference [value] for a certain parameter [key] for this source.
  Future<void> setPreference<T>({required String key, required T value}) async {
    _preferences[key] = value;
    final db = _sharedDb;
    if (db != null) {
      try {
        await db.setPref(_dbPrefKey(key), PrefCodec.encode(value));
      } catch (e, stack) {
        ErrorLogService.instance.log('MediaSource.setPref', e, stack);
        debugPrint('[MediaSource] setPref write-through err: $e');
      }
    }
  }

  /// Delete the preference for a certain parameter [key] for this source.
  Future<void> deletePreference({required String key}) async {
    _preferences.remove(key);
    final db = _sharedDb;
    if (db != null) {
      try {
        await db.deletePref(_dbPrefKey(key));
      } catch (e, stack) {
        ErrorLogService.instance.log('MediaSource.deletePref', e, stack);
        debugPrint('[MediaSource] deletePref write-through err: $e');
      }
    }
  }

  /// Get the best localisation for the label of this media source. If there
  /// is no localisation, the fallback is [sourceName].
  String getLocalisedSourceName(AppModel appModel) {
    return sourceNameLocalisatiton[appModel.appLocale.toLanguageTag()] ??
        sourceName;
  }

  /// Get the best localisation for the description of this media source. If
  /// there is no localisation, the fallback is [description].
  String getLocalisedDescription(AppModel appModel) {
    return descriptionLocalisation[appModel.appLocale.toLanguageTag()] ??
        description;
  }

  /// If a media source requires resources to function, they can be prepared
  /// here and this function will be run once only at runtime during the
  /// initialisation step.
  Future<void> prepareResources() async {}

  /// Executed when this media source is closed. Perform this step to clean up
  /// resources or refresh media history.
  Future<void> onSourceExit({
    required AppModel appModel,
    required WidgetRef ref,
  }) async {}

  /// Get the floating search bar actions of this source when it is the active
  /// source being displayed on its respective media type tab.
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [];
  }

  /// The widget to show when this source is launched. An optional [MediaItem]
  /// can be supplied as a launch parameter.
  ///
  /// Returns a plain [Widget] (not [BaseSourcePage]) so an implementation may
  /// wrap its page in a non-page widget (e.g. the reader wraps it in a
  /// [HibikiAppUiScaleNeutralizer] so the WebView renders at native density).
  /// The only caller feeds this straight into a [WidgetBuilder], so the wider
  /// return type is contract-compatible.
  Widget buildLaunchPage({MediaItem? item, Bookmark? initialBookmarkJump});

  /// If this is not null, this action is executed when the user taps on the
  /// search bar. Sources that do not have a search action should have this
  /// defined.
  Future<void> onSearchBarTap({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) async {
    appModel.openMedia(
      ref: ref,
      mediaSource: this,
    );
  }

  /// This function can be used to clean up resources associated with a
  /// media item upon clearing it.
  Future<void> onMediaItemClear(MediaItem item) async {}

  /// Supplies a sentence that can be used for the sentence field when making
  /// a card while this source is active. Can be set with [setCurrentSentence]
  /// and [clearCurrentSentence] in a source page.
  HibikiTextSelection get currentSentence => _currentSentence;
  HibikiTextSelection _currentSentence = HibikiTextSelection(
    text: '',
  );

  /// Update the current sentence.
  void setCurrentSentence({
    required HibikiTextSelection selection,
  }) {
    _currentSentence = selection;
  }

  /// Clear the current sentence.
  void clearCurrentSentence() {
    _currentSentence = HibikiTextSelection(
      text: '',
    );
  }

  /// Full subtitle-cue text (not punctuation-segmented).
  HibikiTextSelection get currentCueSentence => _currentCueSentence;
  HibikiTextSelection _currentCueSentence = HibikiTextSelection(
    text: '',
  );

  void setCurrentCueSentence({
    required HibikiTextSelection selection,
  }) {
    _currentCueSentence = selection;
  }

  void clearCurrentCueSentence() {
    _currentCueSentence = HibikiTextSelection(
      text: '',
    );
  }

  /// This is used to hold data for generating images and audio.
  String? get currentExtraData => _currentExtraData;
  String? _currentExtraData;

  /// Set extra export data. This should be simplified in the future and be
  /// used as the main way of communicating parameters to the creator for
  /// creating override images/audio information. There should not be media
  /// source specific parameters for general functions like generating images
  /// or audio.
  void setExtraData(String? value) {
    _currentExtraData = value;
  }

  /// Clear extra export data.
  void clearExtraData() {
    _currentExtraData = null;
  }

  /// Gets whether or not a media source should currently supply images.
  bool get shouldGenerateImage => _shouldGenerateImage;
  bool _shouldGenerateImage = true;

  /// Gets whether or not a media source should currently supply audio.
  bool get shouldGenerateAudio => _shouldGenerateAudio;
  bool _shouldGenerateAudio = true;

  /// Controls whether or not a media source should currently supply images.
  void setShouldGenerateImage({required bool value}) {
    _shouldGenerateImage = value;
  }

  /// Controls whether or not a media source should currently supply audio.
  void setShouldGenerateAudio({required bool value}) {
    _shouldGenerateAudio = value;
  }

  /// Supplies a media item that can be used for tracking and updating history,
  /// as well as generating video and audio with timestamp information. This
  /// should be uniquely implemented for each source. Some sources may want
  /// to generate their media item based on current playback information or
  /// progress.
  ///
  /// HBK-AUDIT-123: the base default is an UnsupportedError rather than a bare
  /// UnimplementedError so a contract violation names the source and the method
  /// that was not overridden, instead of surfacing an opaque runtime trap.
  MediaItem get currentMediaItem => throw UnsupportedError(
      '$runtimeType does not implement currentMediaItem');

  /// The body widget to show in the tab when this source's media type and this
  /// source is selected.
  BasePage buildHistoryPage();

  /// Given a [MediaItem], return its title. Some media items may allow
  /// overriding of values for display purposes. If a source does this,
  /// override this function.
  String getDisplayTitleFromMediaItem(MediaItem item) {
    String? overrideTitle = getOverrideTitleFromMediaItem(item);
    if (overrideTitle != null) {
      return overrideTitle;
    }

    return item.title;
  }

  /// Given a [MediaItem], return its subtitle. Some media items may allow
  /// overriding of values for display purposes. If a source does this,
  /// override this function.
  String getDisplaySubtitleFromMediaItem(MediaItem item) {
    return item.mediaIdentifier;
  }

  /// Given a [MediaItem], return its thumbnail. Some media items may allow
  /// overriding of values for display purposes.
  ImageProvider<Object> getDisplayThumbnailFromMediaItem({
    required AppModel appModel,
    required MediaItem item,
    String? fallbackUrl,
    bool noOverride = false,
  }) {
    ImageProvider<Object>? overrideThumbnail =
        getOverrideThumbnailFromMediaItem(
      appModel: appModel,
      item: item,
    );

    if (!noOverride && overrideThumbnail != null) {
      return overrideThumbnail;
    }

    if (item.imageUrl != null) {
      if (item.imageUrl!.startsWith('file://')) {
        final String filePath = Uri.parse(item.imageUrl!).toFilePath();
        return FileImage(File(filePath));
      } else {
        return CachedNetworkImageProvider(
          fallbackUrl ?? item.imageUrl!,
          cacheKey: item.uniqueKey,
        );
      }
    }

    if (item.base64Image == null) {
      return MemoryImage(kTransparentImage);
    }

    UriData? data = Uri.parse(item.base64Image!).data;
    if (data != null) {
      /// A cached version of [MemoryImage] so that the image does not reload
      /// on every revisit
      return CacheImageProvider(item.uniqueKey, data.contentAsBytes());
    } else {
      return MemoryImage(kTransparentImage);
    }
  }

  /// Given a [MediaItem], return its thumbnail. Some media items may allow
  /// overriding of values for display purposes.
  String getThumbnailUri({
    required AppModel appModel,
    required MediaItem item,
    bool noOverride = false,
  }) {
    ImageProvider<Object>? overrideThumbnail =
        getOverrideThumbnailFromMediaItem(
      appModel: appModel,
      item: item,
    );

    if (!noOverride && overrideThumbnail != null) {
      return getOverrideThumbnailFilename(appModel: appModel, item: item);
    }

    if (item.imageUrl != null) {
      return item.imageUrl!;
    }

    if (item.base64Image == null) {
      return '';
    }

    return '';
  }

  /// The map key used to store the override title of an item.
  String getOverrideTitleKey(MediaItem item) {
    return 'override_title://${item.mediaSourceIdentifier}/${item.uniqueKey}';
  }

  /// The map value used to store the override thumbnail of an item.
  String getOverrideThumbnailFilename({
    required AppModel appModel,
    required MediaItem item,
  }) {
    String key =
        '${item.mediaIdentifier}/${item.mediaSourceIdentifier}/override_thumbnail';
    String basename = key.hashCode.toString();
    String filename = path.join(appModel.thumbnailsDirectory.path, basename);

    return filename;
  }

  /// Given a [MediaItem], return its override display title.
  String? getOverrideTitleFromMediaItem(MediaItem item) {
    if (!item.canEdit) {
      return null;
    }

    String key = getOverrideTitleKey(item);
    String? overrideTitle =
        getPreference<String?>(key: key, defaultValue: null);
    return overrideTitle;
  }

  /// Given a [MediaItem], return its override display thumbnail.
  ImageProvider<Object>? getOverrideThumbnailFromMediaItem({
    required AppModel appModel,
    required MediaItem item,
  }) {
    String filename = getOverrideThumbnailFilename(
      appModel: appModel,
      item: item,
    );

    File file = File(filename);
    if (!file.existsSync()) {
      return null;
    }

    return FileImage(file);
  }

  /// Given a [MediaItem], set its override display title. If the title is
  /// blank, the override title is cleared.
  Future<void> setOverrideTitleFromMediaItem({
    required MediaItem item,
    required String? title,
  }) async {
    String key = getOverrideTitleKey(item);
    String? value;
    if (title != null) {
      String trimmedTitle = title.trim();
      if (trimmedTitle.isNotEmpty) {
        value = trimmedTitle;
      }
    }

    await setPreference<String?>(key: key, value: value);
  }

  /// Whether this source lets the user edit a [MediaItem]'s author in the edit
  /// dialog (BUG-220). Default false: the author field is hidden and
  /// [setAuthorFromMediaItem] is a no-op. Sources backing an editable author
  /// column (e.g. EPUB books) override this to true.
  bool get supportsAuthorEdit => false;

  /// Persist a [MediaItem]'s author (BUG-220). Default no-op for sources that do
  /// not support author editing; override alongside [supportsAuthorEdit] to
  /// write the author back to the underlying store. A blank/empty [author]
  /// clears it.
  Future<void> setAuthorFromMediaItem({
    required MediaItem item,
    required String? author,
  }) async {}

  /// Given a [MediaItem], set its override display thumbnail. If null, this
  /// deletes the override thumbnail.
  Future<void> setOverrideThumbnailFromMediaItem({
    required AppModel appModel,
    required MediaItem item,
    required File? file,
    required bool clearOverrideImage,
  }) async {
    String filename = getOverrideThumbnailFilename(
      appModel: appModel,
      item: item,
    );

    File thumbnailFile = File(filename);
    thumbnailFile.createSync(recursive: true);
    if (clearOverrideImage) {
      thumbnailFile.deleteSync();
    } else if (file != null) {
      file.copySync(filename);
    }
  }

  /// Used to clear override values of a [MediaItem] upon deletion.
  Future<void> clearOverrideValues({
    required AppModel appModel,
    required MediaItem item,
  }) async {
    await deletePreference(key: getOverrideTitleKey(item));
    await setOverrideThumbnailFromMediaItem(
      appModel: appModel,
      item: item,
      file: null,
      clearOverrideImage: true,
    );
  }

  /// If this source is non-null, this will be used as the initial function
  /// for the image field over the auto enhancement. Extra durations can be
  /// invoked and defined when initially opening the creator, to call attention
  /// to multiple durations to be used for image generation.
  Future<List<NetworkToFileImage>> generateImages({
    required AppModel appModel,
    required MediaItem item,
    String? data,
  }) {
    // HBK-AUDIT-123: gated by overridesAutoImage; a source that sets that flag
    // must override this. The UnsupportedError names the offending source so
    // the missing override is debuggable rather than an opaque trap.
    throw UnsupportedError(
      '$runtimeType set overridesAutoImage but did not override generateImages',
    );
  }

  /// If this source is non-null, this will be used as the initial function
  /// for the audio field over the auto enhancement.
  Future<File?>? generateAudio({
    required AppModel appModel,
    required MediaItem item,
    String? data,
  }) {
    // HBK-AUDIT-123: gated by overridesAutoAudio; a source that sets that flag
    // must override this. The UnsupportedError names the offending source so
    // the missing override is debuggable rather than an opaque trap.
    throw UnsupportedError(
      '$runtimeType set overridesAutoAudio but did not override generateAudio',
    );
  }

  /// This returns a list of [MediaItem], and is performed to search the media
  /// source for items.
  Future<List<MediaItem>?> searchMediaItems({
    required BuildContext context,
    required String searchTerm,
    required int pageKey,
  }) async {
    // HBK-AUDIT-123: gated by implementsSearch; a source that sets that flag
    // must override this. The UnsupportedError names the offending source so
    // the missing override is debuggable rather than an opaque trap.
    throw UnsupportedError(
      '$runtimeType set implementsSearch but did not override searchMediaItems',
    );
  }

  /// Given a search term, this source may give search suggestions. If the
  /// empty list is returned, then search history will be shown instead.
  ///
  /// HBK-AUDIT-123: suggestions are optional (an empty list already means
  /// "show history"), so the base default returns an empty list instead of
  /// throwing UnimplementedError. This removes a latent unhandled-async-error
  /// surface for any source that implements search but not suggestions.
  Future<List<String>> generateSearchSuggestions(String searchTerm) async {
    return const <String>[];
  }

  /// Aspect ratio of media items.
  double get aspectRatio;
}
