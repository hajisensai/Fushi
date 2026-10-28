import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show VideoSubtitleRegistry;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart'
    show BrowserVideoSample;
import 'package:fushi/src/sync/extension_font_api.dart';
import 'package:fushi/src/sync/fushi_api_access_policy.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// 持有并按需启停 [FushiApiServer]。tokenizer（带读音的分词）注入解耦 FFI。
/// BUG-530：注入挖词/历史 service，让浏览器扩展的 `/api/mine` + `/api/lookup/dictionary`
/// 在这个（扩展被自动配置指向的）server 上真正可用。
class FushiApiServerManager {
  FushiApiServerManager({
    required FushiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    FushiRemoteMiningService? miningService,
    FushiRemoteHistoryService? historyService,
    RemoteThemeColorsProvider? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    bool Function()? autoReadOnLookupProvider,
    bool Function()? dictionaryUnifiedStyleProvider,
    String? Function()? extensionBuildProvider,
    String Function()? appLocaleProvider,
    RemotePopupDictionaryCss Function()? popupDictionaryCssProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function(BrowserVideoSample sample)? onExtensionStudy,
    ExtensionFavoriteHandler? onExtensionFavorite,
    void Function()? onExtensionSeen,
    void Function()? onLookupActivity,
    void Function(String build, String? version)? onExtensionReport,
    Future<VideoSubtitleRegistry?> Function()? subtitleRegistryProvider,
    String Function()? extensionTestPageProvider,
    ExtensionFontApi? fontApi,
    SrsExtensionApi? Function()? srsApiProvider,
    FushiExtensionApiCore? extensionApiCore,
  }) : _lookup = lookupService,
       _mining = miningService,
       _history = historyService,
       _tokenizer = tokenizer,
       _themeColorsProvider = themeColorsProvider,
       _audioSourcesProvider = audioSourcesProvider,
       _autoReadOnLookupProvider = autoReadOnLookupProvider,
       _dictionaryUnifiedStyleProvider = dictionaryUnifiedStyleProvider,
       _extensionBuildProvider = extensionBuildProvider,
       _appLocaleProvider = appLocaleProvider,
       _popupDictionaryCssProvider = popupDictionaryCssProvider,
       _onExtensionPopupSize = onExtensionPopupSize,
       _onExtensionStudy = onExtensionStudy,
       _onExtensionFavorite = onExtensionFavorite,
       _onExtensionSeen = onExtensionSeen,
       _onLookupActivity = onLookupActivity,
       _onExtensionReport = onExtensionReport,
       _subtitleRegistryProvider = subtitleRegistryProvider,
       _extensionTestPageProvider = extensionTestPageProvider,
       _fontApi = fontApi,
       _srsApiProvider = srsApiProvider,
       _extensionApiCore = extensionApiCore;

  final FushiRemoteLookupService _lookup;
  final FushiRemoteMiningService? _mining;
  final FushiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  // BUG-530：主题 CSS 变量供给器，透传给 [FushiApiServer]，随查词响应下发给扩展弹窗。
  final RemoteThemeColorsProvider? _themeColorsProvider;
  // 单词音频：已启用音频源供给器，透传给 [FushiApiServer]，随查词响应下发给扩展。
  final List<String> Function()? _audioSourcesProvider;
  final bool Function()? _autoReadOnLookupProvider;
  // 「统一词典样式」偏好供给器，透传给 [FushiApiServer]，随查词响应下发给扩展弹窗。
  final bool Function()? _dictionaryUnifiedStyleProvider;
  // BUG-726：扩展内容指纹供给器，透传给 [FushiApiServer]，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // app 当前 UI 语言供给器，透传给 [FushiApiServer]（status `locale` / 查词 `appLocale`）。
  final String Function()? _appLocaleProvider;
  // BUG-1718：词典自带 CSS + 用户自定义 CSS 供给器，透传给 [FushiApiServer]，
  // 按 revision 门控随查词响应下发给扩展弹窗。
  final RemotePopupDictionaryCss Function()? _popupDictionaryCssProvider;
  // 弹窗尺寸精细化 Phase D：扩展弹窗拖角调整后回写尺寸的 sink，透传给 [FushiApiServer]。
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  // 扩展视频沉浸时间样本的 sink，透传给 [FushiApiServer]（app 侧进学习统计）。
  final void Function(BrowserVideoSample sample)? _onExtensionStudy;
  final ExtensionFavoriteHandler? _onExtensionFavorite;
  // 浏览器扩展连接探活回调，透传给 [FushiApiServer]（app 侧记录 last-seen）。
  final void Function()? _onExtensionSeen;
  // TODO-2936：查词/制卡活动回调，透传给 [FushiApiServer]（app 侧应用「浏览器」
  // 媒体类型的 Profile 绑定）。
  final void Function()? _onLookupActivity;
  // BUG-1079：扩展自报版本回调，透传给 [FushiApiServer]（app 侧记录浏览器中实际
  // 加载的 build，与内置指纹比对给出更新提示）。
  final void Function(String build, String? version)? _onExtensionReport;
  // 「Jimaku 查字幕」扩展桥：Jimaku API key 供给器，透传给 [FushiApiServer]。
  final Future<VideoSubtitleRegistry?> Function()? _subtitleRegistryProvider;
  // 新手引导「试一试」页的 HTML 供给器，透传给 [FushiApiServer]（GET 路由）。
  final String Function()? _extensionTestPageProvider;
  // 扩展字幕外观「字体」下拉框的真源（app 字体目录 + 推荐字体下载），透传给
  // [FushiApiServer] 的 /api/extension/fonts* 三路。
  final ExtensionFontApi? _fontApi;
  // 复习（SRS）扩展端点供给器，透传给 [FushiApiServer]（模块关着时回 null → 404）。
  final SrsExtensionApi? Function()? _srsApiProvider;
  // 浏览器扩展端点核心（与 app 内浏览器共用同一实例），透传给 [FushiApiServer]；
  // null 时 server 用上面那批 sink / 供给器自建一个。
  final FushiExtensionApiCore? _extensionApiCore;

