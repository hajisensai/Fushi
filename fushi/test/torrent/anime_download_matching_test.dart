import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/anime_download_matching.dart';
import 'package:fushi/src/media/video/jimaku_matching.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';

// 旧番剧下载计划的字幕落位层。按种子标题预估覆盖度 / 预选字幕 / 自动选条目的
// 那一层随旧「番剧下载」对话框删除（BT 搜索改走 VideoResourceRegistry）。

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
        <String>['Frieren - 01.zh.srt', 'Frieren - 01.ja.srt'],
      );
    });

    test('空输入 → 空索引', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        const <JimakuFile>[],
      );
      expect(index.isEmpty, isTrue);
      expect(index.totalFiles, 0);
      expect(index.byEpisode, isEmpty);
      expect(index.unnumbered, isEmpty);
    });
  });

  group('BUG-1206 matchJimakuFilesToVideoNames', () {
    List<JimakuFile> jimakuEpisodes(
      Iterable<int> episodes, {
      String series = 'Test Anime',
      String lang = 'ja',
    }) {
      return <JimakuFile>[
        for (final int ep in episodes)
          JimakuFile(
            name: '$series - ${ep.toString().padLeft(2, '0')}.$lang.srt',
            url: 'https://jimaku.cc/f/$ep.srt',
          ),
      ];
    }

    List<String> packVideos(
      Iterable<int> episodes, {
      String group = 'Grp',
      String series = 'Test Anime',
    }) {
      return <String>[
        for (final int ep in episodes)
          '[$group] $series - ${ep.toString().padLeft(2, '0')} [1080p].mkv',
      ];
    }

    test('错季不再配上：S2 包 01-12 遇绝对编号条目 13-24 → 一条都不配', () {
      // 这正是改前静默配错的形状：旧的 season 分支按「取最前 cap 个」交出
      // 13-24 的字幕并画成「有字幕」。按真实文件名反查后集号集合交集为空。
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        packVideos(<int>[for (int e = 1; e <= 12; e++) e]),
        jimakuEpisodes(<int>[for (int e = 13; e <= 24; e++) e]),
      );
      expect(matches, isEmpty, reason: '集号对不上就必须不配，绝不能猜偏移或凑条数');
    });

    test('条数被真实文件数收敛：条目 24 集、包只 12 集 → 恰好 12 条且集号是包里的', () {
      // 改前这里会下满 24 条（标题没写「全N話」且 AniList 没给 episodes 时
      // 压根不设上界），多出来的 12 条永远配不上任何视频。
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        packVideos(<int>[for (int e = 1; e <= 12; e++) e]),
        jimakuEpisodes(<int>[for (int e = 1; e <= 24; e++) e]),
      );
      expect(matches, hasLength(12));
      expect(
        matches.map((ResolvedSubtitleMatch m) => m.episode).toList(),
        <int>[for (int e = 1; e <= 12; e++) e],
      );
      expect(
        matches.map((ResolvedSubtitleMatch m) => m.file.name).toList(),
        <String>[
          for (int e = 1; e <= 12; e++)
            'Test Anime - ${e.toString().padLeft(2, '0')}.ja.srt',
        ],
        reason: '取的必须是包里那 12 集，不是条目的前 12 条',
      );
    });

    test('部分覆盖：包 01-12、条目只有 03/05/07 → 只配这 3 集，其余跳过', () {
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        packVideos(<int>[for (int e = 1; e <= 12; e++) e]),
        jimakuEpisodes(<int>[3, 5, 7]),
      );
      expect(
        matches.map((ResolvedSubtitleMatch m) => m.episode).toList(),
        <int>[3, 5, 7],
      );
      expect(matches.first.videoFileName, '[Grp] Test Anime - 03 [1080p].mkv');
    });

    test('真实文件名三种写法（- 05 / S02E05 / 第5話）都能反查到同一集', () {
      final List<JimakuFile> subs = jimakuEpisodes(<int>[5]);
      for (final String video in <String>[
        '[Grp] Test Anime - 05 [1080p].mkv',
        'Test.Anime.S02E05.1080p.mkv',
        'テストアニメ 第5話.mkv',
      ]) {
        final List<ResolvedSubtitleMatch> matches =
            matchJimakuFilesToVideoNames(<String>[video], subs);
        expect(matches, hasLength(1), reason: '解析不出集号的写法：$video');
        expect(matches.single.episode, 5);
      }
    });

    test('传绝对路径也按 basename 反查（服务侧喂的是绝对路径）', () {
      // 用 POSIX 分隔符：`package:path` 的 windows context 也认 `/`，而反过来
      // 硬编码 `D:\...` 在 Linux CI 上根本不会被拆分 → 本机绿、CI 红。
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        <String>['/downloads/Test Anime/[Grp] Test Anime - 07 [1080p].mkv'],
        jimakuEpisodes(<int>[7]),
      );
      expect(matches.single.episode, 7);
      expect(matches.single.videoFileName, '[Grp] Test Anime - 07 [1080p].mkv');
    });

    test('同集多语言按偏好取首选（未指定时 ja 优先）', () {
      final List<JimakuFile> mixed = <JimakuFile>[
        const JimakuFile(
          name: 'Test Anime - 05.zh.srt',
          url: 'https://jimaku.cc/f/5zh.srt',
        ),
        const JimakuFile(
          name: 'Test Anime - 05.ja.srt',
          url: 'https://jimaku.cc/f/5ja.srt',
        ),
      ];
      expect(
        matchJimakuFilesToVideoNames(
          packVideos(<int>[5]),
          mixed,
        ).single.file.name,
        'Test Anime - 05.ja.srt',
      );
      expect(
        matchJimakuFilesToVideoNames(
          packVideos(<int>[5]),
          mixed,
          preferredLanguage: 'zh',
        ).single.file.name,
        'Test Anime - 05.zh.srt',
      );
    });

    test('1v1 兜底：单视频无集号 + 条目唯一整片字幕 → 配上（episode 记 null）', () {
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        <String>['Test Anime Movie [BDRip].mkv'],
        const <JimakuFile>[
          JimakuFile(name: 'Movie.ja.srt', url: 'https://jimaku.cc/f/m.srt'),
        ],
      );
      expect(matches, hasLength(1));
      expect(matches.single.episode, isNull);
    });

    test('1v1 不猜：单视频 ep05 + 条目唯一字幕 ep17 → 不配', () {
      expect(
        matchJimakuFilesToVideoNames(
          packVideos(<int>[5]),
          jimakuEpisodes(<int>[17]),
        ),
        isEmpty,
        reason: '双方都有集号却不等 = 错季/错编号的典型形状，宁可不配',
      );
    });

    test('多视频全部对不上时不做 1v1 兜底（多文件绝不猜）', () {
      expect(
        matchJimakuFilesToVideoNames(
          packVideos(<int>[1, 2, 3]),
          const <JimakuFile>[
            JimakuFile(name: 'Whole Season.ja.srt', url: 'https://x/1.srt'),
          ],
        ),
        isEmpty,
      );
    });

    test('非文本字幕（.zip/.mkv）被 JimakuEpisodeIndex 丢弃，不会被反查选中', () {
      expect(
        matchJimakuFilesToVideoNames(packVideos(<int>[1]), const <JimakuFile>[
          JimakuFile(name: 'Test Anime - 01.zip', url: 'https://x/1.zip'),
        ]),
        isEmpty,
      );
    });

    test('空输入不炸', () {
      expect(
        matchJimakuFilesToVideoNames(const <String>[], const <JimakuFile>[]),
        isEmpty,
      );
      expect(
        matchJimakuFilesToVideoNames(
          packVideos(<int>[1]),
          const <JimakuFile>[],
        ),
        isEmpty,
      );
    });
  });
}
