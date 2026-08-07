import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/anime_download_matching.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';

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

    test('无集数种子：索引里只有带集号文件且多于 1 条 → covered 0（给不出就别说有）', () {
      final NyaaTorrent t = _torrent('[Grp] Great Movie Film');
      expect(t.episode, isNull);
      expect(t.episodeRange, isNull);
      final ({int covered, int? total}) c = jimakuCoverageFor(t, index);
      // 旧行为记 1，但 chooseSubtitlesFor 一条也给不出（BUG-1189 的同款不一致）。
      expect(c.covered, 0);
      expect(c.total, isNull);
      expect(chooseSubtitlesFor(t, index), isEmpty);
    });

    test('无集数种子：索引有整季单文件字幕 → covered 1，total null', () {
      final NyaaTorrent t = _torrent('[Grp] Great Movie Film');
      final JimakuEpisodeIndex movieIndex = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[_file('Great Movie.ja.srt')],
      );
      final ({int covered, int? total}) c = jimakuCoverageFor(t, movieIndex);
      expect(c.covered, 1);
      expect(c.total, isNull);
      expect(chooseSubtitlesFor(t, movieIndex), hasLength(1));
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

  group('torrentEpisodeScope', () {
    test('集号区间 → range（区间优先于末位被误读的单集号）', () {
      final TorrentEpisodeScope scope =
          torrentEpisodeScope(_torrent('[Grp] Show 01-13 (1080p)'));
      expect(scope.kind, TorrentEpisodeScopeKind.range);
      expect(scope.range, (1, 13));
    });

    test('单集 → single', () {
      final TorrentEpisodeScope scope =
          torrentEpisodeScope(_torrent('[Grp] Show - 05 (1080p)'));
      expect(scope.kind, TorrentEpisodeScopeKind.single);
      expect(scope.episode, 5);
    });

    test('季号但无集号（整季 BD 包）→ season（BUG-1189 的真实标题）', () {
      final NyaaTorrent t = _torrent(
        '[7³ACG] Watashi wo Tabetai, Hitodenashi 私を喰べたい、ひとでなし '
        'S1 [BDRip 1080p x265 OPUS]',
      );
      // 前提复核：这类标题既解不出集号，也没有区间——旧实现据此误判「无集数概念」。
      expect(t.episode, isNull);
      expect(t.episodeRange, isNull);
      expect(t.season, 1);
      expect(torrentEpisodeScope(t).kind, TorrentEpisodeScopeKind.season);
    });

    test('Complete / batch / BD-BOX / 全13話 等整季标记 → season', () {
      for (final String title in <String>[
        '[Grp] Show Complete Series [1080p]',
        '[Grp] Show batch [1080p]',
        '[Grp] Show BD-BOX [1080p]',
        '[Grp] ショー 全13話 [1080p]',
      ]) {
        expect(
          torrentEpisodeScope(_torrent(title)).kind,
          TorrentEpisodeScopeKind.season,
          reason: title,
        );
      }
    });

    test('剧场版 / 单文件（无集号无季号无整季标记）→ unknown', () {
      expect(
        torrentEpisodeScope(_torrent('[Grp] Great Movie Film')).kind,
        TorrentEpisodeScopeKind.unknown,
      );
    });
  });

  group('整季包字幕匹配（BUG-1189）', () {
    /// 取自 Jimaku 条目 10365 的真实文件名（多字幕组 + Netflix `S01E01` 命名）。
    JimakuEpisodeIndex seasonIndex() => JimakuEpisodeIndex.fromFiles(
          <JimakuFile>[
            for (int ep = 1; ep <= 13; ep++) ...<JimakuFile>[
              _file('[Erai-raws] Watashi wo Tabetai Hitodenashi - '
                  '${ep.toString().padLeft(2, '0')} '
                  '[1080p CR WEB-DL AVC AAC][MultiSub].ass'),
              _file('私を喰べたい、ひとでなし.S01E${ep.toString().padLeft(2, '0')}'
                  '.WEBRip.Netflix.ja[cc].srt'),
            ],
          ],
        );

    final NyaaTorrent seasonPack = _torrent(
      '[7³ACG] Watashi wo Tabetai, Hitodenashi 私を喰べたい、ひとでなし '
      'S1 [BDRip 1080p x265 OPUS]',
    );

    test('整季包 → 索引里每集各给 1 条（此前一条都不给）', () {
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(seasonPack, seasonIndex());
      expect(chosen, hasLength(13));
      expect(
        chosen.map(((int?, JimakuFile) e) => e.$1).toList(),
        <int>[for (int ep = 1; ep <= 13; ep++) ep],
        reason: '按集号升序',
      );
      // 每集取语言权重最优的候选：Netflix 那条的 `.ja[cc]` 标签归一成 ja，
      // 优先于无语言标记的 Erai-raws 版。
      expect(chosen.first.$2.name, contains('Netflix'));
    });

    test('整季包但字幕只有整季单文件 → 退回该单文件（episode null）', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[_file('Watashi wo Tabetai Hitodenashi Season 1.ja.srt')],
      );
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(seasonPack, index);
      expect(chosen, hasLength(1));
      expect(chosen.single.$1, isNull);
    });

    test('整季包 + 空索引 → 空（不硬塞）', () {
      expect(
        chooseSubtitlesFor(
          seasonPack,
          JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]),
        ),
        isEmpty,
      );
    });

    test('覆盖度与实际给出的条数一致（徽标不能说有、详情说无）', () {
      final JimakuEpisodeIndex index = seasonIndex();
      final ({int covered, int? total}) coverage =
          jimakuCoverageFor(seasonPack, index);
      expect(coverage.covered, 13);
      expect(coverage.total, isNull, reason: '整季包应有集数未知');
      expect(coverage.covered, chooseSubtitlesFor(seasonPack, index).length);
    });

    test('四类种子的 covered 恒等于 chooseSubtitlesFor 的条数', () {
      final JimakuEpisodeIndex index = seasonIndex();
      for (final NyaaTorrent t in <NyaaTorrent>[
        seasonPack,
        _torrent('[Grp] Show 01-13 (1080p)'),
        _torrent('[Grp] Show - 05 (1080p)'),
        _torrent('[Grp] Great Movie Film'),
      ]) {
        expect(
          jimakuCoverageFor(t, index).covered,
          chooseSubtitlesFor(t, index).length,
          reason: t.title,
        );
      }
    });
  });

  // 条目 24 集、包只有 12 集时，多出来的 12 条永远配不上任何视频（落位层要求
  // 集号严格相等），纯耗带宽和磁盘。按自述上界收敛条数。
  group('整季包字幕条数收敛', () {
    /// 24 集的 Jimaku 条目（两季合并编号的典型形态）。
    JimakuEpisodeIndex index24() => JimakuEpisodeIndex.fromFiles(
          <JimakuFile>[
            for (int ep = 1; ep <= 24; ep++)
              _file('Show - ${ep.toString().padLeft(2, '0')}.ja.srt'),
          ],
        );

    test('标题自报 `全12話` → 只取 12 条（升序取最前 12 集）', () {
      final NyaaTorrent pack = _torrent('[Grp] Show S1 全12話 [BDRip 1080p]');
      expect(torrentEpisodeScope(pack).seasonEpisodeCount, 12);
      final List<(int?, JimakuFile)> chosen =
          chooseSubtitlesFor(pack, index24());
      expect(chosen, hasLength(12));
      expect(
        chosen.map(((int?, JimakuFile) e) => e.$1).toList(),
        <int>[for (int ep = 1; ep <= 12; ep++) ep],
      );
      // 徽标必须跟着收敛，否则「列表说 24、点进去 12」。
      expect(jimakuCoverageFor(pack, index24()).covered, 12);
    });

    test('标题没写集数 → 用调用方给的该季应有集数收敛', () {
      final NyaaTorrent pack = _torrent('[Grp] Show S1 [BDRip 1080p x265]');
      expect(torrentEpisodeScope(pack).seasonEpisodeCount, isNull);
      expect(
        chooseSubtitlesFor(pack, index24(), seriesEpisodeCount: 12),
        hasLength(12),
      );
      expect(
        jimakuCoverageFor(pack, index24(), seriesEpisodeCount: 12).covered,
        12,
      );
    });

    test('标题自报的集数优先于调用方给的应有集数', () {
      final NyaaTorrent pack = _torrent('[Grp] Show S1 全13話 [BDRip]');
      expect(
        chooseSubtitlesFor(pack, index24(), seriesEpisodeCount: 24),
        hasLength(13),
      );
    });

    test('两个上界都没有 → 不收敛（不发明魔数，维持全给）', () {
      final NyaaTorrent pack = _torrent('[Grp] Show S1 [BDRip 1080p x265]');
      expect(seasonSubtitleCap(torrentEpisodeScope(pack)), isNull);
      expect(chooseSubtitlesFor(pack, index24()), hasLength(24));
    });

    test('上界大于索引集数 → 不截断（有多少给多少）', () {
      final NyaaTorrent pack = _torrent('[Grp] Show S1 [BDRip]');
      expect(
        chooseSubtitlesFor(pack, index24(), seriesEpisodeCount: 50),
        hasLength(24),
      );
    });

    test('收敛只作用于 season 类：区间包仍按自己的区间走', () {
      final NyaaTorrent ranged = _torrent('[Grp] Show 01-24 (1080p)');
      expect(
        chooseSubtitlesFor(ranged, index24(), seriesEpisodeCount: 12),
        hasLength(24),
      );
    });
  });

  // ==========================================================================
  // BUG-1206：落位阶段按包内真实视频文件名反查（根治层）
  // ==========================================================================
  group('BUG-1206 matchJimakuFilesToVideoNames', () {
    List<JimakuFile> jimakuEpisodes(Iterable<int> episodes,
        {String series = 'Test Anime', String lang = 'ja'}) {
      return <JimakuFile>[
        for (final int ep in episodes)
          JimakuFile(
            name: '$series - ${ep.toString().padLeft(2, '0')}.$lang.srt',
            url: 'https://jimaku.cc/f/$ep.srt',
          ),
      ];
    }

    List<String> packVideos(Iterable<int> episodes,
        {String group = 'Grp', String series = 'Test Anime'}) {
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
      expect(matches.map((ResolvedSubtitleMatch m) => m.episode).toList(),
          <int>[3, 5, 7]);
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
            name: 'Test Anime - 05.zh.srt', url: 'https://jimaku.cc/f/5zh.srt'),
        const JimakuFile(
            name: 'Test Anime - 05.ja.srt', url: 'https://jimaku.cc/f/5ja.srt'),
      ];
      expect(
        matchJimakuFilesToVideoNames(packVideos(<int>[5]), mixed)
            .single
            .file
            .name,
        'Test Anime - 05.ja.srt',
      );
      expect(
        matchJimakuFilesToVideoNames(packVideos(<int>[5]), mixed,
                preferredLanguage: 'zh')
            .single
            .file
            .name,
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
        matchJimakuFilesToVideoNames(
          packVideos(<int>[1]),
          const <JimakuFile>[
            JimakuFile(name: 'Test Anime - 01.zip', url: 'https://x/1.zip'),
          ],
        ),
        isEmpty,
      );
    });

    test('空输入不炸', () {
      expect(
          matchJimakuFilesToVideoNames(const <String>[], const <JimakuFile>[]),
          isEmpty);
      expect(
          matchJimakuFilesToVideoNames(
              packVideos(<int>[1]), const <JimakuFile>[]),
          isEmpty);
    });
  });

  group('条目自动选中的季号校验（resolveJimakuEntry）', () {
    const JimakuEntry s1 =
        JimakuEntry(id: 11, name: 'Sousou no Frieren'); // 不写季号 = 第一季
    const JimakuEntry s2 =
        JimakuEntry(id: 22, name: 'Sousou no Frieren 2nd Season');

    test('S1 条目遇上 S2 包：不自动选（本轮根因）', () {
      // 这正是落位层（matchJimakuFilesToVideoNames）拦不住的形状：条目按 1-12
      // 编号、包也是 01-12，集号严格相等照样能配上，配的却是错季字幕。
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      expect(pack.season, 2, reason: '前提：种子标题解析得出季号');
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1],
          torrentSeason: pack.season,
          anilistId: 999,
        ),
        isNull,
      );
    });

    test('候选里有对得上的季 → 自动选那一条，而不是首条', () {
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1, s2],
          torrentSeason: pack.season,
          anilistId: 999,
        )?.id,
        22,
      );
    });

    test('两边都拿不到 season：照常自动选首条（信息缺失不关功能）', () {
      final NyaaTorrent pack = _torrent('[Group] Test Anime - 01 [1080p]');
      expect(pack.season, isNull, reason: '前提：种子标题没有季号 token');
      expect(jimakuEntrySeason(s1.name), 1);
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1],
          torrentSeason: pack.season,
          anilistId: 999,
        )?.id,
        11,
      );
    });

    test('种子没写季号、条目写了季号：仍照常自动选（不凭空拦）', () {
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s2],
          torrentSeason: null,
          anilistId: 999,
        )?.id,
        22,
      );
    });

    test('用户手选的条目不被拦：季号明显不符也原样沿用', () {
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      // 同一份输入，不带 userPickedEntryId 时被拦成 null（对照组，证明拦截确实生效）。
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1],
          torrentSeason: pack.season,
          anilistId: 999,
        ),
        isNull,
      );
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1],
          userPickedEntryId: 11,
          torrentSeason: pack.season,
          anilistId: 999,
        )?.id,
        11,
        reason: '用户可能就是要另一季的字幕（合集版编号不同等），拦他是越权',
      );
    });

    test('手选的条目已不在新结果里 → 回退自动选，且自动选仍受季号校验', () {
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[s1],
          userPickedEntryId: 4242,
          torrentSeason: pack.season,
          anilistId: 999,
        ),
        isNull,
      );
    });

    test('条目挂的 anilist_id 命中所选番 → 一律放行（AniList 按季拆条目，id 即权威）', () {
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[
            JimakuEntry(id: 33, name: 'Sousou no Frieren', anilistId: 999),
          ],
          torrentSeason: pack.season,
          anilistId: 999,
        )?.id,
        33,
      );
      // 挂的是别的番的 id → 不算命中，照常按名字比季号。
      expect(
        resolveJimakuEntry(
          const <JimakuEntry>[
            JimakuEntry(id: 33, name: 'Sousou no Frieren', anilistId: 12345),
          ],
          torrentSeason: pack.season,
          anilistId: 999,
        ),
        isNull,
      );
    });

    test('空候选列表 → null（与改前一致）', () {
      expect(resolveJimakuEntry(const <JimakuEntry>[]), isNull);
    });

    test('jimakuEntrySeason：真实条目名解析，不写季号按第一季', () {
      expect(jimakuEntrySeason('Sousou no Frieren'), 1);
      expect(jimakuEntrySeason('Oshi no Ko 2nd Season'), 2);
      expect(jimakuEntrySeason('Mushoku Tensei S2'), 2);
      expect(jimakuEntrySeason('葬送のフリーレン 第2期'), 2);
      expect(jimakuEntrySeason('Yuru Camp Season 3'), 3);
      expect(jimakuEntrySeason('Spice and Wolf Part 2'), 2);
    });

    test('同季不算冲突：条目与包都写 S2', () {
      final NyaaTorrent pack =
          _torrent('[Group] Sousou no Frieren S2 [01-12][1080p]');
      expect(
        jimakuEntrySeasonConflicts(
          entry: s2,
          torrentSeason: pack.season,
          anilistId: 999,
        ),
        isFalse,
      );
    });
  });
}
