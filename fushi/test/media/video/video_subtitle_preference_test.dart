import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';

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
  group('isImportedExternalSubtitlePath（真实下载文件名，用户报「退出再进字幕没了」）', () {
    // 用户实测截图里的 Jimaku 候选文件名：带括号、CRC、双语后缀。恢复捷径靠这个判据
    // 决定「要不要按路径直接加载」——它一旦认不出，重进就会掉回「只扫视频同目录」的
    // 分支，而下载的字幕根本不住在那儿，字幕就此消失。
    test('括号 / CRC / 双语后缀都不影响识别', () {
      for (final String name in <String>[
        '(Hi10)_Re_Zero_-_01_(BD_720p)_(BlurayDesuYo)_(DB3C1337).ja-en.ass',
        '[Kamigami] Re Zero kara Hajimeru Isekai Seikatsu - 01v3 '
            '[1920x1080 x265 Ma10p AAC][JPN].ass',
        'Re_ゼロから始める異世界生活.新編集版.S01E01.WEBRip.Netflix.ja[cc].srt',
        'Re Life in a different world from zero.S01E01.WEBRip.ja[cc].srt',
      ]) {
        expect(
          isImportedExternalSubtitlePath(
            '/home/u/Documents/app/video_subtitles/$name',
          ),
          isTrue,
          reason: '认不出就等于重进后字幕消失：$name',
        );
      }
    });

    test('内嵌源与非字幕扩展名仍然不认', () {
      expect(isImportedExternalSubtitlePath('embedded:2'), isFalse);
      expect(isImportedExternalSubtitlePath(''), isFalse);
      expect(
        isImportedExternalSubtitlePath('/x/video_subtitles/subs.zip'),
        isFalse,
      );
    });

    test('这些文件名跨集也认得住在别处（不被当成同目录 sidecar）', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '/home/u/Documents/app/video_subtitles/'
              '(Hi10)_Re_Zero_-_01_(BD_720p).ja-en.ass',
          '/media/Anime/Re Zero/S04E02.mkv',
        ),
        isTrue,
      );
    });
  });

  group('shouldReusePersistedSubtitleAcrossEpisode（换集是否沿用导入字幕）', () {
    // 真正的导入/下载字幕：住在 <appDocs>/video_subtitles/，与剧集目录无关 → 沿用。
    test('导入字幕（异目录）→ true（跨集沿用）', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '/home/u/Documents/app/video_subtitles/My Show E01.ja.srt',
          '/media/Anime/My Show/S01E02.mkv',
        ),
        isTrue,
      );
    });

    // BUG-165 核心：剧集自带 sidecar 与新集视频同目录 → 不沿用，按新集名重新匹配。
    test('剧集同目录 sidecar（与新集视频同目录）→ false', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '/media/Anime/My Show/S01E01.ja.srt',
          '/media/Anime/My Show/S01E02.mkv',
        ),
        isFalse,
      );
    });

    test('同目录判定对路径分隔符/末尾不规范不敏感（canonicalize）', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '/media/Anime/My Show/./S01E01.ja.srt',
          '/media/Anime/My Show/sub/../S01E02.mkv',
        ),
        isFalse,
      );
    });

    test('内嵌源（embedded:<n>）→ false（捷径不接管内嵌）', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          'embedded:1',
          '/media/Anime/My Show/S01E02.mkv',
        ),
        isFalse,
      );
    });

    test('空持久化值 → false', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '',
          '/media/Anime/My Show/S01E02.mkv',
        ),
        isFalse,
      );
    });

    test('非字幕扩展名 → false', () {
      expect(
        shouldReusePersistedSubtitleAcrossEpisode(
          '/media/Anime/My Show/S01E01.txt',
          '/media/Anime/My Show/S01E02.mkv',
        ),
        isFalse,
      );
    });
  });
}
