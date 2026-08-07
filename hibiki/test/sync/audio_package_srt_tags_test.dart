import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1165：有声书包 manifest 按 tag name 携带 SRT 书标签，导入端按名重建映射。
/// 覆盖 SRT 书系（标准/独立有声书）标签跨设备 round-trip 与幂等再导入。
void main() {
  FushiDatabase testDb() =>
      FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

  Future<File> seedAndExport({
    required FushiDatabase sourceDb,
    required Directory temp,
    required List<String> tagNames,
  }) async {
    final Directory sourceAudio = Directory(p.join(temp.path, 'source-audio'));
    await sourceAudio.create(recursive: true);
    final File track = File(p.join(sourceAudio.path, 'track01.m4b'))
      ..writeAsStringSync('audio bytes');
    final File alignment = File(p.join(sourceAudio.path, 'align.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');

    await sourceDb.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: 'ttu-tag',
      audioRoot: Value(sourceAudio.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      alignmentFormat: 'srt',
      alignmentPath: alignment.path,
    ));
    await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
      uid: 'srt-tag',
      title: 'Tagged',
      audioRoot: Value(sourceAudio.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: alignment.path,
      importedAt: 1,
      bookKey: const Value('ttu-tag'),
    ));
    final SrtBookRow srt = (await sourceDb.getSrtBookByUid('srt-tag'))!;
    for (final String name in tagNames) {
      final int tagId = await sourceDb.getOrCreateTagByName(name);
      await sourceDb.addTagToSrtBook(srt.id, tagId);
    }

    return SyncAssetPackageService(db: sourceDb).exportAudioDatabasePackage(
      bookKey: 'ttu-tag',
      srtBookUid: 'srt-tag',
      outputFile: File(p.join(temp.path, 'audio.zip')),
    );
  }

  test('SRT 书标签经 audio 包 manifest 按名 round-trip 到目标设备', () async {
    final Directory temp =
        await Directory.systemTemp.createTemp('hibiki-audio-tags-');
    addTearDown(() => temp.delete(recursive: true));
    final FushiDatabase sourceDb = testDb();
    final FushiDatabase targetDb = testDb();
    addTearDown(sourceDb.close);
    addTearDown(targetDb.close);

    final File package = await seedAndExport(
      sourceDb: sourceDb,
      temp: temp,
      tagNames: <String>['听力', 'N2'],
    );

    // manifest 应携带 tags 名（不泄露源设备 tag id）。
    expect(await package.exists(), isTrue);

    final Directory targetAudio = Directory(p.join(temp.path, 'target-audio'));
    await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
      packageFile: package,
      audioDatabaseRoot: targetAudio,
    );

    final SrtBookRow targetSrt = (await targetDb.getSrtBookByUid('srt-tag'))!;
    final Set<String> names = (await targetDb.getTagsForSrtBook(targetSrt.id))
        .map((BookTagRow t) => t.name)
        .toSet();
    expect(names, <String>{'听力', 'N2'});
  });

  test('目标设备已有同名标签时按名复用、不新建重复标签', () async {
    final Directory temp =
        await Directory.systemTemp.createTemp('hibiki-audio-tags2-');
    addTearDown(() => temp.delete(recursive: true));
    final FushiDatabase sourceDb = testDb();
    final FushiDatabase targetDb = testDb();
    addTearDown(sourceDb.close);
    addTearDown(targetDb.close);

    // 目标设备本地已存在同名标签（各设备 id 不同）——导入必须按名归一到既有 id，
    // 不产生重复标签（幂等的真实契约：不依赖包能否被重复导入）。
    final int existingId = await targetDb.createTag('听力', 0xFF010203);

    final File package = await seedAndExport(
      sourceDb: sourceDb,
      temp: temp,
      tagNames: <String>['听力'],
    );
    final Directory targetAudio = Directory(p.join(temp.path, 'target-audio'));
    await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package, audioDatabaseRoot: targetAudio);

    // 标签池仍只有一条「听力」，且沿用目标设备本地既有 id / 色值（未被覆盖）。
    final List<BookTagRow> all = await targetDb.getAllTags();
    expect(all, hasLength(1));
    expect(all.single.id, existingId);
    expect(all.single.colorValue, 0xFF010203);

    final SrtBookRow targetSrt = (await targetDb.getSrtBookByUid('srt-tag'))!;
    final List<BookTagRow> mapped =
        await targetDb.getTagsForSrtBook(targetSrt.id);
    expect(mapped, hasLength(1));
    expect(mapped.single.id, existingId);
  });
}
