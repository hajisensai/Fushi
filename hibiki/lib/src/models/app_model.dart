import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

// archive/archive_io moved to DictionaryImportManager
// audio_service moved to AudioController
// external_app_launcher moved to AnkiIntegration
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:remove_emoji/remove_emoji.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/media/floating_dict_channel.dart';
import 'package:hibiki/src/models/app_font_loader.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';
import 'package:hibiki/src/models/media_history_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart' as theme_notifier;
import 'package:hibiki/src/models/theme_notifier.dart' show ThemeNotifier;
import 'package:hibiki/src/models/audio_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';
import 'package:hibiki/src/models/file_export_manager.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/models/anki_integration.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_client.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_host.dart';
import 'package:hibiki/src/sync/yomitan_api_server_manager.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/shortcut_preferences.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/startup/test_environment.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/platform/platform_providers.dart';

export 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
export 'package:hibiki/src/models/local_audio_source_pref.dart'
    show LocalAudioSourcePref;
export 'package:hibiki/src/models/audio_source_config.dart'
    show AudioSourceConfig, AudioSourceKind;

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

// LocalAudioDbEntry moved to local_audio_manager.dart, re-exported above.

/// A global [Provider] for app-wide configuration and state management.
final appProvider = ChangeNotifierProvider<AppModel>((ref) {
  return AppModel(ref.read(platformServicesProvider));
});

/// Provides color for all quick actions.
final quickActionColorProvider =
    FutureProvider.family<Map<String, Color?>, DictionaryEntry>(
        (ref, entry) async {
  AppModel appModel = ref.watch(appProvider);
  // Key each color to its action's uniqueKey in a single pass; a positional
  // colors[i] join would silently mismap if iteration order ever diverged.
  List<Future<MapEntry<String, Color?>>> futures =
      appModel.quickActions.values.map((e) async {
    return MapEntry(
      e.uniqueKey,
      await e.getIconColor(appModel: appModel, entry: entry),
    );
  }).toList();

  return Map<String, Color?>.fromEntries(await Future.wait(futures));
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
  DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
}) =>
    theme_notifier.buildHibikiColorScheme(
      seedColor: seedColor,
      brightness: brightness,
      variant: variant,
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      primaryContainer: primaryContainer,
    );

/// 书架长按「悬浮字幕」启动后台听书的结果（供 UI 决定提示）。
enum BackgroundListenResult {
  /// 已启动后台听书会话。
  started,

  /// 该书没有可播放的有声书 / 字幕书（无记录或无音频文件）。
  noAudio,

  /// 找到了音频但加载失败。
  loadFailed,
}

/// 一条词典在 FFI 引擎分桶时需要的信息：类型、资源路径、目录是否存在、是否隐藏。
typedef DictPathEntry = ({
  DictionaryType type,
  String path,
  bool exists,
  bool hidden,
  // TODO-622: a term dictionary that also contains kanji records (a mixed
  // JA-JA 国語辞典) carries metadata['hasKanji']=='true'. Such an entry is
  // routed into the kanji bucket too, so add_kanji_dict sees it.
  bool hasKanji,
});

/// 把词典分桶成 FFI 引擎要的四组 path（term/freq/pitch/kanji）的单一真相。
///
/// 隐藏的 freq/pitch/kanji 不进引擎——它们无渲染期隐藏过滤、会直接从引擎冒出来
/// （BUG-177 / TODO-094 S4）；term 在渲染期按 hidden 过滤，故隐藏仍进桶。不存在的
/// 目录跳过。同步 [AppModel._rebuildDictPathsCache] 与异步 `_rebuildDictPathsCacheAsync`
/// 只差「怎么判目录存在」，分桶 switch 收口于此（之前两份逐字复制，改一处忘另一处即漂移）。
@visibleForTesting
({List<String> term, List<String> freq, List<String> pitch, List<String> kanji})
    bucketDictPaths(List<DictPathEntry> entries) {
  final term = <String>[];
  final freq = <String>[];
  final pitch = <String>[];
  final kanji = <String>[];
  for (final DictPathEntry e in entries) {
    if (!e.exists) continue;
    switch (e.type) {
      case DictionaryType.term:
        term.add(e.path);
      case DictionaryType.kanji:
        if (!e.hidden) kanji.add(e.path);
      case DictionaryType.frequency:
        if (!e.hidden) freq.add(e.path);
      case DictionaryType.pitch:
        if (!e.hidden) pitch.add(e.path);
    }
    // TODO-622: a mixed dictionary (type==term but containing kanji records)
    // must be registered in BOTH the term and kanji buckets so word lookup and
    // single-character kanji lookup both hit. query_kanji has a type+char double
    // guard (query.cpp), so a pure term dict (hasKanji==false) is never added
    // here and a registered mixed dict produces zero false kanji hits. Honor
    // hidden like the kanji case (kanji bucket has no render-time hide filter).
    if (e.type == DictionaryType.term && e.hasKanji && !e.hidden) {
      kanji.add(e.path);
    }
  }
  return (term: term, freq: freq, pitch: pitch, kanji: kanji);
}

/// [normalizeSearchTerm] 的返回：清洗后的查询串 + 三步替换各自的微秒耗时，供
/// `[dict-perf]` 打点逐字段读取（耗时本身是可观测性数据，不影响查询结果）。
typedef NormalizedSearchTerm = ({
  String term,
  int emojiMicros,
  int punctMicros,
  int surrogateMicros,
});

/// 词典查询前的查询串清洗单一真相：换行折空格 → emoji 去除 → 首尾标点/符号剥离 →
/// 孤立代理项替换。此前 4 步 replaceAll 散在 [AppModel.searchDictionary] 内、与多个
/// Stopwatch 打点交织，无法单测（依赖整页 AppModel + FFI）。纯逻辑（输入→输出确定）
/// 凿到这里，原调用处仍用 `swPreprocess` 包住总计时、用返回的子计时拼出逐字不变的
/// `[dict-perf] preprocess` 打点。换行折叠是无条件首步（无独立计时），emoji/punct/
/// surrogate 三步各自计时随结果返回。
///
/// 替换契约逐字不变（变=查询语义/缓存键漂移）：`\n`→`' '`、[emojiRegex]→`' '`、
/// [punctuationRegex]→`''`、[loneSurrogateRegex]→`' '`，顺序固定。
@visibleForTesting
NormalizedSearchTerm normalizeSearchTerm(
  String searchTerm, {
  required RegExp emojiRegex,
  required RegExp punctuationRegex,
  required RegExp loneSurrogateRegex,
}) {
  searchTerm = searchTerm.replaceAll('\n', ' ');

  final swEmoji = Stopwatch()..start();
  searchTerm = searchTerm.replaceAll(emojiRegex, ' ');
  swEmoji.stop();

  final swPunct = Stopwatch()..start();
  searchTerm = searchTerm.replaceAll(punctuationRegex, '');
  swPunct.stop();

  final swSurrogate = Stopwatch()..start();
  searchTerm = searchTerm.replaceAll(loneSurrogateRegex, ' ');
  swSurrogate.stop();

  return (
    term: searchTerm,
    emojiMicros: swEmoji.elapsedMicroseconds,
    punctMicros: swPunct.elapsedMicroseconds,
    surrogateMicros: swSurrogate.elapsedMicroseconds,
  );
}

/// 词典搜索结果缓存键的单一真相，逐字不变（变=缓存击穿/旧条目命中不了）。格式：
/// `<term.length>:<term>/<maxTerms>/<maxResults>`。此前是 [AppModel.searchDictionary]
/// 内联插值，无法独立断言「键格式不漂移」。
@visibleForTesting
String buildSearchCacheKey({
  required String term,
  required int maxTerms,
  required int maxResults,
}) {
  return '${term.length}:$term/$maxTerms/$maxResults';
}

/// 从 `blobs.bin` 头部字节解码词典实际类型（freq/pitch），供 term 词典的类型回填迁移。
/// 此前解析与 `RandomAccessFile` 的分次读/定位深交织（[AppModel._migrateDictionaryTypes]），
/// 无法单测（依赖真文件）。纯逻辑吃**已读入的字节**（调用方负责打开/读盘/关闭），按
/// 相同偏移解析，返回检测到的类型；非 freq/pitch 或头部不合法返回 `null`（调用方
/// `continue` 跳过该词典，保持 term 类型不动）。
///
/// 布局（与原 raf 逐次读逐字对齐）：
/// - `bytes[0]` 必须是标志 `0x01`，否则 `null`；
/// - `bytes[1] | (bytes[2] << 8)` 是 exprLen（小端 16 位）；
/// - modeLen 在偏移 `3 + exprLen` 处单字节，越界或 `0` 返回 `null`；
/// - mode 串是其后**至多** `modeLen` 字节（`String.fromCharCodes`）。原逻辑用
///   `raf.readSync(modeLen)`：文件到末尾时只返回剩余字节、不报错，故这里同样截断到
///   `bytes` 末尾（不因 modeLen 越界而提前返 `null`），逐字复刻原行为。
///   `'freq'`→frequency、`'pitch'`/`'ipa'`→pitch，其余 `null`。
@visibleForTesting
DictionaryType? decodeDictTypeFromBlobHeader(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] != 0x01) return null;

  final exprLen = bytes[1] | (bytes[2] << 8);
  final modeLenIndex = 3 + exprLen;
  if (modeLenIndex >= bytes.length) return null;
  final modeLen = bytes[modeLenIndex];
  if (modeLen == 0) return null;

  // 与原 raf.readSync(modeLen) 的截断语义一致：文件不足 modeLen 时取剩余字节。
  final modeStart = modeLenIndex + 1;
  final int modeEnd = (modeStart + modeLen) <= bytes.length
      ? (modeStart + modeLen)
      : bytes.length;
  final mode = String.fromCharCodes(bytes.sublist(modeStart, modeEnd));

  if (mode == 'freq') return DictionaryType.frequency;
  // 'ipa' 音标词典与 'pitch' 共用 pitch 存储/查询通道（native query_pitch 同时读
  // pitch + ipa meta 记录），故归入 pitch 桶，否则迁移期判不出类型、不会被注册成
  // pitch 词典，IPA 数据查不出来（TODO-687 块3）。
  if (mode == 'pitch' || mode == 'ipa') return DictionaryType.pitch;
  return null;
}

/// A scoped model for parameters that affect the entire application.
/// RiverPod is used for global state management across multiple layers,
/// especially for preferences that persist across application restarts.
class AppModel with ChangeNotifier {
  /// Platform-specific service implementations, injected at construction.
  final PlatformServices platformServices;

  AppModel(this.platformServices);

  /// Test-only seam: wires the preferences + local-audio sub-managers directly,
  /// bypassing the heavy [initialise] platform-channel path, so unit tests can
  /// exercise local-audio config against a real [PreferencesRepository] +
  /// [LocalAudioManager] on an in-memory DB and a temp directory.
  ///
  /// Deliberately leaves [_database] uninitialized — tests using this seam must
  /// only exercise code paths that do not touch [_database].
  @visibleForTesting
  void wireLocalAudioForTesting({
    required PreferencesRepository prefsRepo,
    required Directory databaseDirectory,
  }) {
    _prefsRepo = prefsRepo;
    _databaseDirectory = databaseDirectory;
    _localAudioManager = LocalAudioManager(
      prefsRepo: prefsRepo,
      databaseDirectory: databaseDirectory,
    );
  }

  /// Test seam: inject an already-open database so widget tests can exercise
  /// schema builders (e.g. the sync/backup destination) that read [database]
  /// without running the full [initialise] path.
  @visibleForTesting
  void wireDatabaseForTesting(HibikiDatabase db) {
    _database = db;
    _databaseOpened = true;
  }

  /// 全应用共享的冲突弹窗调度器：三处同步入口（手动 / 关书后 / app 启动）
  /// 共用同一份会话级 snooze + 单飞状态，避免冲突弹窗互相重入或反复打扰。
  final SyncConflictPrompter syncConflictPrompter = SyncConflictPrompter();

