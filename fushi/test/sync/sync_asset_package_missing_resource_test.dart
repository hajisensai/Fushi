import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1577：有声书资产包「缺资源」不得被两侧的静默 fail-open 掩盖。
///
/// 导出侧曾经对不存在的源文件只 continue（包里静默少一个资源），导入侧曾经在
/// manifest 的 resources 映射里找不到时回退成 basename（编出一个不存在的路径写进
/// DB）。两者互相掩盖，用户拿到一本「有字幕没声音」的书且没有任何报错。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Map<String, Object?> _manifestOf(File package) {
  final Archive archive = ZipDecoder().decodeBytes(package.readAsBytesSync());
  final ArchiveFile manifest = archive.findFile('manifest.json')!;
  return jsonDecode(utf8.decode(manifest.content as List<int>))
      as Map<String, Object?>;
}

/// 用 [manifest] 换掉 [package] 里的 manifest.json，其余条目原样重打包——用来构造
/// 「旧版本产出的包」（没有 missingResources 这个新键）。
File _repackWithManifest(
  File package,
  Map<String, Object?> manifest,
  File output,
) {
  final Archive source = ZipDecoder().decodeBytes(package.readAsBytesSync());
  final Archive out = Archive();
  final List<int> manifestBytes = utf8.encode(jsonEncode(manifest));
  out.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  for (final ArchiveFile file in source.files) {
    if (!file.isFile || file.name == 'manifest.json') continue;
    final List<int> bytes = file.content as List<int>;
    out.addFile(ArchiveFile(file.name, bytes.length, bytes));
  }
  output.writeAsBytesSync(ZipEncoder().encode(out)!);
  return output;
}

