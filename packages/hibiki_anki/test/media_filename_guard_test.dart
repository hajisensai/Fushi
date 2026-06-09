import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _RecordingAnkiConnectService extends AnkiConnectService {
  final List<String> storedFilenames = <String>[];
  final List<Map<String, String>> addedNotes = <Map<String, String>>[];

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
  }) async {
    addedNotes.add(Map<String, String>.from(fields));
    return addedNotes.length;
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

const AnkiSettings _settings = AnkiSettings(
  selectedDeckId: 1,
  selectedNoteTypeId: 2,
  availableDecks: <AnkiDeck>[
    AnkiDeck(id: 1, name: 'Mining'),
  ],
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(
      id: 2,
      name: 'Hibiki',
      fields: <String>['Expression', 'Audio', 'SentenceAudio'],
    ),
  ],
  fieldMappings: <String, String>{
    'Expression': '{expression}',
    'Audio': '{audio}',
    'SentenceAudio': '{sasayaki-audio}',
  },
  allowDupes: true,
);

String _payloadFor(String audioPath) => jsonEncode(<String, String>{
      'expression': 'word',
      'audio': audioPath,
    });

void main() {
  group('Anki media filenames', () {
    late Directory dir;
    late File audio;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hibiki_anki_media_names');
      audio = File('${dir.path}/local_audio.mp3');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'AnkiConnect does not reuse media names when a fixed local audio path changes content',
        () async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings,
      );

      audio.writeAsBytesSync(<int>[1, 2, 3]);
      final MineOutcome first = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'first',
          sasayakiAudioPath: audio.path,
        ),
      );

      audio.writeAsBytesSync(<int>[9, 8, 7, 6]);
      final MineOutcome second = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'second',
          sasayakiAudioPath: audio.path,
        ),
      );

      expect(first.result, MineResult.success);
      expect(second.result, MineResult.success);
      expect(service.addedNotes, hasLength(2));

      final String firstWordAudio = service.addedNotes[0]['Audio']!;
      final String secondWordAudio = service.addedNotes[1]['Audio']!;
      expect(firstWordAudio, startsWith('[sound:hibiki_audio_'));
      expect(secondWordAudio, startsWith('[sound:hibiki_audio_'));
      expect(firstWordAudio, isNot(secondWordAudio));

      final String firstSentenceAudio = service.addedNotes[0]['SentenceAudio']!;
      final String secondSentenceAudio =
          service.addedNotes[1]['SentenceAudio']!;
      expect(firstSentenceAudio, startsWith('[sound:hibiki_audio_'));
      expect(secondSentenceAudio, startsWith('[sound:hibiki_audio_'));
      expect(firstSentenceAudio, isNot(secondSentenceAudio));
      expect(service.storedFilenames.toSet(), hasLength(2));
    });

    test('content-derived media names use SHA-256 and preserve extension', () {
      expect(
        hibikiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_audio_',
          bytes: utf8.encode('abc'),
          sourceName: 'word.mp3',
        ),
        'hibiki_audio_'
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        '.mp3',
      );
    });

    test(
        'AnkiDroid does not reuse preferred media names when a fixed local audio path changes content',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('app.hibiki.reader/anki');
      final List<List<String>> addedNotes = <List<String>>[];
      final List<String> preferredNames = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'addFileToMedia':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final String preferredName = args['preferredName'] as String;
            preferredNames.add(preferredName);
            return preferredName;
          case 'addNote':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            addedNotes.add(List<String>.from(args['fields'] as List));
            return true;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final repo = _ConfiguredAnkiRepository(_settings);

      audio.writeAsBytesSync(<int>[1, 2, 3]);
      final MineOutcome first = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'first',
          sasayakiAudioPath: audio.path,
        ),
      );

      audio.writeAsBytesSync(<int>[9, 8, 7, 6]);
      final MineOutcome second = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'second',
          sasayakiAudioPath: audio.path,
        ),
      );

      expect(first.result, MineResult.success);
      expect(second.result, MineResult.success);
      expect(addedNotes, hasLength(2));

      final String firstWordAudio = addedNotes[0][1];
      final String secondWordAudio = addedNotes[1][1];
      expect(firstWordAudio, startsWith('[sound:hibiki_audio_'));
      expect(secondWordAudio, startsWith('[sound:hibiki_audio_'));
      expect(firstWordAudio, isNot(secondWordAudio));

      final String firstSentenceAudio = addedNotes[0][2];
      final String secondSentenceAudio = addedNotes[1][2];
      expect(firstSentenceAudio, startsWith('[sound:hibiki_audio_'));
      expect(secondSentenceAudio, startsWith('[sound:hibiki_audio_'));
      expect(firstSentenceAudio, isNot(secondSentenceAudio));
      expect(preferredNames.toSet(), hasLength(2));
    });
  });
}
