import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('PreferencesRepository video danmaku prefs', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('danmaku overlay defaults OFF with a bounded active limit', () {
      expect(repo.videoDanmakuEnabled, isFalse, reason: '弹幕默认关闭，用户显式开启后才显示');
      expect(repo.videoDanmakuMaxActive, kDefaultVideoDanmakuMaxActive);
    });

    test('persists enabled flag and clamps active limit across reload',
        () async {
      await repo.setVideoDanmakuEnabled(false);
      await repo.setVideoDanmakuMaxActive(9999);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoDanmakuEnabled, isFalse);
      expect(reloaded.videoDanmakuMaxActive, kMaxVideoDanmakuActive);
      reloaded.dispose();
    });

    test('default danmaku source config is empty (official, unsigned)', () {
      expect(repo.videoDanmakuConfig, DandanplayConfig.defaults);
    });

    test('persists danmaku server config round-trip and pushes the static',
        () async {
      const DandanplayConfig config = DandanplayConfig(
        baseUrl: 'https://mirror.example.com',
        appId: 'app-123',
        appSecret: 's3cret',
      );
      await repo.setVideoDanmakuConfig(config);

      // Writing publishes to the process-wide static the zero-arg client reads.
      expect(DandanplayConfig.current, config);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoDanmakuConfig, config);
      // loadFromDb primes the static so the in-player client picks it up at boot.
      expect(DandanplayConfig.current, config);
      reloaded.dispose();
    });

    test('loadFromDb resets the static to defaults when no config persisted',
        () async {
      DandanplayConfig.current =
          const DandanplayConfig(baseUrl: 'https://stale.example');
      await _withMultipleDatabaseWarningDisabled(() async {
        final FushiDatabase freshDb = _testDb();
        addTearDown(freshDb.close);
        final PreferencesRepository fresh = PreferencesRepository(freshDb);
        addTearDown(fresh.dispose);
        await fresh.loadFromDb();
        expect(DandanplayConfig.current, DandanplayConfig.defaults);
      });
    });
  });

  group('PreferencesRepository video auto-play-next pref (TODO-639)', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('defaults to ON (auto-play next enabled by default)', () {
      expect(repo.videoAutoPlayNext, isTrue);
    });

    test('persists the opt-out across reload', () async {
      await repo.setVideoAutoPlayNext(false);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoAutoPlayNext, isFalse,
          reason: '用户关掉自动连播后，跨重启必须记住其选择');
      reloaded.dispose();
    });
  });
  group('PreferencesRepository videoRespectAssStyle (TODO-1105)', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('defaults to ON (respect .ass style by default)', () {
      expect(repo.videoRespectAssStyle, isTrue);
    });

    test('persists the opt-out across reload', () async {
      await repo.setVideoRespectAssStyle(false);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoRespectAssStyle, isFalse,
          reason: 'user turning off respect-ass must survive restart');
      reloaded.dispose();
    });
  });

  group('PreferencesRepository video danmaku style + block rules', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('style + block rules default to neutral / empty', () {
      expect(repo.videoDanmakuStyle, VideoDanmakuStyle.defaults);
      expect(repo.videoDanmakuBlockRulesText, isEmpty);
    });

    test('persists style (clamped) and block rules across reload', () async {
      await repo.setVideoDanmakuStyle(const VideoDanmakuStyle(
        fontScale: 5.0,
        opacity: 0.4,
        speedScale: 1.5,
        areaFraction: 0.6,
      ));
      await repo.setVideoDanmakuBlockRulesText('spoiler\n' r'/^\d+$/');

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      final VideoDanmakuStyle style = reloaded.videoDanmakuStyle;
      expect(style.fontScale, VideoDanmakuStyle.maxFontScale,
          reason: 'out-of-range font scale is clamped on the way in');
      expect(style.opacity, 0.4);
      expect(style.speedScale, 1.5);
      expect(style.areaFraction, 0.6);
      expect(reloaded.videoDanmakuBlockRulesText, 'spoiler\n' r'/^\d+$/');
      reloaded.dispose();
    });
  });
}

Future<T> _withMultipleDatabaseWarningDisabled<T>(
  Future<T> Function() body,
) async {
  final bool previous = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  try {
    return await body();
  } finally {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previous;
  }
}
