/// Opt-in Windows host for the Android LAN fixture. Requires the isolated runner.
///
/// Non-secret dart defines:
/// FUSHI_GS_RUN_LIVE=true, FUSHI_GS_GAME_EXE=<original exe>,
/// FUSHI_GS_HOST_IP=<LAN IPv4>, FUSHI_GS_EVIDENCE_DIR=<.codex-test/run>,
/// FUSHI_GS_RUN_SECONDS=1200 (optional).
///
/// No game is launched unless RUN_LIVE is explicitly set. The private credentials
/// file must be transferred into the Android fixture's app-private directory.
/// Pairing is preseeded in the isolated DB; this does not test pairing approval.
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
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/game_stream_input_channel.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
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
      final String isolatedRoot = requireGameStreamIsolatedRoot();
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

      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
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
            'stream': current?.toJson(),
            'error': sync.activeGameStreamHost?.error,
          }),
          flush: true,
        );
      }

      void recordLines() {
        final List<TexthookerLineEntry> lines = hook.selectedSessionLines;
        File(p.join(evidencePath, 'host-lines.json')).writeAsStringSync(
          jsonEncode(<Map<String, Object?>>[
            for (final TexthookerLineEntry line in lines.skip(
              lines.length > 128 ? lines.length - 128 : 0,
            ))
              <String, Object?>{
                'lineId': line.id,
                'textSha256': sha256.convert(utf8.encode(line.text)).toString(),
                'sourceSequence': line.sourceSequence,
                'audioResourceId': line.audioResourceId,
                'audioBackend': line.audioBackend,
                'audioStatus': line.audioStatus.name,
                'audioDurationMs': line.audioDurationMs,
              },
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
          'localeMode': 'off',
          'testRoot': isolatedRoot,
          'dictionary': gameStreamTestDictionary,
          'dictionaryContent':
              'synthetic definitions; production import/lookup',
          'deck': gameStreamTestDeck,
          'runTag': runTag,
          'pairingMode': 'preseeded_test_peer',
        });
        final GalHookLaunchResult launched = await hook.launchGame(
          _gameExe,
          workdir: p.dirname(_gameExe),
          gameTitle: 'STEINS;GATE RE:BOOT',
          japaneseLocaleMode: GalJapaneseLocaleMode.off,
        );
        expect(launched.launched, isTrue);
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
        final GameStreamFixtureForeground foreground =
            await GameStreamFixtureForeground.acquire(evidenceDir);
        try {
          await evidence.writeJson('local-start.json', <String, Object?>{
            'runnerPid': pid,
            'runnerExe': Platform.resolvedExecutable,
            'runnerHwnd': foreground.window,
            'foregroundVerified': true,
          });
          await sync.startGameStream(hwnd: hook.state.boundWindow!.hwnd);
        } finally {
          await foreground.restore();
        }
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
      } finally {
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
        });
      }
    },
    skip: !_runLive || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 50)),
  );
}
