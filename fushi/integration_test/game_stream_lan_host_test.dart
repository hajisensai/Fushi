/// Opt-in Windows host for the Android LAN fixture. Requires the isolated runner.
///
/// Non-secret dart defines:
/// FUSHI_GS_RUN_LIVE=true, FUSHI_GS_GAME_EXE=<original exe>,
/// FUSHI_GS_HOST_IP=<LAN IPv4>, FUSHI_GS_EVIDENCE_DIR=<.codex-test/run>,
/// FUSHI_GS_RUN_SECONDS=1200 (optional).
/// FUSHI_GS_ATTACH_HWND and FUSHI_GS_ATTACH_PID (optional, required together)
/// attach to a verified existing game instead of launching another instance.
///
/// No game is launched unless RUN_LIVE is explicitly set. The private credentials
/// file must be transferred into the Android fixture's app-private directory.
/// Pairing is preseeded in the isolated DB; this does not test pairing approval.
/// After awaiting-local-start.json, prepare voiced dialogue locally, create
/// local-start.request, and leave the game foreground. Capture cannot start
/// until all three prerequisites are met.
/// Create stop.request in the evidence directory to finish the host fixture.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/game_stream_input_channel.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_line_fold.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/platform/desktop/windows_process_query.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/game_stream_lan_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const bool _runLive = bool.fromEnvironment('FUSHI_GS_RUN_LIVE');
const String _gameExe = String.fromEnvironment('FUSHI_GS_GAME_EXE');
const String _hostIp = String.fromEnvironment('FUSHI_GS_HOST_IP');
const String _evidencePath = String.fromEnvironment('FUSHI_GS_EVIDENCE_DIR');
const int _attachHwnd = int.fromEnvironment('FUSHI_GS_ATTACH_HWND');
const int _attachPid = int.fromEnvironment('FUSHI_GS_ATTACH_PID');
const bool _attachRequested =
    bool.hasEnvironment('FUSHI_GS_ATTACH_HWND') ||
    bool.hasEnvironment('FUSHI_GS_ATTACH_PID');
