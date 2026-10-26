import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show DictionarySearchResult;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:path/path.dart' as p;

import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_dictionary_json.dart' show buildCtlMineFields;
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/mining/galgame_cover_resolver.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart'
    show applyGalgameScrapeCandidate;
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart'
    show GalgameMetadataException;
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart'
    show SourceCandidate, draftDate;
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart'
    show GalgameCustomData;
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart'
    show parseGalgameTagInput;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart'
    show GalgameSessionRow, GalgameSourceRow;
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_projection.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart'
    show GalAttachedSurfaceTarget;

/// game 域控制通道路由（Galgame Hook，**仅 Windows**；CLI 侧命令见
/// `packages/fushi_cli/lib/src/commands/game_commands.dart`）。
///
/// 只做控制面接线，所有动作落到 app 现有的同一条链路上：
/// * 启动 = 游戏库「启动」同一组步骤（exe 存在 → 按位数确保随包 helper 就位 →
///   Profile 绑定 → [GalHookSessionController.launchGame]，启动器 / 真实游戏 PID
///   由会话控制器与 injector 处理），结果按 [classifyGalHookLaunchOutcome] 分级；
/// * 附着 = 工作台「附着到运行中的游戏」同一个 [GalHookSessionController.startAttachedCapture]；
/// * 选线程 = 工作台线程下拉同一个 `selectTextThread(remember: true)`；
/// * 制卡 = 浮窗 / 工作台同一个 [GalHookMiningCoordinator.mineLine]（精确行、画面、句音）。
///
/// 能力阶段（`process_found → helper_ready → ipc_ready → text_ready →
/// resource/pcm_ready → paired`）由 [galHookCtlStages] 从会话状态逐级如实给出，
/// 不合并成一个「成功」；`e2e_verified` 永远不是本接口能证明的（见 docs/agent/galgame-hooking.md）。
List<CtlRoute> buildGameCtlRoutes(OpContext context) =>
    buildGameCtlRoutesWith(_AppGameCtlHost(context));

/// 测试入口：注入假的 [GameCtlHost]。
@visibleForTesting
List<CtlRoute> buildGameCtlRoutesWith(GameCtlHost host) {
  final _GameCtl ctl = _GameCtl(host);
  return <CtlRoute>[
    CtlRoute.get('/api/admin/game/games', ctl.listGames),
    CtlRoute.post('/api/admin/game/launch', ctl.launch),
    CtlRoute.get('/api/admin/game/windows', ctl.listWindows),
    CtlRoute.post('/api/admin/game/attach', ctl.attach),
    CtlRoute.post('/api/admin/game/stop', ctl.stop),
    CtlRoute.get('/api/admin/game/status', ctl.status),
    // 静态段 `/threads/select` 只有 POST，`/threads` 只有 GET，不会互相遮挡。
    CtlRoute.get('/api/admin/game/threads', ctl.listThreads),
    CtlRoute.post('/api/admin/game/threads/select', ctl.selectThread),
    CtlRoute.get('/api/admin/game/text', ctl.text),
    CtlRoute.post('/api/admin/game/mine', ctl.mine),
    // ── 工作台细项 ───────────────────────────────────────────────────────
    CtlRoute.put('/api/admin/game/games/:id/config', ctl.configureGame),
    // ── 游戏条目管理 ─────────────────────────────────────────────────────
    CtlRoute.put('/api/admin/game/games/:id/name', ctl.renameGame),
    CtlRoute.put('/api/admin/game/games/:id/play-status', ctl.setPlayStatus),
    CtlRoute.post('/api/admin/game/games/:id/cover', ctl.setCover),
    CtlRoute.put('/api/admin/game/games/:id/details', ctl.editGame),
    CtlRoute.delete('/api/admin/game/games/:id', ctl.removeGame),
    CtlRoute.get('/api/admin/game/games/:id/sessions', ctl.listSessions),
    CtlRoute.delete(
      '/api/admin/game/games/:id/sessions/:sessionId',
      ctl.deleteSession,
    ),
    CtlRoute.get('/api/admin/game/games/:id/scrape', ctl.scrapeSearch),
    CtlRoute.post('/api/admin/game/games/:id/scrape', ctl.scrapeApply),
    CtlRoute.get('/api/admin/game/games/:id/sources', ctl.listSources),
    CtlRoute.delete(
      '/api/admin/game/games/:id/sources/:source',
      ctl.removeSource,
    ),
    CtlRoute.post('/api/admin/game/bind', ctl.bind),
    CtlRoute.put('/api/admin/game/window-mode', ctl.setWindowMode),
    CtlRoute.get('/api/admin/game/tracks', ctl.listTracks),
    CtlRoute.post('/api/admin/game/tracks/select', ctl.selectTrack),
    CtlRoute.post('/api/admin/game/tracks/exclude', ctl.excludeTrack),
    CtlRoute.post('/api/admin/game/tracks/preview', ctl.previewTrack),
    CtlRoute.post('/api/admin/game/audio/stop', ctl.stopAudio),
    CtlRoute.put('/api/admin/game/audio-policy', ctl.setAudioPolicy),
    CtlRoute.get('/api/admin/game/lines/:id/tracks', ctl.lineTracks),
    CtlRoute.post('/api/admin/game/lines/:id/track', ctl.setLineTrack),
    CtlRoute.post('/api/admin/game/lines/:id/preview', ctl.previewLine),
    CtlRoute.post('/api/admin/game/lines/:id/recapture', ctl.recaptureLine),
    CtlRoute.post('/api/admin/game/lines/:id/favorite', ctl.favoriteLine),
    CtlRoute.get('/api/admin/game/textproc', ctl.getTextProcess),
    CtlRoute.put('/api/admin/game/textproc', ctl.setTextProcess),
    CtlRoute.post('/api/admin/game/events/clear', ctl.clearEvents),
    CtlRoute.get('/api/admin/game/lookup-mode', ctl.getLookupMode),
    CtlRoute.put('/api/admin/game/lookup-mode', ctl.setLookupMode),
    CtlRoute.post(
      '/api/admin/game/lookup-profile/clear',
      ctl.clearLookupProfile,
    ),
    CtlRoute.get('/api/admin/game/lookup-profile', ctl.getLookupProfile),
    CtlRoute.post('/api/admin/game/lookup-calibrate', ctl.calibrateLookup),
    CtlRoute.post('/api/admin/game/screenshot', ctl.screenshot),
  ];
}

/// 内嵌查词表面当下的状态（[GalAttachedTextController] 的只读投影，测试用假数据）。
class GameCtlLookupState {
  const GameCtlLookupState({
    this.target,
    this.currentClient,
    this.executablePath,
    this.executableSha256,
    this.profile,
    this.status = GalAttachedTextStatus.disabled,
    this.statusReason,
    this.sampleCalibrationEnabled = false,
    this.canCaptureCalibrationSample = false,
    this.calibrationActive = false,
  });

  final GalAttachedSurfaceTarget? target;
  final GalLookupReferenceClientV1? currentClient;
  final String? executablePath;
  final String? executableSha256;
  final GalLookupSurfaceProfileV1? profile;
  final GalAttachedTextStatus status;
  final String? statusReason;
  final bool sampleCalibrationEnabled;
  final bool canCaptureCalibrationSample;
  final bool calibrationActive;
}

// ── 宿主抽象 ──────────────────────────────────────────────────────────────

/// 一次会话快照：路由只读这一份，测试用假数据构造。
class GameCtlSessionSnapshot {
  const GameCtlSessionSnapshot({
    required this.state,
    this.hasEngineSource = false,
    this.captureExecutable,
    this.textThreads = const <TexthookerTextThread>[],
    this.selectedThreadKey,
    this.sessionLines = const <TexthookerLineEntry>[],
    this.events = const <GalHookEvent>[],
    this.endpoints = const <TexthookerEndpointStatus>[],
    this.recapturingLineId,
    this.textProcessPipeline = kGalDefaultTextProcessPipeline,
    this.attachedExecutable,
    this.attachedMode,
  });

  /// 正在补录的台词行（同一时刻至多一行）。
  final String? recapturingLineId;

  /// 当前（所选线程的）文本处理管线。
  final GalTextProcessPipeline textProcessPipeline;

  /// 内嵌查词表面（attached lookup）当前绑定的 exe；null = 还没有附着目标。
  final String? attachedExecutable;

  /// 该 exe 已保存 profile 的查词表面模式；null = 没有 profile（等同 auto）。
  final GalLookupSurfaceMode? attachedMode;

  final GalHookSessionState state;

  /// 引擎 hook 源已提升为活动源（injector 宣告就绪、文本轮询已开始）。
  final bool hasEngineSource;
  final String? captureExecutable;
  final List<TexthookerTextThread> textThreads;
  final String? selectedThreadKey;

  /// 当前会话、当前线程放行的正式行（工作台 / 浮窗 / 制卡共用的那一份）。
  final List<TexthookerLineEntry> sessionLines;
  final List<GalHookEvent> events;

  /// 外部 WebSocket 文本端点（Textractor 等）的连接状态。
  final List<TexthookerEndpointStatus> endpoints;
}

/// 启动预检没通过的原因（游戏进程根本没被拉起）。
enum GameCtlLaunchPreflight { exeMissing, helperMissing }

/// 一次启动的结果：预检失败，或 [GalHookSessionController.launchGame] 的结构化结果。
class GameCtlLaunchReport {
  const GameCtlLaunchReport.preflight(GameCtlLaunchPreflight this.preflight)
    : result = null;

  const GameCtlLaunchReport.launched(GalHookLaunchResult this.result)
    : preflight = null;

  final GameCtlLaunchPreflight? preflight;
  final GalHookLaunchResult? result;
}

/// 制卡要的 app 服务。拆出来是为了让路由逻辑可单测。
abstract interface class GameCtlHost {
  bool get isWindows;
  bool get gamesModuleEnabled;
  bool get isMigrationReadonly;

  Future<List<GalgameEntry>> loadGames();
  GameCtlSessionSnapshot snapshot();

  Future<GameCtlLaunchReport> launch(GalgameEntry game);
  Future<List<ExternalWindowInfo>> listWindows();
  Future<void> attach(ExternalWindowInfo window);
  Future<void> stop({required bool keepBinding});

  /// [thread] 为 null = 清除选择。
  Future<bool> selectThread(TexthookerTextThread? thread);

  // ── 工作台细项（全部直通 [GalHookSessionController] 等现有 API）────────

  /// 每游戏启动期配置（库页右键菜单同三项：转区 / 超分 / 内容语言）。
  Future<void> setGameJapaneseLocaleMode(String gameId, String modeKey);
  Future<void> setGameUpscalingMode(String gameId, String modeKey);
  Future<void> setGameLanguage(String gameId, String? language);

  Future<void> bindWindow(ExternalWindowInfo? window);
  Future<void> setExternalWindowMode(bool enabled);

  Future<void> refreshAudioTracks();
  void selectVoiceTrack(int sourcePtr);
  void setTrackExcluded(int sourcePtr, bool excluded);
  Future<GalTrackPreview?> exportTrackPreview(int sourcePtr);
  Future<GalTrackPreview?> exportLineTrackPreview(String lineId, int sourcePtr);
  Future<GalTrackPreview?> exportLineAudioPreview(String lineId);
  Future<List<GalAudioTrack>> tracksForLine(String lineId);
  int? lineVoiceSourcePtr(String lineId);
  Future<bool> setLineVoiceTrack(String lineId, int sourcePtr);

  /// 在 app 内播放试听文件（工作台 / 诊断页同一个 [DesktopAudioPlayback]）。
  Future<bool> playAudioFile(String path);
  Future<void> stopAudio();

  Future<bool> startLineRecapture(String lineId);
  Future<bool> finishLineRecapture({required bool discard});

  void setAudioFallbackPolicy(GalAudioFallbackPolicy policy);
  Future<void> setTextProcessPipeline(GalTextProcessPipeline pipeline);

  /// 返回切换后的收藏状态；行不存在返回 null。
  bool? toggleLineFavorite(String lineId);
  void clearEvents();

  Future<void> setLookupMode(GalLookupSurfaceMode mode);
  Future<void> clearLookupProfile();

  GameCtlLookupState lookupState();

  /// 截图样本：工作台「截图校准」同一个 `captureCalibrationSample`（先藏起
  /// 贴附层再抓，画面不含 Fushi 自己的覆盖层）。失败抛 [GalLookupCalibrationCaptureException]。
  Future<GalLookupCalibrationCapture> captureCalibrationSample();

  /// 截图实测几何落库：工作台「截图校准 → 应用」同一个 `applyMeasuredCalibration`。
  Future<bool> applyMeasuredCalibration({
    required GalAttachedSurfaceTarget expectedTarget,
    required String expectedExeSha256,
    required GalLookupSurfaceVariantV1 variant,
  });

  Future<void> writeFile(String path, List<int> bytes);

