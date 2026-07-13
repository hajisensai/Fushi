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
    Map<String, String> Function()? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    String? Function()? extensionBuildProvider,
  })  : _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _themeColorsProvider = themeColorsProvider,
        _audioSourcesProvider = audioSourcesProvider,
        _extensionBuildProvider = extensionBuildProvider;

  final HibikiRemoteLookupService _lookup;
  final HibikiRemoteMiningService? _mining;
  final HibikiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  // BUG-530：主题 CSS 变量供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展弹窗。
  final Map<String, String> Function()? _themeColorsProvider;
  // 单词音频：已启用音频源供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展。
  final List<String> Function()? _audioSourcesProvider;
  // BUG-726：扩展内容指纹供给器，透传给 [YomitanApiServer]，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;

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
      themeColorsProvider: _themeColorsProvider,
      audioSourcesProvider: _audioSourcesProvider,
      extensionBuildProvider: _extensionBuildProvider,
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
