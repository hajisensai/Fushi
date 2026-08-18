import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// 持有并按需启停 [YomitanApiServer]。tokenizer/readingResolver 注入解耦 FFI。
/// BUG-530：注入挖词/历史 service，让浏览器扩展的 `/api/mine` + `/api/lookup/dictionary`
/// 在这个（扩展被自动配置指向的）server 上真正可用。
class YomitanApiServerManager {
  YomitanApiServerManager({
    required FushiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    FushiRemoteMiningService? miningService,
    FushiRemoteHistoryService? historyService,
    Map<String, String> Function()? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    String? Function()? extensionBuildProvider,
    RemotePopupDictionaryCss Function()? popupDictionaryCssProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function()? onExtensionSeen,
    void Function()? onLookupActivity,
    void Function(String build, String? version)? onExtensionReport,
  })  : _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _themeColorsProvider = themeColorsProvider,
        _audioSourcesProvider = audioSourcesProvider,
        _extensionBuildProvider = extensionBuildProvider,
        _popupDictionaryCssProvider = popupDictionaryCssProvider,
        _onExtensionPopupSize = onExtensionPopupSize,
        _onExtensionSeen = onExtensionSeen,
        _onLookupActivity = onLookupActivity,
        _onExtensionReport = onExtensionReport;

  final FushiRemoteLookupService _lookup;
  final FushiRemoteMiningService? _mining;
  final FushiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  // BUG-530：主题 CSS 变量供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展弹窗。
  final Map<String, String> Function()? _themeColorsProvider;
  // 单词音频：已启用音频源供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展。
  final List<String> Function()? _audioSourcesProvider;
  // BUG-726：扩展内容指纹供给器，透传给 [YomitanApiServer]，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // BUG-1718：词典自带 CSS + 用户自定义 CSS 供给器，透传给 [YomitanApiServer]，
  // 按 revision 门控随查词响应下发给扩展弹窗。
  final RemotePopupDictionaryCss Function()? _popupDictionaryCssProvider;
  // 弹窗尺寸精细化 Phase D：扩展弹窗拖角调整后回写尺寸的 sink，透传给 [YomitanApiServer]。
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  // 浏览器扩展连接探活回调，透传给 [YomitanApiServer]（app 侧记录 last-seen）。
  final void Function()? _onExtensionSeen;
  // TODO-2936：查词/制卡活动回调，透传给 [YomitanApiServer]（app 侧应用「浏览器」
  // 媒体类型的 Profile 绑定）。
  final void Function()? _onLookupActivity;
  // BUG-1079：扩展自报版本回调，透传给 [YomitanApiServer]（app 侧记录浏览器中实际
  // 加载的 build，与内置指纹比对给出更新提示）。
  final void Function(String build, String? version)? _onExtensionReport;

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
      popupDictionaryCssProvider: _popupDictionaryCssProvider,
      onExtensionPopupSize: _onExtensionPopupSize,
      onExtensionSeen: _onExtensionSeen,
      onLookupActivity: _onLookupActivity,
      onExtensionReport: _onExtensionReport,
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