  // ── 游戏条目管理（游戏库页 / 详情页同一组仓储调用）────────────────────

  Future<void> setCustomData(String gameId, GalgameCustomData custom);
  Future<void> setPlayStatus(String gameId, GalgamePlayStatus status);

  /// 整行更新（详情页「编辑」保存同一个 `updateEntry`）。
  Future<void> updateEntry(GalgameEntry entry);

  /// 把本地图片拷进游戏封面目录并回填；返回落盘路径，失败 null。
  Future<String?> importCoverFile(String gameId, String sourcePath);

  /// 「自动获取封面」：游戏目录封面图 → exe 图标；返回落盘路径，找不到 null。
  Future<String?> autoCover(GalgameEntry game);

  /// 从库移除（不删磁盘文件）；[deleteStatistics] 时先清统计。返回统计清理的
  /// 失败原因（成功 / 没要求删统计为 null），统计失败不拦移除（与库页同纪律）。
  Future<String?> removeGame(String gameId, {required bool deleteStatistics});

  /// 游玩会话：`{id, startMs, endMs, durationSeconds, dateKey}`。
  Future<List<Map<String, Object?>>> sessions(
    String gameId, {
    required int limit,
    required int offset,
  });
  Future<void> deleteSession(int sessionId);

  Future<GalgameScrapeSearchResult> scrapeSearch(
    String query, {
    Set<GalgameMetadataSource>? sources,
  });

  /// 详情页 / 库页「使用」候选同一个 [applyGalgameScrapeCandidate]；false = 源上找不到。
  Future<bool> applyScrape(String gameId, SourceCandidate candidate);
  Future<List<String>> metadataSources(String gameId);
  Future<void> removeMetadataSource(
    String gameId,
    GalgameMetadataSource source,
  );

  /// 卡片 / 浮窗上显示的那份台词（按游戏的可见文本 profile 处理；无 profile = 原文）。
  String visibleText(TexthookerLineEntry entry);

  Future<Map<String, String>> buildMineFields({
    required String word,
    required String sentence,
    String? reading,
    String? glossary,
    required bool lookup,
    required bool allowDuplicate,
  });

  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    required String sentence,
    int? updateNoteId,
  });
}

/// 生产宿主：全部委托给 app 单例与 [AppModel]。构造期不碰 ref（路由表在启动早期构建）。
class _AppGameCtlHost implements GameCtlHost {
  _AppGameCtlHost(this.context);

  final OpContext context;

  AppModel get _app => context.appModel;

  GalHookSessionController get _session => GalHookSessionController.instance;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  bool get gamesModuleEnabled =>
      _app.moduleVisibility.isEnabled(ModuleId.games);

  @override
  bool get isMigrationReadonly => _app.isMigrationReadonly;

  @override
  Future<List<GalgameEntry>> loadGames() async {
    final GalgameRepository repo = _app.galgameRepo;
    if (!repo.isLoaded) await repo.load();
    return repo.games;
  }

  @override
  GameCtlSessionSnapshot snapshot() {
    final GalHookSessionController session = _session;
    return GameCtlSessionSnapshot(
      state: session.state,
      hasEngineSource: session.hasEngineSource,
      captureExecutable: session.currentCaptureExecutable,
      textThreads: session.textThreads,
      selectedThreadKey: session.selectedTextThreadKey,
      sessionLines: session.selectedSessionLines,
      events: session.events,
      endpoints: session.endpointStatuses,
      recapturingLineId: session.recapturingLineId,
      textProcessPipeline: session.textProcessPipeline,
      attachedExecutable: _attached.executablePath,
      attachedMode: _attached.profile?.mode,
    );
  }

  GalAttachedTextController get _attached =>
      GalHookTextOverlayController.instance.attachedText;

  // ── 工作台细项 ─────────────────────────────────────────────────────────

  @override
  Future<void> setGameJapaneseLocaleMode(String gameId, String modeKey) =>
      _app.galgameRepo.setJapaneseLocaleMode(gameId, modeKey);

  @override
  Future<void> setGameUpscalingMode(String gameId, String modeKey) =>
      _app.galgameRepo.setUpscalingMode(gameId, modeKey);

  @override
  Future<void> setGameLanguage(String gameId, String? language) =>
      _app.galgameRepo.setLanguage(gameId, language);

  @override
  Future<void> bindWindow(ExternalWindowInfo? window) =>
      _session.bindWindow(window);

  @override
  Future<void> setExternalWindowMode(bool enabled) =>
      _session.setExternalWindowMode(enabled);

  @override
  Future<void> refreshAudioTracks() => _session.refreshAudioTracks();

  @override
  void selectVoiceTrack(int sourcePtr) => _session.selectVoiceTrack(sourcePtr);

  @override
  void setTrackExcluded(int sourcePtr, bool excluded) =>
      _session.setTrackExcluded(sourcePtr, excluded);

  @override
  Future<GalTrackPreview?> exportTrackPreview(int sourcePtr) =>
      _session.exportTrackPreview(sourcePtr);

  @override
  Future<GalTrackPreview?> exportLineTrackPreview(
    String lineId,
    int sourcePtr,
  ) => _session.exportLineTrackPreview(lineId, sourcePtr);

  @override
  Future<GalTrackPreview?> exportLineAudioPreview(String lineId) =>
      _session.exportLineAudioPreview(lineId);

  @override
  Future<List<GalAudioTrack>> tracksForLine(String lineId) =>
      _session.tracksForLine(lineId);

  @override
  int? lineVoiceSourcePtr(String lineId) => _session.lineVoiceSourcePtr(lineId);

  @override
  Future<bool> setLineVoiceTrack(String lineId, int sourcePtr) =>
      _session.setLineVoiceTrack(lineId, sourcePtr);

  @override
  Future<bool> playAudioFile(String path) =>
      DesktopAudioPlayback.playFile(path);

  @override
  Future<void> stopAudio() => DesktopAudioPlayback.stop();

  @override
  Future<bool> startLineRecapture(String lineId) =>
      _session.startLineRecapture(lineId);

  @override
  Future<bool> finishLineRecapture({required bool discard}) =>
      _session.finishLineRecapture(discard: discard);

  @override
  void setAudioFallbackPolicy(GalAudioFallbackPolicy policy) =>
      _session.setAudioFallbackPolicy(policy);

  @override
  Future<void> setTextProcessPipeline(GalTextProcessPipeline pipeline) =>
      _session.setTextProcessPipeline(pipeline);

  @override
  bool? toggleLineFavorite(String lineId) {
    final TexthookerService service = TexthookerService.instance;
    if (service.entryById(lineId) == null) return null;
    return service.toggleLineFavorite(lineId);
  }

  @override
  void clearEvents() => _session.clearEvents();

  @override
  Future<void> setLookupMode(GalLookupSurfaceMode mode) =>
      _attached.setMode(mode);

  @override
  Future<void> clearLookupProfile() => _attached.clearProfile();

  @override
  GameCtlLookupState lookupState() {
    final GalAttachedTextController a = _attached;
    return GameCtlLookupState(
      target: a.target,
      currentClient: a.currentClient,
      executablePath: a.executablePath,
      executableSha256: a.executableSha256,
      profile: a.profile,
      status: a.status,
      statusReason: a.statusReason,
      sampleCalibrationEnabled: a.sampleCalibrationEnabled,
      canCaptureCalibrationSample: a.canCaptureCalibrationSample,
      calibrationActive: a.calibrationActive,
    );
  }

  @override
  Future<GalLookupCalibrationCapture> captureCalibrationSample() =>
      GalHookTextOverlayController.instance.captureCalibrationSample();

  @override
  Future<bool> applyMeasuredCalibration({
    required GalAttachedSurfaceTarget expectedTarget,
    required String expectedExeSha256,
    required GalLookupSurfaceVariantV1 variant,
  }) => _attached.applyMeasuredCalibration(
    expectedTarget: expectedTarget,
    expectedExeSha256: expectedExeSha256,
    variant: variant,
  );

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  // ── 游戏条目管理 ───────────────────────────────────────────────────────

  @override
  Future<void> setCustomData(String gameId, GalgameCustomData custom) =>
      _app.galgameRepo.setCustomData(gameId, custom);

  @override
  Future<void> setPlayStatus(String gameId, GalgamePlayStatus status) =>
      _app.galgameRepo.setPlayStatus(gameId, status);

  @override
  Future<void> updateEntry(GalgameEntry entry) =>
      _app.galgameRepo.updateEntry(entry);

  /// 库页「设置封面」去掉文件对话框：同一个 [MediaCoverService.applyGameCover]
  /// （拷盘 + 双键驱逐）→ `setCoverPath`。
  @override
  Future<String?> importCoverFile(String gameId, String sourcePath) async {
    final String? saved = await MediaCoverService.applyGameCover(
      gameId: gameId,
      sourcePath: sourcePath,
    );
    if (saved == null) return null;
    await _app.galgameRepo.setCoverPath(gameId, saved);
    return saved;
  }

  @override
  Future<String?> autoCover(GalgameEntry game) async {
    final ResolvedGameCover? resolved = await autoResolveGameCover(
      gameId: game.id,
      gameName: game.displayName,
      exePath: game.exePath,
      workdir: game.workdir,
    );
    if (resolved == null) return null;
    // 解析期间条目可能已被移除：仓储按 id 更新，行不在就不回填（库页同判据）。
    if (_app.galgameRepo.byId(game.id) == null) return null;
    await _app.galgameRepo.setCoverPath(game.id, resolved.path);
    return resolved.path;
  }

  @override
  Future<String?> removeGame(
    String gameId, {
    required bool deleteStatistics,
  }) async {
    String? statsError;
    if (deleteStatistics) {
      try {
        await _app.database.deleteGameStatisticsForId(gameId);
      } catch (e, stack) {
        ErrorLogService.instance.log('GameCtl.deleteGameStatistics', e, stack);
        statsError = '$e';
      }
    }
    await _app.galgameRepo.remove(gameId);
    return statsError;
  }

  @override
  Future<List<Map<String, Object?>>> sessions(
    String gameId, {
    required int limit,
    required int offset,
  }) async => <Map<String, Object?>>[
    for (final GalgameSessionRow row in await _app.galgameRepo.sessions(
      gameId,
      limit: limit,
      offset: offset,
    ))
      <String, Object?>{
        'id': row.id,
        'startMs': row.startMs,
        'endMs': row.endMs,
        'durationSeconds': row.durationSeconds,
        'dateKey': row.dateKey,
      },
  ];

  @override
  Future<void> deleteSession(int sessionId) =>
      _app.galgameRepo.deleteSession(sessionId);

  @override
  Future<GalgameScrapeSearchResult> scrapeSearch(
    String query, {
    Set<GalgameMetadataSource>? sources,
  }) => GalgameScrapeController.instance.search(query, sources: sources);

  @override
  Future<bool> applyScrape(String gameId, SourceCandidate candidate) =>
      applyGalgameScrapeCandidate(
        repo: _app.galgameRepo,
        gameId: gameId,
        candidate: candidate,
      );

  @override
  Future<List<String>> metadataSources(String gameId) async => <String>[
    for (final GalgameSourceRow row in await _app.galgameRepo.sourcesOf(gameId))
      row.source,
  ];

  @override
  Future<void> removeMetadataSource(
    String gameId,
    GalgameMetadataSource source,
  ) => _app.galgameRepo.removeSource(gameId, source);

  /// 游戏库「启动」（`galgame_home_page._launchGame` / `games_library_page`）去掉
  /// toast 的同一组步骤；helper 校验用无界面版本（与串流远程启动同一个）。
  @override
  Future<GameCtlLaunchReport> launch(GalgameEntry game) async {
    if (!File(game.exePath).existsSync()) {
      return const GameCtlLaunchReport.preflight(
        GameCtlLaunchPreflight.exeMissing,
      );
    }
    final bool is32Bit =
        await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
    final bool installed = await GalgameHelperInstaller()
        .ensureInjectorHeadless(is32Bit: is32Bit);
    if (!installed) {
      return const GameCtlLaunchReport.preflight(
        GameCtlLaunchPreflight.helperMissing,
      );
    }
    // TODO-2936 同款：语言级 / 「游戏」媒体类型的 Profile 绑定，非致命、与启动并行。
    unawaited(
      context.ref
          .read(profileViewModelProvider.notifier)
          .autoApplyBinding(
            languageTag: game.language,
            mediaType: ProfileMediaKind.game,
            restoreFallback: true,
          ),
    );
    final GalHookLaunchResult result = await _session.launchGame(
      game.exePath,
      launchArguments: game.launchArgumentTokens,
      workdir: game.workdir,
      gameId: game.id,
      gameTitle: game.displayName,
      japaneseLocaleMode: galJapaneseLocaleModeFromKey(game.japaneseLocaleMode),
      contentLanguage: game.language,
    );
    return GameCtlLaunchReport.launched(result);
  }

