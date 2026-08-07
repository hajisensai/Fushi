import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late Directory root;
  late FushiDatabase database;
  late _InstallRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-manager-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _InstallRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('first local install exposes signer trust decision', () async {
    final File apk = await _fixtureApk(root, 'first.apk', <int>[1, 2, 3]);
    runtime.inspection = _inspection(versionCode: 1, signer: 'AA:BB');

    final MihonInstallProposal untrusted =
        await manager.prepareLocalInstall(apk.path);
    expect(untrusted.signerTrusted, isFalse);
    expect(untrusted.inspection.signerSha256, 'AA:BB');

    await database.trustMangaSigner(
      MangaTrustedSignersCompanion.insert(
        fingerprint: 'aabb',
        label: 'Fixture signer',
        origin: 'local',
        trustedAt: 1,
      ),
    );
    final File second = await _fixtureApk(root, 'second.apk', <int>[3, 2, 1]);
    final MihonInstallProposal trusted =
        await manager.prepareLocalInstall(second.path);
    expect(trusted.signerTrusted, isTrue);
  });

  test(
    'cold start restores an embedded repository catalogue without stale validators',
    () async {
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: 'https://repo.example/index.json',
          name: 'Fixture repository',
          format: MihonStoreFormat.currentJson.name,
          signingKey: const Value<String?>('aabb'),
          etag: const Value<String?>('"stale-etag"'),
          lastModified: const Value<String?>(
            'Wed, 29 Jul 2026 00:00:00 GMT',
          ),
        ),
      );
      manager.dispose();

      bool sentConditionalValidator = false;
      final MockClient httpClient = MockClient((http.Request request) async {
        sentConditionalValidator =
            request.headers.containsKey(HttpHeaders.ifNoneMatchHeader) ||
                request.headers.containsKey(HttpHeaders.ifModifiedSinceHeader);
        if (sentConditionalValidator) {
          return http.Response('', HttpStatus.notModified);
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'name': 'Fixture repository',
            'badgeLabel': 'Fixture',
            'signingKey': 'aabb',
            'extensionList': <String, Object?>{
              'extensions': <Object?>[
                <String, Object?>{
                  'name': 'Restored extension',
                  'packageName': 'org.example.restored',
                  'resources': <String, Object?>{
                    'apkUrl': 'apk/restored.apk',
                    'iconUrl': 'icons/restored.png',
                  },
                  'extensionLib': '1.6',
                  'versionCode': 8,
                  'versionName': '1.6.8',
                  'contentWarning': 'CONTENT_WARNING_SAFE',
                  'sources': <Object?>[],
                },
              ],
            },
          }),
          HttpStatus.ok,
          headers: <String, String>{HttpHeaders.etagHeader: '"fresh-etag"'},
        );
      });
      manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: runtime,
        storeClient: MihonExtensionStoreClient(client: httpClient),
      );

      await manager.initialise();

      expect(sentConditionalValidator, isFalse);
      expect(manager.available, hasLength(1));
      expect(manager.available.single.packageName, 'org.example.restored');
      expect(
        (await database.getMangaExtensionStores()).single.etag,
        '"fresh-etag"',
      );
    },
  );

  test('rejects downgrade and update signer discontinuity', () async {
    await _seedInstalled(database, versionCode: 5, signer: 'aabb');

    runtime.inspection = _inspection(versionCode: 4, signer: 'aabb');
    final File downgrade = await _fixtureApk(root, 'downgrade.apk', <int>[4]);
    await expectLater(
      manager.prepareLocalInstall(downgrade.path),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'DOWNGRADE_REJECTED',
        ),
      ),
    );

    runtime.inspection = _inspection(versionCode: 6, signer: 'ccdd');
    final File changedSigner = await _fixtureApk(root, 'changed.apk', <int>[6]);
    await expectLater(
      manager.prepareLocalInstall(changedSigner.path),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'SIGNATURE_CHANGED',
        ),
      ),
    );
  });

  test(
    'desktop load failure rolls back the previous extension atomically',
    () async {
      await _seedInstalled(database, versionCode: 5, signer: 'aabb');
      await database.trustMangaSigner(
        MangaTrustedSignersCompanion.insert(
          fingerprint: 'aabb',
          label: 'Fixture signer',
          origin: 'local',
          trustedAt: 1,
        ),
      );
      final Directory extensionDirectory =
          Directory('${root.path}${Platform.pathSeparator}extensions');
      final File installed = File(
        '${extensionDirectory.path}${Platform.pathSeparator}'
        'org.example.fixture.apk',
      );
      await installed.writeAsBytes(<int>[5], flush: true);
      runtime.inspection = _inspection(versionCode: 6, signer: 'aabb');
      runtime.failListSources = true;
      final File update = await _fixtureApk(root, 'update.apk', <int>[6]);
      final MihonInstallProposal proposal =
          await manager.prepareLocalInstall(update.path);

      await expectLater(
        manager.commitInstall(proposal, trustSigner: false),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException error) => error.code,
            'code',
            'LOAD_FAILED',
          ),
        ),
      );

      expect(await installed.readAsBytes(), <int>[5]);
      expect(
        (await database.getMangaExtension('org.example.fixture'))!.versionCode,
        5,
      );
    },
    skip: !(Platform.isWindows || Platform.isMacOS),
  );
}

Future<File> _fixtureApk(
  Directory root,
  String name,
  List<int> bytes,
) async {
  final File file = File('${root.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

MihonExtensionInspection _inspection({
  required int versionCode,
  required String signer,
}) =>
    MihonExtensionInspection(
      packageName: 'org.example.fixture',
      name: 'Fixture extension',
      versionCode: versionCode,
      versionName: '1.6.$versionCode',
      libVersion: '1.6',
      signerSha256: signer,
      sourceClasses: const <String>['FixtureSource'],
    );

Future<void> _seedInstalled(
  FushiDatabase database, {
  required int versionCode,
  required String signer,
}) =>
    database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.fixture',
        name: 'Fixture extension',
        versionCode: versionCode,
        versionName: '1.6.$versionCode',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.fixture.apk',
        apkSha256: 'old',
        signerSha256: signer,
        installedAt: 1,
      ),
    );

class _InstallRuntime extends Fake implements MihonRuntime {
  MihonExtensionInspection inspection = _inspection(
    versionCode: 1,
    signer: 'aabb',
  );
  bool failListSources = false;

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async =>
      inspection;

  @override
  Future<String> installPrivateExtension(String apkPath) async => apkPath;

  @override
  Future<List<MihonSource>> listSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    if (failListSources) {
      throw const MihonRuntimeException(
        'LOAD_FAILED',
        'Fixture load failed',
      );
    }
    return const <MihonSource>[
      MihonSource(
        extensionPackage: 'org.example.fixture',
        id: '9223372036854775807',
        name: 'Fixture source',
        language: 'en',
        baseUrl: 'https://source.example',
      ),
    ];
  }

  @override
  Future<void> invalidateExtension(String packageName) async {}

  @override
  Future<void> dispose() async {}
}
