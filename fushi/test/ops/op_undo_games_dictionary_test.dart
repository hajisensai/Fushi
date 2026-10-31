import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ops/ctl_game_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_descriptions_games.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 游戏与词典域写操作的撤销往返（spec §11）：经 [OpInvoker] 以模型身份执行 →
/// `undo.revert` → 状态回到执行前；执行后被手动改过的，撤销报 superseded 且不覆盖。

// ── 假 app：游戏仓储 + 词典仓库 ─────────────────────────────────────────────

class _FakeGalgameRepo implements GalgameRepository {
  List<GalgameEntry> entries = <GalgameEntry>[];

  @override
  List<GalgameEntry> get games => entries;

  @override
  bool get isLoaded => true;

  @override
  Future<List<GalgameEntry>> load() async => entries;

  @override
  GalgameEntry? byId(String id) {
    for (final GalgameEntry g in entries) {
      if (g.id == id) return g;
    }
    return null;
  }

  void replace(String id, GalgameEntry Function(GalgameEntry g) f) {
    entries = <GalgameEntry>[
      for (final GalgameEntry g in entries) g.id == id ? f(g) : g,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  final _FakeGalgameRepo repo = _FakeGalgameRepo();

  /// 词典仓库的「已提交」状态；读出去的一律是拷贝（与真仓库同纪律）。
  final List<Dictionary> stored = <Dictionary>[];

  @override
  GalgameRepository get galgameRepo => repo;

  @override
  bool moduleEnabled(ModuleId module) => true;

  Dictionary _copy(Dictionary d) => Dictionary.fromJson(d.toJson());

  Dictionary _stored(String name) =>
      stored.singleWhere((Dictionary d) => d.name == name);

  List<Dictionary> _ofType(DictionaryType type) => (<Dictionary>[
    for (final Dictionary d in stored)
      if (d.type == type) _copy(d),
  ]..sort((Dictionary a, Dictionary b) => a.order.compareTo(b.order)));

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
    for (final Dictionary d in stored) _copy(d),
  ];

  @override
  List<Dictionary> get termDictionaries => _ofType(DictionaryType.term);

  @override
  List<Dictionary> get freqDictionaries => _ofType(DictionaryType.frequency);

  @override
  List<Dictionary> get pitchDictionaries => _ofType(DictionaryType.pitch);

  @override
  List<Dictionary> get kanjiSectionDictionaries =>
      kanjiSectionDictionariesOf(dictionaries);

  @override
  Future<void> toggleDictionaryHidden(Dictionary dictionary) async {
    final Dictionary d = _stored(dictionary.name);
    final String ja = JapaneseLanguage.instance.languageCode;
    d.hiddenLanguages = d.hiddenLanguages.contains(ja)
        ? <String>[
            for (final String l in d.hiddenLanguages)
              if (l != ja) l,
          ]
        : <String>[...d.hiddenLanguages, ja];
  }

  @override
  Future<void> updateDictionaryOrder(List<Dictionary> newDictionaries) async {
    for (final Dictionary d in newDictionaries) {
      _stored(d.name).order = d.order;
    }
  }

  @override
  Future<void> setDictionaryDisplayName(
    Dictionary dictionary,
    String? displayName,
  ) async {
    final String? v = displayName?.trim();
    _stored(dictionary.name).displayName =
        (v == null || v.isEmpty || v == dictionary.name) ? null : v;
  }

  @override
  Future<void> setDictionaryLanguageOverride(
    Dictionary dictionary,
    String? language,
  ) async {
    _stored(dictionary.name).languageOverride = language;
  }

  @override
  Future<void> deleteDictionary(Dictionary dictionary) async {
    stored.removeWhere((Dictionary d) => d.name == dictionary.name);
  }

  /// 导入 = 按文件名（去扩展名）新增一本 term 词典。
  @override
  Future<void> importDictionary({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    List<File> cssFiles = const <File>[],
    List<Directory> fontDirs = const <Directory>[],
    VoidCallback? onMemoryError,
    bool forceReplaceExisting = false,
    Map<String, String>? sourceOverride,
    Dictionary? replaceTarget,
  }) async {
    final String name = file.uri.pathSegments.last.split('.').first;
    stored.add(
      Dictionary(
        name: name,
        formatKey: 'yomichan',
        order: stored.length,
        hiddenLanguages: <String>[],
      ),
    );
    onImportSuccess();
  }
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// ── 假 Hook 宿主：会话状态在内存里，条目写进假仓储 ───────────────────────────

const GalAudioTrack _trackA = GalAudioTrack(
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

const GalAudioTrack _trackB = GalAudioTrack(
  sourcePtr: 88,
  format: PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  ),
  avgBytes: 100,
  avgEnergy: 0.4,
  orderIndex: 1,
  clipCount: 2,
);

const ExternalWindowInfo _windowA = ExternalWindowInfo(
  hwnd: 5,
  title: 'A',
  pid: 100,
);
const ExternalWindowInfo _windowB = ExternalWindowInfo(
  hwnd: 6,
  title: 'B',
  pid: 101,
);

class _GameHost implements GameCtlHost {
  _GameHost(this.repo);

  final _FakeGalgameRepo repo;

  GalHookSessionState state = const GalHookSessionState(
    phase: GalHookSessionPhase.running,
    boundWindow: _windowA,
    audioTracks: <GalAudioTrack>[_trackA, _trackB],
    selectedAudioSourcePtr: 77,
  );
  List<TexthookerTextThread> threads = <TexthookerTextThread>[
    for (final String key in <String>['t1', 't2'])
      TexthookerTextThread(
        key: key,
        label: key,
        lineCount: 0,
        latestAt: DateTime.utc(2026, 10, 26),
        observedLineCount: 1,
      ),
  ];
  String? selectedThread = 't1';
  List<TexthookerLineEntry> lines = <TexthookerLineEntry>[
    TexthookerLineEntry(
      id: 'l1',
      text: 'こんにちは',
      source: TexthookerLineSource.values.first,
      receivedAt: DateTime.utc(2026, 10, 26),
      textThreadKey: 't1',
    ),
  ];
  final Map<String, int> lineTrack = <String, int>{'l1': 77};
  GalLookupSurfaceMode? attachedMode = GalLookupSurfaceMode.auto;

  @override
  bool get isWindows => true;
  @override
  bool get gamesModuleEnabled => true;
  @override
  bool get isMigrationReadonly => false;

  @override
  Future<List<GalgameEntry>> loadGames() async => repo.entries;

  @override
  GameCtlSessionSnapshot snapshot() => GameCtlSessionSnapshot(
    state: state,
    hasEngineSource: true,
    textThreads: threads,
    selectedThreadKey: selectedThread,
    sessionLines: lines,
    attachedExecutable: r'C:\games\a\a.exe',
    attachedMode: attachedMode,
  );

  @override
  String visibleText(TexthookerLineEntry entry) => entry.text;

  @override
  Future<bool> selectThread(TexthookerTextThread? thread) async {
    selectedThread = thread?.key;
    return true;
  }

  @override
  Future<List<ExternalWindowInfo>> listWindows() async =>
      const <ExternalWindowInfo>[_windowA, _windowB];

  @override
  Future<void> bindWindow(ExternalWindowInfo? window) async {
    state = window == null
        ? state.copyWith(clearBoundWindow: true)
        : state.copyWith(boundWindow: window);
  }

  @override
  Future<void> refreshAudioTracks() async {}

  @override
  void selectVoiceTrack(int sourcePtr) =>
      state = state.copyWith(selectedAudioSourcePtr: sourcePtr);

  @override
  void setTrackExcluded(int sourcePtr, bool excluded) {
    final Set<int> next = <int>{...state.excludedAudioSourcePtrs};
    excluded ? next.add(sourcePtr) : next.remove(sourcePtr);
    state = state.copyWith(excludedAudioSourcePtrs: next);
  }

  @override
  void setAudioFallbackPolicy(GalAudioFallbackPolicy policy) =>
      state = state.copyWith(audioFallbackPolicy: policy);

  @override
  Future<List<GalAudioTrack>> tracksForLine(String lineId) async =>
      const <GalAudioTrack>[_trackA, _trackB];

  @override
  int? lineVoiceSourcePtr(String lineId) => lineTrack[lineId];

  @override
  Future<bool> setLineVoiceTrack(String lineId, int sourcePtr) async {
    lineTrack[lineId] = sourcePtr;
    return true;
  }

  @override
  bool? toggleLineFavorite(String lineId) {
    bool? now;
    lines = <TexthookerLineEntry>[
      for (final TexthookerLineEntry l in lines)
        if (l.id == lineId) l.copyWith(favorited: now = !l.favorited) else l,
    ];
    return now;
  }

  @override
  Future<void> setLookupMode(GalLookupSurfaceMode mode) async =>
      attachedMode = mode;

  @override
  Future<void> setGameJapaneseLocaleMode(String gameId, String modeKey) async =>
      repo.replace(
        gameId,
        (GalgameEntry g) => g.copyWith(japaneseLocaleMode: modeKey),
      );

  @override
  Future<void> setGameUpscalingMode(String gameId, String modeKey) async => repo
      .replace(gameId, (GalgameEntry g) => g.copyWith(upscalingMode: modeKey));

  @override
  Future<void> setGameLanguage(String gameId, String? language) async =>
      repo.replace(
        gameId,
        (GalgameEntry g) => GalgameEntry(
          id: g.id,
          name: g.name,
          exePath: g.exePath,
          workdir: g.workdir,
          launchArgs: g.launchArgs,
          upscalingMode: g.upscalingMode,
          japaneseLocaleMode: g.japaneseLocaleMode,
          language: language,
          addedAt: g.addedAt,
          playStatus: g.playStatus,
          releaseDate: g.releaseDate,
          customData: g.customData,
        ),
      );

  @override
  Future<void> setCustomData(String gameId, GalgameCustomData custom) async =>
      repo.replace(gameId, (GalgameEntry g) => g.copyWith(customData: custom));

  @override
  Future<void> setPlayStatus(String gameId, GalgamePlayStatus status) async =>
      repo.replace(gameId, (GalgameEntry g) => g.copyWith(playStatus: status));

  @override
  Future<void> updateEntry(GalgameEntry entry) async =>
      repo.replace(entry.id, (GalgameEntry g) => entry);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestAppModel app;
  late _GameHost host;
  late OpCatalog catalog;
  late OpInvoker invoker;

  setUp(() {
    gameOpsPlatformSupported = () => true;
    app = _TestAppModel();
    app.repo.entries = <GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'Game 1',
        exePath: r'C:\games\a\a.exe',
        workdir: r'C:\games\a',
        launchArgs: '-w',
        addedAt: DateTime.utc(2026, 10, 1),
        customData: const GalgameCustomData(
          summary: 'old summary',
          tags: <String>['a', 'b'],
          userRating: 7,
        ),
      ),
    ];
    app.stored.addAll(<Dictionary>[
      for (final (int i, String n) in <(int, String)>[
        (0, 'JMdict'),
        (1, 'Daijirin'),
        (2, 'Meikyo'),
      ])
        Dictionary(
          name: n,
          formatKey: 'yomichan',
          order: i,
          hiddenLanguages: <String>[],
        ),
    ]);
    host = _GameHost(app.repo);
    final OpContext context = OpContext(ref: _Ref(app));
    final List<CtlRoute> routes = <CtlRoute>[
      for (final CtlRoute r in buildDomainOpRoutes(context))
        if (!r.pattern.startsWith('/api/admin/game/')) r,
      ...buildGameCtlRoutesWith(host),
    ];
    catalog = buildAppOpCatalog(context, routes);
    invoker = OpInvoker(catalog);
  });

