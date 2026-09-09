import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:path/path.dart' as p;

void main() {
  group('parseVideoFilename', () {
    test('字幕组式 [组] 标题 - 12 [画质]', () {
      final VideoNameInfo info =
          parseVideoFilename('[SubGroup] Title - 12 [1080p][x264].mkv');
      expect(info.series, 'Title');
      expect(info.episode, 12);
      expect(info.season, isNull);
    });

    test('BUG-1461 Himouto 字幕组命名保留英文识别标题', () {
      final VideoNameInfo info = parseVideoFilename(
        '[Kamigami] Himouto! Umaru-chan - 10 '
        '[1920x1080 x264 AAC Sub(Chs,Cht,Jap)].mkv',
      );
      expect(info.series, 'Himouto! Umaru-chan');
      expect(info.episode, 10);
      expect(info.season, isNull);
    });

    test('SxxEyy 季+集（点分隔）', () {
      final VideoNameInfo info =
          parseVideoFilename('Title.S02E05.1080p.WEB-DL.mkv');
      expect(info.series, 'Title');
      expect(info.season, 2);
      expect(info.episode, 5);
    });

    test('SxxEyy 带字幕组与空格', () {
      final VideoNameInfo info =
          parseVideoFilename('[Group] Series Name - S01E03 [x265].mkv');
      expect(info.series, 'Series Name');
      expect(info.season, 1);
      expect(info.episode, 3);
    });

    test('CJK 第N話', () {
      final VideoNameInfo info = parseVideoFilename('Show 第12話.mkv');
      expect(info.series, 'Show');
      expect(info.episode, 12);
    });

    test('日文番名 + 破折号集号', () {
      final VideoNameInfo info =
          parseVideoFilename('[ABC] 鬼滅の刃 - 08 [1080p][x264].mkv');
      expect(info.series, '鬼滅の刃');
      expect(info.episode, 8);
    });

    test('EP 前缀', () {
      final VideoNameInfo info = parseVideoFilename('Show EP05.mp4');
      expect(info.series, 'Show');
      expect(info.episode, 5);
    });

    test('结尾裸数字', () {
      final VideoNameInfo info = parseVideoFilename('My Anime 03.mp4');
      expect(info.series, 'My Anime');
      expect(info.episode, 3);
    });

    test('无集号 → 整名作系列、单片', () {
      final VideoNameInfo info = parseVideoFilename('Aria the Animation.mkv');
      expect(info.series, 'Aria the Animation');
      expect(info.episode, isNull);
    });

    test('点分隔系列名归一为空格', () {
      final VideoNameInfo info = parseVideoFilename('Cowboy.Bebop.第05話.mkv');
      expect(info.series, 'Cowboy Bebop');
      expect(info.episode, 5);
    });

    test('MoviePilot 显式身份块不污染标题并覆盖季集号', () {
      final VideoNameInfo info = parseVideoFilename(
        'Show {[tmdbid=777;type=tv;g=group-1;s=2;e=3]}.mkv',
      );
      expect(info.series, 'Show');
      expect(info.season, 2);
      expect(info.episode, 3);
    });

    test('re0 发布名保留第三季与正片集号', () {
      final VideoNameInfo info = parseVideoFilename(
        '[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
        '[01][1080P][BDRip][HEVC-10bit][FLACx2].mkv',
      );
      expect(info.series, 'Re Zero kara Hajimeru Isekai Seikatsu');
      expect(info.season, 3);
      expect(info.episode, 1);

      final ParsedMediaName parent = FilenameParser.parse(
        '[DBD-Raws][Re：从零开始的异世界生活 第三季]'
        '[01-16TV全集+SP][1080P][BDRip][HEVC-10bit][简繁外挂][FLAC][MKV]',
      );
      expect(parent.title, 'Re：从零开始的异世界生活');
      expect(parent.season, 3);
    });
  });

  group('G10 第二步：parseVideoFilename 是 FilenameParser.parse 的窄化适配', () {
    test('括号集数 [11]（旧引擎解不出、刮削引擎能）→ 分组/刮削同解', () {
      final VideoNameInfo info = parseVideoFilename(
        '[桜都字幕组] 无职转生～到了异世界就拿出真本事～ [11][1080p][简繁内封].mkv',
      );
      expect(info.series, '无职转生');
      expect(info.episode, 11);
    });

    test('电影关键词由引擎剥离，不再留在系列名里（行为变化，与刮削端一致）', () {
      expect(parseVideoFilename('Some Movie Title.mkv').series, 'Some Title');
      expect(parseVideoFilename('紫罗兰永恒花园 剧场版.mkv').series, '紫罗兰永恒花园');
      expect(parseVideoFilename('紫罗兰永恒花园 剧场版.mkv').episode, isNull);
    });

    test('引擎解不出标题（设备/日期命名）→ stem 兜底、series 永不为空', () {
      final VideoNameInfo device = parseVideoFilename('VID_20260701.mp4');
      expect(device.series, isNotEmpty);
      expect(device.episode, isNull);
      final VideoNameInfo obs = parseVideoFilename('2026-07-01 21-03-55.mkv');
      expect(obs.series, isNotEmpty);
      expect(obs.episode, isNull);
    });

    test('同一文件名两侧恒同解（防引擎再分叉守卫）', () {
      const List<String> samples = <String>[
        '[SubsPlease] Sousou no Frieren - 28 (1080p) [A1B2C3D4].mkv',
        'Title.S02E05.1080p.WEB-DL.mkv',
        '[北宇治字幕组] 摇曳露营 第三季 [08][WebRip][1080p][简繁内封].mkv',
        'Show EP05.mp4',
        'My Anime 03.mp4',
        '鬼灭之刃 第26话.mp4',
      ];
      for (final String f in samples) {
        final VideoNameInfo grouped = parseVideoFilename(f);
        final ParsedMediaName scraped = FilenameParser.parse(f);
        expect(grouped.episode, scraped.episode, reason: '$f 集数分叉');
        expect(grouped.season, scraped.season, reason: '$f 季号分叉');
        expect(grouped.series, scraped.title, reason: '$f 系列名分叉');
      }
    });
  });

  // BUG-1435：Jellyfin / Plex / Netflix 系点分隔命名里，`SxxExx` 之后是**该集独有**
  // 的分集标题 + 发布元数据。此前分集标题被并进系列名，同一部番每集解出不同
  // series，「按文件夹导入」按 series 分组时分不到一组，12 集变成 12 个独立条目。
  group('SxxExx 后的分集标题不进系列名（BUG-1435）', () {
    test('Netflix 式 标题.S01E09.分集标题.WEBRip.Netflix.ja[cc]', () {
      final VideoNameInfo info = parseVideoFilename(
        '日々は過ぎれど飯うまし.S01E09.出店してみますか!.WEBRip.Netflix.ja[cc].mkv',
      );
      expect(info.series, '日々は過ぎれど飯うまし');
      expect(info.season, 1);
      expect(info.episode, 9);
    });

    test('分集标题含下划线时噪声一样剥干净', () {
      // `_`→空格 若发生在「点分隔命名」判定之前，标题里凭空多出空格会让判定失效，
      // `.WEBRip.Netflix.ja` 整串留在系列名里。
      final VideoNameInfo info = parseVideoFilename(
        '日々は過ぎれど飯うまし.S01E05.ドライブ行かない_.WEBRip.Netflix.ja[cc].mkv',
      );
      expect(info.series, '日々は過ぎれど飯うまし');
      expect(info.season, 1);
      expect(info.episode, 5);
    });

    test('分集标题归 secondaryTitle，不丢信息', () {
      final ParsedMediaName parsed = FilenameParser.parse(
        '日々は過ぎれど飯うまし.S01E10.ただいま.WEBRip.Netflix.ja[cc].mkv',
      );
      expect(parsed.title, '日々は過ぎれど飯うまし');
      expect(parsed.secondaryTitle, 'ただいま');
    });

    test('集号前置命名不被截空（S01E04 之前无标题字符时不截断）', () {
      final VideoNameInfo info = parseVideoFilename('S01E04 - Title.mkv');
      expect(info.series, 'Title');
      expect(info.season, 1);
      expect(info.episode, 4);
    });
  });

  group('groupVideosIntoPlaylists', () {
    test('URL 路径（网络来源）：解码后参与解析，编码不渗进系列名/集标题', () {
      const String base = 'https://dav.example.com/media/Show%20A';
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '$base/Show%20A%20S01E01.mkv',
        '$base/Show%20A%20S01E02.mkv',
      ]);
      expect(groups, hasLength(1));
      final VideoGroup g = groups.single;
      expect(g.series, 'Show A', reason: '系列名必须是解码后的（不能是 Show%20A）');
      expect(g.isPlaylist, isTrue);
      expect(g.episodes.first.title, 'Show A S01E01', reason: '集标题同理解码');
      expect(g.episodes.first.path, '$base/Show%20A%20S01E01.mkv',
          reason: 'path 保持原始 URL（播放/入库身份不动）');
    });

    test('整季分集标题各不相同 → 仍归一组，按集号排序（BUG-1435）', () {
      const String prefix = '/v/日々は過ぎれど飯うまし.S01E';
      const String suffix = '.WEBRip.Netflix.ja[cc].mkv';
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '${prefix}09.出店してみますか!$suffix',
        '${prefix}10.ただいま$suffix',
        '${prefix}07.ずっと忘れないと思う$suffix',
        '${prefix}12.ごちそうさま!!$suffix',
        '${prefix}04.この子は星なな$suffix',
        '${prefix}03.お金なくなっちゃった!!$suffix',
        '${prefix}05.ドライブ行かない_$suffix',
        '${prefix}11.クリスマス空いてますか!_$suffix',
      ]);
      expect(groups, hasLength(1), reason: '同一部番必须归一组');
      final VideoGroup g = groups.single;
      expect(g.series, '日々は過ぎれど飯うまし');
      expect(g.isPlaylist, isTrue);
      expect(
        g.episodes.map((VideoEpisode e) => e.episode).toList(),
        <int>[3, 4, 5, 7, 9, 10, 11, 12],
      );
    });

    test('同系列多集 → 一组，按集号排序', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '/v/[G] Title - 03 [1080p].mkv',
        '/v/[G] Title - 01 [1080p].mkv',
        '/v/[G] Title - 02 [1080p].mkv',
      ]);
      expect(groups, hasLength(1));
      final VideoGroup g = groups.single;
      expect(g.series, 'Title');
      expect(g.isPlaylist, isTrue);
      expect(g.episodes.map((VideoEpisode e) => e.episode).toList(),
          <int>[1, 2, 3]);
    });

    test('多系列 → 多组，按系列名排序', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '/v/Beta - 01.mkv',
        '/v/Alpha - 02.mkv',
        '/v/Alpha - 01.mkv',
      ]);
      expect(groups.map((VideoGroup g) => g.series).toList(),
          <String>['Alpha', 'Beta']);
      expect(groups[0].episodes, hasLength(2));
      expect(groups[1].episodes, hasLength(1));
      expect(groups[1].isPlaylist, isFalse);
    });

    test('跨季 SxxEyy 按 季→集 排序', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '/v/Show.S02E01.mkv',
        '/v/Show.S01E02.mkv',
        '/v/Show.S01E01.mkv',
      ]);
      expect(groups, hasLength(1));
      final List<VideoEpisode> eps = groups.single.episodes;
      expect(
        eps.map((VideoEpisode e) => '${e.season}x${e.episode}').toList(),
        <String>['1x1', '1x2', '2x1'],
      );
    });

    test('单文件 → 单片组（非播放列表）', () {
      final List<VideoGroup> groups =
          groupVideosIntoPlaylists(<String>['/v/Standalone Movie.mkv']);
      expect(groups, hasLength(1));
      expect(groups.single.isPlaylist, isFalse);
      expect(groups.single.episodes.single.title, 'Standalone Movie');
    });

    test('空输入 → 空分组', () {
      expect(groupVideosIntoPlaylists(const <String>[]), isEmpty);
    });

    test('文件名只剩集号 → 系列名回落父目录（用户报「被拆成分开的剧集」）', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        r'D:\Videos\动漫\葬送的芙莉莲\02.mp4',
        r'D:\Videos\动漫\葬送的芙莉莲\01.mp4',
        r'D:\Videos\动漫\葬送的芙莉莲\13.mp4',
      ]);
      expect(groups, hasLength(1), reason: '同目录的纯集号文件必须归一组');
      final VideoGroup g = groups.single;
      expect(g.series, '葬送的芙莉莲');
      expect(g.isPlaylist, isTrue);
      expect(
        g.episodes.map((VideoEpisode e) => e.episode).toList(),
        <int>[1, 2, 13],
      );
    });

    test('第NN集 / SxxEyy 形态同样回落父目录', () {
      expect(
        groupVideosIntoPlaylists(<String>[
          '/v/间谍过家家/第01集.mp4',
          '/v/间谍过家家/第02集.mp4',
        ]).single.series,
        '间谍过家家',
      );
      expect(
        groupVideosIntoPlaylists(<String>[
          '/v/Dandadan/S01E01.mkv',
          '/v/Dandadan/S01E02.mkv',
        ]).single.series,
        'Dandadan',
      );
    });

    test('父目录是季目录 → 用目录原名，不并季（并了会撞键丢文件）', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '/v/Show/Season 1/01.mkv',
        '/v/Show/Season 2/01.mkv',
      ]);
      expect(groups.map((VideoGroup g) => g.series).toList(),
          <String>['Season 1', 'Season 2']);
      expect(groups.every((VideoGroup g) => g.episodes.length == 1), isTrue);
    });

    test('目录里混着不同番的纯集号文件仍按目录归一组（可由用户拆分）', () {
      final List<VideoGroup> groups =
          groupVideosIntoPlaylists(<String>['/v/杂/01.mkv', '/v/杂/02.mkv']);
      expect(groups.single.series, '杂');
    });

    test('文件名自带番名时不看目录（既有行为不变）', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        '/v/合集目录/Alpha - 01.mkv',
        '/v/合集目录/Beta - 01.mkv',
      ]);
      expect(groups.map((VideoGroup g) => g.series).toList(),
          <String>['Alpha', 'Beta']);
    });

    test('网络来源的百分号编码目录名解码后再做系列名', () {
      final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
        'https://dav.example.com/media/Show%20A/01.mkv',
        'https://dav.example.com/media/Show%20A/02.mkv',
      ]);
      expect(groups.single.series, 'Show A');
    });

    test('无父目录段（裸文件名）保持原样', () {
      expect(groupVideosIntoPlaylists(<String>['01.mkv']).single.series, '01');
    });
  });

  group('兄弟集合差分定号（BUG-2369）', () {
    /// 用户报障形态：12 集的目录里集号不补零。单文件名规则只认「两位数或带前导
    /// 零」的尾部裸集数，于是 1..9 全部解不出、10..12 解得出——一半文件没有集号，
    /// 番名里还留着那个数字，同一部番被拆成一堆单集卡、顺序变成 1,10,11,12,2…
    test('不补零的 12 集目录：整批定号、归一组、按集号排序', () {
      final List<String> paths = <String>[
        for (int i = 1; i <= 12; i++) '/anime/Chuunibyou/Chuunibyou $i.mkv',
      ];
      final List<VideoGroup> groups = groupVideosIntoPlaylists(paths);
      expect(groups, hasLength(1), reason: '12 个文件必须归一组，不是 10 组');
      final VideoGroup g = groups.single;
      expect(g.series, 'Chuunibyou', reason: '系列名里不能留着集号');
      expect(g.isPlaylist, isTrue);
      expect(
        g.episodes.map((VideoEpisode e) => e.episode).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      );
    });

    test('集号紧贴标题（无分隔符）同样定号', () {
      final List<String> paths = <String>[
        for (int i = 1; i <= 12; i++) '/anime/Show/Show!$i.mkv',
      ];
      final VideoGroup g = groupVideosIntoPlaylists(paths).single;
      expect(
        g.episodes.map((VideoEpisode e) => e.episode).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      );
    });

    test('公共前缀不得切断数字段：只有 10/11/12 的目录不能解成 0/1/2', () {
      final SiblingEpisodeNumbering? sib =
          resolveSiblingEpisodeNumbers(<String>[
        '/a/Show 10.mkv',
        '/a/Show 11.mkv',
        '/a/Show 12.mkv',
      ]);
      expect(sib, isNotNull);
      expect(sib!.numbers.values.toList(), <int>[10, 11, 12]);
      expect(sib.series, 'Show');
    });

    test('parsedEpisodeNumbersOf：整批解析补齐单文件名解不出的集号', () {
      final List<String> paths = <String>[
        for (int i = 1; i <= 12; i++) '/anime/Show/Show $i.mkv',
      ];
      expect(
        parsedEpisodeNumbersOf(paths),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      );
    });

    test('已解出的集号只补不覆盖（后缀带画质块的真实命名）', () {
      final List<String> paths = <String>[
        '/a/Show - Interview 1 [BD].mkv',
        '/a/Show - Interview 2 [BD].mkv',
        '/a/Show - Interview 10 [BD].mkv',
      ];
      // 第三个单看文件名就解得出 10（尾部两位裸数字），前两个解不出。
      expect(parsedEpisodeNumberOf(paths[2]), 10);
      expect(parsedEpisodeNumberOf(paths[0]), isNull);
      expect(parsedEpisodeNumbersOf(paths), <int>[1, 2, 10]);
    });

    test('不同目录各自定号，互不偷号', () {
      final List<String> paths = <String>[
        '/a/S1/Show 1.mkv',
        '/a/S1/Show 2.mkv',
        '/a/S2/Show 10.mkv',
        '/a/S2/Show 11.mkv',
      ];
      expect(parsedEpisodeNumbersOf(paths), <int>[1, 2, 10, 11]);
    });

    test('补零命名不经过差分，行为与修复前逐字相同', () {
      final List<String> paths = <String>[
        '/a/[Nekomoe] Show - 01 [1080p].mkv',
        '/a/[Nekomoe] Show - 02 [1080p].mkv',
        '/a/[Nekomoe] Show - 03 [1080p].mkv',
      ];
      // 每个文件都自带集号 → 差分整条通路不介入。
      expect(fillEpisodeNumbersFromSiblings(paths, <int?>[1, 2, 3]),
          <int>[1, 2, 3]);
      final VideoGroup g = groupVideosIntoPlaylists(paths).single;
      expect(g.series, 'Show');
      expect(g.episodes.map((VideoEpisode e) => e.episode).toList(),
          <int>[1, 2, 3]);
    });
  });

  group('兄弟差分的负样本：判据不成立就整目录放弃（BUG-2369）', () {
    test('混入特典 → 不硬凑集号', () {
      final List<String> paths = <String>[
        '/a/Show 1.mkv',
        '/a/Show 2.mkv',
        '/a/Show OVA.mkv',
      ];
      expect(resolveSiblingEpisodeNumbers(paths), isNull);
      expect(parsedEpisodeNumbersOf(paths), <int?>[null, null, null]);
    });

    test('按年份区分的目录：4 位数字不当集号', () {
      final List<String> paths = <String>[
        '/a/Movie (1979).mkv',
        '/a/Movie (2005).mkv',
      ];
      expect(resolveSiblingEpisodeNumbers(paths), isNull);
      expect(parsedEpisodeNumbersOf(paths), <int?>[null, null]);
    });

    test('差分结果与已解出的集号对不上 → 整目录放弃，不覆盖已有值', () {
      final List<String> paths = <String>[
        '/a/Show 1.mkv',
        '/a/Show 2.mkv',
        '/a/Show 3.mkv',
      ];
      // 差分给的是 1/2/3；已解出的那个说自己是 7（绝对集号口径），两套口径不同。
      expect(
        fillEpisodeNumbersFromSiblings(paths, <int?>[null, null, 7]),
        <int?>[null, null, 7],
      );
    });

    test('stem 重名（不同目录同名文件）→ 该目录判据不成立', () {
      expect(
        resolveSiblingEpisodeNumbers(<String>['/a/01.mkv', '/b/01.mkv']),
        isNull,
      );
    });

    test('单个文件不做差分', () {
      expect(resolveSiblingEpisodeNumbers(<String>['/a/Show 1.mkv']), isNull);
    });

    test('集号真的解不出时按自然序排，不是裸字符串序', () {
      // 三个文件差在「9 / 100 / extra」上：差分因 extra 不是纯数字而放弃，
      // 集号全为 null，末位判据只剩标题。裸字符串序会把 100 排到 9 前面。
      final List<String> paths = <String>[
        '/a/Show - Talk 100 (x).mkv',
        '/a/Show - Talk extra (x).mkv',
        '/a/Show - Talk 9 (x).mkv',
      ];
      final VideoGroup g = groupVideosIntoPlaylists(paths).single;
      expect(g.episodes.every((VideoEpisode e) => e.episode == null), isTrue,
          reason: '前提：这三个都解不出集号，否则这条用例没在测末位判据');
      expect(
        g.episodes.map((VideoEpisode e) => e.title).toList(),
        <String>[
          'Show - Talk 9 (x)',
          'Show - Talk 100 (x)',
          'Show - Talk extra (x)',
        ],
      );
    });
  });

  group('listVideoFilesInDirectory', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hibiki_video_scan_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File touch(String relative) {
      final File f = File(p.join(root.path, relative));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('x');
      return f;
    }

    test('递归扫描子目录中的视频（番剧/季/集 嵌套结构）', () {
      // 用户真实组织方式：顶层只有文件夹，视频埋在子目录里。
      final File e01 = touch(p.join('Show', 'Season 1', 'Show S01E01.mkv'));
      final File e02 = touch(p.join('Show', 'Season 1', 'Show S01E02.mkv'));
      final File movie = touch(p.join('Movies', 'Some Movie', 'movie.mp4'));
      touch(p.join('Show', 'Season 1', 'Show S01E01.srt')); // 非视频，忽略
      touch(p.join('Show', 'cover.jpg')); // 非视频，忽略

      final List<String> found = listVideoFilesInDirectory(root.path);

      expect(
        found.map(p.normalize).toSet(),
        <String>{
          p.normalize(e01.path),
          p.normalize(e02.path),
          p.normalize(movie.path),
        },
      );
    });

    test('顶层视频也能扫到（与子目录视频混合）', () {
      final File top = touch('top.mp4');
      final File nested = touch(p.join('sub', 'nested.mkv'));

      final List<String> found = listVideoFilesInDirectory(root.path);

      expect(
        found.map(p.normalize).toSet(),
        <String>{p.normalize(top.path), p.normalize(nested.path)},
      );
    });

    test('蓝光 .m2ts / .ts 扩展名被识别', () {
      final File m2ts = touch(p.join('BDMV', 'STREAM', '00001.m2ts'));
      final File ts = touch(p.join('TS', 'episode.ts'));

      final List<String> found = listVideoFilesInDirectory(root.path);

      expect(
        found.map(p.normalize).toSet(),
        <String>{p.normalize(m2ts.path), p.normalize(ts.path)},
      );
    });

    test('无视频文件 → 空列表', () {
      touch(p.join('docs', 'readme.txt'));
      touch('cover.png');

      expect(listVideoFilesInDirectory(root.path), isEmpty);
    });

    test('不存在的目录 → 空列表', () {
      expect(
        listVideoFilesInDirectory(p.join(root.path, 'nope')),
        isEmpty,
      );
    });
  });
}
