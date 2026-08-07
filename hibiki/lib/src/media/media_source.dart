import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_to_file_image/network_to_file_image.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_audio/fushi_audio.dart';
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
    _preferences[key] = defaultValue;
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
  ///
  /// [navigation] 是库页视图导航条（见 `MediaLibraryShell`）：实现应把它交给自己的
  /// 页面，由页面放进页头 bottom 槽。回退型来源可以忽略它——那只是没有视图切换，
  /// 不影响正确性。
  BasePage buildHistoryPage({Widget? navigation});

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
    if (!noOverride) {
      final ImageProvider<Object>? overrideThumbnail =
          getOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
      );
      if (overrideThumbnail != null) {
        return overrideThumbnail;
      }
    }

    if (item.imageUrl != null) {
      if (item.imageUrl!.startsWith('file://')) {
        final String filePath = Uri.parse(item.imageUrl!).toFilePath();
        // BUG-959: 按物理像素上限解码，避免 EPUB 原始封面(常 1600×2400)整帧撑爆 ImageCache。
        return resizedFileImage(File(filePath));
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
    if (!noOverride) {
      final File? overrideFile = resolveOverrideThumbnailFile(
        appModel: appModel,
        item: item,
      );
      if (overrideFile != null) {
        return overrideFile.path;
      }
    }

    if (item.imageUrl != null) {
      return item.imageUrl!;
    }

    if (item.base64Image == null) {
      return '';
    }

    return '';
  }

  // ── override 身份（BUG-1317）─────────────────────────────────────────
  //
  // override 书名 / 封面的身份是**条目**（`mediaIdentifier`），不是「用哪个阅读器
  // 打开」。旧实现把源键烧进了两处：
  //   1. key 字符串 `override_title://<src>/<src>/<mediaId>`——源键出现两次，因为
  //      `MediaItem.uniqueKey` 自己就是 `<src>/<mediaId>`；封面同理，文件名是
  //      `'<mediaId>/<src>/override_thumbnail'.hashCode`；
  //   2. 存储命名空间——偏好落 `src:<src>:<key>`（[dbSourcePrefKey]），每个源一份
  //      独立缓存，所以光把源键从 key 字符串里拿掉并不够。
  //
  // 而一本书的 `mediaSourceIdentifier` 由 `EpubBooks.format` **现算**
  // （epub→`reader_ttu` / manga→`reader_manga` / pdf→`reader_pdf`，见
  // `ReaderHibikiSource._bookToMediaItem`），三者共享同一 `hoshi://book/<bookKey>`
  // 身份。于是同一本书在「书架用真实源」与「首页 / 统计 / 通知栏用合成的 EPUB 源」
  // 两条路径上读到不同的键——改名后四处显示不一致；EPUB 转成漫画后连书架侧也读不
  // 回来，用户自定义书名与封面静默丢失。
  //
  // 修法：规范位置 = [overrideStore] 的命名空间 + 只含 `mediaIdentifier` 的键；
  // 读取期依次回退 [legacyOverrideStores] 里的旧位置，命中后**就地重写**成规范
  // 位置。零 schema 迁移、零存量丢失。清理条件：一个版本后（存量已被读取期迁走）
  // 删掉 [legacyOverrideStores] 与全部 legacy helper。

  /// override（书名 / 封面）的**存储归属源**。默认归属自己。
  ///
  /// 共享同一 `mediaIdentifier` 命名空间的源族必须统一归一个源存，否则同一条目在
  /// 不同源实例下落进不同的 `src:<sourceId>:` 偏好命名空间——见
  /// `ReaderMediaSource.overrideStore`（书族三源全归 EPUB 源）。
  MediaSource get overrideStore => this;

  /// 读取期回退位置：规范位置未命中时依次尝试的**旧**存储。
  ///
  /// 每个元素同时提供两样东西：旧偏好命名空间的宿主实例，以及旧键 / 旧封面文件名
  /// 里烧进去的那个源键（[uniqueKey]）。默认只有自己。
  List<MediaSource> get legacyOverrideStores => <MediaSource>[this];

  /// The map key used to store the override title of an item.
  ///
  /// BUG-1317：只含 `mediaIdentifier`，不含任何源键——override 跟着**条目**走。
  String getOverrideTitleKey(MediaItem item) =>
      'override_title://${item.mediaIdentifier}';

  /// BUG-1317 之前的旧书名键形态（源键出现两次）。只用于读取期回退与清除。
  static String legacyOverrideTitleKey({
    required String sourceId,
    required String mediaIdentifier,
  }) =>
      'override_title://$sourceId/$sourceId/$mediaIdentifier';

  /// The map value used to store the override thumbnail of an item.
  ///
  /// BUG-1317：规范文件名只由 `mediaIdentifier` 派生。**读取请走
  /// [resolveOverrideThumbnailFile]**——直接调本函数只拿得到规范路径，看不见还没
  /// 迁移的存量旧文件。
  String getOverrideThumbnailFilename({
    required AppModel appModel,
    required MediaItem item,
  }) =>
      _overrideThumbnailPath(
        appModel,
        '${item.mediaIdentifier}/override_thumbnail',
      );

  /// BUG-1317 之前的旧封面文件名（把源键烧进 hashCode）。只用于读取期回退与清除。
  String legacyOverrideThumbnailFilename({
    required AppModel appModel,
    required MediaItem item,
    required String sourceId,
  }) =>
      _overrideThumbnailPath(
        appModel,
        '${item.mediaIdentifier}/$sourceId/override_thumbnail',
      );

  String _overrideThumbnailPath(AppModel appModel, String key) =>
      path.join(appModel.thumbnailsDirectory.path, key.hashCode.toString());

  /// Given a [MediaItem], return its override display title.
  String? getOverrideTitleFromMediaItem(MediaItem item) {
    if (!item.canEdit) {
      return null;
    }

    final String key = getOverrideTitleKey(item);
    final String? current =
        overrideStore.getPreference<String?>(key: key, defaultValue: null);
    if (current != null) {
      return current;
    }
    return _adoptLegacyOverrideTitle(item: item, canonicalKey: key);
  }

  /// BUG-1317 读取期回退：规范键无值时依次试旧键，命中即就地重写成规范键。
  ///
  /// 重写故意不 await：本函数在 `build()` 里被同步调用，而 [setPreference] /
  /// [deletePreference] 的**内存缓存写发生在第一个 await 之前**，所以「下一次读
  /// 已命中规范键」是同步可见的；落库是写穿，失败由它们内部记日志。
  String? _adoptLegacyOverrideTitle({
    required MediaItem item,
    required String canonicalKey,
  }) {
    for (final MediaSource legacy in legacyOverrideStores) {
      final String legacyKey = legacyOverrideTitleKey(
        sourceId: legacy.uniqueKey,
        mediaIdentifier: item.mediaIdentifier,
      );
      final String? value =
          legacy.getPreference<String?>(key: legacyKey, defaultValue: null);
      if (value == null) {
        continue;
      }
      unawaited(overrideStore.setPreference<String?>(
        key: canonicalKey,
        value: value,
      ));
      unawaited(legacy.deletePreference(key: legacyKey));
      return value;
    }
    return null;
  }

  /// 清除一个条目的 override 书名——规范位置 **与全部旧位置**。
  ///
  /// BUG-1317：不清旧位置的话，「清除改名」会被读取期回退当成存量重新读回来
  /// （用户看到旧名复活），换新名则留下永不再读的孤儿行。
  Future<void> clearOverrideTitle(MediaItem item) async {
    await overrideStore.deletePreference(key: getOverrideTitleKey(item));
    for (final MediaSource legacy in legacyOverrideStores) {
      await legacy.deletePreference(
        key: legacyOverrideTitleKey(
          sourceId: legacy.uniqueKey,
          mediaIdentifier: item.mediaIdentifier,
        ),
      );
    }
  }

  /// BUG-1317：返回**实际存在**的 override 封面文件，没有则 null。
  ///
  /// 命中旧文件名（源键烧进 hash）时就地 rename 成规范文件名。所有消费点——书架卡 /
  /// 编辑弹窗 / 刮削跳过判据 / [getThumbnailUri] /
  /// [getOverrideThumbnailFromMediaItem]——都必须走本入口。
  File? resolveOverrideThumbnailFile({
    required AppModel appModel,
    required MediaItem item,
  }) {
    final String canonical =
        getOverrideThumbnailFilename(appModel: appModel, item: item);
    final File canonicalFile = File(canonical);
    if (canonicalFile.existsSync()) {
      return canonicalFile;
    }
    for (final MediaSource legacy in legacyOverrideStores) {
      final File legacyFile = File(legacyOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
        sourceId: legacy.uniqueKey,
      ));
      if (!legacyFile.existsSync()) {
        continue;
      }
      try {
        canonicalFile.parent.createSync(recursive: true);
        return legacyFile.renameSync(canonical);
      } catch (e, stack) {
        ErrorLogService.instance
            .log('MediaSource.adoptLegacyOverrideThumbnail', e, stack);
        // rename 失败不该让封面凭空消失：仍返回旧文件，下次读再试一次。
        return legacyFile;
      }
    }
    return null;
  }

  /// 删除一个条目全部旧文件名形态的 override 封面（BUG-1317 清理）。
  void _deleteLegacyOverrideThumbnails({
    required AppModel appModel,
    required MediaItem item,
  }) {
    for (final MediaSource legacy in legacyOverrideStores) {
      final File legacyFile = File(legacyOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
        sourceId: legacy.uniqueKey,
      ));
      if (legacyFile.existsSync()) {
        legacyFile.deleteSync();
      }
    }
  }

  /// Given a [MediaItem], return its override display thumbnail.
  ImageProvider<Object>? getOverrideThumbnailFromMediaItem({
    required AppModel appModel,
    required MediaItem item,
  }) {
    final File? file =
        resolveOverrideThumbnailFile(appModel: appModel, item: item);
    if (file == null) {
      return null;
    }

    // BUG-959: 降采样解码；存在性判据保留——它区分「有无 override 封面」（同步 API，
    // 返回 null 表示无 override 由上层回落正常封面），改异步会牵动所有 build 调用点。
    return resizedFileImage(file);
  }

  /// Given a [MediaItem], set its override display title. If the title is
  /// blank, the override title is cleared.
  Future<void> setOverrideTitleFromMediaItem({
    required MediaItem item,
    required String? title,
  }) async {
    String? value;
    if (title != null) {
      final String trimmedTitle = title.trim();
      if (trimmedTitle.isNotEmpty) {
        value = trimmedTitle;
      }
    }

    // BUG-1317: 旧位置无条件清掉再写规范位置——否则「清除改名」会被读取期回退
    // 复活成旧名，「改成新名」则留下永不再读的孤儿行。
    await clearOverrideTitle(item);
    await overrideStore.setPreference<String?>(
      key: getOverrideTitleKey(item),
      value: value,
    );
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

    // BUG-1018 (附带): only touch the disk when there is an actual change. The
    // old unconditional createSync left a 0-byte override file behind on every
    // "save without picking a new image", and getOverrideThumbnailFromMediaItem
    // gates only on existsSync — so the cover then rendered as a broken blank.
    File thumbnailFile = File(filename);
    if (clearOverrideImage) {
      if (thumbnailFile.existsSync()) {
        thumbnailFile.deleteSync();
      }
    } else if (file != null) {
      thumbnailFile.parent.createSync(recursive: true);
      file.copySync(filename);
    } else {
      // 既没清除也没新图：磁盘未动，无需驱逐。
      return;
    }

    // BUG-1317: 无论清除还是换图，旧文件名（源键烧进 hash）都必须一起清掉——
    // 清除时留着会被 [resolveOverrideThumbnailFile] 的回退「复活」，换图时留着
    // 只是永不再读的孤儿文件。
    _deleteLegacyOverrideThumbnails(appModel: appModel, item: item);

    // 统一封面服务不变量（P3）：override 缩略图是「同路径覆盖写/删除」——filename
    // 由 hashCode 派生、换图不换路径，而 ImageCache 按 (path, scale) 而非内容缓存
    // 解码。写/删后必须双键驱逐（裸 FileImage + resizedFileImage 的 ResizeImage 键，
    // 见 [evictLocalCoverCache]），否则书架/编辑弹窗重建仍命中旧解码，表现为
    // 「换了封面没生效」。放在这里而非上层，是让 clearOverrideValues 等所有写入方
    // 共享同一条驱逐路径。
    await evictLocalCoverCache(filename);
  }

  /// Used to clear override values of a [MediaItem] upon deletion.
  Future<void> clearOverrideValues({
    required AppModel appModel,
    required MediaItem item,
  }) async {
    await clearOverrideTitle(item);
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
