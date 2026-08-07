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
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:remove_emoji/remove_emoji.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:fushi/creator.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';
import 'package:fushi/src/media/drag_drop/desktop_drop_reinitializer.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/media/floating_dict_channel.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/models/app_ui_font_chain.dart';
import 'package:fushi/src/models/builtin_tags.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/clipboard_history_repository.dart';
import 'package:fushi/src/models/media_history_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/media/torrent/download_save_root.dart';
import 'package:fushi/src/media/torrent/embedded_torrent_host.dart';
import 'package:fushi/src/media/torrent/qb_torrent_backend.dart';
import 'package:fushi/src/media/torrent/qbittorrent_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/anime_download_importer.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/media/torrent/anime_download_subtitle_resolver.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/torrent/torrent_memory.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/media/tracking/media_tracking_repository.dart';
import 'package:fushi/src/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/deletion_prompt.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/hibiki_server_controller.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart' as theme_notifier;
import 'package:fushi/src/models/theme_notifier.dart'
    show ThemeNotifier, CustomThemeEntry;
// TODO-930: re-export the multi-theme value type so `hibiki/models.dart`
// consumers (theme swatch row, CustomThemePage) can name it.
export 'package:fushi/src/models/theme_notifier.dart' show CustomThemeEntry;
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_routing.dart';
import 'package:fushi/src/migration/migration_readonly.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/file_export_manager.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/models/local_audio_source_pref.dart';
import 'package:fushi/src/models/anki_integration.dart';
import 'package:fushi/src/sync/hibiki_remote_lookup_client.dart';
import 'package:fushi/src/sync/hibiki_remote_mining_client.dart';
import 'package:fushi/src/sync/hibiki_remote_lookup_service.dart';
import 'package:fushi/src/sync/remote_audio_lookup_bytes.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/media/video/video_cover_extractor.dart'
    show extractVideoCover;
import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi/src/mining/youtube_clip_miner.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client_manager.dart';
import 'package:fushi/src/sync/yomitan_api_server_manager.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/platform/platform_providers.dart';

export 'package:fushi/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry, InvalidLocalAudioDbException;
export 'package:fushi/src/models/local_audio_source_pref.dart'
    show LocalAudioSourcePref;