  /// App 级 Hibiki LAN 同步服务端宿主：生命周期归 AppModel（整个会话），
  /// 不再绑在设置页 widget 上——否则切出「同步与备份」页就把服务端关了（BUG-085）。
  /// 启动时若用户启用了 host 则自动开，仅在用户关闭开关或退出 app 时停。配对批准
  /// 弹窗经全局 [navigatorKey]，故在任意界面都能弹。
  late final HibikiSyncServerController syncServerController =
      HibikiSyncServerController(
    navigatorKey: navigatorKey,
    database: () => database,
    syncDataDir: () => databaseDirectory.path,
    remoteLookupServiceFactory: createRemoteLookupService,
    miningServiceFactory: createRemoteMiningService,
    historyServiceFactory: createRemoteHistoryService,
    libraryServiceFactory: () => AppModelLibraryHostService(
      db: database,
      dictionaryResourceRoot: dictionaryResourceDirectory,
      packages: SyncAssetPackageService(db: database),
      refreshDictionaryCache: () async {
        await _rebuildDictPathsCacheAsync();
        dictRepo.clearDictionaryResultsCache();
      },
      runExclusive: runExclusiveWithSync,
      localAudioEntries: localAudioDbs,
      localAudioStagingDir: temporaryDirectory,
      onLocalAudioImported: importSyncedLocalAudioDb,
      audioDatabaseRoot: Directory('${appDirectory.path}/audiobooks'),
      videoSubtitleLangCode: targetLanguage.languageCode,
      removeLocalAudioEntry: (String displayName) async {
        // 按 displayName 在 LocalAudioManager 中找到对应 index 并删除。
        // LocalAudioManager.remove(int) 删除 DB 文件 + 从 prefs 移出 + 推 native。
        final int idx = _localAudioManager.entries
            .indexWhere((LocalAudioDbEntry e) => e.displayName == displayName);
        if (idx < 0) return; // 不存在则幂等跳过
        await _localAudioManager.remove(idx);
        notifyListeners();
      },
    ),
  );

  /// 自动同步（关书后 / app 启动）拿到报告后，若有冲突则弹解决对话框。
  /// fire-and-forget：present 是 barrier 对话框，不阻塞调用方；异常兜住并记日志，
  /// 不让它逃成未捕获 async error。签名与 [SyncReportCallback] typedef 完全一致，
  /// 故两处自动同步入口可直接传方法引用，无需再包 lambda。
  void presentAutoConflicts(SyncRunReport report, SyncBackend backend) {
    if (report.conflicts.isEmpty) return;
    syncConflictPrompter
        .present(
      navigatorKey: navigatorKey,
      db: database,
      backend: backend,
      conflicts: report.conflicts,
      source: ConflictSource.auto,
      inBook: isMediaOpen,
    )
        .catchError((Object e, StackTrace s) {
      debugPrint('[sync] auto conflict prompt failed: $e');
    });
  }

  /// Refresh app-owned caches and visible home tabs after a sync run imports
  /// content into this device. Without this, pulled books/dictionaries/audio can
  /// be in Drift/on disk but stay invisible until a later rebuild or restart.
  Future<void> refreshAfterSyncRun(SyncRunReport report) async {
    if (!report.needsLocalLibraryRefresh) return;

    if (report.dictionariesImported > 0) {
      dictRepo.clearDictionariesCache();
      await _rebuildDictPathsCacheAsync();
      dictRepo.clearDictionaryResultsCache();
      dictionaryMenuNotifier.notifyListeners();
      dictionarySearchAgainNotifier.notifyListeners();
    }

    if (report.booksImported > 0 || report.audiobooksImported > 0) {
      ReaderMediaType.instance.refreshTab();
    }

    if (report.localAudioImported > 0) {
      DictionaryMediaType.instance.refreshTab();
    }

    notifyListeners();
  }

  /// Used for showing dialogs without needing to pass around a [BuildContext].
  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;
  late final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  BuildContext? get _ctx => _navigatorKey.currentContext;

  /// Used to get the versioning metadata of the app. See [initialise].
  RouteObserver<PageRoute> get routeObserver => _routeObserver;
  final RouteObserver<PageRoute> _routeObserver = RouteObserver<PageRoute>();

  /// Persistent database (Drift/SQLite).
  late HibikiDatabase _database;

  /// True once [_database] has been opened in an init path. Used by
  /// [retryInitialise] to close a stale connection before re-running init
  /// (the late fields are reassigned, so the old DB would otherwise leak).
  bool _databaseOpened = false;

  /// Theme management, extracted from AppModel for testability.
  late ThemeNotifier themeNotifier;
  bool _themeListenerAdded = false;

  /// Preference management, extracted from AppModel for testability.
  PreferencesRepository? _prefsRepo;
  PreferencesRepository get prefsRepo => _prefsRepo!;

  /// Media history and search history, extracted for testability.
  late MediaHistoryRepository mediaHistoryRepo;

  /// Dictionary metadata, history, and search caches.
  late DictionaryRepository dictRepo;

  /// Extracted sub-managers.
  late final AudioController audioCtrl = AudioController();
  late final AnkiIntegration ankiIntegration = AnkiIntegration();

  /// 进程级常驻有声书会话（TODO-291 阶段2）：唯一持有 AudiobookPlayerController +
  /// 当前书元数据，常驻执行 cue→悬浮窗/媒体通知/位置落库同步，脱离 reader 页生命周期。
  /// reader 在场时经 [AudiobookSession.attachReader] 注册 WebView 侧回调。
  late final AudiobookSession audiobookSession = AudiobookSession(
    audioHandler: () => audioCtrl.audioHandler,
    showFloatingLyric: () => showFloatingLyric,
    showMediaNotification: () => showMediaNotification,
    floatingLyricStyle: _appLevelFloatingLyricStyle,
    floatingLyricClickLookup: () => floatingLyricClickLookup,
    onFloatingLyricLookup: (String text, int index) {
      // app 级（无 reader attach）桌面悬浮窗点词：路由进常驻主窗口的查词宿主
      // [FloatingLyricLookupHost]（main.dart 根 builder 挂载），不依赖进任何书
      // （TODO-354 ①）。reader attach 时会换成 reader 的弹窗查词处理器。
      FloatingLyricLookupNotifier.instance.requestLookup(text, index);
    },
    controlStreams: AudioControlStreams(
      playStream: audioCtrl.playStream,
      seekStream: audioCtrl.seekStream,
      skipNextStream: audioCtrl.skipNextStream,
      skipPreviousStream: audioCtrl.skipPreviousStream,
      toggleFloatingLyricStream: audioCtrl.toggleFloatingLyricStream,
    ),
  )
    ..skipActionSeconds = (() => ReaderHibikiSource.instance.skipActionSeconds)
    ..onFloatingLyricClosePersist = (() => setShowFloatingLyric(false))
    ..onToggleFloatingLyricFromNotification = toggleFloatingLyricFromControls;
  late DictionaryImportManager _dictImportManager;
  late FileExportManager _fileExportManager;
  late LocalAudioManager _localAudioManager;

  /// Keyboard / gamepad shortcut bindings, persisted in preferences.
  final HibikiShortcutRegistry shortcutRegistry = HibikiShortcutRegistry();

  /// Polls physical game controllers and dispatches them into the shortcut /
  /// focus pipeline on platforms where the Flutter engine does not deliver
  /// gameButton* key events (desktop). No-op on Android/iOS (native key events)
  /// and on desktops without an implemented input source.
  late final GamepadService gamepadService = GamepadService(
    navigatorKey: navigatorKey,
    registry: shortcutRegistry,
  );

  /// Resets the focus highlight to touch mode on every route push/pop so a ring
  /// lit by keyboard/gamepad navigation on one page is not carried onto the next
  /// (BUG-398). Wired into [MaterialApp.navigatorObservers] in main.dart. Same-
  /// route home-tab switches go through HomePage._selectTab, which calls the
  /// underlying [GamepadService.resetHighlightForScreenSwitch] directly.
  late final HighlightResetNavigatorObserver focusHighlightObserver =
      HighlightResetNavigatorObserver(
    gamepadService.resetHighlightForScreenSwitch,
  );

  Color? get systemPrimaryColor => themeNotifier.systemPrimaryColor;

  Future<void> refreshSystemPalette() => themeNotifier.refreshSystemPalette();

  /// Used to get the versioning metadata of the app. See [initialise].
  PackageInfo get packageInfo => _packageInfo;
  late PackageInfo _packageInfo;

  /// Whether [initialise] has completed successfully.
  bool get isInitialised => _isInitialised;
  bool _isInitialised = false;

  /// Non-null if [initialise] threw; UI should display this instead of spinning.
  String? get initError => _initError;
  String? _initError;

  /// Non-null when init was refused because the on-disk DB was created by a
  /// NEWER build of Hibiki than this one (downgrade protection). The UI shows a
  /// dedicated "update your app" notice with NO retry button — retry would fail
  /// identically and this is not a transient error. The DB file is left intact.
  HibikiDatabaseDowngradeException? get downgradeError => _downgradeError;
  HibikiDatabaseDowngradeException? _downgradeError;

  /// Clears the error state and re-runs [initialise].
  Future<void> retryInitialise() async {
    // A previous attempt may have partially initialised resources. Tear down
    // the ones that would otherwise leak or double-register before re-running
    // (the late fields below are reassigned by initialise()).
    if (_databaseOpened) {
      _prefsRepo?.removeListener(notifyListeners);
      if (_themeListenerAdded) {
        themeNotifier.removeListener(notifyListeners);
        _themeListenerAdded = false;
      }
      try {
        await _database.close();
      } catch (e, stack) {
        ErrorLogService.instance
            .log('AppModel.retryInitialise.close', e, stack);
      }
      _databaseOpened = false;
    }
    _initError = null;
    _downgradeError = null;
    _isInitialised = false;
    notifyListeners();
    await initialise();
  }

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

  static RegExp? _emojiRegexInstance;
  static RegExp get _emojiRegex =>
      _emojiRegexInstance ??= RegExp(RemoveEmoji().getRegexString());

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

  /// TODO-376：一次性「请打开首页『查词』tab」信号。值每请求一次自增（内容无关，
  /// 仅作 edge 触发）。桌面悬浮字幕条点词（reader 路由里 `_lookupFromFloatingLyric`）
  /// 这种**显式**查词手势，需要把主窗口从阅读器/任意 tab 切到查词 tab，让
  /// [HomeDictionaryPage] 挂载并消费 [DesktopLookupService.pendingText]。
  ///
  /// 这是与被动剪贴板监听**正交**的显式导航原语：HomePage 监听本信号只切 tab，不监听
  /// DesktopLookupService、也不在剪贴板被动命中时自动切 tab（守卫：剪贴板/热键查词仅
  /// 在查词页生命周期内消费，HomePage 根节点不常驻 DesktopLookupService 监听）。
  final ValueNotifier<int> homeDictionaryTabRequest = ValueNotifier<int>(0);

  /// 发一次「打开查词 tab」请求（桌面悬浮字幕点词等显式手势调）。
  void requestHomeDictionaryTab() {
    homeDictionaryTabRequest.value++;
  }

  /// These directories are prepared at startup in order to reduce redundancy
  /// in actual runtime.
  /// Directory where data that may be dumped is stored.
  Directory get temporaryDirectory => _temporaryDirectory;
  late Directory _temporaryDirectory;

  /// Directory where data may be persisted.
  Directory get appDirectory => _appDirectory;
  late Directory _appDirectory;

  /// Directory where database data is persisted.
  Directory get databaseDirectory => _databaseDirectory;
  late Directory _databaseDirectory;

  /// Directory where database data is persisted.
  Directory get dictionaryResourceDirectory => _dictionaryResourceDirectory;
  late Directory _dictionaryResourceDirectory;

  /// Directory where browser cache data may be persisted.
  Directory get browserDirectory => _browserDirectory;
  late Directory _browserDirectory;

