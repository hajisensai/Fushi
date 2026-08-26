/// 有声书 / 字幕书原始音频文件的判据、解析与删除（删除确认框「同时删除本地文件」）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/src/audiobook/audiobook_source_files.dart';
import 'package:path/path.dart' as p;

void main() {
  group('hasAudiobookSourceFiles', () {
    test('显式列表或 audioRoot 任一非空即有原件', () {
      expect(
        hasAudiobookSourceFiles(audioPaths: null, audioRoot: null),
        isFalse,
      );
      expect(
        hasAudiobookSourceFiles(audioPaths: <String>[], audioRoot: '  '),
        isFalse,
      );
      expect(
        hasAudiobookSourceFiles(
          audioPaths: <String>['/a.mp3'],
          audioRoot: null,
        ),
        isTrue,
      );
      expect(
        hasAudiobookSourceFiles(audioPaths: null, audioRoot: '/music'),
        isTrue,
      );
    });
  });

  group('resolve / delete', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi-audio-src-');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('显式列表：只取真实存在的', () async {
      final File a = File(p.join(tmp.path, 'a.mp3'))..writeAsStringSync('a');
      final List<File> files = await resolveAudiobookSourceFiles(
        audioPaths: <String>[a.path, p.join(tmp.path, 'gone.mp3')],
        audioRoot: tmp.path,
      );
      expect(files.map((File f) => f.path), <String>[a.path]);
    });

    test('audioRoot：直接子文件里的音频、按名排序、不递归', () async {
      File(p.join(tmp.path, '02.mp3')).writeAsStringSync('2');
      File(p.join(tmp.path, '01.mp3')).writeAsStringSync('1');
      File(p.join(tmp.path, 'cover.jpg')).writeAsStringSync('x');
      final Directory sub = Directory(p.join(tmp.path, 'sub'))..createSync();
      File(p.join(sub.path, '03.mp3')).writeAsStringSync('3');

      final List<File> files = await resolveAudiobookSourceFiles(
        audioPaths: null,
        audioRoot: tmp.path,
      );
      expect(files.map((File f) => p.basename(f.path)).toList(), <String>[
        '01.mp3',
        '02.mp3',
      ]);
    });

    test('删除只删解析出的文件，目录与非音频文件保留', () async {
      final File a = File(p.join(tmp.path, '01.mp3'))..writeAsStringSync('1');
      final File cover = File(p.join(tmp.path, 'cover.jpg'))
        ..writeAsStringSync('x');
      final Set<String> removed = await deleteAudiobookSourceFiles(
        audioPaths: null,
        audioRoot: tmp.path,
      );
      expect(removed, <String>{a.path});
      expect(a.existsSync(), isFalse);
      expect(cover.existsSync(), isTrue);
      expect(tmp.existsSync(), isTrue, reason: 'audioRoot 可能是用户的音乐文件夹');
    });
  });
}
