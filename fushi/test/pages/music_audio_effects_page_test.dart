/// 音效页：页面 → 偏好 → 引擎下发的 `MusicOutputSettings.effects` 全链路（不经 mpv），
/// MD3 / Apple 两套、窄屏单栏与宽屏双栏、预设 / 推子 / 曲线拖点 / 复位 / 不支持的后端说明。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/media/music/music_audio_effects_prefs.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_audio_effects_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  MusicOutputSettings? applied;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async =>
      applied = settings;

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async {}

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

class _App extends AppModel {
  _App({
    required this.db,
    required this.backend,
    required PreferencesRepository prefs,
    required Directory dir,
    required bool signalPath,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
    _engine = MusicPlayerEngine(
      backendFactory: () => backend,
      baseSettings: () => MusicOutputSettings(
        gapless: true,
        replayGain: MusicReplayGainMode.off,
        effects: readMusicAudioEffectsPrefs(prefs),
      ),
      capabilitiesOf: (MusicPlayItem _) => signalPath
          ? MusicBackendCapabilities.full
          : const MusicBackendCapabilities(signalPath: false, abLoop: false),
    );
  }

  final FushiDatabase db;
  final _Backend backend;
  late final MusicPlayerEngine _engine;

  late final MusicSession _session = MusicSession(
    engine: _engine,
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  @override
  MusicSession get musicSession => _session;
}

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _Backend backend;
  late PreferencesRepository prefs;

  Future<_App> makeApp({bool signalPath = true}) async {
    final _App app = _App(
      db: db,
      backend: backend,
      prefs: prefs,
      dir: dir,
      signalPath: signalPath,
    );
    await app.musicSession.engine.playQueue(<MusicPlayItem>[
      MusicPlayItem(
        trackUid: 'uid-1',
        path: '${dir.path}${Platform.pathSeparator}song.flac',
        title: 'Song',
        durationMs: 60000,
      ),
    ]);
    return app;
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_fx_page_');
    File(
      '${dir.path}${Platform.pathSeparator}song.flac',
    ).writeAsBytesSync(<int>[0]);
    backend = _Backend();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 留给系统清。
    }
  });

  Future<void> pump(
    WidgetTester tester,
    AppModel app, {
    required double width,
    bool apple = false,
  }) async {
    LocaleSettings.setLocale(AppLocale.en);
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              extensions: <ThemeExtension<dynamic>>[
                FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
              ],
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: MusicAudioEffectsBody(appModel: app),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 写回是异步的（偏好 + 引擎下发）：在真异步区里等它落地。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds 窄屏：总开关 → 选预设 → 偏好与引擎都拿到增益表、出提示条', (
      WidgetTester tester,
    ) async {
      final _App app = await makeApp();
      await pump(tester, app, width: 420, apple: apple);
      expect(
        find.byKey(const ValueKey<String>('music-effects-active-banner')),
        findsNothing,
      );
      // 窄屏：10 段竖推子、chip 组预设。
      for (final int hz in kMusicEqualizerBandsHz) {
        expect(
          find.byKey(ValueKey<String>('music-eq-band-$hz')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey<String>('music-eq-curve')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('music-effects-enabled')),
      );
      await settle(tester);
      expect(prefs.musicEqEnabled, isTrue);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('music-eq-preset-rock')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('music-eq-preset-rock')),
      );
      await settle(tester);
      expect(prefs.musicEqPreset, 'rock');
      expect(
        MusicAudioEffects.parseGains(prefs.musicEqGains),
        MusicEqPreset.rock.gainsDb,
      );
      expect(backend.applied?.effects.gainsDb, MusicEqPreset.rock.gainsDb);
      expect(backend.applied?.effects.isActive, isTrue);
      expect(
        find.byKey(const ValueKey<String>('music-effects-active-banner')),
        findsOneWidget,
      );
    });

    testWidgets('$ds 窄屏：拖一段推子即落到自定义；全部复位回平直、提示条消失', (
      WidgetTester tester,
    ) async {
      await writeMusicAudioEffectsPrefs(
        prefs,
        MusicAudioEffects(
          enabled: true,
          gainsDb: List<double>.of(MusicEqPreset.pop.gainsDb!),
          mono: true,
        ),
        preset: MusicEqPreset.pop,
      );
      final _App app = await makeApp();
      await pump(tester, app, width: 420, apple: apple);
      final Finder fader = find.byKey(
        const ValueKey<String>('music-eq-band-1000'),
      );
      await tester.ensureVisible(fader);
      await tester.drag(fader, const Offset(0, -60));
      await settle(tester);
      expect(prefs.musicEqPreset, 'custom');
      final double g1k = MusicAudioEffects.parseGains(prefs.musicEqGains)[5];
      expect(g1k, greaterThan(MusicEqPreset.pop.gainsDb![5]));
      expect(backend.applied?.effects.gainsDb[5], g1k);

      final Finder reset = find.byKey(
        const ValueKey<String>('music-effects-reset'),
      );
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await settle(tester);
      final MusicAudioEffects after = readMusicAudioEffectsPrefs(prefs);
      expect(after.enabled, isTrue, reason: '复位不动总开关');
      expect(after.isNeutral, isTrue);
      expect(prefs.musicEqPreset, 'flat');
      expect(backend.applied?.effects.isActive, isFalse);
      expect(musicAudioEffectsAf(backend.applied!.effects), isNull);
      expect(
        find.byKey(const ValueKey<String>('music-effects-active-banner')),
        findsNothing,
      );
    });

    testWidgets('$ds 宽屏双栏：竖排预设、拖曲线上的点改那一段', (WidgetTester tester) async {
      await writeMusicAudioEffectsPrefs(
        prefs,
        const MusicAudioEffects(enabled: true),
        preset: MusicEqPreset.flat,
      );
      final _App app = await makeApp();
      await pump(tester, app, width: 1200, apple: apple);
      // 宽屏没有 10 个竖推子（数值在曲线下方），前级是竖推子。
      expect(
        find.byKey(const ValueKey<String>('music-eq-band-1000')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('music-eq-preamp')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('music-eq-preset-vocal')),
        findsOneWidget,
      );

      final Finder curve = find.byKey(const ValueKey<String>('music-eq-curve'));
      final Rect r = tester.getRect(curve);
      // 1 kHz 的横坐标处按下，往上拖。
      final double x = r.left + MusicEqCurve.xOf(1000, r.width);
      final TestGesture g = await tester.startGesture(Offset(x, r.center.dy));
      await g.moveBy(const Offset(0, -20));
      await g.moveBy(const Offset(0, -30));
      await g.up();
      await settle(tester);
      final List<double> gains = MusicAudioEffects.parseGains(
        prefs.musicEqGains,
      );
      expect(gains[5], greaterThan(0));
      for (int i = 0; i < gains.length; i++) {
        if (i != 5) expect(gains[i], 0, reason: '只改抓住的那一段');
      }
      expect(prefs.musicEqPreset, 'custom');

      await tester.tap(
        find.byKey(const ValueKey<String>('music-eq-preset-vocal')),
      );
      await settle(tester);
      expect(
        MusicAudioEffects.parseGains(prefs.musicEqGains),
        MusicEqPreset.vocal.gainsDb,
      );
    });
  }

  testWidgets('托管播放的后端（Apple Music）：页内说明音效不生效', (WidgetTester tester) async {
    final _App app = await makeApp(signalPath: false);
    await pump(tester, app, width: 420);
    expect(
      find.byKey(const ValueKey<String>('music-effects-unsupported')),
      findsOneWidget,
    );
  });

  test('入口副标题：关 / 开 · 预设 · 限幅器', () {
    LocaleSettings.setLocale(AppLocale.en);
    expect(
      musicAudioEffectsStatusLabel(
        const MusicAudioEffects(),
        MusicEqPreset.flat,
      ),
      t.music_eq_off,
    );
    expect(
      musicAudioEffectsStatusLabel(
        const MusicAudioEffects(enabled: true, limiter: true),
        MusicEqPreset.vocal,
      ),
      'On · Vocal · Limiter',
    );
  });
}
