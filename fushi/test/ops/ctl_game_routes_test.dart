import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/lookup/gal_attached_text_controller.dart'
    show GalAttachedTextStatus;
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart'
    show GalAttachedSurfaceTarget;
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/ops/ctl_game_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

class _NoRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('构建路由表时不应访问 ref：${invocation.memberName}');
}

final DateTime _t0 = DateTime.utc(2026, 10, 16, 12);

GalgameEntry _game(String id, {String exe = r'C:\games\a\a.exe'}) =>
    GalgameEntry(
      id: id,
      name: 'Game $id',
      exePath: exe,
      workdir: r'C:\games\a',
      addedAt: _t0,
    );

TexthookerTextThread _thread(String key, {int? native}) => TexthookerTextThread(
  key: key,
  label: 'label-$key',
  lineCount: 0,
  latestAt: _t0,
  nativeThreadId: native,
  observedLineCount: 3,
);

TexthookerLineEntry _line(
  String id,
  String text, {
  TexthookerLineAudioStatus audio = TexthookerLineAudioStatus.unavailable,
  String? backend,
  String? resourceId,
  bool owned = false,
}) => TexthookerLineEntry(
  id: id,
  text: text,
  source: TexthookerLineSource.values.first,
  receivedAt: _t0,
  textThreadKey: 't1',
  audioStatus: audio,
  audioBackend: backend,
  audioResourceId: resourceId,
  eventOwnedVoice: owned,
);

class _FakeHost implements GameCtlHost {
  @override
  bool isWindows = true;
  @override
  bool gamesModuleEnabled = true;
  @override
  bool isMigrationReadonly = false;

  List<GalgameEntry> games = <GalgameEntry>[_game('g1')];
  GameCtlSessionSnapshot snap = const GameCtlSessionSnapshot(
    state: GalHookSessionState(),
  );

  /// launch 执行后切换到的快照。
  GameCtlSessionSnapshot? afterLaunch;
  GameCtlLaunchReport launchReport = const GameCtlLaunchReport.launched(
    GalHookLaunchResult.launched(),
  );
  List<ExternalWindowInfo> windows = const <ExternalWindowInfo>[];
  final List<String> calls = <String>[];
  bool selectResult = true;
  Map<String, String>? minedFields;
  String? minedSentence;
  GalHookMiningResult mineResult = const GalHookMiningResult(
    outcome: MineOutcome(MineResult.success, noteId: 9),
  );

  @override
  Future<List<GalgameEntry>> loadGames() async => games;

  @override
  GameCtlSessionSnapshot snapshot() => snap;

  @override
  Future<GameCtlLaunchReport> launch(GalgameEntry game) async {
    calls.add('launch:${game.id}');
    if (afterLaunch != null) snap = afterLaunch!;
    return launchReport;
  }

  @override
  Future<List<ExternalWindowInfo>> listWindows() async => windows;

  @override
  Future<void> attach(ExternalWindowInfo window) async {
    calls.add('attach:${window.hwnd}');
    snap = GameCtlSessionSnapshot(
      state: GalHookSessionState(
        phase: GalHookSessionPhase.running,
        externalWindowMode: true,
        boundWindow: window,
        gamePid: window.pid,
      ),
    );
  }

  @override
  Future<void> stop({required bool keepBinding}) async {
    calls.add('stop:$keepBinding');
    snap = const GameCtlSessionSnapshot(state: GalHookSessionState());
  }

  @override
  Future<bool> selectThread(TexthookerTextThread? thread) async {
    calls.add('select:${thread?.key}:${thread?.nativeThreadId}');
    return selectResult;
  }

  @override
  String visibleText(TexthookerLineEntry entry) => entry.text.trim();

  @override
  Future<Map<String, String>> buildMineFields({
    required String word,
    required String sentence,
    String? reading,
    String? glossary,
    required bool lookup,
    required bool allowDuplicate,
  }) async => <String, String>{
    'expression': word,
    'reading': reading ?? '',
    'glossary': glossary ?? (lookup ? 'g' : ''),
    'sentence': sentence,
  };

