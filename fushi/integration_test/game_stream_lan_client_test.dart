import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'support/test_app_launcher.dart';

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
      final List<Map<String, Object?>> acknowledgements =
          <Map<String, Object?>>[];
      try {
        await save();
        await launchFushiTestApp();
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
        await _until(
          tester,
          () =>
              receiver!.controlChannel?.state ==
              RTCDataChannelState.RTCDataChannelOpen,
          'ordered control channel',
        );

        final FocusDriver focus = FocusDriver(tester);
        expect(await focus.focusWidget(find.text('A')), isTrue);
        final int downSequence = composer.nextSequence;
        await focus.activate();
        await _until(
          tester,
          () => composer!.lastAcceptedSequence >= downSequence + 1,
          'target-window key down/up acknowledgement',
        );
        expect(composer.lastRejectedSequence, 0);
        evidence['inputAcks'] = acknowledgements;
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
                  line.text == lookup!.currentLine?.text &&
                  line.audioResourceId != null,
            ),
            'voice resource for the current Hook line',
          );
        }
        expect(
          await focus.focusWidget(find.byTooltip(t.game_stream_lookup_toggle)),
          isTrue,
        );
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
        await focus.activate();
        expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);

        // Select a real displayed token by focus, without pixel-coordinate input.
        final List<String> terms =
            (credentials.fixture['lookupTerms'] as List<dynamic>)
                .cast<String>();
        Finder chip = find.byWidgetPredicate(
          (Widget widget) =>
              widget is ActionChip &&
              widget.label is Text &&
              terms.contains((widget.label as Text).data),
        );
        await _until(
          tester,
          () => chip.evaluate().isNotEmpty,
          'a dictionary fixture token in the live Hook line',
        );
        chip = chip.first;
        expect(await focus.focusWidget(chip), isTrue);
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
        final GameStreamTextEvent selectedLine = lookup.currentLine!;
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
        expect(lookup.currentLine?.lineId, selectedLine.lineId);
        expect(lookup.currentLine?.text, selectedLine.text);
        final GameStreamMineResult? mined = await lookup.mine(<String, String>{
          'word': entry.word,
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

        final List<Map<String, Object?>> inbound = <Map<String, Object?>>[];
        for (final StatsReport stat in await peerConnection!.getStats()) {
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
        evidence['inboundRtp'] = inbound;
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
        await binding.convertFlutterSurfaceToImage();
        await tester.pump(const Duration(milliseconds: 300));
        final List<int> screenshot = await binding.takeScreenshot(
          'game-stream-lan',
        );
        await File(
          '${support.path}/game_stream_lan.png',
        ).writeAsBytes(screenshot, flush: true);
        // Screenshot bytes are a private file, not a huge JSON/log attachment.
        evidence.remove('screenshots');
        evidence['status'] = 'passed';
        evidence['endedAt'] = DateTime.now().toUtc().toIso8601String();
        await save();
        navigator.pop();
        await tester.pump(const Duration(milliseconds: 300));
      } catch (error) {
        evidence['status'] = 'failed';
        // Exception text may contain transport information; keep only its type.
        evidence['failureType'] = error.runtimeType.toString();
        await save();
        rethrow;
      } finally {
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
        if (await credentialsFile.exists()) await credentialsFile.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

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
