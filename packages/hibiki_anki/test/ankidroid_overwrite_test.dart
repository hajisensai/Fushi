import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-270 B/C2：AnkiDroid 后端「制卡返回真 noteId + 按 id 覆盖已有卡片」契约。
//
// host 无真 AnkiDroid，故 mock 平台通道 `app.hibiki.reader/anki`，断言：
//  (B)  mineEntry 把 native addNote 返回的 note id 带回 MineOutcome.noteId
//       （旧版返回字符串/true 时优雅降级为 null）。
//  (C2) updateMinedNote 经 `updateNoteFields` 按 id 覆盖渲染后的字段、返回 noteId；
//       渲染为空时拒绝（不清空卡片）；低层 updateNoteFields / notesInfo 透传正确。
//
// 与 AnkiConnect 侧 ankiconnect_create_test / mining_tag_and_parallel_test 的
// MockClient 范式对称（这里用 setMockMethodCallHandler 替代）。

const MethodChannel _channel = MethodChannel('app.hibiki.reader/anki');

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings({bool allowDupes = true}) => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Hibiki',
          fields: <String>['Expression', 'Reading'],
        ),
      ],
      fieldMappings: const <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
      },
      allowDupes: allowDupes,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

/// Installs a mock handler that delegates each method to [responder], records
/// every (method, arguments) call into [calls], and tears itself down.
void _mockChannel(
  List<MethodCall> calls,
  Future<Object?> Function(MethodCall call) responder,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) async {
    calls.add(call);
    return responder(call);
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TODO-270 B: mineEntry returns the real AnkiDroid note id', () {
    test('addNote returning an int id surfaces it on MineOutcome.noteId',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addNote':
            return 1654000000123; // AnkiDroid epoch-ms note id (Long).
          default:
            fail('unexpected channel call: ${call.method}');
        }
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 1654000000123);
    });

    test('legacy native addNote (string "Added note") degrades to noteId=null',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addNote':
            return 'Added note'; // Pre-TODO-270 native return.
          default:
            fail('unexpected channel call: ${call.method}');
        }
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, isNull);
    });

    test('native addNote returning true (test stubs) degrades to null',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        if (call.method == 'checkForDuplicates') return false;
        if (call.method == 'addNote') return true;
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, isNull);
    });
  });

  group('TODO-270 C2: updateMinedNote overwrites by id', () {
    test('renders fields and calls updateNoteFields with the note id',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        if (call.method == 'updateNoteFields') return null;
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.updateMinedNote(
        noteId: 42,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 42);
      // Exactly one channel call: the overwrite. No addNote, no dupe check.
      expect(calls.map((c) => c.method), <String>['updateNoteFields']);
      final args = Map<String, dynamic>.from(calls.single.arguments as Map);
      expect(args['noteId'], 42);
      final fieldValues = Map<String, String>.from(args['fieldValues'] as Map);
      // Both mapped fields rendered from the payload.
      expect(fieldValues['Expression'], '勉強');
      expect(fieldValues['Reading'], 'べんきょう');
    });

    test('empty render is refused (does not clear the existing card)',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        fail('no channel call expected when render is empty: ${call.method}');
      });

      // No field mappings -> buildMinedFields yields an empty map.
      final repo = _ConfiguredAnkiRepository(_settings().copyWith(
        fieldMappings: const <String, String>{},
      ));
      final outcome = await repo.updateMinedNote(
        noteId: 42,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorDetail, contains('refusing to clear'));
      expect(calls, isEmpty);
    });

    test('a PlatformException from the channel becomes MineResult.error',
        () async {
      _mockChannel(<MethodCall>[], (call) async {
        throw PlatformException(code: 'UPDATE_NOTE_FAILED', message: 'gone');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.updateMinedNote(
        noteId: 42,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorDetail, contains('gone'));
    });
  });

  group('TODO-270 C2: low-level updateNoteFields / notesInfo passthrough', () {
    test('updateNoteFields forwards noteId + fieldValues to the channel',
        () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        if (call.method == 'updateNoteFields') return null;
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      await repo.updateNoteFields(7, <String, String>{'Expression': 'x'});

      final args = Map<String, dynamic>.from(calls.single.arguments as Map);
      expect(args['noteId'], 7);
      expect(Map<String, String>.from(args['fieldValues'] as Map),
          <String, String>{'Expression': 'x'});
    });

    test('notesInfo maps the channel name->value map', () async {
      _mockChannel(<MethodCall>[], (call) async {
        if (call.method == 'notesInfo') {
          return <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'};
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final info = await repo.notesInfo(7);

      expect(info, <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'});
    });

    test('notesInfo returns null when the note does not exist', () async {
      _mockChannel(<MethodCall>[], (call) async {
        if (call.method == 'notesInfo') return null;
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      expect(await repo.notesInfo(404), isNull);
    });
  });
}