  FushiApiServer? _server;

  /// AnkiConnect v6 兼容端点（Fushi SRS）。null = SRS 模块关闭，根路径 404。
  /// 运行中切换立即作用到当前 server，下次 [start] 也带上。
  SrsAnkiConnectEndpoint? _ankiConnectEndpoint;

  SrsAnkiConnectEndpoint? get ankiConnectEndpoint => _ankiConnectEndpoint;

  set ankiConnectEndpoint(SrsAnkiConnectEndpoint? endpoint) {
    _ankiConnectEndpoint = endpoint;
    _server?.ankiConnectEndpoint = endpoint;
  }

  bool get isRunning => _server?.isRunning ?? false;
  int? get port => _server?.port;

  Future<void> start({
    required int port,
    required String apiKey,
    FushiApiAccessPolicy accessPolicy = FushiApiAccessPolicy.localOnly,
  }) async {
    if (_server != null) return;
    final FushiApiServer server = FushiApiServer(
      port: port,
      lookupService: _lookup,
      miningService: _mining,
      historyService: _history,
      tokenizer: _tokenizer,
      themeColorsProvider: _themeColorsProvider,
      audioSourcesProvider: _audioSourcesProvider,
      autoReadOnLookupProvider: _autoReadOnLookupProvider,
      dictionaryUnifiedStyleProvider: _dictionaryUnifiedStyleProvider,
      extensionBuildProvider: _extensionBuildProvider,
      appLocaleProvider: _appLocaleProvider,
      popupDictionaryCssProvider: _popupDictionaryCssProvider,
      onExtensionPopupSize: _onExtensionPopupSize,
      onExtensionStudy: _onExtensionStudy,
      onExtensionFavorite: _onExtensionFavorite,
      onExtensionSeen: _onExtensionSeen,
      onLookupActivity: _onLookupActivity,
      onExtensionReport: _onExtensionReport,
      subtitleRegistryProvider: _subtitleRegistryProvider,
      extensionTestPageProvider: _extensionTestPageProvider,
      fontApi: _fontApi,
      srsApiProvider: _srsApiProvider,
      apiKey: apiKey.isEmpty ? null : apiKey,
      accessPolicy: accessPolicy,
      ankiConnectEndpoint: _ankiConnectEndpoint,
      extensionApiCore: _extensionApiCore,
    );
    // 先登记再 await 绑端口：绑定是 I/O、会让出事件循环，启动期间（app 冷启动时
    // SRS runtime 恰在这段空档里注入 AnkiConnect 端点）的 setter 必须能推到这台
    // server 上——登记晚于 await 时注入只落在 manager，server 的端点永远是 null，
    // 根路径恒 404。
    _server = server;
    try {
      await server.start();
    } catch (_) {
      if (identical(_server, server)) _server = null;
      rethrow;
    }
    // 绑定期间被 [stop] 撤下：起好的这台没人再持有，立即关掉而不是让它孤儿运行。
    if (!identical(_server, server)) await server.stop();
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
  }
}
