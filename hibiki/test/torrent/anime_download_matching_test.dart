import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/torrent/anime_download_matching.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

/// 直接 new 一个只有标题有意义的种子（episode/episodeRange 均从标题解析）。
NyaaTorrent _torrent(String title) {
  return NyaaTorrent(
    title: title,
    torrentUrl: '',
    pageUrl: '',
    infoHash: 'abcdef0123456789abcdef0123456789abcdef01',
    seeders: 10,
    leechers: 1,
    downloads: 100,
    sizeText: '1.4 GiB',
    sizeBytes: null,
    categoryId: '1_0',
    trusted: false,
    remake: false,
    pubDate: null,
  );
}

JimakuFile _file(String name) =>
    JimakuFile(name: name, url: 'https://jimaku.cc/f/$name');

void main() {
  group('JimakuEpisodeIndex.fromFiles', () {
    test('只收文本字幕，按集分组，认不出集号的进 unnumbered', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Frieren - 01.ja.srt'),
          _file('Frieren - 02.ja.ass'),
          _file('Frieren Movie.ja.srt'), // 无集号 → unnumbered
          _file('fonts.zip'), // 非文本字幕 → 丢弃
        ],
      );
      expect(index.byEpisode.keys, unorderedEquals(<int>[1, 2]));
      expect(index.byEpisode[1]!.single.name, 'Frieren - 01.ja.srt');
      expect(index.unnumbered.single.name, 'Frieren Movie.ja.srt');
      expect(index.totalFiles, 3);
      expect(index.isEmpty, isFalse);
    });

    test('每集候选按语言权重升序：ja 优先于 en，未知语言最后', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Frieren - 01.en.srt'),
          _file('Frieren - 01.srt'), // 语言未知 → 最后
          _file('Frieren - 01.ja.srt'),
        ],
      );
      expect(
        index.byEpisode[1]!.map((JimakuFile f) => f.name).toList(),
        <String>[
          'Frieren - 01.ja.srt',
          'Frieren - 01.en.srt',
          'Frieren - 01.srt',
        ],
      );
    });

    test('用户选择的语言优先于默认 ja 顺序', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Frieren - 01.ja.srt'),
          _file('Frieren - 01.zh.srt'),
        ],
        preferredLanguage: 'zh',
      );
      expect(
        index.byEpisode[1]!.map((JimakuFile f) => f.name).toList(),
        <String>[
          'Frieren - 01.zh.srt',
          'Frieren - 01.ja.srt',
        ],
      );
    });

    test('空输入 → 空索引', () {
      final JimakuEpisodeIndex index =
          JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      expect(index.isEmpty, isTrue);
      expect(index.totalFiles, 0);
      expect(index.byEpisode, isEmpty);
      expect(index.unnumbered, isEmpty);
    });
  });

  group('jimakuCoverageFor', () {
    final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
      <JimakuFile>[
        _file('Show - 01.ja.srt'),
        _file('Show - 03.ja.srt'),
      ],
    );

    test('单集种子：该集有候选 → 1/1', () {
      final NyaaTorrent t = _torrent('[Grp] Show - 03 (1080p)');
      expect(t.episode, 3);
      expect(t.episodeRange, isNull);
      final ({int covered, int? total}) c = jimakuCoverageFor(t, index);
      expect(c.covered, 1);
      expect(c.total, 1);
    });

    test('单集种子：该集无候选 → 0/1', () {
      final ({int covered, int? total}) c =
          jimakuCoverageFor(_torrent('[Grp] Show - 02 (1080p)'), index);
      expect(c.covered, 0);
      expect(c.total, 1);
    });

    test('batch 种子：total=区间长度，covered=区间内有候选的集数', () {
      final NyaaTorrent t = _torrent('[Grp] Show 01-04 (1080p) [Batch]');
      expect(t.episodeRange, (1, 4));
      final ({int covered, int? total}) c = jimakuCoverageFor(t, index);
      expect(c.covered, 2); // 01 与 03
      expect(c.total, 4);
    });

    test('区间种子按 batch 处理；引擎不再把区间末位误读成单集号', () {
      final NyaaTorrent t = _torrent('Show 01-04');
      // G10 第二步前的旧引擎会把 `01-04` 的末位 04 误解析成单集号（当时靠
      // 「区间优先」掩盖）；统一到刮削引擎后 `\s- N` 需要空格边界，区间就是区间。
      expect(t.episode, isNull);
      expect(t.episodeRange, (1, 4));
      final ({int covered, int? total}) c = jimakuCoverageFor(t, index);
      expect(c.total, 4);
      expect(c.covered, 2);
    });

    test('无集数种子：索引有文件 → covered 1，total null', () {
      final NyaaTorrent t = _torrent('[Grp] Great Movie Film');
      expect(t.episode, isNull);
      expect(t.episodeRange, isNull);
      final ({int covered, int? total}) c = jimakuCoverageFor(t, index);
      expect(c.covered, 1);
      expect(c.total, isNull);
    });

    test('无集数种子：空索引 → covered 0，total null', () {
      final ({int covered, int? total}) c = jimakuCoverageFor(
        _torrent('[Grp] Great Movie Film'),
        JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]),
      );
      expect(c.covered, 0);
      expect(c.total, isNull);
    });
  });

  group('chooseSubtitlesFor', () {
    test('单集：取该集首选 1 条并记录集号', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Show - 05.en.srt'),
          _file('Show - 05.ja.srt'),
        ],
      );
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(_torrent('[Grp] Show - 05 (1080p)'), index);
      expect(chosen, hasLength(1));
      expect(chosen.single.$1, 5);
      expect(chosen.single.$2.name, 'Show - 05.ja.srt'); // ja 优先
    });

    test('单集：该集无候选 → 空', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[_file('Show - 01.ja.srt')],
      );
      expect(
        chooseSubtitlesFor(_torrent('[Grp] Show - 05 (1080p)'), index),
        isEmpty,
      );
    });

    test('batch：区间内每集首选各 1 条，缺集跳过', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Show - 01.en.srt'),
          _file('Show - 01.ja.srt'),
          _file('Show - 03.ja.srt'),
        ],
      );
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(_torrent('[Grp] Show 01-03 (1080p)'), index);
      expect(
        chosen.map(((int?, JimakuFile) e) => (e.$1, e.$2.name)).toList(),
        <(int?, String)>[
          (1, 'Show - 01.ja.srt'),
          (3, 'Show - 03.ja.srt'),
        ],
      );
    });

    test('无集数：有 unnumbered → 给其首选，episode null', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Show - 01.ja.srt'),
          _file('Great Movie.en.srt'),
          _file('Great Movie.ja.srt'),
        ],
      );
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(_torrent('[Grp] Great Movie Film'), index);
      expect(chosen, hasLength(1));
      expect(chosen.single.$1, isNull);
      expect(chosen.single.$2.name, 'Great Movie.ja.srt');
    });

    test('无集数：无 unnumbered 但全部文件只有 1 条 → 给它，episode null', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[_file('Show - 01.ja.srt')],
      );
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(_torrent('[Grp] Great Movie Film'), index);
      expect(chosen, hasLength(1));
      expect(chosen.single.$1, isNull);
      expect(chosen.single.$2.name, 'Show - 01.ja.srt');
    });

    test('无集数：无 unnumbered 且多条带集号文件 → 不猜，返回空', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[
          _file('Show - 01.ja.srt'),
          _file('Show - 02.ja.srt'),
        ],
      );
      expect(
        chooseSubtitlesFor(_torrent('[Grp] Great Movie Film'), index),
        isEmpty,
      );
    });
  });
}
