import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
  testWidgets('video cancel releases the active pointer at its last position', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPointerPage(tester, sent);
    final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
    final Offset start = video.topLeft + Offset(video.width / 2, 100);
    final TestGesture primary = await tester.startGesture(start, pointer: 1);
    final TestGesture secondary = await tester.startGesture(
      start + const Offset(30, 10),
      pointer: 2,
    );
    await secondary.moveBy(const Offset(10, 10));
    await secondary.up();
    await primary.moveBy(const Offset(15, 10));
    await primary.cancel();
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.move,
        GameStreamInputAction.up,
      ],
    );
    expect(sent.last.x, sent[1].x);
    expect(sent.last.y, sent[1].y);
  });

  testWidgets('removing the video releases a held pointer once', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPointerPage(tester, sent);
    final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
    final TestGesture pointer = await tester.startGesture(
      video.topLeft + Offset(video.width / 2, 100),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pointer.cancel();
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.up,
      ],
    );
    expect(sent.last.x, sent.first.x);
    expect(sent.last.y, sent.first.y);
  });

  testWidgets('lookup layout changes release an active drag before remapping', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPointerPage(tester, sent);
    final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
    final TestGesture pointer = await tester.startGesture(
      video.topLeft + Offset(video.width / 2, 100),
    );
    await tester.tap(find.byTooltip(t.game_stream_lookup_toggle));
    await tester.pumpAndSettle();
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
    expect(sent.last.action, GameStreamInputAction.up);
    expect(sent.last.x, sent.first.x);
    expect(sent.last.y, sent.first.y);
    await pointer.moveBy(const Offset(20, 0));
    await pointer.up();
    await tester.pump();
    expect(sent.length, 2, reason: 'The abandoned gesture cannot inject again');
  });

  testWidgets('rotation metrics release a pointer without an app pause', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPointerPage(tester, sent);
    final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
    final TestGesture pointer = await tester.startGesture(
      video.topLeft + Offset(video.width / 2, 100),
    );
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    await pointer.cancel();
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.up,
      ],
    );
    expect(sent.last.x, sent.first.x);
    expect(sent.last.y, sent.first.y);
  });

  testWidgets('focused gamepad holds input and releases on focus loss', (
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
          videoPlaceholder: const Text('frame'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('A'))).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[GameStreamInputAction.down],
    );
    expect(sent.single.button, 'confirm');
    Focus.of(tester.element(find.text('B'))).requestFocus();
    await tester.pump();
    expect(sent.last.action, GameStreamInputAction.up);
    expect(sent.last.button, 'confirm');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent.length, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      sent.skip(2).map((GameStreamInputEvent event) => event.action),
      <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.up,
      ],
    );
    expect(sent.last.button, 'cancel');
  });

  testWidgets('old transcript cannot look up after same-line text changes', (
    WidgetTester tester,
  ) async {
    final _Lookup lookup = _Lookup();
    final GameStreamLookupController controller = GameStreamLookupController(
      lookupClient: lookup,
      streamClient: FushiGameStreamClient(transport: _Transport()),
      clientId: 'c1',
    );
    addTearDown(controller.dispose);
    void apply(String text) => controller.applyTextEvent(
      GameStreamTextEvent(
        sessionId: 's1',
        lineId: 'progressive-line',
        text: text,
        timestampMs: 1,
      ),
    );
    apply('日本');
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (_) async => null,
    );
    addTearDown(composer.dispose);
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
    final Finder paragraph = find.byKey(GameStreamPage.transcriptTextKey);
    Focus.of(tester.element(paragraph)).requestFocus();
    await tester.pump();
    apply('日本語');
    // No frame has rebuilt the paragraph: a real key event still reaches its
    // old callback while the controller already owns the progressive update.
    expect(tester.widget<RichText>(paragraph).text.toPlainText(), '日本');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(lookup.terms, isEmpty);
    expect(controller.selectedTerm, isNull);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(lookup.terms, <String>['日本語']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final Size viewport in <Size>[
    const Size(800, 600),
    const Size(400, 800),
  ]) {
    testWidgets(
      'shared transcript caret queries suffixes without a local dictionary at $viewport',
      (WidgetTester tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final _Lookup lookup = _Lookup();
        expect(FushiDicts.isInitialized, isFalse);
        final GameStreamLookupController controller =
            GameStreamLookupController(
              lookupClient: lookup,
              streamClient: FushiGameStreamClient(transport: _Transport()),
              clientId: 'c1',
            )..applyTextEvent(
              GameStreamTextEvent(
                sessionId: 's1',
                lineId: 'line-1',
                text: '😀 日本語と日本語',
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
        expect(find.byType(ActionChip), findsNothing);
        expect(find.byType(SubtitleTranscriptRow), findsOneWidget);
        final Finder paragraph = find.byKey(GameStreamPage.transcriptTextKey);
        expect(
          tester.widget<RichText>(paragraph).text.toPlainText(),
          '😀 日本語と日本語',
        );
        Focus.of(tester.element(paragraph)).requestFocus();
        await tester.pump();
        // Grapheme caret skips the two-unit emoji and the space independently.
        for (int i = 0; i < 2; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(controller.selectedTerm, '日');
        for (int i = 0; i < 4; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          lookup.terms,
          <String>['日本語と日本語', '日本語'],
          reason:
              'The emoji occupies two UTF-16 units; repeated words must not '
              'resolve through indexOf to the first occurrence.',
        );
      },
    );
  }

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

Future<void> _pumpPointerPage(
  WidgetTester tester,
  List<GameStreamInputEvent> sent,
) async {
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
  await tester.pumpAndSettle();
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
