import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

GameStreamCompanionHostMessage _hostRoundTrip(
  GameStreamCompanionHostMessage message,
) => GameStreamCompanionHostMessage.decode(message.encode());

GameStreamCompanionMessage _roundTrip(GameStreamCompanionMessage message) =>
    GameStreamCompanionMessage.decode(message.encode());

void main() {
  group('host messages', () {
    test('state round-trips every field and compares by value', () {
      const GameStreamCompanionState state = GameStreamCompanionState(
        lineId: 'l1',
        lineText: '猫がいる',
        caret: 2,
        highlightStart: 1,
        highlightCount: 2,
        mode: GameStreamInputMode.lookup,
        controllerUsed: true,
        searching: true,
        error: 'offline',
        mineMessage: 'Card added',
        mineFailed: true,
      );
      final GameStreamCompanionHostMessage decoded = _hostRoundTrip(state);
      expect(decoded, state);
      expect((decoded as GameStreamCompanionState).highlight, (
        start: 1,
        count: 2,
      ));
      expect(
        _hostRoundTrip(const GameStreamCompanionState()),
        const GameStreamCompanionState(),
      );
      expect(
        const GameStreamCompanionState(caret: 1),
        isNot(const GameStreamCompanionState(caret: 2)),
      );
    });

    test('result, command and reply round-trip', () {
      final GameStreamCompanionResult result =
          _hostRoundTrip(
                const GameStreamCompanionResult(
                  revision: 3,
                  resultJson: '{"searchTerm":"猫"}',
                  popupJson: '[]',
                  dictionaryStyles: <String, String>{'JMdict': 'b{}'},
                ),
              )
              as GameStreamCompanionResult;
      expect(result.revision, 3);
      expect(result.resultJson, '{"searchTerm":"猫"}');
      expect(result.popupJson, '[]');
      expect(result.dictionaryStyles, <String, String>{'JMdict': 'b{}'});

      final GameStreamCompanionResult cleared =
          _hostRoundTrip(const GameStreamCompanionResult(revision: 4))
              as GameStreamCompanionResult;
      expect(cleared.resultJson, isNull);
      expect(cleared.dictionaryStyles, isEmpty);

      for (final GameStreamCompanionDictionaryCommand command
          in GameStreamCompanionDictionaryCommand.values) {
        expect(
          (_hostRoundTrip(GameStreamCompanionCommand(command))
                  as GameStreamCompanionCommand)
              .command,
          command,
        );
      }

      final GameStreamCompanionReply reply =
          _hostRoundTrip(
                const GameStreamCompanionReply(
                  id: 7,
                  value: <String, Object?>{'a': 1},
                ),
              )
              as GameStreamCompanionReply;
      expect(reply.id, 7);
      expect(reply.value, <String, Object?>{'a': 1});
    });

    test('malformed input is rejected, not guessed', () {
      expect(
        () => GameStreamCompanionHostMessage.decode('[1]'),
        throwsFormatException,
      );
      expect(
        () => GameStreamCompanionHostMessage.decode('{"type":"nope"}'),
        throwsFormatException,
      );
      expect(
        () => GameStreamCompanionHostMessage.decode('{"type":"result"}'),
        throwsFormatException,
      );
      expect(
        () => GameStreamCompanionHostMessage.decode(
          '{"type":"command","command":"explode"}',
        ),
        throwsFormatException,
      );
    });
  });

  group('companion messages', () {
    test('every message round-trips', () {
      expect(
        _roundTrip(const GameStreamCompanionReady()),
        isA<GameStreamCompanionReady>(),
      );
      final GameStreamCompanionLookupAt at =
          _roundTrip(const GameStreamCompanionLookupAt(lineId: 'l', index: 4))
              as GameStreamCompanionLookupAt;
      expect((at.lineId, at.index), ('l', 4));
      expect(
        (_roundTrip(const GameStreamCompanionLookupText('犬'))
                as GameStreamCompanionLookupText)
            .text,
        '犬',
      );
      expect(
        (_roundTrip(
                  const GameStreamCompanionSetMode(GameStreamInputMode.lookup),
                )
                as GameStreamCompanionSetMode)
            .mode,
        GameStreamInputMode.lookup,
      );
      final GameStreamCompanionMineRequest mine =
          _roundTrip(
                const GameStreamCompanionMineRequest(
                  id: 1,
                  fields: <String, String>{'Word': '猫'},
                ),
              )
              as GameStreamCompanionMineRequest;
      expect(mine.id, 1);
      expect(mine.fields, <String, String>{'Word': '猫'});
      final GameStreamCompanionDuplicateRequest duplicate =
          _roundTrip(
                const GameStreamCompanionDuplicateRequest(
                  id: 2,
                  expression: '猫',
                  reading: 'ねこ',
                ),
              )
              as GameStreamCompanionDuplicateRequest;
      expect(
        (duplicate.id, duplicate.expression, duplicate.reading),
        (2, '猫', 'ねこ'),
      );
      final GameStreamCompanionMediaRequest media =
          _roundTrip(
                const GameStreamCompanionMediaRequest(
                  id: 3,
                  dictionary: 'D',
                  path: 'img/a.png',
                ),
              )
              as GameStreamCompanionMediaRequest;
      expect((media.id, media.dictionary, media.path), (3, 'D', 'img/a.png'));
      final GameStreamCompanionAudioRequest audio =
          _roundTrip(
                const GameStreamCompanionAudioRequest(
                  id: 4,
                  expression: '猫',
                  reading: 'ねこ',
                ),
              )
              as GameStreamCompanionAudioRequest;
      expect((audio.id, audio.expression, audio.reading), (4, '猫', 'ねこ'));
    });

    test('a request without its id is rejected', () {
      expect(
        () => GameStreamCompanionMessage.decode('{"type":"mine","fields":{}}'),
        throwsFormatException,
      );
    });

    test('mine outcome reads unknown values as an error', () {
      expect(
        GameStreamCompanionMineOutcome.fromValue('duplicate'),
        GameStreamCompanionMineOutcome.duplicate,
      );
      expect(
        GameStreamCompanionMineOutcome.fromValue(null),
        GameStreamCompanionMineOutcome.error,
      );
    });
  });

  group('GameStreamCompanionLink', () {
    test('matches replies to requests and forwards other messages', () async {
      final List<String> sent = <String>[];
      final List<GameStreamCompanionHostMessage> received =
          <GameStreamCompanionHostMessage>[];
      final GameStreamCompanionLink link = GameStreamCompanionLink(
        send: (String raw) async => sent.add(raw),
        onHostMessage: received.add,
      );
      final Future<GameStreamCompanionMineOutcome> mine = link.mine(
        <String, String>{'Word': '猫'},
      );
      final Future<bool> duplicate = link.isDuplicate('猫', 'ねこ');
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(2));
      final GameStreamCompanionMineRequest mineRequest =
          GameStreamCompanionMessage.decode(sent[0])
              as GameStreamCompanionMineRequest;
      final GameStreamCompanionDuplicateRequest duplicateRequest =
          GameStreamCompanionMessage.decode(sent[1])
              as GameStreamCompanionDuplicateRequest;
      // Out of order on purpose.
      link.receive(
        GameStreamCompanionReply(id: duplicateRequest.id, value: true).encode(),
      );
      link.receive(
        GameStreamCompanionReply(
          id: mineRequest.id,
          value: GameStreamCompanionMineOutcome.duplicate.name,
        ).encode(),
      );
      expect(await duplicate, isTrue);
      expect(await mine, GameStreamCompanionMineOutcome.duplicate);

      link.receive(const GameStreamCompanionState(lineId: 'x').encode());
      expect(received.single, const GameStreamCompanionState(lineId: 'x'));
    });

    test('closing fails pending requests instead of hanging', () async {
      final GameStreamCompanionLink link = GameStreamCompanionLink(
        send: (String raw) async {},
        onHostMessage: (_) {},
      );
      final Future<bool> pending = link.isDuplicate('a', 'b');
      await Future<void>.delayed(Duration.zero);
      link.close();
      await expectLater(pending, throwsStateError);
    });

    test('a failed send fails the request', () async {
      final GameStreamCompanionLink link = GameStreamCompanionLink(
        send: (String raw) async => throw StateError('no channel'),
        onHostMessage: (_) {},
      );
      await expectLater(link.isDuplicate('a', 'b'), throwsStateError);
    });
  });

  group('relayed popup resources', () {
    test('styles change identity only when their content changes', () {
      final GameStreamCompanionResources resources =
          GameStreamCompanionResources(
            GameStreamCompanionLink(
              send: (String raw) async {},
              onHostMessage: (_) {},
            ),
          );
      resources.updateStyles(<String, String>{'D': 'a{}'});
      final Map<String, String> first = resources.dictionaryStyles;
      resources.updateStyles(<String, String>{'D': 'a{}'});
      expect(identical(resources.dictionaryStyles, first), isTrue);
      resources.updateStyles(<String, String>{'D': 'b{}'});
      expect(identical(resources.dictionaryStyles, first), isFalse);
    });

    test('media and audio are fetched through the link', () async {
      late GameStreamCompanionLink link;
      link = GameStreamCompanionLink(
        send: (String raw) async {
          final GameStreamCompanionMessage message =
              GameStreamCompanionMessage.decode(raw);
          final Object? value = switch (message) {
            GameStreamCompanionMediaRequest() => encodeGameStreamCompanionMedia(
              DictionaryPopupMedia(
                bytes: Uint8List.fromList(<int>[1, 2, 3]),
                contentType: 'image/png',
              ),
            ),
            GameStreamCompanionAudioRequest() => 'https://host/a.mp3',
            _ => null,
          };
          link.receive(
            GameStreamCompanionReply(
              id: (message as GameStreamCompanionRequest).id,
              value: value,
            ).encode(),
          );
        },
        onHostMessage: (_) {},
      );
      final GameStreamCompanionResources resources =
          GameStreamCompanionResources(link);
      final DictionaryPopupMedia? media = await resources.mediaFile('D', 'p');
      expect(media?.bytes, <int>[1, 2, 3]);
      expect(media?.contentType, 'image/png');
      expect(await resources.wordAudioRef('猫', 'ねこ'), 'https://host/a.mp3');
    });

    test('missing media encodes to null and back', () {
      expect(encodeGameStreamCompanionMedia(null), isNull);
      expect(decodeGameStreamCompanionMedia(null), isNull);
    });
  });

  group('pipe', () {
    late Directory spill;
    setUp(() async {
      spill = await Directory.systemTemp.createTemp('gsc');
    });
    tearDown(() => GameStreamCompanionPipe.clearSpills(spill));

    test('a message too big for one Binder transaction crosses as a file, '
        'in order, and the file is removed once read', () async {
      final List<String> wire = <String>[];
      final GameStreamCompanionPipe sender = GameStreamCompanionPipe(
        post: (String raw) async {
          wire.add(raw);
          return true;
        },
        spillDirectory: Directory('${spill.path}/host'),
        inlineLimit: 16,
      );
      final String big = '{"type":"result","x":"${'猫' * 64}"}';
      await sender.send('{"a":1}');
      await sender.send(big);
      await sender.send('{"b":2}');
      expect(wire[0], '{"a":1}');
      expect(wire[1].length, lessThan(big.length));
      expect(Directory('${spill.path}/host').listSync(), hasLength(1));

      final GameStreamCompanionPipe receiver = GameStreamCompanionPipe(
        post: (String raw) async => true,
        spillDirectory: Directory('${spill.path}/panel'),
      );
      final List<String> received = <String>[];
      final Completer<void> done = Completer<void>();
      for (final String raw in wire) {
        receiver.receive(raw, (String message) {
          received.add(message);
          if (received.length == 3) done.complete();
        }, (Object error, StackTrace stack) => done.completeError(error));
      }
      await done.future;
      expect(received, <String>['{"a":1}', big, '{"b":2}']);
      expect(Directory('${spill.path}/host').listSync(), isEmpty);
    });

    test('the default limit keeps a 256 KB image off the Binder buffer', () {
      // base64 of 256 KB is ~350K UTF-16 units, ~700 KB in a Bundle: more
      // than a oneway transaction's async buffer.
      final String reply = GameStreamCompanionReply(
        id: 1,
        value: encodeGameStreamCompanionMedia(
          DictionaryPopupMedia(
            bytes: Uint8List(256 * 1024),
            contentType: 'image/png',
          ),
        ),
      ).encode();
      expect(reply.length, greaterThan(kGameStreamCompanionInlineMessageUnits));
      expect(kGameStreamCompanionInlineMessageUnits * 2, lessThan(256 * 1024));
    });

    test('a message the relay did not take fails the send and its '
        'request', () async {
      final GameStreamCompanionPipe pipe = GameStreamCompanionPipe(
        post: (String raw) async => false,
        spillDirectory: spill,
        inlineLimit: 4,
      );
      await expectLater(pipe.send('{"type":"x"}'), throwsStateError);
      expect(spill.listSync(), isEmpty, reason: 'The spilled copy is gone');

      final GameStreamCompanionLink link = GameStreamCompanionLink(
        send: pipe.send,
        onHostMessage: (_) {},
      );
      await expectLater(link.isDuplicate('a', 'b'), throwsStateError);
    });

    test('clearing the spill root removes unread messages', () async {
      final GameStreamCompanionPipe pipe = GameStreamCompanionPipe(
        post: (String raw) async => true,
        spillDirectory: Directory('${spill.path}/panel'),
        inlineLimit: 4,
      );
      await pipe.send('{"type":"unread"}');
      expect(Directory('${spill.path}/panel').listSync(), hasLength(1));
      await GameStreamCompanionPipe.clearSpills(spill);
      expect(spill.existsSync(), isFalse);
    });
  });

  group('second screen preference', () {
    test('unknown names read as auto', () {
      expect(
        GameStreamSecondScreen.fromName('off'),
        GameStreamSecondScreen.off,
      );
      expect(
        GameStreamSecondScreen.fromName('auto'),
        GameStreamSecondScreen.auto,
      );
      expect(
        GameStreamSecondScreen.fromName('future'),
        GameStreamSecondScreen.auto,
      );
      expect(
        GameStreamSecondScreen.fromName(null),
        GameStreamSecondScreen.auto,
      );
    });

    test('persists through preferences and stays on this device', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      expect(prefs.gameStreamSecondScreen, GameStreamSecondScreen.auto);
      await prefs.setGameStreamSecondScreen(GameStreamSecondScreen.off);
      prefs.dispose();

      final PreferencesRepository reopened = PreferencesRepository(db);
      await reopened.loadFromDb();
      addTearDown(reopened.dispose);
      expect(reopened.gameStreamSecondScreen, GameStreamSecondScreen.off);
      expect(
        SyncRepository.deviceLocalPrefKeys,
        contains(kGameStreamSecondScreenPrefKey),
      );
    });
  });
}
