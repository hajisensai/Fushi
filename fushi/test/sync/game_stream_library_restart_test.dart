import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

class _Library implements GameStreamLibraryHost {
  @override
  bool get launchEnabled => true;

  @override
  Future<List<GameStreamLibraryGame>> listGames() async =>
      const <GameStreamLibraryGame>[];

  @override
  Future<GameStreamLibraryCover?> cover(String gameId) async => null;

  @override
  Future<void> launch({
    required String launchId,
    required String gameId,
    required GameStreamVideoSettings settings,
  }) async {}
}

FushiSyncServerController _controller(FushiDatabase db) =>
    FushiSyncServerController(
      navigatorKey: GlobalKey<NavigatorState>(),
      database: () => db,
      syncDataDir: () => Directory.systemTemp.path,
      remoteLookupServiceFactory: () =>
          throw StateError('these tests never bind a server'),
    );

/// The host replaces its game-stream service on every stop/restart (changing
/// the port, token or enabling HTTPS all restart). The library used to live on
/// the old instance only, so after a restart every receiver read the 404
/// "Game library off" as "host is outdated" although both ends were current.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the library survives the service being replaced by a restart',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final FushiSyncServerController controller = _controller(db);
      final _Library library = _Library();

      controller.configureGameStreamLibrary(library);
      final FushiRemoteGameStreamService before = controller.gameStreamService;
      expect(before.library, same(library));

      await controller.stop();
      final FushiRemoteGameStreamService after = controller.gameStreamService;

      expect(after, isNot(same(before)));
      expect(after.library, same(library));
    },
  );

  test('a library configured before any service exists is attached', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final FushiSyncServerController controller = _controller(db);
    final _Library library = _Library();

    await controller.stop();
    controller.configureGameStreamLibrary(library);

    expect(controller.gameStreamService.library, same(library));
  });
}