  @override
  Future<List<ExternalWindowInfo>> listWindows() =>
      WindowCaptureChannel.listWindows();

  /// 工作台 `_attachToRunningGame` 同一组步骤：Profile 绑定（不带语言、无绑定不回退）
  /// + `startAttachedCapture`。
  @override
  Future<void> attach(ExternalWindowInfo window) async {
    unawaited(
      context.ref
          .read(profileViewModelProvider.notifier)
          .autoApplyBinding(
            mediaType: ProfileMediaKind.game,
            restoreFallback: false,
          ),
    );
    await _session.startAttachedCapture(window);
  }

  @override
  Future<void> stop({required bool keepBinding}) =>
      _session.stopCapture(keepBinding: keepBinding);

  @override
  Future<bool> selectThread(TexthookerTextThread? thread) =>
      _session.selectTextThread(
        thread?.nativeThreadId,
        threadKey: thread?.key,
        // 与工作台线程下拉一致：用户主动选的线程写进本游戏记忆。
        remember: true,
      );

  @override
  String visibleText(TexthookerLineEntry entry) {
    final GalAttachedTextController attached =
        GalHookTextOverlayController.instance.attachedText;
    return galLookupVisibleHookLineText(
      source: entry.text,
      currentSession:
          _session.state.isActive && _session.isLineInCurrentSession(entry),
      sessionExecutable: _session.currentCaptureExecutable,
      attachedExecutable: attached.executablePath,
      attachedSha256: attached.executableSha256,
      profile: attached.profile,
      client: attached.currentClient,
    ).text;
  }

  @override
  Future<Map<String, String>> buildMineFields({
    required String word,
    required String sentence,
    String? reading,
    String? glossary,
    required bool lookup,
    required bool allowDuplicate,
  }) async {
    DictionarySearchResult? found;
    if (lookup && (reading == null || glossary == null)) {
      found = await _app.createRemoteLookupService().searchDictionary(
        term: word,
        wildcards: false,
        maximumTerms: 10,
      );
    }
    return buildCtlMineFields(
      word: word,
      reading: reading,
      sentence: sentence,
      glossary: glossary,
      lookup: found,
      allowDuplicate: allowDuplicate,
    );
  }

  /// 浮窗 `_mineFromLookup` 同一组偏好透传（两个 gal 制卡入口逐字同形）。
  @override
  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    required String sentence,
    int? updateNoteId,
  }) {
    final AppModel model = _app;
    return GalHookMiningCoordinator.instance.mineLine(
      lineId: lineId,
      fields: fields,
      sentenceOverride: sentence,
      compression: MiningMediaCompression.resolve(
        imageTier: model.miningImageQuality,
        audioTier: model.miningAudioQuality,
        format: model.galMiningAnimatedFormat,
      ),
      repo: model.miningAnkiRepository,
      updateNoteId: updateNoteId,
      addTitleTag: model.autoAddBookNameToTags,
      imageMode: model.galMiningImageMode,
      animatedFormat: model.galMiningAnimatedFormat,
      stillFormat: model.galMiningStillFormat,
      clipFormat: model.galMiningClipFormat,
    );
  }
}

// ── 路由处理 ──────────────────────────────────────────────────────────────

class _GameCtl {
  _GameCtl(this.host);

  final GameCtlHost host;

  void _requireHook() {
    if (!host.isWindows) {
      throw const CtlFailure.unsupported('Galgame Hook 只支持 Windows');
    }
    if (!host.gamesModuleEnabled) {
      throw const CtlFailure.rejected('「游戏」模块已关闭（设置 › 功能模块）');
    }
  }

  void _requireWritable() {
    if (host.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  static bool _sameExe(String? a, String b) =>
      a != null &&
      p.equals(p.normalize(a).toLowerCase(), p.normalize(b).toLowerCase());

  Future<GalgameEntry> _findGame(String id) async {
    final String trimmed = id.startsWith('game:') ? id.substring(5) : id;
    for (final GalgameEntry game in await host.loadGames()) {
      if (game.id == trimmed) return game;
    }
    throw CtlFailure.notFound('游戏库里没有 game:$trimmed（见 game ls）');
  }

  Map<String, Object?> _sessionJson(GameCtlSessionSnapshot snap) =>
      galHookCtlSessionJson(snap);

  // ── games ──────────────────────────────────────────────────────────────

  Future<Object?> listGames(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = host.snapshot();
    return <String, Object?>{
      'games': <Map<String, Object?>>[
        for (final GalgameEntry game in await host.loadGames())
          <String, Object?>{
            'id': game.id,
            'key': 'game:${game.id}',
            'title': game.displayName,
            'exePath': game.exePath,
            'exeExists': File(game.exePath).existsSync(),
            'running':
                snap.state.isActive &&
                _sameExe(snap.state.launchExe, game.exePath),
            if (game.language != null) 'language': game.language,
            'playSeconds': game.totalPlaySeconds,
            if (game.lastPlayedMs > 0) 'lastPlayedAt': game.lastPlayedMs,
          },
      ],
    };
  }

  // ── launch ─────────────────────────────────────────────────────────────

  Future<Object?> launch(CtlCall call) async {
    _requireHook();
    _requireWritable();
    final GalgameEntry game = await _findGame(call.requireString('id'));
    final GalHookSessionState before = host.snapshot().state;
    final bool otherRunning =
        before.isActive &&
        !_sameExe(
          before.launchExe ?? host.snapshot().captureExecutable,
          game.exePath,
        );
    if (otherRunning && call.optBool('replace') != true) {
      // 启动会先拆掉当前会话（文本 Hook、制卡、计时）。工作台按钮是用户当面点的，
      // CLI 可能是脚本误触：显式确认才替换。
      throw CtlFailure.conflict(
        '已有正在捕获的会话（${before.launchExe ?? before.boundWindow?.title ?? '外部窗口'}），'
        '替换需要 replace=true',
      );
    }
    final GameCtlLaunchReport report = await host.launch(game);
    final GameCtlSessionSnapshot after = host.snapshot();
    final GameCtlLaunchPreflight? preflight = report.preflight;
    if (preflight != null) {
      return <String, Object?>{
        'ok': false,
        'id': game.id,
        'title': game.displayName,
        'launched': false,
        'outcome': 'preflight_failed',
        'preflight': preflight.name,
        'message': switch (preflight) {
          GameCtlLaunchPreflight.exeMissing => '游戏 exe 不存在：${game.exePath}',
          GameCtlLaunchPreflight.helperMissing =>
            '捕获组件（随包 injector）未就绪或校验失败，未启动游戏',
        },
        'stages': galHookCtlStages(after),
      };
    }
    final GalHookLaunchResult result = report.result!;
    final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
      result: result,
      hasBoundWindow: after.state.boundWindow != null,
      injectorFailure: after.state.injectorFailure,
    );
    return <String, Object?>{
      'ok':
          outcome == GalHookLaunchOutcome.running ||
          outcome == GalHookLaunchOutcome.degradedLoopback,
      'id': game.id,
      'title': game.displayName,
      'launched': result.launched,
      'outcome': outcome.name,
      if (result.reason != null) 'reason': result.reason!.name,
      if (result.diagnostics.failure != GalHookInjectorFailure.none ||
          result.diagnostics.exitCode != null ||
          result.diagnostics.stderrTail.isNotEmpty)
        'diagnostics': <String, Object?>{
          'failure': result.diagnostics.failure.name,
          'exitCode': result.diagnostics.exitCode,
          'stderrTail': result.diagnostics.stderrTail,
        },
      'replacedSession': otherRunning,
      'session': _sessionJson(after),
      'stages': galHookCtlStages(after),
    };
  }

  // ── windows / attach / stop ────────────────────────────────────────────

  Future<Object?> listWindows(CtlCall call) async {
    _requireHook();
    final GalHookSessionState state = host.snapshot().state;
    final List<ExternalWindowInfo> windows = await host.listWindows();
    return <String, Object?>{
      'windows': <Map<String, Object?>>[
        for (final ExternalWindowInfo w in windows)
          <String, Object?>{
            'hwnd': w.hwnd,
            'pid': w.pid,
            'title': w.title,
            'currentGame': state.gamePid != null && w.pid == state.gamePid,
            'bound': state.boundWindow?.hwnd == w.hwnd,
          },
      ],
    };
  }

  Future<ExternalWindowInfo> _resolveWindow(CtlCall call) async {
    final int? hwnd = call.optInt('hwnd');
    final int? pid = call.optInt('pid');
    if ((hwnd == null) == (pid == null)) {
      throw const CtlFailure.badRequest('hwnd 与 pid 二选一');
    }
    final List<ExternalWindowInfo> windows = await host.listWindows();
    if (hwnd != null) {
      for (final ExternalWindowInfo w in windows) {
        if (w.hwnd == hwnd) return w;
      }
      throw CtlFailure.notFound('没有句柄为 $hwnd 的可捕获窗口（见 game windows）');
    }
    final List<ExternalWindowInfo> matched = windows
        .where((ExternalWindowInfo w) => w.pid == pid)
        .toList(growable: false);
    if (matched.isEmpty) {
      throw CtlFailure.notFound('进程 $pid 没有可捕获的顶层窗口（见 game windows）');
    }
    if (matched.length > 1) {
      throw CtlFailure.conflict(
        '进程 $pid 有 ${matched.length} 个窗口，请用 hwnd 指定：'
        '${matched.map((ExternalWindowInfo w) => '${w.hwnd}「${w.title}」').join(' ')}',
      );
    }
    return matched.single;
  }

  Future<Object?> attach(CtlCall call) async {
    _requireHook();
    _requireWritable();
    final ExternalWindowInfo window = await _resolveWindow(call);
    final GalHookSessionState before = host.snapshot().state;
    // 已在捕获这个窗口：重来一遍只会丢掉正在跑的 hook 与已收台词（与工作台同判据）。
    final bool already =
        before.isActive &&
        before.externalWindowMode &&
        before.boundWindow?.hwnd == window.hwnd;
    if (!already) await host.attach(window);
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': after.state.isActive,
      'alreadyAttached': already,
      'window': <String, Object?>{
        'hwnd': window.hwnd,
        'pid': window.pid,
        'title': window.title,
      },
      'session': _sessionJson(after),
      'stages': galHookCtlStages(after),
    };
  }

