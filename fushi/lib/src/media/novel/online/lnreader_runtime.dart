import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

/// 插件执行失败（插件自己抛的异常 / 宿主找不到插件 / 网络失败），消息原样来自 JS。
class LnReaderPluginException implements Exception {
  const LnReaderPluginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 装载插件所需的源码与持久化存储快照。
typedef LnReaderPluginSource = ({String code, Map<String, Object?> storage});

/// LNReader 插件的执行面。调用方只和这个接口打交道，生产实现是
/// [WebViewLnReaderRuntime]；测试注入假实现。
abstract interface class LnReaderRuntime {
  /// 确保插件已装载（运行时重建后会自动重新装载），返回插件自报的元数据。
  Future<LnReaderPluginInfo> ensureLoaded(
    String pluginId,
    Future<LnReaderPluginSource> Function() source,
  );

  /// 卸载 / 更新插件后调用：下次 [ensureLoaded] 重新读源码。
  Future<void> forget(String pluginId);

  Future<List<LnReaderNovelItem>> popular(
    String pluginId, {
    required int page,
    required bool latest,
    Map<String, Object?>? filters,
  });

  Future<List<LnReaderNovelItem>> search(
    String pluginId, {
    required String query,
    required int page,
  });

  /// 作品详情。多页目录（`totalPages > 1` 且插件有 `parsePage`）已合并成完整
  /// 章节表。
  Future<LnReaderNovel> novel(String pluginId, String path);

  /// 章节正文（插件给的 HTML）。
  Future<String> chapter(String pluginId, String path);

  /// 相对路径 → 源站网页地址（插件 `resolveUrl`，缺省 site + path）。
  Future<String> resolveUrl(
    String pluginId,
    String path, {
    required bool isNovel,
  });

  /// 章节 HTML → EPUB 可用的 XHTML 片段，图片换成 `[imagePrefix]N.ext`。
  Future<LnReaderXhtml> toXhtml(
    String html, {
    required String baseUrl,
    required String imagePrefix,
  });

  Future<void> dispose();
}

/// 在一个 headless WebView 里跑 LNReader 插件。
///
/// - 懒建：第一次调用才起 WebView（桌面 WebView2 要求 Flutter view 已挂载，
///   这时一定已有首帧）；空闲 [idleTimeout] 后自动销毁，释放 renderer 子进程。
/// - renderer 死亡：在途调用全部以异常结束，下一次调用重建并重新装载插件。
///   `onRenderProcessGone` 回调**必须传**——Android 侧拿不到回调时默认动作是连
///   整个 app 进程一起杀。
/// - 所有出站请求经 [LnReaderFetchBridge]（app 代理 + 无 CORS）。
class WebViewLnReaderRuntime implements LnReaderRuntime {
  WebViewLnReaderRuntime({
    required LnReaderFetchBridge fetchBridge,
    required this.onStoragePersist,
    this.idleTimeout = const Duration(minutes: 5),
    this.callTimeout = const Duration(minutes: 3),
    Future<String> Function(String key)? assetLoader,
  }) : _fetchBridge = fetchBridge,
       _assetLoader = assetLoader ?? rootBundle.loadString;

  final LnReaderFetchBridge _fetchBridge;

  /// 插件写了 `@libs/storage`：把该插件的完整存储快照交给持久层。
  final Future<void> Function(String pluginId, Map<String, Object?> data)
  onStoragePersist;
  final Duration idleTimeout;
  final Duration callTimeout;
  final Future<String> Function(String key) _assetLoader;

  static const String libsAsset = 'assets/lnreader/lnreader_libs.js';
  static const String hostAsset = 'assets/lnreader/lnreader_host.js';

  HeadlessInAppWebView? _webView;
  Future<InAppWebViewController>? _ready;
  final Map<String, LnReaderPluginInfo> _loaded =
      <String, LnReaderPluginInfo>{};
  final Map<String, Future<LnReaderPluginInfo>> _loading =
      <String, Future<LnReaderPluginInfo>>{};
  int _inFlight = 0;
  Timer? _idleTimer;
  bool _disposed = false;

  /// 当前这一代 WebView 死亡时完成；在途调用与它赛跑。
  Completer<void> _death = Completer<void>();

