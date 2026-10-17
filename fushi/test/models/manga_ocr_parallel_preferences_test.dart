import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart'
    show kMangaOcrMaxSelectableTasks;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

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

  test('越界并行值不会写入或读出超过硬顶的任务数', () async {
    await preferences.setMangaOcrParallelTasks(99);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.mangaOcrParallelTasks, kMangaOcrMaxSelectableTasks);
    reopened.dispose();

    await preferences.setMangaOcrParallelTasks(-1);
    expect(preferences.mangaOcrParallelTasks, 0);
    await preferences.setPref('manga_ocr_parallel_tasks', 99);
    expect(
      preferences.mangaOcrParallelTasks,
      kMangaOcrMaxSelectableTasks,
      reason: '来自旧配置的越界整数也必须受上限约束',
    );
  });

  test('超过 4 的选择原样保存（本机上限在排队时才收，偏好会同步到别的机器）', () async {
    await preferences.setMangaOcrParallelTasks(8);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.mangaOcrParallelTasks, 8);
    reopened.dispose();
  });

  test('本地模型默认逐列 CTC，存量 Baberu 偏好原样保留但解析回 CTC', () async {
    expect(preferences.mangaOcrLocalModel, 'manga_ctc');
    // Baberu 已于 2026-10 删除：老用户偏好里还存着 'baberu'，偏好层不改写存量
    // 值，消费方经 MangaOcrLocalModel.fromKey 落回默认的逐列 CTC。
    for (final String selected in <String>['baberu', 'manga_ctc']) {
      await preferences.setMangaOcrLocalModel(selected);
      final PreferencesRepository reopened = PreferencesRepository(database);
      await reopened.loadFromDb();
      expect(reopened.mangaOcrLocalModel, selected);
      expect(
        MangaOcrLocalModel.fromKey(reopened.mangaOcrLocalModel),
        MangaOcrLocalModel.mangaCtc,
        reason: selected,
      );
      reopened.dispose();
    }
  });
}
