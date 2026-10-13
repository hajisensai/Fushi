import 'dart:io';

import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-3312 延伸：普通 AIFF 文件能直接导入有声书。
///
/// AIFF 是无损 PCM，但 Android 的有声书播放器（ExoPlayer）没有 AIFF 解析器。所以
/// AIFF 进持久目录时一律经 [AudiobookStorage.flacTranscoder] 转成 FLAC，持久目录里
/// 永远不出现 AIFF，书同步到哪一端都能播。
void main() {
  late Directory root;
  late List<(String, String)> calls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_aiff_persist_');
    calls = <(String, String)>[];
    AudiobookStorage.flacTranscoder = (String source, String flacPath) async {
      calls.add((source, flacPath));
      File(flacPath).writeAsStringSync('fLaC:${p.basename(source)}');
    };
  });

  tearDown(() {
    AudiobookStorage.flacTranscoder = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File source(String name) {
    final Directory dir = Directory(p.join(root.path, 'src'))
      ..createSync(recursive: true);
    return File(p.join(dir.path, name))..writeAsStringSync('FORM-AIFF-$name');
  }

  Directory persistDir() =>
      Directory(p.join(root.path, 'persist'))..createSync(recursive: true);

  test('AIFF / AIF are audiobook audio, picker list included', () {
    for (final String name in <String>['a.aiff', 'B.AIF', 'c.Aiff']) {
      expect(AudiobookStorage.isAudioFile(name), isTrue, reason: name);
    }
    expect(
      AudiobookStorage.audioExtensionsNoDot,
      containsAll(<String>['aiff', 'aif']),
    );
  });

  test(
    'syncAudioFiles transcodes AIFF to FLAC and copies the rest as-is',
    () async {
      final Directory dir = persistDir();
      final File aiff = source('01 Intro.aiff');
      final File aif = source('02.AIF');
      final File mp3 = source('03.mp3');
      final List<(int, int)> progress = <(int, int)>[];

      final List<String> got = await AudiobookStorage.syncAudioFiles(
        dir,
        <String>[aiff.path, aif.path, mp3.path],
        onProgress: (int copied, int total) => progress.add((copied, total)),
      );

      expect(got.map(p.basename), <String>[
        '01 Intro.flac',
        '02.flac',
        '03.mp3',
      ]);
      for (final String path in got) {
        expect(p.equals(p.dirname(path), dir.path), isTrue);
        expect(File(path).existsSync(), isTrue);
      }
      expect(calls, <(String, String)>[
        (aiff.path, got[0]),
        (aif.path, got[1]),
      ]);
      expect(File(got[2]).readAsStringSync(), 'FORM-AIFF-03.mp3');
      expect(
        dir.listSync().map((FileSystemEntity e) => p.extension(e.path)),
        isNot(contains('.aiff')),
        reason: '持久目录里不留 AIFF',
      );
      final int total = aiff.lengthSync() + aif.lengthSync() + mp3.lengthSync();
      expect(progress.last, (total, total));
    },
  );

  test(
    'feeding the persisted FLAC back is a no-op, not a second transcode',
    () async {
      final Directory dir = persistDir();
      final List<String> first = await AudiobookStorage.syncAudioFiles(
        dir,
        <String>[source('a.aiff').path],
      );
      calls.clear();

      final List<String> again = await AudiobookStorage.syncAudioFiles(
        dir,
        first,
      );

      expect(again, first);
      expect(calls, isEmpty);
      expect(File(first.single).readAsStringSync(), 'fLaC:a.aiff');
    },
  );

  test('two AIFFs with the same stem do not collapse into one FLAC', () async {
    final Directory dir = persistDir();
    final File a = source('01.aiff');
    final Directory disc2 = Directory(p.join(root.path, 'disc2'))..createSync();
    final File b = File(p.join(disc2.path, '01.aif'))..writeAsStringSync('B');

    final List<String> got = await AudiobookStorage.syncAudioFiles(
      dir,
      <String>[a.path, b.path],
    );

    expect(got.toSet(), hasLength(2));
    expect(got.map(p.extension), everyElement('.flac'));
  });

  test(
    'no transcoder installed: AIFF fails loudly instead of being copied raw',
    () async {
      AudiobookStorage.flacTranscoder = null;
      final Directory dir = persistDir();

      await expectLater(
        AudiobookStorage.syncAudioFiles(dir, <String>[source('a.aiff').path]),
        throwsA(isA<StateError>()),
      );
      expect(dir.listSync(), isEmpty);
    },
  );

  test(
    'a transcoder that produces nothing is an error, not a missing track',
    () async {
      AudiobookStorage.flacTranscoder =
          (String source, String flacPath) async {};
      final Directory dir = persistDir();

      await expectLater(
        AudiobookStorage.syncAudioFiles(dir, <String>[source('a.aiff').path]),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('reference import (copy: false) keeps the original AIFF path', () async {
    final File aiff = source('a.aiff');

    final List<String> got = await AudiobookStorage.syncAudioFiles(
      persistDir(),
      <String>[aiff.path],
      copy: false,
    );

    expect(got, <String>[aiff.path]);
    expect(calls, isEmpty);
  });
}
