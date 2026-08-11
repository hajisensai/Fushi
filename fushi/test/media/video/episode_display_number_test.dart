import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_episode_panel.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';

/// BUG-1544：选集卡片的序号必须跟随**文件名解析出的真实集号**，而不是导入顺位号。
///
/// 缺集 / 只导入了一部分时两者必然错位：`S01E05` 排在列表第 3 位，旧口径标成
/// `03`，用户点开发现是第 5 集。
void main() {
  group('parsedEpisodeNumberOf（纯函数）', () {
    test('S01E05 → 5', () {
      expect(
        parsedEpisodeNumberOf(
          'Young.Ladies.Dont.Play.Fighting.Games.S01E05.The.Night.Before'
          '.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub.mkv',
        ),
        5,
      );
    });

    test('dash 集号 → 真实集号', () {
      expect(parsedEpisodeNumberOf('Hibike! Euphonium 2 - 07.mkv'), 7);
    });

    test('完整路径同样解析（Windows 分隔符）', () {
      expect(
        parsedEpisodeNumberOf(r'D:\anime\Show\Show.S02E11.mkv'),
        11,
      );
    });

    test('解析不出集号（PV/特典）→ null，调用方回落顺位号', () {
      expect(parsedEpisodeNumberOf('Special Preview.mkv'), isNull);
    });
  });

  testWidgets('缺集时集卡角标显示真实集号 05，而不是顺位号 03', (WidgetTester tester) async {
    // 用户实测场景：E01/E02 之后跳到 E05/E06（中间两集没导入）。
    const List<String> paths = <String>[
      'Young.Ladies.Dont.Play.Fighting.Games.S01E01.1080p.mkv',
      'Young.Ladies.Dont.Play.Fighting.Games.S01E02.1080p.mkv',
      'Young.Ladies.Dont.Play.Fighting.Games.S01E05.1080p.mkv',
      'Young.Ladies.Dont.Play.Fighting.Games.S01E06.1080p.mkv',
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoEpisodePanel(
          episodes: <VideoEpisodeEntry>[
            for (final String path in paths)
              VideoEpisodeEntry(
                title: path,
                episodeNumber: parsedEpisodeNumberOf(path),
              ),
          ],
          // 当前集用 play_arrow 顶掉数字，故把它放在第 0 张，让 1..3 张露出数字。
          currentIndex: 0,
          onTapEpisode: (_) {},
          onClose: () {},
          colorScheme: const ColorScheme.light(),
          title: 'Episodes',
          emptyHint: 'No episodes',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('02'), findsOneWidget);
    expect(find.text('05'), findsOneWidget, reason: '第 3 张卡是 E05，不是顺位号 03');
    expect(find.text('06'), findsOneWidget);
    expect(find.text('03'), findsNothing, reason: '顺位号 03 不该出现（没有第 3 集）');
    expect(find.text('04'), findsNothing);
  });

  testWidgets('解析不出集号的条目回落顺位号', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoEpisodePanel(
          episodes: <VideoEpisodeEntry>[
            const VideoEpisodeEntry(title: 'Trailer'),
            VideoEpisodeEntry(
              title: 'Special Preview.mkv',
              episodeNumber: parsedEpisodeNumberOf('Special Preview.mkv'),
            ),
          ],
          currentIndex: 0,
          onTapEpisode: (_) {},
          onClose: () {},
          colorScheme: const ColorScheme.light(),
          title: 'Episodes',
          emptyHint: 'No episodes',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('02'), findsOneWidget, reason: '无集号 → 回落顺位号 02');
  });
}
