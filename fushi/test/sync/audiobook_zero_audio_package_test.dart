import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// BUG-2551：有声书资产包「一个音频都没有」不得静默落库，对端也不得因此卡死在
/// 「有行没音频」的吸收态里。
///
/// BUG-1577 把「某个具体资源缺失」堵住了，但那道校验是 `.map()` 里的**逐元素**
/// 检查——`audioPaths` 本身是空数组时一次都不执行。于是导出端解析出零个音频的包
/// 一路绿灯：对端收到字幕 / 对齐 / 封面，`audioPathsJson` 写成 `[]`，HTTP 200，
/// 同步报告记一次成功，书架上连断链红徽章都不亮（空列表判为「无断链」）。用户
/// 看到的就是「字幕同步过去了，音频没有」。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Map<String, Object?> _manifestOf(File package) {
  final Archive archive = ZipDecoder().decodeBytes(package.readAsBytesSync());
  final ArchiveFile manifest = archive.findFile('manifest.json')!;
  return jsonDecode(utf8.decode(manifest.content as List<int>))
      as Map<String, Object?>;
}

/// 用 [manifest] 换掉 [package] 里的 manifest.json，其余条目原样重打包。
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

/// 一本**健康**的 srt-backed 有声书（files 模式，音频真在磁盘上）。
Future<void> _seedHealthyBook(FushiDatabase db, Directory root) async {
  await root.create(recursive: true);
  final File track = File(p.join(root.path, 'track01.m4b'))
    ..writeAsStringSync('audio bytes');
  final File alignment = File(p.join(root.path, 'align.srt'))
    ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');

  await db.upsertAudiobook(AudiobooksCompanion.insert(
    bookKey: 'ttu-99',
    audioRoot: Value(root.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    alignmentFormat: 'srt',
    alignmentPath: alignment.path,
  ));
  await db.upsertSrtBook(SrtBooksCompanion.insert(
    uid: 'srt-99',
    title: 'Healthy',
    audioRoot: Value(root.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    srtPath: alignment.path,
    importedAt: 9,
    bookKey: const Value('ttu-99'),
  ));
  await db.replaceCuesForBook('ttu-99', <AudioCuesCompanion>[
    AudioCuesCompanion.insert(
      bookKey: 'ttu-99',
      chapterHref: 'chapter.xhtml',
      sentenceIndex: 0,
      textFragmentId: 'frag-0',
      cueText: 'hello',
      startMs: 0,
      endMs: 1000,
      audioFileIndex: 0,
    ),
  ]);
}

/// folder 模式（`audioPathsJson` 空、音频靠枚举 `audioRoot` 目录）的 srt-backed
/// 有声书，且目录里一个音频文件都没有——数据根迁移后目录没跟上、引用导入的原
/// 目录被移走，都会落到这个形状。
Future<void> _seedFolderModeBookWithoutAudio(
  FushiDatabase db,
  Directory audioRoot,
) async {
  await audioRoot.create(recursive: true);
  final File alignment = File(p.join(audioRoot.path, 'align.srt'))
    ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
  final File cover = File(p.join(audioRoot.path, 'cover.jpg'))
    ..writeAsStringSync('cover bytes');

  await db.upsertAudiobook(AudiobooksCompanion.insert(
    bookKey: 'ttu-88',
    audioRoot: Value(audioRoot.path),
    alignmentFormat: 'srt',
    alignmentPath: alignment.path,
  ));
  await db.upsertSrtBook(SrtBooksCompanion.insert(
    uid: 'srt-88',
    title: 'Folder mode',
    audioRoot: Value(audioRoot.path),
    srtPath: alignment.path,
    coverPath: Value(cover.path),
    importedAt: 8,
    bookKey: const Value('ttu-88'),
  ));
}

void main() {
  group('零音频有声书包 (BUG-2551)', () {
    test('导出：音频根解析不出任何音频时，单独下发 unresolvedAudioRoots', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-zero-audio-export-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase db = _testDb();
      addTearDown(db.close);

      final Directory audioRoot = Directory(p.join(temp.path, 'source'));
      await _seedFolderModeBookWithoutAudio(db, audioRoot);

      final File package =
          await SyncAssetPackageService(db: db).exportAudioDatabasePackage(
        bookKey: 'ttu-88',
        srtBookUid: 'srt-88',
        outputFile: File(p.join(temp.path, 'zero.fushiaudio')),
      );

      final Map<String, Object?> manifest = _manifestOf(package);
      expect((manifest['audiobook']! as Map<String, Object?>)['audioPaths'],
          isEmpty);
      expect(manifest['unresolvedAudioRoots'], contains(audioRoot.path),
          reason: '「声明了音频根却一个都枚举不出来」与「某个文件缺失」不是同一类失败，'
              '导入端要能分开判');
      expect(manifest['missingResources'], contains(audioRoot.path),
          reason: '仍汇进 missingResources，旧导入端的诊断文案不退化');
    });

    test('导入：srt-backed 包零音频时抛 Incomplete，一行都不落库', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-zero-audio-import-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory audioRoot = Directory(p.join(temp.path, 'source'));
      await _seedFolderModeBookWithoutAudio(sourceDb, audioRoot);

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-88',
        srtBookUid: 'srt-88',
        outputFile: File(p.join(temp.path, 'zero.fushiaudio')),
      );

      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: package,
          audioDatabaseRoot: Directory(p.join(temp.path, 'target')),
        ),
        throwsA(isA<SyncAssetPackageIncompleteException>()),
        reason: 'srt-backed 有声书的不变式是「EPUB + 音频 + 对齐」，零音频是坏书不是安静的书',
      );

      // 关键：对端绝不能只拿到字幕/对齐而把 audioPathsJson 写成 []。
      expect(await targetDb.getAllAudiobooks(), isEmpty);
      expect(await targetDb.getSrtBookByUid('srt-88'), isNull);
    });

    test('导入：纯字幕书零音频仍合法放行（standalone 本来就可以没有音频）', () async {
      final Directory temp = await Directory.systemTemp
          .createTemp('hibiki-zero-audio-standalone-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory dir = Directory(p.join(temp.path, 'source'))
        ..createSync(recursive: true);
      final File subs = File(p.join(dir.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n');
      // audioRoot 为 null = 从来就没声明过音频，与「声明了却丢了」是两回事。
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-text-only',
        title: 'Subtitles only',
        srtPath: subs.path,
        importedAt: 9,
        bookKey: const Value(''),
      ));

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        srtBookUid: 'srt-text-only',
        outputFile: File(p.join(temp.path, 'textonly.fushiaudio')),
      );
      expect(_manifestOf(package)['unresolvedAudioRoots'], isNull,
          reason: '没声明过音频根 → 没有「未解析的音频根」这回事');

      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: Directory(p.join(temp.path, 'target')),
      );
      expect(await targetDb.getSrtBookByUid('srt-text-only'), isNotNull);
    });

    test('导入：纯字幕书声明了音频根却丢了音频时，照样抛', () async {
      final Directory temp = await Directory.systemTemp
          .createTemp('hibiki-zero-audio-standalone-lost-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory dir = Directory(p.join(temp.path, 'source'))
        ..createSync(recursive: true);
      final File subs = File(p.join(dir.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n');
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-lost-audio',
        title: 'Lost audio',
        audioRoot: Value(dir.path), // 声明了，但目录里没有任何音频文件
        srtPath: subs.path,
        importedAt: 9,
        bookKey: const Value(''),
      ));

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        srtBookUid: 'srt-lost-audio',
        outputFile: File(p.join(temp.path, 'lost.fushiaudio')),
      );

      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: package,
          audioDatabaseRoot: Directory(p.join(temp.path, 'target')),
        ),
        throwsA(isA<SyncAssetPackageIncompleteException>()),
      );
      expect(await targetDb.getSrtBookByUid('srt-lost-audio'), isNull);
    });
  });

  group('音频完好判据 (BUG-2551)', () {
    test('files 模式：路径断链 → 不完好', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-audio-intact-');
      addTearDown(() => temp.delete(recursive: true));
      final File track = File(p.join(temp.path, 'a.mp3'))
        ..writeAsStringSync('x');

      expect(
        await audiobookAudioIsIntact(
            audioPathsJson: jsonEncode(<String>[track.path]), audioRoot: null),
        isTrue,
      );
      track.deleteSync();
      expect(
        await audiobookAudioIsIntact(
            audioPathsJson: jsonEncode(<String>[track.path]), audioRoot: null),
        isFalse,
      );
    });

    test('零音频（空清单 / 空目录 / 什么都没有）→ 不完好', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-audio-intact-empty-');
      addTearDown(() => temp.delete(recursive: true));

      expect(
        await audiobookAudioIsIntact(audioPathsJson: '[]', audioRoot: null),
        isFalse,
        reason: '空清单曾被书架断链判据当成「没问题」，同步侧不能重复这个错',
      );
      expect(
        await audiobookAudioIsIntact(
            audioPathsJson: null, audioRoot: temp.path),
        isFalse,
      );
      expect(
        await audiobookAudioIsIntact(audioPathsJson: null, audioRoot: null),
        isFalse,
      );
    });
  });

  group('远端清单音频能力位 (BUG-2551)', () {
    test('hasAudio 缺键 → null（未知），不是 false', () {
      final RemoteAudiobookInfo info = RemoteAudiobookInfo.fromJson(
          <String, Object?>{'bookKey': 'ttu-1', 'title': 'Old host'});
      expect(info.hasAudio, isNull,
          reason: '旧 host 不下发此字段；当成 false 会让 sweep 每轮朝旧 host 重推所有有声书');
      expect(info.toJson().containsKey('hasAudio'), isFalse,
          reason: '未知不下发，保持与旧 host 同形');
    });

    test('hasAudio 往返 wire 保真', () {
      for (final bool value in <bool>[true, false]) {
        final Map<String, Object?> json =
            RemoteAudiobookInfo(bookKey: 'ttu-1', hasAudio: value).toJson();
        expect(json['hasAudio'], value);
        expect(RemoteAudiobookInfo.fromJson(json).hasAudio, value);
      }
    });
  });

  group('导入写库原子性 (BUG-2551)', () {
    test('cue 段中途抛 → 已写下的 Audiobooks / SrtBooks 行一并回滚', () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('hibiki-import-atomic-');
      addTearDown(() => temp.delete(recursive: true));
      final FushiDatabase sourceDb = _testDb();
      final FushiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      await _seedHealthyBook(sourceDb, Directory(p.join(temp.path, 'source')));
      final File healthy = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookKey: 'ttu-99',
        srtBookUid: 'srt-99',
        outputFile: File(p.join(temp.path, 'healthy.fushiaudio')),
      );

      // 把 cue 的必需键删掉：写库段会先写完 Audiobooks + SrtBooks，再在 cue 这步抛。
      final Map<String, Object?> manifest = _manifestOf(healthy);
      final List<Object?> cues = manifest['cues']! as List<Object?>;
      (cues.first! as Map<String, Object?>).remove('chapterHref');
      final File broken = _repackWithManifest(
        healthy,
        manifest,
        File(p.join(temp.path, 'broken-cue.fushiaudio')),
      );

      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: broken,
          audioDatabaseRoot: Directory(p.join(temp.path, 'target')),
        ),
        throwsA(anything),
      );

      // 关键：不能留下半成品行。书架所有「补拉有声书」入口的判据都是「有没有这行」，
      // 半写下的行会让占位卡 / 书卡菜单 / 对比弹窗同时消失，用户再没有第二次下载入口。
      expect(await targetDb.getAllAudiobooks(), isEmpty,
          reason: 'cue 写失败时 Audiobooks 行必须跟着回滚');
      expect(await targetDb.getSrtBookByUid('srt-99'), isNull,
          reason: 'cue 写失败时 SrtBooks 行必须跟着回滚');
    });
  });
}
