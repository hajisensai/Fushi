import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_play_bar.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets('renders prev/play/next controls', (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    await tester.pumpWidget(buildTestApp(VideoPlayBar(controller: c)));
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });
}
