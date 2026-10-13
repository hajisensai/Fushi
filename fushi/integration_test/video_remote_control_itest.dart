/// Real desktop player + authenticated HTTP phone surrogate + isolated Anki.
/// Run through tool/run_windows_itest.ps1; this does not validate Android UI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart'
    show FlutterError, FlutterExceptionHandler;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebView;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHostPageRoute;
import 'package:fushi/src/utils/window_caption_channel.dart'
    show WindowCaptionChannel;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'support/fake_ankiconnect.dart';
import 'support/fake_ankiconnect_setup.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _sentence = '猫がいる';
const String _peerToken = 'video-remote-integration-paired-token';
const int _phoneHoldSeconds = int.fromEnvironment(
  'VIDEO_REMOTE_PHONE_HOLD_SECONDS',
);

final class _RecordedVideoRemoteService implements VideoRemoteService {
  _RecordedVideoRemoteService(this.delegate);

  final VideoRemoteService delegate;
  final List<String> completedOperations = <String>[];

  @override
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    final Map<String, Object?> result = await delegate.handle(
      operation,
      body,
      peerId,
    );
    completedOperations.add(operation);
    return result;
  }
}

Future<void> _assertCardMedia(
  FakeAnkiConnect anki,
  Map<String, Object?> note,
) async {
  final Map<dynamic, dynamic> fields = note['fields']! as Map;
  final String values = fields.values.join(' ');
  expect(values, contains(_sentence));
  final RegExp audioReference = RegExp(r'\[sound:([^\]]+)\]');
  final RegExp imageReference = RegExp(r'''<img[^>]+src=["']([^"']+)["']''');
  final List<String> references = <String>[
    ...audioReference.allMatches(values).map((RegExpMatch m) => m.group(1)!),
    ...imageReference.allMatches(values).map((RegExpMatch m) => m.group(1)!),
  ];
  expect(
    audioReference.hasMatch(values),
    true,
    reason: 'Extracted audio required',
  );
  expect(
    imageReference.hasMatch(values),
    true,
    reason: 'Extracted frame required',
  );
  for (final String name in references) {
    expect(
      anki.mediaFileNames,
      contains(name),
      reason: 'Every card media reference must exist in isolated Anki: $name',
    );
    expect(
      await File('${anki.mediaDirPath}${Platform.pathSeparator}$name').length(),
      greaterThan(0),
      reason: 'Stored media cannot be empty: $name',
    );
  }
}

