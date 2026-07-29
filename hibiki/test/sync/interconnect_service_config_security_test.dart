import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/interconnect_service_config.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/tls/hibiki_tls_identity.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _ServiceConfigHost extends Fake
    implements HibikiLibraryHostService, InterconnectServiceConfigHost {
  _ServiceConfigHost(this.snapshot);

  final InterconnectServiceConfigSnapshot snapshot;

  @override
  Future<InterconnectServiceConfigSnapshot>
      getInterconnectServiceConfig() async => snapshot;
}

Future<InterconnectSyncBackend> _buildBackend({
  required HibikiDatabase db,
  required String baseUrl,
  required String token,
  String? fingerprint,
}) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(
      url: baseUrl,
      enabled: true,
      fingerprintSha256: fingerprint,
    ),
  ]);
  await repo.setHibikiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String _, String __) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  group('service-config client transport boundary', () {
    test(
        'HTTP impersonator returning 200 receives no service-config request '
        'or peer Authorization', () async {
      int requestCount = 0;
      bool sawAuthorization = false;
      final HttpServer malicious =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      malicious.listen((HttpRequest request) async {
        requestCount++;
        sawAuthorization =
            request.headers.value(HttpHeaders.authorizationHeader) != null;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'preferences': <String, Object?>{
              'jimaku_api_key': PrefCodec.encode('attacker-injected'),
              'manga_online_catalog_enabled': PrefCodec.encode(false),
            },
          }));
        await request.response.close();
      });
      addTearDown(() => malicious.close(force: true));

      for (final String rawBaseUrl in <String>[
        'http://127.0.0.1:${malicious.port}',
        'HTTP://127.0.0.1:${malicious.port}/',
      ]) {
        final HibikiDatabase db =
            HibikiDatabase.forTesting(NativeDatabase.memory());
        try {
          await db.setPref('jimaku_api_key', PrefCodec.encode('child-local'));
          final InterconnectSyncBackend backend = await _buildBackend(
            db: db,
            baseUrl: rawBaseUrl,
            token: 'current-peer-token',
          );

          Object? failure;
          try {
            final InterconnectServiceConfigSnapshot? snapshot =
                await backend.getRemoteServiceConfig();
            await snapshot?.applyTo(db);
          } catch (error) {
            failure = error;
          }
          expect(
            (
              failure is SyncBackendError && failure.message.contains('HTTPS'),
              await db.getPref('jimaku_api_key'),
              requestCount,
              sawAuthorization,
            ),
            (true, PrefCodec.encode('child-local'), 0, false),
            reason: 'HTTP must fail closed before request/auth and before an '
                'impersonator response can reach allowlist apply',
          );
        } finally {
          await db.close();
        }
      }
    });
  });

  group('service-config HTTPS auth and allowlist matrix', () {
    late Directory tempDir;
    late HibikiSyncServer server;
    late String baseUrl;
    late String fingerprint;
    late Set<String> currentPeerTokens;
    const String currentPeerToken = 'current-peer-token';
    const String legacySharedToken = 'legacy-shared-token';

    setUp(() async {
      tempDir =
          Directory.systemTemp.createTempSync('hibiki_service_config_security');
      final ({String certificatePem, String privateKeyPem}) generated =
          HibikiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-service-config-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );
      fingerprint =
          HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem);
      final SecurityContext securityContext = SecurityContext()
        ..useCertificateChainBytes(generated.certificatePem.codeUnits)
        ..usePrivateKeyBytes(generated.privateKeyPem.codeUnits);
      currentPeerTokens = <String>{currentPeerToken};
      final InterconnectServiceConfigSnapshot snapshot =
          InterconnectServiceConfigSnapshot.fromPreferences(<String, String>{
        'jimaku_api_key': PrefCodec.encode('jimaku-current'),
        'video_scraper_tmdb_api_key': PrefCodec.encode('tmdb-current'),
        'qb_connection_config': PrefCodec.encode('{"host":"qb.test"}'),
        'manga_online_catalog_base_url':
            PrefCodec.encode('https://catalog.test'),
        'manga_online_catalog_enabled': PrefCodec.encode(false),
        'sync_device_id': PrefCodec.encode('must-not-leave-host'),
        'future_secret': PrefCodec.encode('must-not-leave-host'),
      });
      server = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: legacySharedToken,
        allowLan: false,
        libraryService: _ServiceConfigHost(snapshot),
        securityContext: securityContext,
        hostFingerprint: fingerprint,
      )..pairedPeerTokensProvider =
          (() async => Set<String>.of(currentPeerTokens));
      await server.start();
      baseUrl = 'https://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<int> requestStatus(
      String token, {
      String method = 'GET',
    }) async {
      final WebDavOps ops = WebDavOps(
        baseUrl: baseUrl,
        username: 'hibiki',
        password: token,
        pinnedFingerprint: fingerprint,
      );
      addTearDown(() => ops.close(force: true));
      final HttpClientRequest request = await ops.buildRequest(
        method,
        '$baseUrl/api/interconnect/service-config',
      );
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    test('current peer token imports exactly the host allowlist over HTTPS',
        () async {
      final HibikiDatabase clientDb =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(clientDb.close);
      await clientDb.setPref(
          'sync_device_id', PrefCodec.encode('child-device'));
      final InterconnectSyncBackend backend = await _buildBackend(
        db: clientDb,
        baseUrl: baseUrl,
        token: currentPeerToken,
        fingerprint: fingerprint,
      );

      final InterconnectServiceConfigSnapshot? snapshot =
          await backend.getRemoteServiceConfig();
      expect(snapshot, isNotNull);
      expect(
        snapshot!.preferences.keys.toSet(),
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
      );
      expect(await snapshot.applyTo(clientDb), 5);
      expect(
        await clientDb.getPref('jimaku_api_key'),
        PrefCodec.encode('jimaku-current'),
      );
      expect(
        await clientDb.getPref('manga_online_catalog_enabled'),
        PrefCodec.encode(false),
      );
      expect(
        await clientDb.getPref('sync_device_id'),
        PrefCodec.encode('child-device'),
        reason: 'device identity is excluded from host-to-child config',
      );
      expect(await clientDb.getPref('future_secret'), isNull);
    });

    test('legacy, wrong and revoked peer tokens are rejected', () async {
      expect(await requestStatus(legacySharedToken), HttpStatus.forbidden);
      expect(await requestStatus('wrong-peer-token'), HttpStatus.unauthorized);
      expect(await requestStatus(currentPeerToken), HttpStatus.ok);

      currentPeerTokens.clear();
      server.invalidatePeerTokenCache();
      expect(await requestStatus(currentPeerToken), HttpStatus.unauthorized);
    });

    test('child has no service-config write method', () async {
      expect(
        await requestStatus(currentPeerToken, method: 'POST'),
        HttpStatus.methodNotAllowed,
      );
      expect(
        await requestStatus(currentPeerToken, method: 'PUT'),
        HttpStatus.methodNotAllowed,
      );
    });
  });
}