export 'package:fushi/src/models/audio_source_config.dart'
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
final quickActionColorProvider = FutureProvider.autoDispose
    .family<Map<String, Color?>, DictionaryEntry>((ref, entry) async {
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
final visibleOnceProvider = StateProvider.autoDispose
    .family<bool, DictionaryEntry>((ref, entry) => false);

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

/// 词典查询前的查询串清洗单一真相：换行折空格 → emoji 去除 → 首尾标点/符号剥离 →
/// 孤立代理项替换。此前 4 步 replaceAll 散在 [AppModel.searchDictionary] 内，无法单测
/// （依赖整页 AppModel + FFI）。纯逻辑（输入→输出确定）凿到这里，返回清洗后的查询串。
///
/// 替换契约逐字不变（变=查询语义/缓存键漂移）：`\n`→`' '`、[emojiRegex]→`' '`、
/// [punctuationRegex]→`''`、[loneSurrogateRegex]→`' '`，顺序固定。
@visibleForTesting
String normalizeSearchTerm(
  String searchTerm, {
  required RegExp emojiRegex,
  required RegExp punctuationRegex,
  required RegExp loneSurrogateRegex,
}) {
  // BUG-442：词典查询前先按同一码点上限截断（用 characters 不切碎代理对 / 字素簇）。
  // 防止超长串（如误把整章文本送进查词）让后续逐次 replaceAll 线性清洗卡顿，也与
  // 渲染层 / 排队层共用同一上限，单一真相。
  if (searchTerm.characters.length > kMaxLookupInputChars) {
    searchTerm = searchTerm.characters.take(kMaxLookupInputChars).toString();
  }
  searchTerm = searchTerm.replaceAll('\n', ' ');
  searchTerm = searchTerm.replaceAll(emojiRegex, ' ');
  searchTerm = searchTerm.replaceAll(punctuationRegex, '');
  searchTerm = searchTerm.replaceAll(loneSurrogateRegex, ' ');
  return searchTerm;
}

/// [normalizeSearchTerm] 在查词前用 [punctuationRegex]（`^[\p{P}\p{S}]+|[\p{P}\p{S}]+$`）
/// 剥掉查询串的**句首/句尾**标点/符号（『「"( 等），引擎才从剥离串的 0 位去屈折/前缀
/// 匹配，`bestLength` 也以剥离串为坐标系。返回原始串**句首**被剥掉的 UTF-16 code unit
/// 数（无句首标点=0）。剪贴板面板的句子横幅显示的是**原始**句子（含句首标点），整词
/// 高亮起点必须右移这段长度，否则高亮左移吞进句首括号、右缺词尾（BUG-773）。
///
/// 与 [normalizeSearchTerm] 共用同一 [punctuationRegex]（单一真相）：只取句首分支
/// （`match.start == 0` 的命中）；只有句尾标点时命中不在句首，返回 0。
@visibleForTesting
int leadingPunctuationStripUnits(String raw, RegExp punctuationRegex) {
  if (raw.isEmpty) return 0;
  final Match? m = punctuationRegex.firstMatch(raw);
  return (m != null && m.start == 0) ? m.end : 0;
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

/// 引擎原始结果（`HoshiDicts.lookup`）缓存键的单一真相。格式：
/// `<term.length>:<term>/<maxResults>`。
///
/// 🔴 **键必须带 [maxResults]**：引擎按该上限 `partial_sort` + `resize` 截断，
/// 不同上限拿到的是**不同长度**的结果集。此前 `maxResults` 是硬编码常量，键里
/// 省掉它是安全的；现在它等于调用方的词头预算（load-more 会以「已显示条数 +
/// maximumTerms」为新上限重查同一个词），若键里不含上限，load-more 就会命中上
/// 一轮的短结果集、拿不到新条目，`allLoaded` 随即为 true —— load-more 永久失灵。
@visibleForTesting
String buildFfiLookupCacheKey({
  required String term,
  required int maxResults,
}) {
  return '${term.length}:$term/$maxResults';
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

/// TODO-1151：本地备份导入/恢复的全屏遮罩阶段。[validating] 选完文件后正在读取/校验
/// 备份并生成合并预览（DB 仍打开、可取消）——旧实现这段只有设置行 24px 小圈，大 zip
/// 校验/预览要数十秒无明显反馈；[running] 正在解压落盘（DB 已关、阻塞、请勿关闭）；
/// [done] 已结束（成功或失败），显示确认视图等用户点「立即重启」。
enum BackupImportPhase { validating, running, done, failed }

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
    // 初始化 late [_thumbnailsDirectory]：书架 / 视频卡渲染经 MediaSource
    // getOverrideThumbnailFilename 读它，未初始化会抛 LateInitializationError。测试里
    // 复用 databaseDirectory（存在且可写）即可，不读它的既有调用点不受影响。
    _thumbnailsDirectory = databaseDirectory;
    _localAudioManager = LocalAudioManager(
      prefsRepo: prefsRepo,
      databaseDirectory: databaseDirectory,
    );
  }

  /// Test seam: inject an already-open database so widget tests can exercise
  /// schema builders (e.g. the sync/backup destination) that read [database]
  /// without running the full [initialise] path.
  @visibleForTesting
  void wireDatabaseForTesting(FushiDatabase db) {
    _database = db;
    _databaseOpened = true;
  }

  /// 全应用共享的冲突弹窗调度器：三处同步入口（手动 / 关书后 / app 启动）
  /// 共用同一份会话级 snooze + 单飞状态，避免冲突弹窗互相重入或反复打扰。
  final SyncConflictPrompter syncConflictPrompter = SyncConflictPrompter();

  /// 删除传播的「其他设备已删除，本地也删？」确认弹窗调度器（同冲突弹窗纪律：会话级
  /// snooze + 单飞）。同步消费到远端删除标记后经 [presentDeletionCandidates] 弹出。
  final DeletionPromptPrompter syncDeletionPrompter = DeletionPromptPrompter();

  /// App 级 Hibiki LAN 同步服务端宿主：生命周期归 AppModel（整个会话），
  /// 不再绑在设置页 widget 上——否则切出「同步与备份」页就把服务端关了（BUG-085）。
  /// 启动时若用户启用了 host 则自动开，仅在用户关闭开关或退出 app 时停。配对批准
  /// 弹窗经全局 [navigatorKey]，故在任意界面都能弹。
  late final FushiSyncServerController syncServerController =
      FushiSyncServerController(
    navigatorKey: navigatorKey,
    database: () => database,
    syncDataDir: () => databaseDirectory.path,
    remoteLookupServiceFactory: createRemoteLookupService,
    miningServiceFactory: createRemoteMiningService,
    historyServiceFactory: createRemoteHistoryService,
    // TODO-1356: advertise this device's real per-platform name (hardware model
    // on mobile, hostname on desktop) so peers never see "localhost".
    deviceInfo: platformServices.deviceInfo,
    // 漫画 P3：互联 host 代跑 OCR（/api/ocr/* + capabilities.mangaOcr）。工厂来自
    // manga_ocr_provider（唯一引用 MangaOcrServiceImpl 的文件）；不支持内置 OCR 的
    // 平台（移动端）也接线——capability 会如实报 supported=false，client 据此隐藏。
    mangaOcrServiceFactory: createMangaOcrService,
    libraryServiceFactory: () => AppModelLibraryHostService(
      db: database,
      dictionaryResourceRoot: dictionaryResourceDirectory,
      packages: SyncAssetPackageService(db: database),
      refreshDictionaryCache: () async {
        await _rebuildDictPathsCacheAsync();
        dictRepo.clearDictionaryResultsCache();
      },
      runExclusive: runExclusiveWithSync,
      // BUG-714: 必须接线 importBookFromFile，否则 host 收到对端 client 的
      // PUT /api/library/books/<title> 时 importBook 抛 UnsupportedError，被
      // 服务端 catch 成 HTTP 500，互联/live 书籍推送（client→host）整体失效。
      // 生产实现即文档约定的 EpubImporter.importFromPath（tmp 文件名 = <title>.epub，
      // fileName 用作 epubPath 与标题回退）。
      importBookFromFile: (File epubFile) => EpubImporter.importFromPath(
        db: database,
        filePath: epubFile.path,
        fileName: path.basename(epubFile.path),
      ),
      localAudioEntries: localAudioDbs,
      localAudioStagingDir: temporaryDirectory,
      onLocalAudioImported: importSyncedLocalAudioDb,
      audioDatabaseRoot: Directory('${appDirectory.path}/audiobooks'),
      videoSubtitleLangCode: JapaneseLanguage.instance.languageCode,
      // client→host 视频上传（syncVideoFiles 开关驱动）：落 <documents>/remote_videos
      // （与 client 下载远端视频落点一致，AppPaths.remoteVideosDirectory 同目录）。
      uploadedVideoRoot: Directory('${appDirectory.path}/remote_videos'),
      // 上传视频封面 best-effort 抽帧（桌面 ffmpeg；移动端无则留空占位）。
      extractVideoCover: (
              {required String videoPath, required String bookUid}) =>
          extractVideoCover(videoPath: videoPath, bookUid: bookUid),
      // host 收到 DELETE /api/library/videos/<id> 时的磁盘回收（VideoDeletionHost）：
      // 复用本机长按删除的同一函数，按「仍在 app 资产目录内 + 无其它条目引用」回收
      // 封面 / 字幕缓存。**不碰用户自己导入的原始视频文件**——远端删除与本地删除
      // 在「删掉哪些字节」上必须完全同语义，否则同一动作在两端后果不同。
      cleanupVideoOnDisk: (VideoBookRow row) =>
          VideoBookRepository(database).reclaimDeletedVideoBookAssets(
        deletedBookUid: row.bookUid,
        deletedCoverPath: row.coverPath,
        deletedSubtitlePath: row.subtitleSource,
        deletedVideoPath: row.videoPath,
      ),
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

  /// 同步报告产出后的统一 UI 回调（onReport）：并列触发**冲突弹窗**与**删除传播确认
  /// 弹窗**。两者独立（无冲突时仍可能有删除候选，反之亦然），故不能嵌套在
  /// [presentAutoConflicts] 的 early-return 之内。签名与 [SyncReportCallback] 一致。
  void presentSyncPrompts(SyncRunReport report, SyncBackend backend) {
    presentAutoConflicts(report, backend);
    presentDeletionCandidates(report, backend);
  }

  /// 同步消费到「远端已删 ∧ 本地在库」候选后，弹逐条确认框让用户选是否本地也删。
  /// fire-and-forget（present 是 barrier 对话框，不阻塞）；解析 itemKey→展示标题后交
  /// [DeletionPromptPrompter]。删除应用与基线推进在 prompter 内完成。
  void presentDeletionCandidates(SyncRunReport report, SyncBackend backend) {
    if (report.deletionCandidates.isEmpty) return;
    _presentDeletionCandidatesAsync(report)
        .catchError((Object e, StackTrace s) {
      debugPrint('[sync] deletion prompt failed: $e');
    });
  }

  Future<void> _presentDeletionCandidatesAsync(SyncRunReport report) async {
    final List<DeletionCandidateView> views = await _resolveDeletionViews(
      report.deletionCandidates,
    );
    if (views.isEmpty) return;
    await syncDeletionPrompter.present(
      navigatorKey: navigatorKey,
      db: database,
      views: views,
      highWaterMs: report.deletionTombstonesHighWaterMs,
      applyDeletions: _applyConfirmedDeletions,
      source: ConflictSource.auto,
      inBook: isMediaOpen,
    );
  }

  /// itemKey（bookKey/bookUid/displayName，用户看不懂）→ 展示标题（书名/视频名）。
  /// 查不到标题时退回 itemKey（绝不因缺标题吞掉候选）。
  Future<List<DeletionCandidateView>> _resolveDeletionViews(
    List<DeletionPropagationCandidate> candidates,
  ) async {
    final Map<String, String> bookTitles = <String, String>{
      for (final EpubBookRow r in await database.getAllEpubBooks())
        r.bookKey: r.title,
    };
    final Map<String, String> videoTitles = <String, String>{
      for (final VideoBookRow r in await database.allVideoBooks())
        r.bookUid: r.title,
    };
    // 纯字幕书（standalone SRT）：itemKey 是 uid，展示其 title（TODO-2470 死角①）。
    final Map<String, String> srtTitles = <String, String>{
      for (final SrtBookRow r in await database.getAllSrtBooks())
        r.uid: r.title,
    };
    // 收藏句：itemKey 是内容键（用户看不懂），从本地在库收藏句解析回句子文本展示。
    // deleteLocal 候选必是本地仍在库者，映射通常命中；查不到退回 itemKey。
    final Map<String, String> favSentenceTexts = <String, String>{
      for (final FavoriteSentence s
          in await FavoriteSentenceRepository(database).getAll())
        FavoriteSentenceRepository.itemKeyOf(s): s.text,
    };
    return <DeletionCandidateView>[
      for (final DeletionPropagationCandidate c in candidates)
        DeletionCandidateView(
          candidate: c,
          // 命名统一 Phase 3.4：墓碑 mediaType 经 [SyncTombstoneKind.tryParse]
          // 显式解析（未知种类 → null → 原样展示 itemKey，透传语义不变）。
          title: switch (SyncTombstoneKind.tryParse(c.mediaType)) {
            // 有声书与其 epub 共享 bookKey，借书名；查不到退回 itemKey。
            SyncTombstoneKind.book ||
            SyncTombstoneKind.audiobook =>
              bookTitles[c.itemKey] ?? c.itemKey,
            SyncTombstoneKind.video => videoTitles[c.itemKey] ?? c.itemKey,
            SyncTombstoneKind.srtbook => srtTitles[c.itemKey] ?? c.itemKey,
            // 收藏词：itemKey 是 NUL 连接键，展示其中的 expression（词本身）。
            SyncTombstoneKind.favoriteword =>
              parseFavoriteWordItemKey(c.itemKey)?.expression ?? c.itemKey,
            SyncTombstoneKind.favoritesentence =>
              favSentenceTexts[c.itemKey] ?? c.itemKey,
            // localaudio: displayName 本身即可读；null = 未知种类原样展示。
            SyncTombstoneKind.localaudio || null => c.itemKey,
          },
        ),
    ];
  }

  /// 应用用户确认的删除：逐条按 mediaType 删本地（[DeleteScope.keepLocalOnly] /
  /// propagateDeletion:false——绝不回写墓碑造成传播循环）。删完刷新书架/视频列表。
  Future<void> _applyConfirmedDeletions(
    List<DeletionPropagationCandidate> confirmed,
  ) async {
    for (final DeletionPropagationCandidate c in confirmed) {
      try {
        // 命名统一 Phase 3.4：墓碑 mediaType 经 [SyncTombstoneKind.tryParse]
        // 显式解析后穷尽 switch（加种类时编译器强制补分支）；未知种类 → null
        // 分支，跳过但留痕（语义与旧 default 一致）。
        switch (SyncTombstoneKind.tryParse(c.mediaType)) {
          case SyncTombstoneKind.book:
            await ReaderHibikiSource.instance.deleteBook(
              db: database,
              bookKey: c.itemKey,
              appModel: this,
              scope: DeleteScope.keepLocalOnly,
            );
          case SyncTombstoneKind.video:
            await VideoBookRepository(database).deleteVideoBook(
              c.itemKey,
              scope: DeleteScope.keepLocalOnly,
            );
          case SyncTombstoneKind.audiobook:
            await AudiobookRepository(database)
                .deleteAudiobook(c.itemKey, propagateDeletion: false);
          case SyncTombstoneKind.srtbook:
            // 纯字幕书：itemKey = srt_books.uid。propagateDeletion 默认 false——
            // 消费远端删除标记时绝不回写墓碑，否则形成传播循环。
            await SrtBookRepository(database).delete(c.itemKey);
          case SyncTombstoneKind.localaudio:
            // 按 displayName 找到本地音频源并移除（不回写墓碑：keepLocalOnly 语义）。
            final int idx = _localAudioManager.entries.indexWhere(
                (LocalAudioDbEntry e) => e.displayName == c.itemKey);
            if (idx >= 0) await _localAudioManager.remove(idx);
          case SyncTombstoneKind.favoriteword:
            // 解析 itemKey → 取消收藏。removeFavoriteWord 默认 propagateDeletion=true：
            // 本设备也需 favoriteword 墓碑抑制第三设备快照的并集复活（幂等，与源墓碑同键）。
            final parsed = parseFavoriteWordItemKey(c.itemKey);
            if (parsed != null) {
              await database.removeFavoriteWord(
                expression: parsed.expression,
                reading: parsed.reading,
                sourceType: parsed.sourceType,
              );
            }
          case SyncTombstoneKind.favoritesentence:
            // 按内容键取消收藏。默认写墓碑（本设备也需抑制第三设备并集复活，与源墓碑同键）。
            await FavoriteSentenceRepository(database)
                .removeByItemKey(c.itemKey);
          case null:
            // 未知类型：跳过，但留痕——用户确认了删除、这里静默吞掉会造成
            // 「以为删了实际没删」且无从排查（mediaType 审计 2026-07-25）。
            debugPrint(
                '[sync] skip deletion of unknown mediaType ${c.mediaType}/${c.itemKey}');
        }
      } catch (e) {
        debugPrint('[sync] apply deletion ${c.mediaType}/${c.itemKey}: $e');
      }
    }
    // 删完刷新受影响的本地库缓存/书架（书 + 视频 + 有声书都可能变）。
    ReaderMediaType.instance.refreshTab();
    notifyListeners();
  }

  /// Refresh app-owned caches and visible home tabs after a sync run imports
  /// content into this device. Without this, pulled books/dictionaries/audio can
  /// be in Drift/on disk but stay invisible until a later rebuild or restart.
  Future<void> refreshAfterSyncRun(SyncRunReport report) async {
    if (!report.needsLocalLibraryRefresh) return;

    if (report.serviceConfigsImported > 0) {
      await refreshPrefCache();
    }

    if (report.dictionariesImported > 0) {
      dictRepo.clearDictionariesCache();
      await _rebuildDictPathsCacheAsync();
      dictRepo.clearDictionaryResultsCache();
      dictionaryMenuNotifier.notifyListeners();
      dictionarySearchAgainNotifier.notifyListeners();
    }

    if (report.booksImported > 0 ||
        report.audiobooksImported > 0 ||
        report.localBookProgressPulled > 0 ||
        report.collectionsUpdated > 0) {
      // 合集专属同步（仅 collectionsUpdated>0、无书内容导入）也必须刷新书架 tab：
      // 否则后台把合集成员落库后，书架非响应式的 _shelfMapsFuture 永不重载，合集
      // 不成组（书架合集不渲染，直到重启 app）。refreshTab 触发本 tab 的
      // tabRefreshNotifier，ReaderHibikiHistoryPage 监听后重载合集折叠映射。
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
  late FushiDatabase _database;

  /// True once [_database] has been opened in an init path. Used by
  /// [retryInitialise] to close a stale connection before re-running init
  /// (the late fields are reassigned, so the old DB would otherwise leak).
  bool _databaseOpened = false;

  /// Whether [database] is safe to read. False before any init path has opened
  /// the DB (and while a test seam deliberately leaves [_database] unset), so
  /// callers outside the init flow must gate [database] access on this instead
  /// of risking a LateInitializationError.
  bool get isDatabaseReady => _databaseOpened;

  /// Theme management, extracted from AppModel for testability.
  late ThemeNotifier themeNotifier;
  bool _themeListenerAdded = false;

  /// Preference management, extracted from AppModel for testability.
  PreferencesRepository? _prefsRepo;
  PreferencesRepository get prefsRepo => _prefsRepo!;
  bool get isPreferencesReady => _prefsRepo != null;

  /// TODO-855: last prefs-version this process has reconciled its cache against.
  /// Used by [refreshPrefCacheIfChanged] so the warm-reuse :popup process only
  /// reloads its pref cache when the main app actually mutated a preference or
  /// switched profile, instead of unconditionally re-scanning the whole
  /// preferences table on every external lookup. -1 = not yet primed.
  int _lastSeenPrefsVersion = -1;

  /// Media history and search history, extracted for testability.
  late MediaHistoryRepository mediaHistoryRepo;

  /// 番剧/小说/漫画进度的可靠 Bangumi 同步入口。
  MediaTrackingService? _mediaTrackingService;
  MediaTrackingService get mediaTrackingService =>
      _mediaTrackingService ??= MediaTrackingService(
        repository: MediaTrackingRepository(_database),
        preferences: prefsRepo,
        userAgent: _mediaTrackingUserAgent,
      );

  String _mediaTrackingAppVersion = 'unknown';
  String get _mediaTrackingUserAgent =>
      'hajisensai/Fushi/$_mediaTrackingAppVersion '
      '(https://github.com/hajisensai/hibiki)';

  /// Dictionary metadata, history, and search caches.
  late DictionaryRepository dictRepo;
  late ClipboardHistoryRepository clipboardHistoryRepo;
  final ClipboardHistoryNotifier clipboardHistoryNotifier =
      ClipboardHistoryNotifier();

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
    floatingLyricContextLines: () => floatingLyricContextLines,
    floatingLyricClickLookup: () => floatingLyricClickLookup,
    onFloatingLyricLookup: (String text, int index) {
      // app 级（无 reader attach）桌面悬浮窗点词：Windows 优先弹 867 app 外全局
      // 查词覆盖窗（TODO-872，主窗最小化/被遮挡也看得见）；覆盖窗不可用才回落
      // 常驻主窗口的 in-app 查词宿主 [FloatingLyricLookupHost]（main.dart 根
      // builder 挂载），不依赖进任何书（TODO-354 ①）。reader attach 时会换成
      // reader 的点词处理器。
      unawaited(() async {
        if (await tryFloatingLyricGlobalLookup(
          appModel: this,
          text: text,
          index: index,
        )) {
          return;
        }
        FloatingLyricLookupNotifier.instance.requestLookup(text, index);
      }());
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
  final FushiShortcutRegistry shortcutRegistry = FushiShortcutRegistry();

  /// TODO-1375：媒体（阅读器 / 视频）是否打开的**可靠**通知源，专供 macOS 原生壳的
  /// 根 sidebar 显隐门控（main.dart 的 MacosWindow）。根因：sidebar 过去直接读
  /// `isMediaOpen`（= `_currentMediaSource != null`）在 MaterialApp.builder 里求值，
  /// 靠 `ref.watch(appProvider)` 重建——但 [openMedia] / [closeMedia] 只改
  /// `_currentMediaSource` 却**从不** notifyListeners，于是退出阅读器后 builder 不重跑、
  /// sidebar 卡在上一次求值的 `null`（永久消失 → 设置 tab 失去唯一切换出口 → 困死）。
  /// 用这个独立 ValueNotifier 在 open/close 里精确 set，配合 ValueListenableBuilder，
  /// 退出媒体必然重建并恢复 sidebar（单一真值源 + 保证通知），且不触发全局根重建。
  /// 非 macOS 平台不读它（阅读器是盖满的整页路由，与壳 sidebar 无关），纯 no-op。
  final ValueNotifier<bool> mediaOpenNotifier = ValueNotifier<bool>(false);

  /// Polls physical game controllers and dispatches them into the shortcut /
  /// focus pipeline on platforms where the Flutter engine does not deliver
  /// gameButton* key events (desktop). No-op on Android/iOS (native key events)
  /// and on desktops without an implemented input source.
  late final GamepadService gamepadService = GamepadService(
    navigatorKey: navigatorKey,
    registry: shortcutRegistry,
    // TODO-1113 P3: lets the pointer route keep the ring lit on a mouse DOWN that
    // carries focus to a target while focus navigation is enabled (hover/move
    // still hide it). Live-read so toggling the preference takes effect at once.
    focusNavigationEnabled: () => experimentalFocusNavigationEnabled,
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

  Future<void> refreshSystemPalette() {
    if (!_themeListenerAdded) {
      return Future<void>.value();
    }
    return themeNotifier.refreshSystemPalette();
  }

  /// Used to get the versioning metadata of the app. See [initialise].
  PackageInfo get packageInfo => _packageInfo;
  late PackageInfo _packageInfo;

  /// Whether [initialise] has completed successfully.
  bool get isInitialised => _isInitialised;
  bool _isInitialised = false;

  /// 已迁移只读态（Fushi 迁移 P1-4，见 [kMigrationReadonlyPrefKey]）。
  /// 置位后本启动周期内：不自启互联/Yomitan 服务、不跑自动同步与后台写手。
  ///
  /// **包名门**：该偏好会随迁移 core 批原样合并进 Fushi 的库，只有真正运行为
  /// 老包（`app.hibiki.reader`）时才生效——否则 Fushi 导入完成后会误锁自己。
  /// 顺序有意：先查偏好（测试夹具里 [packageInfo] 是未初始化的 late 字段，
  /// 偏好为 false 时短路，不触发 LateInitializationError）。
  bool get isMigrationReadonly =>
      prefsRepo.getPref(kMigrationReadonlyPrefKey) == true &&
      packageInfo.packageName == kHibikiPackageName;

  /// BUG-815: the currently-running [_initialiseOnce] future, or null when no
  /// init is in flight. [initialise] uses it to serialise concurrent callers so
  /// a second init can never race the first over the shared [_database] /
  /// repositories / [_isInitialised]. Cleared when the in-flight run completes.
  Future<void>? _initInFlight;

  /// Non-null if [initialise] threw; UI should display this instead of spinning.
  String? get initError => _initError;
  String? _initError;

  /// Non-null when init was refused because the on-disk DB was created by a
  /// NEWER build of Hibiki than this one (downgrade protection). The UI shows a
  /// dedicated "update your app" notice with NO retry button — retry would fail
  /// identically and this is not a transient error. The DB file is left intact.
  FushiDatabaseDowngradeException? get downgradeError => _downgradeError;
  FushiDatabaseDowngradeException? _downgradeError;

  /// Non-null when init failed because the database could NOT be opened even
  /// after the full WAL/sidecar recovery ladder (TODO-905) — i.e. the main
  /// `hibiki.db` itself is corrupt, not just a stale `-wal`/`-shm`. The UI shows
  /// an actionable "restore a backup / clear data" notice; a plain Retry would
  /// loop forever (the very bug TODO-905 fixes), so recovery already ran inside
  /// the open path and a fresh open of the same corrupt file would fail again.
  FushiDatabaseUnrecoverableException? get unrecoverableDbError =>
      _unrecoverableDbError;
  FushiDatabaseUnrecoverableException? _unrecoverableDbError;

  /// BUG-815：非 null 表示桌面**配置了自定义数据根、但本次启动它不可达**（休眠 / 掉线 /
  /// 拔出的盘）。UI 据此显「数据位置未响应」逃生屏（重试 / 显式用默认位置启动），而**不**
  /// 静默把空默认库当真数据显示。真实数据仍原封不动躺在 [DataRootUnavailableException.
  /// configuredPath]。DB 尚未打开（init 在 resolve-data-roots 步就抛出），故重试是干净重跑。
  DataRootUnavailableException? get dataRootUnavailable => _dataRootUnavailable;
  DataRootUnavailableException? _dataRootUnavailable;

  /// Clears the error state and re-runs [initialise].
  Future<void> retryInitialise() async {
    // BUG-815: if an init started by main() is still IN FLIGHT — a slow cold
    // start that merely tripped the 20s loading watchdog, NOT a hang — do NOT
    // tear down / re-open the DB below. Closing [_database] out from under the
    // running init and spawning a SECOND concurrent init races them over the
    // shared _database / repositories / _isInitialised and surfaces as "all data
    // empty" on the home screen (mobile has no custom data root, so restarting —
    // a single clean init — restores everything). Await the in-flight attempt
    // instead: it completes (data appears) or sets _initError (whose own Retry
    // then runs cleanly, because [initialise]'s whenComplete has cleared
    // _initInFlight by that point).
    final Future<void>? inFlight = _initInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
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
      // 仓储绑的是刚被关掉的那个 db 实例，必须丢掉让它重建（否则重试后所有游戏库
      // 读写都打在已关闭的连接上）。
      _galgameRepo = null;
    }
    _initError = null;
    _downgradeError = null;
    _unrecoverableDbError = null;
    _dataRootUnavailable = null;
    _isInitialised = false;
    notifyListeners();
    await initialise();
  }

  /// BUG-815：用户在「数据位置未响应」逃生屏点「仍用默认位置启动」时调用。置全局
  /// [AppPaths.forceDefaultRootForSession] 让本次进程用 `path_provider` 默认根打开
  /// （配置根不动、原盘数据一字节不动），再走常规 [retryInitialise]。仅本次有效：下次
  /// 启动重新探测配置根，盘醒了自动用回真实数据。绝不自动调用——只由用户显式点击触发。
  Future<void> retryInitialiseWithDefaultRoot() async {
    AppPaths.forceDefaultRootForSession = true;
    await retryInitialise();
  }

  /// Used for caching images and audio produced from media seeds.
  DefaultCacheManager get cacheManager =>
      _cacheManager ??= DefaultCacheManager();
  DefaultCacheManager? _cacheManager;

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

  /// 剪贴板面板句子横幅整词高亮定位（BUG-773）：查词前 [normalizeSearchTerm] 用
  /// [_punctuationRegex] 剥掉 [rawQuery] 的句首标点/符号，引擎才从剥离串 0 位匹配、
  /// `bestLength` 以剥离串为坐标系。横幅显示原始句（含句首标点），故高亮起点须右移
  /// 这段被剥长度。委托 [leadingPunctuationStripUnits]（同一正则=单一真相），返回
  /// 句首被剥掉的 UTF-16 code unit 数。
  int lookupLeadingStripUnits(String rawQuery) =>
      leadingPunctuationStripUnits(rawQuery, _punctuationRegex);

  /// Used to notify toggling incognito. Updates the app logo to and from
  /// grayscale.
  final ChangeNotifier incognitoNotifier = ChangeNotifier();

  /// Notifies app to stop showing any screens.
  final ChangeNotifier databaseCloseNotifier = ChangeNotifier();

  /// TODO-959：桌面「数据存储位置」整目录迁移期间为 true。迁移会 [closeDatabase]
  /// （置 `_isInitialised=false`）以释放 Windows 文件锁，否则根 widget 会回退到裸
  /// loading 分支（近黑底 + 转圈，搬大库数秒~数分钟被误判死机）。该标志让根 widget 在
  /// loading 分支**之前**改显一个带「正在迁移数据，请勿关闭」文案 + 进度条的迁移遮罩。
  bool _dataRootMigrationActive = false;
  bool get dataRootMigrationActive => _dataRootMigrationActive;

  /// 迁移进度（跨盘复制时 (已复制文件数, 总文件数)）。同盘 rename 瞬时完成不产生进度，
  /// 此时保持 null → UI 显示不确定进度条。
  ({int copied, int total})? _dataRootMigrationProgress;
  ({int copied, int total})? get dataRootMigrationProgress =>
      _dataRootMigrationProgress;

  /// TODO-1182：迁移失败原因文案。非 null 时根 widget 在迁移遮罩上改显「失败」态
  /// （原因 + 建议 + 重启按钮），而不是像旧实现那样立刻重启导致用户永远看不到失败。
  /// closeResources 已在搬移前关闭 DB（`_isInitialised=false`），本进程无法原地恢复，
  /// 故失败态不撤遮罩（撤了会落到裸 loading）；由用户在失败视图点「重启」回到干净旧根。
  String? _dataRootMigrationFailure;
  String? get dataRootMigrationFailure => _dataRootMigrationFailure;

  /// 进入迁移态：先于 [closeDatabase] 调用，确保「遮罩已上屏 → 关库 → 搬文件」的顺序，
  /// 这样根 widget 在 DB 关闭引发的 rebuild 里看到的是迁移遮罩而非裸 loading。
  void beginDataRootMigration() {
    _dataRootMigrationActive = true;
    _dataRootMigrationProgress = null;
    _dataRootMigrationFailure = null;
    notifyListeners();
  }

  /// 更新迁移进度（跨盘复制每完成一个文件调一次）。无副作用，仅刷进度条。
  void updateDataRootMigrationProgress(int copied, int total) {
    _dataRootMigrationProgress = (copied: copied, total: total);
    notifyListeners();
  }

  /// TODO-1182：迁移失败 → 切到失败态。**保持**遮罩激活（DB 已关，撤遮罩会落到裸 loading），
  /// 让根 widget 在同一遮罩上渲染「失败原因 + 建议 + 重启按钮」，确保用户醒目看到失败。
  void failDataRootMigration(String message) {
    _dataRootMigrationActive = true;
    _dataRootMigrationProgress = null;
    _dataRootMigrationFailure = message;
    notifyListeners();
  }

  /// 退出迁移态。用户在失败视图点「重启」但重启不受支持时兜底回到（受限的）设置页。
  /// 成功路径会重启进程，不会执行到这里。
  void endDataRootMigration() {
    _dataRootMigrationActive = false;
    _dataRootMigrationProgress = null;
    _dataRootMigrationFailure = null;
    notifyListeners();
  }

  /// TODO-1151：本地备份「导入/恢复」期间的全屏遮罩状态。导入同样会
  /// [closeDatabase]（释放数据库句柄以便整体替换 DB + 内容树），流程结束后必须
  /// 重启进程重新载入数据。旧实现只在设置行显示一个 24px 小圈、成功后延迟 500ms
  /// 直接 `exit(0)`，用户看到 app「突然消失」误以为失败。这里镜像 TODO-959 数据根
  /// 迁移的做法：进入导入态时把根 widget 切到明确的「正在导入备份，请勿关闭」遮罩，
  /// 完成后切到「导入完成 → 立即重启」确认视图，由用户点按（或后续可加倒计时）再退出。
  BackupImportPhase? _backupImportPhase;
  BackupImportPhase? get backupImportPhase => _backupImportPhase;
  bool get backupImportActive => _backupImportPhase != null;

  /// 导入完成/失败后展示在确认视图里的文案（成功提示或失败原因）。
  String? _backupImportMessage;
  String? get backupImportMessage => _backupImportMessage;

  /// TODO-1183：备份导入的确定进度（0..1）。用 [ValueNotifier] 让**只有进度条**随每
  /// 4MB 落盘重建，而非每个 chunk 都 [notifyListeners] 触发整棵根 widget 重绘。
  final ValueNotifier<double> backupImportProgress = ValueNotifier<double>(0.0);

  /// 由 [BackupService.importBackupFiles] 的 onProgress 回调（在本 isolate 上被后台
  /// 解压 isolate 的 SendPort 消息驱动）。夹紧到 [0,1]。
  void reportBackupImportProgress(double fraction) {
    backupImportProgress.value = fraction.clamp(0.0, 1.0);
  }

  /// TODO-1151：备份「读取/校验」阶段的作废 token。选完文件后 validate + previewMerge
  /// 会跑数十秒（后台 isolate，UI 不冻结但只有 24px 小圈）。进入 [beginBackupValidating]
  /// 时自增；用户点「取消」或开启新一轮校验会再自增作废旧 token——in-flight 的后台 isolate
  /// 结果回来时用 [isBackupValidatingCurrent] 判断是否仍是最新，陈旧结果**直接丢弃**（不吞
  /// 异常、不硬编码分支，纯 token 判定）。
  int _backupValidatingToken = 0;

  /// 进入「读取/校验备份 + 生成合并预览」的全屏遮罩（DB 仍打开，可取消）。返回本轮
  /// 校验 token；调用方在每个 await 后用 [isBackupValidatingCurrent] 校验后再消费结果。
  int beginBackupValidating() {
    _backupImportPhase = BackupImportPhase.validating;
    _backupImportMessage = null;
    backupImportProgress.value = 0.0;
    final int token = ++_backupValidatingToken;
    notifyListeners();
    return token;
  }

  /// 该 [token] 是否仍是最新校验轮（未被取消、未被新一轮校验取代）。
  bool isBackupValidatingCurrent(int token) => _backupValidatingToken == token;

  /// 用户在 validating 遮罩点「取消」：作废 in-flight token（后台结果回来即丢弃）并退出
  /// 遮罩回到正常 app 树（设置页）。仅在仍处于 validating 相位时生效（避免误清掉已进入
  /// running 的导入态）。
  void cancelBackupValidating() {
    if (_backupImportPhase != BackupImportPhase.validating) return;
    _backupValidatingToken++;
    _backupImportPhase = null;
    notifyListeners();
  }

  /// 校验成功、预览就绪：退出 validating 遮罩，切回正常 app 树，好在其上（经全局
  /// [navigatorKey]）弹确认对话框。不作废 token（调用方已确认本轮仍是最新）。
  void endBackupValidating() {
    if (_backupImportPhase != BackupImportPhase.validating) return;
    _backupImportPhase = null;
    notifyListeners();
  }

  /// 进入导入态：先于 [closeDatabase] 调用，确保「遮罩已上屏 → 关库 → 解压落盘」的
  /// 顺序，根 widget 在关库引发的 rebuild 里看到的是导入遮罩而非裸 loading。
  void beginBackupImport() {
    _backupImportPhase = BackupImportPhase.running;
    _backupImportMessage = null;
    backupImportProgress.value = 0.0;
    notifyListeners();
  }

  /// 导入**成功**结束：切到确认视图（导入完成 → 立即重启），展示成功 [message]。
  /// DB 已关闭，必须重启才能重载数据。
  void completeBackupImport(String message) {
    _backupImportPhase = BackupImportPhase.done;
    _backupImportMessage = message;
    backupImportProgress.value = 1.0;
    notifyListeners();
  }

  /// 导入**失败**结束（如 OOM/损坏/异常）：切到确认视图并置 [BackupImportPhase.failed]，
  /// 让遮罩画红色错误图标 + 失败原因 [message]（根治「失败却显绿✓」，TODO-1183）。DB 已
  /// 关闭，仍必须重启回到可用状态，故失败也走同一「立即重启」出口。
  void failBackupImport(String message) {
    _backupImportPhase = BackupImportPhase.failed;
    _backupImportMessage = message;
    notifyListeners();
  }

  /// TODO-376：一次性「请打开首页『查词』tab」信号。值每请求一次自增（内容无关，
  /// 仅作 edge 触发）。桌面悬浮字幕条点词（reader 路由里 `_lookupFromFloatingLyric`）
  /// 这种**显式**查词手势，需要把主窗口从阅读器/任意 tab 切到查词 tab，让
  /// [HomeDictionaryPage] 挂载并消费 [DesktopLookupService.pendingText]。
  ///
  /// 这是与被动剪贴板监听**正交**的显式导航原语：HomePage 监听本信号只切 tab，不监听
  /// DesktopLookupService、也不在剪贴板被动命中时自动切 tab。
  ///
  /// spec 2026-07-10 §7 后的守卫新事实：DesktopLookupService 的 start/stop 已上移
  /// AppModel（[applyDesktopClipboardLifecycle]，app 级监听），消费按
  /// resolveDesktopLookupConsumer 分区——mainTab 分区仍只由 HomeDictionaryPage
  /// 消费（tab 未挂载时 pending 排队），HomePage 根节点依旧不消费查词请求。
  final ValueNotifier<int> homeDictionaryTabRequest = ValueNotifier<int>(0);

  /// 发一次「打开查词 tab」请求（桌面悬浮字幕点词等显式手势调）。
  void requestHomeDictionaryTab() {
    homeDictionaryTabRequest.value++;
  }

  /// TODO-935 E0：应用数据根的唯一入口快照（启动期 [AppPaths.resolve] 解析一次）。
  /// [temporaryDirectory] / [appDirectory] / [databaseDirectory] 都从它派生，
  /// 后续 E1/E2/E3 换根只动 [AppPaths]，不必再碰这三个 getter 各自的调用点。
  AppPaths get appPaths => _appPaths;
  late AppPaths _appPaths;

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

  /// Maximum number of headwords in a returned dictionary result for
  /// performance purposes.
  final int defaultMaximumDictionaryTermsInResult = 10;

  String get stashKey => mediaHistoryRepo.stashKey;

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
          final int mask = FushiDicts.probeDictContent(dir);
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
          debugPrint('[Fushi] reclassified kanji→term (mixed dict): ${d.name}');
        } catch (e, stack) {
          ErrorLogService.instance
              .log('AppModel.dictKanjiReclassify', e, stack);
          debugPrint('[Fushi] kanji reclassify error for ${d.name}: $e');
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
        debugPrint('[Fushi] migrated dict type: ${d.name} → ${detected.name}');
      } catch (e, stack) {
        ErrorLogService.instance.log('AppModel.dictTypeMigration', e, stack);
        debugPrint('[Fushi] dict type migration error for ${d.name}: $e');
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
        hidden: d.isHidden(JapaneseLanguage.instance),
        hasKanji: d.metadata['hasKanji'] == 'true',
      ));
    }
    final b = bucketDictPaths(entries);
    FushiDicts.initializeTyped(
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
          hidden: dictList[i].isHidden(JapaneseLanguage.instance),
          hasKanji: dictList[i].metadata['hasKanji'] == 'true',
        ),
    ];
    final b = bucketDictPaths(entries);
    FushiDicts.initializeTyped(
      termPaths: b.term,
      freqPaths: b.freq,
      pitchPaths: b.pitch,
      kanjiPaths: b.kanji,
    );
  }

  List<DictionarySearchResult> get dictionaryHistory =>
      dictRepo.dictionaryHistory;

  /// Desktop clipboard-copy history (data source for the panel / transient
  /// popup history button).
  List<ClipboardHistoryEntry> get clipboardHistory =>
      clipboardHistoryRepo.entries;

  /// Record one clipboard-copied text (from DesktopLookupService, origin=clipboard).
  void addClipboardHistoryEntry(String text) {
    clipboardHistoryRepo.add(text, DateTime.now());
    clipboardHistoryNotifier.bump();
  }

  /// Clear clipboard-copy history (the history panel clear button).
  Future<void> clearClipboardHistory() async {
    await clipboardHistoryRepo.clear();
    clipboardHistoryNotifier.bump();
  }

  // ── audio & media streams (delegated to AudioController) ────────────

  Stream<void> get currentMediaPauseStream => audioCtrl.currentMediaPauseStream;

  Stream<void> get playPauseHeadsetActionStream =>
      audioCtrl.playPauseHeadsetActionStream;

  /// Used to check whether or not the app is currently using a media source.
  bool get isMediaOpen => _currentMediaSource != null;

  /// Current active media source.
  MediaSource? get currentMediaSource => _currentMediaSource;
  MediaSource? _currentMediaSource;

  /// Current active media item.
  MediaItem? get currentMediaItem => _currentMediaItem;
  MediaItem? _currentMediaItem;

  /// The user's custom app-wide UI fonts, in the order they appear in the font
  /// library's `appUi` target — an ordered **fallback chain**, not a single
  /// face. Resolved and registered with the Flutter engine by [refreshAppFont];
  /// see [AppFontLoader.resolveAndLoadAll]. Empty means "no custom font", which
  /// hands the choice to the display language's system chain
  /// ([appUiFontChain]).
  List<String> _appFontFamilies = const <String>[];

  /// Primary app-chrome family = head of the resolved chain ([appFontChain]).
  /// Null keeps the platform default (non-CJK UI language with no custom font).
  String? get appFontFamily => appFontChain.isEmpty ? null : appFontChain.first;

  /// Everything after the primary family — feeds `TextStyle.fontFamilyFallback`.
  /// Null (not an empty list) when there is nothing to fall back to, so the
  /// style stays byte-identical to the pre-chain behaviour.
  List<String>? get appFontFallbacks {
    final List<String> chain = appFontChain;
    return chain.length > 1 ? chain.sublist(1) : null;
  }

  /// The full app-chrome font chain for the current display language, memoised
  /// on (locale, custom families) — [textStyle] is read on every theme rebuild,
  /// and rebuilding a dozen-entry chain each time is pure garbage.
  List<String> get appFontChain {
    final Locale uiLocale = appLocale;
    if (_cachedFontChainLocale == uiLocale &&
        identical(_cachedFontChainSource, _appFontFamilies)) {
      return _cachedFontChain;
    }
    _cachedFontChain = appUiFontChain(
      customFamilies: _appFontFamilies,
      locale: uiLocale,
      platform: defaultTargetPlatform,
    );
    _cachedFontChainLocale = uiLocale;
    _cachedFontChainSource = _appFontFamilies;
    return _cachedFontChain;
  }

  List<String> _cachedFontChain = const <String>[];
  Locale? _cachedFontChainLocale;
  List<String>? _cachedFontChainSource;

  /// The user's custom video-subtitle font family, or null to use the platform
  /// default (+ CJK fallback chain). Resolved/registered with the Flutter
  /// engine by [refreshAppFont] from the [FontTarget.videoSubtitle] target
  /// (TODO-864), independent of the app-wide UI font.
  String? _subtitleFontFamily;
  String? get subtitleFontFamily => _subtitleFontFamily;

  /// Loads **all** enabled entries of the `appUiFonts` target as the app-wide UI
  /// font chain (registering each file with the Flutter engine via
  /// [AppFontLoader]) and rebuilds the theme. Falls back to the display
  /// language's system fonts when none is usable. Safe to call repeatedly — a
  /// no-op when the resolved chain is unchanged.
  Future<void> refreshAppFont() async {
    final ReaderSettings settings = ReaderSettings(_database);
    await settings.refreshFromDb();
    // TODO-049: 软件系统字体走独立的 appUiFonts 目标，与小说正文(customFonts)、
    // 词典字体相互独立。整张列表都进链（不再只取第一条），用户排第 2、3 位的字体
    // 才真正参与缺字回退。
    final List<String> families =
        await AppFontLoader.resolveAndLoadAll(settings.appUiFonts);
    // TODO-864: 视频字幕字体走独立的 videoSubtitle 目标；复用同一次
    // refreshFromDb 一起解析。两个 target 都解析完再判是否 notify，否则
    // 只改字幕字体（appUi 未变）时 early-return 会吞掉刷新。
    // 字幕层自带 CJK 回退链（TODO-088）且与 mpv/libass 字号换算耦合（BUG-929），
    // 故仍取单个家族，不走链。
    final String? subtitleFamily =
        await AppFontLoader.resolveAndLoad(settings.videoSubtitleFonts);
    if (listEquals(families, _appFontFamilies) &&
        subtitleFamily == _subtitleFontFamily) {
      return;
    }
    _appFontFamilies = families;
    _subtitleFontFamily = subtitleFamily;
    notifyListeners();
  }

  /// Get the app-wide text style.
  ///
  /// The UI font follows the *display* language ([appLocale]), not the pinned
  /// Japanese reading language (直取 JapaneseLanguage.instance). With no user custom font,
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
      // 缺字回退链（[appUiFontChain]）：用户列表里剩下的字体 + 显示语言的系统
      // CJK 字体 + 其余 CJK 语言。没有它时，主字体缺字（典型如日文 face 上的
      // 简中「们/东」、中文 face 上的日文假名）会逐字掉进引擎默认 fallback，
      // 同一行里字形忽宽忽窄。
      fontFamilyFallback: appFontFallbacks,
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

  /// The app-wide [TextTheme]. [textStyle] carries the locale-aware font
  /// (fontFamily/fontFeatures/baseline); [FushiTypeScale] layers the editorial
  /// size/weight/line-height scale on top. Explicit sizes here survive the
  /// geometry merge `MaterialApp` performs, so this scale — not M3 defaults —
  /// is what renders.
  TextTheme get textTheme => FushiTypeScale.buildTextTheme(textStyle);

  ThemeMode get themeMode => themeNotifier.themeMode;
  ThemeData get theme => themeNotifier.theme;
  ThemeData get darkTheme => themeNotifier.darkTheme;

  ColorScheme buildColorScheme(Brightness brightness) =>
      themeNotifier.buildColorScheme(brightness);

  /// Get the sentence to be used by the [SentenceField] upon card creation.
  FushiTextSelection getCurrentSentence() {
    if (isMediaOpen) {
      return _currentMediaSource!.currentSentence;
    } else {
      MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
      if (mediaType is DictionaryMediaType) {
        return FushiTextSelection(
          text: '',
        );
      } else {
        return (_currentMediaSource ??
                (getCurrentSourceForMediaType(mediaType: mediaType)))
            .currentSentence;
      }
    }
  }

  FushiTextSelection getCurrentCueSentence() {
    if (isMediaOpen) {
      return _currentMediaSource!.currentCueSentence;
    } else {
      MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
      if (mediaType is DictionaryMediaType) {
        return FushiTextSelection(text: '');
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

  /// TODO-1077: reload the dictionary repository cache from the DB after an
  /// external, wholesale change to the `dictionary_metadata` table (a profile
  /// switch replaces the whole table). Rebuilds the in-memory cache, reloads the
  /// native FFI engine with the new dictionary set, and drops the stale search
  /// caches so the next lookup re-merges. Mirrors what `_onCacheRebuild` +
  /// `clearDictionaryResultsCache` do for the incremental per-mutation paths,
  /// but for the bulk "the whole table just changed underneath us" case.
  Future<void> reloadDictionariesFromDb() async {
    await dictRepo.loadFromDb();
    await _rebuildDictPathsCacheAsync();
    dictRepo.clearDictionaryResultsCache();
    dictionarySearchAgainNotifier.notifyListeners();
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
        // PDF 阅读器 Phase 1：注册第二个 reader 源。书架/页头恒用第一个（默认源），PDF 行
        // 仅在打开时经 mediaSourceIdentifier='reader_pdf' 路由到本源、进 ReaderPdfPage。
        // 通用 init 循环与 refreshPrefCache 按 mediaSources 遍历，自动接管本源初始化。
        ReaderPdfSource.instance,
        // 漫画 OCR P1：第三个 reader 源。format=='manga' 的行在打开时经
        // mediaSourceIdentifier='reader_manga' 路由到本源、进 MangaHibikiPage。
        MangaHibikiSource.instance,
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
      // TODO-1368/BUG-691: "Hibiki Symbols" = renamed 3-glyph subset of
      // DejaVu Sans 2.37, embedded as a data: URI @font-face in popup.css.
      'dejavu-fonts',
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

  /// TODO-1260：启动期对**数据根**做 IO 的关键 await 的超时上限。旧代码这些 await 若
  /// 因自定义数据根所在磁盘掉线而永不返回，会让 `initialise()` 无限挂起（首帧不出、
  /// 无限加载），而 `initialise()` 的顶层 try/catch 只接异常、接不住 hang。给这些 await
  /// 叠超时后，超时抛 [TimeoutException]→落顶层 catch→`_initError` 错误屏（有 Retry），
  /// 把「无逃生的无限 hang」变成「可重试的错误」。取 12s：远大于本机盘正常耗时（毫秒级），
  /// 只在盘真掉线 / 卡死时触发。
  static const Duration _initIoTimeout = Duration(seconds: 12);

  /// 给启动关键 IO 的 [Future] 叠一层超时：超时抛带**步骤名**的 [TimeoutException]，
  /// 让错误屏文案能指出卡在哪一步。
  Future<T> _guardInitIo<T>(String step, Future<T> future) => future.timeout(
        _initIoTimeout,
        onTimeout: () => throw TimeoutException(
          'AppModel.initialise 卡在「$step」超过 ${_initIoTimeout.inSeconds}s 未返回'
          '（多半是自定义数据根所在磁盘掉线 / 卡死）',
          _initIoTimeout,
        ),
      );

  /// Prepare application data and state to be ready of use upon starting up
  /// the application. [AppModel] is initialised in the main function before
  /// [runApp] is executed.
  Future<void> _prepareRuntimeDirectories() async {
    // TODO-935 E0：三个数据根经唯一入口 [AppPaths] 解析（内部已honor测试分支
    // [hibikiTestDirectory]，故行为与旧的 test/production 双分支逐字节等价）。
    _appPaths = await AppPaths.resolve();
    // TODO-1236：把上游 `hibiki_audio` 的有声书持久根解析接到 `AppPaths`（它无法 import
    // AppPaths）。这样桌面自定义数据根生效后，有声书新导入落数据根下的 `audiobooks/`
    // （与 TODO-1226 迁移白名单一致），而不是落回平台 Documents。
    AudiobookStorage.documentsRootResolver = AppPaths.documentsRootDirectory;
    _temporaryDirectory = _appPaths.tempRoot;
    _appDirectory = _appPaths.documentsRoot;
    _databaseDirectory = _appPaths.supportRoot;
  }

  /// Public entry point for app initialisation.
  ///
  /// BUG-815: serialises initialisation. If a run is already in flight (e.g. the
  /// loading-watchdog Retry firing while main()'s init is still going on a slow
  /// cold start), concurrent callers share that single run instead of starting a
  /// SECOND init that races the first over [_database] / repositories /
  /// [_isInitialised]. Once the run completes — success OR [_initError] (the body
  /// catches internally and never rethrows, so this future always resolves
  /// normally) — the guard clears, so a genuine retry-after-error still starts a
  /// fresh attempt.
  Future<void> initialise() {
    final Future<void>? existing = _initInFlight;
    if (existing != null) return existing;
    final Future<void> run = _initialiseOnce();
    _initInFlight = run;
    return run.whenComplete(() {
      if (identical(_initInFlight, run)) _initInFlight = null;
    });
  }

  /// One-shot initialisation body. Never call directly — always go through
  /// [initialise] so the in-flight guard holds.
  Future<void> _initialiseOnce() async {
    try {
      debugPrint('[Fushi] init: PackageInfo + DeviceInfo');

      /// Prepare entities that may be repeatedly used at runtime.
      _packageInfo = await PackageInfo.fromPlatform();
      _mediaTrackingAppVersion = _packageInfo.version;
      await platformServices.init();

      debugPrint('[Fushi] init: directories (early, needed for DB)');
      // TODO-1260：这一步内部解析数据根（含对自定义数据根盘的 stat）。盘掉线时最易 hang，
      // 故写启动面包屑 + 叠超时（超时→错误屏 Retry，不再无限加载）。
      ErrorLogService.instance
          .markInitStep('resolve-data-roots（AppPaths.resolve / 数据根 stat）');
      await _guardInitIo('resolve-data-roots', _prepareRuntimeDirectories());

      debugPrint('[Fushi] init: Drift database');
      ErrorLogService.instance
          .markInitStep('open-database（Drift 打开 hibiki.db）');
      _database = FushiDatabase(_databaseDirectory.path);
      _databaseOpened = true;

      // Sync-pref maintenance, before any repository loads them or sync runs:
      // 1) recover device-local sync config if a previous backup import crashed
      //    after overwriting the DB but before re-applying the preserved keys;
      // 2) fold the deprecated "SMB"(WebDAV-gateway) config into WebDAV;
      // 3) migrate the mutually-exclusive `backendType==hibikiServer` interconnect
      //    selection to the independent interconnect toggle (interconnect and a
      //    cloud backup backend can now coexist).
      await BackupService.recoverPendingImport(_databaseDirectory.path);
      await SyncRepository(_database).migrateSmbToWebDav();
      await SyncRepository(_database).migrateInterconnectBackendToToggle();

      /// Prepare all repositories (objects created first, then loaded in
      /// parallel to avoid serial await chains).
      _prefsRepo = PreferencesRepository(_database);
      final BaseAnkiRepository ankiRepo =
          platformServices.createAnkiRepository();
      final profileRepo = ProfileRepository(_database, ankiRepo);
      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache,
          isLowMemory: () => prefsRepo.lowMemoryMode);
      mediaHistoryRepo = MediaHistoryRepository(_database);
      clipboardHistoryRepo = ClipboardHistoryRepository(_database);

      debugPrint('[Fushi] init: repositories (parallel)');
      await Future.wait(<Future<void>>[
        prefsRepo.loadFromDb(),
        profileRepo.ensureDefaultProfile(),
        dictRepo.loadFromDb(),
        mediaHistoryRepo.loadFromDb(),
      ]);
      prefsRepo.addListener(notifyListeners);
      // 代理是**进程级**网络出口配置，却只存在偏好里；同步层的单例（GoogleDriveAuth 等）
      // 拿不到 AppModel，以前就只能各自裸连——BUG-1348 的谷歌云盘登录超时正是如此。偏好
      // 一装载好就把进程级读取器接上去，此后任何 applyAppProxy(client) 都自动拿到同一个值，
      // 不必沿调用链穿参（穿漏一处 = 一条不走代理的暗路）。
      appUserProxyReader = () => prefsRepo.updateCustomProxy;
      _applyMemoryPolicy();
      _mediaTrackingService = MediaTrackingService(
        repository: MediaTrackingRepository(_database),
        preferences: prefsRepo,
        userAgent: _mediaTrackingUserAgent,
      );
      unawaited(mediaTrackingService.syncNow());

      final Map<String, String> prefsSnapshot = prefsRepo.prefsSnapshot;

      themeNotifier = ThemeNotifier(_database, () => textTheme);
      themeNotifier.loadFromPrefsSnapshot(prefsSnapshot);
      themeNotifier.addListener(notifyListeners);
      _themeListenerAdded = true;

      debugPrint('[Fushi] init: directories + system palette (parallel)');
      _browserDirectory = Directory(path.join(appDirectory.path, 'browser'));
      _thumbnailsDirectory =
          Directory(path.join(appDirectory.path, 'thumbnails'));

      _dictionaryResourceDirectory =
          Directory(path.join(appDirectory.path, 'dictionaryResources'));

      _dictionaryImportWorkingDirectory = Directory(
          path.join(appDirectory.path, 'dictionaryImportWorkingDirectory'));
      _webArchiveDirectory =
          Directory(path.join(appDirectory.path, 'webArchive'));

      // TODO-1260：这些目录都派生自数据根（documentsRoot）；盘掉线时 create() 会 hang。
      ErrorLogService.instance.markInitStep(
          'create-runtime-dirs（thumbnails / dictionaryResources 等目录创建）');
      await _guardInitIo(
        'create-runtime-dirs',
        Future.wait(<Future<void>>[
          thumbnailsDirectory.create(recursive: true),
          dictionaryImportWorkingDirectory.create(recursive: true),
          dictionaryResourceDirectory.create(recursive: true),
          refreshSystemPalette(),
          () async {
            _exportDirectory = await prepareFallbackHibikiDirectory();
            _alternateExportDirectory = _exportDirectory;
          }(),
        ]),
      );

      // TODO-1260：内部对每本词典的资源目录做 exists() 探测（数据根派生），同样叠超时。
      ErrorLogService.instance
          .markInitStep('rebuild-dict-paths（词典资源目录 exists 探测）');
      await _guardInitIo('rebuild-dict-paths', _rebuildDictPathsCacheAsync());

      _localAudioManager = LocalAudioManager(
        prefsRepo: prefsRepo,
        databaseDirectory: _databaseDirectory,
      );
      _fileExportManager = FileExportManager(
        exportDirectory: _exportDirectory,
        alternateExportDirectory: _alternateExportDirectory,
      );

      debugPrint('[Fushi] init: populate maps + audio DB (parallel)');
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
        JapaneseLanguage.instance.initialise(),
        injectAssetLicenses(),
        _seedBuiltInTags(),
        _localAudioManager.bindForNativeHandler(clearMissingPath: true),
      ]);

      debugPrint(
          '[Fushi] init: reader settings + enhancements + quick actions + media sources (parallel)');
      MediaSource.setDatabase(_database);
      final readerSettings = ReaderSettings(_database);
      await readerSettings.loadFromPrefsSnapshot(prefsSnapshot);
      // TODO-1393 self-heal: recover custom-font entries whose stored absolute
      // path went stale (data-root move / pre-fix backup restore that never
      // rebased `font_catalog` / iOS reinstall / profile-import stripped path) by
      // relocating them onto same-basename files still present under the current
      // `<documents>/custom_fonts`. Runs before the font resolution below so the
      // app-wide + subtitle fonts load from healed paths on first paint. Idempotent
      // (a no-op DB touch when every path already resolves).
      try {
        final int relocated = await readerSettings.healMissingFontFilePaths(
          path.join(appDirectory.path, 'custom_fonts'),
        );
        if (relocated > 0) {
          debugPrint(
              '[Fushi] init: relocated $relocated stale custom-font path(s) to current custom_fonts dir');
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('AppModel.healFontPaths', e, stack);
      }
      // Register the user's custom app-wide fonts (every enabled entry, in
      // order — the chain feeds fontFamily + fontFamilyFallback) before first
      // paint so the global theme uses them without a flash. Reuses the
      // settings just loaded above to avoid a second prefs read.
      _appFontFamilies =
          await AppFontLoader.resolveAndLoadAll(readerSettings.appUiFonts);
      // TODO-864: 视频字幕字体同样在首帧前从 videoSubtitle 目标解析。
      _subtitleFontFamily =
          await AppFontLoader.resolveAndLoad(readerSettings.videoSubtitleFonts);
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

      debugPrint('[Fushi] init: search preload (parallel)');
      final String warmupChar =
          JapaneseLanguage.instance.helloWorld.substring(0, 1);
      unawaited(Future.wait(<Future<void>>[
        searchDictionary(
          searchTerm: JapaneseLanguage.instance.helloWorld,
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
        debugPrint('[Fushi] search warmup failed (non-fatal): $e');
        return <void>[];
      }));

      debugPrint('[Fushi] init: DONE');
      // TODO-1260：启动正常跑完，清掉启动步进面包屑（否则下次启动会误报上次 hang）。
      ErrorLogService.instance.clearInitStep();
      _isInitialised = true;
      // TODO-855: prime the prefs-version watermark from the freshly loaded
      // cache (keeps refreshPrefCacheIfChanged consistent if ever reused here).
      _lastSeenPrefsVersion = prefsRepo.prefsVersion;
      _setupFloatingDictHandlers();
      // 已迁移只读态（Fushi 迁移 P1-4）：不再自启互联服务——两版并存时端口
      // 固定必冲突（SyncServerPortInUseException 会打到用户脸上）；老版只保
      // 留「重新导出」通道。
      if (isMigrationReadonly) {
        notifyListeners();
        return;
      }
      // Start the LAN sync server now if hosting is enabled, so it runs app-wide
      // for the whole session instead of only while the sync settings page is on
      // screen (BUG-085). Fire-and-forget: a bind failure self-disables + is
      // logged and must never break app init.
      unawaited(syncServerController.startIfEnabled().then((
        FushiServerStartOutcome outcome,
      ) {
        if (outcome is FushiServerPortInUse) {
          ErrorLogService.instance.log(
            'AppModel.startSyncServer',
            'port ${outcome.port} in use',
            StackTrace.current,
          );
        } else if (outcome is FushiServerStartError) {
          ErrorLogService.instance.log(
            'AppModel.startSyncServer',
            outcome.message,
            StackTrace.current,
          );
        }
      }).catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('AppModel.startSyncServer', e, s);
      }));
      // 合集变更 → 防抖轻量同步（根修「合集经常没同步」：合集维度原本只搭载在
      // 低频全量 sweep 上，增删合集后长时间不推送）。任何合集表写入都会在防抖
      // 后跑一轮只含合集维度的双通道同步，见 installCollectionsSyncWatcher 文档。
      installCollectionsSyncWatcher(db: database);
      if (yomitanApiServerEnabled) {
        // fail-open：自启动失败绝不阻塞 init、不改开关语义，但必须留痕（BUG-911），
        // 与邻居 startSyncServer / refreshBrowserExtensionCopy 一致记日志，避免静默吞异常。
        unawaited(startYomitanApiServer().catchError((Object e, StackTrace s) {
          ErrorLogService.instance
              .log('AppModel.startYomitanApiServer.autostart', e, s);
        }));
      }
      // BUG-726：桌面端启动时把 <appSupport> 下已解压的浏览器扩展副本刷新到当前内置版本
      // （只在用户装过扩展、指纹不一致时重解压；没装过不落盘）。此前该副本只在手动跑
      // 「安装扩展」助手时写入 → app 升级后磁盘副本永远停在安装当天的旧版，扩展弹窗与
      // app 内弹窗漂移（BUG-621/688 修了也到不了用户浏览器）。fire-and-forget 不阻塞 init。
      unawaited(
          refreshBrowserExtensionCopy().catchError((Object e, StackTrace s) {
        ErrorLogService.instance
            .log('AppModel.refreshBrowserExtensionCopy', e, s);
      }));
      if (texthookerEnabled) {
        TexthookerWsClientManager.instance.start(texthookerUrls);
      }
      // TODO-861③：启动 check-due 词典自动更新（前台、静默、不弹错）。fire-and-forget，
      // 失败自吞 + 记日志，绝不阻塞 / 中断 app init（守卫见 maybeAutoUpdateDictionaries）。
      unawaited(
          maybeAutoUpdateDictionaries().catchError((Object e, StackTrace s) {
        ErrorLogService.instance
            .log('AppModel.maybeAutoUpdateDictionaries', e, s);
      }));
      // 番剧下载：启动 qb 完成监听 + 自动入库（fire-and-forget；未配置 qb 时每
      // tick 直接返回，无网络开销，绝不阻塞/中断 init）。
      unawaited(
          startAnimeDownloadService().catchError((Object e, StackTrace s) {
        ErrorLogService.instance
            .log('AppModel.startAnimeDownloadService', e, s);
      }));
      notifyListeners();
    } on DataRootUnavailableException catch (e, stack) {
      // BUG-815: a custom data root IS configured but is currently unreachable
      // (slow/sleeping/disconnected drive). AppPaths.resolve threw INSTEAD of
      // silently deriving the empty default location — the DB was never opened
      // (_databaseOpened stays false, so retry is a clean re-run). Surface a
      // dedicated "data location unavailable" escape screen (Retry / explicit
      // opt-in-to-default); do NOT set _initError so the generic error screen
      // doesn't shadow it. The real data is untouched on e.configuredPath.
      debugPrint('[Fushi] init PAUSED (data root unavailable): $e\n$stack');
      ErrorLogService.instance
          .log('AppModel.initialise.dataRootUnavailable', e, stack);
      _dataRootUnavailable = e;
      notifyListeners();
    } on FushiDatabaseDowngradeException catch (e, stack) {
      // The DB is newer than this build. drift refused to open it WITHOUT
      // touching the file (no DROP / migration ran). Surface a dedicated,
      // non-retryable notice instead of the generic init-error screen, and
      // STOP — never continue init, never delete or rebuild the DB.
      debugPrint('[Fushi] init REFUSED (DB downgrade): $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise.downgrade', e, stack);
      _downgradeError = e;
      _initError = '$e';
      notifyListeners();
    } on FushiDatabaseUnrecoverableException catch (e, stack) {
      // TODO-905: the WAL/sidecar recovery ladder already ran inside the open
      // path and exhausted — the main hibiki.db is corrupt. Surface a dedicated,
      // actionable notice (restore backup / clear data) instead of looping the
      // generic Retry button forever against the same un-openable file.
      debugPrint('[Fushi] init FAILED (DB unrecoverable): $e\n$stack');
      ErrorLogService.instance
          .log('AppModel.initialise.unrecoverableDb', e, stack);
      _unrecoverableDbError = e;
      _initError = '$e';
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Fushi] init FAILED: $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise', e, stack);
      _initError = '$e';
      notifyListeners();
    }
  }

  Future<void> initialiseForDictionaryPopup() async {
    if (_isInitialised) {
      debugPrint('[Fushi-popup] init: already initialised, '
          'refreshing prefs if changed');
      // TODO-855: only do the expensive full reload when the main app actually
      // mutated a preference / switched profile since the last lookup; a cheap
      // single-row DB version read gates it.
      await refreshPrefCacheIfChanged();
      await _localAudioManager.bindForNativeHandler();
      return;
    }
    try {
      debugPrint('[Fushi-popup] init: PackageInfo + DeviceInfo');
      _packageInfo = await PackageInfo.fromPlatform();
      _mediaTrackingAppVersion = _packageInfo.version;
      await platformServices.init();

      debugPrint('[Fushi-popup] init: directories');
      await _prepareRuntimeDirectories();

      debugPrint('[Fushi-popup] init: Drift database');
      // TODO-905 D3: the :popup process must NOT delete a poisoned -wal/-shm
      // sidecar (the main process owns recovery); it backs off on IOERR.
      _database = FushiDatabase(_databaseDirectory.path, isMainProcess: false);
      _databaseOpened = true;

      _prefsRepo = PreferencesRepository(_database);
      await prefsRepo.loadFromDb();
      prefsRepo.addListener(notifyListeners);
      _mediaTrackingService = MediaTrackingService(
        repository: MediaTrackingRepository(_database),
        preferences: prefsRepo,
        userAgent: _mediaTrackingUserAgent,
      );

      dictRepo = DictionaryRepository(_database,
          onCacheRebuild: _rebuildDictPathsCache,
          isLowMemory: () => prefsRepo.lowMemoryMode);
      await dictRepo.loadFromDb();

      mediaHistoryRepo = MediaHistoryRepository(_database);
      await mediaHistoryRepo.loadFromDb();
      clipboardHistoryRepo = ClipboardHistoryRepository(_database);
      await clipboardHistoryRepo.loadFromDb();

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
        JapaneseLanguage.instance.initialise(),
        ReaderHibikiSource.instance.initialise(),
        Future.wait(<Future<void>>[
          for (Field field in globalFields)
            for (Enhancement enhancement in enhancements[field]!.values)
              enhancement.initialise(),
        ]),
      ]);

      // 弹窗进程也要加载用户的快捷键绑定：弹窗内的「上/下一个词条」（Alt+滚轮）由
      // popup_settings_injection 把 shortcutRegistry 里的滚轮绑定注入给 popup.js，
      // 不加载就只能发默认值、用户改的键在这个进程里不生效。与主 initialise() 同样
      // 排在 ReaderHibikiSource.initialise() 之后（BUG-207：偏好缓存必须先就位，
      // 否则读到空缓存会把用户快照写成 's:null'）。
      await loadShortcutRegistry(
        shortcutRegistry,
        ReaderHibikiSource.instance,
        defaultTargetPlatform,
      );

      debugPrint('[Fushi-popup] init: DONE');
      _isInitialised = true;
      // TODO-855: prime the prefs-version watermark from the freshly loaded
      // cache so the first warm-reuse lookup doesn't trigger a redundant reload.
      _lastSeenPrefsVersion = prefsRepo.prefsVersion;
      notifyListeners();
    } catch (e, stack) {
      ErrorLogService.instance.log('AppModel.popupInit', e, stack);
      debugPrint('[Fushi-popup] init FAILED: $e\n$stack');
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
    // TODO-855: after a full reload the in-memory cache holds the latest DB
    // version, so advance the watermark to keep refreshPrefCacheIfChanged from
    // immediately reloading again.
    _lastSeenPrefsVersion = prefsRepo.prefsVersion;
  }

  /// TODO-855: refresh the preference cache only when the persisted prefs
  /// version in the DB differs from the last value this process reconciled
  /// against. This is the warm-reuse :popup hot path: a separate process whose
  /// cache survives across external lookups but never observes the main app's
  /// profile switches / preference edits directly. A single indexed
  /// [PreferencesRepository.readPrefsVersionFromDb] row read replaces the
  /// previous unconditional full-table [refreshPrefCache] on every lookup; the
  /// expensive reload now happens only when something actually changed.
  Future<void> refreshPrefCacheIfChanged() async {
    final int dbVersion = await prefsRepo.readPrefsVersionFromDb();
    if (dbVersion == _lastSeenPrefsVersion) return;
    await refreshPrefCache();
    // refreshPrefCache already advanced _lastSeenPrefsVersion from the reloaded
    // cache; align it to the value we just read so a concurrent writer between
    // the read and the reload can still be detected on the next call.
    _lastSeenPrefsVersion = dbVersion;
  }

  // ── sync pref helpers (delegated to PreferencesRepository) ──────────

  dynamic _getPref(String key, {dynamic defaultValue}) =>
      prefsRepo.getPref(key, defaultValue: defaultValue);

  Future<void> _setPref(String key, dynamic value) =>
      prefsRepo.setPref(key, value);

  // TODO-1166：新装时把内置默认标签播种为 5 档星级评分（1⭐..5⭐）。
  // 仍是「一次性、仅空池」播种：`builtInTagsSeeded` 标志种过即不再动，空池才种，
  // 保证既有用户的标签池不被覆盖（老用户改星级走标签管理页的一键补齐入口）。
  Future<void> _seedBuiltInTags() async {
    if (prefsRepo.containsKey('builtInTagsSeeded')) return;
    final existing = await _database.getAllTags();
    if (existing.isEmpty) {
      await seedStarRatingTags(_database);
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

  // TODO-930: multi custom theme list delegation. The UI (theme swatch row +
  // CustomThemePage) talks to AppModel, so mirror ThemeNotifier's list API here
  // exactly like the legacy flat custom_theme_* getters above.
  List<CustomThemeEntry> get customThemes => themeNotifier.customThemes;
  CustomThemeEntry? customThemeById(String id) =>
      themeNotifier.customThemeById(id);
  String? get selectedCustomThemeId => themeNotifier.selectedCustomThemeId;
  CustomThemeEntry? get activeCustomThemeEntry =>
      themeNotifier.activeCustomThemeEntry;
  Future<void> upsertCustomTheme(CustomThemeEntry entry) =>
      themeNotifier.upsertCustomTheme(entry);
  Future<void> deleteCustomTheme(String id) =>
      themeNotifier.deleteCustomTheme(id);
  Future<void> selectCustomTheme(String id) =>
      themeNotifier.selectCustomTheme(id);

  String get brightnessMode => themeNotifier.brightnessMode;
  Future<void> setBrightnessMode(String mode) =>
      themeNotifier.setBrightnessMode(mode);

  /// 墨水屏模式（E-ink）：全局纯黑白主题 + 关动画 + 阅读器/弹窗高对比。
  bool get einkMode => themeNotifier.einkMode;
  Future<void> setEinkMode(bool value) => themeNotifier.setEinkMode(value);

  /// BUG-530：当前 app 主题（MD3 ColorScheme）的关键色 + 查词弹窗尺寸/列数/字号配置，作为
  /// CSS 变量喂给浏览器扩展的查词弹窗（经查词响应的 `theme` 字段下发，改主题/配置即生效，无需
  /// 重装扩展）。内容 content.js 把每一项 `setProperty` 到 `#entries-container` 上，popup.css
  /// 用 `var(...)` 消费：`--md-*` 上色、`--hibiki-popup-max-width/height` 定弹窗盒、
  /// `--hibiki-popup-zoom` 缩放内容字号、`--dict-columns` 决定词典多列布局。与 in-app 弹窗
  /// 注入的 md 变量 / --dict-columns / zoom 同源（dictionary_popup_webview / popup_settings_injection 一致）。
  Map<String, String> browserExtensionThemeColors() {
    final ColorScheme s = themeNotifier.buildColorScheme(
        themeNotifier.isDarkMode ? Brightness.dark : Brightness.light);
    final Color bgColor = _overrideDictionaryColor ?? s.surface;
    // BUG-736：核心色/圆角/列数变量的取值统一来自 buildPopupThemeCssVars——与 in-app
    // 弹窗注入器（popup_settings_injection / dictionary_popup_webview）同一真源，
    // 根除「扩展漏抄一处、退化成灰高亮/白字/直角」的手抄漂移。
    // 注：--md-surface-container-high 沿用扩展侧历史行为，override 色一并顶掉它。
    final Map<String, String> vars = buildPopupThemeCssVars(
      scheme: s,
      backgroundColor: bgColor,
      surfaceContainerHigh: _overrideDictionaryColor ?? s.surfaceContainerHigh,
      dictionaryColumns: popupDictionaryColumns,
    );
    // BUG-688：浏览器浮动弹窗只跟「词典字号」，**不叠加** app 的「界面大小」(appUiScale)。
    // 叠加 appUiScale 会把弹窗放大到 1.5×+ → 浮在网页上盖住大半屏、需滚动条，且大 zoom 作用于
    // 嵌套容器时触发 Blink「CSS zoom + 振假名(rt)绝对定位错位」→ 假名与正文重叠（app 内缩放的
    // 是页面根 documentElement，无此问题；扩展只能缩放浮层嵌套容器）。要更大在词典字号设置里调。
    final double rawZoom = dictionaryFontSize / 16.0;
    final double zoom =
        (rawZoom.isFinite && rawZoom > 0) ? rawZoom.clamp(0.3, 8.0) : 1.0;
    return <String, String>{
      // BUG-688：content.css/popup.css 的正文色/底色直接读 --text-color / --background-color
      // （见 content.css `color: var(--text-color)` / `background-color: var(--background-color)`）。
      // 与 in-app _themeVariablesJs 一致地下发这两个核心变量；漏了它们会导致弹窗容器色回落到
      // data-theme 块的 #000/#fff 或宿主页继承（主题分裂：米卡 + 黑底 + 灰字）。
      '--text-color': vars['--text-color']!,
      '--background-color': vars['--background-color']!,
      // BUG-736：查到词的高亮色。漏发时 popup.css 回落到灰 rgba(160,160,160,0.4)，与 app
      // 内的主题主色高亮不一致（这是「扩展弹窗和 app 不一样」最扎眼的一处）。
      '--hoshi-primary-highlight': vars['--hoshi-primary-highlight']!,
      // BUG-736：卡片底色 alpha 合成用的 RGB 三元组（配 popup.css 的 --hibiki-card-bg-alpha）。
      // 漏发时回落到纯白 255,255,255。
      '--hibiki-card-bg-rgb': vars['--hibiki-card-bg-rgb']!,
      // BUG-688：app 当前明暗，content.js 据此把 #entries-container 的 data-theme 对齐 app
      // （而非宿主网页 prefers-color-scheme），根除「data-theme 跟宿主页 / --md-* 跟 app」的分裂。
      '--hibiki-color-scheme': themeNotifier.isDarkMode ? 'dark' : 'light',
      '--md-surface-container-high': vars['--md-surface-container-high']!,
      '--md-surface-container': vars['--md-surface-container']!,
      '--md-on-surface': vars['--md-on-surface']!,
      '--md-on-surface-variant': vars['--md-on-surface-variant']!,
      '--md-outline-variant': vars['--md-outline-variant']!,
      '--md-primary': vars['--md-primary']!,
      // BUG-736：主色上的文字/图标色（popup.css `color: var(--md-on-primary,#fff)`）。
      '--md-on-primary': vars['--md-on-primary']!,
      // BUG-736：卡片圆角。漏发时 popup.css 回落到硬编码 10px，与 app 内用户设定的圆角
      // （FushiRadii.cardValue，经 buildPopupThemeCssVars）不一致。与两个 in-app 注入器同源。
      '--hibiki-radius-card': vars['--hibiki-radius-card']!,
      // 弹窗尺寸精细化：扩展弹窗默认跟随 app 内 popupMaxWidth/Height，用户显式
      // 解锁「浏览器扩展独立尺寸」后改用扩展自己的键（extensionPopupEffectiveSize）。
      '--hibiki-popup-max-width':
          '${extensionPopupEffectiveSize.width.round()}px',
      '--hibiki-popup-max-height':
          '${extensionPopupEffectiveSize.height.round()}px',
      '--hibiki-popup-zoom': zoom.toStringAsFixed(4),
      '--dict-columns': '$popupDictionaryColumns',
      // 「滑动关闭查词弹窗」偏好（enableSwipeToClose）下发给扩展 content.js：非 CSS 变量、
      // 仅 JS 消费（content.js 据此决定是否给浮动弹窗启用水平拖关手势）。走 theme 传输通道
      // 与 --hibiki-color-scheme 同法（那个也被当 data-theme 而非 CSS 值消费）。值 '1'/'0'。
      '--hibiki-swipe-close':
          ReaderHibikiSource.instance.enableSwipeToClose ? '1' : '0',
      // BUG-1026：查词弹窗滚轮速度倍率下发给扩展 content.js（非 CSS 变量、仅 JS 消费）。
      // content.js hibikiRender 读它设 window.__hoshiPopupWheelSpeed（与 in-app 注入同名
      // 全局），popup.js 的 wheel factor 乘它。走 theme 通道与 --hibiki-swipe-close 同法。
      '--hibiki-wheel-speed': popupWheelSpeed.toStringAsFixed(3),
    };
  }

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

  Color? get customThemeSentenceAudioHighlightColor =>
      themeNotifier.customThemeSentenceAudioHighlightColor;
  Future<void> setCustomThemeSentenceAudioHighlightColor(Color? c) =>
      themeNotifier.setCustomThemeSentenceAudioHighlightColor(c);

  /// TODO-977: 全局音频高亮颜色（与阅读器主题解耦），委托 ThemeNotifier。
  Color? get audioHighlightColor => themeNotifier.audioHighlightColor;
  Future<void> setAudioHighlightColor(Color? c) =>
      themeNotifier.setAudioHighlightColor(c);

  Color? get customThemeLinkColor => themeNotifier.customThemeLinkColor;
  Future<void> setCustomThemeLinkColor(Color? c) =>
      themeNotifier.setCustomThemeLinkColor(c);

  // TODO-928: 委托层同步删 `brightnessMode` 参数（不再透传）。
  Future<void> applyCustomTheme({
    required Color seed,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sentenceAudioHighlightColor,
    Color? linkColor,
  }) =>
      themeNotifier.applyCustomTheme(
        seed: seed,
        fontColor: fontColor,
        backgroundColor: backgroundColor,
        selectionColor: selectionColor,
        primaryColor: primaryColor,
        secondaryColor: secondaryColor,
        tertiaryColor: tertiaryColor,
        containerColor: containerColor,
        sentenceAudioHighlightColor: sentenceAudioHighlightColor,
        linkColor: linkColor,
      );

  // targetLanguage getter 已删（2026-07-26，用户指令）：它恒返回
  // JapaneseLanguage.instance，是个假装可配置的间接层（语言选择从未有 UI，
  // en/zh 子类与 setter 已于 2026-06-05 删除）。日语专属功能（振假名/音高/
  // 字体/字幕语言码/helloWorld 预热等）现直接引用 JapaneseLanguage.instance。
  // 注意：查词流水线语言无关（18 语言变换表全量加载是有意设计），从不经过
  // 这个概念。守卫：test/models/target_language_removed_guard_test.dart。

  String get lastSelectedDeckName => prefsRepo.lastSelectedDeckName;

  /// Get the last selected dictionary format from persisted preferences.
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

  /// Persist a new app locale in preferences and switch the UI language.
  ///
  /// Desktop (TODO-960): live hot-reload, **never** restart the process. The
  /// desktop restart path (`Process.start(detached) + exit(0)`) races the
  /// Windows single-instance mutex (`windows/runner/main.cpp`): the freshly
  /// spawned process reaches `CreateMutexW` before the old process has called
  /// `exit(0)`, gets `ERROR_ALREADY_EXISTS`, fronts the old window then
  /// `return EXIT_SUCCESS` (self-terminates) — moments later the old process
  /// also exits, leaving no process at all (app closes, never reopens). So on
  /// desktop we mutate [LocaleSettings] in place and [notifyListeners]; because
  /// the bulk of the UI reads the global Method A `t` (which does NOT rebuild
  /// on a [LocaleSettings] change by itself), the root widget tree is
  /// additionally remounted via a locale-keyed [Key] at [main]'s
  /// [TranslationProvider] (see `_FushiReaderAppState.build`).
  ///
  /// Mobile (Android/iOS) keeps the native restart path (`restart_app` plugin
  /// rebuilds the Activity/scene — no mutex race). The data-root migration
  /// path still restarts on every platform via its own call site
  /// (`data_root.part.dart`), and is intentionally unaffected by this method.
  Future<void> setAppLocale(String localeTag) async {
    await _setPref('app_locale', localeTag);
    LocaleSettings.setLocaleRaw(localeTag);
    if (isDesktopPlatform) {
      notifyListeners();
      return;
    }
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

  /// 启用的 mpv 着色器（JSON 字符串数组；见 video_shader_manager.dart）。
  String get videoShadersEnabled => prefsRepo.videoShadersEnabled;

  Future<void> setVideoShadersEnabled(String json) =>
      prefsRepo.setVideoShadersEnabled(json);

  /// 用户手动指定的本机 mpv 配置/着色器目录（空=自动）。
  String get videoMpvShaderDir => prefsRepo.videoMpvShaderDir;

  Future<void> setVideoMpvShaderDir(String dir) =>
      prefsRepo.setVideoMpvShaderDir(dir);

  /// 视频字幕模糊（听力沉浸）开关；默认关闭。TODO-840 Part B 起这是遮蔽模式三态的
  /// 历史 bool 投影（blur/hide 都为 true），精确三态读 [videoSubtitleObscureMode]。
  bool get videoSubtitleBlur => prefsRepo.videoSubtitleBlur;

  Future<void> setVideoSubtitleBlur(bool value) =>
      prefsRepo.setVideoSubtitleBlur(value);

  /// 视频字幕遮蔽模式三态（TODO-840 Part B）：不遮蔽 / 模糊 / 隐藏。委托 prefsRepo 的
  /// lazy 投影持久化（见 [PreferencesRepository.videoSubtitleObscureMode]）。
  VideoSubtitleObscureMode get videoSubtitleObscureMode =>
      prefsRepo.videoSubtitleObscureMode;

  Future<void> setVideoSubtitleObscureMode(VideoSubtitleObscureMode mode) =>
      prefsRepo.setVideoSubtitleObscureMode(mode);

  /// 视频**副字幕**遮蔽模式三态（TODO-1382，独立于主字幕）：不遮蔽 / 模糊 / 隐藏。
  /// 委托 prefsRepo 的 lazy 投影持久化（见
  /// [PreferencesRepository.videoSecondarySubtitleObscureMode]）。
  VideoSubtitleObscureMode get videoSecondarySubtitleObscureMode =>
      prefsRepo.videoSecondarySubtitleObscureMode;

  Future<void> setVideoSecondarySubtitleObscureMode(
    VideoSubtitleObscureMode mode,
  ) =>
      prefsRepo.setVideoSecondarySubtitleObscureMode(mode);

  /// 显式全局广播（= 本 model 的 `notifyListeners`，对外可调用）。
  ///
  /// 给「写入方**刻意**不广播、但某个调用点确实需要全局刷新」的路径用：遮蔽模式两个
  /// setter 为了不让高频快捷键重建整个 app 而不广播（见
  /// [PreferencesRepository.setVideoSubtitleObscureMode]），从全局设置页改时由
  /// `setVideoSubtitleObscureModeDual` 显式补这一次。不要拿它当「顺手刷一下 UI」的
  /// 万能锤——每次调用都会重建所有 watch [appProvider] 的 widget。
  void notifyPreferencesChanged() => notifyListeners();

  /// 视频字幕列表自动滚动开关（TODO-613，落 Drift preferences，默认开）。
  bool get videoSubtitleListAutoScroll => prefsRepo.videoSubtitleListAutoScroll;

  Future<void> setVideoSubtitleListAutoScroll(bool value) =>
      prefsRepo.setVideoSubtitleListAutoScroll(value);

  /// 视频字幕列表行字号档位（BUG-878，落 Drift preferences，默认 1=1.0x）。
  int get videoSubtitleListFontScaleIndex =>
      prefsRepo.videoSubtitleListFontScaleIndex;

  Future<void> setVideoSubtitleListFontScaleIndex(int value) =>
      prefsRepo.setVideoSubtitleListFontScaleIndex(value);

  /// 视频字幕列表面板宽度（逻辑像素，BUG-877，落 Drift preferences，0=跟随自适应）。
  double get videoSubtitleListWidth => prefsRepo.videoSubtitleListWidth;

  Future<void> setVideoSubtitleListWidth(double value) =>
      prefsRepo.setVideoSubtitleListWidth(value);

  /// 播放列表自动连播开关（TODO-639，落 Drift preferences，默认开）。
  bool get videoAutoPlayNext => prefsRepo.videoAutoPlayNext;

  Future<void> setVideoAutoPlayNext(bool value) =>
      prefsRepo.setVideoAutoPlayNext(value);

  /// 视频条目自动刮削开关（落 Drift preferences，默认开）。
  bool get videoAutoScrape => prefsRepo.videoAutoScrape;

  Future<void> setVideoAutoScrape(bool value) =>
      prefsRepo.setVideoAutoScrape(value);

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

  /// 弹幕样式（字号/不透明度/速度/显示区域，TODO-1376）。
  VideoDanmakuStyle get videoDanmakuStyle => prefsRepo.videoDanmakuStyle;

  Future<void> setVideoDanmakuStyle(VideoDanmakuStyle style) =>
      prefsRepo.setVideoDanmakuStyle(style);

  /// 弹幕屏蔽规则原始多行文本（每行一条，`/pattern/` 为正则，TODO-1376）。
  String get videoDanmakuBlockRulesText => prefsRepo.videoDanmakuBlockRulesText;

  Future<void> setVideoDanmakuBlockRulesText(String value) =>
      prefsRepo.setVideoDanmakuBlockRulesText(value);

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

  /// 视频控制按钮 9-槽位布局（TODO-274/312 phase 2，持久化键沿用旧三档时期键名，v1 自动迁移）。
  VideoControlLayout get videoControlLayout => prefsRepo.videoControlLayout;

  Future<void> setVideoControlLayout(VideoControlLayout layout) =>
      prefsRepo.setVideoControlLayout(layout);

  /// 视频字幕外观（JSON；见 VideoSubtitleStyle）。
  String get videoSubtitleStyle => prefsRepo.videoSubtitleStyle;

  Future<void> setVideoSubtitleStyle(String json) =>
      prefsRepo.setVideoSubtitleStyle(json);

  /// 是否尊重 .ass 字幕自带样式（TODO-1105；默认 true）。
  bool get videoRespectAssStyle => prefsRepo.videoRespectAssStyle;

  Future<void> setVideoRespectAssStyle(bool value) =>
      prefsRepo.setVideoRespectAssStyle(value);

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

  /// Jimaku 默认字幕语言（`''` = 不限）。见
  /// [PreferencesRepository.jimakuDefaultLanguage]。
  ///
  /// 走 `_prefsRepo?`：几处消费者在 `initState` 里读，偏好仓库尚未就绪（启动早期）
  /// 时应回退「不限」，而不是崩在一个纯锦上添花的默认值上。
  String get jimakuDefaultLanguage => _prefsRepo?.jimakuDefaultLanguage ?? '';

  Future<void> setJimakuDefaultLanguage(String langCode) =>
      prefsRepo.setJimakuDefaultLanguage(langCode);

  /// 默认字幕语言归一成语言选择器用的 `String?`（`''`/空白 → null = 不限）。
  /// 三个 Jimaku 界面（字幕对话框 / 番剧下载 / 批量匹配）共用同一兜底。
  ///
  String? get jimakuDefaultLanguageOrNull {
    final String code = jimakuDefaultLanguage.trim();
    return code.isEmpty ? null : code;
  }

  /// qBittorrent WebUI 连接配置（番剧下载）；null = 未配置未启用。
  QbConnectionConfig? get qbConnectionConfig => prefsRepo.qbConnectionConfig;

  Future<void> setQbConnectionConfig(QbConnectionConfig? config) async {
    await prefsRepo.setQbConnectionConfig(config);
    // 内置引擎资源限制即时生效（用户在设置里改限速/连接数后不必重启）。
    _applyEmbeddedTorrentLimits(config);
  }

  // galgame 窗口超分**每游戏一档**（BUG-1191），存 `galgames.upscaling_mode`，
  // 读写走 [galgameRepo]。这里刻意不再有全局 getter/setter —— 留着一个全局值就会
  // 有人接回去用，然后两份真值慢慢漂开。

  DownloadNetworkProxyConfig get downloadNetworkProxyConfig =>
      DownloadNetworkProxyConfig(
        mode: DownloadNetworkProxyMode.parse(
          prefsRepo.downloadNetworkProxyMode,
        ),
        customProxy: prefsRepo.downloadCustomProxy,
      );

  Future<void> setDownloadNetworkProxyMode(
    DownloadNetworkProxyMode mode,
  ) =>
      prefsRepo.setDownloadNetworkProxyMode(mode.name);

  Future<void> setDownloadCustomProxy(String value) =>
      prefsRepo.setDownloadCustomProxy(value);

  /// Proxy-aware client shared by AniList, Nyaa and Jimaku call sites.
  Future<http.Client> createDownloadHttpClient() =>
      buildDownloadHttpClient(downloadNetworkProxyConfig);

  /// 把配置里的内置引擎资源限制应用到常驻宿主（宿主不存在则 no-op）。
  void _applyEmbeddedTorrentLimits(QbConnectionConfig? config) {
    final EmbeddedTorrentHost? host = _embeddedTorrentHost;
    if (host == null) return;
    final QbConnectionConfig effective = effectiveTorrentConfig(config);
    host.applyLimits(
      downloadKbps: effective.downloadLimitKbps,
      uploadKbps: effective.uploadLimitKbps,
      maxConnections: effective.maxConnections,
      limitLocalPeers: effective.limitLocalPeers,
    );
    // 内存占用上限（按物理内存或用户设定推导；避免 libtorrent 吃满内存）。
    // 用户显式设了 maxConnections 就不用内存预算的连接数覆盖它（传 0）。
    final TorrentMemorySettings mem = computeTorrentMemorySettings(
      memoryLimitMb: effective.memoryLimitMb,
      totalRamMb: detectTotalMemoryMb() ?? 0,
    );
    host.applyMemorySettings(
      mem,
      connectionsLimit: effective.maxConnections > 0 ? 0 : mem.connectionsLimit,
    );
    // 会话级设置（端口/DHT/LSD/UPnP/NAT-PMP/加密/匿名/活跃数/上传槽）。
    host.applySessionSettings(effective);
    // 反吸血开关/阈值（用户可调）。
    host.applyAntiLeechConfig(effective);
    // 上传/做种策略（默认关上传；开启后做种时长/分享率上限），即时生效。
    host.setUploadPolicy(effective);
  }

  /// 番剧下载：计划存储（选种对话框写计划/暂存字幕，与完成监听服务共用同一实例）。
  AnimeDownloadPlanStore? _animeDownloadPlanStore;
  AnimeDownloadPlanStore? get animeDownloadPlanStore => _animeDownloadPlanStore;

  /// 番剧下载：qb 完成监听 + 自动入库服务（app 生命周期常驻；未配置时每 tick 空转）。
  AnimeDownloadService? _animeDownloadService;
  AnimeDownloadService? get animeDownloadService => _animeDownloadService;

  AnimeDownloadSubscriptionStore? _animeDownloadSubscriptionStore;
  AnimeDownloadSubscriptionStore? get animeDownloadSubscriptionStore =>
      _animeDownloadSubscriptionStore;

  /// mokuro.moe 卷下载队列（懒建，app 生命周期常驻）：「在线目录」对话框只
  /// 负责 enqueue，「下载」页任务 tab 与对话框共同观察本实例——关对话框不
  /// 中断下载（统一下载中心）。书架页监听 importedCount 增量刷新书列表。
  MokuroMoeDownloadQueue? _mokuroMoeDownloadQueue;
  MokuroMoeDownloadQueue get mokuroMoeDownloadQueue =>
      _mokuroMoeDownloadQueue ??= MokuroMoeDownloadQueue(
        db: database,
        clientFactory: () =>
            MokuroMoeClient(baseUrl: mangaOnlineCatalogBaseUrl),
      );

  /// Mihon 扩展生态宿主（Android 原生 / Windows、macOS 内置 Java sidecar）。
  ///
  /// 与 mokuro 下载队列一样按首次访问懒建：普通书架和 Mokuro 浏览不会启动 JVM，
  /// 只有进入漫画源/漫画扩展/来源设置才读取扩展数据库；桌面 runtime 又会等到
  /// 第一次真正调用扩展时才启动 M-Extension-Server。
  MihonManager? _mihonManager;
  MihonManager get mihonManager {
    final MihonManager? existing = _mihonManager;
    if (existing != null) return existing;
    if (!MihonRuntimeFactory.isSupported) {
      throw UnsupportedError(
        'Mihon extensions are unavailable on this platform',
      );
    }
    final Directory root =
        Directory(path.join(databaseDirectory.path, 'mihon'));
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: MihonRuntimeFactory.create(root),
      // 只有真实 app 启动这一处装默认扩展仓库（用户诉求：漫画扩展仓库默认带
      // keiyoushi）。别把它挪进 MihonManager 的默认值——那会让每个构造 manager
      // 的单测都去拉真实网络索引，见 MihonManager.seedDefaultStore 的说明。
      seedDefaultStore: true,
    );
    _mihonManager = manager;
    unawaited(manager.initialise());
    return manager;
  }

  AnimeDownloadSubscriptionService? _animeDownloadSubscriptionService;
  AnimeDownloadSubscriptionService? get animeDownloadSubscriptionService =>
      _animeDownloadSubscriptionService;

  /// 内置 libtorrent 下载宿主。**懒建**：只在第一次真的要用下载后端时才创建
  /// （见 [_ensureEmbeddedTorrentHost]）；DLL 缺失/加载失败为 null，服务回退外接
  /// qb。app 释放时 dispose。
  ///
  /// BUG-1053：以前是在 [startAnimeDownloadService] 里对**所有桌面用户无条件**
  /// 创建——而创建 = 起一个 libtorrent session（绑 6881 TCP+UDP + 默认开 DHT）。
  /// 于是没有任何下载任务的用户，只要 Hibiki 开着就一直在跑全球 DHT，路由器
  /// NAT/conntrack 被小包撑爆 → 整机网络周期性高延迟，关掉 Hibiki 即恢复。
  EmbeddedTorrentHost? _embeddedTorrentHost;
  EmbeddedTorrentHost? get embeddedTorrentHost => _embeddedTorrentHost;

  /// 内置下载根集合（懒建 host 时需要）。[startAnimeDownloadService] 里算好存下，
  /// 避免懒建路径再去 await 一次目录解析。TODO-1961：活动根 = 用户配置目录（未配置
  /// 或不可用时 = 默认根），历史根让改过目录的旧任务在下载页仍然可见。
  TorrentSaveRoots? _embeddedTorrentSaveRoots;

  /// 默认下载根 `<documents>/anime_downloads/content`（设置页展示与「恢复默认」用）。
  String? _downloadDefaultSaveRoot;

  /// TODO-1961-a：resume data 目录 `<documents>/anime_downloads/resume`。
  /// 与 `plans/` / `subs/` 同级 —— 它是 app 状态（哪些种子该活着），跟数据根走，
  /// **不**跟用户配置的下载根走。
  String? _embeddedTorrentResumeDir;

  /// 当前仍存在的计划 id 集合（= infohash）。resume 剪枝的真相源：不在这个集合
  /// 里的 `.resume` 文件一律删，否则用户删掉的任务会在下次启动复活成一个 UI 里
  /// 看不见、却在后台做种的种子。每轮 tick 与启动时刷新。
  ///
  /// **null = 尚未从计划仓库加载过**，绝不能退化成空集合：空集合是「用户真的
  /// 一个计划都没有」的合法取值，会让剪枝删光所有 `.resume`。两者混为一谈时，
  /// 启动竞态里一次早到的剪枝就会把用户全部下载/做种任务永久蒸发
  /// （见 [pruneResumeFiles] 的哨兵与 [startAnimeDownloadService] 的顺序注释）。
  Set<String>? _animeDownloadPlanIds;

  /// 启动时用户配置的下载目录不可用（不存在且建不出/写不进）时记下原因与路径，
  /// 设置页据此显示警告。**不静默**：回退默认根这件事必须让用户看见。
  DownloadSaveRootIssue? _downloadSaveRootIssue;
  String? _downloadSaveRootRejectedPath;

  /// 需要真会话时才建（幂等）。不支持的平台 / 无保存路径 / DLL 不可用 → null，
  /// 调用方自然回退外接 qb。
  EmbeddedTorrentHost? _ensureEmbeddedTorrentHost() {
    final EmbeddedTorrentHost? existing = _embeddedTorrentHost;
    if (existing != null) return existing;
    final TorrentSaveRoots? roots = _embeddedTorrentSaveRoots;
    final String? resumeDir = _embeddedTorrentResumeDir;
    if (roots == null || resumeDir == null || !_supportsEmbeddedTorrent()) {
      return null;
    }
    final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
      baseSavePath: roots.active,
      legacySavePaths: roots.legacy,
      resumeDir: resumeDir,
      restoreIds: _animeDownloadPlanIds,
    );
    if (host == null) return null;
    _embeddedTorrentHost = host;
    // 建好即把已保存的资源限制/会话设置铺上（不必等用户改设置）。
    _applyEmbeddedTorrentLimits(prefsRepo.qbConnectionConfig);
    return host;
  }

  /// 默认下载根（未解析完成前为空串）。
  String get downloadDefaultSaveRoot => _downloadDefaultSaveRoot ?? '';

  /// 已保存的下载根配置（空串 = 用默认根）。
  ///
  /// 走 `_prefsRepo?`（而非 `prefsRepo` 的 `!`）：设置区块能在 AppModel 尚未
  /// `initialise()` 的场景下被构建（widget 测试直接 new AppModel 建区块，
  /// 见 test/pages/torrent_settings_field_width_test.dart），此时 `_prefsRepo`
  /// 还是 null，用 `!` 会在 build 里抛 TypeError 把整块设置炸掉。
  String get _configuredDownloadSaveRoot =>
      _prefsRepo?.downloadSaveRoot.trim() ?? '';

  /// 当前生效的下载根（新任务落点）。未解析完成时回退到已保存的配置值/空串。
  String get downloadSaveRoot =>
      _embeddedTorrentSaveRoots?.active ??
      (_configuredDownloadSaveRoot.isNotEmpty
          ? _configuredDownloadSaveRoot
          : downloadDefaultSaveRoot);

  /// 当前是否在用默认下载根（设置页据此禁用「恢复默认」）。
  bool get downloadSaveRootIsDefault => _configuredDownloadSaveRoot.isEmpty;

  /// 启动时配置目录不可用而回退默认根的原因（null = 没发生过回退）。
  DownloadSaveRootIssue? get downloadSaveRootIssue => _downloadSaveRootIssue;

  /// 被拒绝的配置目录（配合 [downloadSaveRootIssue] 提示用户具体是哪个目录）。
  String? get downloadSaveRootRejectedPath => _downloadSaveRootRejectedPath;

  /// TODO-1961：改下载目录。校验通过才落盘，**只影响之后新增的任务**——旧根进历史
  /// 根列表（下载页仍认得旧任务），已在跑的种子不动（不 move_storage）。
  /// 返回 null = 成功；非 null = 目录不可用的原因，调用方必须反馈给用户。
  Future<DownloadSaveRootIssue?> setDownloadSaveRoot(String newRoot) async {
    final String trimmed = newRoot.trim();
    if (trimmed.isEmpty) return DownloadSaveRootIssue.notAbsolute;
    final DownloadSaveRootIssue? issue = await checkDownloadSaveRoot(trimmed);
    if (issue != null) return issue;
    await _applyDownloadSaveRoot(trimmed);
    return null;
  }

  /// 恢复默认下载根（清空配置 key）。旧根同样降级为历史根，不丢任务。
  Future<void> resetDownloadSaveRoot() => _applyDownloadSaveRoot('');

  /// 落盘 + 就地换活动根。[newRoot] 空串 = 恢复默认根。
  Future<void> _applyDownloadSaveRoot(String newRoot) async {
    final String previousActive =
        _embeddedTorrentSaveRoots?.active ?? prefsRepo.downloadSaveRoot.trim();
    await prefsRepo.setDownloadSaveRoot(newRoot);
    if (previousActive.isNotEmpty) {
      await prefsRepo.setDownloadSaveRootHistory(encodeSaveRootHistory(<String>[
        previousActive,
        ...decodeSaveRootHistory(prefsRepo.downloadSaveRootHistory),
      ]));
    }
    final String active =
        newRoot.trim().isEmpty ? downloadDefaultSaveRoot : newRoot.trim();
    final TorrentSaveRoots? existing = _embeddedTorrentSaveRoots;
    if (existing != null) {
      _embeddedTorrentSaveRoots = existing.withActive(active);
    } else if (active.isNotEmpty) {
      _embeddedTorrentSaveRoots = TorrentSaveRoots(
        active: active,
        legacy: <String>[
          if (previousActive.isNotEmpty) previousActive,
          ...decodeSaveRootHistory(prefsRepo.downloadSaveRootHistory),
        ],
      );
    }
    // 会话已在跑：就地换根，绝不重建 session（重建 = 掐断当前下载与做种）。
    if (active.isNotEmpty) _embeddedTorrentHost?.setActiveSaveRoot(active);
    // 用户显式改过目录，之前的启动回退警告作废。
    _downloadSaveRootIssue = null;
    _downloadSaveRootRejectedPath = null;
    notifyListeners();
  }

  /// 启动番剧下载完成监听。幂等（重复调用不重建）；失败由调用方记日志，不破坏 init。
  Future<void> startAnimeDownloadService() async {
    if (_animeDownloadService != null) return;
    final Directory baseDir =
        await AppPaths.documentsSubdirectory('anime_downloads');
    final AnimeDownloadPlanStore store =
        AnimeDownloadPlanStore(baseDir: baseDir);
    _animeDownloadPlanStore = store;

    // 内置引擎宿主：仅桌面（Android/iOS 阶段4/5 再定）。默认下载根就在计划目录旁的
    // `content/` 子目录（分类再往下分）；TODO-1961 起用户可在设置里改成任意目录。
    //
    // BUG-1053：这里**只记路径，不建 session**。真正的 libtorrent session 会绑
    // 6881 并起 DHT，对没有下载任务的用户是纯粹的网络噪声（整机延迟）。改由
    // [_ensureEmbeddedTorrentHost] 在第一次真要用后端时懒建；`_tickOnce` 本就
    // 「没有等待中的计划就不建连接」，所以空闲用户永远不会走到那一步。
    //
    // TODO-1961：配置目录不可写/建不出时**回退默认根并记下原因**（设置页显示警告），
    // 绝不静默把下载丢进一个写不进去的目录。默认根本身不预检——它是既有行为，
    // 首次 add 时 prepareCategory 会建，失败路径与改动前逐字节一致。
    final String defaultSaveRoot = path.join(baseDir.path, 'content');
    _downloadDefaultSaveRoot = defaultSaveRoot;
    String configuredRoot = prefsRepo.downloadSaveRoot.trim();
    if (configuredRoot.isNotEmpty) {
      final DownloadSaveRootIssue? issue =
          await checkDownloadSaveRoot(configuredRoot);
      if (issue != null) {
        _downloadSaveRootIssue = issue;
        _downloadSaveRootRejectedPath = configuredRoot;
        configuredRoot = '';
      }
    }
    _embeddedTorrentSaveRoots = resolveTorrentSaveRoots(
      defaultRoot: defaultSaveRoot,
      configuredRoot: configuredRoot,
      history: decodeSaveRootHistory(prefsRepo.downloadSaveRootHistory),
    );
    _embeddedTorrentResumeDir = path.join(baseDir.path, 'resume');

    // 🔴 顺序不可调换：下面两个 service 的 `..start()` 会**立刻** tick →
    // `_torrentBackendFor` → `_ensureEmbeddedTorrentHost()` → `open()` →
    // `restoreFromResume(restoreIds)` → 剪枝。计划 id 还没加载时那次剪枝的
    // keepIds 会是「空集合」，于是把用户**所有** `.resume` 删光 —— 目标功能
    // （重启后续传/继续做种）被反向实现成一次静默的数据销毁。
    // 兜底见 [pruneResumeFiles] 的 null 哨兵：真被后来的重构调乱顺序，剪枝会
    // 拒绝执行而不是删光；但正确顺序才是第一道防线，别指望兜底。
    await _refreshAnimeDownloadPlanIds(store);

    _animeDownloadService = AnimeDownloadService(
      store: store,
      configProvider: () =>
          effectiveTorrentConfig(prefsRepo.qbConnectionConfig),
      importer: buildAnimeDownloadImporter(database),
      bookImporter: _importDownloadedBooks,
      // BUG-1206：字幕在下载完成时按包内真实文件名反查补取，不在选种时预下。
      subtitleResolver: JimakuPlanSubtitleResolver(
        apiKeyProvider: () => prefsRepo.jimakuApiKey,
        httpClientFactory: createDownloadHttpClient,
        stagingDirFor: store.subsDirFor,
      ).resolve,
      backendFactory: _torrentBackendFor,
      onTick: () {
        _embeddedTorrentHost?.sweepAntiLeech();
        _embeddedTorrentHost?.sweepUploadPolicy();
        unawaited(_saveEmbeddedTorrentResume());
      },
    )..start();
    final AnimeDownloadSubscriptionStore subscriptionStore =
        AnimeDownloadSubscriptionStore(baseDir: baseDir);
    _animeDownloadSubscriptionStore = subscriptionStore;
    _animeDownloadSubscriptionService = AnimeDownloadSubscriptionService(
      store: subscriptionStore,
      planStore: store,
      configProvider: () =>
          effectiveTorrentConfig(prefsRepo.qbConnectionConfig),
      backendFactory: _torrentBackendFor,
      jimakuApiKeyProvider: () => prefsRepo.jimakuApiKey,
      httpClientFactory: createDownloadHttpClient,
    )..start();

    // TODO-1961-a：上次会话留下的种子在这里接回来（续传 + 继续做种）。
    //
    // BUG-1053 的边界必须守住：**只有真的有种子要恢复时才建 session**。
    // 判据是「resume 目录里有属于现存计划的 .resume 文件」——从没下载过东西的
    // 用户永远没有这种文件，于是永远不建 session、不绑端口、不起 DHT，与
    // BUG-1053 修复后的行为逐字节一致。
    await _restoreEmbeddedTorrentSession(store);
  }

  /// TODO-1961-c+d：下载内容改名 / 移动（引擎侧动，做种不断；库路径同步迁移）。
  ///
  /// 后端工厂复用 [_torrentBackendFor]，所以内置引擎与外接 qb 两条路都走得通；
  /// 库迁移走 [VideoBookRepository.migrateMediaPaths]。两步的原子性由
  /// [DownloadRelocateService] 保证（引擎失败则库不动）。
  DownloadRelocateService get downloadRelocateService =>
      DownloadRelocateService(
        backendFactory: () => _torrentBackendFor(
            effectiveTorrentConfig(prefsRepo.qbConnectionConfig)),
        migrateLibraryPaths: ({
          required String fromPath,
          required String toPath,
        }) =>
            VideoBookRepository(database)
                .migrateMediaPaths(fromPath: fromPath, toPath: toPath),
      );

  /// 刷新 [_animeDownloadPlanIds]（resume 剪枝的真相源）并返回它。
  /// 返回值非空：调用过一次之后哨兵就不再是 null。
  Future<Set<String>> _refreshAnimeDownloadPlanIds(
      AnimeDownloadPlanStore store) async {
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    final Set<String> ids = <String>{
      for (final AnimeDownloadPlan plan in plans) plan.id.toLowerCase(),
    };
    _animeDownloadPlanIds = ids;
    return ids;
  }

  /// TODO-1961-a：启动时按需恢复上次的内置引擎会话。
  /// 没有可恢复的种子就**不建 session**（见 BUG-1053）。
  Future<void> _restoreEmbeddedTorrentSession(
      AnimeDownloadPlanStore store) async {
    final String? resumeDir = _embeddedTorrentResumeDir;
    if (resumeDir == null || !_supportsEmbeddedTorrent()) return;
    final Set<String> planIds = await _refreshAnimeDownloadPlanIds(store);
    if (planIds.isEmpty) return;
    bool hasRestorable = false;
    try {
      final Directory dir = Directory(resumeDir);
      if (!await dir.exists()) return;
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.resume')) continue;
        final String id =
            path.basenameWithoutExtension(entity.path).toLowerCase();
        if (planIds.contains(id)) {
          hasRestorable = true;
          break;
        }
      }
    } on FileSystemException {
      return;
    }
    if (!hasRestorable) return;
    final EmbeddedTorrentHost? host = _ensureEmbeddedTorrentHost();
    // host 已经被别处（下载服务 tick）先建出来时，那次 open 可能因为计划 id
    // 还没加载而跳过了恢复（[EmbeddedTorrentHost.hasRestored] = false）。
    // 真相源到位了就在这里补做一次，别让「本次启动不续传」变成常态。
    if (host != null && !host.hasRestored) host.restoreFromResume(planIds);
  }

  /// TODO-1961-a：周期性把 resume data 落盘（host 内部按
  /// [EmbeddedTorrentHost.resumeSaveInterval] 节流，这里每 tick 调是安全的）。
  Future<void> _saveEmbeddedTorrentResume() async {
    final EmbeddedTorrentHost? host = _embeddedTorrentHost;
    final AnimeDownloadPlanStore? store = _animeDownloadPlanStore;
    if (host == null || store == null) return;
    try {
      host.saveResumeSnapshot(await _refreshAnimeDownloadPlanIds(store));
    } catch (e) {
      // 保存失败不打断下载轮询（下轮再试），但必须留痕：resume 长期写不进去
      // 等于「重启后所有下载蒸发」，静默吞掉用户和开发者都看不见。
      debugPrint('[torrent] resume snapshot tick failed: $e');
    }
  }

  /// 下载完成的书籍（epub）入库回调：逐个走 [EpubImporter] 进阅读库
  /// （DuplicatePolicy.skip()，重复导入不报错），返回成功入库的书本数。单本失败跳过。
  Future<int?> _importDownloadedBooks(
      AnimeDownloadPlan plan, List<String> bookAbsolutePaths) async {
    int imported = 0;
    for (final String filePath in bookAbsolutePaths) {
      try {
        await EpubImporter.importFromPath(
          db: database,
          filePath: filePath,
          fileName: path.basename(filePath),
          policy: const DuplicatePolicy.skip(),
        );
        imported++;
      } catch (_) {
        // 单本导入失败跳过，不影响其它书与计划状态（有成功即算入库）。
      }
    }
    return imported;
  }

  /// 内置引擎在本机是否可用（桌面 + DLL 能加载）。下载对话框据此判断能否走
  /// 内置引擎（不必配置外接 qb）。
  ///
  /// BUG-1053：这是**能力探测**，不代表已经开了 session。以前它等价于
  /// `_embeddedTorrentHost != null`，逼得启动就必须建 session（= 绑 6881 + 起
  /// DHT）才能让下载按钮可用。现在探测只加载 DLL、不碰网络，真会话由
  /// [_ensureEmbeddedTorrentHost] 在要下载时才建。
  bool get isEmbeddedTorrentReady =>
      _embeddedTorrentHost != null ||
      (_supportsEmbeddedTorrent() &&
          _embeddedTorrentSaveRoots != null &&
          EmbeddedTorrentHost.probeAvailable());

  /// 按配置解析出应使用的下载后端（供下载对话框的推送按钮与轮询服务共用
  /// 同一选择逻辑）。调用方用完须 `close()`（内置引擎的视图 close 是 no-op，
  /// 不连累常驻 session）。
  TorrentBackend createTorrentBackend(QbConnectionConfig config) =>
      _torrentBackendFor(config);

  /// 后端选择：配置选内置且宿主可用 → 内置引擎的共享 session 视图；否则
  /// 外接 qBittorrent（默认 / 内置不可用时的回退）。
  TorrentBackend _torrentBackendFor(QbConnectionConfig config) {
    final String backend =
        config.resolveBackend(isDesktop: _supportsEmbeddedTorrent());
    // BUG-1053：到这里才是「真的要用下载后端」，session 在此懒建（幂等）。
    final EmbeddedTorrentHost? host =
        backend == QbConnectionConfig.backendEmbedded
            ? _ensureEmbeddedTorrentHost()
            : _embeddedTorrentHost;
    if (backend == QbConnectionConfig.backendEmbedded && host != null) {
      return host.backendView();
    }
    return QbTorrentBackend(QBittorrentClient(
      baseUrl: config.baseUrl,
      username: config.username,
      password: config.password,
    ));
  }

  /// 内置 libtorrent 支持的平台：桌面（Windows 先行；mac/Linux 阶段4）。
  bool _supportsEmbeddedTorrent() =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 每系列记住的 Jimaku 字幕语言偏好（TODO-674）。
  Map<String, String> get jimakuPreferredLanguages =>
      prefsRepo.jimakuPreferredLanguages;

  Future<void> setJimakuPreferredLanguage(String seriesKey, String langCode) =>
      prefsRepo.setJimakuPreferredLanguage(seriesKey, langCode);

  /// 远端/流媒体视频用户手选的字幕来源持久化（退出重进恢复；根因见
  /// [PreferencesRepository.remoteSubtitleSources]）。
  String? remoteSubtitleSource(String bookUid, {int episodeIndex = 0}) =>
      prefsRepo.remoteSubtitleSource(bookUid, episodeIndex: episodeIndex);

  Future<void> setRemoteSubtitleSource(
    String bookUid,
    int episodeIndex,
    String? source,
  ) =>
      prefsRepo.setRemoteSubtitleSource(bookUid, episodeIndex, source);

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
        context: ctx,
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

  // ── dictionary auto-update (TODO-861③, ported from Hoshi 94d0c41) ────

  bool get autoUpdateDictionaries => prefsRepo.autoUpdateDictionaries;
  Future<void> setAutoUpdateDictionaries(bool value) =>
      prefsRepo.setAutoUpdateDictionaries(value);

  DictionaryUpdateInterval get dictionaryUpdateInterval =>
      DictionaryUpdateInterval.fromName(prefsRepo.dictionaryUpdateIntervalName);
  Future<void> setDictionaryUpdateInterval(DictionaryUpdateInterval interval) =>
      prefsRepo.setDictionaryUpdateIntervalName(interval.name);

  DateTime? get lastDictionaryUpdateAt => prefsRepo.lastDictionaryUpdateAt;

  /// 自动更新是否正在进行的再入守卫（与导入并发由 import manager 内部串行，但此处
  /// 防止启动 hook 与潜在重复触发叠加）。
  bool _autoUpdateInProgress = false;

  /// TODO-861③：启动时 check-due 自动更新词典（前台、静默、不弹错）。先用纯函数
  /// [shouldAutoUpdateDictionaries] 守门（未开 / 未到期 / 无可更新 / 正忙 → 直接
  /// 返回），再逐本拉远端 index 比 revision、有新版才下载 force 重导。**失败不中断
  /// 整批**（逐本 try/catch 收集失败）；整批检查完成（无新版也算完成）才写
  /// `lastDictionaryUpdateAt`，任一本检查/重导失败则不推进时间，留待下次启动重试。
  /// 复用手动更新同款「下载→force 重导（保留 order/hidden/collapsed）」链路。
  Future<void> maybeAutoUpdateDictionaries() async {
    if (!autoUpdateDictionaries) return;
    final List<Dictionary> updatable =
        dictionaries.where((Dictionary d) => d.isUpdatable).toList();
    if (!shouldAutoUpdateDictionaries(
      now: DateTime.now(),
      lastUpdate: lastDictionaryUpdateAt,
      interval: dictionaryUpdateInterval,
      hasUpdatable: updatable.isNotEmpty,
      isBusy: _autoUpdateInProgress,
    )) {
      return;
    }
    _autoUpdateInProgress = true;
    int completedCount = 0;
    try {
      for (final Dictionary dictionary in updatable) {
        try {
          final DictionaryRemoteIndexResult remote =
              await DictionaryUpdateService.fetchRemoteIndexResult(
            dictionary.indexUrl,
          );
          if (!remote.succeeded) {
            debugPrint('[Fushi] auto dict update could not check '
                '${dictionary.name}');
            continue;
          }
          if (!DictionaryUpdateService.needsUpdate(
              dictionary.revision, remote.revision)) {
            completedCount++;
            continue;
          }
          await _autoRedownloadAndReimport(dictionary);
          completedCount++;
        } catch (e, stack) {
          // 单本失败不中断其余（移植 Hoshi 的 failures-collect 语义）。
          ErrorLogService.instance
              .log('AppModel.autoUpdateDictionary', e, stack);
          debugPrint('[Fushi] auto dict update failed for '
              '${dictionary.name}: $e');
        }
      }
      // BUG-1281：检查成功且无需更新也是完整成功；旧逻辑只在真正重导过词典时写
      // 时间，导致长期没有新版的用户永远显示“从未”并在每次启动重复联网。
      if (didCompleteDictionaryAutoUpdateBatch(
        totalCount: updatable.length,
        completedCount: completedCount,
      )) {
        await prefsRepo.setLastDictionaryUpdateAt(DateTime.now());
      }
    } finally {
      _autoUpdateInProgress = false;
    }
  }

  /// 静默下载 + force 重导单本词典（复用手动链路语义：保留 order/hidden/collapsed，
  /// 回填 isUpdatable/URL 来源）。无 UI ValueNotifier，用一次性内部 notifier。
  Future<void> _autoRedownloadAndReimport(Dictionary dictionary) async {
    final Directory tempDir = Directory(
      path.join(dictionaryResourceDirectory.path, 'auto_update_temp'),
    );
    final ValueNotifier<String> progressNotifier = ValueNotifier<String>('');
    final ValueNotifier<double> downloadProgress = ValueNotifier<double>(0);
    try {
      final File zipFile = await DictionaryDownloader.download(
        url: dictionary.downloadUrl,
        tempDir: tempDir,
        progressNotifier: downloadProgress,
      );
      await importDictionary(
        file: zipFile,
        progressNotifier: progressNotifier,
        onImportSuccess: () {},
        forceReplaceExisting: true,
        sourceOverride: <String, String>{
          'isUpdatable': 'true',
          'downloadUrl': dictionary.downloadUrl,
          'indexUrl': dictionary.indexUrl,
        },
      );
    } finally {
      progressNotifier.dispose();
      downloadProgress.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  void toggleDictionaryCollapsed(Dictionary dictionary) =>
      dictRepo.toggleDictionaryCollapsed(
          dictionary, JapaneseLanguage.instance.languageCode);

  void toggleDictionaryHidden(Dictionary dictionary) {
    dictRepo.toggleDictionaryHidden(
        dictionary, JapaneseLanguage.instance.languageCode);
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
      FushiToast.show(
        msg: t.dictionaries_delete_failed,
        severity: ToastSeverity.error,
      );
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
      FushiToast.show(
        msg: t.dictionary_delete_failed,
        severity: ToastSeverity.error,
      );
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
        if (backend is InterconnectSyncBackend) {
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
  List<FushiKanjiResult> queryKanjiForTerm(String searchTerm) {
    if (!isSingleKanji(searchTerm)) return const <FushiKanjiResult>[];
    if (!FushiDicts.isInitialized) return const <FushiKanjiResult>[];
    return FushiDicts.instance.queryKanji(searchTerm);
  }

  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    searchTerm = normalizeSearchTerm(
      searchTerm,
      emojiRegex: _emojiRegex,
      punctuationRegex: _punctuationRegex,
      loneSurrogateRegex: _loneSurrogateRegex,
    );

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

    // maxTerms 与 maxResults 现在恒等（引擎上限已对齐词头预算，见下方 lookup 调用
    // 处），键格式保持不变以免旧键格式守卫漂移。
    final String cacheKey = buildSearchCacheKey(
      term: searchTerm,
      maxTerms: effectiveMaxTerms,
      maxResults: effectiveMaxTerms,
    );
    final String ffiCacheKey = buildFfiLookupCacheKey(
      term: searchTerm,
      maxResults: effectiveMaxTerms,
    );

    final cached = dictRepo.getCachedSearch(cacheKey);
    if (useCache && cached != null) {
      return cached;
    }

    if (!FushiDicts.isInitialized) {
      return DictionarySearchResult(searchTerm: searchTerm);
    }

    // Kanji dictionary lookup is orthogonal to the term index: a single kanji
    // can be both a term headword and a kanji entry, so we query the kanji
    // bucket independently and attach the results to whatever term result comes
    // back (or surface a kanji-only result when no term matches). Computed once
    // here so all local FFI return paths below carry the same kanji payload.
    final List<FushiKanjiResult> kanjiResults = queryKanjiForTerm(searchTerm);

    List<FushiLookupResult>? ffiResults =
        dictRepo.getCachedFfiLookup(ffiCacheKey);
    DictionarySearchResult? result;

    if (ffiResults != null) {
      result = buildResultFromLookup(
        searchTerm: searchTerm,
        results: ffiResults,
        maximumTerms: effectiveMaxTerms,
      );
      // 性能：popupJson 从已拿到的 ffiResults 在 Dart 侧生成（buildPopupJsonFromLookup
      // 与 C++ build_popup_json 逐字段对齐，parity 测试见 dictionary_popup_webview_test）。
      // 此前这里调 lookupPopupJson 让 C++ 把同一个词的完整查询管线（scan×文本变体×
      // 去屈折×hash 查询×排序×zstd 解压）从零再跑一遍——FFI 缓存命中/load-more 每页
      // 也照跑。同源生成还消除了「entries 来自缓存、popupJson 来自新查询」的双源分叉。
      result.popupJson = buildPopupJsonFromLookup(
        results: ffiResults,
        maximumTerms: effectiveMaxTerms,
      );
      result = result.withKanjiResults(kanjiResults);
    } else {
      // 🔴 引擎上限 == 本次真正要消费的词头预算。
      // `lookup.cpp` 在 `partial_sort` + `resize(max_results)` **之后**才对存活的
      // 每条结果做 `materialize()`（逐 glossary zstd 解压，每条落在 blobs.bin 的
      // 一个随机偏移上）。此前这里传硬编码 200，而下面的 buildResultFromLookup /
      // buildPopupJsonFromLookup 只取 effectiveMaxTerms（默认 10）条 —— 相当于在
      // 整条链路最贵的按需分页段上白解压 20 倍。
      //
      // 输出逐字不变，三条理由（改这里前必须逐条复核）：
      // 1. `partial_sort` 的比较器没动，top-N 的集合与顺序不变；
      // 2. `query.cpp` 的 `query_raw` 里 `glossaries.push_back` 无条件执行，故
      //    每个返回的 term 至少带一条 glossary —— N 个结果必然凑够 N 条，
      //    buildResultFromLookup 的 maximumTerms 预算先于结果数耗尽；
      // 3. `bestLength` 取 `matched` 的最大 UTF-16 长度，而所有 `matched` 都是
      //    同一个查询串的前缀（`scan_candidates` 只产出前缀），故「码点最长」与
      //    「UTF-16 最长」是同一个元素，它必在 `partial_sort` 后排首位、
      //    永远落在 top-N 内。
      ffiResults = FushiDicts.instance.lookup(
        searchTerm,
        maxResults: effectiveMaxTerms,
      );
      if (ffiResults.isNotEmpty) {
        dictRepo.cacheFfiLookup(ffiCacheKey, ffiResults);
        result = buildResultFromLookup(
          searchTerm: searchTerm,
          results: ffiResults,
          maximumTerms: effectiveMaxTerms,
        );
        // 同上：popupJson 由本次 lookup 的 ffiResults 直接生成，砍掉第二次
        // 完整 C++ 查询（原生查词成本 ×2 → ×1）。
        result.popupJson = buildPopupJsonFromLookup(
          results: ffiResults,
          maximumTerms: effectiveMaxTerms,
        );
        result = result.withKanjiResults(kanjiResults);
      }
    }

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

  /// 远端词典「全部配对候选不可达」后的冷却截止时刻（BUG-1302）；null = 不在冷却中。
  /// 只被 [_searchRemoteDictionary] 读写，单 isolate 内无并发写。
  DateTime? _remoteDictionaryUnreachableUntil;

  /// 测试可见：当前是否处于远端词典失败冷却窗内。
  @visibleForTesting
  bool get isRemoteDictionaryInFailureCooldown {
    final DateTime? until = _remoteDictionaryUnreachableUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<DictionarySearchResult?> _searchRemoteDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    required int maximumTerms,
  }) async {
    if (!remoteLookupEnabled) return null;
    // 配对设备被证实不可达后的冷却窗内直接短路（BUG-1302）。远端查词排在本地
    // 缓存**之前**，不短路的话设备离线/换网/休眠时每次查词都要重付一遍
    // 「3s × 候选数」的传输层超时——这是「某些机器上查词 4-5 秒」的主因。
    final DateTime? until = _remoteDictionaryUnreachableUntil;
    if (until != null) {
      if (DateTime.now().isBefore(until)) return null;
      _remoteDictionaryUnreachableUntil = null;
    }
    try {
      // await 必须收进 try：原实现直接 return 未 await 的 Future，catch 只能抓
      // 同步 throw，异步错误全部漏出成 uncaught（音频路径 lookupRemoteAudio 已
      // 修过同一处写法，词典路径此前遗留）。
      final DictionarySearchResult? result = await FushiRemoteLookupClient(
        repo: SyncRepository(_database),
        httpClient: _remoteLookupClient,
      ).searchDictionary(
        term: searchTerm,
        wildcards: searchWithWildcards,
        maximumTerms: maximumTerms,
      );
      // 拿到任何 HTTP 响应即证明设备活着（含「可达但无结果」的 null），清冷却。
      _remoteDictionaryUnreachableUntil = null;
      return result;
    } on RemoteLookupUnreachableError catch (e, stack) {
      _remoteDictionaryUnreachableUntil =
          DateTime.now().add(kRemoteDictionaryFailureCooldown);
      ErrorLogService.instance.log('remoteDictionaryLookup', e, stack);
      return null;
    } catch (e, stack) {
      ErrorLogService.instance.log('remoteDictionaryLookup', e, stack);
      return null;
    }
  }

  /// Requests for full external storage permissions. Required to handle video
  /// files and their subtitle files in the same directory.
  ///
  /// **只申请存储权限，不碰相机**（BUG-1209）。本函数的全部调用点都是「选扫描根 /
  /// 选文件 / 改下载目录」（`media/import/real_path_directory_picker.dart`），它们只需要
  /// 读盘。此前这里顺带 `requestCameraPermission()`：用户理解不了选个文件夹为什么要给
  /// 相机，合理反应是拒绝，而在同一串权限流程里拒绝很可能把本该给的存储权限一起否掉
  /// ——于是「加了扫描根却扫不出东西」。
  ///
  /// 相机是另一件事，归真正需要相机的入口自己申请：当前唯一的相机消费方
  /// `creator/enhancements/camera_enhancement.dart` 走 image_picker 的 `ImageSource.camera`
  /// 系统拍照 intent，而 `AndroidManifest.xml` 并未声明 `android.permission.CAMERA`，
  /// 该 intent 本就不需要运行时权限，故它从来没有、也不需要调这里。
  ///
  /// 早退门同样只看存储：旧版的 `&& hasCameraPermission()` 在安卓上恒为 false
  /// （CAMERA 未在 manifest 声明 → permission_handler 直接判 denied），使得存储已授权时
  /// 也永远走不进早退分支。
  Future<void> requestExternalStoragePermissions() async {
    if (await platformServices.permission.hasExternalStoragePermission()) {
      return;
    }
    if (isFirstTimeSetup) {
      FushiToast.show(
        msg: t.storage_permissions,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        severity: ToastSeverity.info,
      );
    }

    await platformServices.permission.requestExternalStoragePermission();
  }

  // ── Anki integration (delegated to AnkiIntegration) ─────────────────

  static const MethodChannel methodChannel = FushiChannels.anki;

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
    // 已迁移只读态（Fushi 迁移 P1-4b）：单闸门挡掉全部媒体打开路径——进度/
    // 统计/制卡的所有写点都在媒体页内，媒体不开则写路径整体不可达（好过在
    // 每个写点各加一个特例分支）。老版此时只保留「重新导出」通道。
    if (isMigrationReadonly) {
      FushiToast.show(msg: t.migration_readonly_note);
      return;
    }
    if (killOnPop) {
      _shouldKillMediaOnPop = true;
    }

    mediaSource.clearCurrentSentence();
    mediaSource.clearExtraData();
    // TODO-perf（开媒体反馈）：audio_service 冷启是平台通道重活（冷路径可达数百
    // ms），此前串行挡在 Navigator.push 之前——点下卡片后到路由动画开始前屏幕零
    // 反馈的那段就在这里。改为起跑不阻塞导航：AudioController.initialiseHandler
    // 记忆化在飞 future（并发安全），真正需要 handler 的消费端（reader 的
    // _resolveAudioSlot、书架后台听书 startBackgroundListening）await 同一份，
    // 「会话挂通知前 handler 必就绪」的时序契约不变。方法自带兜底构造、永不抛，
    // unawaited 安全。
    unawaited(initialiseAudioHandler());

    _currentMediaSource = mediaSource;
    if (item != null) {
      _currentMediaItem = item;
    }
    // TODO-1375：把「媒体已打开」推给可靠通知源，让 macOS 根 sidebar 隐藏（阅读全宽）。
    mediaOpenNotifier.value = true;

    _overrideDictionaryColor = null;
    _overrideDictionaryTheme = null;

    if (ReaderHibikiSource.instance.keepScreenAwake) {
      try {
        await WakelockPlus.enable();
      } catch (e) {
        debugPrint('[Fushi] wakelock enable failed: $e');
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
          context: ctx,
          builder: (context) => mediaSource.buildLaunchPage(
              item: item, initialBookmarkJump: initialBookmarkJump),
        ),
      );
    } else {
      await Navigator.push(
        ctx,
        adaptivePageRoute(
          context: ctx,
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
    // TODO-1375：把「媒体已关闭」推给可靠通知源，保证退出阅读器后 macOS 根 sidebar
    // 必然重建恢复（不再依赖碰巧有别的 notifyListeners 触发 builder 重跑）。
    mediaOpenNotifier.value = false;
    _overrideDictionaryColor = null;
    _overrideDictionaryTheme = null;
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Fushi] wakelock disable failed: $e');
    }
    // Returning to the home/menu shell: hide the Android status bar again
    // (TODO-097) instead of plain edge-to-edge. iOS/desktop unchanged.
    await setHomeShellSystemUiMode();
    // TODO-1275 / BUG-361: returning to the home shell — restore desktop_drop's
    // Windows OS drop registration in case an opened reader/video/lookup
    // WebView2 usurped it, so drag-import works again after any media was
    // opened. No-op off Windows / when desktop_drop lacks the reinitialize patch.
    await DesktopDropReinitializer.reinitialize();
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
        builder: (dialogContext) => FushiDialogFrame(
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
      scheme: 'fushi',
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
    Function(FushiTextSelection)? onSelect,
    Function(FushiTextSelection)? onSearch,
  }) async {
    if (sourceText.trim().isEmpty) {
      return;
    }

    segmentedText ??= JapaneseLanguage.instance.textToWords(sourceText);
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
      FushiToast.show(
        msg: t.stash_added_single(term: terms.first),
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        severity: ToastSeverity.success,
      );
    } else {
      FushiToast.show(
        msg: t.stash_added_multiple,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        severity: ToastSeverity.success,
      );
    }
  }

  Future<void> removeFromStash({required String term}) async {
    await mediaHistoryRepo.removeFromStashData(term: term);
    FushiToast.show(
      msg: t.stash_clear_single(term: term),
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.success,
    );
  }

  void clearStash() => mediaHistoryRepo.clearStash();
  List<String> getStash() => mediaHistoryRepo.getStash();
  bool isTermInStash(String searchTerm) =>
      mediaHistoryRepo.isTermInStash(searchTerm);

  /// Shown when a query fails to be made to an online service. For example,
  /// when there is no internet connection.
  void showFailedToCommunicateMessage() {
    FushiToast.show(
      msg: t.failed_online_service,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.error,
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
      FushiToast.show(
        msg: t.copied_to_clipboard,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        severity: ToastSeverity.success,
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

  // ── player preferences (delegated to PreferencesRepository) ─────────

  bool get playerHardwareAcceleration => prefsRepo.playerHardwareAcceleration;
  void setPlayerHardwareAcceleration({required bool value}) =>
      prefsRepo.setPlayerHardwareAcceleration(value: value);

  // TODO-702：有声书退出即停（默认）/ 后台续播（可选）。转发偏好仓库。
  bool get audiobookBackgroundPlay => prefsRepo.audiobookBackgroundPlay;
  Future<void> setAudiobookBackgroundPlay({required bool value}) =>
      prefsRepo.setAudiobookBackgroundPlay(value: value);

  // ── player streams & audio handler (delegated to AudioController) ───

  Stream<void> get playStream => audioCtrl.playStream;
  Stream<Duration> get seekStream => audioCtrl.seekStream;
  Stream<void> get rewindStream => audioCtrl.rewindStream;
  Stream<void> get fastForwardStream => audioCtrl.fastForwardStream;
  Stream<void> get skipNextStream => audioCtrl.skipNextStream;
  Stream<void> get skipPreviousStream => audioCtrl.skipPreviousStream;
  Stream<void> get toggleFloatingLyricStream =>
      audioCtrl.toggleFloatingLyricStream;

  FushiAudioHandler? get audioHandler => audioCtrl.audioHandler;

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
      // TODO-708 P2: 圆角半径 / 窗宽（dp，0=平台原生默认观感）。
      cornerRadius: floatingLyricCornerRadius,
      windowWidth: floatingLyricWidth,
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
    final MediaItem? item =
        await ReaderHibikiSource.instance.mediaItemForBookKey(info.bookKey);
    if (item == null) return;
    // 源必须跟着 item 自己的 mediaSourceIdentifier 走（它已按当前 format 现算）：
    // 写死 ReaderHibikiSource 会让漫画 / PDF 书用 EPUB 阅读器打开。
    await openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: this),
      item: item,
    );
  }

  // ── search & dictionary display (delegated to PreferencesRepository) ─

  bool get autoSearchEnabled => prefsRepo.autoSearchEnabled;
  void toggleAutoSearchEnabled() => prefsRepo.toggleAutoSearchEnabled();

  // TODO-861②：是否扫描非日文文本（选区/查词）。默认 true，向后兼容。
  bool get scanNonJapaneseText => prefsRepo.scanNonJapaneseText;
  Future<void> setScanNonJapaneseText(bool value) =>
      prefsRepo.setScanNonJapaneseText(value);

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

  // 查词弹窗尺寸精细化（2026-07-13）：app 外覆盖窗 / 浏览器扩展的独立尺寸键。
  bool get overlayLookupIndependentSize =>
      prefsRepo.overlayLookupIndependentSize;
  Future<void> setOverlayLookupIndependentSize(bool value) =>
      prefsRepo.setOverlayLookupIndependentSize(value);
  double get overlayLookupMaxWidth => prefsRepo.overlayLookupMaxWidth;
  void setOverlayLookupMaxWidth(double width) =>
      prefsRepo.setOverlayLookupMaxWidth(width);
  double get overlayLookupMaxHeight => prefsRepo.overlayLookupMaxHeight;
  void setOverlayLookupMaxHeight(double height) =>
      prefsRepo.setOverlayLookupMaxHeight(height);

  bool get extensionPopupIndependentSize =>
      prefsRepo.extensionPopupIndependentSize;
  Future<void> setExtensionPopupIndependentSize(bool value) =>
      prefsRepo.setExtensionPopupIndependentSize(value);
  double get extensionPopupMaxWidth => prefsRepo.extensionPopupMaxWidth;
  void setExtensionPopupMaxWidth(double width) =>
      prefsRepo.setExtensionPopupMaxWidth(width);
  double get extensionPopupMaxHeight => prefsRepo.extensionPopupMaxHeight;
  void setExtensionPopupMaxHeight(double height) =>
      prefsRepo.setExtensionPopupMaxHeight(height);

  /// app 外覆盖查词卡的「有效最大宽高」（跟随 app 内 / 解锁后独立）。
  /// controller 的窗口尺寸测算读它，而不是直接读 [popupMaxWidth]/[popupMaxHeight]。
  LookupSize get overlayLookupEffectiveSize => effectiveLookupSize(
        independent: overlayLookupIndependentSize,
        sceneWidth: overlayLookupMaxWidth,
        sceneHeight: overlayLookupMaxHeight,
        sharedWidth: popupMaxWidth,
        sharedHeight: popupMaxHeight,
      );

  /// 浏览器扩展弹窗的「有效最大宽高」（跟随 app 内 / 解锁后独立）。
  /// [browserExtensionThemeColors] 下发的 `--hibiki-popup-max-*` 读它。
  LookupSize get extensionPopupEffectiveSize => effectiveLookupSize(
        independent: extensionPopupIndependentSize,
        sceneWidth: extensionPopupMaxWidth,
        sceneHeight: extensionPopupMaxHeight,
        sharedWidth: popupMaxWidth,
        sharedHeight: popupMaxHeight,
      );

  /// 弹窗尺寸精细化 Phase D：浏览器扩展弹窗被拖右下角把手调整尺寸后，content.js 经
  /// 扩展 ↔ app bridge（POST `/api/extension/popup-size`）回写最终基准最大宽高，由
  /// [YomitanApiServer] 的 `onExtensionPopupSize` sink 调到这里。先 clamp 到与设置页两滑杆
  /// 同一 250-2000/200-1600（[resolveExtensionPopupSize]，任何异常/越界客户端都写不穿），
  /// 再按「拖即解锁」好品味写真值：一动手定制扩展尺寸就脱钩「跟随 app 内」——置
  /// [setExtensionPopupIndependentSize]`(true)` + 写 extension 宽/高键。滑杆与拖拽写同一真
  /// 值，下次查词 [extensionPopupEffectiveSize] 以新值下发（预期行为）。**只写扩展键**，
  /// 绝不碰 overlay / popupMax（app 内 / app 外覆盖窗各自的真值，串台即破坏它们）。
  void _applyExtensionPopupSize(double maxWidth, double maxHeight) {
    final LookupSize size = resolveExtensionPopupSize(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    unawaited(setExtensionPopupIndependentSize(true));
    setExtensionPopupMaxWidth(size.width);
    setExtensionPopupMaxHeight(size.height);
  }

  bool get popupInstantScroll => prefsRepo.popupInstantScroll;
  Future<void> setPopupInstantScroll(bool value) =>
      prefsRepo.setPopupInstantScroll(value);

  // BUG-1026：查词弹窗滚轮速度倍率（默认 1.0，clamp 0.5–5.0）。
  double get popupWheelSpeed => prefsRepo.popupWheelSpeed;
  Future<void> setPopupWheelSpeed(double value) =>
      prefsRepo.setPopupWheelSpeed(value);

  bool get popupBottomDocked => prefsRepo.popupBottomDocked;
  Future<void> setPopupBottomDocked(bool value) =>
      prefsRepo.setPopupBottomDocked(value);

  bool get isFirstTimeSetup => prefsRepo.isFirstTimeSetup;
  void setFirstTimeSetupFlag() => prefsRepo.setFirstTimeSetupFlag();

  /// 是否已展示过「上传/做种」首用提示（下载对话框首次推送时弹一次性提醒）。
  bool get torrentUploadIntroShown => prefsRepo.torrentUploadIntroShown;
  Future<void> setTorrentUploadIntroShown() =>
      prefsRepo.setTorrentUploadIntroShown();

  int get maximumTerms => prefsRepo.maximumTerms;
  void setMaximumTerms(int value) => prefsRepo.setMaximumTerms(value);

  void addToDictionaryHistory({required DictionarySearchResult result}) {
    MediaType mediaType = mediaTypes.values.toList()[currentHomeTabIndex];
    if (mediaType != DictionaryMediaType.instance) {
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
  FushiDatabase get database => _database;

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
    FushiDicts.disposeInstance();
  }

  @override
  void dispose() {
    // BUG-913：对称释放 initialise() 起的 4 个 app-wide 常驻子系统。dispose 是同步的、
    // 这些 stop 多为 Future → fire-and-forget（unawaited）；先停常驻服务，再走现有
    // notifier/repo dispose，最后 super.dispose()。
    if (_isInitialised) {
      // syncServerController 是 late final 带初始化器（读即构造）：仅在已 init（即已被
      // startIfEnabled 构造）时读它，避免「从未 init 却只为销毁而构造」。它既是常驻
      // 服务又是 ChangeNotifier，故 stop() 后还需 dispose()。
      unawaited(syncServerController.stop());
      syncServerController.dispose();
    }
    // 其余三个 stop 都 null 安全 / 单例安全，未启动也可调，无需 _isInitialised 守卫。
    unawaited(TexthookerWsClientManager.instance.stop());
    unawaited(stopYomitanApiServer());
    _animeDownloadService?.stop();
    _animeDownloadSubscriptionService?.stop();
    _mokuroMoeDownloadQueue?.dispose();
    _mokuroMoeDownloadQueue = null;
    _mihonManager?.dispose();
    _mihonManager = null;
    _prefsRepo?.removeListener(notifyListeners);
    if (_themeListenerAdded) {
      themeNotifier.removeListener(notifyListeners);
      themeNotifier.dispose();
      _themeListenerAdded = false;
    }
    dictionaryEntriesNotifier.dispose();
    clipboardHistoryNotifier.dispose();
    dictionarySearchAgainNotifier.dispose();
    dictionaryMenuNotifier.dispose();
    incognitoNotifier.dispose();
    databaseCloseNotifier.dispose();
    homeDictionaryTabRequest.dispose();
    mediaOpenNotifier.dispose();
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
    _remoteLookupHttpClient?.close();
    _remoteLookupHttpClient = null;
    _animeDownloadService?.stop();
    // TODO-1961-a：退出前强制存一次 resume（下次启动据此续传/继续做种）。
    // 用最近一次 tick 缓存的计划 id 集合剪枝 —— dispose 是同步的，不能在这里
    // await 一次 `store.loadAll()`；缓存最多落后一个 tick（20s），代价只是某个
    // 刚删掉的计划多留一轮 resume 文件，下次启动的剪枝会立刻清掉它。
    _embeddedTorrentHost?.dispose(keepIds: _animeDownloadPlanIds);
    _embeddedTorrentHost = null;
    super.dispose();
  }

  Future<void> moveToBack() async {
    try {
      await platformServices.lifecycle.moveTaskToBack();
    } catch (e, stack) {
      ErrorLogService.instance.log('AppModel.moveToBack', e, stack);
      debugPrint('[Fushi] moveToBack failed: $e');
    }
  }

  // ── tags, card export, CSS (delegated) ──────────────────────────────

  String get savedTags => prefsRepo.savedTags;
  void setSavedTags(String value) => prefsRepo.setSavedTags(value);

  bool get autoAddBookNameToTags => prefsRepo.autoAddBookNameToTags;
  void toggleAutoAddBookNameToTags() => prefsRepo.toggleAutoAddBookNameToTags();

  // TODO-1650 制卡图片/GIF 清晰度档 + 音频质量档（透传 prefsRepo）。默认档 = 旧压缩档
  // （现状零破坏）。制卡消费点用 [MiningMediaCompression.resolve] 据这两个档组装媒体档。
  int get miningImageQuality => prefsRepo.miningImageQuality;
  void setMiningImageQuality(int tier) => prefsRepo.setMiningImageQuality(tier);
  int get miningAudioQuality => prefsRepo.miningAudioQuality;
  void setMiningAudioQuality(int tier) => prefsRepo.setMiningAudioQuality(tier);

  // 互联「制卡到服务端」开关（透传 prefsRepo）。默认 false=本地制卡。
  // 用可空读 `_prefsRepo?`：`ankiRepositoryProvider` 在构建期即 watch 本 getter 决定是否
  // 包 RemoteMiningAnkiRepository，而 ankiViewModel/Repository 会被极早期或最小 harness
  // （texthooker/game 健康卡 BUG-1007、bare AppModel widget 测）读取——此时 prefsRepo 尚未
  // 装配（`prefsRepo`=`_prefsRepo!` 会抛 Null check）。prefs 未加载即「开关不可能开过」，
  // 语义正确落 false=本地制卡（现状），既复原「读 anki repo 无需完整初始化」的不变量，
  // 又避免早读崩溃。
  bool get mineToServerEnabled => _prefsRepo?.mineToServer ?? false;
  Future<void> setMineToServer(bool value) => prefsRepo.setMineToServer(value);

  // 视频制卡封面图片模式（GIF / 制卡时当前帧 / 字幕开头帧，透传 prefsRepo）。默认 gif=现状。
  VideoMiningImageMode get videoMiningImageMode =>
      prefsRepo.videoMiningImageMode;
  void setVideoMiningImageMode(VideoMiningImageMode mode) =>
      prefsRepo.setVideoMiningImageMode(mode);

  VideoMiningImageMode get galMiningImageMode => prefsRepo.galMiningImageMode;
  void setGalMiningImageMode(VideoMiningImageMode mode) =>
      prefsRepo.setGalMiningImageMode(mode);

  // 动图编码格式（AVIF / WebP / GIF，透传 prefsRepo）。默认 avif。与上面的「封面模式」
  // 正交：模式选用不用动图，格式选动图怎么编码。
  MiningAnimatedFormat get videoMiningAnimatedFormat =>
      prefsRepo.videoMiningAnimatedFormat;
  void setVideoMiningAnimatedFormat(MiningAnimatedFormat format) =>
      prefsRepo.setVideoMiningAnimatedFormat(format);

  MiningAnimatedFormat get galMiningAnimatedFormat =>
      prefsRepo.galMiningAnimatedFormat;
  void setGalMiningAnimatedFormat(MiningAnimatedFormat format) =>
      prefsRepo.setGalMiningAnimatedFormat(format);

  bool get deduplicatePitchAccents => prefsRepo.deduplicatePitchAccents;
  void toggleDeduplicatePitchAccents() =>
      prefsRepo.toggleDeduplicatePitchAccents();

  bool get harmonicFrequency => prefsRepo.harmonicFrequency;
  void toggleHarmonicFrequency() => prefsRepo.toggleHarmonicFrequency();

  bool get showExpressionTags => prefsRepo.showExpressionTags;
  void toggleShowExpressionTags() => prefsRepo.toggleShowExpressionTags();

  bool get collapseDictionaries => prefsRepo.collapseDictionaries;
  void toggleCollapseDictionaries() => prefsRepo.toggleCollapseDictionaries();

  /// TODO-1357: 查词弹窗「列数 / 自动展开词典数」的平台三态默认解析（纯函数，供守卫）。
  /// - 用户显式设过（[hasExplicit]）→ 一律遵从其存储值 [stored]（尊重用户）。
  /// - 从未设过：桌面（pointer:fine，[isDesktop]）→ [desktopDefault]；
  ///   移动端窄屏 → [mobileDefault]（不硬塞多列 / 多词典，避免窄屏挤爆）。
  /// [desktopDefault] / [mobileDefault] 让列数与自动展开数各定各的平台默认（列数封顶更
  /// 宽松、由 popup.js 视口收敛兜底；自动展开数保守）。
  static int resolvePopupDesktopDefault({
    required bool hasExplicit,
    required int stored,
    required bool isDesktop,
    int desktopDefault = 2,
    int mobileDefault = 1,
  }) =>
      hasExplicit ? stored : (isDesktop ? desktopDefault : mobileDefault);

  /// TODO-1357: 查词弹窗默认「最多列数」（桌面 / 移动均未设 3 / 显式遵从）。列数是
  /// 「自动填充、封顶用户值」——真实生效列数由 popup.js 的视口收敛（每列 ≥170px）算出，
  /// 故默认统一放宽到 3（宽屏 / 宽屏手机铺满、窄屏自动收回，不再硬塞挤爆）。所有
  /// `--dict-columns` 注入点（app_model / dictionary_popup_webview /
  /// popup_settings_injection）都读本 getter，平台默认在此单点收口。
  int get popupDictionaryColumns => resolvePopupDesktopDefault(
        hasExplicit: prefsRepo.hasExplicitPopupDictionaryColumns,
        stored: prefsRepo.popupDictionaryColumns,
        isDesktop: isDesktopPlatform,
        desktopDefault: 3,
        mobileDefault: 3,
      );
  Future<void> setPopupDictionaryColumns(int columns) =>
      prefsRepo.setPopupDictionaryColumns(columns);

  /// 自动展开默认「第一行铺满即展开」（用户拍板 2026-07-14）：未显式设过时默认 1 **行**，
  /// popup.js 再乘当前有效列数（`autoExpandCount` = rows × cols），所以展开本数天然
  /// 跟随列数——列数 3 就是第一行那 3 本，列数改了默认也跟着改，正是拍板的语义。
  ///
  /// BUG-1271：本默认值原本返回 [popupDictionaryColumns]。拍板当时这个偏好的单位是
  /// 「本数」，返回列数 = 「第一行铺满」是对的；TODO-845 之后把单位改成了「行数」，
  /// 却没换算这个默认值，于是它变成 cols **行** × cols 列 = cols² 本 —— 出厂默认
  /// （列数 3）从意图的 3 本膨胀成 9 本，列数调到 4 就是 16 本。单位是行，「第一行
  /// 铺满」就只能写 1。
  ///
  /// 用户显式设过一律遵从其存储值（存量显式值仍按旧「本数」语义写入，会被当成行数
  /// 读，见 BUG-1271 备注；滑块可见可自调，故不做静默数据迁移）。
  int get popupAutoExpandDictionaries =>
      prefsRepo.hasExplicitPopupAutoExpandDictionaries
          ? prefsRepo.popupAutoExpandDictionaries
          : 1;
  Future<void> setPopupAutoExpandDictionaries(int count) =>
      prefsRepo.setPopupAutoExpandDictionaries(count);

  // TODO-1046: daily/weekly reading goals (characters). 0 = unset/off; the
  // statistics page hides the goal card. Delegated to prefsRepo.
  int get readingGoalDailyChars => prefsRepo.readingGoalDailyChars;
  Future<void> setReadingGoalDailyChars(int value) =>
      prefsRepo.setReadingGoalDailyChars(value);

  int get readingGoalWeeklyChars => prefsRepo.readingGoalWeeklyChars;
  Future<void> setReadingGoalWeeklyChars(int value) =>
      prefsRepo.setReadingGoalWeeklyChars(value);

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
  /// FushiFocusRoot/Ring，App 回退到 Flutter 原生焦点遍历。
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

  /// galgame 游戏库仓储（v55 起真相源是 Drift 表 `galgames`，不再是偏好 JSON）。
  ///
  /// 懒建：绑的是 [database]，只有真正用到游戏库的路径才会碰它，冷启动不多跑查询。
  /// 库页/详情页直接用这个仓储做增删改与会话查询。
  GalgameRepository get galgameRepo => _galgameRepo ??= GalgameRepository(
        database,
        // 游玩状态改动上报媒体记录（Bangumi 收藏 type）。fail-open：同步不可用时
        // 本地状态照常生效，事件留在 outbox 由后续同步重试。
        onPlayStatusChanged: (String id, GalgamePlayStatus status) {
          unawaited(
            mediaTrackingService.recordGameStatus(
              gameId: id,
              status: status.value,
            ),
          );
        },
      );
  GalgameRepository? _galgameRepo;

  /// 当前缓存的游戏库列表（同步读，供 widget 首帧渲染）。首次进页面为空表，
  /// 页面在 initState 里调 [reloadGalgames] 从 DB 拉真值。
  List<GalgameEntry> get galgames => galgameRepo.games;

  /// 整表覆写游戏库（保持旧签名：调用方组装整列表后写入；缺失的 id 视为删除）。
  Future<void> setGalgames(List<GalgameEntry> games) =>
      galgameRepo.setGames(games);

  /// 从 DB 重载游戏库缓存。
  Future<List<GalgameEntry>> reloadGalgames() => galgameRepo.load();

  /// 游戏库页的排序/筛选视图偏好（JSON 串，空 = 默认视图）。
  String get galgameLibraryView => prefsRepo.galgameLibraryView;
  Future<void> setGalgameLibraryView(String encoded) =>
      prefsRepo.setGalgameLibraryView(encoded);

  bool get desktopClipboardEnabled => prefsRepo.desktopClipboardEnabled;
  Future<void> setDesktopClipboardEnabled(bool v) async {
    await prefsRepo.setDesktopClipboardEnabled(v);
    await applyDesktopClipboardLifecycle();
  }

  /// 剪切板复制后是否自动查词（默认 true=现状）。false 时面板只显示文字、点词才查。
  /// 与总开关 [desktopClipboardEnabled] 正交，不影响监听生命周期，故无需重跑
  /// [applyDesktopClipboardLifecycle]。
  bool get desktopClipboardAutoLookup => prefsRepo.desktopClipboardAutoLookup;
  Future<void> setDesktopClipboardAutoLookup(bool v) =>
      prefsRepo.setDesktopClipboardAutoLookup(v);

  /// spec 2026-07-10 §7 生命周期上移：剪贴板监听归 AppModel 持有（开=start /
  /// 关=stop），HomeDictionaryPage 退化为 destination==main 分区的消费者。此前
  /// start/stop 绑词典 tab 挂载周期——那是「去向只有主窗 tab」时代的产物；
  /// 面板/瞬态去向要求 app 级监听（tab 未挂载时 pending 排队语义 TODO-376 已有）。
  /// 启动期由 main.dart 桌面块调用一次；设置开关切换时经
  /// [setDesktopClipboardEnabled] 幂等重入（service.start 对已运行是 no-op）。
  Future<void> applyDesktopClipboardLifecycle() async {
    if (!DesktopLookupService.isDesktop) return;
    // 剪贴板复制历史采集：真实剪贴板变化（origin=clipboard、去重通过）落历史。
    DesktopLookupService.instance.onClipboardCaptured =
        addClipboardHistoryEntry;
    if (desktopClipboardEnabled) {
      await DesktopLookupService.instance.start(
        windowMode: desktopClipboardWindowMode,
      );
    } else {
      await DesktopLookupService.instance.stop();
    }
  }

  // TODO-1030 M0 — 全局查词是否抓取选中文本上下文（隐私敏感，默认关）。
  bool get globalContextCaptureEnabled => prefsRepo.globalContextCaptureEnabled;
  Future<void> setGlobalContextCaptureEnabled(bool v) =>
      prefsRepo.setGlobalContextCaptureEnabled(v);
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

  // spec 2026-07-10 剪贴板独立弹窗 — 剪贴板查词去向 + 面板窗四项偏好（转发）。
  DesktopClipboardDestination get desktopClipboardDestination =>
      prefsRepo.desktopClipboardDestination;
  Future<void> setDesktopClipboardDestination(DesktopClipboardDestination v) =>
      prefsRepo.setDesktopClipboardDestination(v);
  double get clipboardPanelOpacity => prefsRepo.clipboardPanelOpacity;
  Future<void> setClipboardPanelOpacity(double v) =>
      prefsRepo.setClipboardPanelOpacity(v);
  // 真透明剪切板文字窗背景不透明度（0.0 = 全透只露文字）。
  double get clipboardTextWindowBgOpacity =>
      prefsRepo.clipboardTextWindowBgOpacity;
  Future<void> setClipboardTextWindowBgOpacity(double v) =>
      prefsRepo.setClipboardTextWindowBgOpacity(v);

  /// 真透明剪切板文字窗的文字颜色 = 当前主题 onSurface（跟随明暗/配色方案）。背景
  /// 仍由 [clipboardTextWindowBgOpacity] 滑杆控制、文字恒实心（满 alpha）。明暗解析
  /// 与悬浮字幕 app 级样式同款（ThemeMode.system 按浅色，保持两处一致）。
  int clipboardTextWindowTextColor() {
    final Brightness brightness =
        themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light;
    return buildColorScheme(brightness).onSurface.value;
  }

  String get clipboardPanelRect => prefsRepo.clipboardPanelRect;
  Future<void> setClipboardPanelRect(String v) =>
      prefsRepo.setClipboardPanelRect(v);
  bool get clipboardPanelPinned => prefsRepo.clipboardPanelPinned;
  Future<void> setClipboardPanelPinned(bool v) =>
      prefsRepo.setClipboardPanelPinned(v);
  bool get clipboardPanelBlockCapture => prefsRepo.clipboardPanelBlockCapture;
  Future<void> setClipboardPanelBlockCapture(bool v) =>
      prefsRepo.setClipboardPanelBlockCapture(v);

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

  /// Anki 本地音频服务器（5050）内置预设 URL 的镜像，供 UI（重置默认）引用。
  static const String ankiLocalAudioUrl =
      PreferencesRepository.ankiLocalAudioUrl;

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
    DeleteScope scope = DeleteScope.keepLocalOnly,
  }) async {
    await prefsRepo.setAudioSourceConfigs(sources);
    final Map<String, LocalAudioDbEntry> current = <String, LocalAudioDbEntry>{
      for (final LocalAudioDbEntry db in localAudioDbs) db.path: db,
    };
    // 删除传播：本地音频源按 displayName 跨设备同步（__local_audio__ / _syncLocalAudioLive）。
    // 检测本次保存移除/新增的本地音频源，按 scope 写/清删除墓碑（itemKey=displayName）。
    final Set<String> nextLocalPaths = <String>{
      for (final AudioSourceConfig s in sources)
        if (s.kind == AudioSourceKind.localAudio &&
            (s.path?.isNotEmpty ?? false))
          s.path!,
    };
    for (final MapEntry<String, LocalAudioDbEntry> e in current.entries) {
      if (!nextLocalPaths.contains(e.key)) {
        // 被移除的本地音频源：syncEverywhere 才记墓碑传播。
        if (scope == DeleteScope.syncEverywhere) {
          try {
            await database.writeSyncDeletionTombstone(
                SyncTombstoneKind.localaudio.dbValue,
                e.value.displayName,
                DateTime.now().millisecondsSinceEpoch);
          } catch (_) {
            // best-effort。
          }
        }
      }
    }
    // 新增/仍在的源清墓碑（防「删了又加、墓碑还在」）。
    for (final AudioSourceConfig s in sources) {
      if (s.kind == AudioSourceKind.localAudio) {
        try {
          await database.clearSyncDeletionTombstone(
              SyncTombstoneKind.localaudio.dbValue, s.displayLabel);
        } catch (_) {
          // best-effort。
        }
      }
    }
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

  // 远端查词/查音频共用一个 http.Client，复用 keep-alive TLS 连接（TODO-744：
  // 避免每次查词都新建 client + 重做 DNS/TCP/TLS 握手）。SyncRepository 每次
  // 现读 URL/token，所以服务器配置变更无需失效此 client；进程退出在 dispose 关。
  http.Client? _remoteLookupHttpClient;
  http.Client get _remoteLookupClient =>
      _remoteLookupHttpClient ??= http.Client();

  Future<String?> lookupRemoteAudio(
    String expression,
    String reading,
  ) async {
    // 远端音频是否查询由「管理音频来源」对话框里的 hibikiRemote 源 enabled 决定
    // （resolveConfigured 只在该源 enabled 时才调用这里）；与词典远端开关 remoteLookupEnabled 无关。
    // await 必须收进 try：原实现直接 return 未 await 的 Future，catch 只能抓同步
    // throw，异步错误全部漏出成 uncaught。
    try {
      return await FushiRemoteLookupClient(
        repo: SyncRepository(_database),
        httpClient: _remoteLookupClient,
      ).lookupAudioUrl(expression: expression, reading: reading);
    } on RemoteLookupUnreachableError catch (e, stack) {
      // 全部配对候选传输层不可达：记一次日志后 rethrow，让 WordAudioResolver 把
      // hibiki-remote 源计入 45s 失败冷却（冷却窗内短路，不再重入、不刷屏）。
      // 「可达但无音频」不走这里，仍正常返回 null。
      ErrorLogService.instance.log('remoteAudioLookup', e, stack);
      rethrow;
    } catch (e, stack) {
      ErrorLogService.instance.log('remoteAudioLookup', e, stack);
      return null;
    }
  }

  FushiRemoteLookupService createRemoteLookupService() {
    return _AppModelRemoteLookupService(this);
  }

  FushiRemoteMiningService createRemoteMiningService() {
    return _AppModelRemoteLookupService(this);
  }

  FushiRemoteHistoryService createRemoteHistoryService() {
    return _AppModelRemoteLookupService(this);
  }

  /// 构造互联「制卡到服务端」的客户端发送器（供 [ankiRepositoryProvider] 在开关开启时包装
  /// [RemoteMiningAnkiRepository]）。复用与远程查词同一 keep-alive http client + 同一配对目标
  /// （enabled 的 FushiClientUrls），明文 http 候选走复用连接、https 带指纹候选走钉扎 client。
  FushiRemoteMiningClient createRemoteMiningClient() {
    return FushiRemoteMiningClient(
      repo: SyncRepository(_database),
      httpClient: _remoteLookupClient,
    );
  }

  // ── yomitan-api server (lifecycle) ──────────────────────────────────
  YomitanApiServerManager? _yomitanServerManager;

  YomitanApiServerManager _ensureYomitanManager() {
    return _yomitanServerManager ??= YomitanApiServerManager(
      lookupService: createRemoteLookupService(),
      // BUG-530：注入挖词/历史，让浏览器扩展在 yomitan-api server 上查词+制卡真正可用
      // （扩展被安装助手自动配置指向本 server 的 port/token）。
      miningService: createRemoteMiningService(),
      historyService: createRemoteHistoryService(),
      // BUG-530：主题色随查词响应下发，扩展弹窗实时跟随用户主题色（改主题即生效）。
      themeColorsProvider: browserExtensionThemeColors,
      // 单词音频（1139②）：已启用音频源随查词响应下发，扩展弹窗据此渲染 ♪ 按钮
      // （点击 → /api/lookup/audio 解析 → HTML5 Audio 播放）。
      audioSourcesProvider: () => enabledAudioSources,
      // BUG-726：内置扩展内容指纹随查词响应下发（`extensionBuild`），扩展 background
      // 与自身 FUSHI_DEFAULTS.build 比对，不一致即 chrome.runtime.reload() 从磁盘拉新。
      // 指纹由 refreshBrowserExtensionCopy 在启动时算好缓存；算好前返回 null（字段省略）。
      extensionBuildProvider: () => _browserExtensionBuild,
      // 弹窗尺寸精细化 Phase D：扩展弹窗被拖角调整尺寸后经 bridge 回写的 sink——clamp + 拖即
      // 解锁 + 只写扩展键（下次查词 browserExtensionThemeColors 读新 extensionPopupEffectiveSize
      // 即以新尺寸下发，闭环）。
      onExtensionPopupSize: _applyExtensionPopupSize,
      // 浏览器扩展连接探活：扩展任一端点命中即刷新 last-seen 时间戳，供扩展管理页
      // 的「验证插件已正常启用」连接检测显示（扩展 SW 启动时主动打 /api/extension/status，
      // 故装完扩展即刷新，无需用户先划词）。
      onExtensionSeen: () => _browserExtensionLastSeenAt = DateTime.now(),
      // BUG-1079：扩展经 /api/extension/status 请求体自报「浏览器中实际加载的 build」。
      // 记到 ValueNotifier 供扩展管理页与内置指纹比对：不一致 = 扩展自更新未生效
      // （用户从别的目录加载 / reload 失败），页面显示更新警示条。
      onExtensionReport: (String build, String? version) {
        _browserExtensionReportedAt = DateTime.now();
        browserExtensionReportedBuild.value = build;
      },
      tokenizer: JapaneseLanguage.instance.textToWords,
      readingResolver: (String w) {
        if (!FushiDicts.isInitialized) return '';
        final List<FushiLookupResult> r =
            FushiDicts.instance.lookup(w, maxResults: 1);
        return r.isEmpty ? '' : r.first.term.reading;
      },
    );
  }

  // BUG-726：内置扩展指纹缓存（refreshBrowserExtensionCopy 启动时填充）。
  String? _browserExtensionBuild;

  /// BUG-726：当前 app 内置浏览器扩展的内容指纹（build）。扩展管理页显示版本、
  /// 判断磁盘副本是否最新。启动时由 [refreshBrowserExtensionCopy] 异步算好，算好前为 null。
  String? get browserExtensionBuild => _browserExtensionBuild;

  // 浏览器扩展连接探活：last-seen 时间戳。yomitan-api server 收到任一扩展端点请求即
  // 刷新（见 [_ensureYomitanManager] 的 onExtensionSeen）。扩展管理页据此判断「插件是否
  // 已正常启用并连上本机」。null = 从未收到过扩展请求。
  DateTime? _browserExtensionLastSeenAt;

  /// 浏览器扩展最近一次访问本机 yomitan-api server 的时间（null = 从未连上）。
  /// 扩展管理页「验证插件已正常启用」据此判断连接状态。
  DateTime? get browserExtensionLastSeenAt => _browserExtensionLastSeenAt;

  /// BUG-1079：扩展自报的「浏览器中实际加载的 build」（/api/extension/status 请求体）。
  /// null = 从未上报（旧扩展发 '{}' / 从未连接）。扩展管理页用 ValueListenableBuilder
  /// 订阅，与 [browserExtensionBuild] 比对：不一致即显示「扩展需手动重新加载」警示。
  final ValueNotifier<String?> browserExtensionReportedBuild =
      ValueNotifier<String?>(null);

  // BUG-1079：最近一次扩展自报版本的时间戳（内存态，与 last-seen 同生命周期）。
  DateTime? _browserExtensionReportedAt;

  /// BUG-1079：扩展最近一次自报版本的时间（null = 从未上报）。
  DateTime? get browserExtensionReportedAt => _browserExtensionReportedAt;

  /// BUG-726：把已解压的浏览器扩展副本刷新到当前 app 内置版本（详见
  /// [refreshBundledBrowserExtensionIfStale]），并缓存内置指纹供查词响应下发。
  /// 仅桌面（扩展解压引导仅桌面有意义）；移动端 no-op。
  Future<void> refreshBrowserExtensionCopy() async {
    if (!DesktopLookupService.isDesktop) return;
    _browserExtensionBuild = await bundledBrowserExtensionFingerprint();
    await refreshBundledBrowserExtensionIfStale(
      serverConfig: BrowserExtensionServerConfig(
        host: '127.0.0.1',
        port: yomitanApiPort,
        token: yomitanApiKey,
      ),
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

  /// TODO-1266：浏览器扩展「安装助手」调用——「装完即用」。确保 yomitan-api server 就绪，
  /// 让扩展装完即可连上本机 app，不必用户再手动去设置里开 server（省掉装完 401 连不上）。
  ///
  /// 幂等 + 不覆盖既有真值（安全 + 向后兼容）：
  /// - token：仅当 [yomitanApiKey] 为空时才生成一枚随机 token 并落盘；**绝不覆盖**用户手填
  ///   或此前已配对的非空 token（覆盖会踢掉扩展已保存的 token 造成 401）。播种在启动/注入前
  ///   完成，保证 server 实际使用的 token 与随后注入扩展 `fushi-defaults.js` 的 token 一致。
  /// - server：仅当当前未启用时才置位并启动；已启用则**跳过不重启**（不打断在跑的 server、
  ///   不干扰活动连接）。[startYomitanApiServer] 本身也幂等（管理器 `if (_server != null)`）。
  ///
  /// 返回 true 表示 server 现在已启用（且预期在运行）；false 表示因端口占用启动失败
  /// （此时 [startYomitanApiServer] 已把 [yomitanApiServerEnabled] 复位为 false，
  /// 调用方据此提示用户端口冲突）。
  Future<bool> ensureYomitanApiServerForBrowserExtension() async {
    // token 就绪：空才播种，非空保留（不覆盖）。用与 sync server 同款的密码学安全随机源。
    if (yomitanApiKey.isEmpty) {
      await setYomitanApiKey(FushiSyncServer.generateToken());
    }
    // 已启用：按「跳过不重启」要求直接返回；token 已就绪且与注入值一致。
    if (yomitanApiServerEnabled) {
      return true;
    }
    await setYomitanApiServerEnabled(true);
    try {
      await startYomitanApiServer();
    } on SyncServerPortInUseException {
      // startYomitanApiServer 已在抛前把开关复位为 false。
      return false;
    }
    return true;
  }

  // ── local audio DB (delegated to LocalAudioManager) ─────────────────

  List<LocalAudioDbEntry> get localAudioDbs => _localAudioManager.entries;

  /// 把外部音频库文件拷进库目录，返回内部副本 entry（不写 prefs、不通知 native）。
  /// 持久化交给后续 [setAudioSourceConfigs]。
  ///
  /// [reference]=true（仅桌面）时跳过复制、直接引用用户原路径（BUG-483），不在
  /// AppData 留副本；移动端缓存临时副本不可引用，故 UI 只在桌面暴露此开关，默认 false。
  Future<LocalAudioDbEntry> importLocalAudioDbFile(
    String sourcePath, {
    required String displayName,
    bool reference = false,
  }) =>
      _localAudioManager.importFile(sourcePath,
          displayName: displayName, reference: reference);

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

  bool get showMediaNotification => prefsRepo.showMediaNotification;
  void toggleShowMediaNotification() => prefsRepo.toggleShowMediaNotification();
  Future<void> setShowMediaNotification(bool value) =>
      prefsRepo.setShowMediaNotification(value);

  bool get showFloatingLyric => prefsRepo.showFloatingLyric;
  Future<void> setShowFloatingLyric(bool value) =>
      prefsRepo.setShowFloatingLyric(value);

  /// TODO-1069/1070：悬浮字幕「用户意图」开关的唯一语义入口（设置页开关委托此处）。
  ///
  /// 历史 bug：设置页开关只裸写 [setShowFloatingLyric] 旁路，不真正拉起/隐藏原生
  /// 悬浮窗——「意图 pref」与「窗实际可见」两语义混用，导致设置页置位与书内翻转
  /// （[toggleFloatingLyricFromControls]）显隐反相、开关不即时。此方法把两语义收成
  /// 一个「置位（非翻转）+ 有会话时原子拉/隐窗 + 写意图 pref」的入口：
  /// - 有活动会话：先按 [value] 拉起/隐藏原生窗（拉起可能因缺 overlay 权限失败，此
  ///   时不写 pref、返回 false，由调用方提示）。窗与 pref 保持同步。
  /// - 无活动会话：仅置意图 pref；下次进书 `_startBackgroundSurfaces` 以同一 pref 为
  ///   唯一门控自动拉起，退书 `stop()` 隐窗时不改意图 pref（保持用户意图）。
  ///
  /// 返回 false 表示开启失败（缺 overlay 权限等），pref 维持原值。
  Future<bool> setFloatingLyricEnabled(bool value) async {
    if (value == showFloatingLyric && !audiobookSession.isActive) {
      // 无会话且意图未变：幂等 no-op。
      return true;
    }
    if (audiobookSession.isActive) {
      // 有活动会话：拉/隐窗要与 pref 原子同步。toggleFloatingLyric 按「当前显隐」
      // 翻转，这里以意图 pref 当作「当前显隐」的真值（二者已同步），把翻转转成置位。
      final bool currentlyShown = showFloatingLyric;
      if (value != currentlyShown) {
        final bool ok = await audiobookSession.toggleFloatingLyric(
          currentlyOn: currentlyShown,
        );
        if (!ok) return false;
      }
    }
    await setShowFloatingLyric(value);
    notifyListeners();
    return true;
  }

  double get floatingLyricFontSize => prefsRepo.floatingLyricFontSize;
  Future<void> setFloatingLyricFontSize(double value) =>
      prefsRepo.setFloatingLyricFontSize(value);

  bool get floatingLyricClickLookup => prefsRepo.floatingLyricClickLookup;
  Future<void> setFloatingLyricClickLookup(bool value) =>
      prefsRepo.setFloatingLyricClickLookup(value);

  // BUG-1095: galgame Hook 台词浮窗字号（逻辑 px），与窗高解耦后的唯一真值。
  double get galHookTextFontSize => prefsRepo.galHookTextFontSize;
  Future<void> setGalHookTextFontSize(double value) =>
      prefsRepo.setGalHookTextFontSize(value);

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

  // TODO-708 P2: 悬浮字幕圆角半径（dp，0=平台原生观感）+ 宽度（dp，0=平台默认宽）。
  int get floatingLyricCornerRadius => prefsRepo.floatingLyricCornerRadius;
  Future<void> setFloatingLyricCornerRadius(int value) =>
      prefsRepo.setFloatingLyricCornerRadius(value);

  int get floatingLyricWidth => prefsRepo.floatingLyricWidth;
  Future<void> setFloatingLyricWidth(int value) =>
      prefsRepo.setFloatingLyricWidth(value);

  // TODO-708 P4: 悬浮字幕上下文行数（对称单值，0=只当前行=今天）。
  int get floatingLyricContextLines => prefsRepo.floatingLyricContextLines;
  Future<void> setFloatingLyricContextLines(int value) =>
      prefsRepo.setFloatingLyricContextLines(value);

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
          final ({
            String message,
            bool success,
            bool record,
            MineToastStatus status
          }) described = describeMineOutcome(outcome, deckName: deckName);
          FushiToast.show(
            msg: described.message,
            severity: mineToastSeverity(described.status),
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('FloatingDict.ankiExport', e, stack);
          FushiToast.show(
            msg: t.card_export_failed,
            severity: ToastSeverity.error,
          );
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

  String get updateCustomProxy => prefsRepo.updateCustomProxy;
  Future<void> setUpdateCustomProxy(String value) =>
      prefsRepo.setUpdateCustomProxy(value);

  /// 外部 mokuro CLI 可执行路径（漫画 OCR 后备；空串=未设，退回 env/PATH 探测）。
  String get mangaExternalMokuroPath => prefsRepo.mangaExternalMokuroPath;
  Future<void> setMangaExternalMokuroPath(String value) =>
      prefsRepo.setMangaExternalMokuroPath(value);

  String get mangaOcrEnginePreference => prefsRepo.mangaOcrEnginePreference;
  Future<void> setMangaOcrEnginePreference(String value) =>
      prefsRepo.setMangaOcrEnginePreference(value);

  String get mangaSpreadPreference => prefsRepo.mangaSpreadPreference;
  Future<void> setMangaSpreadPreference(String value) =>
      prefsRepo.setMangaSpreadPreference(value);

  String get mangaReadingDirection => prefsRepo.mangaReadingDirection;
  Future<void> setMangaReadingDirection(String value) =>
      prefsRepo.setMangaReadingDirection(value);

  int get mangaZoomPercent => prefsRepo.mangaZoomPercent;
  Future<void> setMangaZoomPercent(int value) =>
      prefsRepo.setMangaZoomPercent(value);

  int get mangaZoomSensitivity => prefsRepo.mangaZoomSensitivity;
  Future<void> setMangaZoomSensitivity(int value) =>
      prefsRepo.setMangaZoomSensitivity(value);

  String get mangaPageAnimation => prefsRepo.mangaPageAnimation;
  Future<void> setMangaPageAnimation(String value) =>
      prefsRepo.setMangaPageAnimation(value);

  bool get mangaVolumeKeyPaging => prefsRepo.mangaVolumeKeyPaging;
  Future<void> setMangaVolumeKeyPaging(bool value) =>
      prefsRepo.setMangaVolumeKeyPaging(value);

  bool get mangaTapZonePaging => prefsRepo.mangaTapZonePaging;
  Future<void> setMangaTapZonePaging(bool value) =>
      prefsRepo.setMangaTapZonePaging(value);

  /// 漫画「在线目录」站点根 URL（O1 mokuro.moe 目录源；空值由 client 归一回默认）。
  String get mangaOnlineCatalogBaseUrl => prefsRepo.mangaOnlineCatalogBaseUrl;
  Future<void> setMangaOnlineCatalogBaseUrl(String value) =>
      prefsRepo.setMangaOnlineCatalogBaseUrl(value);

  bool get mangaOnlineCatalogEnabled => prefsRepo.mangaOnlineCatalogEnabled;
  Future<void> setMangaOnlineCatalogEnabled(bool value) =>
      prefsRepo.setMangaOnlineCatalogEnabled(value);

  // TODO-1024 / BUG-479：更新检查结果缓存（缓存优先 + 后台静默刷新）。
  UpdateCheckCacheEntry? get updateCheckCache => prefsRepo.updateCheckCache;
  Future<void> setUpdateCheckCache(UpdateCheckCacheEntry entry) =>
      prefsRepo.setUpdateCheckCache(entry);

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

/// 批量 YouTube 制卡的流解析器（进程级：TTL 缓存跨 mineImmersion 调用共享，一场「生成全部」
/// 同一视频只解析一次流）。放 top-level 而非实例字段，是因 [_AppModelRemoteLookupService]
/// 是 const 构造，无法挂非 const 的可变缓存字段。
final YoutubeClipMiner _youtubeClipMiner = YoutubeClipMiner();

/// TODO-1303：把一次 [MineOutcome] 映射成 [RemoteMineResult]，并**把失败写进错误日志**。
/// 远端挖词（浏览器扩展）此前只回结果名、失败既不回传原因也不记日志 → 「制卡失败报成功 +
/// 诊断黑洞」。这里复用 app 内同一 [logMineFailure]（写 error+stack 进 [ErrorLogService]、
/// 返回简短本地化文案）与 [MineOutcome.audioWarning]（部分成功：卡建了但单词音频落空）语义，
/// 让远端与应用内的失败处理走同一条真相路径。
RemoteMineResult remoteMineResultFromOutcome(MineOutcome outcome) {
  switch (outcome.result) {
    case MineResult.error:
      // logMineFailure：把完整诊断写进错误日志（用户可查/可导出），返回简短本地化文案。
      final String reason = logMineFailure(outcome);
      return RemoteMineResult(
        result: outcome.result.name,
        message: reason,
        detail: outcome.errorDetail,
      );
    case MineResult.success:
      final String? warn = outcome.audioWarning;
      // 部分成功：卡建好了但单词远程音频落空 → 回传警告让扩展区分「真成功 / 没音频」。
      return warn != null && warn.isNotEmpty
          ? RemoteMineResult(result: outcome.result.name, message: warn)
          : RemoteMineResult(result: outcome.result.name);
    case MineResult.duplicate:
    case MineResult.notConfigured:
      return RemoteMineResult(result: outcome.result.name);
  }
}

/// TODO-1303：远端制卡在**未产出 [MineOutcome]** 就失败（引擎中止：缺音频/空壳卡；
/// YouTube 流解析超时；零长度窗）时的错误结果。把原因写进 [ErrorLogService]（不再只
/// `debugPrint` 进黑洞）并回带诊断。[reason]=给用户的简短文案，[detail]=技术细节。
RemoteMineResult remoteMineError(
  String source,
  String reason, {
  String? detail,
  Object? error,
  StackTrace? stackTrace,
}) {
  ErrorLogService.instance.log(source, error ?? detail ?? reason, stackTrace);
  return RemoteMineResult(
    result: MineResult.error.name,
    message: reason,
    detail: detail,
  );
}

class _AppModelRemoteLookupService
    implements
        FushiRemoteLookupService,
        FushiRemoteMiningService,
        FushiRemoteHistoryService {
  const _AppModelRemoteLookupService(this._appModel);

  final AppModel _appModel;

  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    final BaseAnkiRepository repo =
        _appModel.platformServices.createAnkiRepository();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: AnkiMiningContext(sentence: sentence),
    );
    // TODO-1303：回带诊断 + 失败写错误日志（单一真相：remoteMineResultFromOutcome）。
    return remoteMineResultFromOutcome(outcome);
  }

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async {
    // 互联「制卡到服务端」：客户端已把未渲染的 rawPayloadJson + context 文本 + 全部本地
    // 媒体字节发来。这里把字节落成本机临时文件 / 词典缓存、重建 AnkiMiningContext，再走
    // 与 app 内本地制卡**完全同一**的 repo.mineEntry 渲染链路（服务端用自己的字段映射/牌组）。
    final BaseAnkiRepository repo =
        _appModel.platformServices.createAnkiRepository();
    final Directory tmp =
        Directory.systemTemp.createTempSync('hibiki_fwd_mine_');
    try {
      // ① 封面 → 临时文件 → context.coverPath
      String? coverPath;
      if (payload.coverBytes != null) {
        final File f = File('${tmp.path}/cover.${payload.coverExt ?? 'bin'}');
        await f.writeAsBytes(payload.coverBytes!, flush: true);
        coverPath = f.path;
      }
      // ② 句子音频 → 临时文件 → context.sasayakiAudioPath
      String? sentenceAudioPath;
      if (payload.sentenceAudioBytes != null) {
        final File f = File(
            '${tmp.path}/sentence_audio.${payload.sentenceAudioExt ?? 'bin'}');
        await f.writeAsBytes(payload.sentenceAudioBytes!, flush: true);
        sentenceAudioPath = f.path;
      }
      // ③ 单词音频（本地文件）→ 临时文件 → 改写 rawPayloadJson 的 audio 字段为本机路径
      String rawPayloadJson = payload.rawPayloadJson;
      if (payload.wordAudioBytes != null) {
        final File f =
            File('${tmp.path}/word_audio.${payload.wordAudioExt ?? 'bin'}');
        await f.writeAsBytes(payload.wordAudioBytes!, flush: true);
        rawPayloadJson = _rewriteForwardedAudioField(rawPayloadJson, f.path);
      }
      // ④ 词典外字 → 落到 repo 会读取的共享缓存目录（按 path 派生同名，与 repo 读取对齐）
      await _materializeForwardedDictionaryMedia(payload.dictionaryMedia);
      // ⑤ 重建 context 后走本地渲染链路落卡
      final AnkiMiningContext context = AnkiMiningContext(
        sentence: payload.sentence,
        cueSentence: payload.cueSentence,
        documentTitle: payload.documentTitle,
        coverPath: coverPath,
        sentenceAudioPath: sentenceAudioPath,
        sentenceOffset: payload.sentenceOffset,
        source: _forwardedSourceFromName(payload.source),
        bookTitleTag: payload.bookTitleTag,
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
      return remoteMineResultFromOutcome(outcome);
    } catch (e, st) {
      return remoteMineError(
        'Anki.mineForwarded',
        '服务端制卡失败',
        detail: '$e',
        error: e,
        stackTrace: st,
      );
    } finally {
      // 临时封面/音频在 mineEntry 落卡（读+storeMedia）完成后回收；词典缓存目录是共享的
      // （与本地 writeDictionaryMediaCache 同址），下次覆盖即可，不在此删。
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 把 rawPayloadJson 里的 `audio` 字段改写成本机临时文件路径（客户端单词音频是本地文件时）。
  String _rewriteForwardedAudioField(String rawJson, String newAudioPath) {
    try {
      final Map<String, dynamic> map =
          jsonDecode(rawJson) as Map<String, dynamic>;
      map['audio'] = newAudioPath;
      return jsonEncode(map);
    } catch (_) {
      return rawJson;
    }
  }

  /// 把转发来的词典外字字节落到 [ankiDictionaryMediaCacheDirPath]，命名与 repo 读取对齐
  /// （[ankiDictionaryMediaCacheFilename]）。服务端未必装同款词典，故必须用客户端字节。
  Future<void> _materializeForwardedDictionaryMedia(
      List<ForwardedDictMedia> media) async {
    if (media.isEmpty) return;
    final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final ForwardedDictMedia m in media) {
      final bytes = m.bytes;
      if (bytes == null || bytes.isEmpty || m.path.isEmpty) continue;
      final String fname =
          ankiDictionaryMediaCacheFilename(m.dictionary, m.path);
      // 防御：文件名扩展名派生自 client 提供的 path，理论上可含分隔符（`ankiDictionary…`
      // 未过滤 ext）。落在缓存目录之外/嵌套子目录是不可接受的——直接跳过该条（外字缺失即
      // 降级，与其它媒体一致），绝不写出目录。SHA-1 前缀已让路径不可上溯，这里再堵横向。
      if (fname.contains('/') || fname.contains('\\')) continue;
      final File f = File('${dir.path}/$fname');
      await f.writeAsBytes(bytes, flush: true);
    }
  }

  AnkiMiningSource? _forwardedSourceFromName(String? name) {
    switch (name) {
      case 'book':
        return AnkiMiningSource.book;
      case 'video':
        return AnkiMiningSource.video;
      case 'game':
        return AnkiMiningSource.game;
      default:
        return null;
    }
  }

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    // TODO-1176：与 app 内 dictionary_page_mixin.checkDuplicate 走同一 repo.isDuplicate
    // 路径（AnkiConnect findNotes / AnkiDroid findDuplicateNotes），repo 内部已 fail-soft。
    final BaseAnkiRepository repo =
        _appModel.platformServices.createAnkiRepository();
    return repo.isDuplicate(expression, reading);
  }

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async {
    final BaseAnkiRepository repo =
        _appModel.platformServices.createAnkiRepository();
    // 远端制卡（浏览器扩展的 YouTube / Netflix）语义上就是视频制卡，读同一条动图格式
    // 偏好。BUG-1330：这里过去既不传 format 给 resolve、也不传 animatedFormat 给引擎，
    // 用户拍板的 AVIF 默认在扩展这条链路上完全没落地（恒出 GIF）。
    final MiningAnimatedFormat animatedFormat =
        _appModel.videoMiningAnimatedFormat;
    final MiningMediaCompression compression = MiningMediaCompression.resolve(
      imageTier: _appModel.miningImageQuality,
      audioTier: _appModel.miningAudioQuality,
      // 顶格档的动图参数随格式变（AVIF 24fps/1440px、GIF/WebP 12fps/960px）。format 与
      // 下面透传给编码侧的格式**必须是同一个值**：只传其一就是「格式与参数不成对」——
      // 把 AVIF 的顶格档参数喂给 GIF 编码器正是 BUG-1039。
      format: animatedFormat,
    );
    // 优先级 0（YouTube，非 DRM）：有 videoId + 视频时间窗 → 从真实视频流精确裁，不录屏/不回放。
    // 复用应用内播放器已验证的引擎（mediaSource=挖矿流，audioSource=分离音频流或 null）。
    if (payload.youtubeVideoId != null &&
        payload.clipStartMs != null &&
        payload.clipEndMs != null) {
      // 零/负长度窗（字幕时间异常）→ 直接失败，不出无声/无 GIF 的静帧卡：服务端 YouTube 路径无
      // stillFallback，且 requireAudio 在 hasRange=false 时不会中止 → 否则静默降级成坏卡。
      if (payload.clipEndMs! <= payload.clipStartMs!) {
        return remoteMineError(
          'Anki.mineImmersion.youtube',
          'YouTube 字幕时间窗无效（零/负长度），未制卡',
          detail: 'clip window <= 0 '
              '(${payload.clipStartMs}..${payload.clipEndMs})',
        );
      }
      final YoutubeClipRequest yt;
      try {
        yt = await _youtubeClipMiner.buildRequest(
          videoId: payload.youtubeVideoId!,
          startMs: payload.clipStartMs!,
          endMs: payload.clipEndMs!,
          fields: payload.fields,
          sentence: payload.sentence,
          cueSentence: payload.cueSentence,
          documentTitle: payload.documentTitle,
        );
      } catch (e, st) {
        // resolveYoutubeSource 会抛 TimeoutException / 视频不可用等；两个 server 的 /api/mine
        // 只 catch FormatException，这里不兜住会 500 整张卡。收敛成干净的 MineResult.error。
        // TODO-1303：不再只 debugPrint 进黑洞——写进错误日志并回带诊断。
        return remoteMineError(
          'Anki.mineImmersion.youtube',
          'YouTube 视频流解析失败，未制卡',
          detail: 'resolve failed: $e',
          error: e,
          stackTrace: st,
        );
      }
      final ImmersionMiningResult ytRes = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: yt.fields,
          mediaSource: yt.mediaSource,
          audioSource: yt.audioSource,
          clipStartMs: yt.clipStartMs,
          clipEndMs: yt.clipEndMs,
          sentence: yt.sentence,
          cueSentence: yt.cueSentence,
          documentTitle: yt.documentTitle ?? 'YouTube',
          source: AnkiMiningSource.video,
          // YouTube 有音频源 → 缺音频即失败（与应用内一致），不出无声卡。
          requireAudio: true,
          // 与上面 resolve 的 format 同值：引擎按它选编码器 + 输出扩展名 + 降级链。
          animatedFormat: animatedFormat,
          // TODO-2519(2a)：动图 vs 静态帧偏好与格式偏好同源同链路，过去只透传了格式，
          // 用户选「字幕开头截图 / 制卡时截图」在 YouTube 这条路上恒被吞成动图。
          // 服务端路径无 stillFallback（拿不到当前解码帧），两种静态模式都落到引擎的
          // tryStartFrame（immersion_mining_engine.dart:311-318 的排列本就互为兜底）
          // → 静态模式根本不进 extractAnimatedClipWithFallback，不存在 BUG-1039 那种
          // 「格式与编码参数不成对」的风险：静态帧压根不吃 gifFps/gifWidth。
          imageMode: _appModel.videoMiningImageMode,
        ),
        compression: compression,
        tempDir: Directory.systemTemp.path,
        repo: repo,
        // GIF/音频抽取失败摘要写日志，便于排查「没 gif / 只有图片」。
        // TODO-1303：GIF/音频抽取摘要进诊断日志（可导出、不计入用户错误计数）。
        onFailure: (String s) => ErrorLogService.instance
            .logDiagnostic('Anki.mineImmersion.youtube.extract', s),
      );
      if (ytRes.aborted) {
        return remoteMineError('Anki.mineImmersion.youtube',
            'YouTube 制卡失败：${ytRes.abortReason ?? '媒体抽取失败'}',
            detail: ytRes.abortReason);
      }
      return remoteMineResultFromOutcome(ytRes.outcome! as MineOutcome);
    }
    // 捕获来源优先级（Netflix GIF）：① 扩展在播放中录到的字幕片段 webm → ffmpeg 转 GIF+音频
    // （唯一不回放的 Netflix GIF 路径，需用户关硬件加速才非黑）；② 后台软解 native 实例（未建
    // 时返 error）；③ 都没有 → 用 2A 截图字节组卡（buildImmersionRequest 内降级）。
    ImmersionCaptureResult cap = const ImmersionCaptureResult(error: 'skip');
    if (payload.clipBytes != null) {
      // Netflix 批量录制的片段边界即句子边界（seek 到句首 → 录到字幕变化停），整段转码 [0,时长]。
      // 扩展 mineClip 不发段内窗/gifEnd（批量回放全自动、无查词交互、无鼠标/弹窗）→ 无从也无须裁段内窗（V16#4）。
      final int clipDurationMs = payload.clipDurationMs ?? 6000;
      // BUG-1416：动图 vs 静态帧偏好在 Netflix 这条路上过去被结构性吞掉——buildImmersionRequest
      // 恒给 providedCoverBytes，引擎的 imageMode 阶梯（immersion_mining_engine.dart 的
      // `if (coverPath == null)`）根本不会被求值。故必须在**产字节这一层**就按偏好分流。
      final ClipStillTarget? stillTarget = resolveClipStillTarget(
        imageMode: _appModel.videoMiningImageMode,
        clipAnchorMs: payload.clipAnchorMs,
        cueStartMs: payload.cueStartMs,
        mineAtMs: payload.mineAtMs,
        durationMs: clipDurationMs,
      );
      if (stillTarget != null) {
        // 偏移误差在真机上可观测，而不是靠猜：锚点不确定度由扩展在 beginClip 前后实测下发。
        ErrorLogService.instance.logDiagnostic(
          'Anki.mineImmersion.netflix.still',
          'imageMode=${_appModel.videoMiningImageMode.wireName} '
              'offsetMs=${stillTarget.offsetMs} exact=${stillTarget.exact} '
              'anchorMs=${payload.clipAnchorMs} '
              'anchorUncertaintyMs=${payload.clipAnchorUncertaintyMs} '
              'mineAtMs=${payload.mineAtMs} cueStartMs=${payload.cueStartMs}',
        );
      }
      cap = await transcodeClipToCapture(
        payload.clipBytes!,
        durationMs: clipDurationMs,
        compression: compression,
        tempDir: Directory.systemTemp.path,
        // 与上面 resolve 的 format 同值：转码按它选编码器 + 输出扩展名 + 降级链，
        // 实际产出格式经 ImmersionCaptureResult.animatedFormat 回传给封面文件名。
        format: animatedFormat,
        stillTarget: stillTarget,
      );
    } else if (payload.netflixVideoId != null &&
        payload.clipStartMs != null &&
        payload.clipEndMs != null) {
      cap = await ImmersionCaptureChannel.capture(
        netflixVideoId: payload.netflixVideoId!,
        clipStartMs: payload.clipStartMs!,
        clipEndMs: payload.clipEndMs!,
      );
    }
    // TODO-1303：录制片段（clipBytes）来源本应带音频（Netflix 播放必有音轨）→ audioExpected，
    // 引擎在最终无音频（转码丢音轨）时中止而非静默出无声卡；2A 截图 / 后台软解不可用 → 不强求
    // （截图卡本就无音频不算失败）。
    final bool audioExpected = payload.clipBytes != null;
    final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
      buildImmersionRequest(payload, cap, audioExpected: audioExpected),
      compression: compression,
      tempDir: Directory.systemTemp.path,
      repo: repo,
    );
    if (res.aborted) {
      return remoteMineError('Anki.mineImmersion.netflix',
          'Netflix 制卡失败：${res.abortReason ?? '媒体抽取失败'}',
          detail: res.abortReason);
    }
    return remoteMineResultFromOutcome(res.outcome! as MineOutcome);
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
    // TODO-1335 ②：与 app 内查词弹窗同一条 resolveLookupAudioUrl 全源解析（本地库 +
    // hibikiRemote + 远程 URL 模板），而非只查本地库——否则仅配了远程发音源（jpod/forvo）
    // 的用户在扩展/远端查词弹窗里恒无单词音频。解析结果可能是本地文件路径或远程 http(s)
    // URL，remoteAudioLookupFromResolvedUrl 统一归一成字节（远程下载、本地读文件），仍经
    // 本地短命 token 播放。
    final String? resolved = await resolveLookupAudioUrl(
      _appModel,
      expression,
      reading,
    );
    return remoteAudioLookupFromResolvedUrl(
      resolved,
      downloadRemote: _downloadRemoteAudioBytes,
      loadLocalFile: (String filePath) async {
        final File audioFile = File(filePath);
        if (!audioFile.existsSync()) return null;
        return audioFile.readAsBytes();
      },
    );
  }

  /// TODO-1335 ②：服务端下载远程发音源字节（Forvo/jpod/hibikiRemote 解析出的 http(s)
  /// URL）。复用 AppModel 的 keep-alive http client；失败写错误日志并回 null（弹窗降级为
  /// 无音频，绝不抛断查词）。
  Future<RemoteAudioLookup?> _downloadRemoteAudioBytes(Uri uri) async {
    try {
      final http.Response resp = await _appModel._remoteLookupClient
          .get(uri)
          .timeout(kRemoteAudioReceiveTimeout);
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      return RemoteAudioLookup(
        bytes: resp.bodyBytes,
        contentType: remoteAudioContentTypeFromResponse(
          uri,
          resp.headers['content-type'],
        ),
      );
    } catch (e, st) {
      ErrorLogService.instance.log('lookupAudio.downloadRemote', e, st);
      return null;
    }
  }
}
