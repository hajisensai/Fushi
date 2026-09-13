import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  test(
    'v97 upgrade preserves sources and manual collections with series default',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'video_grouping_v98',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await original.into(original.mediaSources).insert(
            MediaSourcesCompanion.insert(
              label: 'Difficulty',
              mediaKind: 'video',
              rootPath: 'D:/lessons',
              createdAt: 123,
            ),
          );
      await original.into(original.mediaCollections).insert(
            MediaCollectionsCompanion.insert(
              name: 'My lessons',
              createdAt: 456,
            ),
          );
      await original
          .into(original.videoBooks)
          .insert(VideoBooksCompanion.insert(
            bookUid: 'lesson',
            title: 'Lesson',
            videoPath: 'D:/lessons/easy/a.mp4',
          ));
      await original.close();
      final sqlite3.Database raw = sqlite3.sqlite3.open(path);
      try {
        raw.execute('ALTER TABLE video_books DROP COLUMN video_grouping_mode');
        raw.execute(
          'ALTER TABLE media_sources DROP COLUMN video_grouping_mode',
        );
        raw.execute(
          'ALTER TABLE media_collections DROP COLUMN source_folder_path',
        );
        raw.execute('PRAGMA user_version = 97');
      } finally {
        raw.dispose();
      }
      final FushiDatabase upgraded = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(upgraded.close);
      expect((await upgraded.select(upgraded.videoBooks).getSingle()).title,
          'Lesson');
      expect(
          (await upgraded.select(upgraded.videoBooks).getSingle())
              .videoGroupingMode,
          isNull);
      await upgraded.update(upgraded.videoBooks).write(
            const VideoBooksCompanion(videoGroupingMode: Value('folder')),
          );
      expect(
          (await upgraded.select(upgraded.videoBooks).getSingle())
              .videoGroupingMode,
          'folder');
      final MediaSourceRow source =
          await upgraded.select(upgraded.mediaSources).getSingle();
      expect(source.label, 'Difficulty');
      expect(source.rootPath, 'D:/lessons');
      expect(source.createdAt, 123);
      expect(source.videoGroupingMode, 'series');
      expect(source.configJson, isNull);
      final MediaCollectionRow collection =
          await upgraded.select(upgraded.mediaCollections).getSingle();
      expect(collection.name, 'My lessons');
      expect(collection.createdAt, 456);
      expect(collection.sourceFolderPath, isNull);
      expect(
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        upgraded.schemaVersion,
      );

      await upgraded.update(upgraded.mediaSources).write(
            const MediaSourcesCompanion(videoGroupingMode: Value('folder')),
          );
      await upgraded.update(upgraded.mediaCollections).write(
            const MediaCollectionsCompanion(
              sourceFolderPath: Value('D:/lessons/easy'),
            ),
          );
      final MediaSourceRow updated =
          await upgraded.select(upgraded.mediaSources).getSingle();
      expect(updated.videoGroupingMode, 'folder');
      expect(updated.copyWith(label: 'Renamed').videoGroupingMode, 'folder');
      expect(
        MediaSourceRow.fromJson(updated.toJson()).videoGroupingMode,
        'folder',
      );
      expect(updated.configJson, isNull);
      expect(
        (await upgraded.select(upgraded.mediaCollections).getSingle())
            .sourceFolderPath,
        'D:/lessons/easy',
      );
    },
  );
}
