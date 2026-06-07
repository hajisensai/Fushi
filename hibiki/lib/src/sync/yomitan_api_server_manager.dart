import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

/// 持有并按需启停 [YomitanApiServer]。tokenizer/readingResolver 注入解耦 FFI。
class YomitanApiServerManager {
  YomitanApiServerManager({
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
  })  : _lookup = lookupService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver;

  final HibikiRemoteLookupService _lookup;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;

  YomitanApiServer? _server;

  bool get isRunning => _server?.isRunning ?? false;
  int? get port => _server?.port;

  Future<void> start({required int port, required String apiKey}) async {
    if (_server != null) return;
    final YomitanApiServer server = YomitanApiServer(
      port: port,
      lookupService: _lookup,
      tokenizer: _tokenizer,
      readingResolver: _readingResolver,
      apiKey: apiKey.isEmpty ? null : apiKey,
      allowLan: true,
    );
    await server.start();
    _server = server;
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
  }
}
