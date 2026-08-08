import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Kodi local extra names are classified without matching normal episodes',
      () {
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\Trailers\official.mkv')?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\Behind The Scenes\making-of.mkv')
          ?.kind,
      VideoMetadataExtraKind.behindTheScenes,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Movies\Film-trailer.mp4')?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(classifyLocalVideoExtra(r'D:\Shows\Title\Title.S01E01.mkv'), isNull);
  });

  test('existing source is backfilled into one idempotent provisional work',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final Directory root =
        await Directory.systemTemp.createTemp('video-metadata-backfill-');
    addTearDown(() async {
      await db.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final Directory show = Directory(p.join(root.path, 'Himouto'));
    await show.create(recursive: true);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Existing source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    for (final int episode in <int>[8, 9]) {
      final File video = File(p.join(
        show.path,
        '[Kamigami] Himouto! Umaru-chan - ${episode.toString().padLeft(2, '0')}'
        ' [1920x1080].mkv',
      ));
      await video.writeAsBytes(const <int>[0]);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>('himouto-$episode'),
        title: Value<String>(p.basenameWithoutExtension(video.path)),
        videoPath: Value<String>(video.path),
        sourceId: Value<int?>(sourceId),
      ));
    }
    final int collectionId = await db.createMediaCollection(
      'Himouto! Umaru-chan',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'himouto-8');
    await db.addToCollection(collectionId, MediaKind.video, 'himouto-9');
    final source = (await db.getMediaSourceById(sourceId))!;
    final VideoSourceMetadataIndexer indexer = VideoSourceMetadataIndexer(db);

    await indexer.index(source);
    final VideoMetadataWorkRow first =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    expect(first.title, 'Himouto! Umaru-chan');
    expect(first.mediaType, 'tv');
    expect(await db.getVideoMetadataSeasons(first.id), hasLength(1));

    await indexer.index(source);
    final VideoMetadataWorkRow second =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    expect(second.id, first.id);
    expect(await db.getVideoMetadataSeasons(first.id), hasLength(1));
  });
}