  Future<Object?> stop(CtlCall call) async {
    _requireHook();
    final bool unbind = call.optBool('unbind') ?? false;
    final bool wasActive = host.snapshot().state.isActive;
    await host.stop(keepBinding: !unbind);
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': !after.state.isActive,
      'wasActive': wasActive,
      'session': _sessionJson(after),
    };
  }

  // ── status ─────────────────────────────────────────────────────────────

  Future<Object?> status(CtlCall call) async {
    _requireHook();
    final int events = call.optInt('events') ?? 20;
    if (events < 0) throw const CtlFailure.badRequest('events 不能为负');
    final GameCtlSessionSnapshot snap = host.snapshot();
    final List<GalHookEvent> recent = snap.events.length <= events
        ? snap.events
        : snap.events.sublist(snap.events.length - events);
    return <String, Object?>{
      'session': _sessionJson(snap),
      'stages': galHookCtlStages(snap),
      'events': <Map<String, Object?>>[
        for (final GalHookEvent e in recent)
          <String, Object?>{
            'at': e.timestamp.toIso8601String(),
            'severity': e.severity.name,
            'stage': e.stage,
            'code': e.code,
            'summary': e.summary,
            if (e.details.isNotEmpty)
              'details': <String, Object?>{
                for (final MapEntry<String, Object?> d in e.details.entries)
                  d.key: _jsonSafe(d.value),
              },
          },
      ],
    };
  }

  // ── threads ────────────────────────────────────────────────────────────

  Future<Object?> listThreads(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = host.snapshot();
    return <String, Object?>{
      'active': snap.state.isActive,
      'selected': snap.selectedThreadKey,
      'threads': <Map<String, Object?>>[
        for (final TexthookerTextThread t in snap.textThreads)
          galHookCtlThreadJson(t, selected: t.key == snap.selectedThreadKey),
      ],
    };
  }

  Future<Object?> selectThread(CtlCall call) async {
    _requireHook();
    final bool clear = call.optBool('clear') ?? false;
    final String? key = call.optString('key');
    if (clear == (key != null)) {
      throw const CtlFailure.badRequest('key 与 clear=true 二选一');
    }
    final GameCtlSessionSnapshot snap = host.snapshot();
    if (!snap.state.isActive) {
      throw const CtlFailure.conflict(
        '没有正在进行的捕获会话（先 game launch / game attach）',
      );
    }
    TexthookerTextThread? thread;
    if (key != null) {
      thread = snap.textThreads.cast<TexthookerTextThread?>().firstWhere(
        (TexthookerTextThread? t) => t!.key == key,
        orElse: () => null,
      );
      if (thread == null) {
        throw CtlFailure.notFound('本会话没有线程 $key（见 game threads）');
      }
    }
    final bool selected = await host.selectThread(thread);
    if (!selected) {
      // native helper 拒绝切换（线程已失效等）：如实返回失败，不改 app 侧选择。
      throw CtlFailure.conflict('捕获组件拒绝切换到线程 ${key ?? '（清除）'}');
    }
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': true,
      'selected': after.selectedThreadKey,
      if (thread != null)
        'thread': galHookCtlThreadJson(thread, selected: true),
    };
  }

  // ── text ───────────────────────────────────────────────────────────────

  Future<Object?> text(CtlCall call) async {
    _requireHook();
    final int limit = call.optInt('limit') ?? 1;
    if (limit < 1) throw const CtlFailure.badRequest('limit 至少为 1');
    final GameCtlSessionSnapshot snap = host.snapshot();
    final List<TexthookerLineEntry> lines = snap.sessionLines;
    final List<TexthookerLineEntry> recent = lines.length <= limit
        ? lines
        : lines.sublist(lines.length - limit);
    return <String, Object?>{
      'active': snap.state.isActive,
      'selectedThread': snap.selectedThreadKey,
      'current': lines.isEmpty ? null : _lineJson(lines.last),
      'lines': <Map<String, Object?>>[
        for (final TexthookerLineEntry line in recent) _lineJson(line),
      ],
      if (lines.isEmpty)
        'hint': snap.textThreads.isNotEmpty && snap.selectedThreadKey == null
            ? '已出现候选文本线程但尚未选择（game threads / game select <key>）'
            : '本会话还没有可用台词',
    };
  }

  Map<String, Object?> _lineJson(TexthookerLineEntry line) {
    final String visible = host.visibleText(line);
    return galHookCtlLineJson(line, visibleText: visible);
  }

  // ── mine ───────────────────────────────────────────────────────────────

  Future<Object?> mine(CtlCall call) async {
    _requireHook();
    _requireWritable();
    final String word = call.requireString('word');
    final GameCtlSessionSnapshot snap = host.snapshot();
    if (!snap.state.isActive) {
      throw const CtlFailure.conflict(
        '没有正在进行的捕获会话（先 game launch / game attach）',
      );
    }
    final List<TexthookerLineEntry> lines = snap.sessionLines;
    if (lines.isEmpty) {
      throw const CtlFailure.conflict('本会话没有可制卡的台词（未选文本线程或尚未收到台词）');
    }
    final String? lineId = call.optString('lineId');
    final TexthookerLineEntry entry;
    if (lineId == null) {
      entry = lines.last;
    } else {
      final TexthookerLineEntry? found = lines
          .cast<TexthookerLineEntry?>()
          .firstWhere(
            (TexthookerLineEntry? l) => l!.id == lineId,
            orElse: () => null,
          );
      if (found == null) {
        throw CtlFailure.notFound('台词 $lineId 不在当前会话 / 当前线程里（见 game text）');
      }
      entry = found;
    }
    final String sentence = host.visibleText(entry);
    final Map<String, String> fields = await host.buildMineFields(
      word: word,
      sentence: sentence,
      reading: call.optString('reading'),
      glossary: call.optString('glossary'),
      lookup: call.optBool('lookup') ?? true,
      allowDuplicate: call.optBool('allowDuplicate') ?? false,
    );
    final GalHookMiningResult result = await host.mineLine(
      lineId: entry.id,
      fields: fields,
      sentence: sentence,
      updateNoteId: call.optInt('updateNoteId'),
    );
    final MineOutcome? outcome = result.outcome;
    return <String, Object?>{
      'ok': result.success || result.queued,
      'result': outcome?.result.name ?? 'aborted',
      'lineId': entry.id,
      'sentence': sentence,
      'expression': fields['expression'],
      'reading': fields['reading'],
      'glossaryFilled': (fields['glossary'] ?? '').isNotEmpty,
      if (outcome?.noteId != null) 'noteId': outcome!.noteId,
      if (outcome?.deckName != null) 'deckName': outcome!.deckName,
      if (outcome?.errorDetail != null) 'errorDetail': outcome!.errorDetail,
      if (outcome?.audioWarning != null) 'audioWarning': outcome!.audioWarning,
      if (result.failureReason != null) 'failureReason': result.failureReason,
      'duplicate': result.duplicate,
      'queued': result.queued,
      'sentenceAudioMissing': result.sentenceAudioMissing,
      'audioFallbackDisabled': result.audioFallbackDisabled,
      'degradedToStill': result.degradedToStill,
      'degradedToAnimated': result.degradedToAnimated,
      'staleScene': result.staleScene,
      if (result.unmappedTokens.isNotEmpty)
        'unmappedTokens': result.unmappedTokens,
    };
  }

  // ── 工作台细项 ─────────────────────────────────────────────────────────

  GameCtlSessionSnapshot _requireSession() {
    final GameCtlSessionSnapshot snap = host.snapshot();
    if (!snap.state.isActive) {
      throw const CtlFailure.conflict(
        '没有正在进行的捕获会话（先 game launch / game attach）',
      );
    }
    return snap;
  }

  /// 选轨 / 排除 / 逐轨试听都只对引擎 hook 源有意义（会话控制器在没有引擎源时
  /// 只记一条警告事件，不改任何状态）：这里先挡住，避免 CLI 拿到「成功」却什么都没变。
  GameCtlSessionSnapshot _requireEngine() {
    final GameCtlSessionSnapshot snap = _requireSession();
    if (!snap.hasEngineSource) {
      throw const CtlFailure.conflict('音轨操作需要引擎 hook 会话（当前没有引擎 hook 源）');
    }
    return snap;
  }

  /// 逐句操作只接受当前会话、当前线程放行的行（与工作台列表同一份）。
  TexthookerLineEntry _sessionLine(GameCtlSessionSnapshot snap, String id) {
    for (final TexthookerLineEntry line in snap.sessionLines) {
      if (line.id == id) return line;
    }
    throw CtlFailure.notFound('台词 $id 不在当前会话 / 当前线程里（见 game text）');
  }

  int _requirePtr(CtlCall call) {
    final int? ptr = call.optInt('ptr');
    if (ptr == null || ptr <= 0) {
      throw const CtlFailure.badRequest('ptr 缺失或不是正整数（见 game tracks）');
    }
    return ptr;
  }

  void _requireKnownTrack(GameCtlSessionSnapshot snap, int ptr) {
    if (!snap.state.audioTracks.any((GalAudioTrack t) => t.sourcePtr == ptr)) {
      throw CtlFailure.notFound('会话音轨里没有 $ptr（先 game tracks 刷新）');
    }
  }

  Future<Map<String, Object?>> _previewJson(
    GalTrackPreview? preview, {
    required bool play,
    required String failure,
  }) async {
    if (preview == null) throw CtlFailure.conflict(failure);
    final bool played = play && await host.playAudioFile(preview.filePath);
    return <String, Object?>{
      'ok': !play || played,
      'filePath': preview.filePath,
      'durationMs': preview.durationMs,
      'played': played,
      if (play && !played) 'message': 'app 内播放失败（文件仍可直接打开）',
    };
  }

  Future<Object?> configureGame(CtlCall call) async {
    _requireHook();
    _requireWritable();
    final GalgameEntry game = await _findGame(call.params['id']!);
    final String? locale = call.optString('locale')?.toLowerCase();
    final String? upscaling = call.optString('upscaling');
    final String? language = call.optString('language');
    final bool clearLanguage = call.optBool('clearLanguage') ?? false;
    if (locale == null &&
        upscaling == null &&
        language == null &&
        !clearLanguage) {
      throw const CtlFailure.badRequest(
        '至少给一项：locale / upscaling / language / clearLanguage',
      );
    }
    if (language != null && clearLanguage) {
      throw const CtlFailure.badRequest('language 与 clearLanguage 二选一');
    }
    String? localeKey;
    if (locale != null) {
      final Set<String> keys = <String>{
        for (final GalJapaneseLocaleMode m in GalJapaneseLocaleMode.values)
          galJapaneseLocaleModeToKey(m),
      };
      if (!keys.contains(locale)) {
        throw CtlFailure.badRequest('locale 只能是 ${keys.join(' | ')}：$locale');
      }
      localeKey = locale;
    }
    String? upscalingKey;
    if (upscaling != null) {
      // 接受持久化键（installed_only）与枚举名（installedOnly），大小写不敏感。
      final Map<String, String> accepted = <String, String>{
        for (final MagpieUpscalingMode m in MagpieUpscalingMode.values) ...{
          magpieUpscalingModeToKey(m): magpieUpscalingModeToKey(m),
          m.name.toLowerCase(): magpieUpscalingModeToKey(m),
        },
      };
      upscalingKey = accepted[upscaling.toLowerCase()];
      if (upscalingKey == null) {
        throw CtlFailure.badRequest(
          'upscaling 只能是 ${MagpieUpscalingMode.values.map(magpieUpscalingModeToKey).join(' | ')}：$upscaling',
        );
      }
    }
    if (localeKey != null) {
      await host.setGameJapaneseLocaleMode(game.id, localeKey);
    }
    if (upscalingKey != null) {
      await host.setGameUpscalingMode(game.id, upscalingKey);
    }
    if (language != null || clearLanguage) {
      await host.setGameLanguage(game.id, clearLanguage ? null : language);
    }
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{
      'ok': true,
      'id': updated.id,
      'title': updated.displayName,
      'locale': galJapaneseLocaleModeToKey(
        galJapaneseLocaleModeFromKey(updated.japaneseLocaleMode),
      ),
      'upscaling': magpieUpscalingModeToKey(
        magpieUpscalingModeFromKey(updated.upscalingMode),
      ),
      'language': updated.language,
      // 两项都是启动期配置：转区在拉起游戏时套、Magpie 只在启动时读一次配置。
      'appliesTo': 'next_launch',
    };
  }

  Future<Object?> bind(CtlCall call) async {
    _requireHook();
    final bool clear = call.optBool('clear') ?? false;
    ExternalWindowInfo? window;
    if (clear) {
      if (call.optInt('hwnd') != null || call.optInt('pid') != null) {
        throw const CtlFailure.badRequest('clear 不能和 hwnd / pid 同时给');
      }
    } else {
      window = await _resolveWindow(call);
      final GalHookSessionState state = host.snapshot().state;
      // 选回已绑定的窗口是 no-op（工作台同判据）：捕获模式下重绑会重启整条会话。
      if (state.boundWindow?.hwnd == window.hwnd) {
        return <String, Object?>{
          'ok': true,
          'unchanged': true,
          'session': _sessionJson(host.snapshot()),
        };
      }
    }
    await host.bindWindow(window);
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': clear
          ? after.state.boundWindow == null
          : after.state.boundWindow?.hwnd == window!.hwnd,
      'session': _sessionJson(after),
    };
  }

  Future<Object?> setWindowMode(CtlCall call) async {
    _requireHook();
    final bool? enabled = call.optBool('enabled');
    if (enabled == null) throw const CtlFailure.badRequest('enabled 缺失');
    await host.setExternalWindowMode(enabled);
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': after.state.externalWindowMode == enabled,
      'enabled': after.state.externalWindowMode,
      if (enabled && after.state.boundWindow == null)
        'hint': '已开启，但还没绑定窗口（game bind --hwnd <句柄>）',
      'session': _sessionJson(after),
    };
  }

  Future<Object?> listTracks(CtlCall call) async {
    _requireHook();
    if (call.optBool('refresh') ?? true) await host.refreshAudioTracks();
    final GameCtlSessionSnapshot snap = host.snapshot();
    final GalHookSessionState s = snap.state;
    return <String, Object?>{
      'engineSource': snap.hasEngineSource,
      'backend': s.audioBackend.name,
      // 只有引擎 PCM 是当前音源时，会话级选轨才影响制卡取音（BUG-1102）。
      'selectionAffectsCapture': galTrackSelectionAffectsCapture(
        s.audioBackend,
      ),
      'selected': s.selectedAudioSourcePtr == 0
          ? null
          : s.selectedAudioSourcePtr,
      'tracks': <Map<String, Object?>>[
        for (final GalAudioTrack t in s.audioTracks)
          galHookCtlTrackJson(
            t,
            selected: t.sourcePtr == s.selectedAudioSourcePtr,
            excluded: s.excludedAudioSourcePtrs.contains(t.sourcePtr),
          ),
      ],
      if (s.audioTracks.isEmpty)
        'emptyHint': galTrackEmptyHintFor(s.audioBackend).name,
    };
  }

  Future<Object?> selectTrack(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireEngine();
    final int ptr = _requirePtr(call);
    _requireKnownTrack(snap, ptr);
    host.selectVoiceTrack(ptr);
    final GameCtlSessionSnapshot after = host.snapshot();
    final bool affects = galTrackSelectionAffectsCapture(
      after.state.audioBackend,
    );
    return <String, Object?>{
      'ok': after.state.selectedAudioSourcePtr == ptr,
      'selected': after.state.selectedAudioSourcePtr,
      'selectionAffectsCapture': affects,
      if (!affects)
        'note': '当前音频后端是 ${after.state.audioBackend.name}，会话级选轨不影响制卡取音',
    };
  }

  Future<Object?> excludeTrack(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireEngine();
    final int ptr = _requirePtr(call);
    _requireKnownTrack(snap, ptr);
    final bool excluded = call.optBool('excluded') ?? true;
    host.setTrackExcluded(ptr, excluded);
    final Set<int> now = host.snapshot().state.excludedAudioSourcePtrs;
    return <String, Object?>{
      'ok': now.contains(ptr) == excluded,
      'ptr': ptr,
      'excluded': now.contains(ptr),
    };
  }

  Future<Object?> previewTrack(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireEngine();
    final int ptr = _requirePtr(call);
    final String? lineId = call.optString('lineId');
    final GalTrackPreview? preview;
    if (lineId != null) {
      _sessionLine(snap, lineId);
      preview = await host.exportLineTrackPreview(lineId, ptr);
    } else {
      preview = await host.exportTrackPreview(ptr);
    }
    return <String, Object?>{
      'ptr': ptr,
      'lineId': ?lineId,
      ...await _previewJson(
        preview,
        play: call.optBool('play') ?? false,
        failure: '没取到这条轨的试听音频（尚无台词时间戳，或该轨在窗口内没有 PCM；见 game status 事件）',
      ),
    };
  }

  Future<Object?> stopAudio(CtlCall call) async {
    _requireHook();
    await host.stopAudio();
    return <String, Object?>{'ok': true};
  }

  Future<Object?> setAudioPolicy(CtlCall call) async {
    _requireHook();
    final String raw = call.requireString('policy');
    final GalAudioFallbackPolicy? policy = GalAudioFallbackPolicy.values
        .cast<GalAudioFallbackPolicy?>()
        .firstWhere(
          (GalAudioFallbackPolicy? p) =>
              p!.storageKey.toLowerCase() == raw.toLowerCase(),
          orElse: () => null,
        );
    if (policy == null) {
      throw CtlFailure.badRequest(
        'policy 只能是 ${GalAudioFallbackPolicy.values.map((GalAudioFallbackPolicy p) => p.storageKey).join(' | ')}：$raw',
      );
    }
    host.setAudioFallbackPolicy(policy);
    final GalAudioFallbackPolicy now = host
        .snapshot()
        .state
        .audioFallbackPolicy;
    return <String, Object?>{
      'ok': now == policy,
      'policy': now.storageKey,
      'allowsEnginePcm': now.allowsEnginePcm,
      'allowsLoopback': now.allowsLoopback,
      'blocksMiningWhenMissing': now.blocksMiningWhenMissing,
    };
  }

  Future<Object?> lineTracks(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireSession();
    final TexthookerLineEntry line = _sessionLine(snap, call.params['id']!);
    final List<GalAudioTrack> tracks = await host.tracksForLine(line.id);
    final int? chosen = host.lineVoiceSourcePtr(line.id);
    return <String, Object?>{
      'lineId': line.id,
      'audioBackend': line.audioBackend,
      'chosen': chosen,
      'tracks': <Map<String, Object?>>[
        for (final GalAudioTrack t in tracks)
          galHookCtlTrackJson(
            t,
            selected: t.sourcePtr == chosen,
            excluded: snap.state.excludedAudioSourcePtrs.contains(t.sourcePtr),
          ),
      ],
      if (line.audioBackend == 'game_resource')
        'note': '这句语音来自游戏资源直提，PCM 轨与它无关',
    };
  }

  Future<Object?> setLineTrack(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireEngine();
    final TexthookerLineEntry line = _sessionLine(snap, call.params['id']!);
    final int ptr = _requirePtr(call);
    final bool ok = await host.setLineVoiceTrack(line.id, ptr);
    if (!ok) {
      throw CtlFailure.conflict('轨 $ptr 在这句的时间窗内没有 PCM，未改动该句音频');
    }
    return <String, Object?>{
      'ok': true,
      'lineId': line.id,
      'chosen': host.lineVoiceSourcePtr(line.id),
      'line': _lineJson(_sessionLine(host.snapshot(), line.id)),
    };
  }

  Future<Object?> previewLine(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireSession();
    final TexthookerLineEntry line = _sessionLine(snap, call.params['id']!);
    return <String, Object?>{
      'lineId': line.id,
      ...await _previewJson(
        await host.exportLineAudioPreview(line.id),
        play: call.optBool('play') ?? false,
        failure: '这句还没有可试听的音频（audioStatus=${line.audioStatus.name}）',
      ),
    };
  }

  Future<Object?> recaptureLine(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireSession();
    final TexthookerLineEntry line = _sessionLine(snap, call.params['id']!);
    final String action = call.requireString('action').toLowerCase();
    switch (action) {
      case 'start':
        if (snap.recapturingLineId != null) {
          throw CtlFailure.conflict(
            '台词 ${snap.recapturingLineId} 正在补录，先 finish / discard',
          );
        }
        if (!await host.startLineRecapture(line.id)) {
          throw const CtlFailure.conflict('补录没能开始（见 game status 事件）');
        }
        return <String, Object?>{
          'ok': true,
          'lineId': line.id,
          'recapturing': true,
          'hint': '在游戏里重播这句语音，然后 game recapture <id> finish',
        };
      case 'finish' || 'discard':
        if (snap.recapturingLineId != line.id) {
          throw CtlFailure.conflict(
            snap.recapturingLineId == null
                ? '没有正在进行的补录'
                : '正在补录的是 ${snap.recapturingLineId}，不是 ${line.id}',
          );
        }
        final bool ok = await host.finishLineRecapture(
          discard: action == 'discard',
        );
        final GameCtlSessionSnapshot after = host.snapshot();
        TexthookerLineEntry? updated;
        for (final TexthookerLineEntry l in after.sessionLines) {
          if (l.id == line.id) updated = l;
        }
        return <String, Object?>{
          'ok': ok,
          'lineId': line.id,
          'discarded': action == 'discard',
          if (updated != null) 'line': _lineJson(updated),
        };
    }
    throw CtlFailure.badRequest('action 只能是 start | finish | discard：$action');
  }

  Future<Object?> favoriteLine(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireSession();
    final TexthookerLineEntry line = _sessionLine(snap, call.params['id']!);
    final bool? favorited = host.toggleLineFavorite(line.id);
    if (favorited == null) throw CtlFailure.notFound('台词 ${line.id} 已不在缓冲里');
    return <String, Object?>{
      'ok': true,
      'lineId': line.id,
      'favorited': favorited,
    };
  }

  Future<Object?> getTextProcess(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = host.snapshot();
    return <String, Object?>{
      'selectedThread': snap.selectedThreadKey,
      'pipeline': snap.textProcessPipeline.toJson(),
      'active': snap.textProcessPipeline.isNotEmpty,
    };
  }

  Future<Object?> setTextProcess(CtlCall call) async {
    _requireHook();
    final GameCtlSessionSnapshot snap = _requireSession();
    // 工作台同一道门：管线按所选线程编排，没选线程时编辑器是禁用的。
    if (snap.selectedThreadKey == null) {
      throw const CtlFailure.conflict('先选文本线程（game select <key>）再设置文本处理');
    }
    final Object? raw = call.body['pipeline'];
    if (raw is! List) {
      throw const CtlFailure.badRequest(
        'pipeline 必须是步骤数组（格式同 game textproc 输出）',
      );
    }
    // fromJson 把未知 kind 静默当成 filterControlChars：CLI 输入先逐步核对 kind。
    for (final Object? step in raw) {
      final Object? kind = step is Map ? step['kind'] : null;
      if (kind is! String || GalTextProcessKind.fromStorageKey(kind) == null) {
        throw CtlFailure.badRequest(
          '未知的文本处理步骤 kind：$kind（可选 '
          '${GalTextProcessKind.values.map((GalTextProcessKind k) => k.storageKey).join(' | ')}）',
        );
      }
    }
    final GalTextProcessPipeline pipeline = GalTextProcessPipeline.fromJson(
      raw,
    );
    // fromJson 对坏步骤是「丢掉继续读」——存档容错可以，CLI 输入不能静默丢步骤。
    if (pipeline.steps.length != raw.length) {
      throw CtlFailure.badRequest(
        'pipeline 里有 ${raw.length - pipeline.steps.length} 个步骤无法解析'
        '（字段类型不对或 id 重复），未保存',
      );
    }
    await host.setTextProcessPipeline(pipeline);
    final GalTextProcessPipeline now = host.snapshot().textProcessPipeline;
    return <String, Object?>{
      'ok': now == pipeline,
      'selectedThread': snap.selectedThreadKey,
      'pipeline': now.toJson(),
    };
  }

  Future<Object?> clearEvents(CtlCall call) async {
    _requireHook();
    host.clearEvents();
    return <String, Object?>{'ok': host.snapshot().events.isEmpty};
  }

  Map<String, Object?> _lookupModeJson(GameCtlSessionSnapshot snap) =>
      <String, Object?>{
        'executable': snap.attachedExecutable,
        'mode': (snap.attachedMode ?? GalLookupSurfaceMode.auto).wireName,
        'hasProfile': snap.attachedMode != null,
      };

  Future<Object?> getLookupMode(CtlCall call) async {
    _requireHook();
    return _lookupModeJson(host.snapshot());
  }

  Future<Object?> setLookupMode(CtlCall call) async {
    _requireHook();
    final String raw = call.requireString('mode');
    final GalLookupSurfaceMode? mode = GalLookupSurfaceMode.fromWireName(raw);
    if (mode == null) {
      throw CtlFailure.badRequest(
        'mode 只能是 ${GalLookupSurfaceMode.values.map((GalLookupSurfaceMode m) => m.wireName).join(' | ')}：$raw',
      );
    }
    if (host.snapshot().attachedExecutable == null) {
      throw const CtlFailure.conflict('内嵌查词还没有附着到游戏（先启动 / 附着并等游戏窗口出现）');
    }
    await host.setLookupMode(mode);
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': after.attachedMode == mode,
      ..._lookupModeJson(after),
    };
  }

  Future<Object?> clearLookupProfile(CtlCall call) async {
    _requireHook();
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('清除内嵌查词校准需要 confirm=true');
    }
    if (host.snapshot().attachedExecutable == null) {
      throw const CtlFailure.conflict('内嵌查词还没有附着到游戏');
    }
    await host.clearLookupProfile();
    final GameCtlSessionSnapshot after = host.snapshot();
    return <String, Object?>{
      'ok': after.attachedMode == null,
      ..._lookupModeJson(after),
    };
  }

  // ── 游戏条目管理 ───────────────────────────────────────────────────────

  // ── 内嵌查词截图校准 ───────────────────────────────────────────────────

  /// 最近一次 `game screenshot` 的截图样本：`lookup-calibrate --from-screenshot`
  /// 用它的参考客户区与截图元数据做投影（工作台样本对话框同一套 draft 语义）。
  GalLookupCalibrationCapture? _lastCapture;

  Map<String, Object?> _lookupStateJson(GameCtlLookupState s) =>
      <String, Object?>{
        'executable': s.executablePath,
        'status': s.status.name,
        if (s.statusReason != null) 'statusReason': s.statusReason,
        'mode': (s.profile?.mode ?? GalLookupSurfaceMode.auto).wireName,
        'sampleCalibrationEnabled': s.sampleCalibrationEnabled,
        'canCaptureSample': s.canCaptureCalibrationSample,
        'calibrationActive': s.calibrationActive,
        if (s.currentClient != null) 'currentClient': s.currentClient!.toJson(),
        if (s.target != null) 'targetHwnd': s.target!.targetHwnd,
        'profile': s.profile?.toJson(),
        if (_lastCapture != null)
          'lastScreenshot': <String, Object?>{
            'capturedAt': _lastCapture!.capturedAt.toIso8601String(),
            'referenceClient': _lastCapture!.referenceClient.toJson(),
          },
      };

  Future<Object?> getLookupProfile(CtlCall call) async {
    _requireHook();
    return _lookupStateJson(host.lookupState());
  }

  Future<Object?> screenshot(CtlCall call) async {
    _requireHook();
    final GameCtlLookupState state = host.lookupState();
    if (!state.canCaptureCalibrationSample) {
      throw CtlFailure.conflict(
        '现在不能截取校准样本（内嵌查词状态 ${state.status.name}'
        '${state.statusReason == null ? '' : ' / ${state.statusReason}'}；'
        '需要已附着的游戏、auto 或 attachedOnly 模式、且不在实点校准中）',
      );
    }
    final GalLookupCalibrationCapture capture;
    try {
      capture = await host.captureCalibrationSample();
    } on GalLookupCalibrationCaptureException catch (e) {
      throw CtlFailure.conflict(
        '截图失败：${e.failure.name}'
        '${e.captureReason == null ? '' : '（${e.captureReason}）'}',
      );
    }
    final String path =
        call.optString('output') ??
        p.join(
          Directory.systemTemp.path,
          'fushi_cli',
          'gal_screenshot_${capture.capturedAt.millisecondsSinceEpoch}.png',
        );
    await host.writeFile(path, capture.pngBytes);
    _lastCapture = capture;
    return <String, Object?>{
      'ok': true,
      'path': path,
      'widthPx': capture.referenceClient.widthPx,
      'heightPx': capture.referenceClient.heightPx,
      'dpi': capture.referenceClient.dpi,
      'sourceText': capture.sourceText,
      'capturedAt': capture.capturedAt.toIso8601String(),
      'presentationCapture':
          capture.captureMetadata?.usedPresentationCapture ?? false,
      'hint':
          '在截图上量正文框：game lookup-calibrate --from-screenshot --px '
          '--rect x,y,w,h --grid 字距,行距,字高,列数（像素按截图尺寸）',
    };
  }

  static List<double> _numbers(String raw, String name, int count) {
    final List<String> parts = raw.split(',');
    final List<double> out = <double>[
      for (final String part in parts)
        double.tryParse(part.trim()) ?? double.nan,
    ];
    if (out.length != count || out.any((double v) => !v.isFinite)) {
      throw CtlFailure.badRequest('$name 应为 $count 个逗号分隔的数字：$raw');
    }
    return out;
  }

  GalLookupTextLayoutV1 _calibrationLayout(CtlCall call, {int? pxHeight}) {
    final Object? rawLayout = call.body['layout'];
    final GalLookupTextLayoutV1 layout;
    if (rawLayout != null) {
      if (call.optString('grid') != null) {
        throw const CtlFailure.badRequest('layout 与 grid 二选一');
      }
      final GalLookupTextLayoutV1? parsed = GalLookupTextLayoutV1.tryFromJson(
        rawLayout,
      );
      if (parsed == null) {
        throw const CtlFailure.badRequest(
          'layout 不是合法的版式 JSON（格式同 game lookup-profile 里 variants[].layout）',
        );
      }
      layout = parsed;
    } else {
      final String? grid = call.optString('grid');
      if (grid == null) {
        throw const CtlFailure.badRequest(
          '缺少字格：grid=字距,行距,字高,列数（均按客户区高度归一，列数为整数）或 layout JSON',
        );
      }
      final List<double> g = _numbers(grid, 'grid', 4);
      if (g[3] != g[3].roundToDouble()) {
        throw CtlFailure.badRequest('grid 的列数必须是整数：${g[3]}');
      }
      // px 模式下字距 / 行距 / 字高 / 字号按客户区高度换算成归一值（缩进单位是字格，不换算）。
      final double scale = pxHeight == null ? 1 : 1 / pxHeight;
      final double? fontSize = _optDouble(call, 'fontSize');
      final double indent = _optDouble(call, 'indent') ?? 0;
      layout = GalLookupTextLayoutV1(
        fontSizePerClientHeight: (fontSize ?? g[2]) * scale,
        quotedTextOnly: call.optBool('quotedOnly') ?? false,
        cellGrid: GalLookupCellGridV1(
          advancePerClientHeight: g[0] * scale,
          lineAdvancePerClientHeight: g[1] * scale,
          cellHeightPerClientHeight: g[2] * scale,
          columns: g[3].toInt(),
          continuationIndent: indent,
          quotedContinuationIndent: _optDouble(call, 'quotedIndent') ?? indent,
          explicitLineBreaks: call.optBool('explicitLineBreaks') ?? false,
        ),
      );
    }
    // 没有字格的版式在工作台里会转去「实点三个探针」的现场校准——那要用户在游戏里
    // 真点字，CLI 代替不了，也不能伪造探针观测。
    if (layout.cellGrid == null) {
      throw const CtlFailure.badRequest(
        '版式缺少 cellGrid：无字格的校准需要在游戏里实点探针，CLI 不支持',
      );
    }
    if (!layout.isValid) {
      throw const CtlFailure.badRequest(
        '版式数值越界（字距/行距/字高须在 0.001–0.25，行距 ≥ 字高，列数 2–128）',
      );
    }
    return layout;
  }

  static double? _optDouble(CtlCall call, String name) {
    final String? raw = call.optString(name);
    if (raw == null) return null;
    final double? v = double.tryParse(raw);
    if (v == null || !v.isFinite) {
      throw CtlFailure.badRequest('$name 必须是数字：$raw');
    }
    return v;
  }

  Future<Object?> calibrateLookup(CtlCall call) async {
    _requireHook();
    _requireWritable();
    final GameCtlLookupState state = host.lookupState();
    if (!state.sampleCalibrationEnabled) {
      throw const CtlFailure.conflict(
        '内嵌查词模式不允许截图校准（先 game lookup-mode auto 或 attachedOnly）',
      );
    }
    final GalAttachedSurfaceTarget? target = state.target;
    final String? sha = state.executableSha256;
    final GalLookupReferenceClientV1? current = state.currentClient;
    if (target == null || sha == null || current == null) {
      throw const CtlFailure.conflict('内嵌查词还没有附着到游戏窗口');
    }
    if (state.calibrationActive) {
      throw const CtlFailure.conflict('工作台里正在进行实点校准，先完成或取消');
    }
    final bool fromScreenshot = call.optBool('fromScreenshot') ?? false;
    GalLookupReferenceClientV1 client = current;
    WindowCaptureMetadata? metadata;
    if (fromScreenshot) {
      final GalLookupCalibrationCapture? capture = _lastCapture;
      if (capture == null) {
        throw const CtlFailure.conflict('还没有截图样本（先 game screenshot）');
      }
      if (capture.exeSha256 != sha || capture.targetHwnd != target.targetHwnd) {
        throw const CtlFailure.conflict('截图样本不属于当前游戏窗口，重新 game screenshot');
      }
      client = capture.referenceClient;
      metadata = capture.captureMetadata;
    }
    final List<double> r = _numbers(call.requireString('rect'), 'rect', 4);
    final bool px = call.optBool('px') ?? false;
    final GalLookupNormalizedRectV1 rect = px
        ? GalLookupNormalizedRectV1(
            left: r[0] / client.widthPx,
            top: r[1] / client.heightPx,
            width: r[2] / client.widthPx,
            height: r[3] / client.heightPx,
          )
        : GalLookupNormalizedRectV1(
            left: r[0],
            top: r[1],
            width: r[2],
            height: r[3],
          );
    if (!rect.isValid) {
      throw CtlFailure.badRequest(
        'rect 超出客户区（归一化后须在 0–1 内且宽高 > 0）：${rect.toJson()}',
      );
    }
    final String? slotRaw = call.optString('slot');
    final GalLookupCalibrationSlotV1? slot = slotRaw == null
        ? null
        : GalLookupCalibrationSlotV1.fromWireName(slotRaw) ??
              (throw CtlFailure.badRequest(
                'slot 只能是 dialogue | narration：$slotRaw',
              ));
    final GalLookupTextLayoutV1 layout = _calibrationLayout(
      call,
      pxHeight: px ? client.heightPx : null,
    );
    // 落库会把 unsafeLeftClickAccepted 记为 true：工作台首次校准要过风险确认框，
    // CLI 等价物是显式 acceptRisk。
    if (state.profile?.unsafeLeftClickAccepted != true &&
        call.optBool('acceptRisk') != true) {
      throw const CtlFailure.badRequest(
        '首次校准需要 acceptRisk=true：点击内嵌查词层的左键会被吞掉、不再传给游戏',
      );
    }
    final GalLookupSurfaceVariantV1? variant = projectGalCalibrationToSource(
      client: client,
      rect: rect,
      layout: layout,
      metadata: metadata,
      slot: slot,
    );
    if (variant == null) {
      throw const CtlFailure.badRequest('无法把这组几何投影到游戏客户区（截图缺少源客户区映射）');
    }
    if (variant.relativeAspectError(current.aspectRatio) >
        GalLookupSurfaceProfileV1.maxRelativeAspectError) {
      throw CtlFailure.conflict(
        '参考客户区比例（${variant.referenceClient.widthPx}×'
        '${variant.referenceClient.heightPx}）与当前游戏窗口（${current.widthPx}×'
        '${current.heightPx}）不一致',
      );
    }
    final bool applied = await host.applyMeasuredCalibration(
      expectedTarget: target,
      expectedExeSha256: sha,
      variant: variant,
    );
    final GameCtlLookupState after = host.lookupState();
    return <String, Object?>{
      'ok': applied,
      'variant': variant.toJson(),
      if (!applied)
        'message':
            '校准没有生效（状态 ${after.status.name}'
            '${after.statusReason == null ? '' : ' / ${after.statusReason}'}；'
            '常见原因：还没有当前台词、截图后游戏窗口变了、捕获租约占用）',
      ..._lookupStateJson(after),
    };
  }

  /// 最近一次 `game scrape` 的候选（`<source>:<externalId>` → 候选），apply 时补封面
  /// 缩略图 URL 用；不在缓存里也能 apply（详情只需 source + externalId）。
  final Map<String, SourceCandidate> _scrapeCandidates =
      <String, SourceCandidate>{};

  Map<String, Object?> _gameJson(GalgameEntry g) => <String, Object?>{
    'id': g.id,
    'title': g.displayName,
    'name': g.name,
    if (g.customData.name != null) 'customName': g.customData.name,
    'playStatus': g.playStatus.name,
    'exePath': g.exePath,
    'exeExists': File(g.exePath).existsSync(),
    'workdir': g.workdir,
    'launchArgs': g.launchArgs,
    if (g.coverPath != null) 'coverPath': g.coverPath,
    if (g.releaseDate != null) 'releaseDate': g.releaseDate,
    if (g.customData.summary != null) 'summary': g.customData.summary,
    if (g.customData.tags.isNotEmpty) 'tags': g.customData.tags,
    if (g.customData.developer != null) 'developer': g.customData.developer,
    if (g.customData.nsfw != null) 'nsfw': g.customData.nsfw,
    if (g.customData.userRating != null) 'rating': g.customData.userRating,
    if (g.customData.userReview != null) 'review': g.customData.userReview,
  };

  /// 条目管理不依赖 Hook 会话：只要「游戏」模块开着（库页本身在任何平台都在），
  /// 但游戏库是 Windows 专属车道（exe 启动），与其余 game 路由同一道平台门。
  Future<GalgameEntry> _manageTarget(CtlCall call) async {
    _requireHook();
    _requireWritable();
    return _findGame(call.params['id']!);
  }

  Future<Object?> renameGame(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final bool clear = call.optBool('clear') ?? false;
    final String? name = call.optString('name');
    if (clear == (name != null)) {
      throw const CtlFailure.badRequest('name 与 clear=true 二选一');
    }
    // 写用户覆盖层 customData.name（库页「重命名」同语义），清除 = 回落到 exe 推导名。
    final GalgameCustomData c = game.customData;
    await host.setCustomData(
      game.id,
      GalgameCustomData(
        name: name,
        coverSource: c.coverSource,
        aliases: c.aliases,
        summary: c.summary,
        tags: c.tags,
        developer: c.developer,
        nsfw: c.nsfw,
        userRating: c.userRating,
        userReview: c.userReview,
      ),
    );
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{'ok': true, ..._gameJson(updated)};
  }

  Future<Object?> setPlayStatus(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final String raw = call.requireString('status');
    final GalgamePlayStatus? status = GalgamePlayStatus.values
        .cast<GalgamePlayStatus?>()
        .firstWhere(
          (GalgamePlayStatus? s) => s!.name.toLowerCase() == raw.toLowerCase(),
          orElse: () => null,
        );
    if (status == null) {
      throw CtlFailure.badRequest(
        'status 只能是 ${GalgamePlayStatus.values.map((GalgamePlayStatus s) => s.name).join(' | ')}：$raw',
      );
    }
    await host.setPlayStatus(game.id, status);
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{
      'ok': updated.playStatus == status,
      ..._gameJson(updated),
    };
  }

  Future<Object?> setCover(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final String? file = call.optString('file');
    final bool auto = call.optBool('auto') ?? false;
    if (auto == (file != null)) {
      throw const CtlFailure.badRequest('file 与 auto=true 二选一');
    }
    final String? saved;
    if (file != null) {
      if (!File(file).existsSync()) {
        throw CtlFailure.notFound('图片文件不存在：$file');
      }
      saved = await host.importCoverFile(game.id, file);
      if (saved == null) {
        throw CtlFailure.rejected('无法把 $file 用作封面（不是可识别的图片，或写入失败）');
      }
    } else {
      saved = await host.autoCover(game);
    }
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{
      'ok': saved != null,
      'coverPath': saved,
      if (saved == null) 'message': '游戏目录里没找到封面图，exe 也没有可用图标',
      ..._gameJson(updated),
    };
  }

  static const Set<String> _clearableFields = <String>{
    'launchArgs',
    'summary',
    'tags',
    'developer',
    'nsfw',
    'rating',
    'review',
    'releaseDate',
  };

  /// 详情页「编辑」页签 + exe / 工作目录 / 启动参数：给哪项改哪项，`clear` 列出要清空的项。
  Future<Object?> editGame(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final List<String> clear = call.stringList('clear');
    for (final String f in clear) {
      if (!_clearableFields.contains(f)) {
        throw CtlFailure.badRequest(
          'clear 不认识 $f（可清空：${_clearableFields.join(' | ')}）',
        );
      }
    }
    String? field(String name) {
      final String? v = call.optString(name);
      if (v != null && clear.contains(name)) {
        throw CtlFailure.badRequest('$name 不能同时设置又清空');
      }
      return v;
    }

    final String? exePath = field('exePath');
    final String? workdir = field('workdir');
    final String? launchArgs = field('launchArgs');
    final String? summary = field('summary');
    final String? tagsRaw = field('tags');
    final String? developer = field('developer');
    final String? review = field('review');
    final String? ratingRaw = field('rating');
    final String? releaseRaw = field('releaseDate');
    final bool? nsfw = call.optBool('nsfw');
    if (nsfw != null && clear.contains('nsfw')) {
      throw const CtlFailure.badRequest('nsfw 不能同时设置又清空');
    }
    double? rating;
    if (ratingRaw != null) {
      final double? v = double.tryParse(ratingRaw);
      // 详情页输入框越界会 clamp；CLI 输入越界直接报错，不替用户改数。
      if (v == null || !v.isFinite || v < 0 || v > 10) {
        throw CtlFailure.badRequest('rating 必须是 0–10 的数字：$ratingRaw');
      }
      rating = v;
    }
    String? releaseDate;
    if (releaseRaw != null) {
      releaseDate = draftDate(releaseRaw);
      if (releaseDate == null) {
        throw CtlFailure.badRequest('releaseDate 必须是 YYYY-MM-DD：$releaseRaw');
      }
    }
    final bool any =
        clear.isNotEmpty ||
        <Object?>[
          exePath,
          workdir,
          launchArgs,
          summary,
          tagsRaw,
          developer,
          review,
          ratingRaw,
          releaseRaw,
          nsfw,
        ].any((Object? v) => v != null);
    if (!any) throw const CtlFailure.badRequest('没有要修改的字段');

    final GalgameCustomData c = game.customData;
    T? pick<T>(String name, T? value, T? current) =>
        clear.contains(name) ? null : value ?? current;
    final GalgameCustomData custom = GalgameCustomData(
      name: c.name,
      coverSource: c.coverSource,
      aliases: c.aliases,
      summary: pick('summary', summary, c.summary),
      tags: clear.contains('tags')
          ? const <String>[]
          : tagsRaw == null
          ? c.tags
          : parseGalgameTagInput(tagsRaw),
      developer: pick('developer', developer, c.developer),
      nsfw: pick('nsfw', nsfw, c.nsfw),
      userRating: pick('rating', rating, c.userRating),
      userReview: pick('review', review, c.userReview),
    );
    // 逐字段重建（详情页 `_save` 同做法）：copyWith 清不掉可空字段（releaseDate）。
    final GalgameEntry next = GalgameEntry(
      id: game.id,
      name: game.name,
      exePath: exePath ?? game.exePath,
      workdir: workdir ?? game.workdir,
      launchArgs: clear.contains('launchArgs')
          ? ''
          : launchArgs ?? game.launchArgs,
      upscalingMode: game.upscalingMode,
      japaneseLocaleMode: game.japaneseLocaleMode,
      language: game.language,
      coverPath: game.coverPath,
      addedAt: game.addedAt,
      playStatus: game.playStatus,
      primarySource: game.primarySource,
      releaseDate: pick('releaseDate', releaseDate, game.releaseDate),
      customData: custom,
      metadata: game.metadata,
      sortOrder: game.sortOrder,
      totalPlaySeconds: game.totalPlaySeconds,
      sessionCount: game.sessionCount,
      lastPlayedMs: game.lastPlayedMs,
    );
    await host.updateEntry(next);
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{
      'ok': true,
      ..._gameJson(updated),
      if (exePath != null && !File(exePath).existsSync())
        'warning': 'exe 路径不存在：$exePath（已保存，启动前请确认）',
    };
  }

  Future<Object?> removeGame(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('从库移除游戏需要 confirm=true（不会删磁盘文件）');
    }
    final GameCtlSessionSnapshot snap = host.snapshot();
    if (snap.state.isActive && _sameExe(snap.state.launchExe, game.exePath)) {
      throw const CtlFailure.conflict('这款游戏正在捕获中，先 game stop');
    }
    final bool deleteStats = call.optBool('deleteStatistics') ?? false;
    final String? statsError = await host.removeGame(
      game.id,
      deleteStatistics: deleteStats,
    );
    return <String, Object?>{
      'ok': true,
      'removed': game.id,
      'title': game.displayName,
      'statisticsDeleted': deleteStats && statsError == null,
      if (statsError != null) 'statisticsError': statsError,
    };
  }

  Future<Object?> listSessions(CtlCall call) async {
    _requireHook();
    final GalgameEntry game = await _findGame(call.params['id']!);
    final int limit = call.optInt('limit') ?? 50;
    final int offset = call.optInt('offset') ?? 0;
    if (limit < 1 || offset < 0) {
      throw const CtlFailure.badRequest('limit 至少为 1，offset 不能为负');
    }
    return <String, Object?>{
      'id': game.id,
      'title': game.displayName,
      'totalPlaySeconds': game.totalPlaySeconds,
      'sessionCount': game.sessionCount,
      'sessions': await host.sessions(game.id, limit: limit, offset: offset),
    };
  }

  Future<Object?> deleteSession(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final int? sessionId = int.tryParse(call.params['sessionId']!);
    if (sessionId == null) {
      throw const CtlFailure.badRequest('sessionId 必须是整数');
    }
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('删除游玩会话需要 confirm=true（会改变统计时长）');
    }
    // 会话必须属于这款游戏：防止 id 打错删到别的游戏的统计。
    final List<Map<String, Object?>> all = await host.sessions(
      game.id,
      limit: 1 << 30,
      offset: 0,
    );
    final Map<String, Object?>? target = all
        .cast<Map<String, Object?>?>()
        .firstWhere(
          (Map<String, Object?>? s) => s!['id'] == sessionId,
          orElse: () => null,
        );
    if (target == null) {
      throw CtlFailure.notFound(
        'game:${game.id} 没有会话 $sessionId（见 game sessions）',
      );
    }
    await host.deleteSession(sessionId);
    return <String, Object?>{'ok': true, 'deleted': target};
  }

  static GalgameMetadataSource _metadataSource(String raw) {
    for (final GalgameMetadataSource s in GalgameMetadataSource.values) {
      if (s.key == raw.toLowerCase()) return s;
    }
    throw CtlFailure.badRequest(
      '资料源只能是 ${GalgameMetadataSource.values.map((GalgameMetadataSource s) => s.key).join(' | ')}：$raw',
    );
  }

  Future<Object?> scrapeSearch(CtlCall call) async {
    _requireHook();
    final GalgameEntry game = await _findGame(call.params['id']!);
    final String query = call.optString('q') ?? game.displayName;
    final String? source = call.optString('source');
    final GalgameScrapeSearchResult result;
    try {
      result = await host.scrapeSearch(
        query,
        sources: source == null
            ? null
            : <GalgameMetadataSource>{_metadataSource(source)},
      );
    } on GalgameMetadataException catch (e) {
      throw CtlFailure(502, 'upstream_failed', '全部资料源都失败：${e.message}');
    }
    return <String, Object?>{
      'id': game.id,
      'query': query,
      'candidates': <Map<String, Object?>>[
        for (final SourceCandidate c in result.candidates)
          () {
            final String key = '${c.source.key}:${c.externalId}';
            _scrapeCandidates[key] = c;
            return <String, Object?>{
              'id': key,
              'source': c.source.key,
              'externalId': c.externalId,
              'name': c.name,
              'nameCn': c.nameCn,
              'releaseDate': c.releaseDate,
              'summary': c.summary,
            };
          }(),
      ],
      'failures': <String, String>{
        for (final MapEntry<GalgameMetadataSource, String> f
            in result.failures.entries)
          f.key.key: f.value,
      },
    };
  }

  Future<Object?> scrapeApply(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final String raw = call.requireString('candidate');
    final int colon = raw.indexOf(':');
    if (colon <= 0 || colon == raw.length - 1) {
      throw CtlFailure.badRequest('候选 id 应为 <source>:<externalId>：$raw');
    }
    final GalgameMetadataSource source = _metadataSource(
      raw.substring(0, colon),
    );
    final String externalId = raw.substring(colon + 1);
    final SourceCandidate candidate =
        _scrapeCandidates[raw] ??
        SourceCandidate(source: source, externalId: externalId);
    final bool applied;
    try {
      applied = await host.applyScrape(game.id, candidate);
    } on GalgameMetadataException catch (e) {
      throw CtlFailure(502, 'upstream_failed', '资料源请求失败：${e.message}');
    }
    if (!applied) {
      throw CtlFailure.notFound('${source.label} 上找不到 $externalId');
    }
    final GalgameEntry updated = await _findGame(game.id);
    return <String, Object?>{
      'ok': true,
      'candidate': raw,
      'sources': await host.metadataSources(game.id),
      ..._gameJson(updated),
    };
  }

  Future<Object?> listSources(CtlCall call) async {
    _requireHook();
    final GalgameEntry game = await _findGame(call.params['id']!);
    return <String, Object?>{
      'id': game.id,
      'primarySource': game.primarySource,
      'sources': await host.metadataSources(game.id),
    };
  }

  Future<Object?> removeSource(CtlCall call) async {
    final GalgameEntry game = await _manageTarget(call);
    final GalgameMetadataSource source = _metadataSource(
      call.params['source']!,
    );
    if (!(await host.metadataSources(game.id)).contains(source.key)) {
      throw CtlFailure.notFound('game:${game.id} 没有 ${source.key} 资料快照');
    }
    await host.removeMetadataSource(game.id, source);
    return <String, Object?>{
      'ok': true,
      'removed': source.key,
      'sources': await host.metadataSources(game.id),
    };
  }
}

