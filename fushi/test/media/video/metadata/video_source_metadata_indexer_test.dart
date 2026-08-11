import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 用**当前平台**的分隔符拼一条绝对路径。
///
/// [classifyLocalVideoExtra] 的目录名判据走 `p.split`（平台上下文）。原来这条用例
/// 硬编码 `D:\Shows\...`：Windows 上 `p.split` 认得反斜杠、目录段能切出来所以全绿；
/// Linux CI 上反斜杠只是普通字符，整串被当成**一个**路径段，`Trailers` / `迷你动画`
/// 这类目录判据一条都命不中，stem 又变成 `d:\shows\title\trailers\official`，
/// `trailer` 后面跟着 `s` 连兜底正则也不匹配 → 全部返回 null。典型的「本机 Windows
/// 绿、CI 必红」。判据本身按平台分是对的（本地扫描拿到的就是平台原生路径），所以
/// 修的是用例的平台假设，不是生产代码。
String _nativePath(List<String> segments) => p.joinAll(<String>[
      if (Platform.isWindows) r'D:\' else '/',
      ...segments,
    ]);

void main() {
  test('Kodi local extra names are classified without matching normal episodes',
      () {
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'Title', 'Trailers', 'official.mkv']),
      )?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>[
          'Shows',
          'Title',
          'Behind The Scenes',
          'making-of.mkv',
        ]),
      )?.kind,
      VideoMetadataExtraKind.behindTheScenes,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Movies', 'Film-trailer.mp4']),
      )?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'Title', 'NCOP2.mkv']),
      )?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'Title', 'Title NCED.mkv']),
      )?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>[
          'Shows',
          'Title',
          'PV',
          '[Group][Title][PV][01].mkv',
        ]),
      )?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>[
          'Shows',
          'Title',
          'NCOP&NCED',
          '[Group][Title][NCOP].mkv',
        ]),
      )?.kind,
      VideoMetadataExtraKind.clip,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>[
          'Shows',
          'Title',
          'menu',
          '[Group][Title][01].mkv',
        ]),
      )?.kind,
      VideoMetadataExtraKind.extra,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'Title', '迷你动画', 'short-01.mkv']),
      )?.kind,
      VideoMetadataExtraKind.short,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'Title', 'Title.S01E01.mkv']),
      ),
      isNull,
    );
  });

  test('existing source is backfilled into one idempotent provisional work',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
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
