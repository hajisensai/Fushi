/// 有声书 / 字幕书「同时删除本地文件」的可删清单判据。
///
/// 这组断言存在的理由是一个具体的数据丢失：删除曾经复用播放装载用的解析，
/// `audioPaths` 为空时它会枚举 `audioRoot` 目录下**全部**音频文件。旧版按目录导入
/// 的年代，一个文件夹放多本书是常规用法——于是删 A 把 B 的音频也删了，B 还留在架上
/// 变成打不开的壳。读的范围可以宽松，删的不行。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/src/audiobook/audiobook_local_files.dart';
import 'package:fushi_audio/src/audiobook/audiobook_playback_files.dart';
import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, deleteLocalFiles;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String persistRoot;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi-audio-local-');
    persistRoot = p.join(tmp.path, 'app', 'audiobooks');
    Directory(persistRoot).createSync(recursive: true);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('audiobookLocalFilePaths', () {
    test('纯 audioRoot 的旧行没有可删清单——一个文件都不给', () {
      // 这条记录从来没记下过「目录里哪些文件属于这本书」。承认这个状态，
      // 而不是现编一个目录清扫补上。
      expect(
        audiobookLocalFilePaths(audioPaths: null, persistRoot: persistRoot),
        isEmpty,
      );
      expect(
        audiobookLocalFilePaths(
          audioPaths: const <String>[],
          persistRoot: persistRoot,
        ),
        isEmpty,
      );
      expect(
        audiobookHasLocalFiles(audioPaths: null, persistRoot: persistRoot),
        isFalse,
        reason: '没有可删清单 → 界面上根本不该摆勾选框',
      );
    });

    test('落在 app 持久目录里的是副本，不是用户原件', () {
      final String copy = p.join(persistRoot, 'abcd1234', '01.mp3');
      expect(
        audiobookLocalFilePaths(
          audioPaths: <String>[copy],
          persistRoot: persistRoot,
        ),
        isEmpty,
        reason: '导入时 app 自己复制的那份由 deletePersistDir 回收，不算原件',
      );
    });

    test('只有显式登记、且在持久目录之外的绝对路径才可删；去重保序', () {
      final String a = p.join(tmp.path, 'music', '01.mp3');
      final String b = p.join(tmp.path, 'music', '02.mp3');
      final String copy = p.join(persistRoot, 'hash', '03.mp3');
      expect(
        audiobookLocalFilePaths(
          audioPaths: <String>[a, b, a, copy, '  ', 'relative/04.mp3'],
          persistRoot: persistRoot,
        ),
        <String>[a, b],
        reason: '相对路径按进程 cwd 解析，删除路径上一律拒绝',
      );
    });

    test('持久根解析不出来（空串）→ 一个文件都不删', () {
      expect(
        audiobookLocalFilePaths(
          audioPaths: <String>[p.join(tmp.path, 'music', '01.mp3')],
          persistRoot: '',
        ),
        isEmpty,
        reason: '判不出「是不是 app 副本」时不删，是这里唯一可接受的失败方向',
      );
    });
  });

  group('删除范围（audioRoot 下混着别的书）', () {
    test('只删本书登记的那几个，同目录里别的书的音频原样保留', () async {
      final Directory music = Directory(p.join(tmp.path, 'music'))
        ..createSync(recursive: true);
      // 本书登记的两个文件。
      final File mine1 = File(p.join(music.path, 'A-01.mp3'))
        ..writeAsStringSync('1');
      final File mine2 = File(p.join(music.path, 'A-02.mp3'))
        ..writeAsStringSync('2');
      // 同一个文件夹里另一本书的音频——旧的目录清扫会把它们一起删掉。
      final File others1 = File(p.join(music.path, 'B-01.mp3'))
        ..writeAsStringSync('3');
      final File others2 = File(p.join(music.path, 'B-02.mp3'))
        ..writeAsStringSync('4');

      final List<String> deletable = audiobookLocalFilePaths(
        audioPaths: <String>[mine1.path, mine2.path],
        persistRoot: persistRoot,
      );
      final LocalFileDeleteReport report = await deleteLocalFiles(deletable);

      expect(report.removedSet, <String>{mine1.path, mine2.path});
      expect(report.failures, isEmpty);
      expect(mine1.existsSync(), isFalse);
      expect(mine2.existsSync(), isFalse);
      expect(others1.existsSync(), isTrue, reason: '同目录里别的书的音频绝不能被牵连');
      expect(others2.existsSync(), isTrue);
      expect(music.existsSync(), isTrue, reason: '只删文件，绝不删目录');
    });

    test('播放解析仍然宽松地枚举整个 audioRoot——两条解析必须是两个口径', () async {
      final Directory music = Directory(p.join(tmp.path, 'music2'))
        ..createSync(recursive: true);
      File(p.join(music.path, 'A-01.mp3')).writeAsStringSync('1');
      File(p.join(music.path, 'B-01.mp3')).writeAsStringSync('2');
      File(p.join(music.path, 'cover.jpg')).writeAsStringSync('x');

      final List<File> playback = await resolveAudiobookPlaybackFiles(
        audioPaths: null,
        audioRoot: music.path,
      );
      expect(
        playback.map((File f) => p.basename(f.path)).toList(),
        <String>['A-01.mp3', 'B-01.mp3'],
        reason: '播放侧照旧枚举目录（多认一个文件顶多多一条轨）',
      );
      expect(
        audiobookLocalFilePaths(audioPaths: null, persistRoot: persistRoot),
        isEmpty,
        reason: '删除侧对同一条记录必须给出空清单',
      );
    });
  });
}