@visibleForTesting
Map<String, Object?> galHookCtlTrackJson(
  GalAudioTrack t, {
  required bool selected,
  required bool excluded,
}) => <String, Object?>{
  'ptr': t.sourcePtr,
  'order': t.orderIndex,
  'sampleRate': t.format.sampleRate,
  'channels': t.format.channels,
  'avgBytes': t.avgBytes,
  'avgEnergy': t.avgEnergy,
  'clips': t.clipCount,
  if (t.clipCountAtCue >= 0) 'clipsAtCue': t.clipCountAtCue,
  'selected': selected,
  'excluded': excluded,
};

Object? _jsonSafe(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is List) return value.map(_jsonSafe).toList(growable: false);
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in value.entries)
        '${e.key}': _jsonSafe(e.value),
    };
  }
  return '$value';
}

// ── JSON 投影（纯函数） ────────────────────────────────────────────────────

/// 会话状态投影：只报会话控制器自己持有的事实，不推断。
@visibleForTesting
Map<String, Object?> galHookCtlSessionJson(GameCtlSessionSnapshot snap) {
  final GalHookSessionState s = snap.state;
  return <String, Object?>{
    'phase': s.phase.name,
    'active': s.isActive,
    'mode': !s.isActive
        ? null
        : s.launchExe != null
        ? 'launch'
        : 'attach',
    'pid': s.gamePid,
    'executable': snap.captureExecutable,
    if (s.boundWindow != null)
      'window': <String, Object?>{
        'hwnd': s.boundWindow!.hwnd,
        'pid': s.boundWindow!.pid,
        'title': s.boundWindow!.title,
      },
    'startedAt': s.sessionStartedAt?.toIso8601String(),
    'audioBackend': s.audioBackend.name,
    'audioFallbackPolicy': s.audioFallbackPolicy.storageKey,
    'injectorFailure': s.injectorFailure.name,
    if (s.injectorDetail.isNotEmpty) 'injectorDetail': s.injectorDetail,
    if (s.fallbackReason != null) 'fallbackReason': s.fallbackReason,
    if (s.lastError != null) 'lastError': s.lastError,
    'engineSource': snap.hasEngineSource,
    'japaneseLocaleApplied': s.japaneseLocaleApplied,
    'selectedThread': snap.selectedThreadKey,
    'threadCount': snap.textThreads.length,
    'lineCount': snap.sessionLines.length,
  };
}

