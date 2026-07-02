import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('PreferencesRepository video danmaku prefs', () {
    late HibikiDatabase db;
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

    test('defaults enable local sidecar MVP with a bounded active limit', () {
      expect(repo.videoDanmakuEnabled, isTrue);
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
      final HibikiDatabase freshDb = _testDb();
      addTearDown(freshDb.close);
      final PreferencesRepository fresh = PreferencesRepository(freshDb);
      addTearDown(fresh.dispose);
      await fresh.loadFromDb();
      expect(DandanplayConfig.current, DandanplayConfig.defaults);
    });
  });

  group('PreferencesRepository video auto-play-next pref (TODO-639)', () {
    late HibikiDatabase db;
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
    late HibikiDatabase db;
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
}
