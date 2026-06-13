import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
