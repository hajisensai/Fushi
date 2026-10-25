import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_cover_image.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_episode_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// 1×1 透明 PNG。
final Uint8List _kTransparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 手机遥控选集弹层（PR #2469 移植）：16:9 封面只为电脑声明有封面的集去取、
/// 打开即滚到当前集、点选回传集下标，空列表给提示。
void main() {
  Widget host(
    List<VideoRemoteEpisodeEntry> episodes,
    ValueChanged<int> onPick, {
    VideoRemoteEpisodeCoverResolver? coverFor,
  }) => MaterialApp(
    theme: buildFushiFallbackTheme(
      Brightness.light,
    ).copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: VideoRemoteEpisodeSheet(
        episodes: episodes,
        onPick: onPick,
        coverFor: coverFor,
      ),
    ),
  );

  List<VideoRemoteEpisodeEntry> episodes(int count, {int current = 0}) =>
      <VideoRemoteEpisodeEntry>[
        for (int i = 0; i < count; i++)
          VideoRemoteEpisodeEntry(
            index: i,
            title: 'Episode ${i + 1}',
            current: i == current,
            hasCover: i.isEven,
          ),
      ];

  test('fromJson：旧版电脑不报 hasCover 即为没有封面', () {
    final VideoRemoteEpisodeEntry legacy = VideoRemoteEpisodeEntry.fromJson(
      const <String, dynamic>{'index': 2, 'title': 'Ep 3', 'current': true},
    );
    expect(legacy.index, 2);
    expect(legacy.current, isTrue);
    expect(legacy.hasCover, isFalse);
    expect(
      VideoRemoteEpisodeEntry.fromJson(const <String, dynamic>{
        'index': 0,
        'title': 'Ep 1',
        'current': false,
        'hasCover': true,
      }).hasCover,
      isTrue,
    );
  });

  testWidgets('只为 hasCover 的集取封面，点选回传集下标', (WidgetTester tester) async {
    final List<int> asked = <int>[];
    final List<int> picked = <int>[];
    await tester.pumpWidget(
      host(
        episodes(4),
        picked.add,
        coverFor: (VideoRemoteEpisodeEntry entry) {
          asked.add(entry.index);
          return VideoRemoteCoverImage(
            cacheKey: 'test-episode-${entry.index}',
            load: () async => _kTransparentPng,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(asked.toSet(), <int>{0, 2});
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);

    await tester.tap(find.text('Episode 3'));
    await tester.pump();
    expect(picked, <int>[2]);
  });

  testWidgets('打开即滚到当前集（上面留一行）', (WidgetTester tester) async {
    await tester.pumpWidget(host(episodes(60, current: 40), (_) {}));
    await tester.pumpAndSettle();
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(
      scrollable.position.pixels,
      closeTo(39 * VideoRemoteEpisodeSheet.rowExtent, 0.5),
    );
    expect(find.text('Episode 41'), findsOneWidget);
  });

  testWidgets('空列表显示提示', (WidgetTester tester) async {
    await tester.pumpWidget(host(const <VideoRemoteEpisodeEntry>[], (_) {}));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-remote-episodes-empty')),
      findsOneWidget,
    );
  });
}
