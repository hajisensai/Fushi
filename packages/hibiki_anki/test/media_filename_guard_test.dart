import 'dart:convert';
import 'dart:async';
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

class _FailingRequiredAudioService extends _RecordingAnkiConnectService {
  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) {
    throw TimeoutException('sentence audio upload timed out');
  }
}

class _FailingRequiredPictureService extends _RecordingAnkiConnectService {
  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) {
    if (filename.startsWith('hibiki_cover_')) {
      throw TimeoutException('card picture upload timed out');
    }
    return super.storeMediaFile(filename: filename, data: data, path: path);
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
      fields: <String>['Expression', 'Audio', 'SentenceAudio', 'Picture'],
    ),
  ],
  fieldMappings: <String, String>{
    'Expression': '{expression}',
    'Audio': '{audio}',
    'SentenceAudio': '{sasayaki-audio}',
    'Picture': '{card-image}',
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
    late File sentenceAudio;
    late File picture;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hibiki_anki_media_names');
      audio = File('${dir.path}/local_audio.mp3');
      sentenceAudio = File('${dir.path}/sentence.wav');
      picture = File('${dir.path}/window.png');
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

    test(
        'AnkiConnect uploads required sentence audio before optional word audio',
        () async {
      sentenceAudio.writeAsBytesSync(<int>[1, 2, 3, 4]);
      audio.writeAsBytesSync(<int>[9, 8, 7]);
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings,
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'sentence',
          sasayakiAudioPath: sentenceAudio.path,
        ),
      );

      expect(outcome.result, MineResult.success);
      expect(service.storedFilenames, hasLength(2));
      expect(
        service.storedFilenames.first,
        hibikiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_audio_',
          bytes: sentenceAudio.readAsBytesSync(),
          sourceName: sentenceAudio.path,
        ),
      );
      expect(service.addedNotes.single['SentenceAudio'], contains('[sound:'));
    });

    test(
        'AnkiConnect does not create a card when required sentence audio fails',
        () async {
      sentenceAudio.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final service = _FailingRequiredAudioService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings,
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(<String, String>{'expression': 'word'}),
        context: AnkiMiningContext(
          sentence: 'sentence',
          sasayakiAudioPath: sentenceAudio.path,
        ),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.connectionTimeout);
      expect(service.addedNotes, isEmpty);
    });

    test(
        'AnkiConnect uploads required picture after sentence audio and before optional media',
        () async {
      sentenceAudio.writeAsBytesSync(<int>[1, 2, 3, 4]);
      picture.writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
      audio.writeAsBytesSync(<int>[9, 8, 7]);
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings,
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: _payloadFor(audio.path),
        context: AnkiMiningContext(
          sentence: 'sentence',
          sasayakiAudioPath: sentenceAudio.path,
          coverPath: picture.path,
          requireCover: true,
        ),
      );

      expect(outcome.result, MineResult.success);
      expect(service.storedFilenames, hasLength(3));
      expect(service.storedFilenames[0], startsWith('hibiki_audio_'));
      expect(service.storedFilenames[1], startsWith('hibiki_cover_'));
      expect(service.addedNotes.single['Picture'], contains('<img src='));
    });

    test('AnkiConnect does not create a card when required picture fails',
        () async {
      picture.writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
      final service = _FailingRequiredPictureService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings,
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(<String, String>{'expression': 'word'}),
        context: AnkiMiningContext(
          sentence: 'sentence',
          coverPath: picture.path,
          requireCover: true,
        ),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.connectionTimeout);
      expect(service.addedNotes, isEmpty);
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

    test('dictionary media cache names use stable SHA-1 path hashes', () {
      expect(
        ankiDictionaryMediaCacheFilename('gaiji/bs一.svg'),
        'hibiki_dict_7de320e8f49c1e60a3ee86953fbafd6cadf701a7.svg',
      );
      expect(
        ankiDictionaryMediaCacheFilename('gaiji/noext'),
        'hibiki_dict_9b891374d454bc61cb63a8b3ac0e229da34e0107.bin',
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