@visibleForTesting
Map<String, Object?> galHookCtlThreadJson(
  TexthookerTextThread t, {
  required bool selected,
}) => <String, Object?>{
  'key': t.key,
  'label': t.label,
  'selected': selected,
  if (t.hookCode != null) 'hookCode': t.hookCode,
  if (t.nativeThreadId != null) 'nativeThreadId': t.nativeThreadId,
  'engineExact': isEngineExactTextThread(t),
  'observedLines': t.observedLineCount,
  'observedArtifacts': t.observedArtifactCount,
  'publishedLines': t.lineCount,
  'audioLines': t.audioLineCount,
  if (t.previewText != null) 'preview': t.previewText,
  'previewIsArtifact': t.previewIsArtifact,
  'latestAt': t.latestAt.toIso8601String(),
};

@visibleForTesting
Map<String, Object?> galHookCtlLineJson(
  TexthookerLineEntry line, {
  required String visibleText,
}) => <String, Object?>{
  'id': line.id,
  'text': visibleText,
  if (visibleText != line.text) 'rawText': line.text,
  'receivedAt': line.receivedAt.toIso8601String(),
  if (line.textThreadKey != null) 'thread': line.textThreadKey,
  if (line.textThreadLabel != null) 'threadLabel': line.textThreadLabel,
  'audioStatus': line.audioStatus.name,
  if (line.audioBackend != null) 'audioBackend': line.audioBackend,
  if (line.audioResourceId != null) 'audioResourceId': line.audioResourceId,
  if (line.audioDurationMs != null) 'audioDurationMs': line.audioDurationMs,
  'eventOwnedVoice': line.eventOwnedVoice,
  if (line.fallbackReason != null) 'fallbackReason': line.fallbackReason,
  'mined': line.mined,
  'favorited': line.favorited,
  if (line.minedNoteId != null) 'minedNoteId': line.minedNoteId,
};

