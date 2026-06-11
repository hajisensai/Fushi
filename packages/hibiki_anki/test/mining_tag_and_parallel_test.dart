import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-062 / BUG-166:
//  (1) Every Hibiki-mined card must carry the `hibiki` tag, appended to the
//      user's configured tags (de-duped, order preserved); both backends behave
//      identically.
//  (2) The 6s slowness root cause was several independent media uploads chained
//      with serial await. After switching to Future.wait, total time drops to
//      the slowest single path. The parallel test injects a per-store delay and
//      proves concurrency from timing (a serial impl blows past the bound).

class _RecordingAnkiConnectService extends AnkiConnectService {
  _RecordingAnkiConnectService({this.storeDelay = Duration.zero});

  final Duration storeDelay;
  final List<String> storedFilenames = <String>[];
  final List<List<String>> addedTags = <List<String>>[];

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    if (storeDelay > Duration.zero) await Future<void>.delayed(storeDelay);
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
    addedTags.add(List<String>.from(tags ?? const <String>[]));
    return addedTags.length;
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

AnkiSettings _settingsWithTags(String tags) => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(id: 2, name: 'Hibiki', fields: <String>['Expression']),
      ],
      fieldMappings: const <String, String>{'Expression': '{expression}'},
      tags: tags,
      allowDupes: true,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

