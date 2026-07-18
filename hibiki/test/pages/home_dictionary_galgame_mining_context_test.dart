import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/mining/galgame_audio_capture_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import '../helpers/test_platform_services.dart';

class _GalgameMiningAppModel extends AppModel {
  _GalgameMiningAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];

  @override
  bool get desktopClipboardEnabled => false;

  @override
  bool get autoSearchEnabled => false;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  bool get compressMiningMedia => true;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    searchedTerms.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class _CapturingAnkiRepository extends BaseAnkiRepository {
  AnkiMiningContext? captured;
  bool? coverExistedDuringMine;
  Uint8List? coverBytesDuringMine;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    captured = context;
    final String? coverPath = context.coverPath;
    if (coverPath != null) {
      final File cover = File(coverPath);
      coverExistedDuringMine = cover.existsSync();
      if (coverExistedDuringMine!) {
        coverBytesDuringMine = cover.readAsBytesSync();
      }
    }
    return MineOutcome.failure('capture');
  }

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => null;
  @override
  Future<bool> openNoteInAnki(int noteId) async => false;
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('stub');
  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

Widget _wrap(
  _GalgameMiningAppModel appModel,
  _CapturingAnkiRepository ankiRepository,
) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
}

HomeDictionarySearchDebug _debug(WidgetTester tester) =>
    tester.state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel captureChannel =
      MethodChannel('app.hibiki.reader/process_audio_capture');
  const ExternalWindowInfo game = ExternalWindowInfo(
    hwnd: 10,
    pid: 4242,
    title: 'Visual novel',
    executablePath: r'C:\Games\vn.exe',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final GalgameAudioCaptureController capture =
      GalgameAudioCaptureController.instance;
  final Uint8List screenshotBytes =
      Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 7, 8, 9]);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
    capture.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = true;
    GalgameAudioCaptureController.debugWindowCaptureOverride =
        (int hwnd) async => WindowCaptureResult(pngBytes: screenshotBytes);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(captureChannel, null);
    DesktopLookupService.instance.debugReset();
    capture.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = null;
  });

  testWidgets(
      'clipboard lookup preserves its audio occurrence and full sentence for mining',
      (WidgetTester tester) async {
    final List<MethodCall> captureCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(captureChannel, (MethodCall call) async {
      captureCalls.add(call);
      if (call.method == 'exportAudio') {
        final Map<Object?, Object?> args =
            call.arguments! as Map<Object?, Object?>;
        final String outputPath = args['outputPath']! as String;
        File(outputPath).writeAsBytesSync(<int>[1, 2, 3], flush: true);
        return <String, Object?>{'ok': true, 'path': outputPath};
      }
      return <String, Object?>{'ok': true};
    });
    expect(await capture.start(game), isTrue);

    final _GalgameMiningAppModel appModel = _GalgameMiningAppModel();
    final _CapturingAnkiRepository ankiRepository = _CapturingAnkiRepository();
    final Directory mediaDirectory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'hibiki-galgame-widget-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    GalgameAudioCaptureController.debugExportOccurrenceOverride = (
      String occurrenceId, {
      required bool compressPicture,
    }) {
      expect(compressPicture, isTrue);
      final File audio = File(
        '${mediaDirectory.path}${Platform.pathSeparator}$occurrenceId.mp3',
      )..writeAsBytesSync(<int>[1, 2, 3], flush: true);
      final File picture = File(
        '${mediaDirectory.path}${Platform.pathSeparator}'
        '$occurrenceId-picture.png',
      )..writeAsBytesSync(screenshotBytes, flush: true);
      return GalgameMiningMedia(
        audioPath: audio.path,
        picturePath: picture.path,
      );
    };
    await tester.pumpWidget(_wrap(appModel, ankiRepository));
    await tester.pump();

    const String lunaSentence = '彼女は斜めにこちらを見た。';
    DesktopLookupService.instance.processClipboardText(lunaSentence);
    await tester.pump();
    await tester.pump();

    final HomeDictionarySearchDebug debug = _debug(tester);
    expect(appModel.searchedTerms, <String>[lunaSentence]);
    expect(debug.debugAudioOccurrenceId, isNotNull);
    expect(
      debug.debugResolveSentenceForMining(<String, String>{
        'expression': '斜めに',
        'sentence': '',
      }),
      lunaSentence,
    );
    expect(
      debug.debugResolveSentenceForMining(<String, String>{
        'sentence': 'popup sentence',
      }),
      'popup sentence',
      reason: 'A future popup-provided sentence must remain authoritative.',
    );

    final MethodCall markCall = captureCalls.singleWhere(
      (MethodCall call) => call.method == 'mark',
    );
    final Map<Object?, Object?> markArgs =
        markCall.arguments! as Map<Object?, Object?>;
    expect(markArgs['occurrenceId'], debug.debugAudioOccurrenceId);
    final WindowCaptureResult prefetchedPicture =
        await capture.debugPendingPicture(debug.debugAudioOccurrenceId!)!;
    expect(prefetchedPicture.ok, isTrue);
    expect(prefetchedPicture.pngBytes, screenshotBytes);

    await tester.runAsync<Object?>(() async {
      await debug.debugMineEntry(<String, String>{
        'expression': '斜めに',
        'matched': '斜めに',
        'dictionaryMedia': '',
      });
      return null;
    });
    expect(ankiRepository.captured, isNotNull);
    expect(ankiRepository.captured!.sentence, lunaSentence);
    expect(ankiRepository.captured!.sasayakiAudioPath, endsWith('.mp3'));
    expect(ankiRepository.captured!.coverPath, endsWith('.png'));
    expect(ankiRepository.captured!.requireCover, isTrue);
    expect(ankiRepository.coverExistedDuringMine, isTrue);
    expect(ankiRepository.coverBytesDuringMine, screenshotBytes);
    expect(File(ankiRepository.captured!.coverPath!).existsSync(), isFalse,
        reason: 'The main lookup page must clean its temporary screenshot.');
    expect(
        File(ankiRepository.captured!.sasayakiAudioPath!).existsSync(), isFalse,
        reason: 'The main lookup page must clean its temporary audio.');
    mediaDirectory.deleteSync(recursive: true);

    await tester.enterText(
      find.byKey(const ValueKey<String>('home_dictionary_search_field')),
      'manual lookup',
    );
    await tester.pump();
    expect(
      debug.debugResolveSentenceForMining(<String, String>{'sentence': ''}),
      isEmpty,
      reason: 'A later manual query must not reuse the Luna sentence context.',
    );
  });
}
