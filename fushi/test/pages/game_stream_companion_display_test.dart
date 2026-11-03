import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/game_stream_companion_page.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/platform/game_stream_companion_display_channel.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:material_ui/material_ui.dart';

const GameStreamCompanionDisplayInfo _bottomScreen =
    GameStreamCompanionDisplayInfo(
      id: 2,
      name: 'Bottom',
      width: 1240,
      height: 1080,
    );

/// Stands in for the Android channel: show() brings the panel up at once.
class _FakeCompanionDisplay implements GameStreamCompanionDisplay {
  _FakeCompanionDisplay({List<GameStreamCompanionDisplayInfo>? displays})
    : _displays = ValueNotifier<List<GameStreamCompanionDisplayInfo>>(
        displays ?? const <GameStreamCompanionDisplayInfo>[_bottomScreen],
      );

  final ValueNotifier<List<GameStreamCompanionDisplayInfo>> _displays;
  final ValueNotifier<bool> _attached = ValueNotifier<bool>(false);
  final StreamController<GameStreamCompanionMessage> _messages =
      StreamController<GameStreamCompanionMessage>.broadcast();
  final List<int> shown = <int>[];
  int dismissed = 0;
  final List<GameStreamCompanionHostMessage> sent =
      <GameStreamCompanionHostMessage>[];

  @override
  ValueListenable<List<GameStreamCompanionDisplayInfo>> get displays =>
      _displays;

  @override
  ValueListenable<bool> get attached => _attached;

  @override
  Stream<GameStreamCompanionMessage> get messages => _messages.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> show(int displayId) async {
    shown.add(displayId);
    _attached.value = true;
  }

  @override
  Future<void> dismiss() async {
    dismissed++;
    _attached.value = false;
  }

  @override
  Future<void> send(GameStreamCompanionHostMessage message) async {
    // Round-trip through the wire format, as the real channel does.
    sent.add(GameStreamCompanionHostMessage.decode(message.encode()));
  }

  void fromCompanion(GameStreamCompanionMessage message) =>
      _messages.add(GameStreamCompanionMessage.decode(message.encode()));

  void setDisplays(List<GameStreamCompanionDisplayInfo> displays) =>
      _displays.value = displays;

  /// The panel went away on its own (crash, closed itself, Activity torn
  /// down), with the display still there.
  void losePanel() => _attached.value = false;

  GameStreamCompanionState get lastState =>
      sent.whereType<GameStreamCompanionState>().last;

  @override
  void dispose() {}
}

class _Lookup implements GameStreamDictionaryLookup {
  final List<String> terms = <String>[];

  @override
  DictionaryPopupResourceSource? get popupResources => null;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    terms.add(term);
    return DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: term, reading: term, meaning: 'cat'),
      ],
    );
  }
}

class _Transport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => GameStreamPostResult(
    json: path.endsWith('/mine')
        ? <String, dynamic>{
            'result': <String, dynamic>{
              'version': kGameStreamWireVersion,
              'ok': true,
            },
          }
        : null,
  );
}

class _Harness {
  _Harness(this.tester, this.display, this.lookup, this.controller, this.sent);

  final WidgetTester tester;
  final _FakeCompanionDisplay display;
  final _Lookup lookup;
  final GameStreamLookupController controller;
  final List<GameStreamInputEvent> sent;
  GameStreamSecondScreen? savedSecondScreen;

