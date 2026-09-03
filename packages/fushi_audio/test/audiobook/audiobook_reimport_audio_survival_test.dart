import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/src/audiobook/audiobook_health.dart';
import 'package:fushi_audio/src/audiobook/audiobook_model.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:fushi_audio/src/audiobook/srt_book_model.dart';
import 'package:fushi_audio/src/audiobook/srt_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1678 / BUG-1679：「只重新导入音频和字幕」之后音频不响、偶尔能响就乱跳页。
///
/// 两条根因都在重新导入这一条路径上，且修法都是**改数据结构让错的用法写不出来**，
/// 而不是给危险 API 加一个「记得传对」的参数：
///   * BUG-1678 —— 「沿用现有音频」是把**已持久化的路径**原样再喂一遍导入流程来
///     表达的。旧写法是「先清目录、再逐个复制」两步，于是先把源文件删了，复制时
///     再去读它抛 [FileSystemException]：音频没了、库里还指着不存在的路径。现在
///     只有 [AudiobookStorage.syncAudioFiles] 这一个原语——「把目录同步成恰好这
///     一组」，删除那一半是私有的，两步写法无从表达。同一形状的另一半是整行
///     upsert：repository 已不再提供「写一整行 Audiobook」的入口，只剩
///     ensure / replaceAudio / replaceAlignment / writeHealth 四个窄动作。
///   * BUG-1679 —— 播放进度 pref 记的是毫秒偏移，只在它绑定的那套音频上有意义。
///     换音频后不归零：超出新时长则恢复 seek 把播放器钉在 EOF（症状「不响」），
///     落在时长内则起播点随机、followAudio 把阅读器拽走（症状「乱跳页」）。
///     归零挂在 [AudiobookRepository.replaceAudio] 上——换音频这件事只有这一个
///     入口，绕不过去。
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

  Directory persistDir() =>
      Directory(p.join(docsDir.path, 'persist'))..createSync(recursive: true);

  // ── BUG-1678 ①：同步原语不会毁掉自己的源文件 ────────────────────────────

  test('syncAudioFiles makes the dir exactly the sources, dropping the rest',
      () async {
    final Directory dir = persistDir();
    final File stale = File(p.join(dir.path, 'stale.mp3'))
      ..writeAsStringSync('X');
    final File a = writeSource('01.mp3', 'AAA');

    final List<String> got =
        await AudiobookStorage.syncAudioFiles(dir, <String>[a.path]);

    expect(got, hasLength(1));
    expect(File(got.single).existsSync(), isTrue);
    expect(p.equals(p.dirname(got.single), dir.path), isTrue,
        reason: '外部源被复制进持久目录');
    expect(stale.existsSync(), isFalse, reason: '不在这一组里的旧音频被清掉');
  });

  test('syncAudioFiles fed the files already in the dir is a no-op, not a wipe',
      () async {
    final Directory dir = persistDir();
    final List<String> first = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[
        writeSource('01.mp3', 'AAA').path,
        writeSource('02.mp3', 'BB').path
      ],
    );

    // 「沿用现有音频」= 把落地后的路径原样喂回来。旧的两步写法在这里会先把它们
    // 删掉，再去读已不存在的文件而抛 FileSystemException。
    final List<String> again =
        await AudiobookStorage.syncAudioFiles(dir, first);

    expect(again, equals(first), reason: '幂等：同一组进去，同一组出来');
    expect(first.every((String path) => File(path).existsSync()), isTrue,
        reason: '沿用现有音频不该把它们从磁盘上删掉（BUG-1678）');
    expect(File(first.first).readAsStringSync(), 'AAA', reason: '内容也没被覆写');
  });

  test('syncAudioFiles keeps a kept file and still drops the replaced one',
      () async {
    final Directory dir = persistDir();
    final List<String> first = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[
        writeSource('01.mp3', 'AAA').path,
        writeSource('02.mp3', 'BB').path
      ],
    );
    final File fresh = writeSource('99.mp3', 'CCCC');

    // 混合：留下第一个，把第二个换掉。三种情况（全换/全留/混合）同一条路径。
    final List<String> mixed = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[first.first, fresh.path],
    );

    expect(mixed.first, first.first, reason: '留下的那个零拷贝原地保留');
    expect(File(first.first).existsSync(), isTrue);
    expect(File(first.last).existsSync(), isFalse, reason: '被换掉的那个清掉');
    expect(File(mixed.last).readAsStringSync(), 'CCCC');
  });

  test('replaceAudio fed its own persisted paths keeps the audio', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await repo.save(SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Demo'
      ..srtPath = '/src/demo.srt'
      ..importedAt = 1);

    final List<String> persisted = await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[
        writeSource('01.mp3', 'AAA').path,
        writeSource('02.mp3', 'BBBB').path,
      ],
    );
    final List<String> again =
        await repo.replaceAudio(uid: 'srtbook_1', pickedPaths: persisted);

    expect(again, equals(persisted));
    expect(persisted.every((String path) => File(path).existsSync()), isTrue,
        reason: '沿用现有音频不该把它们从磁盘上删掉（BUG-1678）');
    expect((await repo.findByUid('srtbook_1'))!.audioPaths, equals(persisted));
  });

  // ── BUG-1678 ②：窄写入不会清掉没碰的列 ─────────────────────────────────

  test('replaceAlignment leaves the audio columns alone', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo
        .replaceAudio(bookKey: 'Demo', audioPaths: <String>['/persist/01.mp3']);
    await repo.replaceAlignment(
        bookKey: 'Demo', format: 'srt', path: '/persist/a.srt');

    // 只换字幕（不带音频）—— 正是用户走的那条路径。
    await repo.replaceAlignment(
        bookKey: 'Demo', format: 'srt', path: '/persist/new.srt');

    final Audiobook after = (await repo.findByBookKey('Demo'))!;
    expect(after.audioPaths, equals(<String>['/persist/01.mp3']),
        reason: '换字幕不得清空音频（BUG-1678）');
    expect(after.alignmentPath, '/persist/new.srt');
  });

  test('replaceAudio leaves the alignment columns alone', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.replaceAlignment(
        bookKey: 'Demo', format: 'srt', path: '/persist/a.srt');
    await repo
        .replaceAudio(bookKey: 'Demo', audioPaths: <String>['/persist/01.mp3']);

    final Audiobook after = (await repo.findByBookKey('Demo'))!;
    expect(after.alignmentFormat, 'srt');
    expect(after.alignmentPath, '/persist/a.srt', reason: '换音频不得清空字幕');
  });

  test('ensureAudiobook is idempotent and never overwrites an existing row',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.replaceAlignment(
        bookKey: 'Demo', format: 'srt', path: '/persist/a.srt');
    await repo
        .replaceAudio(bookKey: 'Demo', audioPaths: <String>['/persist/01.mp3']);

    await repo.ensureAudiobook('Demo');

    final Audiobook after = (await repo.findByBookKey('Demo'))!;
    expect(after.alignmentPath, '/persist/a.srt');
    expect(after.audioPaths, equals(<String>['/persist/01.mp3']));
  });

  // ── BUG-1679：换音频必须作废旧时间轴的播放进度 ─────────────────────────

  test('replaceAudio resets the playback position when the audio changes',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.replaceAudio(
        bookKey: 'Demo', audioPaths: <String>['/persist/old.mp3']);
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 3600000);

    await repo.replaceAudio(
        bookKey: 'Demo', audioPaths: <String>['/persist/new.mp3']);

    expect(await repo.readPositionMs('Demo'), 0,
        reason: '旧位置指向另一段声音：超时长会钉在 EOF「不响」，'
            '在时长内会随机起播并把阅读器拽走「乱跳页」（BUG-1679）');
  });

  test('replaceAudio keeps the position when fed the same audio set', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.replaceAudio(
        bookKey: 'Demo', audioPaths: <String>['/persist/old.mp3']);
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 3600000);

    await repo.replaceAudio(
        bookKey: 'Demo', audioPaths: <String>['/persist/old.mp3']);

    expect(await repo.readPositionMs('Demo'), 3600000,
        reason: '重复导入同一组音频不该误伤「听到哪儿了」');
  });

  test('replaceAlignment / writeHealth never touch the position', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.replaceAudio(
        bookKey: 'Demo', audioPaths: <String>['/persist/old.mp3']);
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 3600000);

    await repo.replaceAlignment(
        bookKey: 'Demo', format: 'srt', path: '/persist/new.srt');
    await repo.writeHealth(
      bookKey: 'Demo',
      health: AudiobookHealth.fromRatePct(ratePct: 90, reason: 'x'),
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

    await repo.replaceAudio(uid: 'srtbook_1', pickedPaths: first);
    expect(await prefs.readPositionMs('srtbook_1'), 3600000);

    await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[writeSource('99.mp3', 'CCCCC').path],
    );
    expect(await prefs.readPositionMs('srtbook_1'), 0);
  });
}
