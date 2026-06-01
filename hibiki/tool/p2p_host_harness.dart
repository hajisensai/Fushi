// Dev/test harness: runs a real HibikiSyncServer on the host so an Android
// emulator (or a real device) can verify P2P sync interop by connecting to
// http://10.0.2.2:<port> (emulator) or http://<host-lan-ip>:<port> (device).
//
// Driven by .codex-test/tools/p2p-interop.ps1 — not shipped, not imported by
// the app. Run from the hibiki package dir with the Flutter SDK's dart:
//   dart run tool/p2p_host_harness.dart [port]
//
// Prints a single machine-readable line once the server is listening:
//   HIBIKI_P2P_READY port=<port> token=<token>
// then serves until killed (5-minute safety cap).
import 'dart:io';

import 'package:hibiki/src/sync/hibiki_sync_server.dart';

Future<void> main(List<String> args) async {
  final int port = args.isNotEmpty ? int.parse(args.first) : 38765;
  const String token = 'p2p-interop-test-token-abc123';

  final Directory dir = Directory.systemTemp.createTempSync('hibiki_p2p_host_');
  // Seed the served root + one book so an authenticated PROPFIND lists content.
  final Directory book =
      Directory('${dir.path}/sync-data/ttu-reader-data/InteropBook');
  book.createSync(recursive: true);
  File('${book.path}/progress_1234_0.5.json')
      .writeAsStringSync('{"dataId":0,"exploredCharCount":500,"progress":0.5,'
          '"lastBookmarkModified":1234}');

  final HibikiSyncServer server = HibikiSyncServer(
    syncDataDir: dir.path,
    port: port,
    token: token,
    allowLan: true, // bind 0.0.0.0 so the emulator reaches it via 10.0.2.2
  );
  await server.start();
  stdout.writeln('HIBIKI_P2P_READY port=${server.port} token=$token');

  await Future<void>.delayed(const Duration(minutes: 5));
  await server.stop();
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {/* best-effort temp cleanup */}
}