  static Future<_Harness> pump(
    WidgetTester tester, {
    _FakeCompanionDisplay? display,
    GameStreamSecondScreen secondScreen = GameStreamSecondScreen.auto,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeCompanionDisplay fake = display ?? _FakeCompanionDisplay();
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
            text: '猫がいる',
            timestampMs: 1,
          ),
        );
    addTearDown(controller.dispose);
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );
    addTearDown(composer.dispose);
    final _Harness harness = _Harness(tester, fake, lookup, controller, sent);
    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          lookupController: controller,
          videoPlaceholder: const Text('frame'),
          companionDisplay: fake,
          secondScreen: secondScreen,
          onSecondScreenChanged: (GameStreamSecondScreen value) =>
              harness.savedSecondScreen = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  Future<void> press(LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(key, platform: 'android');
    await tester.sendKeyUpEvent(key, platform: 'android');
    await tester.pumpAndSettle();
  }

  Future<void> fromCompanion(GameStreamCompanionMessage message) async {
    display.fromCompanion(message);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('with a second display the video fills the page and the line '
      'goes to the panel', (WidgetTester tester) async {
    final _Harness h = await _Harness.pump(tester);
    expect(h.display.shown, <int>[_bottomScreen.id]);
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
    expect(find.byKey(GameStreamPage.dictionaryKey), findsNothing);
    expect(
      tester.getSize(find.byKey(GameStreamPage.videoKey)).width,
      1280,
      reason: 'No rail beside the video',
    );
    expect(h.display.lastState.lineId, 'line-1');
    expect(h.display.lastState.lineText, '猫がいる');
    expect(h.display.lastState.mode, GameStreamInputMode.game);
    expect(
      h.display.sent.whereType<GameStreamCompanionResult>().single.resultJson,
      isNull,
    );
  });

  testWidgets('a tap on the panel looks up; the result is pushed', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    await h.fromCompanion(
      const GameStreamCompanionLookupAt(lineId: 'line-1', index: 2),
    );
    expect(h.lookup.terms, <String>['いる']);
    final GameStreamCompanionResult result = h.display.sent
        .whereType<GameStreamCompanionResult>()
        .last;
    expect(result.resultJson, contains('いる'));
    expect(h.display.lastState.highlightStart, 2);

    // A tap on a line that is no longer current does nothing.
    await h.fromCompanion(
      const GameStreamCompanionLookupAt(lineId: 'old', index: 0),
    );
    expect(h.lookup.terms, <String>['いる']);
  });

  testWidgets('controller buttons still reach the game and drive the panel', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    await h.press(LogicalKeyboardKey.gameButtonA);
    expect(h.sent.map((GameStreamInputEvent e) => e.button), <String?>[
      'confirm',
      'confirm',
    ]);
    // The main screen shows the mode once a controller is used.
    expect(find.byKey(GameStreamPage.modeChipKey), findsOneWidget);

    await h.press(LogicalKeyboardKey.gameButtonSelect);
    expect(h.display.lastState.mode, GameStreamInputMode.lookup);
    expect(h.display.lastState.caret, 0);
    await h.press(LogicalKeyboardKey.arrowRight);
    expect(h.display.lastState.caret, 1);
    await h.press(LogicalKeyboardKey.gameButtonA);
    expect(h.lookup.terms, <String>['がいる']);

    // The dictionary lives in the panel: its buttons become commands.
    await h.press(LogicalKeyboardKey.arrowDown);
    await h.press(LogicalKeyboardKey.gameButtonY);
    await h.press(LogicalKeyboardKey.gameButtonX);
    await h.press(LogicalKeyboardKey.arrowUp);
    expect(
      h.display.sent.whereType<GameStreamCompanionCommand>().map(
        (GameStreamCompanionCommand c) => c.command,
      ),
      <GameStreamCompanionDictionaryCommand>[
        GameStreamCompanionDictionaryCommand.entryNext,
        GameStreamCompanionDictionaryCommand.mineFirstVisible,
        GameStreamCompanionDictionaryCommand.playFirstVisibleAudio,
        GameStreamCompanionDictionaryCommand.entryPrevious,
      ],
    );

    // The panel's chip switches back.
    await h.fromCompanion(
      const GameStreamCompanionSetMode(GameStreamInputMode.game),
    );
    expect(h.display.lastState.mode, GameStreamInputMode.game);
  });

  testWidgets('the panel\'s requests are answered', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    await h.fromCompanion(
      const GameStreamCompanionLookupAt(lineId: 'line-1', index: 0),
    );
    await h.fromCompanion(
      const GameStreamCompanionMineRequest(
        id: 41,
        fields: <String, String>{'Word': '猫'},
      ),
    );
    await h.fromCompanion(
      const GameStreamCompanionAudioRequest(
        id: 42,
        expression: '猫',
        reading: 'ねこ',
      ),
    );
    final Map<int, Object?> replies = <int, Object?>{
      for (final GameStreamCompanionReply reply
          in h.display.sent.whereType<GameStreamCompanionReply>())
        reply.id: reply.value,
    };
    expect(replies[41], GameStreamCompanionMineOutcome.ok.name);
    expect(replies.containsKey(42), isTrue);
    expect(replies[42], isNull, reason: 'No host audio source in this test');
    expect(h.display.lastState.mineFailed, isFalse);
    expect(h.display.lastState.mineMessage, isNotNull);
  });

  testWidgets('a fresh panel gets everything again', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    final int before = h.display.sent.length;
    await h.fromCompanion(const GameStreamCompanionReady());
    final List<GameStreamCompanionHostMessage> resent = h.display.sent.sublist(
      before,
    );
    expect(resent.whereType<GameStreamCompanionState>(), hasLength(1));
    expect(resent.whereType<GameStreamCompanionResult>(), hasLength(1));
  });

  testWidgets('losing the display brings the inline rail back', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
    h.display.setDisplays(const <GameStreamCompanionDisplayInfo>[]);
    await tester.pumpAndSettle();
    expect(h.display.dismissed, 1);
    expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);

    // Plugged back in: the panel returns.
    h.display.setDisplays(const <GameStreamCompanionDisplayInfo>[
      _bottomScreen,
    ]);
    await tester.pumpAndSettle();
    expect(h.display.shown, <int>[_bottomScreen.id, _bottomScreen.id]);
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
  });

  testWidgets('a panel that went away on its own is shown again', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    expect(h.display.shown, <int>[_bottomScreen.id]);
    h.display.losePanel();
    await tester.pumpAndSettle();
    expect(h.display.shown, <int>[
      _bottomScreen.id,
      _bottomScreen.id,
    ], reason: 'The same display is still there and the setting is Auto');
    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
  });

  testWidgets('without a second display nothing changes', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(
      tester,
      display: _FakeCompanionDisplay(
        displays: const <GameStreamCompanionDisplayInfo>[],
      ),
    );
    expect(h.display.shown, isEmpty);
    expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);
    expect(h.display.sent, isEmpty);
  });

  testWidgets('setting Off keeps everything on this screen and is saved', (
    WidgetTester tester,
  ) async {
    final _Harness off = await _Harness.pump(
      tester,
      secondScreen: GameStreamSecondScreen.off,
    );
    expect(off.display.shown, isEmpty);
    expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);
  });

  testWidgets('the controls sheet switches the second screen off', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    await tester.tap(find.byTooltip(t.game_stream_keys));
    await tester.pumpAndSettle();
    expect(find.byKey(GameStreamPage.secondScreenKey), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(GameStreamPage.secondScreenKey),
        matching: find.text(t.game_stream_second_screen_off),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.savedSecondScreen, GameStreamSecondScreen.off);
    expect(h.display.dismissed, 1);
    expect(h.display.shown, <int>[
      _bottomScreen.id,
    ], reason: 'The dismissal is not mistaken for a lost panel');
  });

  group('companion panel', () {
    testWidgets('shows the pushed line and sends taps and mode changes back', (
      WidgetTester tester,
    ) async {
      final List<GameStreamCompanionMessage> sent =
          <GameStreamCompanionMessage>[];
      final GameStreamCompanionController controller =
          GameStreamCompanionController(
            send: (String raw) async =>
                sent.add(GameStreamCompanionMessage.decode(raw)),
          );
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(1240, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: GameStreamCompanionPage(controller: controller)),
      );
      controller.link.receive(
        const GameStreamCompanionState(
          lineId: 'line-1',
          lineText: '猫がいる',
          controllerUsed: true,
        ).encode(),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(GameStreamCompanionPage.lineTextKey), findsOneWidget);
      expect(find.byKey(GameStreamCompanionPage.modeChipKey), findsOneWidget);

      // The first glyph (the text box is wider than the short line).
      final Finder line = find.byKey(GameStreamCompanionPage.lineTextKey);
      await tester.tapAt(
        tester.getTopLeft(line) + Offset(6, tester.getSize(line).height / 2),
      );
      await tester.pumpAndSettle();
      final GameStreamCompanionLookupAt tap = sent
          .whereType<GameStreamCompanionLookupAt>()
          .single;
      expect((tap.lineId, tap.index), ('line-1', 0));

      await tester.tap(find.byKey(GameStreamCompanionPage.modeChipKey));
      await tester.pumpAndSettle();
      expect(
        sent.whereType<GameStreamCompanionSetMode>().single.mode,
        GameStreamInputMode.lookup,
      );
    });

    testWidgets(
      'a cleared result shows the hint, results replace by revision',
      (WidgetTester tester) async {
        final GameStreamCompanionController controller =
            GameStreamCompanionController(send: (String raw) async {});
        addTearDown(controller.dispose);
        controller.link.receive(
          GameStreamCompanionResult(
            revision: 1,
            resultJson: DictionarySearchResult(searchTerm: '猫').toJson(),
            popupJson: '[]',
            dictionaryStyles: const <String, String>{'D': 'a{}'},
          ).encode(),
        );
        expect(controller.result?.searchTerm, '猫');
        expect(controller.result?.popupJson, '[]');
        expect(controller.resources.dictionaryStyles, <String, String>{
          'D': 'a{}',
        });
        // A repeat of the same revision is ignored.
        controller.link.receive(
          const GameStreamCompanionResult(revision: 1).encode(),
        );
        expect(controller.result, isNotNull);
        controller.link.receive(
          const GameStreamCompanionResult(revision: 2).encode(),
        );
        expect(controller.result, isNull);
      },
    );
  });
}
