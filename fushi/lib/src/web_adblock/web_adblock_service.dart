import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 引擎所处阶段（设置页副标题用）。
enum WebAdblockStatus {
  /// 还没加载过（或总开关关着）。
  idle,

  /// 正在下载列表 / 编译 / 恢复缓存。
  loading,

  /// 引擎就绪。
  ready,

  /// 原生库不在本构建里（某平台没随包 / 开发机没编）：能力不可用，WebView 照常。
  unavailable,

  /// 加载失败且没有可用缓存（离线首装等），下次 [WebAdblockService.ensureLoaded] 重试。
  failed,
}

/// 解析白名单原文：逗号 / 空白分隔；容忍用户粘整条 URL、`*.` / `.` 前缀；统一小写。
Set<String> parseWebAdblockAllowlist(String raw) {
  final Set<String> out = <String>{};
  for (final String token in raw.split(RegExp(r'[\s,;，、]+'))) {
    String t = token.trim().toLowerCase();
    if (t.isEmpty) continue;
    if (t.contains('://')) t = Uri.tryParse(t)?.host ?? '';
    final int slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(0, slash);
    final int colon = t.indexOf(':');
    if (colon >= 0) t = t.substring(0, colon);
    while (t.startsWith('*.') || t.startsWith('.')) {
      t = t.substring(t.startsWith('*.') ? 2 : 1);
    }
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// [host] 是否命中白名单（精确或其子域名）。
bool webAdblockHostAllowlisted(String host, Set<String> allowlist) {
  final String h = host.toLowerCase();
  for (final String entry in allowlist) {
    if (h == entry || h.endsWith('.$entry')) return true;
  }
  return false;
}

/// app 侧的广告拦截服务：偏好 → 过滤列表（下载 / 缓存 / 过期刷新）→ 引擎（后台 isolate 编译、
/// 序列化缓存）。实现 [WebAdblockPolicy]，直接交给 [applyAdblockTo]。
///
/// 偏好读取一律经闭包**现读**（开关 / 白名单改了下一次请求就生效）；列表选择变了要调
/// [reload] 换引擎。原生库不可用时 [status] 恒为 [WebAdblockStatus.unavailable]，所有判定放行。
class WebAdblockService extends ChangeNotifier implements WebAdblockPolicy {
  /// [cacheDir] 是**惰性**取的：第一次真要加载列表时才求值（设置页渲染、AppModel 还没
  /// 初始化完的测试宿主都会构造本服务，届时目录可能还没就绪）。
  WebAdblockService({
    required Directory Function() cacheDir,
    required bool Function() readEnabled,
    required List<String> Function() readListIds,
    required String Function() readAllowlist,
    AdblockHttpFetcher? fetcher,
    FushiWebCoreLibrary? library,
    WebAdblockNetworkMode? mode,
  }) : _cacheDir = cacheDir,
       _fetcher = fetcher,
       _readEnabled = readEnabled,
       _readListIds = readListIds,
       _readAllowlist = readAllowlist,
       _library = library,
       _mode = mode ?? currentWebAdblockNetworkMode;

  /// 用 [AppModel] 的偏好与目录装配；列表下载走全应用代理（`createAppHttpClient`）。
  factory WebAdblockService.forApp(AppModel appModel) => WebAdblockService(
    cacheDir: () => Directory(
      '${appModel.appDirectory.path}${Platform.pathSeparator}web_adblock',
    ),
    readEnabled: () => appModel.webAdblockEnabled,
    readListIds: () => appModel.webAdblockListIds,
    readAllowlist: () => appModel.webAdblockAllowlist,
    fetcher: httpClientAdblockFetcher(clientFactory: createAppHttpClient),
  );

  final bool Function() _readEnabled;
  final List<String> Function() _readListIds;
  final String Function() _readAllowlist;
  final FushiWebCoreLibrary? _library;
  final WebAdblockNetworkMode _mode;
  final Directory Function() _cacheDir;
  final AdblockHttpFetcher? _fetcher;
  late final AdblockFilterListService _listService = AdblockFilterListService(
    cacheDir: _cacheDir(),
    fetcher: _fetcher,
  );

  FushiAdblockEngine? _engine;
  List<Map<String, Object?>> _rules = const <Map<String, Object?>>[];
  WebAdblockStatus _status = WebAdblockStatus.idle;
  DateTime? _lastUpdatedAt;
  List<AdblockListLoadResult> _lastResults = const <AdblockListLoadResult>[];
  Future<void>? _inFlight;
  String _allowlistRaw = '';
  Set<String> _allowlist = const <String>{};
  bool _disposed = false;

  FushiWebCoreLibrary? get _lib => _library ?? FushiWebCoreLibrary.instance;

  /// 原生库是否在本构建里。
  bool get isNativeAvailable => _lib != null;

  WebAdblockStatus get status =>
      isNativeAvailable ? _status : WebAdblockStatus.unavailable;

  /// 最近一次成功核对列表的时刻（各列表里最新的那个）；没下载过为 null。
  DateTime? get lastUpdatedAt => _lastUpdatedAt;

  /// 最近一次加载里每份列表的来源 / 错误。
  List<AdblockListLoadResult> get lastResults => _lastResults;

  /// 当前订阅的列表（偏好里的 id 映射到内置列表，未知 id 忽略）。
  List<AdblockFilterList> get selectedLists => <AdblockFilterList>[
    for (final String id in _readListIds())
      if (adblockFilterListById(id) case final AdblockFilterList l) l,
  ];

  @override
  bool get isActive => _readEnabled() && _engine != null;

  @override
  AdblockMatcher? get matcher => _engine;

  @override
  List<Map<String, Object?>> get contentBlockingRules => _rules;

  @override
  bool isAllowlisted(Uri? pageUrl) {
    final String host = pageUrl?.host ?? '';
    if (host.isEmpty) return false;
    final String raw = _readAllowlist();
    if (raw != _allowlistRaw) {
      _allowlistRaw = raw;
      _allowlist = parseWebAdblockAllowlist(raw);
    }
    return webAdblockHostAllowlisted(host, _allowlist);
  }

  /// 按需加载一次（开关关着 / 已就绪 / 原生库不可用时什么也不做）。并发调用共用一次加载。
  Future<void> ensureLoaded() {
    if (!_readEnabled() || !isNativeAvailable || _engine != null) {
      return Future<void>.value();
    }
    return _inFlight ??= _load(force: false).whenComplete(() {
      _inFlight = null;
    });
  }

  /// 「立即更新」：强制联网核对全部订阅列表并重建引擎。返回是否至少有一份列表是新取到
  /// 或确认未变的（全部失败 = false，引擎保持原样）。
  Future<bool> updateNow() async {
    if (!isNativeAvailable) return false;
    await _inFlight;
    await _load(force: true);
    return _lastResults.any(
      (AdblockListLoadResult r) =>
          r.source == AdblockListSource.downloaded ||
          r.source == AdblockListSource.notModified,
    );
  }

  /// 订阅集变了：丢掉当前引擎，按新集合重新加载（开关关着时只丢引擎）。
  Future<void> reload() async {
    await _inFlight;
    _replaceEngine(null, const <Map<String, Object?>>[]);
    _setStatus(WebAdblockStatus.idle);
    await ensureLoaded();
  }

  Future<void> _load({required bool force}) async {
    final FushiWebCoreLibrary? lib = _lib;
    if (lib == null) return;
    _setStatus(WebAdblockStatus.loading);
    final List<AdblockFilterList> lists = selectedLists;
    try {
      final AdblockEngineBundle? bundle =
          await AdblockEngineLoader(
            listService: _listService,
            library: lib,
          ).load(
            lists,
            forceRefresh: force,
            withContentBlockingRules:
                _mode == WebAdblockNetworkMode.contentBlockers,
          );
      if (_disposed) {
        bundle?.engine.dispose();
        return;
      }
      if (bundle == null) {
        // 一份列表都没拿到（离线首装 / 全部取消订阅）。已有引擎（updateNow 失败）保留。
        _lastResults = const <AdblockListLoadResult>[];
        _setStatus(
          _engine != null
              ? WebAdblockStatus.ready
              : (lists.isEmpty
                    ? WebAdblockStatus.idle
                    : WebAdblockStatus.failed),
        );
        return;
      }
      _lastResults = bundle.lists;
      _lastUpdatedAt = _latestFetch(bundle.lists);
      _replaceEngine(
        bundle.engine,
        bundle.contentBlockingRules ?? const <Map<String, Object?>>[],
      );
      _setStatus(WebAdblockStatus.ready);
    } on Object catch (error, stack) {
      debugPrint('[web_adblock] load failed: $error\n$stack');
      if (_disposed) return;
      _setStatus(
        _engine != null ? WebAdblockStatus.ready : WebAdblockStatus.failed,
      );
    }
  }

  static DateTime? _latestFetch(List<AdblockListLoadResult> results) {
    DateTime? latest;
    for (final AdblockListLoadResult r in results) {
      final DateTime? at = r.info?.fetchedAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  void _replaceEngine(
    FushiAdblockEngine? engine,
    List<Map<String, Object?>> rules,
  ) {
    final FushiAdblockEngine? old = _engine;
    _engine = engine;
    _rules = rules;
    if (old != null && !identical(old, engine)) old.dispose();
  }

  void _setStatus(WebAdblockStatus s) {
    if (_disposed) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _replaceEngine(null, const <Map<String, Object?>>[]);
    super.dispose();
  }
}

/// 全应用共用一个 [WebAdblockService]（引擎几 MB，别每个 WebView 各编一份）。
/// 读取方：`ref.read(webAdblockServiceProvider)` 交给 [applyAdblockTo]，并在页面打开时
/// `unawaited(service.ensureLoaded())`。
final ChangeNotifierProvider<WebAdblockService> webAdblockServiceProvider =
    ChangeNotifierProvider<WebAdblockService>((ref) {
      return WebAdblockService.forApp(ref.read(appProvider));
    });
