import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
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
      final VideoNameInfo info = parseVideoFilename('Some Movie Title.mkv');
      expect(info.series, 'Some Movie Title');
      expect(info.episode, isNull);
    });

    test('点分隔系列名归一为空格', () {
      final VideoNameInfo info = parseVideoFilename('Cowboy.Bebop.第05話.mkv');
      expect(info.series, 'Cowboy Bebop');
      expect(info.episode, 5);
    });
  });

  group('groupVideosIntoPlaylists', () {
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
