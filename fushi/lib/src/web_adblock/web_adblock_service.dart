import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

/// app 侧的广告拦截服务：Rust 胖核心（`AdblockCore`，状态全在 Rust 并落盘）的薄壳。
///
/// 这里只做三件事：
/// - 按 Rust 给的清单联网取过滤列表的**原始字节**（走 `createAppHttpClient` 的全局代理），交回
///   Rust；慢的编译在后台 isolate；
/// - 把 Rust 的状态快照（[snapshot]）转成 [ChangeNotifier] 通知给设置页——这是 Rust 快照的
///   最新一份，不是另存的镜像状态；
/// - 实现 [WebAdblockPolicy]，把 WebView 的逐请求 / cosmetic 查询原样转给 Rust。
///
/// 原生库是硬依赖：缺库时第一次用到就抛 `FushiWebCoreLibraryMissing`（打包错误），没有
/// 「判不可用」的降级分支。
class WebAdblockService extends ChangeNotifier implements WebAdblockPolicy {
  /// [dataDir] 是**惰性**取的：第一次真要用核心时才求值；返回 null = 数据目录还没就绪
  /// （AppModel 还没初始化完，例如只渲染设置页的测试宿主），此时 [snapshot] 是
  /// [AdblockSnapshot.notOpened]、命令抛 [StateError]，不打开核心。
  WebAdblockService({
    required Directory? Function() dataDir,
    required AdblockHttpFetcher fetcher,
    WebAdblockNetworkMode? mode,
  }) : _dataDir = dataDir,
       _fetcher = fetcher,
       _mode = mode ?? currentWebAdblockNetworkMode;

  /// 用 [AppModel] 的目录装配；列表下载走全应用代理（`createAppHttpClient`）。
  factory WebAdblockService.forApp(AppModel appModel) => WebAdblockService(
    dataDir: () => appModel.isInitialised
        ? Directory(
            '${appModel.appDirectory.path}${Platform.pathSeparator}web_adblock',
          )
        : null,
    fetcher: httpClientAdblockFetcher(clientFactory: createAppHttpClient),
  );

  final Directory? Function() _dataDir;
  final AdblockHttpFetcher _fetcher;
  final WebAdblockNetworkMode _mode;

  AdblockCore? _core;
  AdblockSnapshot? _snapshot;
  Future<void>? _inFlight;
  List<Map<String, Object?>> _rules = const <Map<String, Object?>>[];
  bool _disposed = false;

  AdblockCore? _tryOpen() {
    final AdblockCore? open = _core;
    if (open != null) return open;
    final Directory? dir = _dataDir();
    if (dir == null) return null;
    return _core = AdblockCore.open(
      dir.path,
      wantContentBlocking: _mode == WebAdblockNetworkMode.contentBlockers,
    );
  }

  AdblockCore get _live =>
      _tryOpen() ??
      (throw StateError('web adblock data directory is not ready yet'));

  /// Rust 核心的最新快照（首次读取时打开核心；数据目录未就绪时是
  /// [AdblockSnapshot.notOpened]，不缓存）。
  AdblockSnapshot get snapshot {
    final AdblockSnapshot? cached = _snapshot;
    if (cached != null) return cached;
    final AdblockCore? core = _tryOpen();
    if (core == null) return AdblockSnapshot.notOpened;
    return _snapshot = core.snapshot();
  }

