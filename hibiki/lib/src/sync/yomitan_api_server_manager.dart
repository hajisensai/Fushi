import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

/// 持有并按需启停 [YomitanApiServer]。tokenizer/readingResolver 注入解耦 FFI。
/// BUG-530：注入挖词/历史 service，让浏览器扩展的 `/api/mine` + `/api/lookup/dictionary`
/// 在这个（扩展被自动配置指向的）server 上真正可用。
class YomitanApiServerManager {
  YomitanApiServerManager({
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    HibikiRemoteMiningService? miningService,
    HibikiRemoteHistoryService? historyService,
  })  : _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver;

  final HibikiRemoteLookupService _lookup;
  final HibikiRemoteMiningService? _mining;
  final HibikiRemoteHistoryService? _history;
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
      miningService: _mining,
      historyService: _history,
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