  tearDown(() => gameOpsPlatformSupported = () => Platform.isWindows);

  Future<OpUndoRecord> run(String id, Map<String, Object?> args) async {
    final OpInvocation done = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
    );
    expect(done.undo, isNotNull, reason: '$id 应返回撤销载荷');
    return done.undo!;
  }

  Future<OpUndoStatus> undo(String id, OpUndoRecord record) async =>
      (await catalog[id]!.undo!.revert(record.payload)).status;

  GalgameEntry game() => app.repo.byId('g1')!;

  group('游戏条目快照（仓储读旧值、写路由写回）', () {
    test('game.rename：撤销清掉自定义名', () async {
      final OpUndoRecord r = await run('game.rename', <String, Object?>{
        'id': 'g1',
        'name': 'My Game',
      });
      expect(game().customData.name, 'My Game');
      expect(await undo('game.rename', r), OpUndoStatus.done);
      expect(game().customData.name, isNull);
      expect(game().customData.summary, 'old summary', reason: '别的覆盖项不受影响');
    });

    test('game.rename：执行后被手动改名 → superseded 且不覆盖', () async {
      final OpUndoRecord r = await run('game.rename', <String, Object?>{
        'id': 'game:g1',
        'name': 'My Game',
      });
      await host.setCustomData(
        'g1',
        const GalgameCustomData(name: 'Hand edited'),
      );
      expect(await undo('game.rename', r), OpUndoStatus.superseded);
      expect(game().customData.name, 'Hand edited');
    });

    test('game.play-status.set', () async {
      final GalgamePlayStatus before = game().playStatus;
      final GalgamePlayStatus target = GalgamePlayStatus.values.firstWhere(
        (GalgamePlayStatus s) => s != before,
      );
      final OpUndoRecord r = await run(
        'game.play-status.set',
        <String, Object?>{'id': 'g1', 'status': target.name},
      );
      expect(game().playStatus, target);
      expect(await undo('game.play-status.set', r), OpUndoStatus.done);
      expect(game().playStatus, before);
    });

    test('game.edit：设值 + 清空的字段都写回原值', () async {
      final OpUndoRecord r = await run('game.edit', <String, Object?>{
        'id': 'g1',
        'launchArgs': '-fullscreen',
        'tags': 'x, y',
        'developer': 'Studio',
        'clear': <String>['summary', 'rating'],
      });
      expect(game().launchArgs, '-fullscreen');
      expect(game().customData.tags, <String>['x', 'y']);
      expect(game().customData.summary, isNull);
      expect(await undo('game.edit', r), OpUndoStatus.done);
      expect(game().launchArgs, '-w');
      expect(game().customData.tags, <String>['a', 'b']);
      expect(game().customData.developer, isNull);
      expect(game().customData.summary, 'old summary');
      expect(game().customData.userRating, 7);
    });

    test('game.config.set：转区 / 语言写回', () async {
      final OpUndoRecord r = await run('game.config.set', <String, Object?>{
        'id': 'g1',
        'locale': 'on',
        'language': 'ja',
      });
      expect(game().japaneseLocaleMode, 'on');
      expect(game().language, 'ja');
      expect(await undo('game.config.set', r), OpUndoStatus.done);
      expect(game().japaneseLocaleMode, 'off', reason: '未设置按解析层回落值 off 写回');
      expect(game().language, isNull);
    });
  });

  group('会话细项快照（读路由取旧值）', () {
    test('game.thread.select：撤销选回原线程；被手动换过 → superseded', () async {
      final OpUndoRecord r = await run('game.thread.select', <String, Object?>{
        'key': 't2',
      });
      expect(host.selectedThread, 't2');
      expect(await undo('game.thread.select', r), OpUndoStatus.done);
      expect(host.selectedThread, 't1');

      final OpUndoRecord again = await run(
        'game.thread.select',
        <String, Object?>{'clear': true},
      );
      expect(host.selectedThread, isNull);
      host.selectedThread = 't2';
      expect(await undo('game.thread.select', again), OpUndoStatus.superseded);
      expect(host.selectedThread, 't2');
    });

    test('game.window.bind：撤销绑回原窗口', () async {
      final OpUndoRecord r = await run('game.window.bind', <String, Object?>{
        'hwnd': 6,
      });
      expect(host.state.boundWindow?.hwnd, 6);
      expect(await undo('game.window.bind', r), OpUndoStatus.done);
      expect(host.state.boundWindow?.hwnd, 5);
    });

    test('game.track.select / game.track.exclude（按 body 里的 ptr 取快照）', () async {
      final OpUndoRecord sel = await run('game.track.select', <String, Object?>{
        'ptr': 88,
      });
      expect(host.state.selectedAudioSourcePtr, 88);
      expect(await undo('game.track.select', sel), OpUndoStatus.done);
      expect(host.state.selectedAudioSourcePtr, 77);

      final OpUndoRecord ex = await run('game.track.exclude', <String, Object?>{
        'ptr': 88,
      });
      expect(host.state.excludedAudioSourcePtrs, <int>{88});
      expect(await undo('game.track.exclude', ex), OpUndoStatus.done);
      expect(host.state.excludedAudioSourcePtrs, isEmpty);

      final OpUndoRecord ex2 = await run(
        'game.track.exclude',
        <String, Object?>{'ptr': 88},
      );
      host.setTrackExcluded(88, false);
      expect(await undo('game.track.exclude', ex2), OpUndoStatus.superseded);
      expect(host.state.excludedAudioSourcePtrs, isEmpty);
    });

    test('game.audio-policy.set', () async {
      final GalAudioFallbackPolicy before = host.state.audioFallbackPolicy;
      final GalAudioFallbackPolicy target = GalAudioFallbackPolicy.values
          .firstWhere((GalAudioFallbackPolicy p) => p != before);
      final OpUndoRecord r = await run(
        'game.audio-policy.set',
        <String, Object?>{'policy': target.storageKey},
      );
      expect(host.state.audioFallbackPolicy, target);
      expect(await undo('game.audio-policy.set', r), OpUndoStatus.done);
      expect(host.state.audioFallbackPolicy, before);
    });

    test(
      'game.line.track.set / game.line.favorite / game.lookup-mode.set',
      () async {
        final OpUndoRecord track = await run(
          'game.line.track.set',
          <String, Object?>{'id': 'l1', 'ptr': 88},
        );
        expect(host.lineTrack['l1'], 88);
        expect(await undo('game.line.track.set', track), OpUndoStatus.done);
        expect(host.lineTrack['l1'], 77);

        final OpUndoRecord fav = await run(
          'game.line.favorite',
          <String, Object?>{'id': 'l1'},
        );
        expect(host.lines.single.favorited, isTrue);
        expect(await undo('game.line.favorite', fav), OpUndoStatus.done);
        expect(host.lines.single.favorited, isFalse);

        final OpUndoRecord fav2 = await run(
          'game.line.favorite',
          <String, Object?>{'id': 'l1'},
        );
        host.toggleLineFavorite('l1');
        expect(await undo('game.line.favorite', fav2), OpUndoStatus.superseded);
        expect(host.lines.single.favorited, isFalse);

        final OpUndoRecord mode = await run(
          'game.lookup-mode.set',
          <String, Object?>{'mode': 'off'},
        );
        expect(host.attachedMode, GalLookupSurfaceMode.off);
        expect(await undo('game.lookup-mode.set', mode), OpUndoStatus.done);
        expect(host.attachedMode, GalLookupSurfaceMode.auto);
      },
    );

    test('非 Windows：游戏操作整体不可用', () async {
      gameOpsPlatformSupported = () => false;
      expect(
        catalog['game.list']!.currentAvailability().code,
        'platform_unsupported',
      );
    });
  });

  group('词典', () {
    Map<String, Dictionary> byName() => <String, Dictionary>{
      for (final Dictionary d in app.stored) d.name: d,
    };
    List<String> termOrder() => <String>[
      for (final Dictionary d in app.termDictionaries) d.name,
    ];

    test('dict.set：启停 + 排序 + 显示名一次撤销回原样', () async {
      final OpUndoRecord r = await run('dict.set', <String, Object?>{
        'name': 'Meikyo',
        'enabled': false,
        'position': 1,
        'displayName': '明鏡',
      });
      expect(termOrder(), <String>['Meikyo', 'JMdict', 'Daijirin']);
      expect(byName()['Meikyo']!.isHidden(JapaneseLanguage.instance), isTrue);
      expect(byName()['Meikyo']!.displayName, '明鏡');
      expect(await undo('dict.set', r), OpUndoStatus.done);
      expect(termOrder(), <String>['JMdict', 'Daijirin', 'Meikyo']);
      expect(byName()['Meikyo']!.isHidden(JapaneseLanguage.instance), isFalse);
      expect(byName()['Meikyo']!.displayName, isNull);
    });

    test('dict.set：执行后被手动重排 → superseded 且不覆盖', () async {
      final OpUndoRecord r = await run('dict.set', <String, Object?>{
        'name': 'Meikyo',
        'position': 1,
      });
      await invoker.invoke('dict.set', <String, Object?>{
        'name': 'JMdict',
        'position': 1,
      });
      expect(termOrder(), <String>['JMdict', 'Meikyo', 'Daijirin']);
      expect(await undo('dict.set', r), OpUndoStatus.superseded);
      expect(termOrder(), <String>['JMdict', 'Meikyo', 'Daijirin']);
    });

    test('dict.set：position 按语言组算，撤销回组内原位 (D_Nz5R4vSH)', () async {
      app.stored.add(
        Dictionary(
          name: 'OALD',
          formatKey: 'yomichan',
          order: 1,
          languageOverride: 'en',
          hiddenLanguages: <String>[],
        ),
      );
      byName()['Daijirin']!.order = 2;
      byName()['Meikyo']!.order = 3;
      expect(termOrder(), <String>['JMdict', 'OALD', 'Daijirin', 'Meikyo']);
      final OpUndoRecord r = await run('dict.set', <String, Object?>{
        'name': 'Meikyo',
        'position': 1,
      });
      // 未标注语言组（JMdict / Daijirin / Meikyo）内第 1 位。分区写回规范顺序
      // （`concatenateLanguageGroups`：已标注组在前、未标注组在后，首尾相接），
      // 旧数据里 OALD 夹在未标注组中间的跨组交错一并消掉（管理页显示顺序 == 查词顺序）。
      expect(termOrder(), <String>['OALD', 'Meikyo', 'JMdict', 'Daijirin']);
      expect(await undo('dict.set', r), OpUndoStatus.done);
      // 撤销回**组内**原位（未标注组第 3 位）；撤销同样走 PUT，写回的仍是规范顺序，
      // 不会再造出跨组交错。
      expect(termOrder(), <String>['OALD', 'JMdict', 'Daijirin', 'Meikyo']);
    });

    test('dict.import：撤销删掉刚导入的那本', () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_dict_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File('${dir.path}/Kenkyusha.zip')
        ..writeAsBytesSync(<int>[0]);
      final OpUndoRecord r = await run('dict.import', <String, Object?>{
        'paths': <String>[file.path],
      });
      expect(byName().keys, contains('Kenkyusha'));
      expect(await undo('dict.import', r), OpUndoStatus.done);
      expect(byName().keys, <String>['JMdict', 'Daijirin', 'Meikyo']);
      // 已被手动删掉：撤销报 superseded，不报错。
      final OpUndoRecord again = await run('dict.import', <String, Object?>{
        'paths': <String>[file.path],
      });
      app.stored.removeWhere((Dictionary d) => d.name == 'Kenkyusha');
      expect(await undo('dict.import', again), OpUndoStatus.superseded);
    });
  });
}