  void _publish(AdblockSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 命令

  /// 总开关。打开时顺带发起一次同步。
  Future<void> setEnabled(bool enabled) async {
    _publish(_live.setEnabled(enabled));
    if (enabled) await ensureLoaded();
  }

  /// 订阅 / 取消订阅一份列表，然后同步让引擎跟上。
  Future<void> setListEnabled(String id, bool enabled) async {
    _publish(_live.setListEnabled(id, enabled));
    await _serialized(() => _sync(force: false));
  }

  /// 白名单原文。
  void setAllowlist(String raw) => _publish(_live.setAllowlist(raw));

  /// 按需同步一次：Rust 判断要不要联网 / 重编（缓存新鲜且引擎已是最新时什么也不做）。
  /// 并发调用共用一次。
  Future<void> ensureLoaded() {
    if (_tryOpen() == null) return Future<void>.value();
    return _serialized(() => _sync(force: false));
  }

  /// 「立即更新」：强制联网核对全部订阅列表。返回是否至少有一份新取到或确认未变。
  Future<bool> updateNow() async {
    await _serialized(() => _sync(force: true));
    return snapshot.lastSyncOk ?? false;
  }

  Future<void> _serialized(Future<void> Function() body) {
    final Future<void>? running = _inFlight;
    if (running != null) {
      return running
          .then((_) {}, onError: (Object _) {})
          .then((_) => _serialized(body));
    }
    final Future<void> next = body().whenComplete(() => _inFlight = null);
    _inFlight = next;
    return next;
  }

  Future<void> _sync({required bool force}) async {
    final AdblockCore core = _live;
    final AdblockSyncPlan plan = core.beginSync(force: force);
    if (!plan.run) {
      _publish(core.snapshot());
      return;
    }
    _publish(core.snapshot()); // loading
    try {
      for (final AdblockFetchItem item in plan.fetch) {
        AdblockFetchResponse? resp;
        Object? failure;
        try {
          resp = await _fetcher(
            item.url,
            etag: item.etag,
            lastModified: item.lastModified,
          );
        } on Object catch (error) {
          failure = error;
        }
        if (_disposed) break;
        core.ingest(
          item.id,
          statusCode: resp?.statusCode ?? 0,
          body: resp?.body,
          etag: resp?.etag,
          lastModified: resp?.lastModified,
          error: failure?.toString(),
        );
      }
    } finally {
      // 无论如何都收尾，否则 Rust 侧一直处于同步中、后续同步都被拒。
      final AdblockSnapshot s = await core.finishSyncInBackground();
      if (_mode == WebAdblockNetworkMode.contentBlockers && s.isActive) {
        _rules = await _decodeRules(core.contentBlockersJson());
      }
      _publish(s);
    }
  }

  static Future<List<Map<String, Object?>>> _decodeRules(Uint8List? json) {
    if (json == null) {
      return Future<List<Map<String, Object?>>>.value(
        const <Map<String, Object?>>[],
      );
    }
    // 5 万条规则的 JSON 解码放后台，不卡 UI。
    return Isolate.run<List<Map<String, Object?>>>(() {
      final Object? decoded = const Utf8Decoder()
          .fuse(const JsonDecoder())
          .convert(json);
      return decoded is List
          ? decoded.whereType<Map<String, Object?>>().toList(growable: false)
          : const <Map<String, Object?>>[];
    });
  }

  // ------------------------------------------------------------------ WebAdblockPolicy

  @override
  bool get isActive => snapshot.isActive;

  @override
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    Uri? pageUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) =>
      (_core ?? _tryOpen())?.check(
        url,
        sourceUrl: sourceUrl,
        pageUrl: pageUrl?.toString(),
        type: type,
      ) ??
      AdblockDecision.allow;

  @override
  String? cosmeticPayload(String href, {Uri? pageUrl}) =>
      _tryOpen()?.cosmeticPayload(href, pageUrl: pageUrl?.toString());

  @override
  String? genericPayload(
    String href, {
    Uri? pageUrl,
    required String classes,
    required String ids,
  }) => _tryOpen()?.genericPayload(
    href,
    pageUrl: pageUrl?.toString(),
    classes: classes,
    ids: ids,
  );

  @override
  List<Map<String, Object?>> get contentBlockingRules => _rules;

  @override
  void dispose() {
    _disposed = true;
    final AdblockCore? core = _core;
    _core = null;
    final Future<void>? running = _inFlight;
    if (core != null) {
      // 后台 isolate 可能还拿着句柄地址：等在途同步收尾再关。
      if (running == null) {
        core.close();
      } else {
        unawaited(running.whenComplete(core.close));
      }
    }
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