  /// Directory where media source thumbnails may be persisted.
  Directory get thumbnailsDirectory => _thumbnailsDirectory;
  late Directory _thumbnailsDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs.
  Directory get exportDirectory => _exportDirectory;
  late Directory _exportDirectory;

  /// Directory where the browser media source saves web archives for offline
  /// use.
  Directory get webArchiveDirectory => _webArchiveDirectory;
  late Directory _webArchiveDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs. Fallback for failure.
  Directory get alternateExportDirectory => _alternateExportDirectory;
  late Directory _alternateExportDirectory;

  /// Directory used as a working directory for dictionary imports.
  Directory get dictionaryImportWorkingDirectory =>
      _dictionaryImportWorkingDirectory;
  late Directory _dictionaryImportWorkingDirectory;

  /// Used to fetch a language by its locale tag with constant time performance.
  /// Initialised with [populateLanguages] at startup.
  late Map<String, Language> languages;

  /// Used to fetch an app locale by its locale tag with constant time
  /// performance. Initialised with [populateLocales] at startup.
  late Map<String, Locale> locales;

  /// Used to fetch a dictionary format by its unique key with constant time
  /// performance. Initialised with [populateDictionaryFormats] at startup.
  late Map<String, DictionaryFormat> dictionaryFormats;

  /// Used to fetch a media type by its unique key with constant time
  /// performance. Initialised with [populateMediaTypes] at startup.
  late Map<String, MediaType> mediaTypes;

  /// Used to fetch initialised fields by their unique key with constant
  /// time performance. Initialised with [populateEnhancements] at startup.
  late Map<String, Field> fields;

  /// Used to fetch initialised enhancements by their unique key with constant
  /// time performance. Initialised with [populateEnhancements] at startup.
  late Map<Field, Map<String, Enhancement>> enhancements;

  /// Used to fetch initialised actions by their unique key with constant
  /// time performance. Initialised with [populateQuickActions] at startup.
  late Map<String, QuickAction> quickActions;

  /// Used to fetch initialised sources by their unique key with constant
  /// time performance. Initialised with [populateMediaSources] at startup.
  late Map<MediaType, Map<String, MediaSource>> mediaSources;

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
      // TODO-622 self-heal: a mixed JA-JA dictionary (term + embedded kanji
      // appendix) was misclassified as 'kanji' by the old detect_type, so its
      // 80k+ term entries only ever reached the kanji bucket and word lookup
      // returned nothing. Re-probe such dictionaries' on-disk blobs.bin via the
      // native single source of truth: if it actually contains term records,
      // demote it back to 'term' and tag metadata['hasKanji'] so the bucket
      // router also registers it as a kanji dict. A genuine KANJIDIC (kanji
      // records only, no term) keeps type 'kanji' and is left untouched.
      if (d.type == DictionaryType.kanji) {
        try {
          final dir = path.join(dictionaryResourceDirectory.path, d.name);
          if (!Directory(dir).existsSync()) continue;
          final int mask = HoshiDicts.probeDictContent(dir);
          const int hasTerm = 0x1;
          const int hasKanji = 0x2;
          if (mask & hasTerm == 0) continue; // pure kanji dict, nothing to fix

          final Map<String, String> meta = Map<String, String>.from(d.metadata);
          if (mask & hasKanji != 0) {
            meta['hasKanji'] = 'true';
          } else {
            meta.remove('hasKanji');
          }
          final updated = Dictionary(
            name: d.name,
            formatKey: d.formatKey,
            order: d.order,
            type: DictionaryType.term,
            metadata: meta,
            hiddenLanguages: d.hiddenLanguages,
            collapsedLanguages: d.collapsedLanguages,
          );
          dictRepo.persistDictionary(updated);
          debugPrint(
              '[Hibiki] reclassified kanji→term (mixed dict): ${d.name}');
        } catch (e, stack) {
          ErrorLogService.instance
              .log('AppModel.dictKanjiReclassify', e, stack);
          debugPrint('[Hibiki] kanji reclassify error for ${d.name}: $e');
        }
        continue;
      }

      if (d.type != DictionaryType.term) continue;

      final blobsFile = File(
          path.join(dictionaryResourceDirectory.path, d.name, 'blobs.bin'));
      if (!blobsFile.existsSync()) continue;

