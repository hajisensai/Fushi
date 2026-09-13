import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi/src/media/video/video_folder_group_coordinator.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test('deleting source snapshots settings changed without another scan',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ));
    addTearDown(db.close);
    final int sourceId =
        await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Lessons',
      mediaKind: 'video',
      rootPath: '/lessons',
      createdAt: 1,
      videoGroupingMode: const Value('folder'),
    ));
    await db.into(db.videoBooks).insert(VideoBooksCompanion.insert(
          bookUid: 'clip',
          title: 'Clip',
          videoPath: '/lessons/clip.mp4',
          sourceId: Value(sourceId),
          videoGroupingMode: const Value('folder'),
        ));
    await (db.update(db.mediaSources)..where((tbl) => tbl.id.equals(sourceId)))
        .write(const MediaSourcesCompanion(videoGroupingMode: Value('series')));
    expect(await db.deleteMediaSource(sourceId), 1);
    final VideoBookRow book = (await db.allVideoBooks()).single;
    expect(book.sourceId, isNull);
    expect(book.videoGroupingMode, 'series');
    expect(book.videoPath, '/lessons/clip.mp4');
  });
  test('one-time folder then series import keeps series after source deletion',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ));
    addTearDown(db.close);
    final VideoFolderGroupCoordinator coordinator = VideoFolderGroupCoordinator(
      database: db,
      repository: VideoBookRepository(db),
    );
    const String path = '/lessons/easy/clip.mp4';
    await db.into(db.videoBooks).insert(VideoBooksCompanion.insert(
          bookUid: 'clip',
          title: 'Clip',
          videoPath: path,
        ));
    Future<void> importOnce(String mode) async {
      final int id = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Lessons',
        mediaKind: 'video',
        rootPath: '/lessons',
        createdAt: 1,
        videoGroupingMode: Value(mode),
      ));
      await coordinator.groupPaths(
        videoPaths: <String>[path],
        sourceId: id,
        groupingMode: mode,
        sourceRoot: '/lessons',
      );
      await db.deleteMediaSource(id);
    }

    Future<Map<String, int>> folded() async => applyVideoFolderCollectionPolicy(
          primary: await db.getPrimaryCollectionIdByEntry(),
          collections: await db.getAllMediaCollections(),
          items: await db.getAllCollectionItems(),
          books: await db.allVideoBooks(),
          sources: await db.getMediaSourcesByKind('video'),
        );
    await importOnce('folder');
    expect((await folded()).containsKey('video|clip'), isTrue);
    expect((await db.allVideoBooks()).single.sourceId, isNull);
    expect((await db.allVideoBooks()).single.videoGroupingMode, 'folder');
    await importOnce('series');
    expect((await db.allVideoBooks()).single.sourceId, isNull);
    expect((await db.allVideoBooks()).single.videoGroupingMode, 'series');
    expect((await folded()).containsKey('video|clip'), isFalse);
    expect(await db.getAllMediaCollections(), hasLength(1),
        reason: '旧目录合集保留，只改变主折叠选择');
  });
}
