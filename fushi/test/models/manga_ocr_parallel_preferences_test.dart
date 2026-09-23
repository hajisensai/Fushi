import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase database;
  late PreferencesRepository preferences;

  setUp(() async {
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    preferences = PreferencesRepository(database);
    await preferences.loadFromDb();
  });

  tearDown(() async {
    preferences.dispose();
    await database.close();
  });

  test('OCR 并行任务默认自动，选择 4 与恢复自动都写穿数据库', () async {
    expect(preferences.mangaOcrParallelTasks, 0);
    for (final int selected in <int>[4, 0]) {
      await preferences.setMangaOcrParallelTasks(selected);
      expect(preferences.mangaOcrParallelTasks, selected);

      final PreferencesRepository reopened = PreferencesRepository(database);
      await reopened.loadFromDb();
      expect(
        reopened.mangaOcrParallelTasks,
        selected,
        reason: '重新创建偏好仓库后必须读取已保存的选择',
      );
      reopened.dispose();
    }
  });

  test('越界并行值不会写入或读出超过 4 的任务数', () async {
    await preferences.setMangaOcrParallelTasks(99);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.mangaOcrParallelTasks, 4);
    reopened.dispose();

    await preferences.setMangaOcrParallelTasks(-1);
    expect(preferences.mangaOcrParallelTasks, 0);
    await preferences.setPref('manga_ocr_parallel_tasks', 99);
    expect(preferences.mangaOcrParallelTasks, 4, reason: '来自旧配置的越界整数也必须受上限约束');
  });

  test('本地模型默认 manga-ocr，Baberu 与切回选择都持久化', () async {
    expect(preferences.mangaOcrLocalModel, 'manga_ocr');
    for (final String selected in <String>['baberu', 'manga_ocr']) {
      await preferences.setMangaOcrLocalModel(selected);
      final PreferencesRepository reopened = PreferencesRepository(database);
      await reopened.loadFromDb();
      expect(reopened.mangaOcrLocalModel, selected);
      reopened.dispose();
    }
  });
}
