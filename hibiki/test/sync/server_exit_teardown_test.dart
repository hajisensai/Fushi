import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'sync_settings_schema_source_corpus.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

HibikiSyncServerController _controller(HibikiDatabase db) =>
    HibikiSyncServerController(
      navigatorKey: GlobalKey<NavigatorState>(),
      database: () => db,
      syncDataDir: () => Directory.systemTemp.path,
      // Never built in these tests: shutdown runs with no server started.
      remoteLookupServiceFactory: () =>
          throw StateError('must not build the server in teardown tests'),
    );

/// TODO-036: at process exit on Windows, Bonsoir's mDNS events are posted onto
/// the message pump from an OS DNS callback thread. If they reach a torn-down
/// Flutter messenger the process crashes. The controller's [shutdownForExit]
/// must stop every live Bonsoir source (LAN broadcast + any registered
/// discovery browser) so the event source is dead before the engine is torn
/// down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HibikiSyncServerController.shutdownForExit', () {
    test('disposes every registered discovery browser', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final HibikiSyncServerController controller = _controller(db);

      final LanDiscoveryService a = LanDiscoveryService(deviceId: 'a');
      final LanDiscoveryService b = LanDiscoveryService(deviceId: 'b');
      controller.registerDiscovery(a);
      controller.registerDiscovery(b);

      expect(a.isDisposed, isFalse);
      expect(b.isDisposed, isFalse);

      await controller.shutdownForExit();

      expect(a.isDisposed, isTrue,
          reason: 'exit teardown must stop the Bonsoir browser at its root');
      expect(b.isDisposed, isTrue);
    });

    test('unregistered discovery is NOT disposed by the controller', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final HibikiSyncServerController controller = _controller(db);

      final LanDiscoveryService a = LanDiscoveryService(deviceId: 'a');
      controller.registerDiscovery(a);
      controller.unregisterDiscovery(a);

      await controller.shutdownForExit();

      expect(a.isDisposed, isFalse,
          reason: 'a page that already disposed its own browser must not be '
              'double-disposed by the controller');
    });

    test('is idempotent and safe with nothing registered', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final HibikiSyncServerController controller = _controller(db);

      // No broadcast started, no discovery registered: must be a clean no-op.
      await controller.shutdownForExit();
      await controller.shutdownForExit();

      expect(controller.isRunning, isFalse);
    });

    test('does NOT persist serverEnabled=false (app exit is not a toggle-off)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      // Simulate the user having enabled hosting in a previous session.
      await repo.setServerEnabled(true);

      final HibikiSyncServerController controller = _controller(db);
      await controller.shutdownForExit();

      expect(await repo.isServerEnabled(), isTrue,
          reason: 'app exit must leave the hosting intent so the next launch '
              'restores it; only an explicit user toggle-off clears it');
    });
  });

  group('source guards: main.dart installs the Bonsoir exit teardown', () {
    test('main() prevents the native window close to teardown first', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('windowManager.setPreventClose(true)'), isTrue,
          reason: 'desktop must intercept WM_CLOSE so Bonsoir is stopped '
              'BEFORE the engine is torn down (TODO-036)');
    });

    test('the app state handles window close with a fast exit (no destroy)',
        () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(
          main.contains('with WidgetsBindingObserver, WindowListener'), isTrue,
          reason: 'the app state must implement WindowListener to receive '
              'onWindowClose');
      expect(main.contains('void onWindowClose()'), isTrue,
          reason: 'must handle the native close signal');
      // TODO-086: destroy() syncly tears down the engine plugin-by-plugin =
      // the multi-second exit hang; the close path now uses exit(0).
      expect(main.contains('windowManager.destroy()'), isFalse,
          reason: 'onWindowClose must NOT destroy() (sync engine teardown); '
              'it must exit(0) instead (TODO-086)');
    });

    test('onWindowClose cuts Bonsoir event source before exit (TODO-036 kept)',
        () {
      final String main = File('lib/main.dart').readAsStringSync();
      final int closeAt = main.indexOf('void onWindowClose()');
      expect(closeAt, greaterThanOrEqualTo(0));
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      expect(hookAt, greaterThan(closeAt));
      final int cutAt = main.indexOf('shutdownForExitFast()', hookAt);
      final int exitAt =
          main.indexOf('platformServices.lifecycle.exitApp()', hookAt);
      expect(cutAt, greaterThan(hookAt),
          reason: 'exit must cut the Bonsoir event source (TODO-036)');
      expect(exitAt, greaterThan(cutAt),
          reason: 'the event-source cut must run before exit(0)');
    });

    test('exit teardown is bounded by a timeout so close-X can never freeze',
        () {
      final String main = File('lib/main.dart').readAsStringSync();
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      expect(hookAt, greaterThanOrEqualTo(0));
      final String body = main.substring(hookAt);
      // TODO-086: Bonsoir exit timeout tightened from 3s to 1.5s (the fast
      // variant already backgrounds the native stop).
      expect(
          body.contains('.timeout(const Duration(milliseconds: 1500))'), isTrue,
          reason: 'a hung bonsoir native stop must not block exit forever: '
              'the fast teardown await must carry a 1.5s timeout (TODO-086)');
      expect(body.contains('on TimeoutException'), isTrue,
          reason: 'the timeout must be logged and swallowed, never escape '
              'the close path');
    });

    test('detached lifecycle is a fallback teardown path', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('AppLifecycleState.detached'), isTrue,
          reason: 'detached must also tear down Bonsoir for paths that do not '
              'go through window_manager');
    });
  });

  group('source guards: discovery registers with the app-level controller', () {
    test('sync-settings discovery widget registers + unregisters', () {
      // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，负向/正向断言都
      // 覆盖全部 part（discovery widget 现住 interconnect.part.dart）。
      final String schema = readSyncSettingsSchemaSource();
      expect(schema.contains('syncServerController'), isTrue);
      expect(schema.contains('.registerDiscovery('), isTrue,
          reason: 'the discovery widget must register its browser so the exit '
              'hook can stop it');
      expect(schema.contains('.unregisterDiscovery('), isTrue,
          reason: 'the widget must unregister on its own dispose to avoid a '
              'double-dispose');
    });
  });

  group('HibikiSyncServerController.shutdownForExitFast (TODO-086)', () {
    test('cuts every registered discovery event source', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final HibikiSyncServerController controller = _controller(db);
      final LanDiscoveryService a = LanDiscoveryService(deviceId: 'a');
      final LanDiscoveryService b = LanDiscoveryService(deviceId: 'b');
      controller.registerDiscovery(a);
      controller.registerDiscovery(b);

      await controller.shutdownForExitFast();

      expect(a.isDisposed, isTrue,
          reason: 'fast exit must still cut the Bonsoir event source at root');
      expect(b.isDisposed, isTrue);
    });

    test('is idempotent and safe with nothing registered', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final HibikiSyncServerController controller = _controller(db);
      await controller.shutdownForExitFast();
      await controller.shutdownForExitFast();
      expect(controller.isRunning, isFalse);
    });
  });
}
