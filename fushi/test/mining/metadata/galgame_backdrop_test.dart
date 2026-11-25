import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';

/// v155：游戏的横版背景——VNDB 不出截图背景、draft 往返与
/// 合并、仓储落图（显式换 / 自动补）与删游戏后的文件回收。
void main() {
  // 落图走封面 writer，写完驱逐图片缓存要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('backdropUrl', () {
    test('VNDB 详情不再拿截图当横版海报（实机画面带对话框 / UI）', () {
      final GalgameMetadataDraft draft = parseVndbVisualNovel(
        <Object?, Object?>{
          'id': 'v1',
          'titles': <Object?>[],
          'screenshots': <Object?>[
            <String, Object?>{
              'url': 'https://s/a.jpg',
              'sexual': 0,
              'violence': 0,
              'dims': <int>[1920, 1080],
            },
          ],
        },
      );
      expect(draft.backdropUrl, isNull);
    });

    test('draft JSON 往返；合并取有的源', () {
      const GalgameMetadataDraft withArt = GalgameMetadataDraft(
        name: 'y',
        backdropUrl: 'https://s/a.jpg',
      );
      expect(
        GalgameMetadataDraft.fromJson(withArt.toJson()).backdropUrl,
        'https://s/a.jpg',
      );
      expect(
        mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: const GalgameMetadataDraft(name: 'x'),
          GalgameMetadataSource.vndb: withArt,
        }).backdropUrl,
        'https://s/a.jpg',
      );
    });
  });

  group('GalgameRepository.applyScrapedBackdrop', () {
    late FushiDatabase db;
    late Directory dir;
    late GalgameRepository repo;
    int downloads = 0;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('gal_backdrop_');
      downloads = 0;
      repo = GalgameRepository(
        db,
        itemImagesDirectory: Directory(p.join(dir.path, 'items')),
        itemImageDownload: (String url) async {
          downloads++;
          return File(p.join(dir.path, 'dl_$downloads.gif'))
            ..writeAsBytesSync(<int>[
              0x47,
              0x49,
              0x46,
              0x38,
              0x39,
              0x61,
              1,
              0,
              1,
              0,
              0,
              0,
              0,
              0x3B,
            ]);
        },
      );
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      await repo.load();
    });

    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('显式落图；自动补齐已有就不下；删游戏回收文件', () async {
      await repo.applyScrapedBackdrop(
        'g1',
        'https://s/a.jpg',
        replaceExisting: true,
      );
      final ItemImageRow row = (await db.getItemImages(
        MediaKind.game,
        'g1',
      )).single;
      expect(row.sourceUrl, 'https://s/a.jpg');
      expect(File(row.path).existsSync(), isTrue);

      await repo.applyScrapedBackdrop(
        'g1',
        'https://s/b.jpg',
        replaceExisting: false,
      );
      expect(downloads, 1, reason: '自动补齐不覆盖已有背景');

      await repo.remove('g1');
      expect(await db.getAllItemImages(), isEmpty);
      expect(File(row.path).existsSync(), isFalse);
    });

    test('游戏不在库：不下载', () async {
      await repo.applyScrapedBackdrop(
        'nope',
        'https://s/a.jpg',
        replaceExisting: true,
      );
      expect(downloads, 0);
    });
  });
}
