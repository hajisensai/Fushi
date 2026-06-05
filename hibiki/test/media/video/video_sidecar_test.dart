import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';

void main() {
  group('pickSidecar（按 app 学习语言优先）', () {
    const String base = "Miss Kobayashi's Dragon Maid - S01E01";

    test('学日语：.ja.srt 优先于其它语言/无语言标记', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.en.srt',
        '$base.ja.ass',
        '$base.ja.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.srt');
    });

    test('学日语无 .ja.srt：退到 .ja.ass', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.ass',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.ass');
    });

    test('学韩语但无 ko 标记：回退无语言标记的 .srt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.en.srt',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ko'), '$base.srt');
    });

    test('学韩语命中 .ko.srt 优先', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.ko.srt',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ko'), '$base.ko.srt');
    });

    test('学英语：.en.srt 优先于 .ja.srt 与无语言标记', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ja.srt',
        '$base.en.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'en'), '$base.en.srt');
    });

    test('无语言标记字幕全格式优先级：srt > ass > ssa > vtt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.vtt',
        '$base.ssa',
        '$base.ass',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.srt');
    });

    test('语言标记字幕全格式优先级：.ja.srt > .ja.ass > .ja.ssa > .ja.vtt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.vtt',
        '$base.ja.ssa',
        '$base.ja.ass',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.ass');
    });

    test('语言标记字幕整体优先于无语言标记（.ja.vtt 胜过 .srt）', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ja.vtt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.vtt');
    });

    test('无任何同名字幕返回 null', () {
      final List<String> files = <String>['$base.mkv', 'other.srt'];
      expect(pickSidecar(base, files, langCode: 'ja'), isNull);
    });

    test('大小写不敏感匹配，返回原始文件名', () {
      final List<String> files = <String>['$base.JA.SRT'];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.JA.SRT');
    });
  });
}
