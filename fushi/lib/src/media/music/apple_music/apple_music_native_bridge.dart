/// Apple 平台的 Apple Music 桥：method / event channel → Swift MusicKit
/// （`fushi/apple/FushiAppleMusic.swift`，iOS 15.1+、macOS 14+）。
///
/// - 授权：`MusicAuthorization.request()` 弹系统框；订阅：`MusicSubscription.current`。
/// - 播放：`ApplicationMusicPlayer`，队列只放一首；进度由原生 ~250 ms 轮询 `playbackTime` 推送。
/// - 资料库 token：`DefaultMusicTokenProvider` 给系统按 App ID 生成的 developer token 与配套的
///   Music-User-Token（不用 Worker 代签的那枚：用户 token 跟签发它的 developer token 绑定）。
/// - 「断开」：系统授权只能在设置里撤，这里只让 app 停止使用（由 [AppleMusicAccount] 记偏好）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';

const String kAppleMusicNativeChannel = 'app.fushi.reader/apple_music';
const String kAppleMusicNativeEventChannel =
    'app.fushi.reader/apple_music/events';

/// 原生事件 map → 播放器事件（原生与测试共用）。不认识的类型回 null。
AppleMusicPlayerEvent? parseAppleMusicNativeEvent(Object? raw) {
  if (raw is! Map) return null;
  final Object? type = raw['type'];
  final Object? song = raw['songId'];
  final String? songId = song is String && song.isNotEmpty ? song : null;
  int? ms(Object? v) => v is num ? v.round() : null;
  switch (type) {
    case 'progress':
      final int? pos = ms(raw['positionMs']);
      if (pos == null) return null;
      final int? dur = ms(raw['durationMs']);
      return AppleMusicProgress(
        positionMs: pos,
        durationMs: dur != null && dur > 0 ? dur : null,
        songId: songId,
      );
    case 'playing':
      return AppleMusicPlayingChanged(raw['playing'] == true, songId: songId);
    case 'ended':
      return AppleMusicEnded(songId: songId);
    case 'error':
      final Object? m = raw['message'];
      return AppleMusicPlaybackError(
        m is String && m.isNotEmpty ? m : 'unknown',
        songId: songId,
      );
    case 'account':
      return AppleMusicAccountChanged(AppleMusicAccountState.fromMap(raw));
  }
  return null;
}

class AppleMusicNativeBridge implements AppleMusicBridge {
  AppleMusicNativeBridge({
    MethodChannel channel = const MethodChannel(kAppleMusicNativeChannel),
    EventChannel eventChannel = const EventChannel(
      kAppleMusicNativeEventChannel,
    ),
  }) : _channel = channel,
       _eventChannel = eventChannel;

  final MethodChannel _channel;
  final EventChannel _eventChannel;

  /// 对外的一条事件流：原生事件 + Dart 侧自己产生的事件（断开时的 [AppleMusicAccountChanged]：
  /// 原生撤不了系统授权、不会推 account 事件，播放后端仍要知道账号已断开）。
  late final StreamController<AppleMusicPlayerEvent> _out =
      StreamController<AppleMusicPlayerEvent>.broadcast(
        onListen: _listenNative,
        onCancel: _cancelNative,
      );
  StreamSubscription<AppleMusicPlayerEvent>? _nativeSub;

  @override
  Stream<AppleMusicPlayerEvent> get events => _out.stream;

  void _listenNative() {
    _nativeSub ??= _eventChannel
        .receiveBroadcastStream()
        .map(parseAppleMusicNativeEvent)
        .where((AppleMusicPlayerEvent? e) => e != null)
        .cast<AppleMusicPlayerEvent>()
        .listen(_out.add, onError: _out.addError);
  }

  Future<void> _cancelNative() async {
    final Future<void>? cancelled = _nativeSub?.cancel();
    _nativeSub = null;
    await cancelled;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw AppleMusicBridgeException(e.code, e.message);
    } on MissingPluginException {
      // macOS 13 / 旧构建：原生侧没注册。
      throw const AppleMusicBridgeException('unsupported');
    }
  }

  @override
  Future<AppleMusicAccountState> accountState() async {
    final Map<Object?, Object?>? m = await _invoke<Map<Object?, Object?>>(
      'accountState',
    );
    return m == null
        ? AppleMusicAccountState.signedOut
        : AppleMusicAccountState.fromMap(m);
  }

  @override
  Future<AppleMusicAccountState> authorize(BuildContext context) async {
    final Map<Object?, Object?>? m = await _invoke<Map<Object?, Object?>>(
      'authorize',
    );
    return m == null
        ? AppleMusicAccountState.signedOut
        : AppleMusicAccountState.fromMap(m);
  }

  /// 原生撤销不了系统授权：停掉播放（「已断开」由账号层的偏好记），并发出已断开，让播放后端
  /// 把当前曲判失败（停不掉也照样发）。
  @override
  Future<void> unauthorize() async {
    try {
      await stop();
    } finally {
      if (!_out.isClosed) {
        _out.add(
          const AppleMusicAccountChanged(AppleMusicAccountState.signedOut),
        );
      }
    }
  }

  @override
  Future<AppleMusicUserCredentials?> userCredentials() async {
    final Map<Object?, Object?>? m = await _invoke<Map<Object?, Object?>>(
      'userCredentials',
    );
    final Object? dev = m?['developerToken'];
    final Object? user = m?['userToken'];
    if (dev is! String || user is! String || dev.isEmpty || user.isEmpty) {
      return null;
    }
    return AppleMusicUserCredentials(developerToken: dev, userToken: user);
  }

  @override
  Future<void> play(String songId, {int startMs = 0, bool autoplay = true}) =>
      _invoke<void>('play', <String, Object?>{
        'songId': songId,
        'startMs': startMs,
        'autoplay': autoplay,
      });

  @override
  Future<void> pause() => _invoke<void>('pause');

  @override
  Future<void> resume() => _invoke<void>('resume');

  @override
  Future<void> stop() => _invoke<void>('stop');

  @override
  Future<void> seek(int positionMs) =>
      _invoke<void>('seek', <String, Object?>{'positionMs': positionMs});

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    await _cancelNative();
    await _out.close();
  }
}
