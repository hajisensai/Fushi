// BUG-4245：原盘入库（DiscLibraryImporter）——扫描器与下载流水线共用的那一份。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/disc/disc_library_import.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bluray/bluray_fixture.dart';

/// 在 [root] 下铺一张两条标题（各 1500 秒）的盘。
void _writeDisc(String root) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  const int start = 45000 * 4;
  const int seconds = 1500;
  for (final (int i, String clip) in <String>['00010', '00011'].indexed) {
    File(
      p.join(root, 'BDMV', 'PLAYLIST', '0000${i + 1}.mpls'),
    ).writeAsBytesSync(
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clip,
            inTimeTicks: start,
            outTimeTicks: start + 45000 * seconds,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: start),
        ],
      ),
    );
    File(p.join(root, 'BDMV', 'CLIPINF', '$clip.clpi')).writeAsBytesSync(
      buildClpiFixture(
        presentationStartTicks: start,
        presentationEndTicks: start + 45000 * seconds,
      ),
    );
    File(
      p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
    ).writeAsBytesSync(Uint8List(4096));
  }
}

void main() {
  late FushiDatabase db;
  late Directory temp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('fushi-disc-import-');
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('一张盘一个 playlist 合集，成员是 .mpls，按标题顺序；重跑幂等', () async {
    final String root = p.join(temp.path, 'Show (2026)', 'DISC1');
    _writeDisc(root);
    final List<(int, String)> ready = <(int, String)>[];
    final DiscLibraryImporter importer = DiscLibraryImporter(db);

    final DiscLibraryImportReport first = await importer.importBlurayDiscs(
      <String>[root],
      sourceId: null,
      restoreDissolvedGroups: false,
      onCollectionReady: (int id, String disc) async => ready.add((id, disc)),
    );
    expect(first.imported, 1);
    final DiscLibraryImportedDisc disc = first.discs.single;
    expect(disc.name, 'DISC1');
    expect(disc.created, isTrue);
    expect(disc.titlePaths, <String>[
      p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
      p.join(root, 'BDMV', 'PLAYLIST', '00002.mpls'),
    ]);
    expect(ready, <(int, String)>[(disc.collectionId, root)]);

    final DiscLibraryImportReport again = await importer.importBlurayDiscs(
      <String>[root],
      sourceId: null,
      restoreDissolvedGroups: false,
    );
    expect(again.imported, 0, reason: '重跑对齐既有合集，不新建');
    expect(again.discs.single.collectionId, disc.collectionId);
    expect(again.discs.single.created, isFalse);
    expect(await db.getAllMediaCollections(), hasLength(1));
    expect(await db.allVideoBooks(), hasLength(2));
  });

  test('用户删过盘合集：扫描（不恢复）不复活，下载入库（恢复）重建', () async {
    final String root = p.join(temp.path, 'DISC1');
    _writeDisc(root);
    final DiscLibraryImporter importer = DiscLibraryImporter(db);
    final DiscLibraryImportReport first = await importer.importBlurayDiscs(
      <String>[root],
      sourceId: null,
      restoreDissolvedGroups: false,
    );
    await db.deleteMediaCollection(first.discs.single.collectionId);

    final DiscLibraryImportReport scanned = await importer.importBlurayDiscs(
      <String>[root],
      sourceId: null,
      restoreDissolvedGroups: false,
    );
    expect(scanned.discs, isEmpty);
    expect(await db.getAllMediaCollections(), isEmpty);

    final DiscLibraryImportReport downloaded = await importer.importBlurayDiscs(
      <String>[root],
      sourceId: null,
      restoreDissolvedGroups: true,
    );
    expect(downloaded.discs.single.created, isTrue);
    expect(await db.getAllMediaCollections(), hasLength(1));
  });

  test('读不出的盘（半张盘 / 不是 DVD 的镜像）记进 unreadable，不报错', () async {
    final String half = p.join(temp.path, 'HALF');
    Directory(p.join(half, 'BDMV', 'PLAYLIST')).createSync(recursive: true);
    final File iso = File(p.join(temp.path, 'data.iso'))
      ..writeAsBytesSync(Uint8List(4096));
    final DiscLibraryImporter importer = DiscLibraryImporter(db);

    final DiscLibraryImportReport bd = await importer.importBlurayDiscs(
      <String>[half],
      sourceId: null,
      restoreDissolvedGroups: true,
    );
    expect(bd.unreadable, <String>[half]);
    final DiscLibraryImportReport dvd = await importer.importDvdDiscs(
      <String>[iso.path],
      sourceId: null,
      restoreDissolvedGroups: true,
    );
    expect(dvd.discs, isEmpty);
    expect(dvd.failed, isEmpty);
    expect(dvd.unreadable, <String>[iso.path]);
    expect(await db.getAllMediaCollections(), isEmpty);
  });
}
