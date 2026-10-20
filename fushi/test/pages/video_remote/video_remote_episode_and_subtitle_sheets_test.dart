import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_cover_image.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_episode_sheet.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_library_sheet.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// 遥控弹层（用户 2026-10-21）：选集与点播带封面预览；在线字幕搜索按电脑预填
/// 先搜一次、改词重搜、点选回传候选。
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: buildFushiFallbackTheme(
      Brightness.light,
    ).copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(body: child),
  );

  ImageProvider cover(String key, List<String> asked) => VideoRemoteCoverImage(
    cacheKey: 'test|$key',
    load: () async {
      asked.add(key);
      return null;
    },
  );

  group('选集', () {
    testWidgets('只给有封面的集取封面，标出当前集，点选回传下标并轻震', (WidgetTester tester) async {
      final List<Object?> haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final List<String> asked = <String>[];
      final List<int> picked = <int>[];
      await tester.pumpWidget(
        host(
          VideoRemoteEpisodeSheet(
            episodes: const <VideoRemoteEpisodeEntry>[
              VideoRemoteEpisodeEntry(index: 0, title: 'Ep 1', hasCover: true),
              VideoRemoteEpisodeEntry(index: 1, title: 'Ep 2', current: true),
            ],
            coverFor: (VideoRemoteEpisodeEntry e) =>
                cover('ep${e.index}', asked),
            onPick: picked.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(asked, <String>['ep0']);
      expect(find.byType(VideoRemoteCoverThumb), findsNWidgets(2));
      expect(find.text('Playing'), findsOneWidget);
      await tester.tap(find.text('Ep 1'));
      expect(picked, <int>[0]);
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
    });

    test('解析电脑的集列表：缺 hasCover 视为没有封面', () {
      final VideoRemoteEpisodeEntry old = VideoRemoteEpisodeEntry.fromJson(
        const <String, dynamic>{'index': 2, 'title': 'Ep 3', 'current': true},
      );
      expect(old.hasCover, isFalse);
      expect(old.current, isTrue);
      expect(
        VideoRemoteEpisodeEntry.fromJson(const <String, dynamic>{
          'index': 0,
          'title': 'a',
          'hasCover': true,
        }).hasCover,
        isTrue,
      );
    });
  });

  testWidgets('点播：有封面的条目才取封面', (WidgetTester tester) async {
    final List<String> asked = <String>[];
    await tester.pumpWidget(
      host(
        VideoRemoteLibrarySheet(
          load: (String query, int offset) async =>
              const VideoRemoteLibraryPage(
                items: <VideoRemoteLibraryEntry>[
                  VideoRemoteLibraryEntry(
                    bookUid: 'a',
                    title: 'A',
                    hasCover: true,
                  ),
                  VideoRemoteLibraryEntry(bookUid: 'b', title: 'B'),
                ],
                total: 2,
              ),
          coverFor: (VideoRemoteLibraryEntry e) => cover(e.bookUid, asked),
          onPick: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(asked, <String>['a']);
  });

  group('在线字幕', () {
    testWidgets('打开按电脑预填搜一次并回填，改词重搜，点选回传', (WidgetTester tester) async {
      final List<(String?, int?)> searches = <(String?, int?)>[];
      final List<VideoRemoteSubtitleResult> picked =
          <VideoRemoteSubtitleResult>[];
      await tester.pumpWidget(
        host(
          VideoRemoteSubtitleSearchSheet(
            search: (String? query, int? episode) async {
              searches.add((query, episode));
              return VideoRemoteSubtitleSearchPage(
                query: query ?? 'Frieren',
                episode: query == null ? 4 : episode,
                results: <VideoRemoteSubtitleResult>[
                  VideoRemoteSubtitleResult(
                    handle: 'h-${query ?? 'prefill'}',
                    provider: 'jimaku',
                    fileName: '${query ?? 'Frieren'} - 04.srt',
                    language: 'ja',
                    episode: 4,
                    downloadCount: 12,
                  ),
                ],
              );
            },
            onPick: picked.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(searches, <(String?, int?)>[(null, null)]);
      expect(find.text('Frieren'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Frieren - 04.srt'), findsOneWidget);
      expect(find.textContaining('Jimaku'), findsOneWidget);

      await tester.enterText(
        find.byKey(
          const ValueKey<String>('video-remote-subtitle-search-query'),
        ),
        'Sousou',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(searches.last, ('Sousou', 4));

      await tester.tap(find.text('Sousou - 04.srt'));
      expect(picked.single.handle, 'h-Sousou');
    });

    testWidgets('来源错误与空结果各有说明', (WidgetTester tester) async {
      String? error = 'no_source';
      await tester.pumpWidget(
        host(
          VideoRemoteSubtitleSearchSheet(
            search: (String? query, int? episode) async =>
                VideoRemoteSubtitleSearchPage(
                  query: 'X',
                  results: const <VideoRemoteSubtitleResult>[],
                  error: error,
                ),
            onPick: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No subtitle source is set up on the computer'),
        findsOneWidget,
      );
      error = null;
      await tester.showKeyboard(
        find.byKey(
          const ValueKey<String>('video-remote-subtitle-search-query'),
        ),
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('No subtitles found'), findsOneWidget);
    });
  });

  test('封面缓存键相等即同一张图（不看取图闭包）', () {
    Future<Uint8List?> a() async => null;
    Future<Uint8List?> b() async => Uint8List(1);
    expect(
      VideoRemoteCoverImage(cacheKey: 'k', load: a),
      VideoRemoteCoverImage(cacheKey: 'k', load: b),
    );
    expect(
      VideoRemoteCoverImage(cacheKey: 'k', load: a),
      isNot(VideoRemoteCoverImage(cacheKey: 'other', load: a)),
    );
  });
}
