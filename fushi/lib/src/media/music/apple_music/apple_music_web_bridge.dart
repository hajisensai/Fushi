/// Windows / Android 的 Apple Music 桥：隐藏 WebView 加载 Worker 托管的 MusicKit JS 页
/// （`https://rank.fushi.moe/musickit/`，`services/leaderboard/src/musickit_page.js`），整曲 DRM 由
/// WebView 的 CDM（WebView2 / Android WebView 的 Widevine）解，Fushi 不碰音频数据（方案 §3.1 / P3 / P4）。
///
/// - 页面的 `window.fushiMusicKit` 负责 configure / authorize / 播放控制，事件经 JS handler
///   `fushiMusicKit` 回来；「只排不播」与 token / 订阅状态读取直接对 `MusicKit.getInstance()` 求值
///   （宿主注入的脚本不受页面 CSP 约束）。
/// - 登录：`authorize()` 要开 Apple ID 弹窗，隐藏 WebView 里没人看得见，所以由
///   [AppleMusicWebLoginPage] 用一个**可见**的 WebView 加载同一页、把弹窗接成页内 WebView；
///   Music-User-Token 存在该源的 localStorage（同一 WebView 数据目录），登录完重建隐藏 WebView
///   让它读到。
/// - 系统媒体会话由 app 自己的会话负责：页面会清空 `navigator.mediaSession`（§3.4）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_login_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;

/// 托管页。必须是 https：MusicKit JS 的 `authorize()` 不认 file:// / 自定义 scheme。
final Uri kAppleMusicWebBridgePage = Uri.parse(
  'https://rank.fushi.moe/musickit/',
);

/// 托管页所在源（只给这个源授 DRM 权限 / 收它的桥消息）。
const String kAppleMusicWebBridgeOrigin = 'https://rank.fushi.moe';

/// 页面加载 + MusicKit configure 的超时。
const Duration kAppleMusicWebInitTimeout = Duration(seconds: 40);

/// 单次桥调用的超时（setQueue 首次要拉 DRM license，留宽）。
const Duration kAppleMusicWebCallTimeout = Duration(seconds: 30);

/// MusicKit JS `PlaybackStates`（v3）。
abstract final class MusicKitPlaybackState {
  static const int none = 0;
  static const int loading = 1;
  static const int playing = 2;
  static const int paused = 3;
  static const int stopped = 4;
  static const int ended = 5;
  static const int seeking = 6;
  static const int waiting = 8;
  static const int stalled = 9;
  static const int completed = 10;
}

/// 读账号状态：authorized + 订阅（`previewOnly` 为真 = 只能试听）+ 账号 storefront。
const String _kAccountJs = '''
const r = await window.fushiMusicKit.init();
if (!r || r.ok !== true) return JSON.stringify(r || {ok:false});
const m = window.MusicKit.getInstance();
const authorized = !!m.isAuthorized;
return JSON.stringify({
  ok: true,
  status: authorized ? 'authorized' : 'notDetermined',
  canPlayCatalogContent: authorized && m.previewOnly !== true,
  canBecomeSubscriber: authorized && m.previewOnly === true,
  storefront: authorized ? (m.storefrontId || null) : null,
});
''';

/// 资料库 token 对（同页的 developer token + MusicKit 授权得到的用户 token）。
const String _kCredentialsJs = '''
const r = await window.fushiMusicKit.init();
if (!r || r.ok !== true) return JSON.stringify(null);
const m = window.MusicKit.getInstance();
if (!m.isAuthorized || !m.musicUserToken) return JSON.stringify(null);
return JSON.stringify({developerToken: m.developerToken, userToken: m.musicUserToken});
''';

/// 放一首：替换队列；[autoplay] 为假时只排好、定位、不出声。
const String _kPlayJs = '''
const r = await window.fushiMusicKit.init();
if (!r || r.ok !== true) return JSON.stringify(r || {ok:false});
try {
  const m = window.MusicKit.getInstance();
  await m.setQueue({ song: String(songId), startPlaying: false });
  if (startMs > 0) await m.seekToTime(startMs / 1000);
  if (autoplay) await m.play();
  return JSON.stringify({ok: true});
} catch (e) {
  return JSON.stringify({ok: false, error: {name: String((e && (e.name || e.errorCode)) || 'Error'), message: String((e && (e.message || e.description)) || e)}});
}
''';

/// `{ok:false, error:{name,message}}` → 异常文本。
String _errorText(Object? decoded) {
  if (decoded is Map) {
    final Object? e = decoded['error'];
    if (e is Map) {
      final String name = '${e['name'] ?? 'Error'}';
      final String msg = '${e['message'] ?? ''}';
      return msg.isEmpty ? name : '$name: $msg';
    }
  }
  return 'unknown';
}

