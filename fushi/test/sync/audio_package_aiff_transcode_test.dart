import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudiobookStorage;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// BUG-3312 延伸：桌面「引用原文件」导入的 AIFF 有声书，经同步包 / 互联下载到
/// 另一端时，AIFF 原样进包。Android 的有声书播放器（ExoPlayer）不认 AIFF，所以
/// 接收端 [SyncAssetPackageService.importAudioDatabasePackage] 在落库前把 AIFF 转成
/// FLAC——所有跨设备路径都汇到这一个函数。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  late Directory temp;
  late FushiDatabase sourceDb;
  late FushiDatabase targetDb;
  late List<String> transcoded;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi-aiff-package-');
    sourceDb = _testDb();
    targetDb = _testDb();
    transcoded = <String>[];
    AudiobookStorage.flacTranscoder = (String source, String flacPath) async {
      transcoded.add(p.basename(source));
      File(
        flacPath,
      ).writeAsStringSync('fLaC<${File(source).readAsStringSync()}>');
    };
  });

  tearDown(() async {
    AudiobookStorage.flacTranscoder = null;
    await sourceDb.close();
    await targetDb.close();
    await temp.delete(recursive: true);
  });

  /// 发送端：一本「引用原文件」的书，音频路径直接指向源目录里的 [names]。
  Future<File> exportReferenceBook(List<String> names) async {
    final Directory src = Directory(p.join(temp.path, 'library'))
      ..createSync(recursive: true);
    final List<String> tracks = <String>[
      for (final String name in names)
        (File(p.join(src.path, name))..writeAsStringSync('pcm:$name')).path,
    ];
    final File srt = File(p.join(src.path, 'book.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
    await sourceDb.upsertAudiobook(
      AudiobooksCompanion.insert(
        bookKey: 'aiff-book',
        audioRoot: Value(src.path),
        audioPathsJson: Value(jsonEncode(tracks)),
        alignmentFormat: 'srt',
        alignmentPath: srt.path,
      ),
    );
    await sourceDb.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt-aiff',
        title: 'AIFF Book',
        audioRoot: Value(src.path),
        audioPathsJson: Value(jsonEncode(tracks)),
        srtPath: srt.path,
        importedAt: 1,
        bookKey: const Value('aiff-book'),
      ),
    );
    return SyncAssetPackageService(db: sourceDb).exportAudioDatabasePackage(
      bookKey: 'aiff-book',
      srtBookUid: 'srt-aiff',
      outputFile: File(p.join(temp.path, 'book.fushiaudio')),
    );
  }

  Directory targetRoot() => Directory(p.join(temp.path, 'target'));

  test(
    'received AIFF tracks land as FLAC, in order, without clobbering',
    () async {
      final File package = await exportReferenceBook(<String>[
        'a.aiff',
        'b.mp3',
        'a.flac',
        'c.AIF',
      ]);

      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetRoot(),
      );

      final String dir = p.join(targetRoot().path, 'aiff-book');
      final List<String> expected = <String>[
        p.join(dir, 'a _1.flac'), // a.flac 是另一轨：不能被 a.aiff 的产物覆盖
        p.join(dir, 'b.mp3'),
        p.join(dir, 'a.flac'),
        p.join(dir, 'c.flac'),
      ];
      final AudiobookRow book = (await targetDb.getAudiobookByBookKey(
        'aiff-book',
      ))!;
      expect(jsonDecode(book.audioPathsJson!), expected);
      final SrtBookRow srt = (await targetDb.getSrtBookByUid('srt-aiff'))!;
      expect(jsonDecode(srt.audioPathsJson!), expected);

      expect(transcoded, <String>['a.aiff', 'c.AIF']);
      expect(File(expected[0]).readAsStringSync(), 'fLaC<pcm:a.aiff>');
      expect(File(expected[2]).readAsStringSync(), 'pcm:a.flac');
      expect(File(expected[3]).readAsStringSync(), 'fLaC<pcm:c.AIF>');
      expect(
        Directory(
          dir,
        ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
        isNot(anyOf(contains('a.aiff'), contains('c.AIF'))),
        reason: '解出来的 AIFF 转完即删',
      );
    },
  );

  test('standalone (pure SRT) packages are normalised the same way', () async {
    final Directory src = Directory(p.join(temp.path, 'library'))
      ..createSync(recursive: true);
    final File track = File(p.join(src.path, 'voice.aiff'))
      ..writeAsStringSync('pcm');
    final File srt = File(p.join(src.path, 'voice.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    await sourceDb.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt-solo',
        title: 'Solo',
        audioRoot: Value(src.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        srtPath: srt.path,
        importedAt: 1,
        bookKey: const Value(''),
      ),
    );
    final File package = await SyncAssetPackageService(db: sourceDb)
        .exportAudioDatabasePackage(
          srtBookUid: 'srt-solo',
          outputFile: File(p.join(temp.path, 'solo.fushiaudio')),
        );

    await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
      packageFile: package,
      audioDatabaseRoot: targetRoot(),
    );

    final SrtBookRow row = (await targetDb.getSrtBookByUid('srt-solo'))!;
    expect(jsonDecode(row.audioPathsJson!), <String>[
      p.join(targetRoot().path, 'srt-solo', 'voice.flac'),
    ]);
    expect(
      File(p.join(targetRoot().path, 'srt-solo', 'voice.aiff')).existsSync(),
      isFalse,
    );
  });

  test(
    'a failed transcode writes no rows, so the book can be fetched again',
    () async {
      final File package = await exportReferenceBook(<String>['a.aiff']);
      AudiobookStorage.flacTranscoder = null;

      await expectLater(
        SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
          packageFile: package,
          audioDatabaseRoot: targetRoot(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await targetDb.getAudiobookByBookKey('aiff-book'), isNull);
      expect(await targetDb.getSrtBookByUid('srt-aiff'), isNull);
    },
  );

  test(
    're-downloading the same book replaces the earlier FLAC in place',
    () async {
      final File package = await exportReferenceBook(<String>['a.aiff']);
      final SyncAssetPackageService target = SyncAssetPackageService(
        db: targetDb,
      );
      await target.importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetRoot(),
      );
      await target.importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetRoot(),
      );

      final String dir = p.join(targetRoot().path, 'aiff-book');
      final AudiobookRow book = (await targetDb.getAudiobookByBookKey(
        'aiff-book',
      ))!;
      expect(jsonDecode(book.audioPathsJson!), <String>[p.join(dir, 'a.flac')]);
      expect(
        Directory(
          dir,
        ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
        unorderedEquals(<String>['a.flac', 'book.srt']),
      );
    },
  );
}
