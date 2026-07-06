import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_loading_overlay.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('TODO-1213: shows title + phase text + back button',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        VideoLoadingOverlay(
          title: 'Attack on Titan - S1E1',
          phaseText: 'Connecting to stream…',
          onBack: () {},
        ),
      ),
    );

    expect(find.text('Attack on Titan - S1E1'), findsOneWidget);
    expect(find.text('Connecting to stream…'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('TODO-1213: empty title hides the title row',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        VideoLoadingOverlay(
          title: '',
          phaseText: 'Preparing…',
          onBack: () {},
        ),
      ),
    );

    expect(find.text('Preparing…'), findsOneWidget);
    // Only the phase text is a Text; no title Text rendered for empty title.
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('TODO-1213: null progress renders indeterminate spinner, no %',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        VideoLoadingOverlay(
          title: 'X',
          phaseText: 'Buffering…',
          onBack: () {},
        ),
      ),
    );

    final CircularProgressIndicator indicator = tester.widget(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, isNull);
    // No percentage suffix when progress is null.
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Buffering…'), findsOneWidget);
  });

  testWidgets(
      'TODO-1213: subtitle download progress drives determinate bar + percent',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        VideoLoadingOverlay(
          title: 'X',
          phaseText: 'Downloading subtitles…',
          progress: 0.42,
          onBack: () {},
        ),
      ),
    );

    final CircularProgressIndicator indicator = tester.widget(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, 0.42);
    expect(find.textContaining('Downloading subtitles…'), findsOneWidget);
    expect(find.textContaining('42%'), findsOneWidget);
  });

  testWidgets('TODO-1213: tapping back invokes onBack (exit not stuck)',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      _harness(
        VideoLoadingOverlay(
          title: 'X',
          phaseText: 'Connecting to stream…',
          onBack: () => taps++,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(taps, 1);
  });
}
