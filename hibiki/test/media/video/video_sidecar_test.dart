import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';

void main() {
  group('pickSidecar', () {
    const String base = "Miss Kobayashi's Dragon Maid - S01E01";

    test('.ja.srt 优先于其它（龙女仆日文字幕）', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ja.ass',
        '$base.ja.srt',
        '$base.en.srt',
      ];
      expect(pickSidecar(base, files), '$base.ja.srt');
    });

    test('无 .ja.srt 时退到 .ja.ass（Season 00 部分集）', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.ass',
        '$base.srt',
      ];
      expect(pickSidecar(base, files), '$base.ja.ass');
    });

    test('无日文外挂时退到 .srt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ass'
      ];
      expect(pickSidecar(base, files), '$base.srt');
    });

    test('退到 .ass', () {
      final List<String> files = <String>['$base.mkv', '$base.ass'];
      expect(pickSidecar(base, files), '$base.ass');
    });

    test('无任何字幕返回 null', () {
      final List<String> files = <String>['$base.mkv', 'other.srt'];
      expect(pickSidecar(base, files), isNull);
    });

    test('大小写不敏感匹配，返回原始文件名', () {
      final List<String> files = <String>['$base.JA.SRT'];
      expect(pickSidecar(base, files), '$base.JA.SRT');
    });
  });
}
