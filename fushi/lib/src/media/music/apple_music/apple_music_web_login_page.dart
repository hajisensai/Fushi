/// Apple ID 登录页（网页桥，Windows / Android）：可见 WebView 加载托管的 MusicKit JS 页并调
/// `authorize()`；MusicKit 用 `window.open` 开的 Apple ID 弹窗接成页内的第二个 WebView
/// （`windowId`，保住 opener 关系，登录结果才能 postMessage 回来）。成功 pop(true)。
///
/// Music-User-Token 由 MusicKit 存进托管页源的 localStorage；隐藏的播放 WebView 与这里同一
/// WebView 数据目录，重建后即读到（[AppleMusicWebBridge.authorize]）。
///
/// 登录分两段：先 `init()`（configure，带 [kAppleMusicWebInitTimeout]——DRM 服务卡死的设备上
/// MusicKit 在这里永远不返回），再 `authorize()`（用户输密码，不设超时）。弹窗每加载完一个
/// Apple 授权页就补回传通道（[appleMusicPopupOpenerSeedJs]），失败时按弹窗走过的页面给出原因
/// （[AppleMusicLoginBlocker]），整段轨迹写进诊断日志。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_login_flow.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/utils.dart';

/// 诊断日志来源名。
const String kAppleMusicLoginDiagSource = 'AppleMusic.login';

/// 调 init（MusicKit configure）。
const String _kInitJs = '''
const r = await window.fushiMusicKit.init();
return JSON.stringify(r || {ok: false});
''';

/// 调 authorize 并回报是否已授权。
const String _kAuthorizeJs = '''
const r = await window.fushiMusicKit.authorize();
return JSON.stringify(r || {ok: false});
''';

/// 弹窗页要新开窗口（Apple 授权页「立即体验」开订阅页）时走这个 JS handler，交给系统浏览器。
const String _kOpenExternalHandler = 'fushiAppleMusicOpenExternal';

/// 弹窗 Apple 授权页上把 `window.open(…, '_blank')` 转给 [_kOpenExternalHandler]：Android
/// WebView 的 onCreateWindow 拿不到 `window.open` 的目标地址，接成页内窗口又会盖住登录流程。
const String _kWrapWindowOpenJs =
    '''
(() => {
  if (location.hostname !== '$kAppleMusicAuthorizeHost' || window.__fushiOpenWrapped) return;
  window.__fushiOpenWrapped = true;
  const open = window.open;
  window.open = function (url, target) {
    if (target === '_blank' && window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('$_kOpenExternalHandler', String(url));
      return null;
    }
    return open.apply(this, arguments);
  };
})()
''';

/// 只把 https 的 Apple 页交给系统浏览器。
bool _isAppleHttps(Uri url) =>
    url.scheme == 'https' &&
    (url.host == 'apple.com' || url.host.endsWith('.apple.com'));

/// 登录失败的用户可读原因。
String appleMusicLoginFailureText({
  required AppleMusicLoginBlocker? blocker,
  required String? error,
}) => switch (blocker) {
  AppleMusicLoginBlocker.noSubscription =>
    t.music_apple_music_login_no_subscription,
  AppleMusicLoginBlocker.unsupportedCountry =>
    t.music_apple_music_login_unsupported_country,
  AppleMusicLoginBlocker.unsupportedDevice =>
    t.music_apple_music_login_unsupported_device,
  null => error ?? 'unknown',
};

class AppleMusicWebLoginPage extends StatefulWidget {
  const AppleMusicWebLoginPage({super.key});

  @override
  State<AppleMusicWebLoginPage> createState() => _AppleMusicWebLoginPageState();
}

class _AppleMusicWebLoginPageState extends State<AppleMusicWebLoginPage> {
  InAppWebViewController? _bridge;

