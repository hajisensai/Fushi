import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/src/audiobook/audiobook_model.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:fushi_audio/src/audiobook/srt_book_model.dart';
import 'package:fushi_audio/src/audiobook/srt_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1678 / BUG-1679：「只重新导入音频和字幕」之后音频不响、偶尔能响就乱跳页。
///
/// 两条根因都在重新导入这一条路径上：
///   * BUG-1678 —— 「沿用现有音频」是把**已持久化的路径**原样再喂一遍导入流程来
///     表达的，而导入流程开头无条件 `cleanAudioFiles(persistDir)` 会先把这些源
///     文件删掉，紧接着复制循环再去读它就抛 [FileSystemException]：用户的音频没
///     了，库里还指着已不存在的路径。另一半是整行 upsert——凭空造的 `Audiobook`
///     会把本次没碰的列（audioPaths / audioRoot）一起清空。
///   * BUG-1679 —— 播放进度 pref 记的是毫秒偏移，只在它绑定的那套音频上有意义。
///     换音频后不归零：超出新时长则恢复 seek 把播放器钉在 EOF（症状「不响」），
///     落在时长内则起播点随机、followAudio 把阅读器拽走（症状「乱跳页」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late FushiDatabase db;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('fushi_reimport_audio_');
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
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  File writeSource(String name, String bytes) {
    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    return File(p.join(srcDir.path, name))..writeAsStringSync(bytes);
  }

  Audiobook audiobookWith({
    required String bookKey,
    List<String>? audioPaths,
    String? audioRoot,
    String alignmentPath = '/persist/demo.srt',
  }) {
    return Audiobook()
      ..bookKey = bookKey
      ..audioPaths = audioPaths
      ..audioRoot = audioRoot
      ..alignmentFormat = 'srt'
      ..alignmentPath = alignmentPath;
  }

  // ── BUG-1678：重新导入不得毁掉现有音频 ──────────────────────────────────

  test('cleanAudioFiles keeps the files named in `keep` and deletes the rest',
      () async {
    final Directory dir = Directory(p.join(docsDir.path, 'persist'))
      ..createSync(recursive: true);
    final File kept = File(p.join(dir.path, '01.mp3'))..writeAsStringSync('A');
    final File dropped = File(p.join(dir.path, '02.mp3'))
      ..writeAsStringSync('B');

    await AudiobookStorage.cleanAudioFiles(dir, keep: <String>[kept.path]);

    expect(kept.existsSync(), isTrue, reason: '本次导入的源文件绝不能被清目录删掉（BUG-1678）');
    expect(dropped.existsSync(), isFalse, reason: '不在保留集里的旧音频照常整组替换');
  });

  test(
      'replaceAudio fed its own persisted paths keeps the audio on disk and '
      'in the row instead of destroying it', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await repo.save(SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Demo'
      ..srtPath = '/src/demo.srt'
      ..importedAt = 1);

    // 第一次：正常从外部导入一组音频。
    final List<String> persisted = await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[
        writeSource('01.mp3', 'AAA').path,
        writeSource('02.mp3', 'BBBB').path,
      ],
    );
    expect(persisted, hasLength(2));
    expect(persisted.every((String path) => File(path).existsSync()), isTrue);

    // 第二次：把上一轮的持久路径原样喂回去 —— 这正是「换字幕、音频不变」在 UI 层
    // 的表达方式。修复前这里会先删源文件再读它，抛 FileSystemException。
    final List<String> again = await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: persisted,
    );

    expect(again, equals(persisted));
    expect(persisted.every((String path) => File(path).existsSync()), isTrue,
        reason: '沿用现有音频不该把它们从磁盘上删掉（BUG-1678）');
    final SrtBook? saved = await repo.findByUid('srtbook_1');
    expect(saved!.audioPaths, equals(persisted));
  });

  test(
      'Audiobook.cloneOf carries every column so a partial write cannot wipe '
      'the audio through the whole-row upsert', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      audioPaths: <String>['/persist/01.mp3'],
    ));

    // 只换字幕：基线取现有行，只改 alignmentPath。
    final Audiobook current = (await repo.findByBookKey('Demo'))!;
    await repo.saveAudiobook(
      Audiobook.cloneOf(current)..alignmentPath = '/persist/new.srt',
    );

    final Audiobook? after = await repo.findByBookKey('Demo');
    expect(after!.audioPaths, equals(<String>['/persist/01.mp3']),
        reason: '换字幕不得清空音频（BUG-1678）');
    expect(after.alignmentPath, '/persist/new.srt');
  });

  test('a from-scratch Audiobook still wipes untouched columns (why cloneOf)',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      audioPaths: <String>['/persist/01.mp3'],
    ));

    // 负向对照：upsert 是整行覆盖，凭空造的行会把音频列清零。写入方必须走
    // cloneOf；这条测试把那个前提钉住，防止有人把 cloneOf 当成可选的。
    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      alignmentPath: '/persist/new.srt',
    ));

    expect((await repo.findByBookKey('Demo'))!.audioPaths, isNull);
  });

  // ── BUG-1679：换音频必须作废旧时间轴的播放进度 ─────────────────────────

  test('saveAudiobook resets the playback position when the audio set changes',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      audioPaths: <String>['/persist/old.mp3'],
    ));
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 3600000);

    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      audioPaths: <String>['/persist/new.mp3'],
    ));

    expect(await repo.readPositionMs('Demo'), 0,
        reason: '旧位置指向另一段声音：超时长会钉在 EOF「不响」，'
            '在时长内会随机起播并把阅读器拽走「乱跳页」（BUG-1679）');
  });

  test('saveAudiobook keeps the playback position when the audio is unchanged',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.saveAudiobook(audiobookWith(
      bookKey: 'Demo',
      audioPaths: <String>['/persist/old.mp3'],
    ));
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 3600000);

    // 只换字幕 / 只回写 health：音频没变，听到哪儿了就该还在哪儿。
    final Audiobook current = (await repo.findByBookKey('Demo'))!;
    await repo.saveAudiobook(
      Audiobook.cloneOf(current)..alignmentPath = '/persist/new.srt',
    );

    expect(await repo.readPositionMs('Demo'), 3600000);
  });

  test('replaceAudio resets the SRT book position only when the audio changes',
      () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    final AudiobookRepository prefs = AudiobookRepository(db);
    await repo.save(SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Demo'
      ..srtPath = '/src/demo.srt'
      ..importedAt = 1);

    final List<String> first = await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[writeSource('01.mp3', 'AAA').path],
    );
    // SRT 书的进度键是 uid（与 AudiobookSessionLauncher 的 SRT 分支同源）。
    await prefs.updatePositionMs(bookKey: 'srtbook_1', positionMs: 3600000);

    // 沿用同一套音频：不动进度。
    await repo.replaceAudio(uid: 'srtbook_1', pickedPaths: first);
    expect(await prefs.readPositionMs('srtbook_1'), 3600000);

    // 换成另一组音频：归零。
    await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[writeSource('99.mp3', 'CCCCC').path],
    );
    expect(await prefs.readPositionMs('srtbook_1'), 0);
  });
}
