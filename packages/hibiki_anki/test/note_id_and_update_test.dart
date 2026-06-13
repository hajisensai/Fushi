import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-270 A/C1:
//  (A) AnkiConnect addNote already returns the new note id; the repository must
//      thread it into MineOutcome.noteId so callers can later *update* the same
//      card. MineOutcome.success() with no arg must still work (noteId == null)
//      — backward compatible (AnkiDroid does not yet return an id).
//  (C1) New service capability: updateNoteFields (overwrite an existing note's
//      fields by id) and notesInfo (read back current fields). The repository's
//      updateMinedNote reuses the exact same field-render pipeline as mineEntry.

/// Service double that records update/addNote calls and serves canned ids,
/// without opening a socket (extends the real service but overrides the IPC
/// surface used by these tests).
class _RecordingService extends AnkiConnectService {
  _RecordingService({this.addNoteId = 42});

  final int? addNoteId;
  final List<String> storedFilenames = <String>[];
  final List<({int noteId, Map<String, String> fields})> updateCalls =
      <({int noteId, Map<String, String> fields})>[];

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    storedFilenames.add(filename);
  }

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  }) async =>
      addNoteId;

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async =>
      false;

  @override
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    updateCalls.add((noteId: noteId, fields: Map<String, String>.from(fields)));
  }
}

class _ConfiguredRepo extends AnkiConnectRepository {
  _ConfiguredRepo({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings() => const AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(
            id: 2, name: 'Hibiki', fields: <String>['Expression', 'Reading']),
      ],
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
      },
      allowDupes: true,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

void main() {
  // ── service-level request shaping (real IPC envelope via MockClient) ──────

  Future<T> withMock<T>(
    Future<T> Function(AnkiConnectService service) body, {
    required List<http.Request> sink,
    int status = 200,
    Object? result,
    Object? error,
  }) {
    final String responseBody =
        jsonEncode(<String, Object?>{'result': result, 'error': error});
    final client = MockClient((http.Request request) async {
      sink.add(request);
      return http.Response(
        responseBody,
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    return http.runWithClient(
      () => body(AnkiConnectService(host: '127.0.0.1', port: 8765)),
      () => client,
    );
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  group('addNote returns the new note id (task A, service layer)', () {
    test('parses an integer id from the result', () async {
      final issued = <http.Request>[];
      final int? id = await withMock(
        (s) => s.addNote(
          deckName: 'D',
          modelName: 'M',
          fields: const <String, String>{'F': 'v'},
        ),
        sink: issued,
        result: 1700000000001,
      );
      expect(id, 1700000000001);
    });
  });

  group('updateNoteFields shaping (task C1, service layer)', () {
    test('posts the updateNoteFields action with {note:{id,fields}}', () async {
      final issued = <http.Request>[];
      await withMock(
        (s) => s.updateNoteFields(
          555,
          const <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'},
        ),
        sink: issued,
        result: null, // updateNoteFields returns null on success
      );
      final body = bodyOf(issued.single);
      expect(body['action'], 'updateNoteFields');
      expect(body['version'], 6);
      final note = (body['params'] as Map)['note'] as Map;
      expect(note['id'], 555);
      expect(note['fields'],
          <String, dynamic>{'Expression': '勉強', 'Reading': 'べんきょう'});
    });

    test('propagates an AnkiConnect error', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock(
          (s) => s.updateNoteFields(1, const <String, String>{'F': 'v'}),
          sink: issued,
          error: 'note was not found: 1',
        ),
        throwsA(isA<AnkiConnectException>()),
      );
    });
  });

  group('notesInfo parsing (task C1, service layer)', () {
    test('posts {notes:[id]} and flattens fields to name->value', () async {
      final issued = <http.Request>[];
      final Map<String, String>? fields = await withMock(
        (s) => s.notesInfo(777),
        sink: issued,
        result: <Map<String, dynamic>>[
          <String, dynamic>{
            'noteId': 777,
            'modelName': 'Hibiki',
            'tags': <String>['hibiki'],
            'fields': <String, dynamic>{
              'Expression': <String, dynamic>{'value': '勉強', 'order': 0},
              'Reading': <String, dynamic>{'value': 'べんきょう', 'order': 1},
            },
          },
        ],
      );
      final body = bodyOf(issued.single);
      expect(body['action'], 'notesInfo');
      expect((body['params'] as Map)['notes'], <int>[777]);
      expect(fields, <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'});
    });

    test('returns null when the note does not exist (empty item)', () async {
      final issued = <http.Request>[];
      final Map<String, String>? fields = await withMock(
        (s) => s.notesInfo(999),
        sink: issued,
        // AnkiConnect returns a list with an empty object for a missing note.
        result: <Map<String, dynamic>>[<String, dynamic>{}],
      );
      expect(fields, isNull);
    });

    test('returns null when the result list is empty', () async {
      final issued = <http.Request>[];
      final Map<String, String>? fields = await withMock(
        (s) => s.notesInfo(999),
        sink: issued,
        result: const <Map<String, dynamic>>[],
      );
      expect(fields, isNull);
    });
  });

  // ── repository-level: noteId threading + updateMinedNote reuse ────────────

  group('mineEntry carries the note id (task A, repository layer)', () {
    test('MineOutcome.noteId == the id addNote returned', () async {
      final service = _RecordingService(addNoteId: 12345);
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 12345);
    });

    test('a null backend id surfaces as noteId == null (still success)',
        () async {
      final service = _RecordingService(addNoteId: null);
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, isNull);
    });
  });

  group('updateMinedNote reuses the field render (task C1, repository layer)',
      () {
    test('renders fields like mineEntry and calls updateNoteFields by id',
        () async {
      final service = _RecordingService();
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.updateMinedNote(
        noteId: 888,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 888);
      expect(service.updateCalls, hasLength(1));
      final call = service.updateCalls.single;
      expect(call.noteId, 888);
      // Same field rendering pipeline as mineEntry (handlebar mappings applied).
      expect(call.fields,
          <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'});
    });

    test('refuses to clear an existing card when nothing renders', () async {
      final service = _RecordingService();
      // No field mappings -> buildMinedFields renders nothing.
      final repo = _ConfiguredRepo(
        service: service,
        settings: _settings().copyWith(fieldMappings: const <String, String>{}),
      );

      final MineOutcome outcome = await repo.updateMinedNote(
        noteId: 1,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorDetail, contains('empty'));
      expect(service.updateCalls, isEmpty,
          reason: 'must not update with an empty field set');
    });

    test('maps an invalid payload to error without throwing', () async {
      final service = _RecordingService();
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.updateMinedNote(
        noteId: 1,
        rawPayloadJson: 'not json',
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.error);
      expect(service.updateCalls, isEmpty);
    });
  });

  group('MineOutcome.noteId backward compatibility (task A)', () {
    test('success() with no arg still works and has a null noteId', () {
      const MineOutcome o = MineOutcome.success();
      expect(o.result, MineResult.success);
      expect(o.noteId, isNull);
    });

    test('success(noteId:) carries the id', () {
      const MineOutcome o = MineOutcome.success(noteId: 7);
      expect(o.result, MineResult.success);
      expect(o.noteId, 7);
    });

    test('duplicate/notConfigured/failure have a null noteId', () {
      expect(const MineOutcome.duplicate().noteId, isNull);
      expect(const MineOutcome.notConfigured().noteId, isNull);
      expect(MineOutcome.failure('x').noteId, isNull);
    });
  });
}
