import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:http/http.dart' as http;

AnkiSettings _settings({String? audioMapping}) => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[
        AnkiDeck(id: 1, name: 'Mining'),
      ],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Hibiki',
          fields: <String>[
            'Expression',
            if (audioMapping != null) 'Audio',
            if (audioMapping == null) 'Picture',
          ],
        ),
      ],
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        if (audioMapping != null) 'Audio': audioMapping,
        if (audioMapping == null) 'Picture': '{card-image}',
      },
      allowDupes: true,
    );

class _Repository extends AnkiConnectRepository {
  _Repository(this.settings, AnkiConnectService service)
      : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConcurrentSameHashService extends AnkiConnectService {
  final Completer<void> _bothChecked = Completer<void>();
  final Set<String> media = <String>{};
  final List<String> deleted = <String>[];
  int checks = 0;
  int stores = 0;
  int notes = 0;

  @override
  Future<bool> mediaFileExists(String filename) async {
    checks += 1;
    if (checks == 2) _bothChecked.complete();
    await _bothChecked.future;
    return false;
  }

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    stores += 1;
    media.add(filename);
    if (stores == 2) {
      throw TimeoutException('second transaction lost its write response');
    }
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleted.add(filename);
    media.remove(filename);
  }

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
    notes += 1;
    return notes;
  }
}

class _RemoteAudioCleanupRetryService extends AnkiConnectService {
  final Set<String> media = <String>{};
  int deleteAttempts = 0;
  int notes = 0;

  @override
  Future<bool> mediaFileExists(String filename) async => false;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    media.add(filename);
    throw TimeoutException('store committed but its response was lost');
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleteAttempts += 1;
    if (deleteAttempts == 1) {
      throw TimeoutException('first cleanup attempt was lost');
    }
    media.remove(filename);
  }

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
    notes += 1;
    return notes;
  }
}

enum _AddNoteResult {
  duplicate,
  knownFailure,
  commitUnknown,
}

class _TerminalAddNoteService extends AnkiConnectService {
  _TerminalAddNoteService({
    required this.result,
    this.preexisting = false,
  });

  final _AddNoteResult result;
  final bool preexisting;
  final Set<String> media = <String>{};
  final List<String> stored = <String>[];
  final List<String> deleted = <String>[];
  int addAttempts = 0;

  @override
  Future<bool> mediaFileExists(String filename) async => preexisting;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    stored.add(filename);
    media.add(filename);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleted.add(filename);
    media.remove(filename);
  }

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
    switch (result) {
      case _AddNoteResult.duplicate:
        throw AnkiConnectDuplicateException('explicit duplicate');
      case _AddNoteResult.knownFailure:
        throw AnkiConnectException('known addNote rejection');
      case _AddNoteResult.commitUnknown:
        throw AnkiConnectCommitUnknownException(
          'addNote',
          http.ClientException('response reset after request delivery'),
        );
    }
  }
}

class _PeerCommitDuplicateService extends AnkiConnectService {
  final Completer<void> _bothChecked = Completer<void>();
  final Set<String> media = <String>{};
  final List<String> deleted = <String>[];
  int checks = 0;
  int addAttempts = 0;

  @override
  Future<bool> mediaFileExists(String filename) async {
    checks += 1;
    if (checks == 2) _bothChecked.complete();
    await _bothChecked.future;
    return false;
  }

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    media.add(filename);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleted.add(filename);
    media.remove(filename);
  }

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
    if (addAttempts == 1) return 101;
    await Future<void>.delayed(Duration.zero);
    throw AnkiConnectDuplicateException('peer duplicate');
  }
}

