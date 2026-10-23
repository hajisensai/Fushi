import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_library_sheet.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:material_ui/material_ui.dart';

/// 1×1 透明 PNG。
const List<int> _kTransparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// 点播弹层：列电脑视频库、搜索按词重取、标出正在放的那部、点选回传 bookUid、
/// 滚到底续取下一页。
void main() {
  Widget host(
    VideoRemoteLibraryLoader load,
    ValueChanged<String> onPick, {
    VideoRemoteLibraryCoverResolver? coverFor,
  }) => MaterialApp(
    theme: buildFushiFallbackTheme(
      Brightness.light,
    ).copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: VideoRemoteLibrarySheet(
        load: load,
        onPick: onPick,
        coverFor: coverFor,
      ),
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
    expect(find.text('Video 34', skipOffstage: false), findsOneWidget);
  });

  testWidgets('shows covers only for entries that have one', (
    WidgetTester tester,
  ) async {
    final List<String> asked = <String>[];
    await tester.pumpWidget(
      host(
        (String query, int offset) async => const VideoRemoteLibraryPage(
          items: <VideoRemoteLibraryEntry>[
            VideoRemoteLibraryEntry(
              bookUid: 'with',
              title: 'With cover',
              coverVersion: 7,
            ),
            VideoRemoteLibraryEntry(bookUid: 'without', title: 'No cover'),
          ],
          total: 2,
        ),
        (_) {},
        coverFor: (VideoRemoteLibraryEntry entry) {
          asked.add(entry.bookUid);
          return entry.coverVersion == null
              ? null
              : MemoryImage(Uint8List.fromList(_kTransparentPng));
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(asked, containsAll(<String>['with', 'without']));
    expect(
      find.byKey(const ValueKey<String>('video-remote-library-cover-with')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-library-cover-without')),
      findsNothing,
    );
  });

  testWidgets('a cover that fails to load falls back to the icon', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        (String query, int offset) async => const VideoRemoteLibraryPage(
          items: <VideoRemoteLibraryEntry>[
            VideoRemoteLibraryEntry(
              bookUid: 'bad',
              title: 'Bad',
              coverVersion: 1,
            ),
          ],
          total: 1,
        ),
        (_) {},
        coverFor: (_) => MemoryImage(Uint8List.fromList(<int>[0, 1, 2])),
      ),
    );
    await tester.pumpAndSettle();
    // 解码失败要真实异步跑完才回到 errorBuilder。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final Finder cover = find.byKey(
      const ValueKey<String>('video-remote-library-cover-bad'),
    );
    expect(cover, findsOneWidget);
    expect(
      find.descendant(of: cover, matching: find.byType(FushiIcon)),
      findsOneWidget,
    );
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