/// 页面 `fushiMusicKit` 事件 → 播放器事件。返回 null = 不转发（`ready` / 未知类型）。
///
/// [lastState] 是上一次的 MusicKit 播放状态（出声沿判定用）；结束只在进入 ended / completed
/// 那一刻发一次。
({AppleMusicPlayerEvent? event, int? state}) parseAppleMusicWebEvent(
  Object? raw, {
  int? lastState,
}) {
  if (raw is! Map) return (event: null, state: lastState);
  final Object? song = raw['songId'];
  final String? songId = song is String && song.isNotEmpty ? song : null;
  int? ms(Object? v) => v is num ? v.round() : null;
  switch (raw['type']) {
    case 'time':
      final int? pos = ms(raw['positionMs']);
      if (pos == null) return (event: null, state: lastState);
      final int? dur = ms(raw['durationMs']);
      return (
        event: AppleMusicProgress(
          positionMs: pos,
          durationMs: dur != null && dur > 0 ? dur : null,
          songId: songId,
        ),
        state: lastState,
      );
    case 'state':
    case 'item':
      final int? state = ms(raw['state']);
      if (state == null || state == lastState) {
        return (event: null, state: lastState);
      }
      if (state == MusicKitPlaybackState.ended ||
          state == MusicKitPlaybackState.completed) {
        return (event: AppleMusicEnded(songId: songId), state: state);
      }
      final bool wasPlaying = lastState == MusicKitPlaybackState.playing;
      final bool playing = state == MusicKitPlaybackState.playing;
      // loading / seeking / waiting / stalled 是过渡态：不改出声与否的判断。
      final bool settled =
          playing ||
          state == MusicKitPlaybackState.paused ||
          state == MusicKitPlaybackState.stopped ||
          state == MusicKitPlaybackState.none;
      if (!settled || playing == wasPlaying) {
        return (event: null, state: playing || settled ? state : lastState);
      }
      return (
        event: AppleMusicPlayingChanged(playing, songId: songId),
        state: state,
      );
    case 'error':
      final Object? m = raw['message'];
      final Object? n = raw['name'];
      return (
        event: AppleMusicPlaybackError(
          m is String && m.isNotEmpty
              ? (n is String ? '$n: $m' : m)
              : 'unknown',
          songId: songId,
        ),
        state: lastState,
      );
    case 'auth':
      return (
        event: AppleMusicAccountChanged(
          AppleMusicAccountState(
            status: raw['authorized'] == true
                ? AppleMusicAuthStatus.authorized
                : AppleMusicAuthStatus.notDetermined,
            // 订阅情况要另外问（previewOnly）；账号层收到后会重读。
            canPlayCatalogContent: raw['authorized'] == true,
          ),
        ),
        state: lastState,
      );
  }
  return (event: null, state: lastState);
}

/// 隐藏 WebView 的初始设置（登录页的可见 WebView 用同一份，保证同一数据目录、同样的权限）。
InAppWebViewSettings appleMusicWebViewSettings() => InAppWebViewSettings(
  javaScriptEnabled: true,
  // 没有用户手势也要能出声（实测：被拦后 MusicKit 卡在 loading，PR #2725）。Windows fork 已在
  // 环境参数里全局放开（BUG-1091），这里管 Android。
  mediaPlaybackRequiresUserGesture: false,
  // authorize() 用 window.open 开 Apple ID 登录弹窗。
  javaScriptCanOpenWindowsAutomatically: true,
  supportMultipleWindows: true,
  disableContextMenu: true,
  isInspectable: false,
);

/// 只给托管页的源授 EME（Android WebView 的 Widevine 要 `PROTECTED_MEDIA_ID` 权限）。
Future<PermissionResponse> appleMusicPermissionResponse(
  PermissionRequest request,
) async {
  final String origin = request.origin.origin;
  final bool ok =
      origin == kAppleMusicWebBridgeOrigin &&
      request.resources.every(
        (PermissionResourceType r) =>
            r == PermissionResourceType.PROTECTED_MEDIA_ID,
      );
  return PermissionResponse(
    resources: request.resources,
    action: ok ? PermissionResponseAction.GRANT : PermissionResponseAction.DENY,
  );
}

class AppleMusicWebBridge implements AppleMusicBridge {
  AppleMusicWebBridge();

  final StreamController<AppleMusicPlayerEvent> _events =
      StreamController<AppleMusicPlayerEvent>.broadcast();

