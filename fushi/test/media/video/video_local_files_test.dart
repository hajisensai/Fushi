/// 删除确认框「同时删除本地文件」（视频侧）的判据与删除护栏：
/// 远端流没有文件可删、相对路径不可删、播放列表各集算本地文件、仍被别的行引用的
/// 文件保留、大小写不同的同一个文件仍被护栏挡住、目录绝不删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_local_files.dart';
import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, platformPathKey;
import 'package:path/path.dart' as p;

/// 把路径里的字母大小写整体翻转，用来构造「同一个文件的另一种写法」。
String _swapCase(String value) => String.fromCharCodes(<int>[
      for (final int c in value.codeUnits)
        if (c >= 0x41 && c <= 0x5A)
          c + 32
        else if (c >= 0x61 && c <= 0x7A)
          c - 32
        else
          c,
    ]);

void main() {
  group('isLocalVideoFilePath', () {
    test('绝对的裸路径 / 盘符路径算本地', () {
      expect(isLocalVideoFilePath(r'D:\Videos\ep01.mkv'), isTrue);
      expect(isLocalVideoFilePath('/home/u/ep01.mkv'), isTrue);
    });

    test('相对路径不算本地——File.delete() 会按进程 cwd 解析', () {
      // 删除路径上「删掉哪个文件取决于 app 启动时的工作目录」是不可接受的不确定性。
      expect(isLocalVideoFilePath('relative/ep01.mkv'), isFalse);
      expect(isLocalVideoFilePath('ep01.mkv'), isFalse);
    });

    test('带 scheme 的 URI 不算本地（远端直传 / WebDAV / content）', () {
      expect(isLocalVideoFilePath('https://host/stream?token=1'), isFalse);
      expect(isLocalVideoFilePath('http://192.168.1.2:8080/a.mkv'), isFalse);
      expect(isLocalVideoFilePath('content://media/external/video/1'), isFalse);
      expect(isLocalVideoFilePath('file:///tmp/a.mkv'), isFalse);
    });

    test('空 / 空白不算', () {
      expect(isLocalVideoFilePath(''), isFalse);
      expect(isLocalVideoFilePath('   '), isFalse);
    });
  });

  group('playlistEntryPaths', () {
    test('解出各集路径；坏 JSON / 非列表 → 空', () {
      final String json = jsonEncode(<Map<String, Object>>[
        <String, Object>{'title': 'e1', 'path': r'D:\v\e1.mkv'},
        <String, Object>{
          'title': 'e2',
          'path': r'D:\v\e2.mkv',
          'positionMs': 3,
        },
      ]);
      expect(playlistEntryPaths(json), <String>[
        r'D:\v\e1.mkv',
        r'D:\v\e2.mkv',
      ]);
      expect(playlistEntryPaths(null), isEmpty);
      expect(playlistEntryPaths(''), isEmpty);
      expect(playlistEntryPaths('{not json'), isEmpty);
      expect(playlistEntryPaths('{"a":1}'), isEmpty);
    });
  });

  group('localVideoFileCandidates', () {
    test('videoPath + 播放列表各集，去重、剔远端', () {
      final String json = jsonEncode(<Map<String, Object>>[
        <String, Object>{'title': 'e1', 'path': 'D:/v/e1.mkv'},
        <String, Object>{'title': 'e1-dup', 'path': r'D:\v\e1.mkv'},
        <String, Object>{'title': 'remote', 'path': 'https://h/e2.mkv'},
      ]);
      expect(
        localVideoFileCandidates(
          videoPath: r'D:\v\list.m3u8',
          playlistJson: json,
        ),
        <String>[r'D:\v\list.m3u8', 'D:/v/e1.mkv'],
      );
    });

    test('远端流 → 无候选 → 弹窗不摆勾选框', () {
      expect(
        localVideoFileCandidates(videoPath: 'https://h/stream?token=x'),
        isEmpty,
      );
    });
  });

  group('deleteLocalVideoFiles', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi-local-del-');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('删未被引用的文件；被引用的保留；目录与缺失路径跳过', () async {
      final File a = File(p.join(tmp.path, 'a.mkv'))..writeAsStringSync('a');
      final File b = File(p.join(tmp.path, 'b.mkv'))..writeAsStringSync('b');
      final Directory d = Directory(p.join(tmp.path, 'dir'))..createSync();
      final String missing = p.join(tmp.path, 'missing.mkv');

      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path, b.path, d.path, missing],
        stillReferenced: <String>{platformPathKey(b.path)},
      );

      expect(report.removedSet, <String>{a.path});
      expect(report.failures, isEmpty, reason: '本来就不存在的路径不算删除失败');
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isTrue, reason: '仍被别的库行引用的文件不能删');
      expect(d.existsSync(), isTrue, reason: '目录绝不删');
    });

    test('护栏比对经路径归一（分隔符差异不放行误删）', () async {
      final File a = File(p.join(tmp.path, 'a.mkv'))..writeAsStringSync('a');
      final String flipped = a.path.replaceAll(r'\', '/');
      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path],
        stillReferenced: <String>{platformPathKey(flipped)},
      );
      expect(report.removed, isEmpty);
      expect(a.existsSync(), isTrue);
    });

    test('护栏比对折大小写：Windows 上大小写不同仍是同一个文件', () async {
      // 这正是 normalizeVideoPath 当判据时漏掉的那一格：它不折大小写，
      // `D:\a\b.mkv` 与 `d:\a\b.mkv` 被判成两个文件，护栏漏命中就删掉了用户
      // 还在用的那一份。
      final File a = File(p.join(tmp.path, 'Case.mkv'))..writeAsStringSync('a');
      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path],
        stillReferenced: <String>{platformPathKey(_swapCase(a.path))},
      );
      if (Platform.isWindows) {
        expect(report.removed, isEmpty, reason: 'Windows 上大小写不同 = 同一个文件');
        expect(a.existsSync(), isTrue);
      } else {
        expect(
          report.removedSet,
          <String>{a.path},
          reason: 'Linux/Android 大小写敏感，那真是另一个文件，不该被护栏挡住',
        );
        expect(a.existsSync(), isFalse);
      }
    });

  });
}