/// 建一本 srt-backed 有声书（Audiobooks + SrtBooks + 1 条 cue），返回音频/字幕/封面
/// 三个文件（files 模式：audioPathsJson 非空）。
Future<(File, File, File)> _seedSrtBackedBook(
  FushiDatabase db,
  Directory sourceAudio,
) async {
  await sourceAudio.create(recursive: true);
  final File track = File(p.join(sourceAudio.path, 'track01.m4b'))
    ..writeAsStringSync('audio bytes');
  final File alignment = File(p.join(sourceAudio.path, 'align.srt'))
    ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
  final File cover = File(p.join(sourceAudio.path, 'cover.jpg'))
    ..writeAsStringSync('cover bytes');

  await db.upsertAudiobook(AudiobooksCompanion.insert(
    bookKey: 'ttu-77',
    audioRoot: Value(sourceAudio.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    alignmentFormat: 'srt',
    alignmentPath: alignment.path,
  ));
  await db.upsertSrtBook(SrtBooksCompanion.insert(
    uid: 'srt-77',
    title: 'Paired',
    audioRoot: Value(sourceAudio.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    srtPath: alignment.path,
    coverPath: Value(cover.path),
    importedAt: 7,
    bookKey: const Value('ttu-77'),
  ));
  await db.replaceCuesForBook('ttu-77', <AudioCuesCompanion>[
    AudioCuesCompanion.insert(
      bookKey: 'ttu-77',
      chapterHref: 'chapter.xhtml',
      sentenceIndex: 0,
      textFragmentId: 'frag-0',
      cueText: 'hello',
      startMs: 0,
      endMs: 1000,
      audioFileIndex: 0,
    ),
  ]);
  return (track, alignment, cover);
}

void main() {
  group('audio package missing resources (BUG-1577)', () {
    test('导出：源音频文件不存在时记进 manifest.missingResources，不静默跳过', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-missing-export-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      addTearDown(sourceDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'));
      final (File track, _, _) =
          await _seedSrtBackedBook(sourceDb, sourceAudio);
      // 音频文件在导出前消失（用户删了 / 外接盘拔了）。
      track.deleteSync();

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-77',
        srtBookUid: 'srt-77',
        outputFile: File(p.join(temp.path, 'incomplete.fushiaudio')),
      );

      final Map<String, Object?> manifest = _manifestOf(package);
      expect(manifest['missingResources'], contains(track.path),
          reason: '缺失的源文件必须写进 manifest，包不完整这件事不能没有痕迹');
      final Map<String, Object?> resources =
          manifest['resources']! as Map<String, Object?>;
      expect(resources.containsKey(track.path), isFalse,
          reason: '不存在的文件不进 resources 映射');
      // 字幕/封面仍在包里：一本书缺 1 个文件不该让整个导出失败。
      expect(resources.length, 2, reason: '部分缺失时其余资源照常入包（不把 6 缺 1 变成整包失败）');
    });

    test('导入：必需资源在包里没有登记时抛 Incomplete 且一行都不写 DB', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-missing-import-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'));
      final (File track, _, _) =
          await _seedSrtBackedBook(sourceDb, sourceAudio);
      track.deleteSync();

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-77',
        srtBookUid: 'srt-77',
        outputFile: File(p.join(temp.path, 'incomplete.fushiaudio')),
      );

      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: package,
          audioDatabaseRoot: targetAudio,
        ),
        throwsA(isA<SyncAssetPackageIncompleteException>()),
        reason: '包里没有该音频 → 必须报错，不能编 basename 路径',
      );

      // 关键：绝不能留下指向不存在文件的 DB 行。
      expect(await targetDb.getAllAudiobooks(), isEmpty);
      expect(await targetDb.getSrtBookByUid('srt-77'), isNull);
      expect(
        File(p.join(targetAudio.path, 'ttu-77', 'track01.m4b')).existsSync(),
        isFalse,
        reason: '旧实现会写出这个「看着像样但不存在」的路径',
      );
    });

    test('导入：纯 SRT 包缺字幕资源时同样抛，不落 SrtBooks 行', () async {
      final Directory temp = await Directory.systemTemp
          .createTemp('hibiki-pkg-missing-standalone-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'))
        ..createSync(recursive: true);
      final File voice = File(p.join(sourceAudio.path, 'voice.mp3'))
        ..writeAsStringSync('voice bytes');
      final File subs = File(p.join(sourceAudio.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n');
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-standalone-77',
        title: 'Standalone',
        audioRoot: Value(sourceAudio.path),
        audioPathsJson: Value(jsonEncode(<String>[voice.path])),
        srtPath: subs.path,
        importedAt: 9,
        bookKey: const Value(''),
      ));
      subs.deleteSync(); // 字幕文件在导出前消失。

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        srtBookUid: 'srt-standalone-77',
        outputFile: File(p.join(temp.path, 'standalone.fushiaudio')),
      );

      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: package,
          audioDatabaseRoot: targetAudio,
        ),
        throwsA(isA<SyncAssetPackageIncompleteException>()),
      );
      expect(await targetDb.getSrtBookByUid('srt-standalone-77'), isNull);
    });

    test('封面缺失只降级为无封面，不抛也不编造路径', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-missing-cover-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'));
      final (_, _, File cover) =
          await _seedSrtBackedBook(sourceDb, sourceAudio);
      cover.deleteSync();

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-77',
        srtBookUid: 'srt-77',
        outputFile: File(p.join(temp.path, 'nocover.fushiaudio')),
      );

      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetAudio,
      );

      final SrtBookRow srt = (await targetDb.getSrtBookByUid('srt-77'))!;
      expect(srt.coverPath, isNull, reason: '封面是装饰性资源：缺了置空，不编路径');
      expect(File(srt.srtPath).existsSync(), isTrue);
    });

    test('向后兼容：旧格式 manifest（无 missingResources 键）导入仍成功', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-legacy-ok-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'));
      await _seedSrtBackedBook(sourceDb, sourceAudio);

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-77',
        srtBookUid: 'srt-77',
        outputFile: File(p.join(temp.path, 'healthy.fushiaudio')),
      );

      // 健康包与旧包同形：不带新键（旧版本导入端读到的 manifest 逐键不变）。
      final Map<String, Object?> manifest = _manifestOf(package);
      expect(manifest.containsKey('missingResources'), isFalse,
          reason: '没有缺失时不写新键，健康包与旧包同形');

      // 再显式重打一个「旧包」（哪怕将来默认写这个键，这条也仍在测缺键路径）。
      final Map<String, Object?> legacy = Map<String, Object?>.from(manifest)
        ..remove('missingResources');
      final File legacyPackage = _repackWithManifest(
        package,
        legacy,
        File(p.join(temp.path, 'legacy.fushiaudio')),
      );

      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: legacyPackage,
        audioDatabaseRoot: targetAudio,
      );

      final AudiobookRow audiobook =
          (await targetDb.getAudiobookByBookKey('ttu-77'))!;
      final List<dynamic> audioPaths =
          jsonDecode(audiobook.audioPathsJson!) as List<dynamic>;
      expect(audioPaths, hasLength(1));
      expect(File(audioPaths.single as String).existsSync(), isTrue,
          reason: '旧格式包必须照常导入，且落地路径真实存在');
      expect(File(audiobook.alignmentPath).existsSync(), isTrue);
    });

    test('向后兼容：旧格式坏包（resources 不全、无新键）也必须被拒绝', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-legacy-bad-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'));
      final (File track, _, _) =
          await _seedSrtBackedBook(sourceDb, sourceAudio);
      track.deleteSync();

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-77',
        srtBookUid: 'srt-77',
        outputFile: File(p.join(temp.path, 'incomplete.fushiaudio')),
      );
      // 抹掉新键，还原成「旧版本产出的坏包」：判据只能是 resources 映射本身。
      final Map<String, Object?> legacy =
          Map<String, Object?>.from(_manifestOf(package))
            ..remove('missingResources');
      final File legacyPackage = _repackWithManifest(
        package,
        legacy,
        File(p.join(temp.path, 'legacy-bad.fushiaudio')),
      );

      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: legacyPackage,
          audioDatabaseRoot: Directory(p.join(temp.path, 'target')),
        ),
        throwsA(isA<SyncAssetPackageIncompleteException>()),
        reason: '拒绝落库的判据是 resources 映射，不依赖新键',
      );
      expect(await targetDb.getAllAudiobooks(), isEmpty);
    });

    test('folder 模式（audioPaths 空、音频在 audioRoot）导出不再是零个音频文件', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-folder-mode-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'))
        ..createSync(recursive: true);
      // 播放端按 compareAudioFilePath 排序枚举目录；故意乱序建文件。
      File(p.join(sourceAudio.path, 'ch02.mp3')).writeAsStringSync('two');
      File(p.join(sourceAudio.path, 'ch01.mp3')).writeAsStringSync('one');
      File(p.join(sourceAudio.path, 'notes.txt')).writeAsStringSync('junk');
      final File subs = File(p.join(sourceAudio.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nfolder\n');

      // folder 模式：audioPathsJson 留空，音频只由 audioRoot 目录承载。
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-folder-1',
        title: 'Folder mode',
        audioRoot: Value(sourceAudio.path),
        srtPath: subs.path,
        importedAt: 3,
        bookKey: const Value(''),
      ));

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        srtBookUid: 'srt-folder-1',
        outputFile: File(p.join(temp.path, 'folder.fushiaudio')),
      );

      final Map<String, Object?> manifest = _manifestOf(package);
      final Map<String, Object?> srtBook =
          manifest['srtBook']! as Map<String, Object?>;
      expect(
          srtBook['audioPaths'],
          <String>[
            p.join(sourceAudio.path, 'ch01.mp3'),
            p.join(sourceAudio.path, 'ch02.mp3'),
          ],
          reason: 'folder 模式必须展开成真实音频清单，且与播放端同序');

      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetAudio,
      );

      final SrtBookRow srt = (await targetDb.getSrtBookByUid('srt-folder-1'))!;
      final List<dynamic> audioPaths =
          jsonDecode(srt.audioPathsJson!) as List<dynamic>;
      expect(audioPaths, hasLength(2), reason: 'folder 模式的书导入后必须真的有音频');
      for (final dynamic path in audioPaths) {
        expect(File(path as String).existsSync(), isTrue);
      }
      expect(
          File(p.join(targetAudio.path, 'srt-folder-1', 'notes.txt'))
              .existsSync(),
          isFalse,
          reason: '只收音频文件，不把目录里的杂物一起打包');
    });

    test('folder 模式音频目录为空时把 audioRoot 记进 missingResources', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-pkg-folder-empty-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      addTearDown(sourceDb.close);

      final Directory sourceAudio = Directory(p.join(temp.path, 'source'))
        ..createSync(recursive: true);
      final File subs = File(p.join(sourceAudio.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nempty\n');
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-folder-empty',
        title: 'Folder empty',
        audioRoot: Value(sourceAudio.path),
        srtPath: subs.path,
        importedAt: 4,
        bookKey: const Value(''),
      ));

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        srtBookUid: 'srt-folder-empty',
        outputFile: File(p.join(temp.path, 'folder-empty.fushiaudio')),
      );

      expect(
          _manifestOf(package)['missingResources'], contains(sourceAudio.path),
          reason: '一个音频都没解析出来的空包必须留下痕迹');
    });
  });
}
