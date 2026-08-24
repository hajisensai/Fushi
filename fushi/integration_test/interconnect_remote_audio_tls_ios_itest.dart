import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/tls/fushi_tls_identity.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart'
    show audioRefToWebViewUrl;
import 'package:fushi/src/utils/misc/tts_channel.dart' show TtsChannel;
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/media_fixtures.dart' show generateSilentAudio;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

const String _token = 'ios-device-audio-test-token';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS fetches pinned interconnect audio locally and both playback paths consume it',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'interconnect-remote-audio-tls-ios',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'the physical-device app must initialize first',
          );
          final AppModel appModel = await readyAppModel(tester);
          final SyncRepository repo = SyncRepository(appModel.database);
          final List<FushiClientUrl> oldUrls = await repo.getFushiClientUrls();
          final String? oldToken = await repo.getFushiClientToken();
          final Directory hostRoot = await Directory.systemTemp.createTemp(
            'fushi_tls_audio_itest_',
          );
          FushiSyncServer? server;
          File? cachedAudio;
          try {
            final File sourceAudio = await generateSilentAudio(
              outPath: '${hostRoot.path}/source.m4a',
              duration: const Duration(seconds: 2),
            );
            final Uint8List sourceBytes = await sourceAudio.readAsBytes();
            final FushiTlsIdentity identity = await FushiTlsIdentityStore(
              dataDir: hostRoot.path,
            ).loadOrCreate();
            final SecurityContext context = SecurityContext()
              ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
              ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
            server = FushiSyncServer(
              syncDataDir: hostRoot.path,
              port: 0,
              token: _token,
              remoteLookupService: _FixtureAudioLookup(sourceBytes),
              securityContext: context,
              hostFingerprint: identity.fingerprintSha256,
            );
            await server.start();
            final String baseUrl = 'https://127.0.0.1:${server.port}';
            await repo.setFushiClientUrls(<FushiClientUrl>[
              FushiClientUrl(
                url: baseUrl,
                fingerprintSha256: identity.fingerprintSha256,
                token: _token,
              ),
            ]);
            await repo.setFushiClientToken(_token);

            final String? ref = await FushiRemoteLookupClient(
              repo: repo,
            ).lookupAudioUrl(expression: '猫', reading: 'ねこ');
            expect(ref, isNotNull);
            expect(
              ref!.startsWith('http'),
              isFalse,
              reason: 'a pinned self-signed URL must never escape to iOS media',
            );
            cachedAudio = File(ref);
            expect(await cachedAudio.exists(), isTrue);
            final List<int> bytes = await cachedAudio.readAsBytes();
            expect(
              bytes,
              sourceBytes,
              reason: 'the real pinned HTTPS second hop must preserve bytes',
            );
            expect(
              utf8.decode(bytes.sublist(4, 8)),
              'ftyp',
              reason: 'the downloaded fixture must be a real M4A container',
            );

            final String? webViewRef = await audioRefToWebViewUrl(ref);
            expect(
              webViewRef,
              startsWith('data:audio/mp4;base64,'),
              reason: 'popup WebView must receive trusted local bytes, not TLS',
            );

            final bool played = await TtsChannel.instance.playAudioRef(ref);
            expect(
              played,
              isTrue,
              reason:
                  'the native iOS playback fallback must load the same file',
            );
            await tester.pump(const Duration(milliseconds: 500));
          } finally {
            await TtsChannel.instance.stop();
            await server?.stop();
            await repo.setFushiClientUrls(oldUrls);
            await repo.setFushiClientToken(oldToken);
            if (cachedAudio != null && await cachedAudio.exists()) {
              await cachedAudio.delete();
            }
            if (await hostRoot.exists()) {
              await hostRoot.delete(recursive: true);
            }
          }
        },
      );
    },
  );
}

class _FixtureAudioLookup implements FushiRemoteLookupService {
  const _FixtureAudioLookup(this.bytes);

  final Uint8List bytes;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => RemoteAudioLookup(bytes: bytes, contentType: 'audio/mp4');
}
