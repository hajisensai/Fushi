import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/bangumi_token_migration.dart';
import 'package:fushi/src/media/tracking/plugin/bundled_tracking_plugins.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

import 'tracking_plugin_test_support.dart';

/// The built-in Bangumi token moves into the real bundled plugin (asset
/// `assets/tracking_plugins/…`) on the real sandbox engine (spec 2026-11-11
/// §4).
void main() {
  const String token = 'secret-token-123';
  late Directory root;
  late RecordingEngine engine;
  late TrackingPluginManager manager;
  late PluginTrackingProviders providers;
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late int accountChanges;
  late List<Object> errors;

  Uint8List asset() => File(
    'assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug',
  ).readAsBytesSync();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fushi-bangumi-migration-');
    engine = RecordingEngine.real();
    manager = TrackingPluginManager(rootDir: root, engine: engine);
    accountChanges = 0;
    errors = <Object>[];
    providers = PluginTrackingProviders(
      manager: manager,
      onAccountChanged: () => accountChanges++,
    );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
  });

  tearDown(() async {
    await manager.dispose();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<BangumiTokenMigration> migrate() => migrateBangumiTokenToPlugin(
    preferences: preferences,
    removePref: preferences.removePref,
    manager: manager,
    providers: providers,
    onError: (Object error, StackTrace _) => errors.add(error),
  );

  test('a saved token is imported once without network; preferences are '
      'removed and the plugin is signed in', () async {
    await preferences.setPref(kBangumiAccessTokenPref, ' $token ');
    await preferences.setPref(kBangumiAccountNamePref, 'Hikari');
    await manager.ensureBundled(asset());

    expect(await migrate(), BangumiTokenMigration.moved);

    final List<Map<String, Object?>> imports = engine.argsOf(
      'login',
      op: 'import',
    );
    expect(imports, hasLength(1));
    expect(imports.single['inputs'], <String, Object?>{
      'token': token,
      'name': 'Hikari',
    });
    expect(engine.httpRequests, isEmpty);
    expect(await db.getPref(kBangumiAccessTokenPref), isNull);
    expect(await db.getPref(kBangumiAccountNamePref), isNull);
    expect(preferences.getPref(kBangumiAccessTokenPref), isNull);
    final account = manager.accountOf(kBundledBangumiPluginId);
    expect(account.loggedIn, isTrue);
    expect(account.name, 'Hikari');
    expect(accountChanges, 1);
    expect(providers.byPluginId(kBundledBangumiPluginId)!.isConfigured, isTrue);

    // Second start: nothing left to move.
    expect(await migrate(), BangumiTokenMigration.nothing);
    expect(engine.argsOf('login', op: 'import'), hasLength(1));
    expect(errors, isEmpty);
  });

  test('no saved token: nothing happens', () async {
    await manager.ensureBundled(asset());
    expect(await migrate(), BangumiTokenMigration.nothing);
    expect(engine.argsOf('login'), isEmpty);
    expect(manager.accountOf(kBundledBangumiPluginId).loggedIn, isFalse);
  });

  test(
    'bundled plugin turned off: the token stays for a later start',
    () async {
      await preferences.setPref(kBangumiAccessTokenPref, token);
      await manager.ensureBundled(asset());
      await manager.setEnabled(kBundledBangumiPluginId, false);

      expect(await migrate(), BangumiTokenMigration.kept);
      expect(preferences.getPref(kBangumiAccessTokenPref), token);
      expect(engine.argsOf('login'), isEmpty);
    },
  );

  test(
    'a failing import keeps the preference and never reports the token',
    () async {
      await preferences.setPref(kBangumiAccessTokenPref, token);
      await preferences.setPref(kBangumiAccountNamePref, 'Hikari');
      await manager.ensureBundled(
        buildPluginZip(
          fakeManifest(id: kBundledBangumiPluginId, siteId: 'bangumi'),
          js: fakeSiteJs.replaceFirst(
            'async login(a) {',
            "async login(a) { if (a.op === 'import') "
                "throw new Error('vault is locked');",
          ),
        ),
      );

      expect(await migrate(), BangumiTokenMigration.kept);
      expect(preferences.getPref(kBangumiAccessTokenPref), token);
      expect(preferences.getPref(kBangumiAccountNamePref), 'Hikari');
      expect(manager.accountOf(kBundledBangumiPluginId).loggedIn, isFalse);
      expect(engine.argsOf('login', op: 'import'), hasLength(1));
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('vault is locked'));
      expect(errors.single.toString(), isNot(contains(token)));
    },
  );
}
