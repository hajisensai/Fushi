import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';

class _CommitUnknownService extends AnkiConnectService {
  int addAttempts = 0;
  int duplicateChecks = 0;
  int findCalls = 0;
  AnkiDuplicateScope? receivedScope;

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addAttempts += 1;
    receivedScope = duplicateScope;
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
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    duplicateChecks += 1;
    return false;
  }

  @override
  Future<List<int>> findNotesByField({
    required String deckName,
    required String fieldName,
    required String fieldValue,
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    findCalls += 1;
    return <int>[777];
  }
}

class _DuplicateService extends AnkiConnectService {
  int duplicateChecks = 0;

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    throw AnkiConnectDuplicateException(
      'cannot create note because it is a duplicate',
    );
  }

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    duplicateChecks += 1;
    return true;
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
  group('AnkiConnect atomic addNote duplicate handling', () {
    test('normal mining does not preflight or reconcile with findNotes',
        () async {
      final service = _CommitUnknownService();
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.noteId, isNull);
      expect(outcome.errorDetail, contains('may have created'));
      expect(service.addAttempts, 1,
          reason: 'response-phase addNote reset must not be blindly retried');
      expect(service.duplicateChecks, 0,
          reason: 'mining must not run a GUI-thread findNotes preflight');
      expect(service.findCalls, 0,
          reason: 'a lost addNote response cannot be reconciled safely');
      expect(service.receivedScope, AnkiDuplicateScope.deck);
    });

    test('native duplicate response becomes MineOutcome.duplicate', () async {
      final service = _DuplicateService();
      final repo = _ConfiguredRepo(service: service, settings: _settings());

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: _context,
      );

      expect(outcome.result, MineResult.duplicate);
      expect(outcome.noteId, isNull);
      expect(service.duplicateChecks, 0);
    });

    test('allowDupes=true also never runs a separate duplicate query',
        () async {
      final service = _CommitUnknownService();
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
      expect(service.findCalls, 0);
    });
  });
}
