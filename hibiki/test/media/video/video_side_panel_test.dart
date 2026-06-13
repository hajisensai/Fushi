import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'package:hibiki/src/media/video/video_favorite_sentences_panel.dart';
import 'package:hibiki/src/media/video/video_side_panel.dart';

void main() {
  testWidgets('VideoTranslucentSidePanel keeps the video area visible',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              title: 'Speed',
              onClose: () {},
              child: const Text('1.5x'),
            ),
          ],
        ),
      ),
    );

    final Material material = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('Speed'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, isNotNull);
    expect(material.color!.a, lessThan(1));
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('1.5x'), findsOneWidget);
    // BUG-254：右上角 X 关闭按钮已删除（关闭改由页面层全屏 barrier 点面板外承载）。
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('VideoFavoriteSentencesPanel shows only the current episode',
      (WidgetTester tester) async {
    final List<FavoriteSentence> tapped = <FavoriteSentence>[];
    final FavoriteSentence current = FavoriteSentence(
      text: 'Current episode sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13),
      sectionIndex: 1,
      normCharOffset: 12000,
      source: kFavoriteSentenceSourceVideo,
    );
    final FavoriteSentence other = FavoriteSentence(
      text: 'Other episode sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13),
      sectionIndex: 2,
      normCharOffset: 24000,
      source: kFavoriteSentenceSourceVideo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentEpisode: 1,
            sentences: <FavoriteSentence>[current, other],
            onTapSentence: tapped.add,
          ),
        ),
      ),
    );

    expect(find.text('Current episode sentence'), findsOneWidget);
    expect(find.text('Other episode sentence'), findsNothing);

    await tester.tap(find.text('Current episode sentence'));
    expect(tapped, <FavoriteSentence>[current]);
  });
}
