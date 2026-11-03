// Debug-only demo of the game stream's second-display panel, for checking it
// on an emulator or device without a Windows game host:
//
//   flutter build apk --debug -t integration_test/game_stream_companion_demo_main.dart
//   adb shell settings put global overlay_display_devices 1240x1080/320
//
// It opens GameStreamPage with a fake line, a fake dictionary and an input
// log in place of the video. Never part of the shipped app: lib/main.dart
// does not import it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/game_stream_companion_main.dart' as companion;
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/platform/game_stream_companion_display_channel.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// The companion engine resolves its entry point in the root library.
@pragma('vm:entry-point')
void gameStreamCompanionMain() => companion.gameStreamCompanionMain();

void main() {
  if (!kDebugMode) {
    throw StateError('game stream companion demo is debug-only');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(TranslationProvider(child: const _DemoApp()));
}

class _DemoApp extends StatefulWidget {
  const _DemoApp();

  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  final ValueNotifier<List<String>> _inputLog = ValueNotifier<List<String>>(
    const <String>[],
  );
  late final GameStreamInputComposer _composer = GameStreamInputComposer(
    sessionId: 'demo',
    clientId: 'demo-receiver',
    sender: (GameStreamInputEvent event) async {
      final String what = event.button ?? event.key ?? '${event.kind}';
      _inputLog.value = <String>[
        '${event.action.name} $what',
        ..._inputLog.value,
      ].take(8).toList();
      return GameStreamInputAck(sequence: event.sequence, accepted: true);
    },
  );
  late final GameStreamLookupController _lookup =
      GameStreamLookupController(
        lookupClient: _DemoLookup(),
        streamClient: FushiGameStreamClient(transport: _DemoTransport()),
        clientId: 'demo-receiver',
      )..applyTextEvent(
        GameStreamTextEvent(
          sessionId: 'demo',
          lineId: 'demo-1',
          text: '今日はいい天気ですね。散歩に行きましょう。',
          timestampMs: 1,
        ),
      );
  final GameStreamCompanionDisplay? _companion =
      GameStreamCompanionDisplay.forCurrentPlatform();

  @override
  void dispose() {
    _companion?.dispose();
    _composer.dispose();
    _lookup.dispose();
    _inputLog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildFushiFallbackTheme(Brightness.dark),
      home: GameStreamPage(
        sessionId: 'demo',
        clientId: 'demo-receiver',
        inputComposer: _composer,
        lookupController: _lookup,
        companionDisplay: _companion,
        secondScreen: GameStreamSecondScreen.auto,
        videoPlaceholder: ColoredBox(
          color: const Color(0xFF203040),
          child: Center(
            child: ValueListenableBuilder<List<String>>(
              valueListenable: _inputLog,
              builder: (BuildContext context, List<String> log, Widget? _) =>
                  Text(
                    'DEMO GAME FRAME\n\ninput sent to host:\n${log.join('\n')}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoLookup implements GameStreamDictionaryLookup {
  @override
  DictionaryPopupResourceSource? get popupResources => null;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final String word = term.characters.take(2).toString();
    return DictionarySearchResult(
      searchTerm: term,
      bestLength: word.length,
      headwordCount: 1,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'Demo',
          word: word,
          reading: word,
          meaning: 'demo meaning for 「$word」 (looked up "$term")',
        ),
      ],
    );
  }
}

class _DemoTransport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => GameStreamPostResult(
    json: path.endsWith('/mine')
        ? <String, dynamic>{
            'result': <String, dynamic>{
              'version': kGameStreamWireVersion,
              'ok': true,
              'message': 'demo card',
            },
          }
        : null,
  );
}
