import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/focus_driver.dart';
import 'helpers/game_stream_lan_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// Run only with tool/run_game_stream_android_qa.ps1. The separate package is
/// mandatory: this fixture must never provision or clear the user's app data.
/// Credentials enter through run-as stdin into an app-private file, never Dart
/// defines, assets, source code, test output, or process arguments.
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android receives a locally started Windows game session',
    (WidgetTester tester) async {
      final GameStreamFlutterErrorRecorder flutterErrors =
          GameStreamFlutterErrorRecorder();
      addTearDown(flutterErrors.restore);
      expect(Platform.isAndroid, isTrue);
      final PackageInfo package = await PackageInfo.fromPlatform();
      expect(package.packageName, 'app.fushi.reader.streamqa');
      final Directory support = await getApplicationSupportDirectory();
      final _Credentials credentials = await _Credentials.read(
        File('${support.path}/game_stream_lan_credentials.private.json'),
      );
      final Map<String, Object?> evidence = <String, Object?>{
        'version': 1,
        'packageName': package.packageName,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'sessionId': credentials.sessionId,
        'pairingMode': credentials.fixture['pairingMode'],
        'status': 'running',
        'uiInputCoverage': 'focus gamepad confirm, drawer and token',
        'inputEffectVerified': false,
        'mineCoverage': 'production controller and authenticated HTTP',
      };
      final File report = File('${support.path}/game_stream_lan_result.json');
      Future<void> save() async {
        await report.writeAsString(jsonEncode(evidence), flush: true);
        binding.reportData = evidence;
      }

      FushiGameStreamReceiver? receiver;
      GameStreamInputComposer? composer;
      GameStreamLookupController? lookup;
      FushiGameStreamClient? client;
      SyncRepository? repository;
      RTCPeerConnection? peerConnection;
      bool surfaceConverted = false;
      Future<void> captureVideoScreenshot(String stage) async {
        if (receiver?.ready != true) return;
        try {
          if (!surfaceConverted) {
            await binding.convertFlutterSurfaceToImage();
            surfaceConverted = true;
          }
          await tester.pump(const Duration(milliseconds: 300));
          final List<int> screenshot = await binding.takeScreenshot(
            'game-stream-$stage',
          );
          await File(
            '${support.path}/game_stream_lan.png',
          ).writeAsBytes(screenshot, flush: true);
          evidence['screenshotStage'] = stage;
          evidence['screenshotSavedAt'] = DateTime.now()
              .toUtc()
              .toIso8601String();
        } catch (error) {
          // Visual evidence is best effort and must preserve a lookup/mine error.
          evidence['screenshotErrorType'] = error.runtimeType.toString();
        } finally {
          // Keep image bytes in the private file, never in JSON or test logs.
          evidence.remove('screenshots');
        }
      }

      Future<void> recordRtpEvidence() async {
        final RTCPeerConnection? connection = peerConnection;
        if (connection == null) return;
        final List<Map<String, Object?>> inbound = await _inboundRtpStats(
          connection,
        );
        evidence['inboundRtp'] = inbound;
        final List<num> audioEnergy = inbound
            .where(
              (Map<String, Object?> item) =>
                  item['kind'] == 'audio' || item['mediaType'] == 'audio',
            )
            .map((Map<String, Object?> item) => item['totalAudioEnergy'])
            .whereType<num>()
            .toList();
        evidence['audioEnergyStatus'] = audioEnergy.isEmpty
            ? 'unavailable'
            : audioEnergy.any((num energy) => energy > 0)
            ? 'nonzero'
            : 'silent';
      }

      final List<Map<String, Object?>> acknowledgements =
          <Map<String, Object?>>[];
      try {
        await save();
        flutterErrors.install();
        await launchFushiTestApp();
        flutterErrors.install();
        expect(await waitForHome(tester), isTrue, reason: 'Home must render');
        final AppModel model = await enableFocusNavigation(tester);
        expect(model.isInitialised, isTrue);
        repository = SyncRepository(model.database);
        final FushiClientUrl peer = credentials.peer;
        await repository.setFushiClientUrls(<FushiClientUrl>[peer]);
        client = FushiGameStreamClient(
          transport: InterconnectGameStreamTransport(repo: repository),
          timeout: const Duration(seconds: 10),
        )..bindPeer(peer);
        final List<GameStreamSession> sessions = await client.listSessions(
          clientId: credentials.clientId,
        );
        expect(
          sessions.any(
            (GameStreamSession s) => s.sessionId == credentials.sessionId,
          ),
          isTrue,
        );
        final GameStreamSession? joined = await client.join(
          sessionId: credentials.sessionId,
          clientId: credentials.clientId,
          clientName: credentials.clientName,
        );
        expect(joined, isNotNull);
        final String clientId = client.effectiveClientId(credentials.clientId);
        lookup = GameStreamLookupController(
          lookupClient: InterconnectGameStreamDictionaryLookup(
            repo: repository,
            peer: peer,
          ),
          streamClient: client,
          clientId: clientId,
        );
        final List<GameStreamTextEvent> lines = <GameStreamTextEvent>[];
        receiver = FushiGameStreamReceiver(
          client: client,
          onTextEvent: (GameStreamTextEvent line) {
            lines.add(line);
            lookup!.applyTextEvent(line);
          },
          onInputAck: (GameStreamInputAck ack) {
            acknowledgements.add(<String, Object?>{
              'sequence': ack.sequence,
              'accepted': ack.accepted,
              'reason': ack.reason,
            });
            composer?.applyAck(ack);
          },
          // Keep the genuine native peer for receive-side RTP evidence. This is
          // the same LAN-only configuration as the production factory.
          peerFactory: () async {
            final RTCPeerConnection pc = await createPeerConnection(
              <String, dynamic>{
                'iceServers': <Map<String, dynamic>>[],
                'sdpSemantics': 'unified-plan',
              },
            );
            peerConnection = pc;
            return pc;
          },
        );
        composer = GameStreamInputComposer(
          sessionId: credentials.sessionId,
          clientId: clientId,
          sender: receiver.sendInput,
        );
        await receiver.connect(
          sessionId: credentials.sessionId,
          clientId: clientId,
        );
        final NavigatorState navigator = Navigator.of(
          tester.element(find.byType(Scaffold).first),
        );
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => GameStreamPage(
                sessionId: credentials.sessionId,
                clientId: clientId,
                inputComposer: composer!,
                lookupController: lookup,
                receiver: receiver,
              ),
            ),
          ),
        );
        await _until(tester, () => receiver!.ready, 'remote video first frame');
        evidence['videoWidth'] = receiver.renderer.videoWidth;
        evidence['videoHeight'] = receiver.renderer.videoHeight;
        evidence['firstFrameRendered'] = true;
        await captureVideoScreenshot('first-frame');
        await save();
        await _until(
          tester,
          () =>
              receiver!.controlChannel?.state ==
              RTCDataChannelState.RTCDataChannelOpen,
          'ordered control channel',
        );

        final FocusDriver focus = FocusDriver(tester);
        await _until(
          tester,
          () => lookup!.currentLine != null,
          'Hook text over the data channel',
        );
        if (credentials.fixture['expectAudio'] == true) {
          await _until(
            tester,
            () => lines.any(
              (GameStreamTextEvent line) =>
                  line.lineId == lookup!.currentLine?.lineId &&
                  line.text == lookup.currentLine?.text &&
                  line.audioResourceId != null,
            ),
            'voice resource for the current Hook line',
          );
        }
        // Bind lookup and mining to the voiced line the operator prepared.
        // Input is tested only after this line's host-side card is verified.
        final GameStreamTextEvent preparedLine = lookup.currentLine!;
        bool preparedLineIsCurrent() =>
            lookup!.currentLine?.lineId == preparedLine.lineId &&
            lookup.currentLine?.text == preparedLine.text;
        evidence['preparedLine'] = _lineEvidence(preparedLine);
        await save();
        expect(
          await focus.focusWidget(find.byTooltip(t.game_stream_lookup_toggle)),
          isTrue,
        );
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);

        // Navigate the visible transcript caret through the production keyboard
        // path; no coordinate injection or direct lookup invocation selects it.
        final List<String> terms =
            (credentials.fixture['lookupTerms'] as List<dynamic>)
                .cast<String>();
        int sourceOffset = -1;
        await _until(tester, () {
          final String sentence = lookup!.currentLine?.text ?? '';
          for (final String term in terms) {
            sourceOffset = sentence.indexOf(term);
            if (sourceOffset >= 0) return true;
          }
          return false;
        }, 'a dictionary fixture term in the live Hook line');
        expect(
          preparedLineIsCurrent(),
          isTrue,
          reason: 'The prepared voiced line changed before lookup',
        );
        final String sourceSentence = preparedLine.text;
        final int caretIndex = sourceSentence
            .substring(0, sourceOffset)
            .characters
            .length;
        final Finder paragraph = find.byKey(GameStreamPage.transcriptTextKey);
        expect(await focus.focusWidget(paragraph), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        for (int i = 0; i < caretIndex; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await focus.activate();
        await _until(
          tester,
          () => lookup!.result?.entries.isNotEmpty == true,
          'remote dictionary result',
        );
        expect(find.byType(DictionaryPopupLayer), findsOneWidget);
        final DictionaryEntry entry = lookup.result!.entries.firstWhere(
          (DictionaryEntry e) =>
              e.dictionaryName == credentials.fixture['dictionaryName'],
        );
        expect(
          preparedLineIsCurrent(),
          isTrue,
          reason: 'The prepared voiced line changed during lookup',
        );
        final GameStreamTextEvent selectedLine = preparedLine;
        evidence['lookup'] = <String, Object?>{
          'lineId': selectedLine.lineId,
          'sentence': selectedLine.text,
          'expression': entry.word,
          'dictionaryName': entry.dictionaryName,
        };
        await save();

        // A second query exercises the same recursive-lookup controller path;
        // this does not claim native WebView text-selection gestures were tested.
        await lookup.lookup(entry.word);
        expect(lookup.result?.entries, isNotEmpty);
        expect(
          preparedLineIsCurrent(),
          isTrue,
          reason: 'The prepared voiced line changed before mining',
        );
        final GameStreamMineResult? mined = await lookup.mine(<String, String>{
          'expression': entry.word,
          'reading': entry.reading,
          'glossary': entry.meaning,
        });
        evidence['mine'] = mined?.toJson();
        expect(
          mined?.ok,
          isTrue,
          reason: 'Windows must execute its existing mining chain',
        );
        if (credentials.fixture['expectAudio'] == true) {
          expect(mined?.detail, isNot('sentence_audio_missing'));
        }

        // Preserve the prepared sentence's completed mining evidence before
        // advancing the game. The next line may legitimately have no voice.
        await save();
        expect(
          await focus.focusWidget(find.byTooltip(t.game_stream_lookup_toggle)),
          isTrue,
        );
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);

        expect(await focus.focusWidget(find.text('A')), isTrue);
        final GameStreamTextEvent? lineBeforeInput = lookup.currentLine;
        final int eventsBeforeInput = lines.length;
        final Map<String, Object?> beforeInput = _lineEvidence(lineBeforeInput);
        evidence['inputResponse'] = <String, Object?>{
          'status': 'pending',
          'before': beforeInput,
          'causalProof': 'unverified',
        };
        await save();
        final int downSequence = composer.nextSequence;
        final Map<String, Object?> inputTiming = <String, Object?>{
          'holdAfterDownAckMs': 200,
          'keyDownSequence': downSequence,
          'keyUpSequence': downSequence + 1,
        };
        evidence['inputTiming'] = inputTiming;
        final Stopwatch press = Stopwatch()..start();
        inputTiming['downSentAt'] = DateTime.now().toUtc().toIso8601String();
        try {
          // Model a human press on the real focused A control. The production
          // input path keeps its normal timing; only this fixture holds the key.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
          await _until(
            tester,
            () => composer!.lastAcceptedSequence >= downSequence,
            'target-window key down acknowledgement',
          );
          inputTiming['downAckAt'] = DateTime.now().toUtc().toIso8601String();
          await tester.pump(const Duration(milliseconds: 200));
        } finally {
          inputTiming['upSentAt'] = DateTime.now().toUtc().toIso8601String();
          inputTiming['actualPressMs'] = press.elapsedMilliseconds;
          await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        }
        await _until(
          tester,
          () => composer!.lastAcceptedSequence >= downSequence + 1,
          'target-window key up acknowledgement',
        );
        inputTiming['upAckAt'] = DateTime.now().toUtc().toIso8601String();
        expect(composer.lastRejectedSequence, 0);
        evidence['inputAcks'] = acknowledgements;
        // ACK means the host accepted window-targeted messages. It does not
        // demonstrate that a DirectInput game consumed them. Observe a bounded
        // period without sending more keys, and preserve the actual text delta.
        final DateTime responseDeadline = DateTime.now().add(
          const Duration(seconds: 3),
        );
        bool textChanged() =>
            lookup!.currentLine?.text != lineBeforeInput?.text;
        while (!textChanged() && DateTime.now().isBefore(responseDeadline)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        evidence['inputResponse'] = <String, Object?>{
          'status': textChanged() ? 'observed_text_change' : 'unverified',
          'before': beforeInput,
          'after': _lineEvidence(lookup.currentLine),
          'textChanged': textChanged(),
          'newTextEvents': lines.length - eventsBeforeInput,
          'keyDownSequence': downSequence,
          'keyUpSequence': downSequence + 1,
          // Auto-advance and a user's local actions can also change text. Even
          // a delta is observational evidence, not proof of input causality.
          'causalProof': 'unverified',
          'observationLimitSeconds': 3,
        };
        await save();
        expect(
          await focus.focusWidget(find.byTooltip(t.game_stream_lookup_toggle)),
          isTrue,
        );
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);
        await recordRtpEvidence();
        await save();
        final List<Map<String, Object?>> inbound =
            evidence['inboundRtp']! as List<Map<String, Object?>>;
        final List<Map<String, Object?>> audio = inbound
            .where(
              (Map<String, Object?> item) =>
                  item['kind'] == 'audio' || item['mediaType'] == 'audio',
            )
            .toList();
        if (credentials.fixture['expectAudio'] == true) {
          expect(
            audio,
            isNotEmpty,
            reason: 'Receive-side audio RTP is required',
          );
          expect(
            audio.any(
              (Map<String, Object?> item) =>
                  (item['bytesReceived'] as num? ?? 0) > 0,
            ),
            isTrue,
          );
          if (evidence['audioEnergyStatus'] != 'unavailable') {
            expect(
              evidence['audioEnergyStatus'],
              'nonzero',
              reason: 'Received audio must contain nonzero energy',
            );
          }
        }
        evidence['receivedLines'] = lines
            .map(
              (GameStreamTextEvent e) => <String, Object?>{
                'lineId': e.lineId,
                'text': e.text,
                'timestampMs': e.timestampMs,
              },
            )
            .toList();
        await captureVideoScreenshot('passed');
        evidence['status'] = 'passed';
        evidence['endedAt'] = DateTime.now().toUtc().toIso8601String();
        await save();
        navigator.pop();
        await tester.pump(const Duration(milliseconds: 300));
      } catch (error) {
        evidence['status'] = 'failed';
        // Exception text may contain transport information; keep only its type/code.
        evidence.addAll(gameStreamFailureSummary(error));
        if (error is GameStreamRequestError) {
          evidence['failureCode'] = error.code;
          evidence['failureHttpStatus'] = error.statusCode;
        }
        await captureVideoScreenshot('failed');
        await save();
        rethrow;
      } finally {
        final Map<String, Object?>? flutterFailure = flutterErrors.lastFailure;
        flutterErrors.restore();
        // Preserve receive-side evidence even when text, lookup, or mining fails.
        // A stats failure must not hide the original stage's exception.
        try {
          await recordRtpEvidence();
        } catch (error) {
          evidence['inboundRtpErrorType'] = error.runtimeType.toString();
        }
        await save();
        await receiver?.disconnect();
        if (client != null) {
          try {
            await client.stop(
              sessionId: credentials.sessionId,
              clientId: client.effectiveClientId(credentials.clientId),
              reason: 'receiver_left',
            );
          } catch (_) {}
        }
        receiver?.dispose();
        composer?.dispose();
        lookup?.dispose();
        await repository?.setFushiClientUrls(<FushiClientUrl>[]);
        // Pairing exists only for this run. Remove the credential file even when
        // an assertion fails; the script provisions it afresh for another run.
        final File credentialsFile = File(
          '${support.path}/game_stream_lan_credentials.private.json',
        );
        if (evidence['status'] != 'passed' &&
            !evidence.containsKey('failureType') &&
            flutterFailure != null) {
          evidence.addAll(flutterFailure);
          await save();
        }
        if (await credentialsFile.exists()) await credentialsFile.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<List<Map<String, Object?>>> _inboundRtpStats(
  RTCPeerConnection connection,
) async {
  final List<Map<String, Object?>> inbound = <Map<String, Object?>>[];
  final List<StatsReport> reports = await connection.getStats().timeout(
    const Duration(seconds: 5),
  );
  for (final StatsReport stat in reports) {
    if (stat.type != 'inbound-rtp') continue;
    final Map<dynamic, dynamic> values = stat.values;
    inbound.add(<String, Object?>{
      for (final String key in <String>[
        'kind',
        'mediaType',
        'bytesReceived',
        'packetsReceived',
        'framesDecoded',
        'totalSamplesReceived',
        'totalAudioEnergy',
      ])
        if (values.containsKey(key)) key: values[key],
    });
  }
  return inbound;
}

Map<String, Object?> _lineEvidence(GameStreamTextEvent? line) =>
    <String, Object?>{
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'lineId': line?.lineId,
      'textSha256': line == null
          ? null
          : sha256.convert(utf8.encode(line.text)).toString(),
      'textLength': line?.text.length,
    };

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(ready(), isTrue, reason: label);
}

class _Credentials {
  const _Credentials(
    this.peer,
    this.sessionId,
    this.clientId,
    this.clientName,
    this.fixture,
  );
  final FushiClientUrl peer;
  final String sessionId;
  final String clientId;
  final String clientName;
  final Map<String, dynamic> fixture;

  static Future<_Credentials> read(File file) async {
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final Uri host = Uri.parse(json['hostUrl'] as String);
      if (json['version'] != 1 ||
          host.scheme != 'https' ||
          host.userInfo.isNotEmpty ||
          (json['token'] as String).isEmpty ||
          (json['tlsFingerprint'] as String).isEmpty) {
        throw const FormatException();
      }
      return _Credentials(
        FushiClientUrl(
          url: host.toString(),
          token: json['token'] as String,
          fingerprintSha256: json['tlsFingerprint'] as String,
          deviceName: 'Windows LAN QA',
        ),
        json['sessionId'] as String,
        json['clientId'] as String,
        json['clientName'] as String,
        json['fixture'] as Map<String, dynamic>,
      );
    } catch (_) {
      throw StateError('Missing or invalid private LAN QA credentials');
    }
  }
}