  @override
  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    required String sentence,
    int? updateNoteId,
  }) async {
    calls.add('mine:$lineId:$updateNoteId');
    minedFields = fields;
    minedSentence = sentence;
    return mineResult;
  }

  // ── 工作台细项 ─────────────────────────────────────────────────────────

  final Map<String, Map<String, Object?>> gameConfig =
      <String, Map<String, Object?>>{};
  GalTrackPreview? preview = const GalTrackPreview(
    filePath: r'C:\tmp\p.wav',
    durationMs: 1200,
  );
  bool playResult = true;
  bool lineTrackResult = true;
  bool recaptureStartResult = true;
  final Map<String, int> lineTrack = <String, int>{};
  List<GalAudioTrack> lineTracks = const <GalAudioTrack>[];

  void update({
    GalHookSessionState? state,
    String? recapturing,
    bool clearRecapturing = false,
    GalTextProcessPipeline? pipeline,
    List<GalHookEvent>? events,
    GalLookupSurfaceMode? attachedMode,
    bool clearAttachedMode = false,
  }) {
    final GameCtlSessionSnapshot s = snap;
    snap = GameCtlSessionSnapshot(
      state: state ?? s.state,
      hasEngineSource: s.hasEngineSource,
      captureExecutable: s.captureExecutable,
      textThreads: s.textThreads,
      selectedThreadKey: s.selectedThreadKey,
      sessionLines: s.sessionLines,
      events: events ?? s.events,
      endpoints: s.endpoints,
      recapturingLineId: clearRecapturing
          ? null
          : recapturing ?? s.recapturingLineId,
      textProcessPipeline: pipeline ?? s.textProcessPipeline,
      attachedExecutable: s.attachedExecutable,
      attachedMode: clearAttachedMode ? null : attachedMode ?? s.attachedMode,
    );
  }

  @override
  Future<void> setGameJapaneseLocaleMode(String gameId, String modeKey) async {
    calls.add('locale:$gameId:$modeKey');
    games = <GalgameEntry>[
      for (final GalgameEntry g in games)
        g.id == gameId ? g.copyWith(japaneseLocaleMode: modeKey) : g,
    ];
  }

  @override
  Future<void> setGameUpscalingMode(String gameId, String modeKey) async {
    calls.add('upscaling:$gameId:$modeKey');
  }

  @override
  Future<void> setGameLanguage(String gameId, String? language) async {
    calls.add('language:$gameId:$language');
  }

  @override
  Future<void> bindWindow(ExternalWindowInfo? window) async {
    calls.add('bind:${window?.hwnd}');
    update(
      state: window == null
          ? snap.state.copyWith(clearBoundWindow: true)
          : snap.state.copyWith(boundWindow: window),
    );
  }

  @override
  Future<void> setExternalWindowMode(bool enabled) async {
    calls.add('windowMode:$enabled');
    update(state: snap.state.copyWith(externalWindowMode: enabled));
  }

  @override
  Future<void> refreshAudioTracks() async => calls.add('refresh');

  @override
  void selectVoiceTrack(int sourcePtr) {
    calls.add('selectTrack:$sourcePtr');
    update(state: snap.state.copyWith(selectedAudioSourcePtr: sourcePtr));
  }

  @override
  void setTrackExcluded(int sourcePtr, bool excluded) {
    calls.add('exclude:$sourcePtr:$excluded');
    final Set<int> next = <int>{...snap.state.excludedAudioSourcePtrs};
    excluded ? next.add(sourcePtr) : next.remove(sourcePtr);
    update(state: snap.state.copyWith(excludedAudioSourcePtrs: next));
  }

  @override
  Future<GalTrackPreview?> exportTrackPreview(int sourcePtr) async {
    calls.add('preview:$sourcePtr');
    return preview;
  }

  @override
  Future<GalTrackPreview?> exportLineTrackPreview(
    String lineId,
    int sourcePtr,
  ) async {
    calls.add('linePreview:$lineId:$sourcePtr');
    return preview;
  }

  @override
  Future<GalTrackPreview?> exportLineAudioPreview(String lineId) async {
    calls.add('lineAudio:$lineId');
    return preview;
  }

  @override
  Future<List<GalAudioTrack>> tracksForLine(String lineId) async => lineTracks;

  @override
  int? lineVoiceSourcePtr(String lineId) => lineTrack[lineId];

  @override
  Future<bool> setLineVoiceTrack(String lineId, int sourcePtr) async {
    calls.add('lineTrack:$lineId:$sourcePtr');
    if (lineTrackResult) lineTrack[lineId] = sourcePtr;
    return lineTrackResult;
  }

  @override
  Future<bool> playAudioFile(String path) async {
    calls.add('play:$path');
    return playResult;
  }

  @override
  Future<void> stopAudio() async => calls.add('stopAudio');

  @override
  Future<bool> startLineRecapture(String lineId) async {
    calls.add('recapStart:$lineId');
    if (recaptureStartResult) update(recapturing: lineId);
    return recaptureStartResult;
  }

  @override
  Future<bool> finishLineRecapture({required bool discard}) async {
    calls.add('recapFinish:$discard');
    update(clearRecapturing: true);
    return !discard;
  }

  @override
  void setAudioFallbackPolicy(GalAudioFallbackPolicy policy) {
    calls.add('policy:${policy.storageKey}');
    update(state: snap.state.copyWith(audioFallbackPolicy: policy));
  }

  @override
  Future<void> setTextProcessPipeline(GalTextProcessPipeline pipeline) async {
    calls.add('textproc:${pipeline.steps.length}');
    update(pipeline: pipeline);
  }

  @override
  bool? toggleLineFavorite(String lineId) {
    calls.add('favorite:$lineId');
    return true;
  }

  @override
  void clearEvents() {
    calls.add('clearEvents');
    update(events: const <GalHookEvent>[]);
  }

  @override
  Future<void> setLookupMode(GalLookupSurfaceMode mode) async {
    calls.add('lookupMode:${mode.wireName}');
    update(attachedMode: mode);
  }

  @override
  Future<void> clearLookupProfile() async {
    calls.add('lookupClear');
    update(clearAttachedMode: true);
  }

  // ── 游戏条目管理 ───────────────────────────────────────────────────────

  void _replace(String id, GalgameEntry Function(GalgameEntry) f) {
    games = <GalgameEntry>[
      for (final GalgameEntry g in games) g.id == id ? f(g) : g,
    ];
  }

  String? importedCover = r'C:\covers\g1.png';
  String? autoCoverPath;
  String? statsError;
  List<Map<String, Object?>> sessionRows = <Map<String, Object?>>[
    <String, Object?>{
      'id': 3,
      'startMs': 0,
      'endMs': 1000,
      'durationSeconds': 1,
      'dateKey': '2026-10-16',
    },
  ];
  GalgameScrapeSearchResult scrapeResult = const GalgameScrapeSearchResult(
    candidates: <SourceCandidate>[
      SourceCandidate(
        source: GalgameMetadataSource.vndb,
        externalId: 'v17',
        name: 'Ever17',
        coverUrl: 'https://x/c.jpg',
      ),
    ],
  );
  Exception? scrapeError;
  bool applyResult = true;
  SourceCandidate? applied;
  List<String> sourceKeys = <String>['vndb'];

  @override
  Future<void> setCustomData(String gameId, GalgameCustomData custom) async {
    calls.add('custom:$gameId:${custom.name}');
    _replace(gameId, (GalgameEntry g) => g.copyWith(customData: custom));
  }

  @override
  Future<void> setPlayStatus(String gameId, GalgamePlayStatus status) async {
    calls.add('playStatus:$gameId:${status.name}');
    _replace(gameId, (GalgameEntry g) => g.copyWith(playStatus: status));
  }

  @override
  Future<void> updateEntry(GalgameEntry entry) async {
    calls.add('update:${entry.id}');
    _replace(entry.id, (_) => entry);
  }

  @override
  Future<String?> importCoverFile(String gameId, String sourcePath) async {
    calls.add('coverFile:$gameId');
    return importedCover;
  }

  @override
  Future<String?> autoCover(GalgameEntry game) async {
    calls.add('autoCover:${game.id}');
    return autoCoverPath;
  }

  @override
  Future<String?> removeGame(
    String gameId, {
    required bool deleteStatistics,
  }) async {
    calls.add('remove:$gameId:$deleteStatistics');
    games = games.where((GalgameEntry g) => g.id != gameId).toList();
    return statsError;
  }

  @override
  Future<List<Map<String, Object?>>> sessions(
    String gameId, {
    required int limit,
    required int offset,
  }) async => sessionRows.skip(offset).take(limit).toList();

  @override
  Future<void> deleteSession(int sessionId) async {
    calls.add('deleteSession:$sessionId');
    sessionRows = sessionRows
        .where((Map<String, Object?> r) => r['id'] != sessionId)
        .toList();
  }

  @override
  Future<GalgameScrapeSearchResult> scrapeSearch(
    String query, {
    Set<GalgameMetadataSource>? sources,
  }) async {
    calls.add('scrape:$query:${sources?.map((s) => s.key).join(',')}');
    if (scrapeError != null) throw scrapeError!;
    return scrapeResult;
  }

  @override
  Future<bool> applyScrape(String gameId, SourceCandidate candidate) async {
    applied = candidate;
    return applyResult;
  }

  @override
  Future<List<String>> metadataSources(String gameId) async => sourceKeys;

  @override
  Future<void> removeMetadataSource(
    String gameId,
    GalgameMetadataSource source,
  ) async {
    calls.add('removeSource:${source.key}');
    sourceKeys = sourceKeys.where((String k) => k != source.key).toList();
  }

  // ── 内嵌查词截图校准 ───────────────────────────────────────────────────

  GameCtlLookupState lookup = const GameCtlLookupState();
  GalLookupCalibrationCapture? capture;
  GalLookupCalibrationCaptureException? captureError;
  bool applyCalibrationResult = true;
  GalLookupSurfaceVariantV1? appliedVariant;
  final Map<String, List<int>> written = <String, List<int>>{};

  @override
  GameCtlLookupState lookupState() => lookup;

  @override
  Future<GalLookupCalibrationCapture> captureCalibrationSample() async {
    if (captureError != null) throw captureError!;
    return capture!;
  }

  @override
  Future<bool> applyMeasuredCalibration({
    required GalAttachedSurfaceTarget expectedTarget,
    required String expectedExeSha256,
    required GalLookupSurfaceVariantV1 variant,
  }) async {
    appliedVariant = variant;
    return applyCalibrationResult;
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    written[path] = bytes;
  }
}

