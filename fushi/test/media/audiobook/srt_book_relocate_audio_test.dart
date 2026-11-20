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
    expect(result, SrtBookRelocateResult.relocated);

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
    expect(result, SrtBookRelocateResult.relocated);

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
    expect(result, SrtBookRelocateResult.countMismatch);

    final SrtBook? srt = await SrtBookRepository(db).findByUid(uid);
    expect(srt!.audioPaths, before);
    final Audiobook? ab = await AudiobookRepository(db).findByBookKey(bookKey);
    expect(ab!.audioPaths, before);
  });

  test('没有对齐字幕的 audiobooks 脏行不被救活', () async {
    const String dirtyKey = 'dirty';
    final Directory dir = Directory(p.join(docsDir.path, 'dirty'))
      ..createSync(recursive: true);
    final File stale = File(p.join(dir.path, 'stale.mp3'))
      ..writeAsStringSync('S');
    final AudiobookRepository abRepo = AudiobookRepository(db);
    await abRepo.ensureAudiobook(dirtyKey);
    await abRepo.replaceAudio(
      bookKey: dirtyKey,
      audioPaths: <String>[stale.path],
    );
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
    final File fresh = File(p.join(dir.path, 'fresh.mp3'))
      ..writeAsStringSync('F');

    final SrtBookRelocateResult result = await SrtBookRepository(
      db,
    ).relocateAudioPaths('srtbook_epub_$dirtyKey', <String>[fresh.path]);
    expect(result, SrtBookRelocateResult.relocated);
    final Audiobook? ab = await abRepo.findByBookKey(dirtyKey);
    expect(ab!.audioPaths, <String>[stale.path]);
  });
}