const int _runSeconds = int.fromEnvironment(
  'FUSHI_GS_RUN_SECONDS',
  defaultValue: 1200,
);
const String _clientId = 'android-lan-qa';
const String _clientName = 'Android QA';
const String _sgreSha =
    '75a83a0e2a7e22055417ae0474b47be98418c4e42c695c548b558705c404b9d8';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SGRE production host streams to the paired Android LAN fixture',
    (WidgetTester tester) async {
      final GameStreamFlutterErrorRecorder flutterErrors =
          GameStreamFlutterErrorRecorder();
      addTearDown(flutterErrors.restore);
      final String isolatedRoot = requireGameStreamIsolatedRoot();
      expect(
        !_attachRequested || (_attachHwnd > 0 && _attachPid > 0),
        isTrue,
        reason: 'Attach mode requires both a positive HWND and PID',
      );
      const bool attachExisting = _attachRequested;
      expect(
        File(_gameExe).existsSync(),
        isTrue,
        reason: 'Supply the original installed SGRE executable',
      );
      final InternetAddress? hostAddress = InternetAddress.tryParse(_hostIp);
      expect(
        hostAddress,
        isNotNull,
        reason: 'Supply the Windows LAN IPv4 address',
      );
      expect(hostAddress!.type, InternetAddressType.IPv4);
      expect(
        hostAddress.isLoopback,
        isFalse,
        reason: 'Android must use a real LAN connection',
      );
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      expect(
        interfaces
            .expand((NetworkInterface nic) => nic.addresses)
            .any((InternetAddress address) => address.address == _hostIp),
        isTrue,
      );
      expect(_runSeconds, inInclusiveRange(60, 2400));
      final String evidencePath = p.normalize(p.absolute(_evidencePath));
      expect(_evidencePath, isNotEmpty);
      expect(p.split(evidencePath), contains('.codex-test'));
      final Directory evidenceDir = Directory(evidencePath);
      await evidenceDir.create(recursive: true);
      await restrictGameStreamFixtureDirectory(evidenceDir);
      final File credentials = File(
        p.join(evidencePath, 'credentials.private.json'),
      );
      expect(
        credentials.existsSync(),
        isFalse,
        reason: 'Use a new evidence directory for each session',
      );
      final String exeHash = sha256
          .convert(await File(_gameExe).readAsBytes())
          .toString();
      expect(
        exeHash,
        _sgreSha,
        reason: 'This fixture targets the measured SGRE build',
      );
      final String runTag =
          'fushi_game_stream_e2e_${DateTime.now().microsecondsSinceEpoch}';
      final GameStreamLanEvidence evidence = GameStreamLanEvidence(
        directory: evidenceDir,
        runTag: runTag,
      );
      Map<String, Object?>? failure;

      flutterErrors.install();
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
      } finally {
        flutterErrors.install();
      }
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel app = container.read(appProvider);
      final AppPaths paths = await AppPaths.resolve();
      expect(p.isWithin(isolatedRoot, paths.supportRoot.path), isTrue);
      expect(p.isWithin(isolatedRoot, paths.documentsRoot.path), isTrue);
      final FushiSyncServerController sync = app.syncServerController;
      final GalHookSessionController hook = GalHookSessionController.instance;
      final TexthookerService text = TexthookerService.instance;
      final SyncRepository repository = SyncRepository(app.database);
      GameStreamEvidenceMiningAdapter? mining;
      bool observedConnection = false;
      bool listenersInstalled = false;

      void recordState() {
        final GameStreamSession? current = sync.gameStreamService.session;
        if (current?.state == GameStreamSessionState.connected) {
          observedConnection = true;
        }
        File(p.join(evidencePath, 'host-state.json')).writeAsStringSync(
          jsonEncode(<String, Object?>{
            'recordedAt': DateTime.now().toUtc().toIso8601String(),
            'hookPhase': hook.state.phase.name,
            'gamePid': hook.state.gamePid,
            'hwnd': hook.state.boundWindow?.hwnd,
            'foldProgressiveLines': text.foldProgressiveLines,
            'audioFallbackPolicy': hook.state.audioFallbackPolicy.storageKey,
            'selectedThreadSha256': hook.selectedTextThreadKey == null
                ? null
                : sha256
                      .convert(utf8.encode(hook.selectedTextThreadKey!))
                      .toString(),
            'stream': current?.toJson(),
            'error': sync.activeGameStreamHost?.error,
          }),
          flush: true,
        );
      }

      void recordLines() {
        final List<TexthookerLineEntry> lines = hook.selectedSessionLines;
        String? hashIdentity(String? value) => value == null
            ? null
            : sha256.convert(utf8.encode(value)).toString();
        Map<String, Object?> lineMetadata(int index) {
          final TexthookerLineEntry line = lines[index];
          final TexthookerLineEntry? previous = index > 0
              ? lines[index - 1]
              : null;
          final String normalized = normalizeForFold(line.text);
          final String? prior = previous == null
              ? null
              : normalizeForFold(previous.text);
          return <String, Object?>{
            'lineId': line.id,
            'textSha256': hashIdentity(line.text),
            'textLength': line.text.length,
            'normalizedLength': normalized.length,
            'receivedAt': line.receivedAt.toUtc().toIso8601String(),
            'hookTimestampMs': line.hookTimestampMs,
            'source': line.source.name,
            'sourceLabelSha256': hashIdentity(line.sourceLabel),
            'threadSha256': hashIdentity(line.textThreadKey),
            'eventOwnedVoice': line.eventOwnedVoice,
            'sourceSequence': line.sourceSequence,
            'audioResourceId': line.audioResourceId,
            'audioBackend': line.audioBackend,
            'audioStatus': line.audioStatus.name,
            'audioDurationMs': line.audioDurationMs,
            if (previous != null) ...<String, Object?>{
              'sameEndpointAsPrevious':
                  previous.source == line.source &&
                  previous.sourceLabel == line.sourceLabel &&
                  previous.textThreadKey == line.textThreadKey,
              'prefixRelatedToPrevious':
                  normalized.startsWith(prior!) || prior.startsWith(normalized),
              'suffixRelatedToPrevious':
                  normalized.endsWith(prior) || prior.endsWith(normalized),
              'progressiveWithPrevious': isProgressiveTextUpdate(
                previous.text,
                line.text,
              ),
            },
          };
        }

        File(p.join(evidencePath, 'host-lines.json')).writeAsStringSync(
          jsonEncode(<Map<String, Object?>>[
            for (
              int i = lines.length > 128 ? lines.length - 128 : 0;
              i < lines.length;
              i++
            )
              lineMetadata(i),
          ]),
          flush: true,
        );
      }

      try {
        await importGameStreamTestDictionary(app, evidenceDir);
        final anki = await configureGameStreamTestAnki(app, runTag);
        mining = GameStreamEvidenceMiningAdapter(
          repo: anki,
          evidence: evidence,
        );
        sync.configureGameStreamMining(mining);
        await repository.setInterconnectEnabled(true);
        await repository.setServerPort(0);
        await repository.setServerTlsEnabled(true);
        // Never print this fixture-only credential or include it in public evidence.
        final String token = FushiSyncServer.generateToken();
        await app.database.upsertPairedPeer(
          FushiPairedPeersCompanion.insert(
            peerId: _clientId,
            token: token,
            pairedAtMs: DateTime.now().millisecondsSinceEpoch,
            deviceName: const Value<String?>(_clientName),
          ),
        );
        final bool ready = await GalgameHelperInstaller().ensureInjector(
          is32Bit: false,
          context: tester.element(find.byType(Navigator).first),
        );
        expect(
          ready,
          isTrue,
          reason: 'Build/install the matching official x64 helper first',
        );
        await evidence.writeJson('setup.json', <String, Object?>{
          'exePath': _gameExe,
          'exeSha256': exeHash,
          'entryMode': attachExisting ? 'attach_existing' : 'launch',
          'localeMode': attachExisting ? 'unchanged' : 'off',
          'testRoot': isolatedRoot,
          'dictionary': gameStreamTestDictionary,
          'dictionaryContent':
              'synthetic definitions; production import/lookup',
          'deck': gameStreamTestDeck,
          'runTag': runTag,
          'pairingMode': 'preseeded_test_peer',
        });
        if (attachExisting) {
          final List<ExternalWindowInfo> matches =
              (await WindowCaptureChannel.listWindows())
                  .where(
                    (ExternalWindowInfo window) => window.hwnd == _attachHwnd,
                  )
                  .toList();
          expect(
            matches,
            hasLength(1),
            reason: 'Expected one exact existing HWND',
          );
          final ExternalWindowInfo existing = matches.single;
          expect(
            existing.pid,
            _attachPid,
            reason: 'The HWND owner PID changed',
          );
          final String? imagePath = windowsProcessImagePath(_attachPid);
          expect(
            imagePath,
            isNotNull,
            reason: 'Cannot verify existing game image',
          );
          final String expectedPath = await File(
            _gameExe,
          ).resolveSymbolicLinks();
          final String actualPath = await File(
            imagePath!,
          ).resolveSymbolicLinks();
          expect(
            p.normalize(actualPath).toLowerCase(),
            p.normalize(expectedPath).toLowerCase(),
            reason:
                'Existing process must run the exact SHA-verified game image',
          );
          await evidence.writeJson('attachment.json', <String, Object?>{
            'hwnd': existing.hwnd,
            'pid': existing.pid,
            'nativeImagePath': imagePath,
            'canonicalImagePath': actualPath,
            'exeSha256': exeHash,
            'pathMatches': true,
          });
          await hook.startAttachedCapture(existing);
          expect(hook.state.gamePid, _attachPid);
          expect(hook.state.boundWindow?.hwnd, _attachHwnd);
        } else {
          final GalHookLaunchResult launched = await hook.launchGame(
            _gameExe,
            workdir: p.dirname(_gameExe),
            gameTitle: 'STEINS;GATE RE:BOOT',
            japaneseLocaleMode: GalJapaneseLocaleMode.off,
          );
          expect(launched.launched, isTrue);
        }
        final DateTime windowDeadline = DateTime.now().add(
          const Duration(seconds: 45),
        );
        while (hook.state.boundWindow == null &&
            DateTime.now().isBefore(windowDeadline)) {
          if (hook.state.phase == GalHookSessionPhase.error) break;
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(hook.state.isActive, isTrue);
        expect(hook.state.boundWindow, isNotNull);
        sync.addListener(recordState);
        hook.addListener(recordState);
        text.addListener(recordLines);
        listenersInstalled = true;
        final int gameHwnd = hook.state.boundWindow!.hwnd;
        final File localStart = File(
          p.join(evidencePath, 'local-start.request'),
        );
        await evidence.writeJson('awaiting-local-start.json', <String, Object?>{
          'gamePid': hook.state.gamePid,
          'gameHwnd': gameHwnd,
          'requestFile': localStart.path,
          'requires': 'local game foreground and voiced dialogue',
        });
        recordState();
        recordLines();
        // The live operator prepares voiced dialogue and explicitly releases
        // this fixture gate. Never attach to another app's input queue or steal
        // focus to simulate a local user's click.
        final DateTime localDeadline = DateTime.now().add(
          const Duration(minutes: 10),
        );
        bool localReady = false;
        while (DateTime.now().isBefore(localDeadline)) {
          final Map<String, Object?> target =
              await GameStreamInputChannel.inspect(gameHwnd);
          if (target['alive'] != true ||
              target['pid'] != hook.state.gamePid ||
              hook.state.boundWindow?.hwnd != gameHwnd ||
              !hook.state.isActive) {
            throw StateError('Game session changed before local stream start');
          }
          if (localStart.existsSync() &&
              target['foreground'] == true &&
              target['visible'] == true &&
              target['minimized'] != true) {
            localReady = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          localReady,
          isTrue,
          reason: 'Waiting for local game preparation',
        );
        await evidence.writeJson('local-start.json', <String, Object?>{
          'runnerPid': pid,
          'runnerExe': Platform.resolvedExecutable,
          'gameHwnd': gameHwnd,
          'foregroundVerified': true,
          'mode': 'operator_prepared_game',
        });
        await sync.startGameStream(hwnd: gameHwnd);
        final Map<String, Object?> gameTarget =
            await GameStreamInputChannel.inspect();
        await evidence.writeJson('game-target-before-join.json', gameTarget);
        expect(
          gameTarget['foreground'],
          isTrue,
          reason: 'The bound game must be foreground before Android joins',
        );
        final GameStreamSession session = sync.gameStreamService.session!;
        final FushiTlsIdentity identity = await FushiTlsIdentityStore(
          dataDir: app.databaseDirectory.path,
        ).loadOrCreate();
        final String hostUrl = 'https://$_hostIp:${sync.boundPort}';
        await credentials.writeAsString(
          jsonEncode(<String, Object?>{
            'version': 1,
            'hostUrl': hostUrl,
            'token': token,
            'tlsFingerprint': identity.fingerprintSha256,
            'sessionId': session.sessionId,
            'clientId': _clientId,
            'clientName': _clientName,
            'fixture': <String, Object?>{
              'lookupTerms': gameStreamTestTerms,
              'dictionaryName': gameStreamTestDictionary,
              'expectAudio': true,
              'pairingMode': 'preseeded_test_peer',
            },
          }),
          flush: true,
        );
        await evidence.writeJson('ready.json', <String, Object?>{
          'hostUrl': hostUrl,
          'sessionId': session.sessionId,
          'clientId': _clientId,
          'credentialsFile': credentials.path,
          'pairingMode': 'preseeded_test_peer',
        });
        recordState();
        recordLines();
        final DateTime deadline = DateTime.now().add(
          Duration(seconds: _runSeconds),
        );
        final File stop = File(p.join(evidencePath, 'stop.request'));
        while (DateTime.now().isBefore(deadline) && !stop.existsSync()) {
          if (sync.gameStreamService.session?.state.isTerminal == true) break;
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(observedConnection, isTrue, reason: 'Android never connected');
        expect(evidence.failures, isEmpty);
        expect(
          evidence.verifiedNotes,
          isNotEmpty,
          reason: 'No remote true-card readback passed',
        );
      } catch (error) {
        failure = gameStreamFailureSummary(error);
        rethrow;
      } finally {
        flutterErrors.restore();
        failure ??= flutterErrors.lastFailure;
        if (listenersInstalled) {
          sync.removeListener(recordState);
          hook.removeListener(recordState);
          text.removeListener(recordLines);
        }
        await sync.stopGameStream(reason: 'fixture_finished');
        sync.configureGameStreamMining(null);
        mining?.clear();
        await sync.revokePeer(_clientId);
        await sync.stop();
        await hook.stopCapture();
        if (credentials.existsSync()) await credentials.delete();
        await evidence.writeJson('finished.json', <String, Object?>{
          'observedConnection': observedConnection,
          'verifiedNoteIds': evidence.verifiedNotes,
          'verificationFailures': evidence.failures,
          'credentialRevoked': true,
          if (failure != null) ...failure,
        });
      }
    },
    skip: !_runLive || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 50)),
  );
}