const GalAudioTrack _track = GalAudioTrack(
  sourcePtr: 77,
  format: PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  ),
  avgBytes: 100,
  avgEnergy: 0.5,
  orderIndex: 0,
  clipCount: 3,
);

Future<Object?> _call(
  List<CtlRoute> routes,
  String method,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
  Map<String, String> query = const <String, String>{},
}) {
  for (final CtlRoute route in routes) {
    final Map<String, String>? params = route.match(path);
    if (route.method == method && params != null) {
      return route.handler(
        CtlCall(
          method: method,
          path: path,
          params: params,
          body: body,
          query: query,
        ),
      );
    }
  }
  throw StateError('no route $method $path');
}

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

Map<String, String> _stageMap(Object? stages) => <String, String>{
  for (final Object? s in stages! as List<Object?>)
    (s! as Map<String, Object?>)['stage']! as String:
        (s as Map<String, Object?>)['status']! as String,
};

void main() {
  test('生产路由表构建期不碰 ref，路径都在 /api/admin/game/ 下且不重复', () {
    final List<CtlRoute> routes = buildGameCtlRoutes(
      OpContext(ref: _NoRef(), focusMainWindow: () async {}),
    );
    final Set<String> seen = <String>{};
    for (final CtlRoute r in routes) {
      expect(r.pattern, startsWith('/api/admin/game/'));
      expect(seen.add('${r.method} ${r.pattern}'), isTrue);
    }
    expect(routes, hasLength(44));
  });

  group('门控', () {
    test('非 Windows 一律 501', () async {
      final _FakeHost host = _FakeHost()..isWindows = false;
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(routes, 'GET', '/api/admin/game/status'),
        _status(501),
      );
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/launch', body: {'id': 'g1'}),
        _status(501),
      );
      expect(host.calls, isEmpty);
    });

    test('游戏模块关闭 422；只读状态拒绝启动', () async {
      final _FakeHost off = _FakeHost()..gamesModuleEnabled = false;
      await expectLater(
        _call(buildGameCtlRoutesWith(off), 'GET', '/api/admin/game/games'),
        _status(422),
      );
      final _FakeHost ro = _FakeHost()..isMigrationReadonly = true;
      await expectLater(
        _call(
          buildGameCtlRoutesWith(ro),
          'POST',
          '/api/admin/game/launch',
          body: {'id': 'g1'},
        ),
        _status(422),
      );
    });
  });

  group('launch', () {
    test('未知游戏 404', () async {
      await expectLater(
        _call(
          buildGameCtlRoutesWith(_FakeHost()),
          'POST',
          '/api/admin/game/launch',
          body: {'id': 'nope'},
        ),
        _status(404),
      );
    });

    test('成功：outcome=running，阶段逐级给出', () async {
      final _FakeHost host = _FakeHost()
        ..afterLaunch = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.running,
            gamePid: 100,
            launchExe: r'C:\games\a\a.exe',
            boundWindow: ExternalWindowInfo(hwnd: 5, title: 'A', pid: 100),
            audioBackend: GalHookAudioBackend.gameResource,
          ),
          hasEngineSource: true,
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/launch',
                body: {'id': 'game:g1'},
              )
              as Map<String, Object?>;
      expect(host.calls, <String>['launch:g1']);
      expect(out['ok'], isTrue);
      expect(out['outcome'], 'running');
      final Map<String, String> stages = _stageMap(out['stages']);
      expect(stages['process_found'], 'observed');
      expect(stages['helper_ready'], 'observed');
      expect(stages['ipc_ready'], 'observed');
      // 没有台词 → text 未就绪，后端已起但无逐句事件 → 不能算 resource/pcm_ready。
      expect(stages['text_ready'], 'pending');
      expect(stages['resource/pcm_ready'], 'pending');
      expect(stages['paired'], 'pending');
      expect(stages['e2e_verified'], 'not_verifiable');
    });

    test('窗口没出现 = windowMissing，ok=false', () async {
      final _FakeHost host = _FakeHost()
        ..afterLaunch = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.waitingSignals,
            gamePid: 100,
            launchExe: r'C:\games\a\a.exe',
          ),
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/launch',
                body: {'id': 'g1'},
              )
              as Map<String, Object?>;
      expect(out['ok'], isFalse);
      expect(out['outcome'], 'windowMissing');
    });

    test('注入失败带诊断，下游阶段标 blocked', () async {
      final _FakeHost host = _FakeHost()
        ..launchReport = const GameCtlLaunchReport.launched(
          GalHookLaunchResult.failed(
            GalHookLaunchFailureReason.injectionFailed,
            diagnostics: GalHookInjectorDiagnostics(
              failure: GalHookInjectorFailure.bitnessMismatch,
              exitCode: 3,
              stderrTail: 'bitness',
            ),
          ),
        )
        ..afterLaunch = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.error,
            injectorFailure: GalHookInjectorFailure.bitnessMismatch,
          ),
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/launch',
                body: {'id': 'g1'},
              )
              as Map<String, Object?>;
      expect(out['ok'], isFalse);
      expect(out['outcome'], 'failed');
      expect(out['reason'], 'injectionFailed');
      expect((out['diagnostics']! as Map<String, Object?>)['exitCode'], 3);
      final Map<String, String> stages = _stageMap(out['stages']);
      expect(stages['helper_ready'], 'failed');
      expect(stages['ipc_ready'], 'blocked');
      expect(stages['text_ready'], 'blocked');
    });

    test('预检失败不进会话控制器语义：helperMissing', () async {
      final _FakeHost host = _FakeHost()
        ..launchReport = const GameCtlLaunchReport.preflight(
          GameCtlLaunchPreflight.helperMissing,
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/launch',
                body: {'id': 'g1'},
              )
              as Map<String, Object?>;
      expect(out['ok'], isFalse);
      expect(out['outcome'], 'preflight_failed');
      expect(out['preflight'], 'helperMissing');
    });

    test('已在捕获别的游戏：无 replace 时 409，不启动', () async {
      final _FakeHost host = _FakeHost()
        ..snap = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.running,
            launchExe: r'C:\other\b.exe',
          ),
        );
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/launch', body: {'id': 'g1'}),
        _status(409),
      );
      expect(host.calls, isEmpty);
      final Map<String, Object?> out =
          await _call(
                routes,
                'POST',
                '/api/admin/game/launch',
                body: {'id': 'g1', 'replace': true},
              )
              as Map<String, Object?>;
      expect(out['replacedSession'], isTrue);
      expect(host.calls, <String>['launch:g1']);
    });
  });

  group('attach / stop', () {
    const ExternalWindowInfo a = ExternalWindowInfo(
      hwnd: 11,
      title: 'A',
      pid: 7,
    );
    const ExternalWindowInfo b1 = ExternalWindowInfo(
      hwnd: 21,
      title: 'B1',
      pid: 8,
    );
    const ExternalWindowInfo b2 = ExternalWindowInfo(
      hwnd: 22,
      title: 'B2',
      pid: 8,
    );

    test('按 hwnd / 唯一 pid 附着；多窗口 pid 409；不存在 404', () async {
      final _FakeHost host = _FakeHost()
        ..windows = const <ExternalWindowInfo>[a, b1, b2];
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      final Map<String, Object?> out =
          await _call(
                routes,
                'POST',
                '/api/admin/game/attach',
                body: {'pid': 7},
              )
              as Map<String, Object?>;
      expect(out['ok'], isTrue);
      expect(host.calls, <String>['attach:11']);
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/attach', body: {'pid': 8}),
        _status(409),
      );
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/attach', body: {'hwnd': 99}),
        _status(404),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/attach',
          body: <String, Object?>{},
        ),
        _status(400),
      );
    });

    test('已在捕获同一窗口不重启会话', () async {
      final _FakeHost host = _FakeHost()
        ..windows = const <ExternalWindowInfo>[a]
        ..snap = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.running,
            externalWindowMode: true,
            boundWindow: a,
          ),
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/attach',
                body: {'hwnd': 11},
              )
              as Map<String, Object?>;
      expect(out['alreadyAttached'], isTrue);
      expect(host.calls, isEmpty);
    });

    test('stop 透传 keepBinding', () async {
      final _FakeHost host = _FakeHost()
        ..snap = const GameCtlSessionSnapshot(
          state: GalHookSessionState(phase: GalHookSessionPhase.running),
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/stop',
                body: {'unbind': true},
              )
              as Map<String, Object?>;
      expect(host.calls, <String>['stop:false']);
      expect(out['ok'], isTrue);
      expect(out['wasActive'], isTrue);
    });
  });

  group('threads / text', () {
    GameCtlSessionSnapshot activeWith({
      List<TexthookerLineEntry> lines = const <TexthookerLineEntry>[],
      String? selected,
    }) => GameCtlSessionSnapshot(
      state: const GalHookSessionState(
        phase: GalHookSessionPhase.running,
        gamePid: 3,
      ),
      textThreads: <TexthookerTextThread>[_thread('t1', native: 77)],
      selectedThreadKey: selected,
      sessionLines: lines,
    );

    test('选线程把 native id 与 key 一起交给会话', () async {
      final _FakeHost host = _FakeHost()..snap = activeWith();
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      final Map<String, Object?> out =
          await _call(
                routes,
                'POST',
                '/api/admin/game/threads/select',
                body: {'key': 't1'},
              )
              as Map<String, Object?>;
      expect(out['ok'], isTrue);
      expect(host.calls, <String>['select:t1:77']);
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/threads/select',
          body: {'key': 'zz'},
        ),
        _status(404),
      );
      await _call(
        routes,
        'POST',
        '/api/admin/game/threads/select',
        body: {'clear': true},
      );
      expect(host.calls.last, 'select:null:null');
    });

    test('helper 拒绝切换 → 409；无会话 → 409', () async {
      final _FakeHost host = _FakeHost()
        ..snap = activeWith()
        ..selectResult = false;
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'POST',
          '/api/admin/game/threads/select',
          body: {'key': 't1'},
        ),
        _status(409),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(_FakeHost()),
          'POST',
          '/api/admin/game/threads/select',
          body: {'key': 't1'},
        ),
        _status(409),
      );
    });

    test('text 返回当前台词（可见文本）与提示', () async {
      final _FakeHost host = _FakeHost()
        ..snap = activeWith(
          selected: 't1',
          lines: <TexthookerLineEntry>[
            _line('l1', 'first'),
            _line('l2', ' second '),
          ],
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'GET',
                '/api/admin/game/text',
                query: {'limit': '5'},
              )
              as Map<String, Object?>;
      final Map<String, Object?> current =
          out['current']! as Map<String, Object?>;
      expect(current['id'], 'l2');
      expect(current['text'], 'second');
      expect(current['rawText'], ' second ');
      expect(out['lines'], hasLength(2));

      host.snap = activeWith();
      final Map<String, Object?> empty =
          await _call(
                buildGameCtlRoutesWith(host),
                'GET',
                '/api/admin/game/text',
              )
              as Map<String, Object?>;
      expect(empty['current'], isNull);
      expect(empty['hint'], contains('尚未选择'));
    });
  });

  group('mine', () {
    GameCtlSessionSnapshot withLines(List<TexthookerLineEntry> lines) =>
        GameCtlSessionSnapshot(
          state: const GalHookSessionState(phase: GalHookSessionPhase.running),
          selectedThreadKey: 't1',
          sessionLines: lines,
        );

    test('缺省对当前台词制卡，句子用可见文本', () async {
      final _FakeHost host = _FakeHost()
        ..snap = withLines(<TexthookerLineEntry>[
          _line('l1', 'a'),
          _line('l2', ' 猫が好き '),
        ]);
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/mine',
                body: {'word': '猫', 'updateNoteId': 4},
              )
              as Map<String, Object?>;
      expect(host.calls, <String>['mine:l2:4']);
      expect(host.minedSentence, '猫が好き');
      expect(host.minedFields!['sentence'], '猫が好き');
      expect(out['ok'], isTrue);
      expect(out['result'], 'success');
      expect(out['noteId'], 9);
    });

    test('指定行不在会话 404；无台词 409；缺 word 400', () async {
      final _FakeHost host = _FakeHost()
        ..snap = withLines(<TexthookerLineEntry>[_line('l1', 'a')]);
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/mine',
          body: {'word': 'a', 'lineId': 'x'},
        ),
        _status(404),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/mine',
          body: <String, Object?>{},
        ),
        _status(400),
      );
      host.snap = withLines(const <TexthookerLineEntry>[]);
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/mine', body: {'word': 'a'}),
        _status(409),
      );
    });

    test('中止的制卡如实返回 ok=false 与原因', () async {
      final _FakeHost host = _FakeHost()
        ..snap = withLines(<TexthookerLineEntry>[_line('l1', 'a')])
        ..mineResult = const GalHookMiningResult(
          failureReason: 'captured line is no longer available',
        );
      final Map<String, Object?> out =
          await _call(
                buildGameCtlRoutesWith(host),
                'POST',
                '/api/admin/game/mine',
                body: {'word': 'a'},
              )
              as Map<String, Object?>;
      expect(out['ok'], isFalse);
      expect(out['result'], 'aborted');
      expect(out['failureReason'], contains('no longer'));
    });
  });

  group('galHookCtlStages', () {
    test('空闲：全部 not_reached，e2e 不可证明', () {
      final Map<String, String> s = _stageMap(
        galHookCtlStages(
          const GameCtlSessionSnapshot(state: GalHookSessionState()),
        ),
      );
      expect(s.keys, <String>[
        'process_found',
        'helper_ready',
        'ipc_ready',
        'text_ready',
        'resource/pcm_ready',
        'paired',
        'e2e_verified',
      ]);
      expect(s['process_found'], 'not_reached');
      expect(s['paired'], 'not_reached');
      expect(s['e2e_verified'], 'not_verifiable');
    });

    test('Loopback 降级不算 resource/pcm_ready，也不算 paired', () {
      final Map<String, String> s = _stageMap(
        galHookCtlStages(
          GameCtlSessionSnapshot(
            state: const GalHookSessionState(
              phase: GalHookSessionPhase.degraded,
              gamePid: 1,
              audioBackend: GalHookAudioBackend.systemLoopback,
            ),
            hasEngineSource: true,
            selectedThreadKey: 't1',
            sessionLines: <TexthookerLineEntry>[
              _line(
                'l1',
                'x',
                audio: TexthookerLineAudioStatus.fallback,
                backend: 'loopback',
              ),
            ],
          ),
        ),
      );
      expect(s['text_ready'], 'observed');
      expect(s['resource/pcm_ready'], 'degraded');
      expect(s['paired'], 'degraded');
    });

    test('只有 PCM 时间窗：resource/pcm observed，paired 仍 pending', () {
      final Map<String, String> s = _stageMap(
        galHookCtlStages(
          GameCtlSessionSnapshot(
            state: const GalHookSessionState(
              phase: GalHookSessionPhase.running,
              gamePid: 1,
              audioBackend: GalHookAudioBackend.enginePcm,
            ),
            hasEngineSource: true,
            sessionLines: <TexthookerLineEntry>[
              _line(
                'l1',
                'x',
                audio: TexthookerLineAudioStatus.matched,
                backend: 'engine_pcm',
              ),
            ],
          ),
        ),
      );
      expect(s['resource/pcm_ready'], 'observed');
      expect(s['paired'], 'pending');
    });

    test('事件所有权的资源配对才算 paired observed', () {
      final List<Map<String, Object?>> stages = galHookCtlStages(
        GameCtlSessionSnapshot(
          state: const GalHookSessionState(
            phase: GalHookSessionPhase.running,
            gamePid: 1,
            audioBackend: GalHookAudioBackend.gameResource,
          ),
          hasEngineSource: true,
          sessionLines: <TexthookerLineEntry>[
            _line(
              'l1',
              'x',
              audio: TexthookerLineAudioStatus.matched,
              backend: 'game_resource',
              resourceId: 'v001.ogg',
              owned: true,
            ),
          ],
        ),
      );
      expect(_stageMap(stages)['paired'], 'observed');
    });

    test('IPC 阶段失败：helper observed、ipc failed、下游 blocked', () {
      final Map<String, String> s = _stageMap(
        galHookCtlStages(
          const GameCtlSessionSnapshot(
            state: GalHookSessionState(
              phase: GalHookSessionPhase.degraded,
              gamePid: 1,
              injectorFailure: GalHookInjectorFailure.protocolMismatch,
            ),
          ),
        ),
      );
      expect(s['process_found'], 'observed');
      expect(s['helper_ready'], 'observed');
      expect(s['ipc_ready'], 'failed');
      expect(s['text_ready'], 'blocked');
      expect(s['paired'], 'blocked');
    });
  });

  group('工作台细项', () {
    _FakeHost engineHost({
      List<TexthookerLineEntry> lines = const <TexthookerLineEntry>[],
      bool engine = true,
      String? selected = 't1',
    }) => _FakeHost()
      ..snap = GameCtlSessionSnapshot(
        state: const GalHookSessionState(
          phase: GalHookSessionPhase.running,
          gamePid: 1,
          audioBackend: GalHookAudioBackend.enginePcm,
          audioTracks: <GalAudioTrack>[_track],
        ),
        hasEngineSource: engine,
        selectedThreadKey: selected,
        sessionLines: lines,
        attachedExecutable: r'C:\games\a\a.exe',
      );

    Future<Map<String, Object?>> call(
      _FakeHost host,
      String method,
      String path, {
      Map<String, Object?> body = const <String, Object?>{},
      Map<String, String> query = const <String, String>{},
    }) async =>
        await _call(
              buildGameCtlRoutesWith(host),
              method,
              path,
              body: body,
              query: query,
            )
            as Map<String, Object?>;

    test('config：转区键校验、超分接受枚举名、结果读回', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> out = await call(
        host,
        'PUT',
        '/api/admin/game/games/g1/config',
        body: {'locale': 'on', 'upscaling': 'installedOnly', 'language': 'ja'},
      );
      expect(host.calls, <String>[
        'locale:g1:on',
        'upscaling:g1:installed_only',
        'language:g1:ja',
      ]);
      expect(out['locale'], 'on');
      expect(out['appliesTo'], 'next_launch');
      final List<CtlRoute> routes = buildGameCtlRoutesWith(_FakeHost());
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/games/g1/config',
          body: {'locale': 'maybe'},
        ),
        _status(400),
      );
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/games/g1/config',
          body: <String, Object?>{},
        ),
        _status(400),
      );
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/games/zz/config',
          body: {'locale': 'on'},
        ),
        _status(404),
      );
    });

    test('bind / window-mode', () async {
      const ExternalWindowInfo w = ExternalWindowInfo(
        hwnd: 5,
        title: 'A',
        pid: 9,
      );
      final _FakeHost host = _FakeHost()
        ..windows = const <ExternalWindowInfo>[w];
      final Map<String, Object?> bound = await call(
        host,
        'POST',
        '/api/admin/game/bind',
        body: {'hwnd': 5},
      );
      expect(bound['ok'], isTrue);
      final Map<String, Object?> again = await call(
        host,
        'POST',
        '/api/admin/game/bind',
        body: {'hwnd': 5},
      );
      expect(again['unchanged'], isTrue);
      await call(host, 'POST', '/api/admin/game/bind', body: {'clear': true});
      expect(host.calls, <String>['bind:5', 'bind:null']);
      final Map<String, Object?> mode = await call(
        host,
        'PUT',
        '/api/admin/game/window-mode',
        body: {'enabled': true},
      );
      expect(mode['enabled'], isTrue);
      expect(mode['hint'], isNotNull);
    });

    test('tracks 默认先刷新；选轨 / 排除需要引擎源且轨存在', () async {
      final _FakeHost host = engineHost();
      final Map<String, Object?> list = await call(
        host,
        'GET',
        '/api/admin/game/tracks',
      );
      expect(host.calls, <String>['refresh']);
      expect(list['selectionAffectsCapture'], isTrue);
      expect(
        (list['tracks']! as List<Object?>).single,
        containsPair('ptr', 77),
      );

      final Map<String, Object?> sel = await call(
        host,
        'POST',
        '/api/admin/game/tracks/select',
        body: {'ptr': 77},
      );
      expect(sel['ok'], isTrue);
      final Map<String, Object?> ex = await call(
        host,
        'POST',
        '/api/admin/game/tracks/exclude',
        body: {'ptr': 77},
      );
      expect(ex['excluded'], isTrue);
      final Map<String, Object?> inc = await call(
        host,
        'POST',
        '/api/admin/game/tracks/exclude',
        body: {'ptr': 77, 'excluded': false},
      );
      expect(inc['excluded'], isFalse);

      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/tracks/select',
          body: {'ptr': 5},
        ),
        _status(404),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(engineHost(engine: false)),
          'POST',
          '/api/admin/game/tracks/select',
          body: {'ptr': 77},
        ),
        _status(409),
      );
    });

    test('试听：返回文件路径；--play 在 app 内播放；导出失败 409', () async {
      final _FakeHost host = engineHost(
        lines: <TexthookerLineEntry>[_line('l1', 'x')],
      );
      final Map<String, Object?> path = await call(
        host,
        'POST',
        '/api/admin/game/tracks/preview',
        body: {'ptr': 77},
      );
      expect(path['filePath'], r'C:\tmp\p.wav');
      expect(path['played'], isFalse);
      final Map<String, Object?> played = await call(
        host,
        'POST',
        '/api/admin/game/tracks/preview',
        body: {'ptr': 77, 'lineId': 'l1', 'play': true},
      );
      expect(played['played'], isTrue);
      expect(host.calls, contains('linePreview:l1:77'));
      expect(host.calls, contains(r'play:C:\tmp\p.wav'));

      host.playResult = false;
      final Map<String, Object?> failed = await call(
        host,
        'POST',
        '/api/admin/game/lines/l1/preview',
        body: {'play': true},
      );
      expect(failed['ok'], isFalse);
      expect(failed['filePath'], isNotNull);

      host.preview = null;
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'POST',
          '/api/admin/game/lines/l1/preview',
        ),
        _status(409),
      );
      await call(host, 'POST', '/api/admin/game/audio/stop');
      expect(host.calls.last, 'stopAudio');
    });

    test('音频降级策略', () async {
      final _FakeHost host = engineHost();
      final Map<String, Object?> out = await call(
        host,
        'PUT',
        '/api/admin/game/audio-policy',
        body: {'policy': 'cleanonly'},
      );
      expect(out['policy'], 'cleanOnly');
      expect(out['allowsLoopback'], isFalse);
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'PUT',
          '/api/admin/game/audio-policy',
          body: {'policy': 'loud'},
        ),
        _status(400),
      );
    });

    test('逐句选轨：成功写回，取不到 PCM 时 409', () async {
      final _FakeHost host = engineHost(
        lines: <TexthookerLineEntry>[_line('l1', 'x')],
      )..lineTracks = const <GalAudioTrack>[_track];
      final Map<String, Object?> tracks = await call(
        host,
        'GET',
        '/api/admin/game/lines/l1/tracks',
      );
      expect(tracks['chosen'], isNull);
      final Map<String, Object?> set = await call(
        host,
        'POST',
        '/api/admin/game/lines/l1/track',
        body: {'ptr': 77},
      );
      expect(set['chosen'], 77);
      host.lineTrackResult = false;
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'POST',
          '/api/admin/game/lines/l1/track',
          body: {'ptr': 77},
        ),
        _status(409),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'GET',
          '/api/admin/game/lines/nope/tracks',
        ),
        _status(404),
      );
    });

    test('补录：start → finish；并发 / 错行 409', () async {
      final _FakeHost host = engineHost(
        lines: <TexthookerLineEntry>[_line('l1', 'x'), _line('l2', 'y')],
      );
      final Map<String, Object?> start = await call(
        host,
        'POST',
        '/api/admin/game/lines/l1/recapture',
        body: {'action': 'start'},
      );
      expect(start['recapturing'], isTrue);
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/lines/l2/recapture',
          body: {'action': 'start'},
        ),
        _status(409),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/lines/l2/recapture',
          body: {'action': 'finish'},
        ),
        _status(409),
      );
      final Map<String, Object?> done = await call(
        host,
        'POST',
        '/api/admin/game/lines/l1/recapture',
        body: {'action': 'finish'},
      );
      expect(done['ok'], isTrue);
      expect(host.calls, <String>['recapStart:l1', 'recapFinish:false']);
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/lines/l1/recapture',
          body: {'action': 'finish'},
        ),
        _status(409),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/lines/l1/recapture',
          body: {'action': 'rewind'},
        ),
        _status(400),
      );
    });

    test('收藏 / 清空事件', () async {
      final _FakeHost host = engineHost(
        lines: <TexthookerLineEntry>[_line('l1', 'x')],
      );
      final Map<String, Object?> fav = await call(
        host,
        'POST',
        '/api/admin/game/lines/l1/favorite',
      );
      expect(fav['favorited'], isTrue);
      final Map<String, Object?> cleared = await call(
        host,
        'POST',
        '/api/admin/game/events/clear',
      );
      expect(cleared['ok'], isTrue);
    });

    test('文本处理：要先选线程；坏步骤 / 未知 kind 拒绝而不是静默丢', () async {
      final _FakeHost host = engineHost();
      final Map<String, Object?> set = await call(
        host,
        'PUT',
        '/api/admin/game/textproc',
        body: {
          'pipeline': <Object?>[
            <String, Object?>{'id': 'a', 'kind': 'filterControlChars'},
          ],
        },
      );
      expect(set['ok'], isTrue);
      expect(host.calls, <String>['textproc:1']);
      final Map<String, Object?> got = await call(
        host,
        'GET',
        '/api/admin/game/textproc',
      );
      expect(got['pipeline'], hasLength(1));

      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/textproc',
          body: {
            'pipeline': <Object?>[
              <String, Object?>{'id': 'a', 'kind': 'nope'},
            ],
          },
        ),
        _status(400),
      );
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/textproc',
          body: {
            'pipeline': <Object?>[
              <String, Object?>{'id': 'a', 'kind': 'filterControlChars'},
              <String, Object?>{'id': 'a', 'kind': 'filterControlChars'},
            ],
          },
        ),
        _status(400),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(engineHost(selected: null)),
          'PUT',
          '/api/admin/game/textproc',
          body: {'pipeline': <Object?>[]},
        ),
        _status(409),
      );
    });

    test('内嵌查词模式与清除校准', () async {
      final _FakeHost host = engineHost();
      final Map<String, Object?> before = await call(
        host,
        'GET',
        '/api/admin/game/lookup-mode',
      );
      expect(before['mode'], 'auto');
      expect(before['hasProfile'], isFalse);
      final Map<String, Object?> set = await call(
        host,
        'PUT',
        '/api/admin/game/lookup-mode',
        body: {'mode': 'attachedOnly'},
      );
      expect(set['ok'], isTrue);
      expect(set['mode'], 'attachedOnly');
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/lookup-profile/clear'),
        _status(400),
      );
      final Map<String, Object?> cleared = await call(
        host,
        'POST',
        '/api/admin/game/lookup-profile/clear',
        body: {'confirm': true},
      );
      expect(cleared['hasProfile'], isFalse);
      await expectLater(
        _call(
          routes,
          'PUT',
          '/api/admin/game/lookup-mode',
          body: {'mode': 'weird'},
        ),
        _status(400),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(_FakeHost()),
          'PUT',
          '/api/admin/game/lookup-mode',
          body: {'mode': 'off'},
        ),
        _status(409),
      );
    });
  });

  group('游戏条目管理', () {
    Future<Map<String, Object?>> run(
      _FakeHost host,
      String method,
      String path, {
      Map<String, Object?> body = const <String, Object?>{},
      Map<String, String> query = const <String, String>{},
    }) async =>
        await _call(
              buildGameCtlRoutesWith(host),
              method,
              path,
              body: body,
              query: query,
            )
            as Map<String, Object?>;

    test('rename 写覆盖层，--clear 回落；只读状态拒绝', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> out = await run(
        host,
        'PUT',
        '/api/admin/game/games/g1/name',
        body: {'name': '新名字'},
      );
      expect(out['title'], '新名字');
      expect(out['customName'], '新名字');
      final Map<String, Object?> cleared = await run(
        host,
        'PUT',
        '/api/admin/game/games/g1/name',
        body: {'clear': true},
      );
      expect(cleared['customName'], isNull);
      expect(cleared['title'], 'Game g1');
      await expectLater(
        _call(
          buildGameCtlRoutesWith(_FakeHost()..isMigrationReadonly = true),
          'PUT',
          '/api/admin/game/games/g1/name',
          body: {'name': 'x'},
        ),
        _status(422),
      );
    });

    test('play-status', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> out = await run(
        host,
        'PUT',
        '/api/admin/game/games/g1/play-status',
        body: {'status': 'PLAYING'},
      );
      expect(out['playStatus'], 'playing');
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'PUT',
          '/api/admin/game/games/g1/play-status',
          body: {'status': 'beaten'},
        ),
        _status(400),
      );
    });

    test('cover：文件不存在 404；--auto 找不到 ok=false', () async {
      final _FakeHost host = _FakeHost();
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'POST',
          '/api/admin/game/games/g1/cover',
          body: {'file': r'Z:\definitely\missing.png'},
        ),
        _status(404),
      );
      final Map<String, Object?> auto = await run(
        host,
        'POST',
        '/api/admin/game/games/g1/cover',
        body: {'auto': true},
      );
      expect(auto['ok'], isFalse);
      expect(host.calls, <String>['autoCover:g1']);
      host.autoCoverPath = r'C:\covers\g1.ico.png';
      final Map<String, Object?> ok = await run(
        host,
        'POST',
        '/api/admin/game/games/g1/cover',
        body: {'auto': true},
      );
      expect(ok['coverPath'], r'C:\covers\g1.ico.png');
    });

    test('edit：设置 + 清空，越界评分 / 坏日期 400', () async {
      final _FakeHost host = _FakeHost();
      await run(
        host,
        'PUT',
        '/api/admin/game/games/g1/details',
        body: {
          'launchArgs': '-w',
          'tags': 'a，b,a',
          'rating': '7',
          'releaseDate': '2020-01-02',
          'summary': 's',
        },
      );
      GalgameEntry g = host.games.single;
      expect(g.launchArgs, '-w');
      expect(g.customData.tags, <String>['a', 'b']);
      expect(g.customData.userRating, 7);
      expect(g.releaseDate, '2020-01-02');
      final Map<String, Object?> out = await run(
        host,
        'PUT',
        '/api/admin/game/games/g1/details',
        body: {
          'clear': <String>['releaseDate', 'summary', 'launchArgs'],
        },
      );
      g = host.games.single;
      expect(g.releaseDate, isNull);
      expect(g.customData.summary, isNull);
      expect(g.launchArgs, '');
      expect(g.customData.userRating, 7);
      expect(out['ok'], isTrue);
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        {'rating': '11'},
        {'releaseDate': '2020'},
        <String, Object?>{},
        {
          'clear': <String>['exePath'],
        },
        {
          'summary': 'x',
          'clear': <String>['summary'],
        },
      ]) {
        await expectLater(
          _call(routes, 'PUT', '/api/admin/game/games/g1/details', body: bad),
          _status(400),
          reason: '$bad',
        );
      }
    });

    test('remove：要 confirm；正在捕获时 409；统计失败如实返回', () async {
      final _FakeHost host = _FakeHost()..statsError = 'db locked';
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(routes, 'DELETE', '/api/admin/game/games/g1'),
        _status(400),
      );
      final _FakeHost busy = _FakeHost()
        ..snap = const GameCtlSessionSnapshot(
          state: GalHookSessionState(
            phase: GalHookSessionPhase.running,
            launchExe: r'C:\games\a\a.exe',
          ),
        );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(busy),
          'DELETE',
          '/api/admin/game/games/g1',
          query: {'confirm': 'true'},
        ),
        _status(409),
      );
      final Map<String, Object?> out = await run(
        host,
        'DELETE',
        '/api/admin/game/games/g1',
        query: {'confirm': 'true', 'deleteStatistics': 'true'},
      );
      expect(host.calls, <String>['remove:g1:true']);
      expect(out['statisticsDeleted'], isFalse);
      expect(out['statisticsError'], 'db locked');
      expect(host.games, isEmpty);
    });

    test('sessions / session-delete：只删本游戏的会话', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> list = await run(
        host,
        'GET',
        '/api/admin/game/games/g1/sessions',
      );
      expect(list['sessions'], hasLength(1));
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await expectLater(
        _call(routes, 'DELETE', '/api/admin/game/games/g1/sessions/3'),
        _status(400),
      );
      await expectLater(
        _call(
          routes,
          'DELETE',
          '/api/admin/game/games/g1/sessions/99',
          query: {'confirm': 'true'},
        ),
        _status(404),
      );
      final Map<String, Object?> del = await run(
        host,
        'DELETE',
        '/api/admin/game/games/g1/sessions/3',
        query: {'confirm': 'true'},
      );
      expect(del['ok'], isTrue);
      expect(host.calls, <String>['deleteSession:3']);
    });

    test('scrape 搜索 → apply 用缓存的候选（带封面 URL）', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> found = await run(
        host,
        'GET',
        '/api/admin/game/games/g1/scrape',
        query: {'source': 'vndb'},
      );
      expect(host.calls.single, 'scrape:Game g1:vndb');
      expect(
        (found['candidates']! as List<Object?>).single,
        containsPair('id', 'vndb:v17'),
      );
      // 同一路由表实例（缓存挂在路由对象上）。
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      await _call(routes, 'GET', '/api/admin/game/games/g1/scrape');
      await _call(
        routes,
        'POST',
        '/api/admin/game/games/g1/scrape',
        body: {'candidate': 'vndb:v17'},
      );
      expect(host.applied!.coverUrl, 'https://x/c.jpg');
      // 不在缓存里也能 apply（只需 source + externalId）。
      await run(
        host,
        'POST',
        '/api/admin/game/games/g1/scrape',
        body: {'candidate': 'bgm:123'},
      );
      expect(host.applied!.source, GalgameMetadataSource.bgm);
      expect(host.applied!.externalId, '123');

      host.applyResult = false;
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/games/g1/scrape',
          body: {'candidate': 'bgm:404'},
        ),
        _status(404),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '/api/admin/game/games/g1/scrape',
          body: {'candidate': 'anidb:1'},
        ),
        _status(400),
      );
      host.scrapeError = GalgameMetadataException('all down');
      await expectLater(
        _call(routes, 'GET', '/api/admin/game/games/g1/scrape'),
        _status(502),
      );
    });

    test('sources / source-remove', () async {
      final _FakeHost host = _FakeHost();
      final Map<String, Object?> list = await run(
        host,
        'GET',
        '/api/admin/game/games/g1/sources',
      );
      expect(list['sources'], <String>['vndb']);
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'DELETE',
          '/api/admin/game/games/g1/sources/bgm',
        ),
        _status(404),
      );
      final Map<String, Object?> out = await run(
        host,
        'DELETE',
        '/api/admin/game/games/g1/sources/vndb',
      );
      expect(out['sources'], isEmpty);
    });
  });

  group('内嵌查词截图校准', () {
    const GalAttachedSurfaceTarget target = GalAttachedSurfaceTarget(
      sessionEpoch: 1,
      surfaceEpoch: 1,
      targetPid: 10,
      targetHwnd: 20,
    );
    const GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
      widthPx: 1280,
      heightPx: 720,
      dpi: 96,
    );
    final String sha = 'a' * 64;

    _FakeHost readyHost({
      bool sampleEnabled = true,
      GalLookupSurfaceProfileV1? profile,
    }) => _FakeHost()
      ..lookup = GameCtlLookupState(
        target: target,
        currentClient: client,
        executablePath: r'C:\games\a\a.exe',
        executableSha256: sha,
        profile: profile,
        status: GalAttachedTextStatus.needsCalibration,
        sampleCalibrationEnabled: sampleEnabled,
        canCaptureCalibrationSample: sampleEnabled,
      );

    GalLookupCalibrationCapture captureOf(int hwnd) =>
        GalLookupCalibrationCapture(
          sourceText: '「テスト」',
          pngBytes: Uint8List.fromList(<int>[1, 2, 3]),
          referenceClient: client,
          exePath: r'C:\games\a\a.exe',
          exeSha256: sha,
          sessionEpoch: 1,
          occurrenceId: 'o1',
          targetHwnd: hwnd,
          capturedAt: _t0,
          selectedThreadKey: 't1',
        );

    Future<Map<String, Object?>> run(
      List<CtlRoute> routes,
      String method,
      String path, {
      Map<String, Object?> body = const <String, Object?>{},
    }) async =>
        await _call(routes, method, path, body: body) as Map<String, Object?>;

    test('lookup-profile 读当前状态', () async {
      final Map<String, Object?> out = await run(
        buildGameCtlRoutesWith(readyHost()),
        'GET',
        '/api/admin/game/lookup-profile',
      );
      expect(out['status'], 'needsCalibration');
      expect(out['currentClient'], client.toJson());
      expect(out['profile'], isNull);
    });

    test('screenshot 写文件并返回路径；不能截时 409', () async {
      final _FakeHost host = readyHost()..capture = captureOf(20);
      final Map<String, Object?> out = await run(
        buildGameCtlRoutesWith(host),
        'POST',
        '/api/admin/game/screenshot',
        body: {'output': r'C:\out\s.png'},
      );
      expect(out['path'], r'C:\out\s.png');
      expect(out['widthPx'], 1280);
      expect(host.written[r'C:\out\s.png'], <int>[1, 2, 3]);

      host.captureError = const GalLookupCalibrationCaptureException(
        GalLookupCalibrationCaptureFailure.sceneChanged,
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(host),
          'POST',
          '/api/admin/game/screenshot',
        ),
        _status(409),
      );
      await expectLater(
        _call(
          buildGameCtlRoutesWith(readyHost(sampleEnabled: false)),
          'POST',
          '/api/admin/game/screenshot',
        ),
        _status(409),
      );
    });

    test('像素 rect + grid 换算成归一值，经 applyMeasuredCalibration 落库', () async {
      final _FakeHost host = readyHost();
      final Map<String, Object?> out = await run(
        buildGameCtlRoutesWith(host),
        'POST',
        '/api/admin/game/lookup-calibrate',
        body: {
          'rect': '128,504,1024,180',
          'px': true,
          'grid': '36,54,36,26',
          'indent': '-1',
          'slot': 'dialogue',
          'acceptRisk': true,
        },
      );
      expect(out['ok'], isTrue);
      final GalLookupSurfaceVariantV1 v = host.appliedVariant!;
      expect(v.referenceClient, client);
      expect(v.bodyRect.left, closeTo(0.1, 1e-9));
      expect(v.bodyRect.top, closeTo(0.7, 1e-9));
      expect(v.bodyRect.width, closeTo(0.8, 1e-9));
      expect(v.bodyRect.height, closeTo(0.25, 1e-9));
      expect(v.layout.cellGrid!.advancePerClientHeight, closeTo(0.05, 1e-9));
      expect(
        v.layout.cellGrid!.lineAdvancePerClientHeight,
        closeTo(0.075, 1e-9),
      );
      expect(v.layout.cellGrid!.columns, 26);
      expect(v.layout.cellGrid!.continuationIndent, -1);
      expect(v.slot, GalLookupCalibrationSlotV1.dialogue);
    });

    test('首次校准要 acceptRisk；已接受过的 profile 不再要', () async {
      final List<CtlRoute> routes = buildGameCtlRoutesWith(readyHost());
      const Map<String, Object?> body = <String, Object?>{
        'rect': '0.1,0.7,0.8,0.2',
        'grid': '0.05,0.07,0.05,20',
      };
      await expectLater(
        _call(routes, 'POST', '/api/admin/game/lookup-calibrate', body: body),
        _status(400),
      );
      final _FakeHost accepted = readyHost(
        profile: GalLookupSurfaceProfileV1(
          exePath: r'C:\games\a\a.exe',
          exeSha256: sha,
          mode: GalLookupSurfaceMode.auto,
          unsafeLeftClickAccepted: true,
          variants: const <GalLookupSurfaceVariantV1>[],
        ),
      );
      final Map<String, Object?> out = await run(
        buildGameCtlRoutesWith(accepted),
        'POST',
        '/api/admin/game/lookup-calibrate',
        body: body,
      );
      expect(out['ok'], isTrue);
    });

    test('参数与状态门：越界 / 无字格 / 模式不允许 / 截图不匹配 / 未生效', () async {
      final _FakeHost host = readyHost();
      final List<CtlRoute> routes = buildGameCtlRoutesWith(host);
      Future<void> bad(Map<String, Object?> body, int status) => expectLater(
        _call(routes, 'POST', '/api/admin/game/lookup-calibrate', body: body),
        _status(status),
        reason: '$body',
      );
      await bad({
        'rect': '0.5,0.5,0.8,0.2',
        'grid': '0.05,0.07,0.05,20',
        'acceptRisk': true,
      }, 400);
      await bad({
        'rect': '0.1,0.7,0.8,0.2',
        'grid': '0.05,0.04,0.05,20',
        'acceptRisk': true,
      }, 400);
      await bad({'rect': '0.1,0.7,0.8,0.2', 'acceptRisk': true}, 400);
      await bad({
        'rect': '0.1,0.7,0.8,0.2',
        'layout': <String, Object?>{
          'fontFamily': '',
          'fontSizePerClientHeight': 0.05,
          'letterSpacingPerClientHeight': 0,
          'lineHeight': 1,
          'textAlign': 'left',
          'verticalAlign': 'top',
          'paddingPerClientHeight': 0,
        },
        'acceptRisk': true,
      }, 400);
      await bad({
        'rect': '0.1,0.7,0.8,0.2',
        'grid': '0.05,0.07,0.05,20',
        'fromScreenshot': true,
        'acceptRisk': true,
      }, 409);
      await expectLater(
        _call(
          buildGameCtlRoutesWith(readyHost(sampleEnabled: false)),
          'POST',
          '/api/admin/game/lookup-calibrate',
          body: {
            'rect': '0.1,0.7,0.8,0.2',
            'grid': '0.05,0.07,0.05,20',
            'acceptRisk': true,
          },
        ),
        _status(409),
      );

      // 截图样本属于别的窗口 → 409。
      host.capture = captureOf(99);
      await run(routes, 'POST', '/api/admin/game/screenshot');
      await bad({
        'rect': '0.1,0.7,0.8,0.2',
        'grid': '0.05,0.07,0.05,20',
        'fromScreenshot': true,
        'acceptRisk': true,
      }, 409);

      // 落库函数拒绝 → ok=false 并带状态。
      host.applyCalibrationResult = false;
      final Map<String, Object?> out = await run(
        routes,
        'POST',
        '/api/admin/game/lookup-calibrate',
        body: {
          'rect': '0.1,0.7,0.8,0.2',
          'grid': '0.05,0.07,0.05,20',
          'acceptRisk': true,
        },
      );
      expect(out['ok'], isFalse);
      expect(out['message'], contains('needsCalibration'));
    });
  });
}
