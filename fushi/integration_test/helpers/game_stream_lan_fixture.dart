/// Real LAN test setup. No live database, preferences, or credentials are copied.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/sync/game_stream_mining.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:html/parser.dart' show parseFragment;
import 'package:path/path.dart' as p;

const String gameStreamTestDeck = 'Fushi Game Stream E2E';
const String gameStreamTestDictionary = 'FushiGameStreamE2E';
MiningMediaCompression gameStreamFixtureCompression() =>
    MiningMediaCompression.resolve(imageTier: 3, audioTier: 2);

const List<String> gameStreamTestTerms = <String>[
  'サイ',
  '俺',
  '私',
  '君',
  '何',
  'ない',
  'いる',
  'こと',
  'それ',
  'これ',
  'ね',
  'の',
  'I',
  'the',
  'The',
  'you',
  'You',
  'time',
  'Time',
  'and',
  'is',
  'to',
  'of',
  'a',
];

Map<String, Object?> gameStreamFailureSummary(Object error) {
  final Map<String, Object?> summary = <String, Object?>{
    'failureType': error.runtimeType.toString(),
  };
  if (error is PlatformException) {
    summary['failureCode'] = error.code;
  } else if (error is FlutterErrorDetails) {
    summary['failureType'] = error.exception.runtimeType.toString();
    if (error.exception is PlatformException) {
      summary['failureCode'] = (error.exception as PlatformException).code;
    }
  }
  return summary;
}

class GameStreamFlutterErrorRecorder {
  GameStreamFlutterErrorRecorder({FlutterExceptionHandler? bindingHandler})
    : _bindingHandler = bindingHandler ?? FlutterError.onError;

  final FlutterExceptionHandler? _bindingHandler;
  FlutterExceptionHandler? _installed;
  Map<String, Object?>? _lastFailure;

  Map<String, Object?>? get lastFailure => _lastFailure;

  void install() {
    _installed = (FlutterErrorDetails details) {
      _lastFailure ??= gameStreamFailureSummary(details);
      _bindingHandler?.call(details);
    };
    FlutterError.onError = _installed;
  }

  void restore() {
    FlutterError.onError = _bindingHandler;
    _installed = null;
  }
}

/// SharedPreferences (Anki settings) must be isolated as well as Drift/AppPaths.
String requireGameStreamIsolatedRoot() {
  final String? root = fushiTestRootPath();
  final String? appData = Platform.environment['APPDATA'];
  if (root == null ||
      appData == null ||
      !p.isWithin(p.normalize(root), p.normalize(appData))) {
    throw StateError(
      'Use run_windows_itest.ps1 with its isolated APPDATA/root',
    );
  }
  return root;
}

/// The token file inherits only this Windows user's access, not the checkout ACL.
Future<void> restrictGameStreamFixtureDirectory(Directory directory) async {
  final ProcessResult identity = await Process.run('whoami', const <String>[]);
  final String principal = '${identity.stdout}'.trim();
  if (identity.exitCode != 0 || principal.isEmpty) {
    throw StateError('Cannot identify the private fixture directory owner');
  }
  final ProcessResult restricted = await Process.run('icacls', <String>[
    directory.path,
    '/inheritance:r',
    '/grant:r',
    '$principal:(OI)(CI)F',
  ]);
  if (restricted.exitCode != 0) {
    throw StateError('Cannot restrict access to the fixture credentials');
  }
}

