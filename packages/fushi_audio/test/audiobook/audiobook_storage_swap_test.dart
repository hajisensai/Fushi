import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:fushi_audio/src/audiobook/srt_book_model.dart';
import 'package:fushi_audio/src/audiobook/srt_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-4810：换音频是「拷新 → 写库 → 删旧」，任何一步失败都原样撤回。
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

  /// 持久目录下第 [n] 个回收批次（被杀进程的残留现场用）。
  Directory retiredBatch(Directory dir, int n) =>
      Directory(p.join(dir.path, AudiobookStorage.retiredDirName, '$n'))
        ..createSync(recursive: true);

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
      '${AudiobookStorage.retiredDirName}/1/old.mp3': 'OLD',
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
    final Directory batch = retiredBatch(dir, 1);
    File(first[0]).renameSync(p.join(batch.path, '01.mp3'));
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

  test('a same-named swap killed before its commit gives the name back to '
      'the old file', () async {
    final Directory dir = persistDir();
    final List<String> first = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'OLD-1').path, source('02.mp3', 'OLD-2').path],
    );
    // 进程死在「新 01 已落到正式名字」之后、写库成立之前：旧 01 在回收批次里，
    // 没有已提交标记；库还是旧的 cue / 对齐 / 进度。
    final Directory batch = retiredBatch(dir, 1);
    File(first[0]).renameSync(p.join(batch.path, '01.mp3'));
    File(first[0]).writeAsStringSync('NEW-1-NEVER-COMMITTED');

    final List<String> again = await AudiobookStorage.syncAudioFiles(
      dir,
      first,
    );

    expect(again, first);
    expect(snapshot(dir), <String, String>{
      '01.mp3': 'OLD-1',
      '02.mp3': 'OLD-2',
    }, reason: '库指着的是旧音频：未提交的同名新文件不能顶替它');
  });

  test('a swap killed after its commit keeps the new file and drops the '
      'retired one', () async {
    final Directory dir = persistDir();
    final List<String> current = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'NEW').path],
    );
    // 进程死在「写库已成立、标记已落」之后、删回收目录之前。
    final Directory batch = retiredBatch(dir, 1);
    File(p.join(batch.path, '01.mp3')).writeAsStringSync('OLD');
    File(
      p.join(batch.path, AudiobookStorage.retiredCommittedMarker),
    ).writeAsStringSync('');

    final List<String> again = await AudiobookStorage.syncAudioFiles(
      dir,
      current,
    );

    expect(again, current);
    expect(snapshot(dir), <String, String>{'01.mp3': 'NEW'});
  });

  test('a successful swap marks its retired batch committed before '
      'deleting it', () async {
    final Directory dir = persistDir();
    await AudiobookStorage.syncAudioFiles(dir, <String>[
      source('01.mp3', 'OLD').path,
    ]);
    // 更早一次没走完、旧文件也没能挪回去的批次：这次写库成立后它同样作废。
    final Directory stale = retiredBatch(dir, 3);
    File(p.join(stale.path, 'ghost.mp3')).writeAsStringSync('GHOST');
    // 让收拾阶段挪不回 ghost.mp3：原名被一个同名目录占着。
    Directory(p.join(dir.path, 'ghost.mp3')).createSync();

    Map<String, String>? duringCommit;
    await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[source('01.mp3', 'NEW', dir: 'src2').path],
      commit: (List<String> persisted) async {
        duringCommit = snapshot(dir);
      },
    );

    expect(duringCommit, <String, String>{
      '01.mp3': 'NEW',
      '${AudiobookStorage.retiredDirName}/3/ghost.mp3': 'GHOST',
      '${AudiobookStorage.retiredDirName}/4/01.mp3': 'OLD',
    }, reason: '写库成立之前不落已提交标记；本次用自己的新批次');
    expect(snapshot(dir), <String, String>{'01.mp3': 'NEW'});
  });

  group('held-open files (Windows sharing semantics)', () {
    test('an old file that cannot be moved aside aborts the swap and puts '
        'the others back', () async {
      final Directory dir = persistDir();
      final List<String> first =
          await AudiobookStorage.syncAudioFiles(dir, <String>[
            source('01.mp3', 'OLD-1').path,
            source('02.mp3', 'OLD-2').path,
            source('03.mp3', 'OLD-3').path,
          ]);
      final Map<String, String> before = snapshot(dir);
      // 播放器还开着 02.mp3。
      final RandomAccessFile held = File(first[1]).openSync();
      try {
        await expectLater(
          AudiobookStorage.syncAudioFiles(dir, <String>[
            source('new.mp3', 'NEW').path,
          ]),
          throwsA(isA<FileSystemException>()),
        );
        expect(snapshot(dir), before);
      } finally {
        held.closeSync();
      }
    });

    test('leftovers that cannot be deleted do not block the next '
        'sync', () async {
      final Directory dir = persistDir();
      await AudiobookStorage.syncAudioFiles(dir, <String>[
        source('01.mp3', 'CURRENT').path,
      ]);
      // 上一次换音频已成立，但回收批次里的旧文件、暂存里的同名残留都还被占着。
      final Directory batch = retiredBatch(dir, 1);
      final File oldFile = File(p.join(batch.path, '00.mp3'))
        ..writeAsStringSync('OLD');
      File(
        p.join(batch.path, AudiobookStorage.retiredCommittedMarker),
      ).writeAsStringSync('');
      final File staleStaged = File(
        p.join(dir.path, AudiobookStorage.incomingDirName, 'new.mp3'),
      )..createSync(recursive: true);
      staleStaged.writeAsStringSync('STALE');
      final List<RandomAccessFile> held = <RandomAccessFile>[
        oldFile.openSync(),
        staleStaged.openSync(),
      ];
      final List<String> got;
      try {
        got = await AudiobookStorage.syncAudioFiles(dir, <String>[
          source('new.mp3', 'NEW').path,
        ]);
      } finally {
        for (final RandomAccessFile f in held) {
          f.closeSync();
        }
      }

      expect(got.map(p.basename), <String>[
        'new.mp3',
      ], reason: '暂存目录里的同名残留不能把正式名字挤成 "new _1.mp3"');
      expect(File(got.single).readAsStringSync(), 'NEW');
      expect(File(p.join(dir.path, '01.mp3')).existsSync(), isFalse);

      // 占用解除后的下一次同步把残留收干净，且不把作废的旧文件挪回来。
      final List<String> again = await AudiobookStorage.syncAudioFiles(
        dir,
        got,
      );
      expect(again, got);
      expect(snapshot(dir), <String, String>{'new.mp3': 'NEW'});
    });
  }, testOn: 'windows');

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
