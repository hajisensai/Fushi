// BUG-5260（反馈 LBhq-ZoXjw）：与正片同目录、只靠文件名标出的 `[Menu]` / `[CM]`
// 特典要判成本地附件并挂到父作品，不能当正片单独进刮削计划；文件级与发布级
// 共用同一份特典标记词表。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/download/video_release_extras.dart';
import 'package:fushi_engine/media/video/metadata/video_extra_markers.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 当前平台分隔符的绝对路径（分类器按 `p.split` 切目录段）。
String _nativePath(List<String> segments) =>
    p.joinAll(<String>[if (Platform.isWindows) r'D:\' else '/', ...segments]);

const String _dir = '[Nekomoe kissaten] Tonikaku Kawaii';

VideoMetadataExtraKind? _kindOf(String fileName) => classifyLocalVideoExtra(
  _nativePath(<String>['Anime', _dir, fileName]),
)?.kind;

void main() {
  test('file-name extra markers in the same folder as episodes', () {
    expect(
      _kindOf('[Nekomoe kissaten] Tonikaku Kawaii [Menu][01][BDRip 1080p].mkv'),
      VideoMetadataExtraKind.extra,
    );
    expect(
      _kindOf('[Nekomoe kissaten] Tonikaku Kawaii [CM][02][BDRip 1080p].mkv'),
      VideoMetadataExtraKind.clip,
    );
    expect(
      _kindOf('[Nekomoe kissaten] Tonikaku Kawaii [NCED][BDRip 1080p].mkv'),
      VideoMetadataExtraKind.clip,
    );
    expect(
      _kindOf('[Nekomoe kissaten] Tonikaku Kawaii OVA [PV][BDRip 1080p].mkv'),
      VideoMetadataExtraKind.clip,
    );
    expect(
      _kindOf('Tonikaku Kawaii Teaser.mkv'),
      VideoMetadataExtraKind.teaser,
    );
    expect(_kindOf('Tonikaku Kawaii 予告編.mkv'), VideoMetadataExtraKind.trailer);
    expect(_kindOf('Tonikaku Kawaii BDメニュー.mkv'), VideoMetadataExtraKind.extra);
    expect(
      _kindOf('[Grp] Tonikaku Kawaii ノンクレジットOP.mkv'),
      VideoMetadataExtraKind.clip,
    );
  });

  test('broad words and main-feature titles are not extras (BUG-1969)', () {
    for (final String name in <String>[
      '[Nekomoe kissaten] Tonikaku Kawaii [01][BDRip 1080p].mkv',
      '[Nekomoe kissaten] Tonikaku Kawaii OVA [BDRip 1080p].mkv',
      '[Grp] Tonikaku Kawaii [SP][BDRip 1080p].mkv',
      'Special A - 01.mkv',
      'Extra Olympia Kyklos - 03.mkv',
      '[Grp] Show [CMCT].mkv',
      '[Grp] 摄影机不要停！[正片+特典映像][1080P].mkv',
    ]) {
      expect(_kindOf(name), isNull, reason: name);
    }
  });

  test('release-level and file-level judgements share one vocabulary', () {
    for (final String title in <String>[
      '[Group] Show Menu',
      '[Group] Show CM',
      '[Group] Show NCED',
      'Show 予告',
      '【特典映像】Show',
      '[Group] Show Bonus',
    ]) {
      expect(videoExtraMarkerKind(title), isNotNull, reason: title);
      expect(looksLikeExtrasOnlyRelease(title), isTrue, reason: title);
      expect(_kindOf('$title.mkv'), isNotNull, reason: title);
    }
    // 明写「正片」的打包发布不是「只有特典」。
    expect(
      looksLikeExtrasOnlyRelease('[DBD-Raws][摄影机不要停！][正片+特典映像][1080P]'),
      isFalse,
    );
  });

  test(
    'Menu / CM files beside episodes attach to the parent work as extras',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final Directory root = await Directory.systemTemp.createTemp(
        'video-menu-cm-extras-',
      );
      addTearDown(() async {
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      final Directory show = Directory(p.join(root.path, _dir));
      await show.create(recursive: true);
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Anime',
          mediaKind: 'video',
          rootPath: root.path,
          createdAt: 1,
        ),
      );
      Future<void> addBook(String uid, String fileName) async {
        final File video = File(p.join(show.path, fileName));
        await video.writeAsBytes(const <int>[0]);
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(uid),
            title: Value<String>(p.basenameWithoutExtension(fileName)),
            videoPath: Value<String>(video.path),
            sourceId: Value<int?>(sourceId),
          ),
        );
      }

      for (final int episode in <int>[1, 2]) {
        final String n = episode.toString().padLeft(2, '0');
        await addBook(
          'ep-$n',
          '[Nekomoe kissaten] Tonikaku Kawaii [$n][BDRip 1080p].mkv',
        );
      }
      await addBook(
        'menu-01',
        '[Nekomoe kissaten] Tonikaku Kawaii [Menu][01][BDRip 1080p].mkv',
      );
      await addBook(
        'cm-01',
        '[Nekomoe kissaten] Tonikaku Kawaii [CM][01][BDRip 1080p].mkv',
      );
      // 旧版本把 Menu 当独立作品建过 book-owned work：这次索引应原地清掉。
      await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('menu-01'),
          mediaType: 'movie',
          title: 'Menu',
          updatedAt: 1,
        ),
      );
      final int collectionId = await db.createMediaCollection(
        'Tonikaku Kawaii',
        collectionType: 'playlist',
      );
      await db.addToCollection(collectionId, MediaKind.video, 'ep-01');
      await db.addToCollection(collectionId, MediaKind.video, 'ep-02');
      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;

      final List<String> planned = <String>[
        for (final VideoSourceScrapeWork work in await VideoSourceWorkPlanner(
          db,
        ).plan(source))
          for (final VideoBookRow member in work.members) member.bookUid,
      ];
      expect(planned, isNot(contains('menu-01')));
      expect(planned, isNot(contains('cm-01')));

      expect(await VideoSourceMetadataIndexer(db).index(source), isTrue);
      final VideoMetadataWorkRow work = (await db
          .getVideoMetadataWorkByCollection(collectionId))!;
      expect(await db.getVideoMetadataWorkByBook('menu-01'), isNull);
      expect(await db.getVideoMetadataWorkByBook('cm-01'), isNull);
      final Map<String?, String> extras = <String?, String>{
        for (final VideoMetadataExtraRow row in await db.getVideoMetadataExtras(
          work.id,
        ))
          row.bookUid: row.kind,
      };
      expect(extras, <String?, String>{'menu-01': 'extra', 'cm-01': 'clip'});
    },
  );
}
