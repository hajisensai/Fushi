import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/creator/enhancements/local_audio_enhancement.dart';

/// BUG-1005：制卡器单词音频物化 helper 守卫。制卡自动填充在本地库落空后走全源
/// [resolveLookupAudioUrl]（含远程发音源），再由 [materializeWordAudioRef] 把解析出的
/// ref（远端 URL / 本地路径）落成本地文件供 Anki。这里覆盖 helper 的下载/回退/扩展名推断。
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('word_audio_mat');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('wordAudioExtFor', () {
    test('优先取 URL 路径已知音频后缀', () {
      expect(wordAudioExtFor(Uri.parse('https://a/x.mp3'), null), 'mp3');
      expect(wordAudioExtFor(Uri.parse('https://a/x.opus'), null), 'opus');
      expect(wordAudioExtFor(Uri.parse('https://a/x.m4a?y=1'), null), 'm4a');
    });
    test('URL 无后缀时按 Content-Type', () {
      expect(wordAudioExtFor(Uri.parse('https://a/get?term=x'), 'audio/ogg'),
          'ogg');
      expect(wordAudioExtFor(Uri.parse('https://a/get'), 'audio/mpeg'), 'mp3');
    });
    test('都不认时回退 mp3', () {
      expect(wordAudioExtFor(Uri.parse('https://a/get'), null), 'mp3');
      expect(
          wordAudioExtFor(Uri.parse('https://a/x.txt'), 'text/plain'), 'mp3');
    });
  });

  group('materializeWordAudioRef', () {
    test('远端 http 200 → 下载写盘并按后缀命名', () async {
      final http.Client client = MockClient((http.Request req) async {
        expect(req.url.toString(), 'https://forvo.example/word.mp3');
        return http.Response.bytes(<int>[1, 2, 3, 4], 200);
      });
      final File? f = await materializeWordAudioRef(
          'https://forvo.example/word.mp3',
          dir: dir,
          client: client);
      expect(f, isNotNull);
      expect(f!.path, endsWith('.mp3'));
      expect(await f.readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('远端非 2xx（404「本源没有此词」）→ null，不落半成品', () async {
      final http.Client client =
          MockClient((http.Request req) async => http.Response('no', 404));
      final File? f = await materializeWordAudioRef(
          'https://forvo.example/word.mp3',
          dir: dir,
          client: client);
      expect(f, isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('远端空体 → null', () async {
      final http.Client client = MockClient(
          (http.Request req) async => http.Response.bytes(<int>[], 200));
      final File? f = await materializeWordAudioRef('https://a/x.mp3',
          dir: dir, client: client);
      expect(f, isNull);
    });

    test('本地路径存在 → 直接包 File；不存在 → null', () async {
      final File local = File('${dir.path}/local.mp3')
        ..writeAsBytesSync(<int>[9, 9]);
      final File? hit = await materializeWordAudioRef(local.path, dir: dir);
      expect(hit?.path, local.path);
      final File? miss =
          await materializeWordAudioRef('${dir.path}/nope.mp3', dir: dir);
      expect(miss, isNull);
    });

    test('file:// ref → 解析成本地路径', () async {
      final File local = File('${dir.path}/f.mp3')..writeAsBytesSync(<int>[1]);
      final String fileUri = Uri.file(local.path).toString();
      final File? hit = await materializeWordAudioRef(fileUri, dir: dir);
      expect(hit, isNotNull);
      expect(hit!.readAsBytesSync(), <int>[1]);
    });

    test('空 ref → null', () async {
      expect(await materializeWordAudioRef('', dir: dir), isNull);
    });
  });
}
