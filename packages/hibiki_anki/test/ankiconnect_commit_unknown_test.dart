import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';

class _CommitUnknownService extends AnkiConnectService {
  _CommitUnknownService({
    required this.reconcileIds,
    this.duplicateBeforeAdd = false,
  });

  final List<int> reconcileIds;
  final bool duplicateBeforeAdd;
  int addAttempts = 0;
  int duplicateChecks = 0;
  int findCalls = 0;

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  }) async {
    addAttempts += 1;
    throw AnkiConnectCommitUnknownException(
      'addNote',
      http.ClientException('Connection reset by peer'),
    );
  }

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async {
    duplicateChecks += 1;
    return duplicateBeforeAdd;
  }

  Future<List<int>> findNotesByField({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async {
    findCalls += 1;
    return reconcileIds;
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

AnkiSettings _settings({bool allowDupes = false}) => AnkiSettings(
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
const AnkiMiningContext _context = AnkiMiningContext(sentence: '');

void main() {
  group('AnkiConnect addNote unknown commit reconciliation', () {
    test('unique post-reset findNotes match becomes success(noteId)', () async {
      final service = _CommitUnknownService(reconcileIds: <int>[777]);
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 777);
      expect(service.addAttempts, 1,
          reason: 'response-phase addNote reset must not be blindly retried');
      expect(service.duplicateChecks, 1,
          reason:
              'reconciliation is allowed only after the pre-check was clean');
      expect(service.findCalls, 1);
    });

    test('no post-reset match stays an explicit uncertain failure', () async {
      final service = _CommitUnknownService(reconcileIds: const <int>[]);
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.noteId, isNull);
      expect(outcome.errorDetail, contains('may have created'));
      expect(service.findCalls, 1);
    });

    test('multiple post-reset matches stay uncertain, not success', () async {
      final service = _CommitUnknownService(reconcileIds: <int>[7, 8]);
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.noteId, isNull);
      expect(outcome.errorDetail, contains('could not uniquely confirm'));
      expect(service.findCalls, 1);
    });

    test('allowDupes=true never reconciles by first field or claims success',
        () async {
      final service = _CommitUnknownService(reconcileIds: <int>[777]);
      final repo = _ConfiguredRepo(
        service: service,
        settings: _settings(allowDupes: true),
      );

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.noteId, isNull);
      expect(service.duplicateChecks, 0);
      expect(service.findCalls, 0,
          reason: 'with duplicates allowed, a first-field match is not unique');
    });
  });
}