// ── 能力阶段 ──────────────────────────────────────────────────────────────

/// 阶段状态。刻意没有 `passed`/`verified`：本接口只能报 app 会话**观测**到的事实，
/// 达不到 docs/agent/galgame-hooking.md 的「最小通过证据」全部条款（例如没有独立校验
/// PID 不是启动器、没有排除 UI 伪影）。
abstract final class GalHookCtlStageStatus {
  /// app 会话观测到了该阶段的信号（见 evidence）。
  static const String observed = 'observed';

  /// 进行中 / 等待用户动作（例如尚未选文本线程）。
  static const String pending = 'pending';

  /// 明确失败（见 reason / failure）。
  static const String failed = 'failed';

  /// 只有显式降级（Loopback）——不算该阶段通过。
  static const String degraded = 'degraded';

  /// 上游阶段失败，本阶段无从谈起。
  static const String blocked = 'blocked';

  /// 会话还没走到这里。
  static const String notReached = 'not_reached';

  /// 本接口无法证明（e2e_verified）。
  static const String notVerifiable = 'not_verifiable';
}

const Set<GalHookInjectorFailure> _processStageFailures =
    <GalHookInjectorFailure>{
      GalHookInjectorFailure.targetMissing,
      GalHookInjectorFailure.gameExeMissing,
      GalHookInjectorFailure.steamTimeout,
      GalHookInjectorFailure.launcherEnded,
      GalHookInjectorFailure.launcherDiscoveryFailed,
    };

