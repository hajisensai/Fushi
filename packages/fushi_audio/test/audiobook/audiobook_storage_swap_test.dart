import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:fushi_audio/src/audiobook/srt_book_model.dart';
import 'package:fushi_audio/src/audiobook/srt_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-4791：换音频是「拷新 → 写库 → 删旧」，任何一步失败都原样撤回。
///
/// 旧实现先把持久目录里不在新清单里的音频删光、再逐个拷新文件、最后才由调用方
/// 写库：拷到一半失败（磁盘满 / 源盘掉线 / AIFF 转码失败）时旧音频已经没了，库里
/// 的 `audioPaths` 还指着它们——复制导入的书，目录里那份就是唯一副本。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_audio_swap_');
  });

  tearDown(() {
    AudiobookStorage.flacTranscoder = null;
    AudiobookStorage.documentsRootResolver = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File source(String name, String body, {String dir = 'src'}) {
    final Directory d = Directory(p.join(root.path, dir))
      ..createSync(recursive: true);
    return File(p.join(d.path, name))..writeAsStringSync(body);
  }

  Directory persistDir() =>
      Directory(p.join(root.path, 'persist'))..createSync(recursive: true);

  /// 持久目录的全貌（相对路径 → 内容），含暂存 / 回收子目录里的东西。
  Map<String, String> snapshot(Directory dir) => <String, String>{
    for (final FileSystemEntity f in dir.listSync(recursive: true))
      if (f is File)
        p.relative(f.path, from: dir.path).replaceAll(r'\', '/'): f
            .readAsStringSync(),
  };

  /// 让第二个文件的「拷贝」失败：AIFF 走转码器，转码器抛错。
  void failTranscode() {
    AudiobookStorage.flacTranscoder = (String src, String dest) async {
      File(dest).writeAsStringSync('half-written');
      throw const FileSystemException('disk full');
    };
  }

  test(
    'a copy that fails midway leaves the old audio exactly as it was',
    () async {
      final Directory dir = persistDir();
      await AudiobookStorage.syncAudioFiles(dir, <String>[
        source('old1.mp3', 'OLD-1').path,
        source('old2.mp3', 'OLD-2').path,
      ]);
      File(p.join(dir.path, 'book.srt')).writeAsStringSync('SRT');
      final Map<String, String> before = snapshot(dir);
      failTranscode();

      await expectLater(
        AudiobookStorage.syncAudioFiles(dir, <String>[
          source('new1.mp3', 'NEW-1').path,
          source('new2.aiff', 'NEW-2').path,
          source('new3.mp3', 'NEW-3').path,
        ]),
        throwsA(isA<FileSystemException>()),
      );

      expect(snapshot(dir), before, reason: '旧音频必须原样还在，已拷好的新文件与半成品都要收走');
    },
  );

  test('a plain copy whose destination cannot be written throws instead of '
      'hanging', () async {
    final Directory dir = persistDir();
    // 落点被一个同名目录占着：打不开（无权限 / 磁盘满的替身）。
    Directory(p.join(dir.path, 'new.mp3')).createSync();

    await expectLater(
      AudiobookStorage.persistFileWithProgress(
        source('new.mp3', 'NEW'),
        dir,
      ).timeout(const Duration(seconds: 10)),
      throwsA(isA<FileSystemException>()),
    );
    expect(snapshot(dir), isEmpty);
  });

  test('an unreadable source fails before anything on disk moves', () async {
    final Directory dir = persistDir();
    await AudiobookStorage.syncAudioFiles(dir, <String>[
      source('old.mp3', 'OLD').path,
    ]);
    final Map<String, String> before = snapshot(dir);

    await expectLater(
      AudiobookStorage.syncAudioFiles(dir, <String>[
        source('new.mp3', 'NEW').path,
        p.join(root.path, 'src', 'gone.mp3'),
      ]),
      throwsA(isA<FileSystemException>()),
    );
    expect(snapshot(dir), before);
  });

  test('a same-named replacement keeps the name instead of becoming '
      '"<stem> _1"', () async {
    final Directory dir = persistDir();
    await AudiobookStorage.syncAudioFiles(dir, <String>[
      source('01.mp3', 'OLD').path,
    ]);

    final List<String> got = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'NEW', dir: 'src2').path],
    );

    expect(got.map(p.basename), <String>['01.mp3']);
    expect(snapshot(dir), <String, String>{'01.mp3': 'NEW'});
  });

  test('commit runs with the new files in place and the old ones not yet '
      'deleted; they go only after it returns', () async {
    final Directory dir = persistDir();
    await AudiobookStorage.syncAudioFiles(dir, <String>[
      source('old.mp3', 'OLD').path,
    ]);

    Map<String, String>? duringCommit;
    List<String>? handed;
    final List<String> got = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('new.mp3', 'NEW').path],
      commit: (List<String> persisted) async {
        handed = persisted;
        duringCommit = snapshot(dir);
      },
    );

    expect(handed, got);
    expect(duringCommit, <String, String>{
      'new.mp3': 'NEW',
      '${AudiobookStorage.retiredDirName}/old.mp3': 'OLD',
    });
    expect(snapshot(dir), <String, String>{'new.mp3': 'NEW'});
  });

  test('a commit that throws puts the directory back', () async {
    final Directory dir = persistDir();
    final List<String> first = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'OLD-1').path, source('02.mp3', 'OLD-2').path],
    );
    final Map<String, String> before = snapshot(dir);

    await expectLater(
      AudiobookStorage.syncAudioFiles(
        dir,
        <String>[
          first[0], // 沿用
          source('02.mp3', 'NEW-2', dir: 'src2').path, // 同名替换
          source('03.mp3', 'NEW-3', dir: 'src2').path, // 新增
        ],
        commit: (List<String> persisted) async =>
            throw StateError('db write failed'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(snapshot(dir), before);
  });

  test('reference import drops the old copies only after commit', () async {
    final Directory dir = persistDir();
    await AudiobookStorage.syncAudioFiles(dir, <String>[
      source('old.mp3', 'OLD').path,
    ]);
    final Map<String, String> before = snapshot(dir);
    final String original = source('lib.mp3', 'LIB', dir: 'library').path;

    await expectLater(
      AudiobookStorage.syncAudioFiles(
        dir,
        <String>[original],
        copy: false,
        commit: (List<String> persisted) async =>
            throw StateError('db write failed'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(snapshot(dir), before, reason: '写库没成，旧副本仍是库里指着的那份');

    final List<String> got = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[original],
      copy: false,
      commit: (List<String> persisted) async {},
    );
    expect(got, <String>[original]);
    expect(snapshot(dir), isEmpty);
    expect(File(original).readAsStringSync(), 'LIB');
  });

  test('leftovers of a swap killed midway are put back on the next '
      'sync', () async {
    final Directory dir = persistDir();
    final List<String> first = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'OLD-1').path, source('02.mp3', 'OLD-2').path],
    );
    // 进程死在「旧文件已挪走、新文件还没落位」：01 在回收目录，暂存里有半份新的。
    final Directory retired = Directory(
      p.join(dir.path, AudiobookStorage.retiredDirName),
    )..createSync();
    File(first[0]).renameSync(p.join(retired.path, '01.mp3'));
    Directory(p.join(dir.path, AudiobookStorage.incomingDirName)).createSync();
    File(
      p.join(dir.path, AudiobookStorage.incomingDirName, 'new.mp3'),
    ).writeAsStringSync('HALF');

    // 库里还指着 first：把它原样喂回来（「沿用现有音频」）。
    final List<String> again = await AudiobookStorage.syncAudioFiles(
      dir,
      first,
    );

    expect(again, first);
    expect(snapshot(dir), <String, String>{
      '01.mp3': 'OLD-1',
      '02.mp3': 'OLD-2',
    });
  });

  group('SrtBookRepository.replaceAudio', () {
    late FushiDatabase db;
    late SrtBookRepository repo;

    setUp(() {
      AudiobookStorage.documentsRootResolver = () async => root;
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = SrtBookRepository(db);
    });

    tearDown(() => db.close());

    Future<void> seed() => repo.save(
      SrtBook()
        ..uid = 'srtbook_1'
        ..title = 'Demo'
        ..srtPath = ''
        ..bookKey = ''
        ..importedAt = 1,
    );

    test('a failed copy keeps the row and the files it points at', () async {
      await seed();
      final List<String> first = await repo.replaceAudio(
        uid: 'srtbook_1',
        pickedPaths: <String>[source('old.mp3', 'OLD').path],
      );
      failTranscode();

      await expectLater(
        repo.replaceAudio(
          uid: 'srtbook_1',
          pickedPaths: <String>[
            source('new1.mp3', 'NEW-1').path,
            source('new2.aiff', 'NEW-2').path,
          ],
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect((await repo.findByUid('srtbook_1'))!.audioPaths, first);
      expect(File(first.single).readAsStringSync(), 'OLD');
    });

    test('a failed row write rolls the files back', () async {
      await seed();
      final List<String> first = await repo.replaceAudio(
        uid: 'srtbook_1',
        pickedPaths: <String>[source('old.mp3', 'OLD').path],
      );
      final Directory dir = await AudiobookStorage.ensurePersistDir(
        'srtbook_1',
      );
      final Map<String, String> before = snapshot(dir);
      await db.customStatement(
        'CREATE TRIGGER fail_srt_write BEFORE UPDATE ON srt_books '
        "BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );

      await expectLater(
        repo.replaceAudio(
          uid: 'srtbook_1',
          pickedPaths: <String>[source('new.mp3', 'NEW').path],
        ),
        throwsA(anything),
      );

      await db.customStatement('DROP TRIGGER fail_srt_write');
      expect((await repo.findByUid('srtbook_1'))!.audioPaths, first);
      expect(snapshot(dir), before);
    });
  });
}
