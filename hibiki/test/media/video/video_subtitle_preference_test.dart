import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';

void main() {
  group('pickSameNameSubs（外挂字幕只列当前集同名前缀）', () {
    const String base = "Miss Kobayashi's Dragon Maid - S01E01";

    test('龙女仆 S01E01 在一堆 S01E0x.ja.srt 中只挑 S01E01.ja.srt', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
        "Miss Kobayashi's Dragon Maid - S01E03.ja.srt",
        'random.srt',
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        <String>['$base.ja.srt'],
      );
    });

    test('同集多语言后缀都列出（.ja.srt + .en.srt）', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.en.srt',
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        containsAll(<String>['$base.ja.srt', '$base.en.srt']),
      );
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), hasLength(2));
    });

    test('学习语言标记字幕排在前（学日语 → .ja.srt 排 .en.srt 之前）', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.en.srt',
        '$base.srt',
        '$base.ja.srt',
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        <String>['$base.ja.srt', '$base.en.srt', '$base.srt'],
      );
    });

    test('学韩语 → .ko.srt 排前，无 ko 则按原序', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.ko.srt',
        '$base.srt',
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ko'),
        <String>['$base.ko.srt', '$base.ja.srt', '$base.srt'],
      );
    });

    test('无后缀的精确同名字幕也列出（base.srt）', () {
      final List<String> dirFiles = <String>['$base.mkv', '$base.srt'];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        <String>['$base.srt'],
      );
    });

    test('大小写不敏感匹配，返回原始文件名', () {
      final List<String> dirFiles = <String>['$base.JA.SRT'];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        <String>['$base.JA.SRT'],
      );
    });

    test('只收 srt/ass/ssa/vtt 扩展名，前缀同名但非字幕的文件不列', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.nfo',
        '$base.ja.srt',
        '$base.txt',
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        <String>['$base.ja.srt'],
      );
    });

    test('前缀不同名（别集）一律不列', () {
      final List<String> dirFiles = <String>[
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
        'S01E01.ja.srt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), isEmpty);
    });
  });

  group('pickEpisodeSubtitleSource（换集按同类偏好选新集字幕源）', () {
    // 上一集选了内嵌 streamIndex 1 → 新集也优先内嵌 1。
    test('上次选内嵌 N，新集有内嵌 N → 用内嵌 N', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.embedded(streamIndex: 0, label: 'e0'),
        SubtitleSource.embedded(streamIndex: 1, label: 'e1'),
        SubtitleSource.external(externalPath: '/x/ep.ja.srt', label: 'ja'),
      ];
      final SubtitleSource? picked =
          pickEpisodeSubtitleSource('embedded:1', sources);
      expect(picked, isNotNull);
      expect(picked!.isEmbedded, isTrue);
      expect(picked.streamIndex, 1);
    });

    test('上次选内嵌 N，新集无内嵌 N → 回退第一个内嵌轨', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.embedded(streamIndex: 0, label: 'e0'),
        SubtitleSource.external(externalPath: '/x/ep.ja.srt', label: 'ja'),
      ];
      final SubtitleSource? picked =
          pickEpisodeSubtitleSource('embedded:3', sources);
      expect(picked, isNotNull);
      expect(picked!.isEmbedded, isTrue);
      expect(picked.streamIndex, 0);
    });

    // 上一集选了外挂 .ja.srt → 新集优先同后缀 .ja.srt。
    test('上次选外挂 .ja.srt，新集优先同语言后缀 .ja.srt', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.external(
            externalPath: '/x/S01E02.en.srt', label: 'S01E02.en.srt'),
        SubtitleSource.external(
            externalPath: '/x/S01E02.ja.srt', label: 'S01E02.ja.srt'),
        SubtitleSource.embedded(streamIndex: 0, label: 'e0'),
      ];
      final SubtitleSource? picked =
          pickEpisodeSubtitleSource('/x/S01E01.ja.srt', sources);
      expect(picked, isNotNull);
      expect(picked!.isEmbedded, isFalse);
      expect(picked.externalPath, '/x/S01E02.ja.srt');
    });

    test('上次选外挂 .ass，新集优先同扩展名 .ass', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.external(
            externalPath: '/x/S01E02.srt', label: 'S01E02.srt'),
        SubtitleSource.external(
            externalPath: '/x/S01E02.ass', label: 'S01E02.ass'),
      ];
      final SubtitleSource? picked =
          pickEpisodeSubtitleSource('/x/S01E01.ass', sources);
      expect(picked, isNotNull);
      expect(picked!.externalPath, '/x/S01E02.ass');
    });

    test('上次选外挂但新集无同后缀外挂 → 回退第一个外挂', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.external(
            externalPath: '/x/S01E02.en.srt', label: 'S01E02.en.srt'),
        SubtitleSource.embedded(streamIndex: 0, label: 'e0'),
      ];
      final SubtitleSource? picked =
          pickEpisodeSubtitleSource('/x/S01E01.ja.srt', sources);
      expect(picked, isNotNull);
      expect(picked!.isEmbedded, isFalse);
      expect(picked.externalPath, '/x/S01E02.en.srt');
    });

    test('无持久化偏好（null）→ 返回 null（调用方走默认 sidecar 检测）', () {
      const List<SubtitleSource> sources = <SubtitleSource>[
        SubtitleSource.embedded(streamIndex: 0, label: 'e0'),
      ];
      expect(pickEpisodeSubtitleSource(null, sources), isNull);
    });

    test('空源列表 → null', () {
      expect(
        pickEpisodeSubtitleSource('embedded:0', const <SubtitleSource>[]),
        isNull,
      );
    });
  });
}