      final raf = blobsFile.openSync();
      try {
        final int len = raf.lengthSync();
        if (len < 4) continue;
        // 读一个覆盖到 mode 串末尾的连续前缀（modeLen 单字节、上界 255，故 mode
        // 最长 255），把逐次 raf 读换成「读足够前缀 + 纯函数按相同偏移解析」。先读
        // 4 字节 header 拿 exprLen，再从头读到 modeEnd 上界，截断到文件长度。
        final header = raf.readSync(4);
        final exprLen = header[1] | (header[2] << 8);
        final int prefixLen = 3 + exprLen + 1 + 255;
        raf.setPositionSync(0);
        final List<int> head = raf.readSync(prefixLen < len ? prefixLen : len);
        final DictionaryType? detected = decodeDictTypeFromBlobHeader(head);
        if (detected == null) continue;

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

  // 隐藏的 freq/pitch/kanji 不进引擎（无渲染期隐藏过滤会直接冒出来，BUG-177/TODO-094）；
  // term 渲染期过滤故隐藏仍进桶。always rebuild 即使全空：删掉最后一本要落进空引擎让
  // 旧 in-memory 索引失效，查询不再命中（BUG-171）。分桶 switch 收口在 [bucketDictPaths]。
  void _rebuildDictPathsCache() {
    _migrateDictionaryTypes();
    final List<DictPathEntry> entries = <DictPathEntry>[];
    for (final d in dictRepo.dictionaries) {
      final p = path.join(dictionaryResourceDirectory.path, d.name);
      entries.add((
        type: d.type,
        path: p,
        exists: Directory(p).existsSync(),
        hidden: d.isHidden(targetLanguage),
        hasKanji: d.metadata['hasKanji'] == 'true',
      ));
    }
    final b = bucketDictPaths(entries);
    HoshiDicts.initializeTyped(
      termPaths: b.term,
      freqPaths: b.freq,
      pitchPaths: b.pitch,
      kanjiPaths: b.kanji,
    );
  }

  Future<void> _rebuildDictPathsCacheAsync() async {
    _migrateDictionaryTypes();
    final dictList = dictRepo.dictionaries;
    final List<String> paths = <String>[
      for (final d in dictList)
        path.join(dictionaryResourceDirectory.path, d.name),
    ];
    final existsResults = await Future.wait(
      [for (final p in paths) Directory(p).exists()],
    );
    final List<DictPathEntry> entries = <DictPathEntry>[
      for (var i = 0; i < dictList.length; i++)
        (
          type: dictList[i].type,
          path: paths[i],
          exists: existsResults[i],
          hidden: dictList[i].isHidden(targetLanguage),
          hasKanji: dictList[i].metadata['hasKanji'] == 'true',
        ),
    ];
    final b = bucketDictPaths(entries);
    HoshiDicts.initializeTyped(
      termPaths: b.term,
      freqPaths: b.freq,
      pitchPaths: b.pitch,
      kanjiPaths: b.kanji,
    );
  }

  List<DictionarySearchResult> get dictionaryHistory =>
      dictRepo.dictionaryHistory;

  // ── audio & media streams (delegated to AudioController) ────────────

  Stream<void> get currentMediaPauseStream => audioCtrl.currentMediaPauseStream;

  Stream<void> get playPauseHeadsetActionStream =>
      audioCtrl.playPauseHeadsetActionStream;

  Stream<bool> get creatorActiveStream => audioCtrl.creatorActiveStream;

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

  /// The user's custom app-wide UI font family, or null to use the language
  /// default. Resolved and registered with the Flutter engine by
  /// [refreshAppFont]; see [AppFontLoader].
  String? _appFontFamily;
  String? get appFontFamily => _appFontFamily;

  /// Loads the first enabled entry from the reader's `customFonts` list as the
  /// app-wide UI font (registering the file with the Flutter engine via
  /// [AppFontLoader]) and rebuilds the theme. Falls back to the language
  /// default when none is usable. Safe to call repeatedly — a no-op when the
  /// resolved family is unchanged.
  Future<void> refreshAppFont() async {
    final ReaderSettings settings = ReaderSettings(_database);
    await settings.refreshFromDb();
    // TODO-049: 软件系统字体走独立的 appUiFonts 目标，与小说正文(customFonts)、
    // 词典字体相互独立。
    final String? family =
        await AppFontLoader.resolveAndLoad(settings.appUiFonts);
    if (family == _appFontFamily) return;
    _appFontFamily = family;
    notifyListeners();
  }

  /// Get the app-wide text style.
  ///
  /// The UI font follows the *display* language ([appLocale]), not the pinned
  /// Japanese reading language ([targetLanguage]). With no user custom font,
  /// [fontFamily] is left null so the platform resolves the correct regional
  /// glyphs for the UI locale (e.g. Simplified-Chinese glyphs for `zh-CN`)
  /// instead of the Japanese kanji variants the old `NotoSansJP` + `ja`-locale
  /// pin forced on every Material platform. Japanese reader/dictionary content
  /// renders in WebView with its own CSS font, so it is unaffected by this
  /// app-chrome style.
  TextStyle get textStyle {
    final Locale uiLocale = appLocale;
    return TextStyle(
      fontFamily: appFontFamily,
      fontFeatures: const [FontFeature('liga', 0)],
      locale: uiLocale,
      textBaseline: _isIdeographicLocale(uiLocale)
          ? TextBaseline.ideographic
          : TextBaseline.alphabetic,
    );
  }

  /// CJK locales sit on the ideographic baseline; every other script uses the
  /// alphabetic baseline. Drives [textStyle]'s [TextStyle.textBaseline].
  static bool _isIdeographicLocale(Locale locale) {
    switch (locale.languageCode) {
      case 'ja':
      case 'zh':
      case 'ko':
        return true;
      default:
        return false;
    }
  }

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

  void updateDictionaryOrder(List<Dictionary> newDictionaries) {
    // dictRepo.updateDictionaryOrder persists the new order, fires
    // _onCacheRebuild (_rebuildDictPathsCache → engine reload) and drops the
    // search result caches so the next lookup re-merges in the new order. We
    // still have to nudge any already-open lookup page to re-query — otherwise
    // its current result keeps the old order until it is reopened or the app
    // restarts. Mirrors the delete paths (BUG-355).
    dictRepo.updateDictionaryOrder(newDictionaries);
    dictionarySearchAgainNotifier.notifyListeners();
  }

  /// Populate maps for languages at startup to optimise performance.
  void populateLanguages() {
    /// A list of languages that the app will support at runtime.
    final List<Language> availableLanguages = List<Language>.unmodifiable(
      [
        JapaneseLanguage.instance,
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
        if (AudioRecorderEnhancement.isAvailable)
          AudioRecorderEnhancement(field: AudioField.instance),
      ],
      AudioSentenceField.instance: [
        ClearFieldEnhancement(field: AudioSentenceField.instance),
        PickAudioEnhancement(field: AudioSentenceField.instance),
        if (AudioRecorderEnhancement.isAvailable)
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
        if (CameraEnhancement.isAvailable) CameraEnhancement(),
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
    try {
      final String dirPath =
          await platformServices.directory.getHibikiExportDirectory();
      final Directory hibikiDirectory = Directory(dirPath);
      await platformServices.directory
          .excludeFromMediaScanner(hibikiDirectory.path);
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

    Directory hibikiDirectory = Directory(directoryPath);

    if (!hibikiDirectory.existsSync()) {
      hibikiDirectory.createSync(recursive: true);
    }
    await platformServices.directory
        .excludeFromMediaScanner(hibikiDirectory.path);

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
  Future<void> _prepareRuntimeDirectories() async {
    final Directory? testTemp = hibikiTestDirectory('temp');
    if (testTemp != null) {
      _temporaryDirectory = testTemp;
      _appDirectory = hibikiTestDirectory('app-documents')!;
      _databaseDirectory = hibikiTestDirectory('app-support')!;
      return;
    }
    _temporaryDirectory = await getTemporaryDirectory();
    _appDirectory = await getApplicationDocumentsDirectory();
    _databaseDirectory = await getApplicationSupportDirectory();
  }

  Future<void> initialise() async {
    try {
      debugPrint('[Hibiki] init: PackageInfo + DeviceInfo');

      /// Prepare entities that may be repeatedly used at runtime.
      _packageInfo = await PackageInfo.fromPlatform();
      await platformServices.init();

      debugPrint('[Hibiki] init: directories (early, needed for DB)');
      await _prepareRuntimeDirectories();

      debugPrint('[Hibiki] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);
      _databaseOpened = true;

      // Sync-pref maintenance, before any repository loads them or sync runs:
      // 1) recover device-local sync config if a previous backup import crashed
      //    after overwriting the DB but before re-applying the preserved keys;
      // 2) fold the deprecated "SMB"(WebDAV-gateway) config into WebDAV.
      await BackupService.recoverPendingImport(_databaseDirectory.path);
      await SyncRepository(_database).migrateSmbToWebDav();

      /// Prepare all repositories (objects created first, then loaded in
      /// parallel to avoid serial await chains).
      _prefsRepo = PreferencesRepository(_database);
      final BaseAnkiRepository ankiRepo =
          platformServices.createAnkiRepository();
      final profileRepo = ProfileRepository(_database, ankiRepo);
      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache);
      mediaHistoryRepo = MediaHistoryRepository(_database);

      debugPrint('[Hibiki] init: repositories (parallel)');
      await Future.wait(<Future<void>>[
        prefsRepo.loadFromDb(),
        profileRepo.ensureDefaultProfile(),
        dictRepo.loadFromDb(),
        mediaHistoryRepo.loadFromDb(),
      ]);
      prefsRepo.addListener(notifyListeners);
      _applyMemoryPolicy();

      final Map<String, String> prefsSnapshot = prefsRepo.prefsSnapshot;

      themeNotifier = ThemeNotifier(_database, () => textTheme);
      themeNotifier.loadFromPrefsSnapshot(prefsSnapshot);
      themeNotifier.addListener(notifyListeners);
      _themeListenerAdded = true;

      debugPrint('[Hibiki] init: directories + system palette (parallel)');
      _browserDirectory = Directory(path.join(appDirectory.path, 'browser'));
      _thumbnailsDirectory =
          Directory(path.join(appDirectory.path, 'thumbnails'));

      _dictionaryResourceDirectory =
          Directory(path.join(appDirectory.path, 'dictionaryResources'));

      _dictionaryImportWorkingDirectory = Directory(
          path.join(appDirectory.path, 'dictionaryImportWorkingDirectory'));
      _webArchiveDirectory =
          Directory(path.join(appDirectory.path, 'webArchive'));

      await Future.wait(<Future<void>>[
        thumbnailsDirectory.create(recursive: true),
        dictionaryImportWorkingDirectory.create(recursive: true),
        dictionaryResourceDirectory.create(recursive: true),
        refreshSystemPalette(),
        () async {
          _exportDirectory = await prepareFallbackHibikiDirectory();
          _alternateExportDirectory = _exportDirectory;
        }(),
      ]);

      await _rebuildDictPathsCacheAsync();

      _localAudioManager = LocalAudioManager(
        prefsRepo: prefsRepo,
        databaseDirectory: _databaseDirectory,
      );
      _fileExportManager = FileExportManager(
        exportDirectory: _exportDirectory,
        alternateExportDirectory: _alternateExportDirectory,
      );

      debugPrint('[Hibiki] init: populate maps + audio DB (parallel)');
      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();
      populateQuickActions();

      _dictImportManager = DictionaryImportManager(
        dictRepo: dictRepo,
        resourceDirectory: _dictionaryResourceDirectory,
        formats: dictionaryFormats,
      );

      await Future.wait(<Future<void>>[
        targetLanguage.initialise(),
        injectAssetLicenses(),
        _seedBuiltInTags(),
        _localAudioManager.bindForNativeHandler(clearMissingPath: true),
      ]);

      debugPrint(
          '[Hibiki] init: reader settings + enhancements + quick actions + media sources (parallel)');
      MediaSource.setDatabase(_database);
      final readerSettings = ReaderSettings(_database);
      await readerSettings.loadFromPrefsSnapshot(prefsSnapshot);
      // Register the user's custom app-wide font (first enabled entry) before
      // first paint so the global theme uses it without a flash. Reuses the
      // settings just loaded above to avoid a second prefs read.
      _appFontFamily =
          await AppFontLoader.resolveAndLoad(readerSettings.appUiFonts);
      ReaderHibikiSource.readerSettings = readerSettings;

      // Start polling physical controllers on platforms that need it (desktop);
      // start() is a no-op where the engine already delivers gameButton* keys.
      gamepadService.start();

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

      // BUG-207: load the shortcut registry only AFTER ReaderHibikiSource has
      // run initialise() (which populates its in-memory preference cache from
      // the DB). Reading shortcut_bindings_json before the cache is loaded saw
      // an empty cache -> null -> resetToDefaults, and getPreference's
      // cache-miss write-through clobbered the saved JSON with 's:null',
      // permanently dropping the user's custom keys on every launch. Mirrors the
      // profile-switch path (refreshPrefCache: refresh source caches first, then
      // loadShortcutRegistry).
      await loadShortcutRegistry(
        shortcutRegistry,
        ReaderHibikiSource.instance,
        defaultTargetPlatform,
      );

      debugPrint('[Hibiki] init: search preload (parallel)');
      final String warmupChar = targetLanguage.helloWorld.substring(0, 1);
      unawaited(Future.wait(<Future<void>>[
        searchDictionary(
          searchTerm: targetLanguage.helloWorld,
          searchWithWildcards: false,
          useCache: false,
        ),
        searchDictionary(
          searchTerm: '$warmupChar?',
          searchWithWildcards: true,
          useCache: false,
        ),
        searchDictionary(
          searchTerm: '$warmupChar*',
          searchWithWildcards: true,
          useCache: false,
        ),
      ]).catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log('AppModel.searchWarmup', e, stack);
        debugPrint('[Hibiki] search warmup failed (non-fatal): $e');
        return <void>[];
      }));

      debugPrint('[Hibiki] init: DONE');
      _isInitialised = true;
      _setupFloatingDictHandlers();
      if (showFloatingDict) setShowFloatingDict(false);
      // Start the LAN sync server now if hosting is enabled, so it runs app-wide
      // for the whole session instead of only while the sync settings page is on
      // screen (BUG-085). Fire-and-forget: a bind failure self-disables + is
      // logged and must never break app init.
      unawaited(syncServerController.startIfEnabled().then((
        HibikiServerStartOutcome outcome,
      ) {
        if (outcome is HibikiServerPortInUse) {
          ErrorLogService.instance.log(
            'AppModel.startSyncServer',
            'port ${outcome.port} in use',
            StackTrace.current,
          );
        } else if (outcome is HibikiServerStartError) {
          ErrorLogService.instance.log(
            'AppModel.startSyncServer',
            outcome.message,
            StackTrace.current,
          );
        }
      }).catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('AppModel.startSyncServer', e, s);
      }));
      if (yomitanApiServerEnabled) {
        unawaited(startYomitanApiServer().catchError((Object _) {}));
      }
      if (texthookerEnabled) {
        TexthookerWsClientHost.instance.start(texthookerUrls);
      }
      notifyListeners();
    } on HibikiDatabaseDowngradeException catch (e, stack) {
      // The DB is newer than this build. drift refused to open it WITHOUT
      // touching the file (no DROP / migration ran). Surface a dedicated,
      // non-retryable notice instead of the generic init-error screen, and
      // STOP — never continue init, never delete or rebuild the DB.
      debugPrint('[Hibiki] init REFUSED (DB downgrade): $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise.downgrade', e, stack);
      _downgradeError = e;
      _initError = '$e';
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
      debugPrint('[Hibiki-popup] init: already initialised, refreshing prefs');
      await refreshPrefCache();
      await _localAudioManager.bindForNativeHandler();
      return;
    }
    try {
      debugPrint('[Hibiki-popup] init: PackageInfo + DeviceInfo');
      _packageInfo = await PackageInfo.fromPlatform();
      await platformServices.init();

      debugPrint('[Hibiki-popup] init: directories');
      await _prepareRuntimeDirectories();

      debugPrint('[Hibiki-popup] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);
      _databaseOpened = true;

      _prefsRepo = PreferencesRepository(_database);
      await prefsRepo.loadFromDb();
      prefsRepo.addListener(notifyListeners);

      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache);
      await dictRepo.loadFromDb();

      mediaHistoryRepo = MediaHistoryRepository(_database);
      await mediaHistoryRepo.loadFromDb();

      // The popup process always runs this full branch (separate :popup
      // process, _isInitialised starts false). PopupDictApp.build() reads
      // appModel.theme/darkTheme/themeMode which delegate to themeNotifier,
      // so it MUST be constructed here exactly as in initialise() — otherwise
      // the late final throws LateInitializationError (HBK-AUDIT-003).
      themeNotifier = ThemeNotifier(_database, () => textTheme);
      themeNotifier.loadFromPrefsSnapshot(prefsRepo.prefsSnapshot);
      themeNotifier.addListener(notifyListeners);
      _themeListenerAdded = true;

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

      await Future.wait(<Future<void>>[
        thumbnailsDirectory.create(recursive: true),
        dictionaryImportWorkingDirectory.create(recursive: true),
        dictionaryResourceDirectory.create(recursive: true),
      ]);
      await _rebuildDictPathsCacheAsync();

      _localAudioManager = LocalAudioManager(
        prefsRepo: prefsRepo,
        databaseDirectory: _databaseDirectory,
      );
      _fileExportManager = FileExportManager(
        exportDirectory: _exportDirectory,
        alternateExportDirectory: _alternateExportDirectory,
      );
      await _localAudioManager.bindForNativeHandler();

      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      MediaSource.setDatabase(_database);
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();

      await Future.wait(<Future<void>>[
        targetLanguage.initialise(),
        ReaderHibikiSource.instance.initialise(),
        Future.wait(<Future<void>>[
          for (Field field in globalFields)
            for (Enhancement enhancement in enhancements[field]!.values)
              enhancement.initialise(),
        ]),
      ]);

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
    // Shortcut bindings are profile-scoped: reload the live registry from the
    // (now-refreshed) source preference so a profile switch takes effect
    // immediately instead of only after an app restart.
    await loadShortcutRegistry(
      shortcutRegistry,
      ReaderHibikiSource.instance,
      defaultTargetPlatform,
    );
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

  // _bindLocalAudioDbForNativeHandler moved to LocalAudioManager.bindForNativeHandler

  // _rowToDictionary, _dictionaryToCompanion, _persistDictionary
  // moved to DictionaryRepository.

  // ── Theme delegates (logic moved to ThemeNotifier) ──────────────────

  static Map<String,
          ({Color seed, Brightness brightness, DynamicSchemeVariant variant})>
      get themePresets => ThemeNotifier.themePresets;

  static String themeLabel(String key) => ThemeNotifier.themeLabel(key);

  String get appThemeKey => themeNotifier.appThemeKey;
  Future<void> setAppThemeKey(String key) => themeNotifier.setAppThemeKey(key);

  String get brightnessMode => themeNotifier.brightnessMode;
  Future<void> setBrightnessMode(String mode) =>
      themeNotifier.setBrightnessMode(mode);

  double get customAppUiScale => themeNotifier.customAppUiScale;
  double get autoAppUiScale => themeNotifier.autoAppUiScale;
  double get appUiScale => themeNotifier.appUiScale;
  Future<void> setAppUiScale(double value) =>
      themeNotifier.setAppUiScale(value);
  double resolveAppUiScaleForViewport({
    required Size viewport,
    required TargetPlatform platform,
  }) =>
      themeNotifier.resolveAppUiScaleForViewport(
        viewport: viewport,
        platform: platform,
      );

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

  /// The lookup/segmentation language. Only one language is registered
  /// (Japanese) and there is no picker, so this returns the sole registered
  /// language directly — no persisted `target_language` pref, no `late`
  /// [languages] map lookup that could miss and crash.
  ///
  /// Returning [JapaneseLanguage.instance] directly (instead of
  /// `languages.values.first`) removes the init-window race: [languages] is a
  /// `late` field only assigned in [populateLanguages] partway through
  /// [initialise], so any widget that rebuilds during early init (before
  /// [populateLanguages]) and reads [targetLanguage] would throw
  /// `LateInitializationError`. [populateLanguages] registers exactly this one
  /// instance, so the value is identical at every point in the lifecycle.
  Language get targetLanguage => JapaneseLanguage.instance;

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

  /// Persist a new app locale in preferences. Restarts the app so every
  /// widget re-resolves [t] with the new locale (Method A lookups don't
  /// automatically rebuild on locale change).
  Future<void> setAppLocale(String localeTag) async {
    await _setPref('app_locale', localeTag);
    LocaleSettings.setLocaleRaw(localeTag);
    if (platformServices.lifecycle.supportsRestart) {
      await platformServices.lifecycle.restartApp();
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

  bool get startupDefaultDictionaryTab => prefsRepo.startupDefaultDictionaryTab;

  Future<void> setStartupDefaultDictionaryTab(bool value) =>
      prefsRepo.setStartupDefaultDictionaryTab(value);

  /// 「视频」功能现已毕业为常驻：首页底栏永久显示「视频」tab、视频页导入入口
  /// 永久放出、书架不再重复显示视频分区。功能仍标记为实验性（底栏图标徽标 +
  /// 视频页提示横幅），但不再受设置开关门控——故此处恒为 true，保持所有调用点
  /// （home_page 底栏 / home_video_page 导入 / 书架视频区门控）逻辑不变。
  bool get experimentalVideoEnabled => true;

  /// 启用的 mpv 着色器（JSON 字符串数组；见 video_shader_manager.dart）。
  String get videoShadersEnabled => prefsRepo.videoShadersEnabled;

  Future<void> setVideoShadersEnabled(String json) =>
      prefsRepo.setVideoShadersEnabled(json);

  /// 用户手动指定的本机 mpv 配置/着色器目录（空=自动）。
  String get videoMpvShaderDir => prefsRepo.videoMpvShaderDir;

  Future<void> setVideoMpvShaderDir(String dir) =>
      prefsRepo.setVideoMpvShaderDir(dir);

  /// 视频字幕模糊（听力沉浸）开关；默认关闭。
  bool get videoSubtitleBlur => prefsRepo.videoSubtitleBlur;

  Future<void> setVideoSubtitleBlur(bool value) =>
      prefsRepo.setVideoSubtitleBlur(value);

  /// 视频字幕列表自动滚动开关（TODO-613，落 Drift preferences，默认开）。
  bool get videoSubtitleListAutoScroll => prefsRepo.videoSubtitleListAutoScroll;

  Future<void> setVideoSubtitleListAutoScroll(bool value) =>
      prefsRepo.setVideoSubtitleListAutoScroll(value);

  /// 播放列表自动连播开关（TODO-639，落 Drift preferences，默认开）。
  bool get videoAutoPlayNext => prefsRepo.videoAutoPlayNext;

  Future<void> setVideoAutoPlayNext(bool value) =>
      prefsRepo.setVideoAutoPlayNext(value);

  bool get videoDanmakuEnabled => prefsRepo.videoDanmakuEnabled;

  Future<void> setVideoDanmakuEnabled(bool value) =>
      prefsRepo.setVideoDanmakuEnabled(value);

  bool get videoDanmakuOnlineEnabled => prefsRepo.videoDanmakuOnlineEnabled;

  Future<void> setVideoDanmakuOnlineEnabled(bool value) =>
      prefsRepo.setVideoDanmakuOnlineEnabled(value);

  int get videoDanmakuMaxActive => prefsRepo.videoDanmakuMaxActive;

  Future<void> setVideoDanmakuMaxActive(int value) =>
      prefsRepo.setVideoDanmakuMaxActive(value);

  /// Dandanplay 弹幕来源配置（自建服务器地址 + 可选 API 凭据）。
  DandanplayConfig get videoDanmakuConfig => prefsRepo.videoDanmakuConfig;

  Future<void> setVideoDanmakuConfig(DandanplayConfig config) =>
      prefsRepo.setVideoDanmakuConfig(config);

  int? getVideoDanmakuEpisodeId(String bookUid) =>
      prefsRepo.getVideoDanmakuEpisodeId(bookUid);

  Future<void> setVideoDanmakuEpisodeId(String bookUid, int episodeId) =>
      prefsRepo.setVideoDanmakuEpisodeId(bookUid, episodeId);

  /// 桌面视频页按视频原始比例锁定原生窗口；默认开启。
  bool get videoLockWindowAspectRatio => prefsRepo.videoLockWindowAspectRatio;

  Future<void> setVideoLockWindowAspectRatio(bool value) =>
      prefsRepo.setVideoLockWindowAspectRatio(value);

  /// 视频画面缩放/比例模式（窗口+全屏 Video fit；默认 cover=保持比例占满无黑边）。
  VideoFitMode get videoFitMode => prefsRepo.videoFitMode;

  Future<void> setVideoFitMode(VideoFitMode mode) =>
      prefsRepo.setVideoFitMode(mode);

  String get videoAsbplayerConfig => prefsRepo.videoAsbplayerConfig;

  Future<void> setVideoAsbplayerConfig(String json) =>
      prefsRepo.setVideoAsbplayerConfig(json);

  VideoControlCustomization get videoControlCustomization =>
      prefsRepo.videoControlCustomization;

  Future<void> setVideoControlCustomization(
    VideoControlCustomization customization,
  ) =>
      prefsRepo.setVideoControlCustomization(customization);

  /// 视频控制按钮 9-槽位布局（TODO-274/312 phase 2，与 legacy 共用持久化键，v1 自动迁移）。
  VideoControlLayout get videoControlLayout => prefsRepo.videoControlLayout;

  Future<void> setVideoControlLayout(VideoControlLayout layout) =>
      prefsRepo.setVideoControlLayout(layout);

  /// 视频字幕外观（JSON；见 VideoSubtitleStyle）。
  String get videoSubtitleStyle => prefsRepo.videoSubtitleStyle;

  Future<void> setVideoSubtitleStyle(String json) =>
      prefsRepo.setVideoSubtitleStyle(json);

  /// 视频 mpv 配置（JSON；见 VideoMpvConfig）。
  String get videoMpvConfig => prefsRepo.videoMpvConfig;

  Future<void> setVideoMpvConfig(String json) =>
      prefsRepo.setVideoMpvConfig(json);

  VideoImmersiveMode get videoImmersiveMode => prefsRepo.videoImmersiveMode;

  Future<void> setVideoImmersiveMode(VideoImmersiveMode mode) =>
      prefsRepo.setVideoImmersiveMode(mode);

  /// Jimaku API key（自动获取日语字幕）。
  String get jimakuApiKey => prefsRepo.jimakuApiKey;

  Future<void> setJimakuApiKey(String key) => prefsRepo.setJimakuApiKey(key);

  bool get reverseNavigationBar => prefsRepo.reverseNavigationBar;
  void toggleReverseNavigationBar() => prefsRepo.toggleReverseNavigationBar();

  bool get reverseReaderBottomBar => prefsRepo.reverseReaderBottomBar;
  void toggleReverseReaderBottomBar() =>
      prefsRepo.toggleReverseReaderBottomBar();

  /// Show the dictionary menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  Future<void> showDictionaryMenu({
    List<String> initialImportPaths = const <String>[],
  }) async {
    final ctx = _ctx;
    if (ctx == null) return;
    await Navigator.push(
      ctx,
      adaptivePageRoute(
        context: ctx,
        builder: (context) => DictionaryDialogPage(
          initialImportPaths: initialImportPaths,
        ),
      ),
    );

    notifyListeners();
    dictionaryMenuNotifier.notifyListeners();
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

  // ── dictionary import (delegated to DictionaryImportManager) ────────

  Future<void> importDictionaryFromDirectory({
    required Directory directory,
    required ValueNotifier<String> progressNotifier,
    required ValueNotifier<int?> countNotifier,
    required ValueNotifier<int?> totalNotifier,
    required Function() onImportSuccess,
    VoidCallback? onMemoryError,
  }) =>
      _dictImportManager.importFromDirectory(
        directory: directory,
        progressNotifier: progressNotifier,
        countNotifier: countNotifier,
        totalNotifier: totalNotifier,
        onImportSuccess: onImportSuccess,
        lowMemoryMode: lowMemoryMode,
        onMemoryError: onMemoryError,
      );

  Future<void> importDictionary({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    List<File> cssFiles = const [],
    List<Directory> fontDirs = const [],
    VoidCallback? onMemoryError,
    // TODO-609：在线更新走 force=true（同名直接重导）+ sourceOverride（catalog 的
    // 下载/index URL 回填来源）。默认 null/false，本地导入向后兼容、行为不变。
    bool forceReplaceExisting = false,
    Map<String, String>? sourceOverride,
  }) =>
      _dictImportManager.importFromFile(
        file: file,
        progressNotifier: progressNotifier,
        onImportSuccess: onImportSuccess,
        lowMemoryMode: lowMemoryMode,
        cssFiles: cssFiles,
        fontDirs: fontDirs,
        onMemoryError: onMemoryError,
        forceReplaceExisting: forceReplaceExisting,
        sourceOverride: sourceOverride,
      );

  void toggleDictionaryCollapsed(Dictionary dictionary) => dictRepo
      .toggleDictionaryCollapsed(dictionary, targetLanguage.languageCode);

  void toggleDictionaryHidden(Dictionary dictionary) {
    dictRepo.toggleDictionaryHidden(dictionary, targetLanguage.languageCode);
    // toggleDictionaryHidden persists the dict, which fires _onCacheRebuild
    // (_rebuildDictPathsCache) and reloads the engine WITHOUT the now-hidden
    // freq/pitch dictionary. But a popupJson cached while the dict was still
    // enabled would keep showing its values on the next (cache-hit) lookup, so
    // drop the search caches too — mirrors the delete paths (BUG-171/BUG-177).
    dictRepo.clearDictionaryResultsCache();
  }

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
      // Reload the native FFI engine off the now-empty dictionary set so every
      // previously loaded index is dropped; otherwise queries keep hitting the
      // deleted dictionaries until the app restarts (BUG-171). With no
      // dictionaries left this rebuilds into an empty engine that
      // searchDictionary already degrades to empty results.
      _rebuildDictPathsCache();
    } catch (e, stack) {
      ErrorLogService.instance.log('deleteDictionaries', e, stack);
      HibikiToast.show(msg: t.dictionaries_delete_failed);
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
      // Propagate the deletion to the remote sync staging area so the package
      // does not become an orphan that union-sync re-pulls forever (phantom
      // dictionary + slow sync, BUG-086). Best-effort + serialized with sync;
      // never blocks or fails the local delete.
      unawaited(_propagateDictionaryDeleteToRemote(dictionary.name));
    } catch (e, stack) {
      ErrorLogService.instance.log('deleteDictionary', e, stack);
      HibikiToast.show(msg: t.dictionary_delete_failed);
    } finally {
      dictionarySearchAgainNotifier.notifyListeners();
    }
  }

  /// Best-effort removal of a deleted dictionary's package from the remote sync
  /// staging namespace (BUG-086). Only runs when dictionary sync is enabled and
  /// the backend is configured/authenticated; offline / unconfigured / errors
  /// are swallowed (logged) so a local delete never depends on the network.
  /// Serialized through the sync mutex so it can't race an in-flight sync on the
  /// singleton backend (the BUG-083 hazard).
  Future<void> _propagateDictionaryDeleteToRemote(String name) async {
    try {
      final SyncRepository repo = SyncRepository(database);
      if (!await repo.isSyncDictionaryEnabled()) return;
      final SyncBackend backend =
          resolveSyncBackend(await repo.getBackendType());
      await runExclusiveWithSync(() async {
        if (!await backend.restoreAuth(repo)) return;
        if (!await backend.isAuthenticated) return;
        // 互联（live）后端直接走 host DELETE 端点；云后端走暂存删除路径。
        if (backend is HibikiClientSyncBackend) {
          await backend.deleteRemoteDictionary(name);
          return;
        }
        await deleteRemoteDictionaryAsset(backend, name);
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('deleteDictionary.remote', e, stack);
    }
  }

  void clearDictionaryResultsCache() => dictRepo.clearDictionaryResultsCache();

  /// Gets the raw unprocessed entries straight from a dictionary database
  /// given a search term. This will be processed later for user viewing.
  /// True when [text] is exactly one CJK ideograph (a single kanji), counted by
  /// runes so astral-plane characters (CJK Extension B+, encoded as a surrogate
  /// pair in a Dart String) are treated as one character rather than two. Only a
  /// single-kanji lookup is eligible for a kanji-dictionary query; multi-character
  /// terms and kana/latin singletons skip it so the term-lookup path keeps its
  /// current zero-overhead behaviour.
  static bool isSingleKanji(String text) {
    final List<int> runes = text.runes.toList();
    if (runes.length != 1) return false;
    return _isKanjiCodePoint(runes.single);
  }

  /// Unicode block test for Han ideographs (no kana_kit dependency in this
  /// layer). Covers the CJK Unified Ideographs block, its common extensions, and
  /// compatibility ideographs — the same ranges a kanji dictionary indexes.
  static bool _isKanjiCodePoint(int cp) {
    return (cp >= 0x4E00 && cp <= 0x9FFF) || // CJK Unified Ideographs
        (cp >= 0x3400 && cp <= 0x4DBF) || // Extension A
        (cp >= 0x20000 && cp <= 0x2A6DF) || // Extension B
        (cp >= 0x2A700 && cp <= 0x2EBEF) || // Extensions C–F
        (cp >= 0x30000 && cp <= 0x3134F) || // Extensions G–H
        (cp >= 0xF900 && cp <= 0xFAFF) || // CJK Compatibility Ideographs
        (cp >= 0x2F800 && cp <= 0x2FA1F); // Compatibility Ideographs Supplement
  }

  /// Queries the kanji dictionary bucket for a single-character lookup and
  /// returns the per-character kanji results to attach to a
  /// [DictionarySearchResult]. Returns an empty list for multi-character terms,
  /// non-kanji singletons, or when no kanji dictionary is loaded — so the term
  /// lookup path is never slowed for ordinary word lookups. The engine call is
  /// only made for a real single kanji (TODO-094 S4).
  List<HoshiKanjiResult> queryKanjiForTerm(String searchTerm) {
    if (!isSingleKanji(searchTerm)) return const <HoshiKanjiResult>[];
    if (!HoshiDicts.isInitialized) return const <HoshiKanjiResult>[];
    return HoshiDicts.instance.queryKanji(searchTerm);
  }

  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    final swTotal = Stopwatch()..start();
    final swPreprocess = Stopwatch()..start();

    final NormalizedSearchTerm normalized = normalizeSearchTerm(
      searchTerm,
      emojiRegex: _emojiRegex,
      punctuationRegex: _punctuationRegex,
      loneSurrogateRegex: _loneSurrogateRegex,
    );
    searchTerm = normalized.term;

    swPreprocess.stop();
    debugPrint('[dict-perf] preprocess: ${swPreprocess.elapsedMilliseconds}ms '
        '(emoji=${normalized.emojiMicros}µs '
        'punct=${normalized.punctMicros}µs '
        'surrogate=${normalized.surrogateMicros}µs) '
        '"$searchTerm"');

    if (searchTerm.trim().isEmpty) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    final int effectiveMaxTerms = overrideMaximumTerms ?? maximumTerms;
    final bool tryRemoteFirst = allowRemoteLookup && remoteLookupEnabled;
    if (tryRemoteFirst) {
      final DictionarySearchResult? remoteResult =
          await _searchRemoteDictionary(
        searchTerm: searchTerm,
        searchWithWildcards: searchWithWildcards,
        maximumTerms: effectiveMaxTerms,
      );
      if (remoteResult != null) {
        return remoteResult;
      }
    }

    final String cacheKey = buildSearchCacheKey(
      term: searchTerm,
      maxTerms: effectiveMaxTerms,
      maxResults: maximumDictionarySearchResults,
    );

    final cached = dictRepo.getCachedSearch(cacheKey);
    if (useCache && cached != null) {
      swTotal.stop();
      debugPrint('[dict-perf] cache HIT: ${swTotal.elapsedMilliseconds}ms');
      return cached;
    }

    if (!HoshiDicts.isInitialized) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    // Kanji dictionary lookup is orthogonal to the term index: a single kanji
    // can be both a term headword and a kanji entry, so we query the kanji
    // bucket independently and attach the results to whatever term result comes
    // back (or surface a kanji-only result when no term matches). Computed once
    // here so all local FFI return paths below carry the same kanji payload.
    final List<HoshiKanjiResult> kanjiResults = queryKanjiForTerm(searchTerm);

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
      result.popupJson = HoshiDicts.instance.lookupPopupJson(
        searchTerm,
        maxResults: maximumDictionarySearchResults,
        maxTerms: effectiveMaxTerms,
      );
      result = result.withKanjiResults(kanjiResults);
      swBuild.stop();
      debugPrint(
          '[dict-perf] FFI cache HIT, buildResult+popupJson: ${swBuild.elapsedMilliseconds}ms entries=${result.entries.length}');
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
        result.popupJson = HoshiDicts.instance.lookupPopupJson(
          searchTerm,
          maxResults: maximumDictionarySearchResults,
          maxTerms: effectiveMaxTerms,
        );
        result = result.withKanjiResults(kanjiResults);
      }
      swLookup.stop();
      debugPrint(
          '[dict-perf] FFI lookup + build + popupJson: ${swLookup.elapsedMilliseconds}ms entries=${result?.entries.length ?? 0}');
    }

    swTotal.stop();
    debugPrint(
        '[dict-perf] searchDictionary total: ${swTotal.elapsedMilliseconds}ms');

    if (result != null && result.entries.isNotEmpty) {
      dictRepo.cacheSearchResult(cacheKey, result);
      return result;
    }
    // No term match, but a single-kanji lookup hit the kanji dictionary: return
    // a kanji-only result so the popup can still render the kanji card. Cached
    // like a term result so a repeat lookup is served from cache.
    if (kanjiResults.isNotEmpty) {
      final DictionarySearchResult kanjiOnly = DictionarySearchResult(
        searchTerm: searchTerm,
        kanjiResults: kanjiResults,
      );
      dictRepo.cacheSearchResult(cacheKey, kanjiOnly);
      return kanjiOnly;
    }
    if (allowRemoteLookup && !tryRemoteFirst) {
      final DictionarySearchResult? remoteResult =
          await _searchRemoteDictionary(
        searchTerm: searchTerm,
        searchWithWildcards: searchWithWildcards,
        maximumTerms: effectiveMaxTerms,
      );
      if (remoteResult != null) {
        return remoteResult;
      }
    }
    return DictionarySearchResult(searchTerm: searchTerm);
  }

  Future<DictionarySearchResult?> _searchRemoteDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    required int maximumTerms,
  }) async {
    if (!remoteLookupEnabled) return null;
    try {
      return HibikiRemoteLookupClient(repo: SyncRepository(_database))
          .searchDictionary(
        term: searchTerm,
        wildcards: searchWithWildcards,
        maximumTerms: maximumTerms,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('remoteDictionaryLookup', e, stack);
      return null;
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
    if (await platformServices.permission.hasExternalStoragePermission() &&
        await platformServices.permission.hasCameraPermission()) {
      return;
    }
    if (isFirstTimeSetup) {
      HibikiToast.show(
        msg: t.storage_permissions,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    }

    await platformServices.permission.requestCameraPermission();
    await platformServices.permission.requestExternalStoragePermission();
  }

  // ── Anki integration (delegated to AnkiIntegration) ─────────────────

  static const MethodChannel methodChannel = HibikiChannels.anki;

  Future<void> showAnkidroidApiMessage() =>
      ankiIntegration.showApiMessage(_ctx);

  Future<void> requestAnkidroidPermissions() =>
      ankiIntegration.requestPermissions();

  Future<List<String>> getDecks() => ankiIntegration.getDecks(_ctx);

  Future<List<String>> getModelList() => ankiIntegration.getModelList(_ctx);

  DictionaryFormat getDictionaryFormat(Dictionary dictionary) =>
      dictionaryFormats[dictionary.formatKey]!;

  Future<List<String>> getFieldList(String model) =>
      ankiIntegration.getFieldList(model, _ctx);

  // ── file export (delegated to FileExportManager) ───────────────────

  File getImageExportFile({bool fallback = false}) =>
      _fileExportManager.getImageExportFile(fallback: fallback);

  File getImageCompressedFile({bool fallback = false}) =>
      _fileExportManager.getImageCompressedFile(fallback: fallback);

  File getAudioExportFile({bool fallback = false, String ext = 'mp3'}) =>
      _fileExportManager.getAudioExportFile(fallback: fallback, ext: ext);

  File getPreviewImageFile(Directory directory, int index) =>
      _fileExportManager.getPreviewImageFile(directory, index);

  File getAudioPreviewFile(Directory directory, {String ext = 'mp3'}) =>
      _fileExportManager.getAudioPreviewFile(directory, ext: ext);

  File getThumbnailFile() => _fileExportManager.getThumbnailFile();

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
      } catch (e) {
        debugPrint('[Hibiki] wakelock enable failed: $e');
      }
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
    audioCtrl.audioHandler?.mediaItem.add(null);

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
    } catch (e) {
      debugPrint('[Hibiki] wakelock disable failed: $e');
    }
    // Returning to the home/menu shell: hide the Android status bar again
    // (TODO-097) instead of plain edge-to-edge. iOS/desktop unchanged.
    await setHomeShellSystemUiMode();
    await mediaSource.onSourceExit(
      appModel: this,
      ref: ref,
    );

    await audioCtrl.audioHandler?.stop();

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
    if (!isAndroidPlatform) {
      final ctx = _ctx;
      if (ctx == null || !ctx.mounted) return;
      await showAppDialog(
        context: ctx,
        builder: (dialogContext) => HibikiDialogFrame(
          maxWidth: 520,
          maxHeightFactor: 0.80,
          insetPadding: const EdgeInsets.all(24),
          scrollable: false,
          child: PopupDictionaryPage(
            searchTerm: trimmed,
            closeInApp: () => Navigator.of(dialogContext).pop(),
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
    platformServices.clipboard.copyToClipboard(term);

    /// Redundant to do this with the share notification on Android 33+
    if (platformServices.clipboard.shouldShowCopyToast) {
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

    final List<String> defaultPaths =
        await platformServices.directory.getDefaultPickerDirectories();
    for (final String dirPath in defaultPaths) {
      final Directory directory = Directory(dirPath);
      if (!directories.contains(directory)) {
        directories.add(directory);
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

  // TODO-702：有声书退出即停（默认）/ 后台续播（可选）。转发偏好仓库。
  bool get audiobookBackgroundPlay => prefsRepo.audiobookBackgroundPlay;
  Future<void> setAudiobookBackgroundPlay({required bool value}) =>
      prefsRepo.setAudiobookBackgroundPlay(value: value);

  bool get showSubtitlesInNotification => prefsRepo.showSubtitlesInNotification;
  void setShowSubtitlesInNotification({required bool value}) =>
      prefsRepo.setShowSubtitlesInNotification(value: value);

  bool get playerUseOpenSLES => prefsRepo.playerUseOpenSLES;
  void setPlayerUseOpenSLES({required bool value}) =>
      prefsRepo.setPlayerUseOpenSLES(value: value);

  // ── player streams & audio handler (delegated to AudioController) ───

  Stream<void> get playStream => audioCtrl.playStream;
  Stream<Duration> get seekStream => audioCtrl.seekStream;
  Stream<void> get rewindStream => audioCtrl.rewindStream;
  Stream<void> get fastForwardStream => audioCtrl.fastForwardStream;
  Stream<void> get skipNextStream => audioCtrl.skipNextStream;
  Stream<void> get skipPreviousStream => audioCtrl.skipPreviousStream;
  Stream<void> get toggleFloatingLyricStream =>
      audioCtrl.toggleFloatingLyricStream;

  HibikiAudioHandler? get audioHandler => audioCtrl.audioHandler;

  Future<void> initialiseAudioHandler() => audioCtrl.initialiseHandler();

  // ── 进程级常驻有声书会话编排（TODO-291 阶段2） ─────────────────────────

  /// app 级（无 reader）悬浮窗样式：用全局主题色，背景跟随当前明暗。reader attach
  /// 时会用 reader 主题样式覆盖。
  FloatingLyricStyle _appLevelFloatingLyricStyle() {
    final Brightness brightness =
        themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light;
    final ColorScheme scheme = buildColorScheme(brightness);
    final bool dark = brightness == Brightness.dark;
    final Color bg = scheme.surface;
    final Color fg = scheme.onSurface;
    final Color accent = scheme.primary;
    final int textOpacity = floatingLyricTextOpacity;
    final int buttonBgOpacity = floatingLyricButtonBgOpacity;
    final int bgOpacity = floatingLyricBgOpacity;
    return FloatingLyricStyle(
      fontSize: floatingLyricFontSize,
      // TODO-370: 文字 / 按钮底色透明度按设置缩放 alpha（默认 100=保持原观感）。
      textColor: FloatingLyricStyle.scaleAlpha(fg.value, textOpacity),
      // TODO-576: 条背景透明度按设置缩放 alpha（默认 70=更不挡视野）。
      bgColor: FloatingLyricStyle.scaleAlpha(
        bg.withAlpha(dark ? 230 : 220).value,
        bgOpacity,
      ),
      buttonTextColor: fg.value,
      buttonBgColor: FloatingLyricStyle.scaleAlpha(
        (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
        buttonBgOpacity,
      ),
      highlightColor: accent.withAlpha(128).value,
      activeColor: accent.value,
    );
  }

  /// 通知栏「悬浮字幕」custom action / 设置开关翻转悬浮窗（含偏好读写）。返回 false
  /// 表示开启失败（如缺 overlay 权限）。
  Future<bool> toggleFloatingLyricFromControls() async {
    final bool currentlyOn = showFloatingLyric;
    final bool ok =
        await audiobookSession.toggleFloatingLyric(currentlyOn: currentlyOn);
    if (!ok) return false;
    await setShowFloatingLyric(!currentlyOn);
    notifyListeners();
    return true;
  }

  /// 书架长按「悬浮字幕」入口：启动该书的后台听书会话（无正在播则用该书启动；已有
  /// 别的书在播则顶掉切到该书）。同时打开悬浮窗偏好并拉起悬浮窗。返回结果供 UI 提示。
  Future<BackgroundListenResult> startBackgroundListening(
      String bookKey) async {
    await initialiseAudioHandler();
    final AudiobookSessionLauncher launcher =
        AudiobookSessionLauncher(database);
    final AudiobookSessionStartRequest? req = await launcher.resolve(bookKey);
    if (req == null) {
      return BackgroundListenResult.noAudio;
    }
    // 开启悬浮窗偏好，让 session.start 的 _startBackgroundSurfaces 自动拉起悬浮窗。
    if (!showFloatingLyric) {
      await setShowFloatingLyric(true);
    }
    try {
      final controller = await audiobookSession.start(
        info: req.info,
        audioFiles: req.audioFiles,
        prefs: req.prefs,
        persist: req.persist,
        // 灌全书 cue：后台听书无 reader 喂 cue，否则悬浮窗推空串（TODO-354 根因②）。
        cues: req.cues,
      );
      if (controller == null) return BackgroundListenResult.loadFailed;
    } catch (e, stack) {
      ErrorLogService.instance
          .log('AppModel.startBackgroundListening', e, stack);
      return BackgroundListenResult.loadFailed;
    }
    // 无正在播则用该书开播（用户决策④：无正在播 → 用该书启动）。
    final controller = audiobookSession.controller;
    if (controller != null && !controller.isPlaying) {
      await controller.play();
    }
    notifyListeners();
    return BackgroundListenResult.started;
  }

  /// 停止后台听书会话（迷你条 / 悬浮窗关闭 → 完全停止）。
  Future<void> stopBackgroundListening() async {
    await audiobookSession.stop();
    if (showFloatingLyric) {
      await setShowFloatingLyric(false);
    }
    notifyListeners();
  }

  /// 首页「正在听书」迷你条「回到书」：打开当前后台会话所属书的 reader 页。
  /// 重建 MediaItem（迷你条手头无现成 item）；解析不到（如 standalone SRT 无 EPUB 行）
  /// 时静默不导航（迷你条仍可用 stop / 状态显示）。
  Future<void> openBackgroundListeningBook(WidgetRef ref) async {
    final SessionBookInfo? info = audiobookSession.book;
    if (info == null) return;
    final ReaderHibikiSource source = ReaderHibikiSource.instance;
    final MediaItem? item = await source.mediaItemForBookKey(info.bookKey);
    if (item == null) return;
    await openMedia(ref: ref, mediaSource: source, item: item);
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

  double get defaultPopupMaxHeight => prefsRepo.defaultPopupMaxHeight;
  double get popupMaxHeight => prefsRepo.popupMaxHeight;
  void setPopupMaxHeight(double height) => prefsRepo.setPopupMaxHeight(height);

  bool get popupInstantScroll => prefsRepo.popupInstantScroll;
  Future<void> setPopupInstantScroll(bool value) =>
      prefsRepo.setPopupInstantScroll(value);

  bool get popupBottomDocked => prefsRepo.popupBottomDocked;
  Future<void> setPopupBottomDocked(bool value) =>
      prefsRepo.setPopupBottomDocked(value);

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

  /// Close the database and notify listeners, without exiting the app.
  Future<void> closeDatabase() async {
    _isInitialised = false;
    databaseCloseNotifier.notifyListeners();
    await _database.close();
  }

  /// Safely shutdown and stop database operations.
  Future<void> shutdown() async {
    await closeDatabase();
    await platformServices.lifecycle.exitApp();
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
    if (_themeListenerAdded) {
      themeNotifier.removeListener(notifyListeners);
      themeNotifier.dispose();
    }
    dictionaryEntriesNotifier.dispose();
    dictionarySearchAgainNotifier.dispose();
    dictionaryMenuNotifier.dispose();
    incognitoNotifier.dispose();
    databaseCloseNotifier.dispose();
    homeDictionaryTabRequest.dispose();
    // session 的控制流订阅引用 audioCtrl 的 stream，须在 audioCtrl.dispose 前拆。
    audiobookSession.dispose();
    audioCtrl.dispose();
    gamepadService.dispose();
    // Dispose the extracted repository notifiers (all ChangeNotifiers). Only
    // when fully initialised — a failed/partial init leaves these `late`
    // fields unassigned, and reading them would throw.
    _prefsRepo?.dispose();
    if (_isInitialised) {
      dictRepo.dispose();
      mediaHistoryRepo.dispose();
    }
    super.dispose();
  }

  Future<void> moveToBack() async {
    try {
      await platformServices.lifecycle.moveTaskToBack();
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

  bool get remoteLookupEnabled => prefsRepo.remoteLookupEnabled;
  Future<void> setRemoteLookupEnabled(bool value) =>
      prefsRepo.setRemoteLookupEnabled(value);

  bool get yomitanApiServerEnabled => prefsRepo.yomitanApiServerEnabled;
  Future<void> setYomitanApiServerEnabled(bool value) =>
      prefsRepo.setYomitanApiServerEnabled(value);

  int get yomitanApiPort => prefsRepo.yomitanApiPort;
  Future<void> setYomitanApiPort(int value) =>
      prefsRepo.setYomitanApiPort(value);

  String get yomitanApiKey => prefsRepo.yomitanApiKey;
  Future<void> setYomitanApiKey(String value) =>
      prefsRepo.setYomitanApiKey(value);

  /// 实验性：整套键盘/手柄焦点导航是否启用（默认 false）。关闭时 main.dart 不安装
  /// HibikiFocusRoot/Ring，App 回退到 Flutter 原生焦点遍历。
  bool get experimentalFocusNavigationEnabled =>
      prefsRepo.experimentalFocusNavigationEnabled;
  Future<void> setExperimentalFocusNavigationEnabled(bool value) =>
      prefsRepo.setExperimentalFocusNavigationEnabled(value);

  bool get texthookerEnabled => prefsRepo.texthookerEnabled;
  Future<void> setTexthookerEnabled(bool value) =>
      prefsRepo.setTexthookerEnabled(value);

  List<String> get texthookerUrls => prefsRepo.texthookerUrls;
  Future<void> setTexthookerUrls(List<String> urls) =>
      prefsRepo.setTexthookerUrls(urls);

  bool get desktopClipboardEnabled => prefsRepo.desktopClipboardEnabled;
  Future<void> setDesktopClipboardEnabled(bool v) =>
      prefsRepo.setDesktopClipboardEnabled(v);
  bool get desktopClipboardAlwaysOnTop => prefsRepo.desktopClipboardAlwaysOnTop;
  Future<void> setDesktopClipboardAlwaysOnTop(bool v) =>
      prefsRepo.setDesktopClipboardAlwaysOnTop(v);
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      prefsRepo.desktopClipboardWindowMode;
  Future<void> setDesktopClipboardWindowMode(
      DesktopClipboardWindowMode v) async {
    await prefsRepo.setDesktopClipboardWindowMode(v);
    if (DesktopLookupService.isDesktop) {
      await DesktopLookupService.instance.configureWindowMode(v);
    }
  }

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

  List<AudioSourceConfig> get audioSourceConfigs {
    final List<AudioSourceConfig> saved = prefsRepo.audioSourceConfigs;
    final Map<String, LocalAudioDbEntry> localByPath =
        <String, LocalAudioDbEntry>{
      for (final LocalAudioDbEntry db in localAudioDbs) db.path: db,
    };
    final Set<String> savedLocalPaths = saved
        .where((AudioSourceConfig source) =>
            source.kind == AudioSourceKind.localAudio &&
            localByPath.containsKey(source.path))
        .map((AudioSourceConfig source) => source.path ?? '')
        .where((String value) => value.isNotEmpty)
        .toSet();
    return <AudioSourceConfig>[
      for (final AudioSourceConfig source in saved)
        if (source.kind != AudioSourceKind.localAudio)
          source
        else if (localByPath.containsKey(source.path))
          AudioSourceConfig.localAudio(
            label: localByPath[source.path]!.displayName,
            path: source.path!,
            enabled: localByPath[source.path]!.enabled,
          ),
      for (final LocalAudioDbEntry db in localAudioDbs)
        if (!savedLocalPaths.contains(db.path))
          AudioSourceConfig.localAudio(
            label: db.displayName,
            path: db.path,
            enabled: db.enabled,
          ),
    ];
  }

  List<AudioSourceConfig> get enabledAudioSourceConfigs => audioSourceConfigs
      .where((AudioSourceConfig source) => source.enabled)
      .toList(growable: false);

  List<String> get enabledAudioSources {
    final List<AudioSourceConfig> configs = enabledAudioSourceConfigs;
    if (configs.isNotEmpty) {
      return configs
          .map((AudioSourceConfig source) {
            switch (source.kind) {
              case AudioSourceKind.hibikiRemote:
                return WordAudioResolver.hibikiRemoteAudioUrl;
              case AudioSourceKind.localAudio:
                return WordAudioResolver.localAudioUrl;
              case AudioSourceKind.remoteAudio:
                return source.url ?? '';
            }
          })
          .where((String source) => source.isNotEmpty)
          .toList(growable: false);
    }
    final List<String> sources = audioSources
        .where((source) => source != WordAudioResolver.localAudioUrl)
        .toList(growable: false);
    // 删了 master 总开关后，本地音频是否参与 legacy 回退路径，
    // 由「是否存在已启用的本地库」决定（与 typed-config 路径语义一致）。
    if (!localAudioDbs.any((LocalAudioDbEntry e) => e.enabled)) return sources;

    return <String>[
      WordAudioResolver.localAudioUrl,
      ...sources,
    ];
  }

  void setAudioSources(List<String> sources) =>
      prefsRepo.setAudioSources(sources);

  /// [sourcesByPath] 为指定 path 的**新增** local-audio 库预置子来源偏好，让
  /// 注册同步库时一次写穿（避免随后再调 setLocalAudioDbSources 二次落盘 + 二次推
  /// native）。仅对 [current] 里尚不存在的库生效；已有库的子来源以现存为准（按
  /// path 经 copyWith 继承），不被覆盖。
  Future<void> setAudioSourceConfigs(
    List<AudioSourceConfig> sources, {
    Map<String, List<LocalAudioSourcePref>> sourcesByPath =
        const <String, List<LocalAudioSourcePref>>{},
  }) async {
    await prefsRepo.setAudioSourceConfigs(sources);
    final Map<String, LocalAudioDbEntry> current = <String, LocalAudioDbEntry>{
      for (final LocalAudioDbEntry db in localAudioDbs) db.path: db,
    };
    final List<LocalAudioDbEntry> nextDbs = <LocalAudioDbEntry>[
      for (final AudioSourceConfig source in sources)
        if (source.kind == AudioSourceKind.localAudio &&
            (source.path?.isNotEmpty ?? false))
          (current[source.path] ??
                  LocalAudioDbEntry(
                    path: source.path!,
                    displayName: source.displayLabel,
                    enabled: source.enabled,
                    sources: sourcesByPath[source.path] ??
                        const <LocalAudioSourcePref>[],
                  ))
              .copyWith(
            displayName: source.displayLabel,
            enabled: source.enabled,
          ),
    ];
    await _localAudioManager.setEntries(nextDbs);
    // 回收所有不再被引用的本地音频副本（含曾持久化已移除 + 拷贝但从未持久化的孤儿）。
    await _localAudioManager.pruneOrphans(
      nextDbs.map((LocalAudioDbEntry db) => db.path),
    );
  }

  Future<String?> lookupRemoteAudio(
    String expression,
    String reading,
  ) async {
    // 远端音频是否查询由「管理音频来源」对话框里的 hibikiRemote 源 enabled 决定
    // （resolveConfigured 只在该源 enabled 时才调用这里）；与词典远端开关 remoteLookupEnabled 无关。
    try {
      return HibikiRemoteLookupClient(repo: SyncRepository(_database))
          .lookupAudioUrl(expression: expression, reading: reading);
    } catch (e, stack) {
      ErrorLogService.instance.log('remoteAudioLookup', e, stack);
      return null;
    }
  }

  HibikiRemoteLookupService createRemoteLookupService() {
    return _AppModelRemoteLookupService(this);
  }

  HibikiRemoteMiningService createRemoteMiningService() {
    return _AppModelRemoteLookupService(this);
  }

  HibikiRemoteHistoryService createRemoteHistoryService() {
    return _AppModelRemoteLookupService(this);
  }

  // ── yomitan-api server (lifecycle) ──────────────────────────────────
  YomitanApiServerManager? _yomitanServerManager;

  YomitanApiServerManager _ensureYomitanManager() {
    return _yomitanServerManager ??= YomitanApiServerManager(
      lookupService: createRemoteLookupService(),
      tokenizer: JapaneseLanguage.instance.textToWords,
      readingResolver: (String w) {
        if (!HoshiDicts.isInitialized) return '';
        final List<HoshiLookupResult> r =
            HoshiDicts.instance.lookup(w, maxResults: 1);
        return r.isEmpty ? '' : r.first.term.reading;
      },
    );
  }

  Future<void> startYomitanApiServer() async {
    try {
      await _ensureYomitanManager()
          .start(port: yomitanApiPort, apiKey: yomitanApiKey);
    } on SyncServerPortInUseException {
      await setYomitanApiServerEnabled(false);
      rethrow;
    }
  }

  Future<void> stopYomitanApiServer() async {
    await _yomitanServerManager?.stop();
  }

  // ── local audio DB (delegated to LocalAudioManager) ─────────────────

  List<LocalAudioDbEntry> get localAudioDbs => _localAudioManager.entries;

  /// 把外部音频库文件拷进库目录，返回内部副本 entry（不写 prefs、不通知 native）。
  /// 持久化交给后续 [setAudioSourceConfigs]。
  Future<LocalAudioDbEntry> importLocalAudioDbFile(
    String sourcePath, {
    required String displayName,
  }) =>
      _localAudioManager.importFile(sourcePath, displayName: displayName);

  Future<void> setLocalAudioDbs(List<LocalAudioDbEntry> dbs) =>
      _localAudioManager.setEntries(dbs);

  /// 枚举一个本地音频库内的全部子来源名（用于「编辑来源」对话框）。
  Future<List<String>> listLocalAudioSources(String path) =>
      TtsChannel.instance.listLocalAudioSources(path);

  /// 该库当前已存的子来源偏好（优先级序 + 逐源启用）；未配置返回空。
  List<LocalAudioSourcePref> sourcePrefsForLocalDb(String path) {
    for (final LocalAudioDbEntry e in _localAudioManager.entries) {
      if (e.path == path) return e.sources;
    }
    return const <LocalAudioSourcePref>[];
  }

  /// 设置某库的子来源偏好，立即持久化并重推 native。
  Future<void> setLocalAudioDbSources(
      String path, List<LocalAudioSourcePref> prefs) async {
    await _localAudioManager.setSourcesFor(path, prefs);
    notifyListeners();
  }

  /// 同步拉到一个远端本地音频库：把 staging 的 .db 拷进本机库目录（重建本机 path，
  /// 绝不复用远端 manifest 的绝对 path——它在本机不存在），经 [setAudioSourceConfigs]
  /// 双写 `audio_source_configs` + `local_audio_dbs` + 推 native，再还原子来源偏好
  /// 并刷 UI。按 displayName 去重（已存在则跳过）。
  ///
  /// 由 [SyncOrchestrator.onLocalAudioImported] 调用，故注册逻辑集中在此（拥有
  /// LocalAudioManager 的 AppModel），保持双真相源一致。
  Future<void> importSyncedLocalAudioDb(LocalAudioPackageContents c) async {
    final bool exists = audioSourceConfigs.any((AudioSourceConfig s) =>
        s.kind == AudioSourceKind.localAudio &&
        s.displayLabel == c.displayName);
    if (exists) return;
    if (!await c.dbFile.exists()) return;
    final LocalAudioDbEntry entry =
        await importLocalAudioDbFile(c.dbFile.path, displayName: c.displayName);
    final AudioSourceConfig cfg = AudioSourceConfig.localAudio(
      label: c.displayName,
      path: entry.path,
      enabled: c.enabled,
    );
    // 一次写穿：把子来源偏好随新库一起 bake 进 setEntries，省掉随后再调
    // setLocalAudioDbSources 的二次 prefs 写 + 二次 native 全量重推。
    await setAudioSourceConfigs(
      <AudioSourceConfig>[...audioSourceConfigs, cfg],
      sourcesByPath: c.sources.isEmpty
          ? const <String, List<LocalAudioSourcePref>>{}
          : <String, List<LocalAudioSourcePref>>{entry.path: c.sources},
    );
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

  bool get floatingLyricClickLookup => prefsRepo.floatingLyricClickLookup;
  Future<void> setFloatingLyricClickLookup(bool value) =>
      prefsRepo.setFloatingLyricClickLookup(value);

  // TODO-370: 悬浮字幕透明度（按钮底色 / 文字），0..100 百分比，100=保持现观感。
  int get floatingLyricButtonBgOpacity =>
      prefsRepo.floatingLyricButtonBgOpacity;
  Future<void> setFloatingLyricButtonBgOpacity(int value) =>
      prefsRepo.setFloatingLyricButtonBgOpacity(value);

  int get floatingLyricTextOpacity => prefsRepo.floatingLyricTextOpacity;
  Future<void> setFloatingLyricTextOpacity(int value) =>
      prefsRepo.setFloatingLyricTextOpacity(value);

  // TODO-576: 悬浮字幕/歌词条背景透明度（0..100 百分比），默认 70=更不挡视野。
  int get floatingLyricBgOpacity => prefsRepo.floatingLyricBgOpacity;
  Future<void> setFloatingLyricBgOpacity(int value) =>
      prefsRepo.setFloatingLyricBgOpacity(value);

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
        final BaseAnkiRepository repo = platformServices.createAnkiRepository();
        final Map<String, String> fields = <String, String>{
          'expression': word,
          'reading': reading,
          'glossary': DictionaryEntry.meaningToPlainText(meaning),
        };
        try {
          final MineOutcome outcome = await repo.mineEntry(
            rawPayloadJson: jsonEncode(fields),
            context: const AnkiMiningContext(sentence: ''),
          );
          // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
          final String deckName = outcome.result == MineResult.success
              ? (await repo.loadSettings()).selectedDeckName ?? ''
              : '';
          HibikiToast.show(
            msg: describeMineOutcome(outcome, deckName: deckName).message,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('FloatingDict.ankiExport', e, stack);
          HibikiToast.show(msg: t.card_export_failed);
        }
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
}

class _AppModelRemoteLookupService
    implements
        HibikiRemoteLookupService,
        HibikiRemoteMiningService,
        HibikiRemoteHistoryService {
  const _AppModelRemoteLookupService(this._appModel);

  final AppModel _appModel;

  @override
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    final BaseAnkiRepository repo =
        _appModel.platformServices.createAnkiRepository();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: AnkiMiningContext(sentence: sentence),
    );
    return outcome.result.name;
  }

  @override
  void recordHistory(DictionarySearchResult result) {
    _appModel.mediaHistoryRepo.addToSearchHistory(
      historyKey: DictionaryMediaType.instance.uniqueKey,
      searchTerm: result.searchTerm,
    );
    _appModel.dictRepo.addHistoryResult(
      result,
      _appModel.maximumDictionaryHistoryItems,
    );
  }

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final DictionarySearchResult result = await _appModel.searchDictionary(
      searchTerm: term,
      searchWithWildcards: wildcards,
      overrideMaximumTerms: maximumTerms,
      useCache: false,
      allowRemoteLookup: false,
    );
    return result.entries.isEmpty ? null : result;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async {
    final Map<String, dynamic>? info =
        await TtsChannel.instance.queryLocalAudio(
      expression,
      reading,
    );
    if (info == null) return null;
    final String? file = info['file'] as String?;
    final String? source = info['source'] as String?;
    if (file == null || source == null) return null;
    final int dbIndex = (info['dbIndex'] as int?) ?? 0;
    final String? resolved = await TtsChannel.instance.extractLocalAudio(
      file,
      source,
      dbIndex: dbIndex,
    );
    if (resolved == null || resolved.isEmpty) return null;
    final Uri? uri = Uri.tryParse(resolved);
    final String filePath =
        uri != null && uri.scheme == 'file' ? uri.toFilePath() : resolved;
    final File audioFile = File(filePath);
    if (!audioFile.existsSync()) return null;
    return RemoteAudioLookup(
      bytes: await audioFile.readAsBytes(),
      contentType: _remoteAudioContentType(filePath),
    );
  }

  String _remoteAudioContentType(String filePath) {
    switch (path.extension(filePath).toLowerCase()) {
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.m4b':
        return 'audio/mp4';
      case '.ogg':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      default:
        return 'application/octet-stream';
    }
  }
}