Future<String> _seedVideoWithSrt(
  VideoBookRepository repo,
  Directory dir,
) async {
  final String path = '${dir.path}${Platform.pathSeparator}remote-control.mp4';
  final File video = await generateTestVideo(
    outPath: path,
    duration: Duration(
      seconds: 30 + (_phoneHoldSeconds > 0 ? _phoneHoldSeconds : 0),
    ),
  );
  if (!await video.exists() || await video.length() == 0) {
    throw StateError('ffmpeg must generate a non-empty integration fixture');
  }
  await File(
    '${dir.path}${Platform.pathSeparator}remote-control.srt',
  ).writeAsString(
    '1\n00:00:00,500 --> 00:00:03,500\n$_sentence\n\n'
    '2\n00:00:04,000 --> 00:00:08,000\n猫が寝ている\n',
  );
  final String uid = singleVideoBookUid(video.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(uid),
      title: const Value('remote-control'),
      videoPath: Value(video.absolute.path),
    ),
  );
  return uid;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'HTTP phone controls real fullscreen player, mines media and manages DB favorites',
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = testErrorHandler);
      final Directory temp = await Directory.systemTemp.createTemp(
        'fushi-remote-itest-',
      );
      FakeAnkiConnect? anki;
      FushiSyncServer? server;
      final HttpClient http = HttpClient();
      try {
        await launchFushiTestApp();
        final bool homeReady = await waitForHome(tester);
        // Startup installs the production logger. Restore the binding handler
        // before assertions so a real failure keeps its original diagnostics.
        FlutterError.onError = testErrorHandler;
        expect(homeReady, true, reason: 'App must initialize');
        debugPrint('[video-remote-desktop] home initialized');
        final AppModel appModel = await readyAppModel(tester);
        // Record the phone-surrogate operations that actually reached the host so
        // the test proves the HTTP layer drove the real player, not just the UI.
        final _RecordedVideoRemoteService recording =
            _RecordedVideoRemoteService(appModel.videoRemoteHost);
        await enableFocusNavigation(tester);
        expect(
          await seedDictionary(tester),
          true,
          reason: 'Generated dictionary must load',
        );
        anki = await FakeAnkiConnect.start();
        await configureFakeAnkiConnect(tester, anki);
        debugPrint('[video-remote-desktop] isolated Anki configured');
        final VideoBookRepository repo = VideoBookRepository(appModel.database);
        final String uid = await _seedVideoWithSrt(repo, temp);
        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
            ),
          ),
        );

        VideoFushiTestHooks hooks() =>
            tester.state<State<VideoFushiPage>>(
                  find.byType(VideoFushiPage, skipOffstage: false).first,
                )
                as VideoFushiTestHooks;
        for (int i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(Video).evaluate().isNotEmpty &&
              hooks().debugCueCount > 0) {
            break;
          }
        }
        expect(
          find.byType(Video),
          findsWidgets,
          reason: 'Real media_kit video must render',
        );
        expect(
          hooks().debugCueCount,
          greaterThan(0),
          reason: 'Generated sidecar must load',
        );
        debugPrint('[video-remote-desktop] real player and sidecar ready');

        final FocusDriver driver = FocusDriver(tester);
        expect(
          await driver.requestFocusInside(find.byType(Video)),
          true,
          reason: 'Video must own focus for its production fullscreen shortcut',
        );
        // The chrome auto-hides while native playback becomes ready. Use the
        // actual focus-scoped shortcut instead of indexing a hidden icon.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        debugPrint('[video-remote-desktop] fullscreen shortcut activated');
        bool fullscreen() => find
            .byType(Video)
            .evaluate()
            .any(
              (Element element) =>
                  ModalRoute.of(element)
                      is WindowFullscreenHostPageRoute<void> &&
                  ModalRoute.of(element)!.isCurrent,
            );
        for (int i = 0; i < 40 && !fullscreen(); i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          fullscreen(),
          true,
          reason: 'Focus activation must enter the actual fullscreen route',
        );
        expect(
          await WindowCaptionChannel.isFullscreen(),
          true,
          reason:
              'Player route must also enter the real native fullscreen window',
        );
        debugPrint('[video-remote-desktop] fullscreen route confirmed');
        void assertImmersive() {
          expect(
            fullscreen(),
            true,
            reason: 'Phone operation must retain fullscreen route',
          );
          expect(
            find.byType(DictionaryPopupWebView, skipOffstage: false),
            findsNothing,
            reason:
                'Phone lookup/mining must not create a desktop dictionary popup',
          );
        }

        server = FushiSyncServer(
          syncDataDir: temp.path,
          port: 0,
          token: 'legacy-not-used',
          allowLan: _phoneHoldSeconds > 0,
          remoteLookupService: appModel.createRemoteLookupService(),
          videoRemoteService: recording,
        );
        server.pairedPeerTokensProvider = () async => <String>{_peerToken};
        await server.start();
        int requestSerial = 0;
        Map<String, dynamic> state = <String, dynamic>{};
        Future<Map<String, dynamic>> phone(
          String operation, [
          Map<String, dynamic> data = const <String, dynamic>{},
        ]) async {
          debugPrint('[video-remote-desktop] HTTP $operation begin');
          final Map<String, dynamic>? result = await tester.runAsync(() async {
            final HttpClientRequest request = await http.postUrl(
              Uri.parse(
                'http://127.0.0.1:${server!.port}/api/video-remote/$operation',
              ),
            );
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Basic ${base64Encode(utf8.encode('phone:$_peerToken'))}',
            );
            request.headers.contentType = ContentType.json;
            request.write(
              jsonEncode(<String, dynamic>{
                'sessionId': state['sessionId'],
                'subtitleVersion': state['subtitleVersion'],
                'requestId': 'itest_${++requestSerial}',
                ...data,
              }),
            );
            final HttpClientResponse response = await request.close();
            final String text = await utf8.decoder.bind(response).join();
            expect(
              response.statusCode,
              200,
              reason: '$operation failed: $text',
            );
            return jsonDecode(text) as Map<String, dynamic>;
          });
          await tester.pump();
          debugPrint('[video-remote-desktop] HTTP $operation complete');
          return result!;
        }

        state = await phone('snapshot');
        expect(state['available'], true);
        final Map<String, dynamic> subtitles = await phone('subtitles');
        final List<dynamic> cues = subtitles['cues'] as List<dynamic>;
        final Map<String, dynamic> cue =
            (cues.firstWhere(
                      (dynamic item) => (item as Map)['text'] == _sentence,
                    )
                    as Map)
                .cast<String, dynamic>();
        await phone('command', <String, dynamic>{
          'action': 'seekCue',
          'cueId': cue['id'],
        });
        for (int i = 0; i < 20 && !hooks().debugIsPlaying; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(hooks().debugIsPlaying, true);
        final Map<String, dynamic> lookup = await phone(
          'lookupBegin',
          <String, dynamic>{'cueId': cue['id']},
        );
        for (int i = 0; i < 20 && hooks().debugIsPlaying; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          hooks().debugIsPlaying,
          false,
          reason: 'Lookup must pause real mpv',
        );
        assertImmersive();
        final Map<String, dynamic> draft = <String, dynamic>{
          'requestId': 'mine-once',
          'contextId': lookup['contextId'],
          'fields': <String, dynamic>{
            'rawFields': <String, String>{
              'expression': '猫',
              'reading': 'ねこ',
              'glossary': 'cat',
            },
            'sentence': _sentence,
          },
        };
        Map<String, dynamic> task = await phone('mine', draft);
        final Map<String, dynamic> duplicate = await phone('mine', draft);
        expect(duplicate['taskId'], task['taskId']);
        for (int i = 0; i < 240 && task['status'] == 'running'; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          task = await phone('mineStatus', <String, dynamic>{
            'taskId': task['taskId'],
          });
          assertImmersive();
        }
        expect(
          task['status'],
          'succeeded',
          reason: 'Real ffmpeg/mining must finish: $task',
        );
        expect(
          anki.notes,
          hasLength(1),
          reason: 'Retry must not create a duplicate card',
        );
        await _assertCardMedia(anki, anki.notes.single);
        await phone('favoriteSet', <String, dynamic>{
          'cueId': cue['id'],
          'favorited': true,
        });
        final FavoriteSentenceRepository favorites = FavoriteSentenceRepository(
          appModel.database,
        );
        final List<FavoriteSentence> stored = (await favorites.getAll())
            .where(
              (FavoriteSentence favorite) =>
                  favorite.bookKey == uid && favorite.text == _sentence,
            )
            .toList();
        expect(
          stored,
          hasLength(1),
          reason: 'Phone favorite must persist to actual app DB',
        );
        final Map<String, dynamic> remoteFavorites = await phone(
          'favorites',
          <String, dynamic>{'currentOnly': true, 'query': _sentence},
        );
        expect(remoteFavorites['total'], 1);
        expect(
          (remoteFavorites['items'] as List<dynamic>).single,
          containsPair('id', stored.single.id),
          reason: 'Phone favorites must expose the persisted DB record',
        );
        assertImmersive();
        await phone('favoritesRemove', <String, dynamic>{
          'ids': <String>[stored.single.id],
        });
        expect(
          (await favorites.getAll()).any(
            (FavoriteSentence favorite) => favorite.id == stored.single.id,
          ),
          false,
        );
        await phone('lookupEnd', <String, dynamic>{
          'contextId': lookup['contextId'],
        });
        for (int i = 0; i < 20 && !hooks().debugIsPlaying; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          hooks().debugIsPlaying,
          true,
          reason: 'Closing phone dictionary must restore owned pause',
        );
        assertImmersive();
        await phone('disconnect');
        expect(
          recording.completedOperations,
          containsAll(<String>[
            'snapshot',
            'subtitles',
            'command',
            'lookupBegin',
            'mine',
            'favoriteSet',
            'favorites',
            'favoritesRemove',
            'lookupEnd',
            'disconnect',
          ]),
          reason: 'Every phone operation must reach the real host service',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 500));
      } finally {
        http.close(force: true);
        await server?.stop();
        await anki?.close();
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
