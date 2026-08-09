import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_core/fushi_core.dart';
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
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\NCOP2.mkv')?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\Title NCED.mkv')?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\PV\[Group][Title][PV][01].mkv')
          ?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(
        r'D:\Shows\Title\NCOP&NCED\[Group][Title][NCOP].mkv',
      )?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\menu\[Group][Title][01].mkv')
          ?.kind,
      VideoMetadataExtraKind.extra,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\迷你动画\short-01.mkv')?.kind,
      VideoMetadataExtraKind.short,
    );
    expect(classifyLocalVideoExtra(r'D:\Shows\Title\Title.S01E01.mkv'), isNull);
  });

  test('existing source is backfilled into one idempotent provisional work',
      () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
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
    final File ncop = File(p.join(show.path, 'Himouto NCOP.mkv'));
    await ncop.writeAsBytes(const <int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('himouto-ncop'),
      title: const Value<String>('Himouto NCOP'),
      videoPath: Value<String>(ncop.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('himouto-ncop'),
        mediaType: 'movie',
        title: 'Himouto NCOP',
        updatedAt: 1,
      ),
    );
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
    expect(await db.getVideoMetadataWorkByBook('himouto-ncop'), isNull,
        reason: '历史误建的 NCOP 独立作品应清理，但 VideoBook 仍保留');
    expect(await db.getVideoBookByBookUid('himouto-ncop'), isNotNull);
    final List<VideoMetadataExtraRow> extras =
        await db.getVideoMetadataExtras(first.id);
    expect(extras.single.bookUid, 'himouto-ncop');
    expect(extras.single.kind, 'clip');

    await indexer.index(source);
    final VideoMetadataWorkRow second =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    expect(second.id, first.id);
    expect(await db.getVideoMetadataSeasons(first.id), hasLength(1));
  });
}