  HeadlessInAppWebView? _webView;
  Future<InAppWebViewController>? _ready;
  int? _lastState;

  /// 这一代隐藏页里排着一首（play 成功过、之后没 stop）。这一代被拆掉时据此发
  /// [AppleMusicSessionLost]：播放后端才知道那首已经不在了，不会对着新页面发 resume / seek。
  bool _hasQueue = false;

  /// 正在等的桥调用数：调用自己的失败经返回值上报，这期间页面顺带发的 `error` 事件不再重复转发。
  int _calls = 0;
  bool _disposed = false;

  @override
  Stream<AppleMusicPlayerEvent> get events => _events.stream;

  void _emit(AppleMusicPlayerEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _onPageEvent(Object? raw) {
    final ({AppleMusicPlayerEvent? event, int? state}) r =
        parseAppleMusicWebEvent(raw, lastState: _lastState);
    _lastState = r.state;
    final AppleMusicPlayerEvent? e = r.event;
    if (e == null) return;
    if (e is AppleMusicPlaybackError && _calls > 0) return;
    _emit(e);
  }

  Future<InAppWebViewController> _controller() {
    if (_disposed) {
      return Future<InAppWebViewController>.error(
        const AppleMusicBridgeException('disposed'),
      );
    }
    final Future<InAppWebViewController>? current = _ready;
    if (current != null) return current;
    final Future<InAppWebViewController> started = _start();
    _ready = started;
    unawaited(
      started.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_ready, started)) unawaited(_teardown());
        },
      ),
    );
    return started;
  }

  Future<InAppWebViewController> _start() async {
    if (Platform.isWindows) {
      // 窗口挂载前构造 HeadlessInAppWebView 会崩 WebView2（main.dart 预热处同一约束）。
      await WidgetsBinding.instance.endOfFrame;
    }
    final Completer<InAppWebViewController> loaded =
        Completer<InAppWebViewController>();
    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(kAppleMusicWebBridgePage)),
      initialSettings: appleMusicWebViewSettings(),
      onWebViewCreated: (InAppWebViewController c) {
        c.addJavaScriptHandler(
          handlerName: 'fushiMusicKit',
          callback: (List<dynamic> args) {
            _onPageEvent(args.isEmpty ? null : args.first);
            return null;
          },
        );
      },
      onPermissionRequest: (InAppWebViewController _, PermissionRequest r) =>
          appleMusicPermissionResponse(r),
      // 隐藏 WebView 不该开窗（登录走可见的登录页）；拒掉，别让弹窗把桥页面顶掉。返回 false =
      // 不接管（插件丢掉这个窗口请求）；先前写成 true 是「已接管」却没人建窗，请求悬空。
      onCreateWindow: (InAppWebViewController _, CreateWindowAction _) async =>
          false,
      onLoadStop: (InAppWebViewController c, WebUri? url) async {
        if (loaded.isCompleted) return;
        final Object? ok = await c.evaluateJavascript(
          source: 'typeof window.fushiMusicKit === "object"',
        );
        if (ok == true) {
          loaded.complete(c);
        } else {
          loaded.completeError(
            const AppleMusicBridgeException('bridge_page_missing'),
          );
        }
      },
      onReceivedError:
          (
            InAppWebViewController _,
            WebResourceRequest req,
            WebResourceError e,
          ) {
            if (req.isForMainFrame != false && !loaded.isCompleted) {
              loaded.completeError(
                AppleMusicBridgeException('bridge_page_load', e.description),
              );
            }
          },
      onWebContentProcessDidTerminate: (InAppWebViewController _) =>
          unawaited(_teardown(lostReason: 'renderer_gone')),
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail _) =>
              unawaited(_teardown(lostReason: 'renderer_gone')),
    );
    _webView = webView;
    await webView.run();
    return loaded.future.timeout(
      kAppleMusicWebInitTimeout,
      onTimeout: () =>
          throw const AppleMusicBridgeException('bridge_page_timeout'),
    );
  }

  /// 拆掉这一代隐藏页。[lostReason] 非空 = 不是有意停播（renderer 崩溃 / 登录后重建）：这一代
  /// 排着曲目时发 [AppleMusicSessionLost]，让播放后端把当前曲判失败、下次播放重新打开。
  Future<void> _teardown({String? lostReason}) async {
    final HeadlessInAppWebView? w = _webView;
    final bool hadQueue = _hasQueue;
    _webView = null;
    _ready = null;
    _lastState = null;
    _hasQueue = false;
    if (lostReason != null && hadQueue) {
      _emit(AppleMusicSessionLost(lostReason));
    }
    if (w != null) {
      try {
        await w.dispose();
      } on Object {
        // renderer 已死时 dispose 可能抛；这一代反正要丢。
      }
    }
  }

  /// 跑一段 async 函数体（返回 JSON 字符串），解出结果。
  Future<Object?> _run(
    String body, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final InAppWebViewController c = await _controller();
    _calls++;
    try {
      final CallAsyncJavaScriptResult? r = await c
          .callAsyncJavaScript(functionBody: body, arguments: args)
          .timeout(
            kAppleMusicWebCallTimeout,
            onTimeout: () =>
                throw const AppleMusicBridgeException('bridge_call_timeout'),
          );
      if (r == null) throw const AppleMusicBridgeException('bridge_call');
      final String? error = r.error;
      if (error != null && error.isNotEmpty) {
        throw AppleMusicBridgeException('bridge_js', error);
      }
      final Object? v = r.value;
      return v is String ? jsonDecode(v) : v;
    } finally {
      _calls--;
    }
  }

  /// 调 `window.fushiMusicKit.<method>(...args)`，`{ok:false}` 抛。
  Future<Map<Object?, Object?>> _api(
    String method, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final Object? r = await _run(
      'const r = await window.fushiMusicKit[method].apply(null, args);'
      'return JSON.stringify(r === undefined ? null : r);',
      <String, dynamic>{'method': method, 'args': args},
    );
    if (r is Map && r['ok'] == true) return r;
    throw AppleMusicBridgeException(method, _errorText(r));
  }

  @override
  Future<AppleMusicAccountState> accountState() async {
    final Object? r = await _run(_kAccountJs);
    if (r is Map && r['ok'] == true) return AppleMusicAccountState.fromMap(r);
    throw AppleMusicBridgeException('account', _errorText(r));
  }

  @override
  Future<AppleMusicAccountState> authorize(BuildContext context) async {
    final bool? ok = await Navigator.of(context).push<bool>(
      adaptivePageRoute<bool>(
        context: context,
        builder: (BuildContext _) => const AppleMusicWebLoginPage(),
      ),
    );
    // 没登录成功：token 没变，不动正在用的这一代（正在放的曲目照常放）。
    if (ok != true) return accountState();
    // 登录页的 WebView 把 Music-User-Token 写进了同源 localStorage；隐藏 WebView 是在那之前
    // configure 的，重建一代让它读到。这一代若正排着曲目，经 [AppleMusicSessionLost] 通知
    // 播放后端（它把当前曲判失败、下次按播放重新 setQueue），不静默丢掉。
    await _teardown(lostReason: 'reauthorized');
    final AppleMusicAccountState s = await accountState();
    _emit(AppleMusicAccountChanged(s));
    return s;
  }

  @override
  Future<void> unauthorize() async {
    try {
      await _api('unauthorize');
    } finally {
      // 清 token 失败也算断开（账号层已记「未连接」）：播放后端据此停掉当前曲。
      _hasQueue = false;
      _emit(const AppleMusicAccountChanged(AppleMusicAccountState.signedOut));
    }
  }

  @override
  Future<AppleMusicUserCredentials?> userCredentials() async {
    final Object? r = await _run(_kCredentialsJs);
    if (r is! Map) return null;
    final Object? dev = r['developerToken'];
    final Object? user = r['userToken'];
    if (dev is! String || user is! String || dev.isEmpty || user.isEmpty) {
      return null;
    }
    return AppleMusicUserCredentials(developerToken: dev, userToken: user);
  }

  @override
  Future<void> play(
    String songId, {
    int startMs = 0,
    bool autoplay = true,
  }) async {
    _lastState = null;
    final Object? r = await _run(_kPlayJs, <String, dynamic>{
      'songId': songId,
      'startMs': startMs,
      'autoplay': autoplay,
    });
    if (r is! Map || r['ok'] != true) {
      throw AppleMusicBridgeException('play', _errorText(r));
    }
    _hasQueue = true;
  }

  @override
  Future<void> pause() async {
    if (_ready == null) return;
    await _api('pause');
  }

  @override
  Future<void> resume() async => _api('resume');

  @override
  Future<void> stop() async {
    _hasQueue = false;
    if (_ready == null) return;
    await _api('stop');
  }

  @override
  Future<void> seek(int positionMs) async =>
      _api('seek', <Object?>[positionMs]);

  @override
  Future<void> setVolume(double volume) async {
    if (_ready == null) return;
    await _api('setVolume', <Object?>[volume.clamp(0, 1)]);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown();
    await _events.close();
  }
}
