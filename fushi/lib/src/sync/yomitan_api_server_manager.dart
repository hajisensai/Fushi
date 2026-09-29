import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show VideoSubtitleRegistry;
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart'
    show BrowserVideoSample;
import 'package:fushi/src/sync/extension_font_api.dart';
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
    RemoteThemeColorsProvider? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    bool Function()? autoReadOnLookupProvider,
    String? Function()? extensionBuildProvider,
    String Function()? appLocaleProvider,
    RemotePopupDictionaryCss Function()? popupDictionaryCssProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function(BrowserVideoSample sample)? onExtensionStudy,
    void Function()? onExtensionSeen,
    void Function()? onLookupActivity,
    void Function(String build, String? version)? onExtensionReport,
    Future<VideoSubtitleRegistry?> Function()? subtitleRegistryProvider,
    String Function()? extensionTestPageProvider,
    ExtensionFontApi? fontApi,
  })  : _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _themeColorsProvider = themeColorsProvider,
        _audioSourcesProvider = audioSourcesProvider,
        _autoReadOnLookupProvider = autoReadOnLookupProvider,
        _extensionBuildProvider = extensionBuildProvider,
        _appLocaleProvider = appLocaleProvider,
        _popupDictionaryCssProvider = popupDictionaryCssProvider,
        _onExtensionPopupSize = onExtensionPopupSize,
        _onExtensionStudy = onExtensionStudy,
        _onExtensionSeen = onExtensionSeen,
        _onLookupActivity = onLookupActivity,
        _onExtensionReport = onExtensionReport,
        _subtitleRegistryProvider = subtitleRegistryProvider,
        _extensionTestPageProvider = extensionTestPageProvider,
        _fontApi = fontApi;

  final FushiRemoteLookupService _lookup;
  final FushiRemoteMiningService? _mining;
  final FushiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  // BUG-530：主题 CSS 变量供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展弹窗。
  final RemoteThemeColorsProvider? _themeColorsProvider;
  // 单词音频：已启用音频源供给器，透传给 [YomitanApiServer]，随查词响应下发给扩展。
  final List<String> Function()? _audioSourcesProvider;
  final bool Function()? _autoReadOnLookupProvider;
  // BUG-726：扩展内容指纹供给器，透传给 [YomitanApiServer]，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // app 当前 UI 语言供给器，透传给 [YomitanApiServer]（status `locale` / 查词 `appLocale`）。
  final String Function()? _appLocaleProvider;
  // BUG-1718：词典自带 CSS + 用户自定义 CSS 供给器，透传给 [YomitanApiServer]，
  // 按 revision 门控随查词响应下发给扩展弹窗。
  final RemotePopupDictionaryCss Function()? _popupDictionaryCssProvider;
  // 弹窗尺寸精细化 Phase D：扩展弹窗拖角调整后回写尺寸的 sink，透传给 [YomitanApiServer]。
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  // 扩展视频沉浸时间样本的 sink，透传给 [YomitanApiServer]（app 侧进学习统计）。
  final void Function(BrowserVideoSample sample)? _onExtensionStudy;
  // 浏览器扩展连接探活回调，透传给 [YomitanApiServer]（app 侧记录 last-seen）。
  final void Function()? _onExtensionSeen;
  // TODO-2936：查词/制卡活动回调，透传给 [YomitanApiServer]（app 侧应用「浏览器」
  // 媒体类型的 Profile 绑定）。
  final void Function()? _onLookupActivity;
  // BUG-1079：扩展自报版本回调，透传给 [YomitanApiServer]（app 侧记录浏览器中实际
  // 加载的 build，与内置指纹比对给出更新提示）。
  final void Function(String build, String? version)? _onExtensionReport;
  // 「Jimaku 查字幕」扩展桥：Jimaku API key 供给器，透传给 [YomitanApiServer]。
  final Future<VideoSubtitleRegistry?> Function()? _subtitleRegistryProvider;
  // 新手引导「试一试」页的 HTML 供给器，透传给 [YomitanApiServer]（GET 路由）。
  final String Function()? _extensionTestPageProvider;
  // 扩展字幕外观「字体」下拉框的真源（app 字体目录 + 推荐字体下载），透传给
  // [YomitanApiServer] 的 /api/extension/fonts* 三路。
  final ExtensionFontApi? _fontApi;

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
      autoReadOnLookupProvider: _autoReadOnLookupProvider,
      extensionBuildProvider: _extensionBuildProvider,
      appLocaleProvider: _appLocaleProvider,
      popupDictionaryCssProvider: _popupDictionaryCssProvider,
      onExtensionPopupSize: _onExtensionPopupSize,
      onExtensionStudy: _onExtensionStudy,
      onExtensionSeen: _onExtensionSeen,
      onLookupActivity: _onLookupActivity,
      onExtensionReport: _onExtensionReport,
      subtitleRegistryProvider: _subtitleRegistryProvider,
      extensionTestPageProvider: _extensionTestPageProvider,
      fontApi: _fontApi,
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
