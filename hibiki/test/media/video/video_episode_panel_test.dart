import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/episode_thumbnail_cache.dart';
import 'package:hibiki/src/media/video/video_episode_panel.dart';

/// 测试用缩略图解析器：记录被解析的 entry（验证面板把封面路径 / 视频路径 / key 正确
/// 透传给解析器），恒返回 null 以走占位分支——避免在 widget 测试里真渲染 `Image.file`
/// （flutter_test 下真实文件图片解码需真事件循环，否则单帧 pump 会挂，是已知坑）。
/// coverPath → 显示路径的解析逻辑由 `episode_thumbnail_cache_test.dart` 全覆盖。
class _RecordingResolver implements EpisodeThumbnailResolver {
  final List<VideoEpisodeEntry> resolved = <VideoEpisodeEntry>[];

  @override
  Future<String?> resolve(VideoEpisodeEntry entry) async {
    resolved.add(entry);
    return null;
  }
}

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  List<VideoEpisodeEntry> episodes(int n) => <VideoEpisodeEntry>[
        for (int i = 0; i < n; i++)
          VideoEpisodeEntry(title: 'Episode ${i + 1}', thumbnailKey: 'k$i'),
      ];

  // 面板行会异步解析封面；用一个恒返回 null 的解析器让占位（movie 图标）稳定渲染，
  // 且不产生真实文件 IO / Image.file 解码。
  EpisodeThumbnailResolver nullResolver() => _RecordingResolver();

  testWidgets('lists episodes; tap reports the episode index (TODO-638)',
      (WidgetTester tester) async {
    final List<int> tapped = <int>[];
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        thumbnailResolver: nullResolver(),
        currentIndex: 1,
        onTapEpisode: tapped.add,
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));
    await tester.pump();

    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('Episode 3'), findsOneWidget);

    await tester.tap(find.text('Episode 3'));
    expect(tapped, <int>[2]);
  });

  testWidgets(
      'highlights the current episode with a play_arrow overlay (TODO-638)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        thumbnailResolver: nullResolver(),
        currentIndex: 1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));
    await tester.pump();

    // 仅当前集（Episode 2, index 1）有 play_arrow 覆盖标记。
    final Finder currentTile = find.ancestor(
      of: find.text('Episode 2'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: currentTile, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    final Finder otherTile = find.ancestor(
      of: find.text('Episode 1'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: otherTile, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
    // 每行左下角显示序号徽标（无封面时仍能看清顺序）。
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets(
      'each row asks the resolver for its own entry (cover/video/key '
      'wiring)', (WidgetTester tester) async {
    final _RecordingResolver resolver = _RecordingResolver();
    final List<VideoEpisodeEntry> input = <VideoEpisodeEntry>[
      const VideoEpisodeEntry(
        title: 'E1',
        coverPath: '/covers/e1.jpg',
        videoPath: '/vids/e1.mkv',
        thumbnailKey: 'uid1',
      ),
      const VideoEpisodeEntry(
        title: 'E2',
        videoPath: '/vids/e2.mkv',
        thumbnailKey: 'uid2',
      ),
    ];
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: input,
        thumbnailResolver: resolver,
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));
    await tester.pump(); // 让每行的异步 resolve 完成。

    // 两行都向解析器要了各自的 entry，封面 / 视频路径 / key 原样透传。
    expect(resolver.resolved.length, 2);
    final VideoEpisodeEntry e1 =
        resolver.resolved.firstWhere((VideoEpisodeEntry e) => e.title == 'E1');
    expect(e1.coverPath, '/covers/e1.jpg');
    expect(e1.videoPath, '/vids/e1.mkv');
    expect(e1.thumbnailKey, 'uid1');
    // 解析器恒返回 null → 每行回退占位（movie 图标）。
    expect(find.byIcon(Icons.movie_outlined), findsWidgets);
  });

  testWidgets('missing cover falls back to placeholder icon (no Image)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(2),
        thumbnailResolver: nullResolver(),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsWidgets);
  });

  testWidgets('header × button reports onClose (TODO-638)',
      (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(2),
        thumbnailResolver: nullResolver(),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () => closed++,
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));
    await tester.pump();

    expect(find.text('Episodes'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, 1);
  });

  testWidgets('empty episode list shows the empty hint (TODO-638)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: const <VideoEpisodeEntry>[],
        thumbnailResolver: nullResolver(),
        currentIndex: -1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes here',
      ),
    ));
    await tester.pump();

    expect(find.text('No episodes here'), findsOneWidget);
  });
}
