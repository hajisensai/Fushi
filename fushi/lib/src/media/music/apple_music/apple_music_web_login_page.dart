/// Apple ID 登录页（网页桥，Windows / Android）：可见 WebView 加载托管的 MusicKit JS 页并调
/// `authorize()`；MusicKit 用 `window.open` 开的 Apple ID 弹窗接成页内的第二个 WebView
/// （`windowId`，保住 opener 关系，登录结果才能 postMessage 回来）。成功 pop(true)。
///
/// Music-User-Token 由 MusicKit 存进托管页源的 localStorage；隐藏的播放 WebView 与这里同一
/// WebView 数据目录，重建后即读到（[AppleMusicWebBridge.authorize]）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 调 authorize 并回报是否已授权。
const String _kAuthorizeJs = '''
const r = await window.fushiMusicKit.authorize();
return JSON.stringify(r || {ok: false});
''';

class AppleMusicWebLoginPage extends StatefulWidget {
  const AppleMusicWebLoginPage({super.key});

  @override
  State<AppleMusicWebLoginPage> createState() => _AppleMusicWebLoginPageState();
}

class _AppleMusicWebLoginPageState extends State<AppleMusicWebLoginPage> {
  final GlobalKey _bridgeKey = GlobalKey();
  InAppWebViewController? _bridge;

  /// MusicKit 开的 Apple ID 弹窗（onCreateWindow 的 windowId）；null = 没开。
  int? _popupWindowId;

  bool _busy = true;
  String? _error;
  bool _done = false;

  Future<void> _authorize() async {
    final InAppWebViewController? c = _bridge;
    if (c == null || _done) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    bool authorized = false;
    try {
      final CallAsyncJavaScriptResult? r = await c.callAsyncJavaScript(
        functionBody: _kAuthorizeJs,
      );
      final Object? v = r?.value;
      final Object? decoded = v is String ? jsonDecode(v) : v;
      if (r?.error case final String e when e.isNotEmpty) {
        error = e;
      } else if (decoded is Map && decoded['ok'] == true) {
        authorized = decoded['authorized'] == true;
        if (!authorized) error = 'not authorized';
      } else if (decoded is Map && decoded['error'] is Map) {
        final Map<Object?, Object?> e =
            decoded['error'] as Map<Object?, Object?>;
        error = '${e['name'] ?? 'Error'}: ${e['message'] ?? ''}';
      } else {
        error = 'unknown';
      }
    } on Object catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    if (authorized) {
      _done = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _popupWindowId = null;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int? popup = _popupWindowId;
    return FushiPageScaffold(
      title: t.music_apple_music_login_title,
      body: Stack(
        children: <Widget>[
          // 桥页面本身（无可见内容）：撑满但留在弹窗下面。
          Positioned.fill(
            child: InAppWebView(
              key: _bridgeKey,
              initialUrlRequest: URLRequest(
                url: WebUri.uri(kAppleMusicWebBridgePage),
              ),
              initialSettings: appleMusicWebViewSettings(),
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
                  onCloseWindow: (InAppWebViewController _) {
                    if (mounted) setState(() => _popupWindowId = null);
                  },
                ),
              ),
            ),
          if (popup == null && (_busy || _error != null))
            Positioned.fill(
              child: ColoredBox(
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
        ],
      ),
    );
  }
}
