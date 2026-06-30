import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/audiobook/audiobook_storage.dart';
import 'package:hibiki_audio/src/audiobook/srt_book_model.dart';
import 'package:hibiki_audio/src/audiobook/srt_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1032：SrtBookRepository.replaceAudio 是三入口（书架重新定位/书架导入音频/
/// 阅读器内导入）归一后的唯一写入路径。本测试核实它的「复制导入 + 改写
/// audioPaths + 清空 audioRoot」语义与阅读器内 _openSrtBookAudioPicker 等价：
/// 选定文件被复制进 uid 派生的持久目录、audioPaths 指向复制后的路径、audioRoot 清空。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late HibikiDatabase db;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('hibiki_replace_audio_');
    // ensurePersistDir/deletePersistDir 经 getApplicationDocumentsDirectory()
    // 解析持久根，测试把它指向临时目录。
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
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
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

  Future<void> seedBook(SrtBookRepository repo, {String? audioRoot}) async {
    final SrtBook book = SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Demo'
      ..srtPath = '/src/demo.srt'
      ..importedAt = 1
      ..audioRoot = audioRoot;
    await repo.save(book);
  }

  test(
      'replaceAudio copies picked files into the uid persist dir, sets '
      'audioPaths to the copied paths, and clears audioRoot', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedBook(repo, audioRoot: '/some/old/folder');

    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    final File a = File(p.join(srcDir.path, '01.mp3'))
      ..writeAsStringSync('AAA');
    final File b = File(p.join(srcDir.path, '02.mp3'))
      ..writeAsStringSync('BBBB');

    final List<String> persisted = await repo.replaceAudio(
      uid: 'srtbook_1',
      pickedPaths: <String>[a.path, b.path],
    );

    final SrtBook? saved = await repo.findByUid('srtbook_1');
    expect(saved, isNotNull);
    // audioPaths == 复制后的持久路径（与返回值一致），audioRoot 被清空。
    expect(saved!.audioPaths, equals(persisted));
    expect(saved.audioRoot, isNull);

    // 复制后的路径落在 uid 派生的持久目录之内（非原始 /src 路径）。
    final Directory persistDir =
        await AudiobookStorage.ensurePersistDir('srtbook_1');
    for (final String path in persisted) {
      expect(p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(path)),
          isTrue,
          reason: '$path should be inside ${persistDir.path}');
      expect(File(path).existsSync(), isTrue);
    }
    expect(File(persisted[0]).readAsStringSync(), 'AAA');
    expect(File(persisted[1]).readAsStringSync(), 'BBBB');
  });

  test(
      'replaceAudio replaces a previous audio set (cleanAudioFiles) instead '
      'of accumulating', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedBook(repo);

    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    final File first = File(p.join(srcDir.path, 'first.mp3'))
      ..writeAsStringSync('1');
    await repo
        .replaceAudio(uid: 'srtbook_1', pickedPaths: <String>[first.path]);

    final File second = File(p.join(srcDir.path, 'second.mp3'))
      ..writeAsStringSync('2');
    final List<String> persisted = await repo
        .replaceAudio(uid: 'srtbook_1', pickedPaths: <String>[second.path]);

    final SrtBook? saved = await repo.findByUid('srtbook_1');
    expect(saved!.audioPaths, equals(persisted));

    // 持久目录只剩最新一组音频，旧文件已被 cleanAudioFiles 删除。
    final Directory persistDir =
        await AudiobookStorage.ensurePersistDir('srtbook_1');
    final List<String> audioInDir = persistDir
        .listSync()
        .whereType<File>()
        .where((File f) => AudiobookStorage.isAudioFile(f.path))
        .map((File f) => p.basename(f.path))
        .toList();
    expect(audioInDir, <String>['second.mp3']);
  });

  test('replaceAudio with empty picks is a no-op (no write, no throw)',
      () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedBook(repo, audioRoot: '/keep/this');

    final List<String> persisted =
        await repo.replaceAudio(uid: 'srtbook_1', pickedPaths: <String>[]);
    expect(persisted, isEmpty);

    final SrtBook? saved = await repo.findByUid('srtbook_1');
    // 空选不触碰既有真值。
    expect(saved!.audioRoot, '/keep/this');
    expect(saved.audioPaths, isNull);
  });

  test('replaceAudio throws StateError for an unknown uid', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    final File src = File(p.join(docsDir.path, 'x.mp3'))
      ..writeAsStringSync('x');
    expect(
      () => repo.replaceAudio(uid: 'missing', pickedPaths: <String>[src.path]),
      throwsStateError,
    );
  });
}
