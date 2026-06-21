import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/models/preferences_repository.dart';

import 'video_hibiki_page_source_corpus.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  // TODO-152 sub-B: video picture-fit mode preference + BoxFit mapping.

  group('videoFitModeToBoxFit', () {
    test('cover -> BoxFit.cover (keep ratio, fill, crop edges)', () {
      expect(videoFitModeToBoxFit(VideoFitMode.cover), BoxFit.cover);
    });

    test('contain -> BoxFit.contain (keep ratio, add black bars)', () {
      expect(videoFitModeToBoxFit(VideoFitMode.contain), BoxFit.contain);
    });

    test('fill -> BoxFit.fill (stretch, no ratio)', () {
      expect(videoFitModeToBoxFit(VideoFitMode.fill), BoxFit.fill);
    });
  });

  group('VideoFitMode.fromStorage', () {
    test('round-trips every mode through its storageValue', () {
      for (final VideoFitMode mode in VideoFitMode.values) {
        expect(VideoFitMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('unknown / legacy value falls back to contain', () {
      expect(VideoFitMode.fromStorage(''), VideoFitMode.contain);
      expect(VideoFitMode.fromStorage('bogus'), VideoFitMode.contain);
    });
  });

  group('PreferencesRepository.videoFitMode', () {
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

    test('defaults to contain for new installs', () {
      expect(repo.videoFitMode, VideoFitMode.contain);
    });

    test('preserves an existing cover preference across a reload', () async {
      await repo.setVideoFitMode(VideoFitMode.cover);
      expect(repo.videoFitMode, VideoFitMode.cover);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoFitMode, VideoFitMode.cover);
      reloaded.dispose();
    });

    test('preserves an existing fill preference across a reload', () async {
      await repo.setVideoFitMode(VideoFitMode.fill);
      expect(repo.videoFitMode, VideoFitMode.fill);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoFitMode, VideoFitMode.fill);
      reloaded.dispose();
    });
  });

  // Source guard: both the windowed Video and the fullscreen-route Video must
  // derive their fit from the single _videoFitMode preference via
  // videoFitModeToBoxFit, never the old hard-coded BoxFit.cover / params.fit.
  test('source guard: video page fit follows the videoFitMode preference', () {
    // TODO-590 batch15：全屏路由侧 Video（含 fit: videoFitModeToBoxFit(_videoFitMode)）
    // 随 fullscreen 域搬到 fullscreen.part.dart，故改读合并语料；窗口侧 Video 仍在主壳。
    final String src = readVideoHibikiSource();
    // Windowed + fullscreen both go through the mapping helper.
    final int mappedFitCount =
        'fit: videoFitModeToBoxFit(_videoFitMode)'.allMatches(src).length;
    expect(mappedFitCount, greaterThanOrEqualTo(2),
        reason: 'windowed + fullscreen Video must both map fit from the pref');
    // The old hard-coded windowed cover line is gone.
    expect(src, isNot(contains('fit: BoxFit.cover')),
        reason: 'windowed fit must no longer be hard-coded to cover');
    // Pref read on init + setter for the picker callback.
    expect(src, contains('appModel.videoFitMode'));
    expect(src, contains('_setVideoFitMode'));
  });
}
