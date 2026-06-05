import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';

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
}
