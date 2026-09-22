import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
  testWidgets(
    'uninitialised local dictionary still exposes tappable segments',
    (WidgetTester tester) async {
      final _Lookup lookup = _Lookup();
      final GameStreamLookupController controller =
          GameStreamLookupController(
            lookupClient: lookup,
            streamClient: FushiGameStreamClient(transport: _Transport()),
            clientId: 'c1',
          )..applyTextEvent(
            GameStreamTextEvent(
              sessionId: 's1',
              lineId: 'line-1',
              text: '日本語',
              timestampMs: 1,
            ),
          );
      final GameStreamInputComposer composer = GameStreamInputComposer(
        sessionId: 's1',
        clientId: 'c1',
        sender: (_) async => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GameStreamPage(
            sessionId: 's1',
            clientId: 'c1',
            inputComposer: composer,
            lookupController: controller,
            videoPlaceholder: const Text('frame'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('日本語'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('game-stream-segments')),
        findsOneWidget,
      );
      final ActionChip chip = tester.widget<ActionChip>(
        find.byType(ActionChip).first,
      );
      final String selected = (chip.label as Text).data!;
      await tester.tap(find.byType(ActionChip).first);
      await tester.pumpAndSettle();
      expect(lookup.terms, <String>[selected]);
    },
  );

  testWidgets('session key mapping sends matching key down and up', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          videoPlaceholder: const Text('frame'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.game_stream_keys));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('game-stream-binding-up')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter').last);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text(t.game_stream_keys_hint))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent event) => event.kind),
      <GameStreamInputKind>[GameStreamInputKind.key, GameStreamInputKind.key],
    );
    expect(sent.map((GameStreamInputEvent event) => event.key), <String>[
      'Enter',
      'Enter',
    ]);
    expect(
      sent.map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.up,
      ],
    );
  });

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

class _Lookup implements GameStreamDictionaryLookup {
  final List<String> terms = <String>[];

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    terms.add(term);
    return null;
  }
}

class _Transport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => const GameStreamPostResult(json: null);
}