/// Only an opt-in live fixture may temporarily activate its own exact runner.
Future<void> importGameStreamTestDictionary(
  AppModel app,
  Directory evidence,
) async {
  final Archive archive = Archive();
  void addJson(String name, Object value) {
    final List<int> bytes = utf8.encode(jsonEncode(value));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addJson('index.json', <String, Object>{
    'title': gameStreamTestDictionary,
    'format': 3,
    'revision': 'lan-e2e-1',
    'sequenced': false,
  });
  addJson('term_bank_1.json', <List<Object>>[
    for (int i = 0; i < gameStreamTestTerms.length; i++)
      <Object>[
        gameStreamTestTerms[i],
        '',
        '',
        '',
        0,
        <String>['Synthetic LAN E2E definition for ${gameStreamTestTerms[i]}.'],
        i,
        '',
      ],
  ]);
  final File file = File(p.join(evidence.path, 'dictionary.fixture.zip'));
  await file.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool imported = false;
  try {
    await app.importDictionary(
      file: file,
      progressNotifier: progress,
      onImportSuccess: () => imported = true,
    );
  } finally {
    progress.dispose();
  }
  if (!imported ||
      !app.dictionaries.any(
        (dictionary) => dictionary.name == gameStreamTestDictionary,
      )) {
    throw StateError('The isolated dictionary was not imported');
  }
}

Future<BaseAnkiRepository> configureGameStreamTestAnki(
  AppModel app,
  String runTag,
) async {
  final BaseAnkiRepository repo = app.platformServices.createAnkiRepository();
  await repo.saveSettings(
    AnkiSettings(
      selectedDeckName: gameStreamTestDeck,
      selectedNoteTypeName: 'Lapis',
      tags: runTag,
      tagIncludeHibiki: false,
      tagIncludeCategory: false,
      duplicateScope: AnkiDuplicateScope.deck,
      fieldMappings: const <String, String>{
        'Expression': '{expression}',
        'ExpressionReading': '{reading}',
        'MainDefinition': '{glossary-first}',
        'Glossary': '{glossary}',
        'Sentence': '{sentence}',
        'SentenceAudio': '{sentence-audio}',
        'Picture': '{card-image}',
        'MiscInfo': '{source-link}',
      },
    ),
  );
  await repo.createDeck(gameStreamTestDeck);
  final AnkiFetchResult fetched = await repo.fetchConfiguration();
  if (fetched is! AnkiFetchSuccess ||
      !fetched.noteTypes.any((AnkiNoteType type) => type.name == 'Lapis')) {
    throw StateError('AnkiConnect must already have the Lapis note type');
  }
  final AnkiSettings settings = await repo.loadSettings();
  if (settings.selectedDeckName != gameStreamTestDeck ||
      settings.selectedNoteTypeName != 'Lapis' ||
      settings.tags != runTag) {
    throw StateError('Anki test deck/model selection was not preserved');
  }
  return repo;
}

/// This observer delegates every capture and mine to the production adapter.
/// It only reads back notes in this run's dedicated test deck/tag.
class GameStreamEvidenceMiningAdapter extends FushiGameStreamMiningAdapter {
  GameStreamEvidenceMiningAdapter({
    required BaseAnkiRepository repo,
    required this.evidence,
  }) : super(
         repository: () => repo,
         coordinator: GalHookMiningCoordinator(
           captureAudio: evidence.captureAudio,
         ),
         compression: gameStreamFixtureCompression,
         stillFormat: MiningStillFormat.png,
         captureStill: evidence.capture,
       );

  final GameStreamLanEvidence evidence;

  @override
  Future<GameStreamMineResult> mine(
    GameStreamMineRequest request,
    GameStreamTextEvent line,
  ) async {
    final Set<int> before = await evidence.findRunNotes();
    final GameStreamMineResult result = await super.mine(request, line);
    if (result.ok) {
      try {
        await evidence.verifyMine(line, before);
      } catch (error) {
        evidence.failures.add('Mining readback: $error');
        await evidence.writeJson('verification-failure.json', <String, Object?>{
          'lineId': line.lineId,
          'error': '$error',
        });
      }
    }
    return result;
  }
}

class GameStreamLanEvidence {
  GameStreamLanEvidence({required this.directory, required this.runTag});

  final Directory directory;
  final String runTag;
  final List<String> failures = <String>[];
  final List<int> verifiedNotes = <int>[];
  final Map<String, ({String text, String pngSha256})> _frames =
      <String, ({String text, String pngSha256})>{};
  final Map<String, ({String sentence, String sha256, int bytes})> _audio =
      <String, ({String sentence, String sha256, int bytes})>{};

  /// Observe the exact production line-specific resource/cache bytes consumed
  /// by the miner. This does not certify the original archive or voice purity.
  Future<Uint8List?> captureAudio({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) async {
    final Uint8List? bytes = await GalHookSessionController.instance
        .captureAudioBytes(
          lineId: lineId,
          sentence: sentence,
          outputExtension: outputExtension,
        );
    if (bytes != null && bytes.isNotEmpty) {
      _audio[lineId] = (
        sentence: sentence,
        sha256: sha256.convert(bytes).toString(),
        bytes: bytes.length,
      );
    }
    return bytes;
  }

  Future<void> writeJson(String name, Object data) async {
    await File(p.join(directory.path, name)).writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  Future<WindowCaptureResult> capture(int hwnd) async {
    final List<TexthookerLineEntry> lines = TexthookerService.instance.entries;
    final TexthookerLineEntry? before = lines.isEmpty ? null : lines.last;
    final WindowCaptureResult result = await WindowCaptureChannel.captureWindow(
      hwnd,
    );
    final List<TexthookerLineEntry> current =
        TexthookerService.instance.entries;
    final TexthookerLineEntry? after = current.isEmpty ? null : current.last;
    if (result.ok &&
        before != null &&
        before.id == after?.id &&
        before.text == after?.text) {
      final Uint8List bytes = result.pngBytes!;
      final String name = sha256.convert(utf8.encode(before.id)).toString();
      _frames[before.id] = (
        text: before.text,
        pngSha256: sha256.convert(bytes).toString(),
      );
      await File(
        p.join(directory.path, 'frame-$name.png'),
      ).writeAsBytes(bytes, flush: true);
    }
    return result;
  }

  Future<Object?> _anki(String action, Map<String, Object?> params) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final HttpClientRequest request = await client.postUrl(
        Uri.parse('http://127.0.0.1:8765'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'action': action,
          'version': 6,
          'params': params,
        }),
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final Map<String, dynamic> body =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      if (response.statusCode != 200 || body['error'] != null) {
        throw StateError('AnkiConnect $action failed: ${body['error']}');
      }
      return body['result'];
    } finally {
      client.close(force: true);
    }
  }

  Future<Set<int>> findRunNotes() async {
    final Object? result = await _anki('findNotes', <String, Object?>{
      'query': 'deck:"$gameStreamTestDeck" tag:$runTag',
    });
    return (result! as List<dynamic>).cast<int>().toSet();
  }

  Future<Uint8List> _media(String name) async {
    final Object? value = await _anki('retrieveMediaFile', <String, Object?>{
      'filename': name,
    });
    if (value is! String || value.isEmpty) {
      throw StateError('Missing Anki media $name');
    }
    return base64Decode(value);
  }

  Future<void> verifyMine(GameStreamTextEvent line, Set<int> before) async {
    final Set<int> added = (await findRunNotes()).difference(before);
    if (added.length != 1) {
      throw StateError(
        'Expected exactly one new test note; got ${added.length}',
      );
    }
    final int noteId = added.single;
    final List<dynamic> notes =
        (await _anki('notesInfo', <String, Object?>{
              'notes': <int>[noteId],
            }))!
            as List<dynamic>;
    final Map<String, dynamic> fields =
        (notes.single as Map<String, dynamic>)['fields']
            as Map<String, dynamic>;
    String field(String name) =>
        (fields[name] as Map<String, dynamic>)['value'] as String;
    final String sentence = parseFragment(field('Sentence')).text ?? '';
    if (sentence != line.text) {
      throw StateError('Anki sentence differs from mined lineId');
    }
    final String? audioName = RegExp(
      r'\[sound:([^\]]+)\]',
    ).firstMatch(field('SentenceAudio'))?.group(1);
    final String? pictureName = parseFragment(
      field('Picture'),
    ).querySelector('img')?.attributes['src'];
    if (audioName == null || pictureName == null) {
      throw StateError('The note lacks sentence audio or picture');
    }
    final Uint8List audio = await _media(audioName);
    final Uint8List picture = await _media(pictureName);
    final ({String text, String pngSha256})? frame = _frames[line.lineId];
    final String pictureHash = sha256.convert(picture).toString();
    if (frame == null || frame.text != line.text) {
      throw StateError('Missing frozen PNG for the mined lineId');
    }
    final String frameName = sha256
        .convert(utf8.encode(line.lineId))
        .toString();
    final Uint8List frozenBytes = await File(
      p.join(directory.path, 'frame-$frameName.png'),
    ).readAsBytes();
    final MiningMediaCompression compression = gameStreamFixtureCompression();
    final Uint8List expectedPicture = await downsampleCardScreenshotAsync(
      frozenBytes,
      maxLongEdge: compression.screenshotMaxLongEdge,
      quality: compression.screenshotQuality,
      encoding: CardScreenshotEncoding.png,
    );
    final String expectedPictureHash = sha256
        .convert(expectedPicture)
        .toString();
    if (expectedPictureHash != pictureHash) {
      throw StateError('Anki picture differs from compressed frozen line PNG');
    }
    final capturedAudio = _audio[line.lineId];
    final String audioHash = sha256.convert(audio).toString();
    if (capturedAudio == null ||
        capturedAudio.sentence != line.text ||
        capturedAudio.sha256 != audioHash) {
      throw StateError('Anki audio differs from the production line capture');
    }
    verifiedNotes.add(noteId);
    await writeJson('note-$noteId.json', <String, Object?>{
      'noteId': noteId,
      'lineId': line.lineId,
      'sentenceSha256': sha256.convert(utf8.encode(line.text)).toString(),
      'audioResourceId': line.audioResourceId,
      'audioBytes': audio.length,
      'audioSha256': audioHash,
      'lineAudioCaptureSha256': capturedAudio.sha256,
      'lineAudioCaptureBytes': capturedAudio.bytes,
      'audioMatchesLineCaptureBytes': true,
      'pictureBytes': picture.length,
      'pictureSha256': pictureHash,
      'frozenFrameSha256': frame.pngSha256,
      'compressedFrozenFrameSha256': expectedPictureHash,
      'pictureMatchesCompressedFrozenFrame': true,
      'screenshotMaxLongEdge': compression.screenshotMaxLongEdge,
      'screenshotQuality': compression.screenshotQuality,
      'deck': gameStreamTestDeck,
      'runTag': runTag,
      'audioResourceByteComparison': 'not_run',
      'pureVoiceClassification': 'not_run',
    });
  }
}