void main() {
  late Directory tempDirectory;
  late File cover;
  late File audio;

  setUp(() {
    tempDirectory =
        Directory.systemTemp.createTempSync('anki-media-rollback-race');
    cover = File('${tempDirectory.path}/same.gif')
      ..writeAsBytesSync(<int>[
        0x47,
        0x49,
        0x46,
        0x38,
        0x39,
        0x61,
        0x01,
        0x00,
        0x01,
        0x00,
      ]);
    audio = File('${tempDirectory.path}/word.aac')
      ..writeAsBytesSync(<int>[0x41, 0x44, 0x54, 0x53]);
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('failed concurrent note cannot delete shared hash committed by peer',
      () async {
    final _ConcurrentSameHashService service = _ConcurrentSameHashService();
    final _Repository first = _Repository(_settings(), service);
    final _Repository second = _Repository(_settings(), service);

    final List<MineOutcome> outcomes = await Future.wait(<Future<MineOutcome>>[
      first.mineEntry(
        rawPayloadJson: '{"expression":"first"}',
        context: AnkiMiningContext(sentence: '', coverPath: cover.path),
      ),
      second.mineEntry(
        rawPayloadJson: '{"expression":"second"}',
        context: AnkiMiningContext(sentence: '', coverPath: cover.path),
      ),
    ]);

    expect(
      outcomes.where(
        (MineOutcome outcome) => outcome.result == MineResult.success,
      ),
      hasLength(1),
    );
    expect(service.notes, 1);
    expect(
      service.media,
      isNotEmpty,
      reason: 'the successful peer note still references this hash media',
    );
    expect(
      service.deleted,
      isEmpty,
      reason: 'a committed peer lease permanently protects the shared file',
    );
  });

  test('remote-audio warning retries cleanup retained after lost response',
      () async {
    final _RemoteAudioCleanupRetryService service =
        _RemoteAudioCleanupRetryService();
    final _Repository repository =
        _Repository(_settings(audioMapping: '{audio}'), service);

    final MineOutcome outcome = await repository.mineEntry(
      rawPayloadJson:
          '{"expression":"audio","audio":"${audio.uri.toString()}"}',
      context: const AnkiMiningContext(sentence: ''),
    );

    expect(outcome.result, MineResult.success);
    expect(service.notes, 1);
    expect(service.deleteAttempts, 2);
    expect(
      service.media,
      isEmpty,
      reason: 'the non-fatal route must clean its unreferenced committed write',
    );
  });

  test('explicit duplicate rolls back newly uploaded cover and audio',
      () async {
    final _TerminalAddNoteService service = _TerminalAddNoteService(
      result: _AddNoteResult.duplicate,
    );
    final _Repository repository = _Repository(_settings(), service);

    final MineOutcome outcome = await repository.mineEntry(
      rawPayloadJson: '{"expression":"duplicate"}',
      context: AnkiMiningContext(
        sentence: '',
        coverPath: cover.path,
        sasayakiAudioPath: audio.path,
      ),
    );

    expect(outcome.result, MineResult.duplicate);
    expect(service.addAttempts, 1);
    expect(service.stored, hasLength(2));
    expect(service.deleted, unorderedEquals(service.stored));
    expect(service.media, isEmpty);
  });

  test('known addNote rejection rolls back newly uploaded media', () async {
    final _TerminalAddNoteService service = _TerminalAddNoteService(
      result: _AddNoteResult.knownFailure,
    );
    final _Repository repository = _Repository(_settings(), service);

    final MineOutcome outcome = await repository.mineEntry(
      rawPayloadJson: '{"expression":"rejected"}',
      context: AnkiMiningContext(sentence: '', coverPath: cover.path),
    );

    expect(outcome.result, MineResult.error);
    expect(service.addAttempts, 1);
    expect(service.stored, hasLength(1));
    expect(service.deleted, service.stored);
    expect(service.media, isEmpty);
  });

  test('explicit duplicate preserves preexisting cover and audio', () async {
    final _TerminalAddNoteService service = _TerminalAddNoteService(
      result: _AddNoteResult.duplicate,
      preexisting: true,
    );
    final _Repository repository = _Repository(_settings(), service);

    final MineOutcome outcome = await repository.mineEntry(
      rawPayloadJson: '{"expression":"preexisting"}',
      context: AnkiMiningContext(
        sentence: '',
        coverPath: cover.path,
        sasayakiAudioPath: audio.path,
      ),
    );

    expect(outcome.result, MineResult.duplicate);
    expect(service.addAttempts, 1);
    expect(service.stored, hasLength(2));
    expect(service.deleted, isEmpty);
    expect(service.media, unorderedEquals(service.stored));
  });

  test('explicit duplicate cannot delete media committed by peer note',
      () async {
    final _PeerCommitDuplicateService service = _PeerCommitDuplicateService();
    final _Repository first = _Repository(_settings(), service);
    final _Repository second = _Repository(_settings(), service);

    final List<MineOutcome> outcomes = await Future.wait(<Future<MineOutcome>>[
      first.mineEntry(
        rawPayloadJson: '{"expression":"peer-success"}',
        context: AnkiMiningContext(sentence: '', coverPath: cover.path),
      ),
      second.mineEntry(
        rawPayloadJson: '{"expression":"peer-duplicate"}',
        context: AnkiMiningContext(sentence: '', coverPath: cover.path),
      ),
    ]);

    expect(
      outcomes.map((MineOutcome outcome) => outcome.result),
      containsAll(<MineResult>[MineResult.success, MineResult.duplicate]),
    );
    expect(service.addAttempts, 2);
    expect(service.deleted, isEmpty);
    expect(service.media, isNotEmpty);
  });

  test('commit-unknown keeps new media and never retries addNote', () async {
    final _TerminalAddNoteService service = _TerminalAddNoteService(
      result: _AddNoteResult.commitUnknown,
    );
    final _Repository repository = _Repository(_settings(), service);

    final MineOutcome outcome = await repository.mineEntry(
      rawPayloadJson: '{"expression":"unknown"}',
      context: AnkiMiningContext(
        sentence: '',
        coverPath: cover.path,
        sasayakiAudioPath: audio.path,
      ),
    );

    expect(outcome.result, MineResult.error);
    expect(outcome.errorDetail, contains('may have created'));
    expect(service.addAttempts, 1);
    expect(service.stored, hasLength(2));
    expect(service.deleted, isEmpty);
    expect(service.media, unorderedEquals(service.stored));
  });
}