const Set<GalHookInjectorFailure> _ipcStageFailures = <GalHookInjectorFailure>{
  GalHookInjectorFailure.readyTimeout,
  GalHookInjectorFailure.nativeLoopbackAckTimeout,
  GalHookInjectorFailure.sharedMemoryUnavailable,
  GalHookInjectorFailure.protocolMismatch,
  GalHookInjectorFailure.handshakeTimeout,
};

bool _inProgress(GalHookSessionPhase phase) => switch (phase) {
  GalHookSessionPhase.resolving ||
  GalHookSessionPhase.launching ||
  GalHookSessionPhase.attaching ||
  GalHookSessionPhase.injecting ||
  GalHookSessionPhase.waitingSignals => true,
  _ => false,
};

const Set<TexthookerLineAudioStatus> _audioPresent =
    <TexthookerLineAudioStatus>{
      TexthookerLineAudioStatus.matched,
      TexthookerLineAudioStatus.encoded,
    };

/// 逐级给出能力阶段，**不合并**：每一级只看自己的证据，上游失败时下游标 `blocked`。
///
/// 判据（全部来自 [GalHookSessionController] 已有状态）：
/// * `process_found`：会话持有的游戏 PID（launch 时 injector 回报 / attach 时窗口所属
///   进程）；是否是真实游戏而非启动器，本接口**不独立校验**。
/// * `helper_ready` / `ipc_ready`：引擎 hook 源已提升为活动源 = injector 宣告就绪且
///   native 通道已在轮询；失败按 [GalHookInjectorFailure] 归到对应一级。
/// * `text_ready`：当前会话 + 当前线程放行的正式行非空；伪影是否已排除由用户选线程判断。
/// * `resource/pcm_ready`：有台词被配上 `game_resource` / `engine_pcm` 句音；
///   `systemLoopback` 只是降级，标 `degraded`，不算通过。
/// * `paired`：有台词的句音来自 native 事件所有权（`eventOwnedVoice`）且带资源 id；
///   只有 PCM 时间窗拼接的标 `pending`（不是稳定 event ID 配对）。
@visibleForTesting
List<Map<String, Object?>> galHookCtlStages(GameCtlSessionSnapshot snap) {
  final GalHookSessionState s = snap.state;
  final GalHookInjectorFailure failure = s.injectorFailure;
  final bool active = s.isActive;
  final bool progressing = _inProgress(s.phase);
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  bool upstreamFailed = false;

  void add(
    String stage,
    String status, {
    Map<String, Object?> evidence = const <String, Object?>{},
    String? note,
  }) {
    final String effective =
        upstreamFailed &&
            status != GalHookCtlStageStatus.observed &&
            status != GalHookCtlStageStatus.failed &&
            status != GalHookCtlStageStatus.notVerifiable
        ? GalHookCtlStageStatus.blocked
        : status;
    out.add(<String, Object?>{
      'stage': stage,
      'status': effective,
      if (evidence.isNotEmpty) 'evidence': evidence,
      if (note != null) 'note': note,
    });
    if (effective == GalHookCtlStageStatus.failed) upstreamFailed = true;
  }

  // process_found
  final int pid = s.gamePid ?? 0;
  if (pid > 0) {
    add(
      'process_found',
      GalHookCtlStageStatus.observed,
      evidence: <String, Object?>{
        'pid': pid,
        'executable': ?snap.captureExecutable,
        if (s.boundWindow != null) 'hwnd': s.boundWindow!.hwnd,
      },
      note: '会话持有的 PID；未独立校验它不是启动器 / relay 进程',
    );
  } else if (_processStageFailures.contains(failure)) {
    add(
      'process_found',
      GalHookCtlStageStatus.failed,
      evidence: <String, Object?>{'failure': failure.name},
    );
  } else {
    add(
      'process_found',
      active || progressing
          ? GalHookCtlStageStatus.pending
          : GalHookCtlStageStatus.notReached,
    );
  }

  // helper_ready / ipc_ready
  final bool helperFailure =
      failure != GalHookInjectorFailure.none &&
      !_processStageFailures.contains(failure) &&
      !_ipcStageFailures.contains(failure);
  if (snap.hasEngineSource) {
    add(
      'helper_ready',
      GalHookCtlStageStatus.observed,
      evidence: const <String, Object?>{'engineSource': true},
    );
    add(
      'ipc_ready',
      GalHookCtlStageStatus.observed,
      evidence: const <String, Object?>{'nativePolling': true},
    );
  } else if (helperFailure) {
    add(
      'helper_ready',
      GalHookCtlStageStatus.failed,
      evidence: <String, Object?>{
        'failure': failure.name,
        if (s.injectorDetail.isNotEmpty) 'detail': s.injectorDetail,
      },
    );
    add('ipc_ready', GalHookCtlStageStatus.blocked);
  } else if (_ipcStageFailures.contains(failure)) {
    add(
      'helper_ready',
      GalHookCtlStageStatus.observed,
      evidence: <String, Object?>{'injectorRan': true, 'failure': failure.name},
      note: 'injector 已运行并回报了 IPC 阶段的分类失败',
    );
    add(
      'ipc_ready',
      GalHookCtlStageStatus.failed,
      evidence: <String, Object?>{
        'failure': failure.name,
        if (s.injectorDetail.isNotEmpty) 'detail': s.injectorDetail,
      },
    );
  } else {
    final bool externalText = snap.endpoints.any(
      (TexthookerEndpointStatus e) =>
          e.phase == TexthookerEndpointPhase.connected,
    );
    final String waiting = active || progressing
        ? GalHookCtlStageStatus.pending
        : GalHookCtlStageStatus.notReached;
    add('helper_ready', waiting);
    add(
      'ipc_ready',
      waiting,
      evidence: externalText
          ? const <String, Object?>{'externalTextEndpoint': true}
          : const <String, Object?>{},
      note: externalText ? '外部 WebSocket 文本端点已连接（非 native helper 通道）' : null,
    );
  }

  // text_ready
  final List<TexthookerLineEntry> lines = snap.sessionLines;
  if (!active) {
    add('text_ready', GalHookCtlStageStatus.notReached);
  } else if (lines.isNotEmpty) {
    add(
      'text_ready',
      GalHookCtlStageStatus.observed,
      evidence: <String, Object?>{
        'lines': lines.length,
        'thread': ?snap.selectedThreadKey,
        'lastAt': lines.last.receivedAt.toIso8601String(),
      },
      note: snap.selectedThreadKey == null
          ? '来自不带线程身份的来源（WebSocket 等）'
          : '系统 / UI 伪影是否排除取决于所选线程，本接口不判定',
    );
  } else {
    add(
      'text_ready',
      GalHookCtlStageStatus.pending,
      evidence: <String, Object?>{'candidateThreads': snap.textThreads.length},
      note: snap.textThreads.isNotEmpty && snap.selectedThreadKey == null
          ? '已有候选线程，尚未选择'
          : '尚未收到台词',
    );
  }

  // resource/pcm_ready
  int resourceLines = 0;
  int pcmLines = 0;
  int ownedPairs = 0;
  for (final TexthookerLineEntry line in lines) {
    if (!_audioPresent.contains(line.audioStatus)) continue;
    if (line.audioBackend == 'game_resource') {
      resourceLines++;
      if (line.eventOwnedVoice && line.audioResourceId != null) ownedPairs++;
    } else if (line.audioBackend == 'engine_pcm') {
      pcmLines++;
    }
  }
  final Map<String, Object?> audioEvidence = <String, Object?>{
    'backend': s.audioBackend.name,
    'resourceLines': resourceLines,
    'pcmLines': pcmLines,
  };
  if (!active) {
    add('resource/pcm_ready', GalHookCtlStageStatus.notReached);
  } else if (resourceLines + pcmLines > 0) {
    add(
      'resource/pcm_ready',
      GalHookCtlStageStatus.observed,
      evidence: audioEvidence,
    );
  } else if (s.audioBackend == GalHookAudioBackend.systemLoopback) {
    add(
      'resource/pcm_ready',
      GalHookCtlStageStatus.degraded,
      evidence: audioEvidence,
      note: 'Loopback 是显式降级（整机混音），不证明引擎资源 / PCM',
    );
  } else if (s.audioBackend == GalHookAudioBackend.none) {
    add(
      'resource/pcm_ready',
      progressing
          ? GalHookCtlStageStatus.pending
          : GalHookCtlStageStatus.failed,
      evidence: audioEvidence,
      note: progressing ? null : '当前会话没有任何音频后端',
    );
  } else {
    add(
      'resource/pcm_ready',
      GalHookCtlStageStatus.pending,
      evidence: audioEvidence,
      note: '音频后端已启动，尚未观测到逐句资源 / PCM 事件',
    );
  }

  // paired
  if (!active) {
    add('paired', GalHookCtlStageStatus.notReached);
  } else if (ownedPairs > 0) {
    add(
      'paired',
      GalHookCtlStageStatus.observed,
      evidence: <String, Object?>{'eventOwnedPairs': ownedPairs},
    );
  } else {
    add(
      'paired',
      s.audioBackend == GalHookAudioBackend.systemLoopback
          ? GalHookCtlStageStatus.degraded
          : GalHookCtlStageStatus.pending,
      evidence: <String, Object?>{'eventOwnedPairs': 0, 'pcmLines': pcmLines},
      note: pcmLines > 0 ? '只有 PCM 时间窗拼接，没有稳定 event ID 配对' : null,
    );
  }

  add(
    'e2e_verified',
    GalHookCtlStageStatus.notVerifiable,
    note: '需在原始启动路径人工完成「当前文本 → 对应语音 → 画面 → 真卡写入」，CLI 状态不构成该证据',
  );
  return out;
}
