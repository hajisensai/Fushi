/// Apple Music 账号（MusicKit 方案 §4）：本机桥 + 「在 Fushi 里已连接」偏好 + 授权 / 订阅快照。
///
/// - [canPlayFullTracks]：本平台有 MusicKit 播放器、用户在 Fushi 里连接过、授权有效、订阅有效。
///   catalog 来源据此切整曲 / 试听，资料库来源据此出现。
/// - 「已连接」单独记偏好：Apple 原生的系统授权 app 撤不掉（只能去系统设置），断开只是 Fushi
///   不再用它；网页桥断开时同时清掉 Music-User-Token。
/// - 状态读一次缓存 [kAppleMusicAccountStateTtl]：网页桥读状态要起隐藏 WebView，不能每进一次
///   服务器页都读。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';

/// 账号状态缓存多久。
const Duration kAppleMusicAccountStateTtl = Duration(minutes: 5);

/// 资料库 token 拿不到（未授权 / 已失效）。
class AppleMusicNotSignedInException implements Exception {
  const AppleMusicNotSignedInException();

  @override
  String toString() => 'AppleMusicNotSignedInException';
}

class AppleMusicAccount extends ChangeNotifier {
  AppleMusicAccount({
    required AppleMusicBridge? Function() bridge,
    required bool Function() connected,
    required Future<void> Function(bool) setConnected,
    DateTime Function()? now,
  }) : _bridgeFactory = bridge,
       _connected = connected,
       _setConnected = setConnected,
       _now = now ?? DateTime.now;

  final AppleMusicBridge? Function() _bridgeFactory;
  final bool Function() _connected;
  final Future<void> Function(bool) _setConnected;
  final DateTime Function() _now;

  AppleMusicBridge? _bridge;
  bool _bridgeMade = false;
  StreamSubscription<AppleMusicPlayerEvent>? _sub;

  AppleMusicAccountState _state = AppleMusicAccountState.signedOut;
  DateTime? _stateAt;
  Future<AppleMusicAccountState>? _refreshing;
  Object? _lastError;

  /// 本平台的桥（懒建，整个进程一份：播放后端与设置页共用）。没有就是 null。
  AppleMusicBridge? get bridge {
    if (!_bridgeMade) {
      _bridgeMade = true;
      _bridge = _bridgeFactory();
      _sub = _bridge?.events.listen((AppleMusicPlayerEvent e) {
        if (e is AppleMusicAccountChanged) {
          // 网页桥的 auth 事件不带订阅情况：作废缓存，下次读时重读。
          _stateAt = null;
          if (!e.state.isAuthorized) _set(e.state);
        }
      });
    }
    return _bridge;
  }

  /// 本平台能不能整曲播放（与登录无关）。
  bool get platformSupported => bridge != null;

  /// 用户在 Fushi 里连接过（且没断开）。
  bool get connected => _connected();

  AppleMusicAccountState get state => _state;

  /// 最近一次读状态的错误（桥起不来 / 托管页打不开）；成功读到即清空。
  Object? get lastError => _lastError;

  bool get canPlayFullTracks =>
      platformSupported && connected && _state.canPlayFullTracks;

  void _set(AppleMusicAccountState s) {
    _stateAt = _now();
    if (s == _state) return;
    _state = s;
    notifyListeners();
  }

  /// 读授权 / 订阅状态；[force] 为假时缓存未过期直接给。没连接 / 不支持时不碰桥。
  Future<AppleMusicAccountState> refresh({bool force = false}) {
    final AppleMusicBridge? b = bridge;
    if (b == null || !connected) {
      return Future<AppleMusicAccountState>.value(_state);
    }
    final DateTime? at = _stateAt;
    if (!force &&
        at != null &&
        _now().difference(at) < kAppleMusicAccountStateTtl) {
      return Future<AppleMusicAccountState>.value(_state);
    }
    return _refreshing ??= () async {
      try {
        final AppleMusicAccountState s = await b.accountState();
        _lastError = null;
        _set(s);
        return s;
      } on Object catch (e) {
        _lastError = e;
        notifyListeners();
        return _state;
      } finally {
        _refreshing = null;
      }
    }();
  }

  /// 连接：请求授权（原生弹系统框 / 网页推登录页），成功即记「已连接」。
  Future<AppleMusicAccountState> connect(BuildContext context) async {
    final AppleMusicBridge? b = bridge;
    if (b == null) return _state;
    try {
      final AppleMusicAccountState s = await b.authorize(context);
      _lastError = null;
      if (s.isAuthorized) await _setConnected(true);
      _set(s);
      return s;
    } on Object catch (e) {
      _lastError = e;
      notifyListeners();
      rethrow;
    }
  }

  /// 断开：停播、记「未连接」；网页桥同时清掉用户 token。
  Future<void> disconnect() async {
    await _setConnected(false);
    final AppleMusicBridge? b = bridge;
    if (b != null) {
      try {
        await b.unauthorize();
      } on Object catch (e) {
        _lastError = e;
      }
    }
    _set(AppleMusicAccountState.signedOut);
    notifyListeners();
  }

  /// 资料库请求用的 token 对。
  Future<AppleMusicUserCredentials> userCredentials() async {
    final AppleMusicBridge? b = bridge;
    if (b == null || !connected) throw const AppleMusicNotSignedInException();
    final AppleMusicUserCredentials? c = await b.userCredentials();
    if (c == null) throw const AppleMusicNotSignedInException();
    return c;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_bridge?.dispose());
    super.dispose();
  }
}
