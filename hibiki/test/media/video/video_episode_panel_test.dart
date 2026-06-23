import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_episode_panel.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  List<PlaylistEntry> episodes(int n) => <PlaylistEntry>[
        for (int i = 0; i < n; i++)
          PlaylistEntry(title: 'Episode ${i + 1}', path: '/v/$i.mp4'),
      ];

  testWidgets('lists episodes; tap reports the episode index (TODO-638)',
      (WidgetTester tester) async {
    final List<int> tapped = <int>[];
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        currentIndex: 1,
        onTapEpisode: tapped.add,
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('Episode 3'), findsOneWidget);

    await tester.tap(find.text('Episode 3'));
    expect(tapped, <int>[2]);
  });

  testWidgets(
      'highlights the current episode with a play_arrow leading icon '
      '(TODO-638)', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        currentIndex: 1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    // 仅当前集（Episode 2, index 1）有 play_arrow leading 标记。
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
    // 非当前集显示序号。
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('header × button reports onClose (TODO-638)',
      (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(2),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () => closed++,
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    expect(find.text('Episodes'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, 1);
  });

  testWidgets('empty episode list shows the empty hint (TODO-638)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: const <PlaylistEntry>[],
        currentIndex: -1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes here',
      ),
    ));

    expect(find.text('No episodes here'), findsOneWidget);
  });

  testWidgets(
      'two-digit episode numbers stay single-line and visible at large font '
      '(TODO-759)', (WidgetTester tester) async {
    // 界面调大字号（appUiScale=3.0 → fontSize 14*3=42）下，两位数序号（tabular
    // figures，宽于一位数）此前被固定 24px 的 leading SizedBox 逼着换行，dense
    // ListTile 行高按 title 决定不随 leading 抬高，第二行被纵向裁切看不见。修复后
    // 序号列宽随字号缩放且 Text 单行不换行：① 序号 Text 仍可见且单行 ② leading
    // SizedBox 宽度 >= 阈值（不再固定 24）。
    const double largeFontSize = 42; // 14 * appUiScale(3.0)
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(12),
        currentIndex: 0, // 当前集 0 用 play_arrow；序号从「2」起全是显式 Text。
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
        fontSize: largeFontSize,
      ),
    ));
    await tester.pumpAndSettle();

    // ListView.builder 懒构建：大字号下后面的集可能在视口外未构建，先滚到序号「10」。
    final Finder tenText = find.text('10');
    await tester.scrollUntilVisible(tenText, 200,
        scrollable: find.byType(Scrollable));
    await tester.pumpAndSettle();

    // 两位数序号「10」存在、可见、且单行（softWrap:false / maxLines:1）。
    expect(tenText, findsOneWidget);
    final Text tenWidget = tester.widget<Text>(tenText);
    expect(tenWidget.maxLines, 1);
    expect(tenWidget.softWrap, false);

    // 序号未被纵向裁切：Text 的渲染高度约等于单行高度（< 1.6 行），不是两行。
    final Size tenSize = tester.getSize(tenText);
    expect(tenSize.height, lessThan(largeFontSize * 1.6),
        reason: 'episode number must render on a single line, not wrap');

    // 序号 leading 列宽随字号放大到阈值以上（不再固定 24px）。
    final Finder leadingBox = find.ancestor(
      of: tenText,
      matching: find.byType(SizedBox),
    );
    final SizedBox box = tester.widget<SizedBox>(leadingBox.first);
    expect(box.width, isNotNull);
    expect(box.width!, greaterThanOrEqualTo(largeFontSize + 12));
  });
}
