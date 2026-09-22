import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
  testWidgets('portrait receiver can hide lookup and send shoulder input', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          videoPlaceholder: const Text('remote frame'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byKey(GameStreamPage.transcriptKey)).dy,
      greaterThan(tester.getTopLeft(find.byKey(GameStreamPage.videoKey)).dy),
    );
    await tester.tap(find.text('L'));
    await tester.pump();
    expect(
      sent
          .where(
            (GameStreamInputEvent event) => event.button == 'shoulder_left',
          )
          .length,
      2,
    );
    await tester.tap(find.byTooltip(t.game_stream_lookup_toggle));
    await tester.pump();
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders video surface, transcript rail and sends touch input', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          videoPlaceholder: const Text('remote frame'),
        ),
      ),
    );

    expect(find.byKey(GameStreamPage.videoKey), findsOneWidget);
    expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);
    expect(find.text('remote frame'), findsOneWidget);

    await tester.tapAt(const Offset(120, 80));
    await tester.pump();

    expect(sent, isNotEmpty);
    expect(sent.first.kind, GameStreamInputKind.pointer);
    expect(sent.first.action, GameStreamInputAction.down);
    expect(sent.first.x, inInclusiveRange(0, 1));
    expect(sent.first.y, inInclusiveRange(0, 1));
  });
}
