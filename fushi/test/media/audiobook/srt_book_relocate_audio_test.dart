import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/audiobook/audiobook_storage_platform.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG（#3722 c48 gap-novelmisc-1）：书架「重新定位文件」只改写 `srt_books` 一侧，
/// EPUB 有声书的 `audiobooks` 行仍指着坏路径。会话启动器优先读 `audiobooks` 行：
/// - 旧路径部分还在 → 按那一行的残缺列表起播（文件缺项、cue 错位）；
/// - 旧路径全断 → 退到 srt 行按 uid 身份起播（cue / 进度挂在 bookKey 上，字幕不跟、
///   进度归零）。
///
/// 钉在启动器读路径上：重新定位后 `resolve(bookKey)` 必须仍是 audiobooks 来源、
/// 拿到全部新路径，播放进度不动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late FushiDatabase db;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('fushi_relocate_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return docsDir.path;
            }
            return null;
          },
        );
    installAudiobookStoragePlatform();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    AudiobookStorage.documentsRootResolver = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  const String bookKey = 'epub-audio';
  const String uid = 'srtbook_epub_$bookKey';

  /// 一本 EPUB 有声书：`audiobooks` 行（带对齐字幕）+ 配对 srt 行，两行登记同一批
  /// 两个音频文件；断点 1234 ms。返回原来那两个文件。
  Future<List<File>> seedEpubAudiobook() async {
    final Directory oldDir = Directory(p.join(docsDir.path, 'old'))
      ..createSync(recursive: true);
    final List<File> audio = <File>[
      File(p.join(oldDir.path, '01.mp3'))..writeAsStringSync('A1'),
      File(p.join(oldDir.path, '02.mp3'))..writeAsStringSync('A2'),
    ];
    final File alignment = File(p.join(oldDir.path, 'align.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');
    final List<String> paths = <String>[for (final File f in audio) f.path];

    final AudiobookRepository abRepo = AudiobookRepository(db);
    await abRepo.replaceAlignment(
      bookKey: bookKey,
      format: 'srt',
      path: alignment.path,
    );
    await abRepo.replaceAudio(bookKey: bookKey, audioPaths: paths);
    await abRepo.updatePositionMs(bookKey: bookKey, positionMs: 1234);

    await SrtBookRepository(db).save(
      SrtBook()
        ..uid = uid
        ..title = 'Paired'
        ..srtPath = alignment.path
        ..audioPaths = paths
        ..importedAt = 1
        ..bookKey = bookKey,
    );
    return audio;
  }

  /// 把 [files] 挪进新目录，返回新路径。
  List<String> moveAll(List<File> files) {
    final Directory newDir = Directory(p.join(docsDir.path, 'moved'))
      ..createSync(recursive: true);
    return <String>[
      for (final File f in files)
        f.renameSync(p.join(newDir.path, p.basename(f.path))).path,
    ];
  }

  test('部分断链：重新定位后启动器拿到 audiobooks 行的完整新列表', () async {
    final List<File> audio = await seedEpubAudiobook();
    // 只挪走第二个文件：旧列表还剩一个能用。
    final String moved = moveAll(<File>[audio[1]]).single;
    final List<String> picked = <String>[audio[0].path, moved];

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths(uid, picked);
    expect(result, isA<SrtBookRelocated>());

    final AudiobookSessionStartRequest? request =
        await AudiobookSessionLauncher(db).resolve(bookKey);
    expect(request, isNotNull);
    expect(request!.isSrtBookSource, isFalse);
    expect(
      request.audioFiles.map((File f) => f.path).toList(),
      picked,
      reason: 'audiobooks 行没跟着改时这里只有残存的一个文件',
    );
    expect(await AudiobookRepository(db).readPositionMs(bookKey), 1234);
  });

  test('全部断链：重新定位后仍按 bookKey 身份起播，进度不归零', () async {
    final List<File> audio = await seedEpubAudiobook();
    final List<String> picked = moveAll(audio);

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths(uid, picked);
    expect(result, isA<SrtBookRelocated>());

    final AudiobookSessionStartRequest? request =
        await AudiobookSessionLauncher(db).resolve(bookKey);
    expect(request, isNotNull);
    expect(
      request!.isSrtBookSource,
      isFalse,
      reason: '只改 srt 行时启动器退到 srt 行按 uid 起播：cue / 进度对不上',
    );
    expect(request.audioFiles.map((File f) => f.path).toList(), picked);
    expect(await AudiobookRepository(db).readPositionMs(bookKey), 1234);
    final SrtBook? srt = await SrtBookRepository(db).findByUid(uid);
    expect(srt!.audioPaths, picked);
  });

  test('配对行文件数不等：拒绝，两行一字不改', () async {
    final List<File> audio = await seedEpubAudiobook();
    final List<String> before = <String>[for (final File f in audio) f.path];
    final List<String> picked = moveAll(<File>[audio[0]]);

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths(uid, picked);
    expect(
      result,
      isA<SrtBookRelocateCountMismatch>().having(
        (SrtBookRelocateCountMismatch r) => r.expected,
        'expected',
        before.length,
      ),
    );

    final SrtBook? srt = await SrtBookRepository(db).findByUid(uid);
    expect(srt!.audioPaths, before);
    final Audiobook? ab = await AudiobookRepository(db).findByBookKey(bookKey);
    expect(ab!.audioPaths, before);
  });

  test('两行原登记数互相不等：报冲突带两边的数，两行一字不改', () async {
    final List<File> audio = await seedEpubAudiobook();
    final List<String> srtBefore = <String>[for (final File f in audio) f.path];
    // 脏数据：audiobooks 行登记了三个文件，srt 行只有两个。
    final List<String> abBefore = <String>[
      ...srtBefore,
      p.join(docsDir.path, 'old', '03.mp3'),
    ];
    await AudiobookRepository(
      db,
    ).replaceAudio(bookKey: bookKey, audioPaths: abBefore);

    for (final int count in <int>[2, 3]) {
      final List<String> picked = <String>[
        for (int i = 0; i < count; i++) p.join(docsDir.path, 'n$i.mp3'),
      ];
      final SrtBookRelocateResult result = await SrtBookRepository(
        db,
      ).relocateAudioPaths(uid, picked);
      expect(
        result,
        isA<SrtBookRelocateRecordsConflict>()
            .having(
              (SrtBookRelocateRecordsConflict r) => r.srtBookCount,
              'srtBookCount',
              2,
            )
            .having(
              (SrtBookRelocateRecordsConflict r) => r.audiobookCount,
              'audiobookCount',
              3,
            ),
        reason: '选 $count 个：两行登记不一致时不能报一个永远选不对的期望数',
      );
    }
    final SrtBook? srt = await SrtBookRepository(db).findByUid(uid);
    expect(srt!.audioPaths, srtBefore);
    final Audiobook? ab = await AudiobookRepository(db).findByBookKey(bookKey);
    expect(ab!.audioPaths, abBefore);
  });

  /// 旧版书架 audioOnly 导入误落的脏行：`audiobooks` 行没有对齐字幕、音频
  /// 在 [audioPath]（还存在，所以启动器会优先拿它起播），配对 srt 行登记的音频已断。
  Future<void> seedDirtyRow(String dirtyKey, String audioPath) async {
    final AudiobookRepository abRepo = AudiobookRepository(db);
    await abRepo.ensureAudiobook(dirtyKey);
    await abRepo.replaceAudio(
      bookKey: dirtyKey,
      audioPaths: <String>[audioPath],
    );
    final Directory dir = Directory(p.join(docsDir.path, 'dirty_srt'))
      ..createSync(recursive: true);
    final File srt = File(p.join(dir.path, 'b.srt'))..writeAsStringSync('');
    await SrtBookRepository(db).save(
      SrtBook()
        ..uid = 'srtbook_epub_$dirtyKey'
        ..title = 'Dirty'
        ..srtPath = srt.path
        ..audioPaths = <String>[p.join(dir.path, 'gone.mp3')]
        ..importedAt = 1
        ..bookKey = dirtyKey,
    );
  }

  test('没有对齐字幕的 audiobooks 脏行：重新定位后被删，启动器读到新文件', () async {
    const String dirtyKey = 'dirty';
    final Directory dirtyPersist = await AudiobookStorage.ensurePersistDir(
      dirtyKey,
    );
    final File stale = File(p.join(dirtyPersist.path, 'stale.mp3'))
      ..writeAsStringSync('S');
    await seedDirtyRow(dirtyKey, stale.path);
    final Directory freshDir = Directory(p.join(docsDir.path, 'fresh'))
      ..createSync(recursive: true);
    final File fresh = File(p.join(freshDir.path, 'fresh.mp3'))
      ..writeAsStringSync('F');

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths('srtbook_epub_$dirtyKey', <String>[fresh.path]);
    expect(result, isA<SrtBookRelocated>());
    expect(
      await AudiobookRepository(db).findByBookKey(dirtyKey),
      isNull,
      reason: '脏行不救活也不删时，启动器永远优先读它，重新定位不生效',
    );
    expect(dirtyPersist.existsSync(), isFalse, reason: '脏行的持久目录随行删除');

    final AudiobookSessionStartRequest? request =
        await AudiobookSessionLauncher(db).resolve(dirtyKey);
    expect(request, isNotNull);
    expect(request!.isSrtBookSource, isTrue);
    expect(request.audioFiles.map((File f) => f.path).toList(), <String>[
      fresh.path,
    ]);
  });

  test('新选的文件就在脏行持久目录里：删行但保留目录，不删刚选的文件', () async {
    const String dirtyKey = 'dirty-inside';
    final Directory dirtyPersist = await AudiobookStorage.ensurePersistDir(
      dirtyKey,
    );
    final File stale = File(p.join(dirtyPersist.path, 'stale.mp3'))
      ..writeAsStringSync('S');
    await seedDirtyRow(dirtyKey, stale.path);
    // 用户重新定位时选中的正是脏行目录里的文件。
    final File picked = File(p.join(dirtyPersist.path, 'chapter.mp3'))
      ..writeAsStringSync('P');

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths('srtbook_epub_$dirtyKey', <String>[picked.path]);
    expect(result, isA<SrtBookRelocated>());
    expect(await AudiobookRepository(db).findByBookKey(dirtyKey), isNull);
    expect(picked.existsSync(), isTrue, reason: '整目录删除会删掉用户刚选的文件');

    final AudiobookSessionStartRequest? request =
        await AudiobookSessionLauncher(db).resolve(dirtyKey);
    expect(request, isNotNull);
    expect(request!.isSrtBookSource, isTrue);
    expect(request.audioFiles.map((File f) => f.path).toList(), <String>[
      picked.path,
    ]);
  });

  test('重新定位被拒绝时脏行与目录都不动', () async {
    const String dirtyKey = 'dirty-rejected';
    final Directory dirtyPersist = await AudiobookStorage.ensurePersistDir(
      dirtyKey,
    );
    final File stale = File(p.join(dirtyPersist.path, 'stale.mp3'))
      ..writeAsStringSync('S');
    await seedDirtyRow(dirtyKey, stale.path);
    final Directory freshDir = Directory(p.join(docsDir.path, 'fresh2'))
      ..createSync(recursive: true);
    final List<String> picked = <String>[
      for (final String n in <String>['a.mp3', 'b.mp3'])
        (File(p.join(freshDir.path, n))..writeAsStringSync(n)).path,
    ];

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths('srtbook_epub_$dirtyKey', picked);
    expect(result, isA<SrtBookRelocateCountMismatch>());
    final Audiobook? ab = await AudiobookRepository(db).findByBookKey(dirtyKey);
    expect(ab!.audioPaths, <String>[stale.path]);
    expect(stale.existsSync(), isTrue);
  });

  group('独立字幕书（无配对有声书行）', () {
    const String standaloneUid = 'srtbook_standalone';

    Future<List<String>> seedStandalone() async {
      final Directory dir = Directory(p.join(docsDir.path, 'standalone'))
        ..createSync(recursive: true);
      final List<String> paths = <String>[
        p.join(dir.path, '01.mp3'),
        p.join(dir.path, '02.mp3'),
      ];
      final File srt = File(p.join(dir.path, 'b.srt'))..writeAsStringSync('');
      await SrtBookRepository(db).save(
        SrtBook()
          ..uid = standaloneUid
          ..title = 'Standalone'
          ..srtPath = srt.path
          ..audioPaths = paths
          ..importedAt = 1
          ..bookKey = '',
      );
      return paths;
    }

    test('文件数变了：先回 CountChanged 带原登记数，一字不改', () async {
      final List<String> before = await seedStandalone();
      final List<String> merged = <String>[p.join(docsDir.path, 'all.mp3')];

      final SrtBookRelocateResult result = await SrtBookRepository(
        db,
      ).relocateAudioPaths(standaloneUid, merged);
      expect(
        result,
        isA<SrtBookRelocateCountChanged>().having(
          (SrtBookRelocateCountChanged r) => r.expected,
          'expected',
          2,
        ),
      );
      final SrtBook? srt = await SrtBookRepository(db).findByUid(standaloneUid);
      expect(srt!.audioPaths, before);
    });

    test('确认后带 allowCountChange：选几个写几个', () async {
      await seedStandalone();
      final List<String> merged = <String>[p.join(docsDir.path, 'all.mp3')];

      final SrtBookRelocateResult result = await SrtBookRepository(
        db,
      ).relocateAudioPaths(standaloneUid, merged, allowCountChange: true);
      expect(result, isA<SrtBookRelocated>());
      final SrtBook? srt = await SrtBookRepository(db).findByUid(standaloneUid);
      expect(srt!.audioPaths, merged);
    });

    test('文件数相同：直接改写，不问', () async {
      await seedStandalone();
      final List<String> moved = <String>[
        p.join(docsDir.path, 'm1.mp3'),
        p.join(docsDir.path, 'm2.mp3'),
      ];

      final SrtBookRelocateResult result = await SrtBookRepository(
        db,
      ).relocateAudioPaths(standaloneUid, moved);
      expect(result, isA<SrtBookRelocated>());
      final SrtBook? srt = await SrtBookRepository(db).findByUid(standaloneUid);
      expect(srt!.audioPaths, moved);
    });
  });
}
