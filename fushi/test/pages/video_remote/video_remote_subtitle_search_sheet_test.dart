import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// 手机「在线搜索字幕」弹层：打开即按电脑默认值搜并预填、改词重搜、点一条让
/// 电脑下载应用、失败原因就地显示。
void main() {
  Widget host(
    VideoRemoteSubtitleSearcher search,
    VideoRemoteSubtitleDownloader download,
    VoidCallback onApplied,
  ) => MaterialApp(
    theme: buildFushiFallbackTheme(
      Brightness.light,
    ).copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: VideoRemoteSubtitleSearchSheet(
        search: search,
        download: download,
        errorText: (Object error) => 'failed: $error',
        onApplied: onApplied,
      ),
    ),
  );

  const VideoRemoteSubtitleSearchResult hits = VideoRemoteSubtitleSearchResult(
    query: '葬送のフリーレン',
    episode: 3,
    candidates: <VideoRemoteSubtitleCandidate>[
      VideoRemoteSubtitleCandidate(
        id: '1.0',
        fileName: 'frieren_03.ja.srt',
        provider: 'jimaku',
        language: 'ja',
      ),
    ],
  );

  testWidgets('searches with the computer defaults and prefills them', (
    WidgetTester tester,
  ) async {
    final List<(String?, int?)> searches = <(String?, int?)>[];
    await tester.pumpWidget(
      host(
        (String? query, int? episode) async {
          searches.add((query, episode));
          return hits;
        },
        (_) async {},
        () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(searches, <(String?, int?)>[(null, null)]);
    expect(find.text('葬送のフリーレン'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('frieren_03.ja.srt'), findsOneWidget);
    expect(find.text('jimaku'), findsOneWidget);
    expect(find.text('JA'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('video-remote-subtitle-search-episode'),
        ),
        matching: find.byType(EditableText),
      ),
      '4',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-subtitle-search-go')),
    );
    await tester.pumpAndSettle();
    expect(searches.last, ('葬送のフリーレン', 4));
  });

  testWidgets('picking a hit asks the computer to apply it', (
    WidgetTester tester,
  ) async {
    final List<String> downloads = <String>[];
    int applied = 0;
    await tester.pumpWidget(
      host(
        (String? query, int? episode) async => hits,
        (String id) async => downloads.add(id),
        () => applied++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('frieren_03.ja.srt'));
    await tester.pumpAndSettle();
    expect(downloads, <String>['1.0']);
    expect(applied, 1);
  });

  testWidgets('failures stay in the sheet', (WidgetTester tester) async {
    int applied = 0;
    await tester.pumpWidget(
      host(
        (String? query, int? episode) async => hits,
        (String id) async => throw StateError('nope'),
        () => applied++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('frieren_03.ja.srt'));
    await tester.pumpAndSettle();
    expect(applied, 0);
    expect(
      find.byKey(const ValueKey<String>('video-remote-subtitle-search-error')),
      findsOneWidget,
    );
    expect(find.text('frieren_03.ja.srt'), findsOneWidget);
  });

  testWidgets('no hits says so', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        (String? query, int? episode) async =>
            const VideoRemoteSubtitleSearchResult(
              query: 'x',
              candidates: <VideoRemoteSubtitleCandidate>[],
            ),
        (_) async {},
        () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-remote-subtitle-search-empty')),
      findsOneWidget,
    );
  });
}