  Future<InAppWebViewController> _controller() {
    if (_disposed) {
      return Future<InAppWebViewController>.error(
        StateError('LNReader runtime disposed'),
      );
    }
    return _ready ??= _start();
  }

  Future<InAppWebViewController> _start() async {
    final String libs = await _assetLoader(libsAsset);
    final String host = await _assetLoader(hostAsset);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final Completer<InAppWebViewController> loaded =
        Completer<InAppWebViewController>();
    _death = Completer<void>();
    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data:
            '<!doctype html><html><head><meta charset="utf-8"></head>'
            '<body></body></html>',
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri('https://fushi.local/lnreader/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // 宿主页不加载任何外部资源；插件网络全部经桥。
        blockNetworkImage: true,
        disableContextMenu: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        controller.addJavaScriptHandler(
          handlerName: 'fushiLnFetch',
          callback: (List<dynamic> args) =>
              _fetchBridge.perform(args.isEmpty ? null : args.first),
        );
        controller.addJavaScriptHandler(
          handlerName: 'fushiLnStorage',
          callback: (List<dynamic> args) async {
            final Object? payload = args.isEmpty ? null : args.first;
            if (payload is Map && payload['id'] != null) {
              final Object? data = payload['data'];
              await onStoragePersist(
                payload['id'].toString(),
                data is Map
                    ? data.map(
                        (Object? key, Object? value) =>
                            MapEntry<String, Object?>(key.toString(), value),
                      )
                    : <String, Object?>{},
              );
            }
            return true;
          },
        );
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        if (loaded.isCompleted) return;
        try {
          await controller.evaluateJavascript(source: libs);
          await controller.evaluateJavascript(source: host);
          final Object? ok = await controller.evaluateJavascript(
            source: 'typeof globalThis.__fushiLnReader === "object"',
          );
          if (ok != true) {
            throw const LnReaderPluginException(
              'LNReader host failed to initialise',
            );
          }
          loaded.complete(controller);
        } on Object catch (error, stack) {
          if (!loaded.isCompleted) loaded.completeError(error, stack);
        }
      },
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(_handleDeath()),
    );
    _webView = webView;
    await webView.run();
    return loaded.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw const LnReaderPluginException(
        'LNReader host did not load in time',
      ),
    );
  }

  Future<void> _handleDeath() async {
    if (!_death.isCompleted) _death.complete();
    await _teardown();
  }

  Future<void> _teardown() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final HeadlessInAppWebView? webView = _webView;
    _webView = null;
    _ready = null;
    _loaded.clear();
    _loading.clear();
    if (webView != null) {
      try {
        await webView.dispose();
      } on Object {
        // renderer 已死时 dispose 可能抛；这一代反正要丢。
      }
    }
  }

  Future<T> _track<T>(Future<T> Function() body) async {
    _idleTimer?.cancel();
    _inFlight++;
    try {
      return await body();
    } finally {
      _inFlight--;
      if (_inFlight == 0 && !_disposed) {
        _idleTimer = Timer(idleTimeout, () {
          if (_inFlight == 0) unawaited(_teardown());
        });
      }
    }
  }

  /// 调宿主 `__fushiLnReader[method](...args)`，结果经 JSON 过桥（各平台
  /// `callAsyncJavaScript` 返回值的解码形态不一致，统一成字符串最稳）。
  Future<Object?> _invoke(
    String method,
    List<Object?> args,
  ) => _track(() async {
    final InAppWebViewController controller = await _controller();
    final Completer<void> death = _death;
    final Future<CallAsyncJavaScriptResult?> call = controller
        .callAsyncJavaScript(
          functionBody:
              'const r = await globalThis.__fushiLnReader[method]'
              '.apply(null, args);'
              'return JSON.stringify(r === undefined ? null : r);',
          arguments: <String, dynamic>{'method': method, 'args': args},
        );
    final CallAsyncJavaScriptResult? result =
        await Future.any(<Future<CallAsyncJavaScriptResult?>>[
          call,
          death.future.then<CallAsyncJavaScriptResult?>(
            (_) => throw const LnReaderPluginException('LNReader host crashed'),
          ),
        ]).timeout(
          callTimeout,
          onTimeout: () =>
              throw LnReaderPluginException('LNReader call timed out: $method'),
        );
    if (result == null) {
      throw LnReaderPluginException('LNReader call failed: $method');
    }
    final String? error = result.error;
    if (error != null && error.isNotEmpty) {
      throw LnReaderPluginException(error);
    }
    final Object? value = result.value;
    if (value is String) return jsonDecode(value);
    return value;
  });

  @override
  Future<LnReaderPluginInfo> ensureLoaded(
    String pluginId,
    Future<LnReaderPluginSource> Function() source,
  ) {
    final LnReaderPluginInfo? info = _loaded[pluginId];
    if (info != null && _ready != null) return Future.value(info);
    return _loading[pluginId] ??= () async {
      try {
        final LnReaderPluginSource loaded = await source();
        final Object? raw = await _invoke('load', <Object?>[
          pluginId,
          loaded.code,
          loaded.storage,
        ]);
        final LnReaderPluginInfo info = LnReaderPluginInfo.fromJson(
          raw is Map ? raw : const <Object?, Object?>{},
        );
        _loaded[pluginId] = info;
        return info;
      } finally {
        unawaited(_loading.remove(pluginId));
      }
    }();
  }

  @override
  Future<void> forget(String pluginId) async {
    _loaded.remove(pluginId);
    if (_ready == null) return;
    await _invoke('unload', <Object?>[pluginId]);
  }

  @override
  Future<List<LnReaderNovelItem>> popular(
    String pluginId, {
    required int page,
    required bool latest,
    Map<String, Object?>? filters,
  }) async => _items(
    await _invoke('popular', <Object?>[pluginId, page, latest, filters]),
  );

  @override
  Future<List<LnReaderNovelItem>> search(
    String pluginId, {
    required String query,
    required int page,
  }) async => _items(await _invoke('search', <Object?>[pluginId, query, page]));

  @override
  Future<LnReaderNovel> novel(String pluginId, String path) async {
    final Object? raw = await _invoke('novel', <Object?>[pluginId, path]);
    final LnReaderNovel novel = LnReaderNovel.fromJson(
      raw is Map ? raw : const <Object?, Object?>{},
    );
    final LnReaderPluginInfo? info = _loaded[pluginId];
    if (novel.totalPages <= 1 || info == null || !info.hasParsePage) {
      return novel;
    }
    // 多页目录：parseNovel 只带首页（有的插件首页一章都不带），其余页逐页取。
    final List<List<LnReaderChapter>> pages = <List<LnReaderChapter>>[
      novel.chapters,
    ];
    for (
      int page = novel.chapters.isEmpty ? 1 : 2;
      page <= novel.totalPages;
      page++
    ) {
      final Object? chapters = await _invoke('page', <Object?>[
        pluginId,
        path,
        page,
      ]);
      pages.add(<LnReaderChapter>[
        if (chapters is List)
          for (final Object? chapter in chapters)
            if (chapter is Map) LnReaderChapter.fromJson(chapter),
      ]);
    }
    return novel.withChapters(mergeLnReaderChapterPages(pages));
  }

  @override
  Future<String> chapter(String pluginId, String path) async =>
      (await _invoke('chapter', <Object?>[pluginId, path]) ?? '').toString();

  @override
  Future<String> resolveUrl(
    String pluginId,
    String path, {
    required bool isNovel,
  }) async =>
      (await _invoke('resolveUrl', <Object?>[pluginId, path, isNovel]) ?? '')
          .toString();

  @override
  Future<LnReaderXhtml> toXhtml(
    String html, {
    required String baseUrl,
    required String imagePrefix,
  }) async {
    final Object? raw = await _invoke('toXhtml', <Object?>[
      html,
      baseUrl,
      imagePrefix,
    ]);
    return LnReaderXhtml.fromJson(
      raw is Map ? raw : const <Object?, Object?>{},
    );
  }

  static List<LnReaderNovelItem> _items(Object? raw) => <LnReaderNovelItem>[
    if (raw is List)
      for (final Object? item in raw)
        if (item is Map) LnReaderNovelItem.fromJson(item),
  ];

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _teardown();
    _fetchBridge.close();
  }
}
