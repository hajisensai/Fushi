import 'dart:async';
import 'dart:io';

import 'package:hibiki/language.dart';
import 'package:local_assets_server/local_assets_server.dart';

/// Minimal ttu asset server for migration only.
///
/// Uses the same fixed ports as the original reader (52059/52060)
/// so that IndexedDB origin lookup finds existing user data.
class TtuMigrationServer {
  TtuMigrationServer._();

  static final Map<int, LocalAssetsServer> _servers =
      <int, LocalAssetsServer>{};

  static int portForLanguage(Language language) {
    if (language is JapaneseLanguage) {
      return 52059;
    }
    if (language is EnglishLanguage) {
      return 52060;
    }
    throw UnimplementedError('Unsupported TTU migration language: $language');
  }

  static Future<LocalAssetsServer> start(Language language) async {
    final int port = portForLanguage(language);
    final LocalAssetsServer? existing = _servers[port];
    if (existing != null) {
      return existing;
    }

    final LocalAssetsServer server = LocalAssetsServer(
      address: InternetAddress.loopbackIPv4,
      port: port,
      assetsBasePath: 'assets/ttu-ebook-reader',
      logger: const DebugLogger(),
    );
    await server.serve().timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException(
            'TTU migration server failed to start within 15 seconds',
          ),
        );
    _servers[port] = server;
    return server;
  }
}
