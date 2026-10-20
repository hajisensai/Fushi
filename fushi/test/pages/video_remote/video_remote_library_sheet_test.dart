import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_library_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// 点播弹层：列电脑视频库、搜索按词重取、标出正在放的那部、点选回传 bookUid、
/// 滚到底续取下一页。
void main() {
  Widget host(VideoRemoteLibraryLoader load, ValueChanged<String> onPick) =>
      MaterialApp(
        theme: buildFushiFallbackTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: VideoRemoteLibrarySheet(load: load, onPick: onPick),
        ),
      );

  List<VideoRemoteLibraryEntry> entries(int from, int count) =>
      <VideoRemoteLibraryEntry>[
        for (int i = from; i < from + count; i++)
          VideoRemoteLibraryEntry(bookUid: 'v$i', title: 'Video $i'),
      ];

  testWidgets('lists, searches and picks', (WidgetTester tester) async {
    final List<(String, int)> requests = <(String, int)>[];
    final List<String> picked = <String>[];
    await tester.pumpWidget(
      host((String query, int offset) async {
        requests.add((query, offset));
        if (query.isNotEmpty) {
          return const VideoRemoteLibraryPage(
            items: <VideoRemoteLibraryEntry>[
              VideoRemoteLibraryEntry(
                bookUid: 'match',
                title: 'Frieren 2',
                collection: 'Frieren',
                positionMs: 61000,
              ),
            ],
            total: 1,
          );
        }
        return VideoRemoteLibraryPage(
          items: entries(0, 3),
          total: 3,
          currentBookUid: 'v1',
        );
      }, picked.add),
    );
    await tester.pumpAndSettle();
    expect(requests, <(String, int)>[('', 0)]);
    expect(find.text('Video 0'), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('video-remote-library-search')),
      ' fri ',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(requests.last, ('fri', 0));
    expect(find.text('Video 0'), findsNothing);
    expect(find.text('Frieren · Resume at 1:01'), findsOneWidget);

    await tester.tap(find.text('Frieren 2'));
    expect(picked, <String>['match']);
  });

  testWidgets('loads the next page near the end', (WidgetTester tester) async {
    final List<int> offsets = <int>[];
    await tester.pumpWidget(
      host((String query, int offset) async {
        offsets.add(offset);
        return VideoRemoteLibraryPage(
          items: entries(offset, offset == 0 ? 30 : 5),
          total: 35,
        );
      }, (_) {}),
    );
    await tester.pumpAndSettle();
    expect(offsets, <int>[0]);
    await tester.drag(
      find.byKey(const ValueKey<String>('video-remote-library-list')),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    expect(offsets, <int>[0, 30]);
    // 行带封面后更高：第二页到了再拉到底才进构建范围。
    await tester.drag(
      find.byKey(const ValueKey<String>('video-remote-library-list')),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    expect(offsets, <int>[0, 30]);
    expect(find.text('Video 34', skipOffstage: false), findsOneWidget);
  });

  testWidgets('empty and failed states', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        (String query, int offset) async => const VideoRemoteLibraryPage(
          items: <VideoRemoteLibraryEntry>[],
          total: 0,
        ),
        (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("The computer's video library is empty"), findsOneWidget);
  });
}
