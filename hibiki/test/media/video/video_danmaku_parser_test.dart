import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Bilibili XML danmaku parser', () {
    test('parses text, timing, mode and color from <d p="..."> rows', () {
      const String xml = '''
<i>
  <d p="1.25,1,25,16777215,0,0,abc,1">こんにちは &amp; テスト</d>
  <d p="2.5,5,25,16711680,0,0,abc,2">上固定</d>
</i>
''';

      final List<VideoDanmakuItem> items = parseBilibiliDanmakuXml(xml);

      expect(items, hasLength(2));
      expect(items.first.startMs, 1250);
      expect(items.first.mode, VideoDanmakuMode.scroll);
      expect(items.first.colorArgb, 0xFFFFFFFF);
      expect(items.first.text, 'こんにちは & テスト');
      expect(items.last.startMs, 2500);
      expect(items.last.mode, VideoDanmakuMode.top);
      expect(items.last.colorArgb, 0xFFFF0000);
    });

    test('skips malformed rows and unsupported positioned comments', () {
      const String xml = '''
<i>
  <d>missing p</d>
  <d p="bad,1,25,16777215">bad time</d>
  <d p="3,7,25,16777215">advanced positioned comment</d>
  <d p="4,4,25,255">bottom</d>
</i>
''';

      final List<VideoDanmakuItem> items = parseBilibiliDanmakuXml(xml);

      expect(items.map((VideoDanmakuItem item) => item.text), <String>[
        'bottom',
      ]);
      expect(items.single.mode, VideoDanmakuMode.bottom);
      expect(items.single.colorArgb, 0xFF0000FF);
    });
  });

  group('Dandanplay JSON danmaku parser', () {
    test('parses Dandanplay comments[] p/m rows', () {
      const String json = '''
{
  "comments": [
    {"p": "1.5,1,16777215,0", "m": "流れる"},
    {"p": "2.25,5,16711935,0", "m": "上"},
    {"p": "bad", "m": "bad"}
  ]
}
''';

      final List<VideoDanmakuItem> items = parseDandanplayDanmakuJson(json);

      expect(items, hasLength(2));
      expect(items.first.startMs, 1500);
      expect(items.first.mode, VideoDanmakuMode.scroll);
      expect(items.last.startMs, 2250);
      expect(items.last.mode, VideoDanmakuMode.top);
      expect(items.last.colorArgb, 0xFFFF00FF);
    });

    test('accepts tolerant object rows and skips bad data', () {
      const String json = '''
{
  "comments": [
    {"time": 3.25, "mode": 4, "color": 255, "text": "底"},
    {"time": "4.5", "type": "scroll", "text": "文字列時間"},
    {"time": null, "text": "bad"},
    {"time": 6, "mode": 7, "text": "positioned"}
  ]
}
''';

      final List<VideoDanmakuItem> items = parseDandanplayDanmakuJson(json);

      expect(items.map((VideoDanmakuItem item) => item.text), <String>[
        '底',
        '文字列時間',
      ]);
      expect(items.first.mode, VideoDanmakuMode.bottom);
      expect(items.last.mode, VideoDanmakuMode.scroll);
    });
  });

  group('danmaku sidecar detection and file limits', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_danmaku_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('pickDanmakuSidecar prefers explicit danmaku XML over plain JSON', () {
      const String base = 'Episode 01';
      final List<String> files = <String>[
        '$base.mkv',
        '$base.json',
        '$base.danmaku.xml',
        '$base.en.srt',
      ];

      expect(pickDanmakuSidecar(base, files), '$base.danmaku.xml');
    });

    test('findDanmakuSidecar returns an absolute same-name sidecar path', () {
      final File video = File(p.join(tempDir.path, 'Episode 01.mkv'))
        ..writeAsStringSync('video');
      final File danmaku =
          File(p.join(tempDir.path, 'Episode 01.dandanplay.json'))
            ..writeAsStringSync('{"comments": []}');
      File(p.join(tempDir.path, 'Other.danmaku.xml')).writeAsStringSync('<i/>');

      expect(findDanmakuSidecar(video.path), p.normalize(danmaku.path));
    });

    test('loadDanmakuSidecarFile refuses files above maxBytes', () async {
      final File file = File(p.join(tempDir.path, 'Episode 01.xml'))
        ..writeAsStringSync('<i>${'x' * 64}</i>');

      final VideoDanmakuLoadResult result =
          await loadDanmakuSidecarFile(file, maxBytes: 8);

      expect(result.tooLarge, isTrue);
      expect(result.items, isEmpty);
      expect(result.sourcePath, file.path);
    });
  });
}