  /// renderer / WebContent 进程死亡的统一处置（守卫
  /// `test/webview/webview_render_process_gone_guard_test.dart`）。桥页或弹窗任一死掉，
  /// 弹窗的 opener 关系都已断：丢掉旧控制器与弹窗，桥页按新 epoch 整个重建，加载完
  /// 重新 `authorize()`（[_bridge] 为 null 时 onLoadStop 才会接上）。
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'apple-music-web-login',
    flushBeforeRebuild: () async {
      _bridge = null;
      _popupWindowId = null;
    },
    afterRebuild: () {
      if (!mounted) return;
      setState(() {
        _busy = true;
        _error = null;
      });
    },
  );

  void _onWebContentTerminated(InAppWebViewController _) =>
      unawaited(_deathGuard.handleWebContentTerminated());

  void _onRenderProcessGone(
    InAppWebViewController _,
    RenderProcessGoneDetail detail,
  ) => unawaited(
    _deathGuard.handleDeath(
      didCrash: detail.didCrash,
      rendererPriorityAtExit: detail.rendererPriorityAtExit,
    ),
  );

  /// MusicKit 开的 Apple ID 弹窗（onCreateWindow 的 windowId）；null = 没开。
  int? _popupWindowId;

  bool _busy = true;
  String? _error;
  bool _done = false;

  /// 本次尝试的弹窗轨迹（每次 [_authorize] 重开）。
  AppleMusicLoginTrace _trace = AppleMusicLoginTrace();

  /// 跑一段桥函数体，解出 `{ok, ...}`；失败返回错误文本。
  Future<({Map<Object?, Object?>? ok, String? error})> _call(
    InAppWebViewController c,
    String body,
  ) async {
    final CallAsyncJavaScriptResult? r = await c.callAsyncJavaScript(
      functionBody: body,
    );
    if (r?.error case final String e when e.isNotEmpty) {
      return (ok: null, error: e);
    }
    final Object? v = r?.value;
    final Object? decoded = v is String ? jsonDecode(v) : v;
    if (decoded is Map && decoded['ok'] == true) {
      return (ok: decoded, error: null);
    }
    if (decoded is Map && decoded['error'] is Map) {
      final Map<Object?, Object?> e = decoded['error'] as Map<Object?, Object?>;
      return (
        ok: null,
        error: '${e['name'] ?? 'Error'}: ${e['message'] ?? ''}',
      );
    }
    return (ok: null, error: 'unknown');
  }

  Future<void> _authorize() async {
    final InAppWebViewController? c = _bridge;
    if (c == null || _done) return;
    final AppleMusicLoginTrace trace = AppleMusicLoginTrace();
    _trace = trace;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    String result;
    bool authorized = false;
    try {
      final ({Map<Object?, Object?>? ok, String? error}) init = await _call(
        c,
        _kInitJs,
      ).timeout(kAppleMusicWebInitTimeout);
      if (init.ok == null) {
        error = init.error;
        result = 'init failed: $error';
      } else {
        final ({Map<Object?, Object?>? ok, String? error}) auth = await _call(
          c,
          _kAuthorizeJs,
        );
        authorized = auth.ok?['authorized'] == true;
        error = auth.ok == null
            ? auth.error
            : (authorized ? null : 'not authorized');
        result = authorized ? 'authorized' : 'authorize failed: $error';
      }
    } on TimeoutException {
      error = t.music_apple_music_login_init_timeout;
      result = 'init timeout';
    } on Object catch (e) {
      error = '$e';
      result = 'error: $e';
    }
    ErrorLogService.instance.logDiagnostic(
      kAppleMusicLoginDiagSource,
      trace.describe(result),
    );
    if (!mounted || !identical(_trace, trace)) return;
    if (authorized) {
      _done = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _popupWindowId = null;
      _error = appleMusicLoginFailureText(blocker: trace.blocker, error: error);
    });
  }

  /// 弹窗加载完一页：记轨迹；在 Apple 授权页上补回传通道、接管新开窗口。
  Future<void> _onPopupLoadStop(InAppWebViewController c, WebUri? url) async {
    if (url == null) return;
    final AppleMusicLoginTrace trace = _trace;
    trace.popupPage(url);
    if (url.host != kAppleMusicAuthorizeHost) return;
    try {
      trace.openerSeed(
        await c.evaluateJavascript(
          source: appleMusicPopupOpenerSeedJs(kAppleMusicWebBridgePage),
        ),
      );
      await c.evaluateJavascript(source: _kWrapWindowOpenJs);
    } on Object catch (e) {
      trace.openerSeed('error');
      ErrorLogService.instance.logDiagnostic(
        kAppleMusicLoginDiagSource,
        'popup script failed: $e',
      );
    }
  }

  void _onPopupCreated(InAppWebViewController c) {
    c.addJavaScriptHandler(
      handlerName: _kOpenExternalHandler,
      callback: (List<dynamic> args) {
        final Uri? url = args.isEmpty ? null : Uri.tryParse('${args.first}');
        if (url != null && _isAppleHttps(url)) {
          _trace.externalOpen(url);
          unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int? popup = _popupWindowId;
    final bool overlay = popup == null && (_busy || _error != null);
    return FushiPageScaffold(
      title: t.music_apple_music_login_title,
      body: Stack(
        children: <Widget>[
          // 桥页面本身（无可见内容）：撑满但留在弹窗下面。
          Positioned.fill(
            child: InAppWebView(
              key: _deathGuard.rebuildKey,
              initialUrlRequest: URLRequest(
                url: WebUri.uri(kAppleMusicWebBridgePage),
              ),
              initialSettings: appleMusicWebViewSettings(),
              onWebContentProcessDidTerminate: _onWebContentTerminated,
              onRenderProcessGone: _onRenderProcessGone,
              onPermissionRequest:
                  (InAppWebViewController _, PermissionRequest r) =>
                      appleMusicPermissionResponse(r),
              onLoadStop: (InAppWebViewController c, WebUri? _) {
                if (_bridge != null) return;
                _bridge = c;
                unawaited(_authorize());
              },
              onReceivedError:
                  (
                    InAppWebViewController _,
                    WebResourceRequest req,
                    WebResourceError e,
                  ) {
                    if (req.isForMainFrame == false || !mounted) return;
                    setState(() {
                      _busy = false;
                      _error = e.description;
                    });
                  },
              onCreateWindow:
                  (InAppWebViewController _, CreateWindowAction a) async {
                    if (!mounted) return false;
                    setState(() => _popupWindowId = a.windowId);
                    return true;
                  },
            ),
          ),
          if (popup != null)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: InAppWebView(
                  key: ValueKey<int>(popup),
                  windowId: popup,
                  initialSettings: appleMusicWebViewSettings(),
                  onWebViewCreated: _onPopupCreated,
                  onLoadStop: (InAppWebViewController c, WebUri? url) =>
                      unawaited(_onPopupLoadStop(c, url)),
                  // 弹窗里再开窗口只有 Apple 授权页的订阅入口，已由 _kWrapWindowOpenJs 外开；
                  // 其余一律不接，不在登录页上叠第三层 WebView。
                  onCreateWindow:
                      (InAppWebViewController _, CreateWindowAction _) async =>
                          false,
                  onWebContentProcessDidTerminate: _onWebContentTerminated,
                  onRenderProcessGone: _onRenderProcessGone,
                  onCloseWindow: (InAppWebViewController _) {
                    _trace.popupClosed();
                    if (mounted) setState(() => _popupWindowId = null);
                  },
                ),
              ),
            ),
          // 加载 / 出错遮罩：三种状态（加载 → 出错 → 弹窗 / 登录页）之间交叉淡化，不硬切；
          // 遮罩淡出时由 IgnorePointer 放行底下的登录页 / 弹窗。
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !overlay,
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                child: !overlay
                    ? const SizedBox.expand(
                        key: ValueKey<String>('apple_music_login_none'),
                      )
                    : ColoredBox(
                        key: ValueKey<String>(
                          _error == null
                              ? 'apple_music_login_busy'
                              : 'apple_music_login_error',
                        ),
                        color: Theme.of(context).colorScheme.surface,
                        child: Center(
                          child: _error == null
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  spacing: tokens.spacing.gap,
                                  children: <Widget>[
                                    const FushiCircularProgressIndicator(),
                                    Text(t.music_apple_music_login_opening),
                                  ],
                                )
                              : FushiPlaceholderMessage(
                                  icon: FushiIcons.cloudOff,
                                  message: t.music_apple_music_login_failed,
                                  detail: _error,
                                  action: FushiPressScale(
                                    child: FushiFilledButton.icon(
                                      onPressed: () => unawaited(_authorize()),
                                      icon: const FushiIcon(FushiIcons.refresh),
                                      label: Text(t.music_server_retry),
                                    ),
                                  ),
                                ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