void main() {
  group('buildNoteTags appends the hibiki tag (append, de-dupe, order)', () {
    Future<List<String>> tagsForConnect(String configured,
        {AnkiMiningSource? source}) async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settingsWithTags(configured),
      );
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: AnkiMiningContext(sentence: '', source: source),
      );
      expect(outcome.result, MineResult.success);
      expect(service.addedTags, hasLength(1));
      return service.addedTags.single;
    }

    test('empty user tags -> only [hibiki]', () async {
      expect(await tagsForConnect(''), <String>['hibiki']);
    });

    test('user tags are preserved and hibiki appended at the end', () async {
      expect(await tagsForConnect('jp::vocab mined'),
          <String>['jp::vocab', 'mined', 'hibiki']);
    });

    test('whitespace runs do not create empty tags', () async {
      expect(await tagsForConnect('  alpha   beta  '),
          <String>['alpha', 'beta', 'hibiki']);
    });

    test('a user-configured hibiki tag is not duplicated', () async {
      expect(await tagsForConnect('hibiki extra'), <String>['hibiki', 'extra']);
    });

    test('AnkiDroid backend appends hibiki identically', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('app.hibiki.reader/anki');
      final List<List<String>> addedTags = <List<String>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addNote':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            addedTags.add(List<String>.from(args['tags'] as List));
            return true;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final repo = _ConfiguredAnkiRepository(_settingsWithTags('foo bar'));
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(outcome.result, MineResult.success);
      expect(addedTags.single, <String>['foo', 'bar', 'hibiki']);
    });
  });

  group('TODO-115: source maps to category tag (book/anime), both backends',
      () {
    Future<List<String>> tagsForConnect(String configured,
        {AnkiMiningSource? source}) async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settingsWithTags(configured),
      );
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: AnkiMiningContext(sentence: '', source: source),
      );
      expect(outcome.result, MineResult.success);
      expect(service.addedTags, hasLength(1));
      return service.addedTags.single;
    }

    Future<List<String>> tagsForDroid(String configured,
        {AnkiMiningSource? source}) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('app.hibiki.reader/anki');
      final List<List<String>> addedTags = <List<String>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addNote':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            addedTags.add(List<String>.from(args['tags'] as List));
            return true;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final repo = _ConfiguredAnkiRepository(_settingsWithTags(configured));
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: AnkiMiningContext(sentence: '', source: source),
      );
      expect(outcome.result, MineResult.success);
      return addedTags.single;
    }

    test('book source -> appends both hibiki and book (AnkiConnect)', () async {
      expect(await tagsForConnect('', source: AnkiMiningSource.book),
          <String>['hibiki', 'book']);
    });

    test('video source -> appends both hibiki and anime (AnkiConnect)',
        () async {
      expect(await tagsForConnect('', source: AnkiMiningSource.video),
          <String>['hibiki', 'anime']);
    });

    test('null source -> only hibiki, no category tag (AnkiConnect)', () async {
      expect(await tagsForConnect('', source: null), <String>['hibiki']);
    });

    test('user tags preserved, then hibiki, then category (AnkiConnect)',
        () async {
      expect(await tagsForConnect('jp::vocab', source: AnkiMiningSource.video),
          <String>['jp::vocab', 'hibiki', 'anime']);
    });

    test('a user-configured category tag is not duplicated (AnkiConnect)',
        () async {
      expect(await tagsForConnect('book', source: AnkiMiningSource.book),
          <String>['book', 'hibiki']);
    });

    test('AnkiDroid backend maps source to the same category tags', () async {
      expect(await tagsForDroid('', source: AnkiMiningSource.book),
          <String>['hibiki', 'book']);
      expect(await tagsForDroid('', source: AnkiMiningSource.video),
          <String>['hibiki', 'anime']);
      expect(
          await tagsForDroid('foo', source: null), <String>['foo', 'hibiki']);
    });
  });

  group('media uploads run in parallel (timing proof for the 6s fix)', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hibiki_anki_parallel');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('AnkiConnect: 5 independent media stores finish in ~1 delay, not 5x',
        () async {
      const Duration perStore = Duration(milliseconds: 200);
      final service = _RecordingAnkiConnectService(storeDelay: perStore);

      final cover = File('${dir.path}/cover.jpg')
        ..writeAsBytesSync(<int>[1, 2]);
      final sasayaki = File('${dir.path}/say.mp3')
        ..writeAsBytesSync(<int>[3, 4]);
      final wordAudio = File('${dir.path}/word.mp3')
        ..writeAsBytesSync(<int>[5, 6]);

      final cacheDir = Directory(ankiDictionaryMediaCacheDirPath())
        ..createSync(recursive: true);
      final dictPathA = '${dir.path}/gaiji_a.svg';
      final dictPathB = '${dir.path}/gaiji_b.svg';
      final dictFileA = File(
          '${cacheDir.path}/${ankiDictionaryMediaCacheFilename(dictPathA)}')
        ..writeAsBytesSync(<int>[7]);
      final dictFileB = File(
          '${cacheDir.path}/${ankiDictionaryMediaCacheFilename(dictPathB)}')
        ..writeAsBytesSync(<int>[8]);
      addTearDown(() {
        if (dictFileA.existsSync()) dictFileA.deleteSync();
        if (dictFileB.existsSync()) dictFileB.deleteSync();
      });

      final settings = AnkiSettings(
        selectedDeckId: 1,
        selectedNoteTypeId: 2,
        availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
        availableNoteTypes: const <AnkiNoteType>[
          AnkiNoteType(id: 2, name: 'Hibiki', fields: <String>['Expression']),
        ],
        fieldMappings: const <String, String>{'Expression': '{expression}'},
        allowDupes: true,
      );
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settings,
      );

      final payload = jsonEncode(<String, dynamic>{
        'expression': '勉強',
        'audio': wordAudio.path,
        'dictionaryMedia': <Map<String, String>>[
          {
            'dictionary': 'd',
            'path': dictPathA,
            'filename': 'hoshi_dict_0.svg'
          },
          {
            'dictionary': 'd',
            'path': dictPathB,
            'filename': 'hoshi_dict_1.svg'
          },
        ],
      });

      final sw = Stopwatch()..start();
      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 's',
          coverPath: cover.path,
          sasayakiAudioPath: sasayaki.path,
        ),
      );
      sw.stop();

      expect(outcome.result, MineResult.success);
      expect(service.storedFilenames, hasLength(5));
      expect(
        sw.elapsed,
        lessThan(const Duration(milliseconds: 800)),
        reason: 'media stores must run in parallel, not serially '
            '(elapsed ${sw.elapsedMilliseconds}ms)',
      );
    });
  });
}
