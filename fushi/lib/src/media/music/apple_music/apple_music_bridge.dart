/// Apple Music 授权与播放的平台桥（MusicKit 方案 §3.1）。
///
/// 桥**只管授权（含 Music-User-Token）、订阅状态与播放**；catalog / 资料库浏览由 Dart 直接调
/// `api.music.apple.com`（`fushi_engine/media/music/apple_music/`）。两种实现：
/// - [AppleMusicNativeBridge]：method / event channel → Swift MusicKit（iOS、macOS 14+）；
/// - [AppleMusicWebBridge]：隐藏 WebView 加载 Worker 托管的 MusicKit JS 页（Windows、Android）。
/// Linux 没有能解 DRM 的播放器（WPE 无 Widevine），[createAppleMusicBridge] 回 null，只剩浏览 + 试听。
///
/// 播放一次只给 MusicKit 一首（Fushi 的队列是唯一真相，方案 §3.3）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';

/// 授权状态（与 Swift `MusicAuthorization.Status` 同名；网页桥只有 notDetermined / authorized）。
enum AppleMusicAuthStatus {
  notDetermined('notDetermined'),
  denied('denied'),
  restricted('restricted'),
  authorized('authorized');

  const AppleMusicAuthStatus(this.wire);

  final String wire;

  static AppleMusicAuthStatus fromWire(Object? raw) {
    for (final AppleMusicAuthStatus s in values) {
      if (s.wire == raw) return s;
    }
    return AppleMusicAuthStatus.notDetermined;
  }
}

/// 账号状态快照。
@immutable
class AppleMusicAccountState {
  const AppleMusicAccountState({
    required this.status,
    this.canPlayCatalogContent = false,
    this.canBecomeSubscriber = false,
    this.storefront,
  });

  static const AppleMusicAccountState signedOut = AppleMusicAccountState(
    status: AppleMusicAuthStatus.notDetermined,
  );

  final AppleMusicAuthStatus status;

  /// 订阅有效、能整曲播放 catalog 内容。
  final bool canPlayCatalogContent;

  /// 能开通订阅（未订阅时界面提示用）。
  final bool canBecomeSubscriber;

  /// 账号所在 storefront（两位小写国家码）；未知为 null。
  final String? storefront;

  bool get isAuthorized => status == AppleMusicAuthStatus.authorized;

  /// 能整曲播放：已授权且订阅有效。
  bool get canPlayFullTracks => isAuthorized && canPlayCatalogContent;

  static AppleMusicAccountState fromMap(Map<Object?, Object?> m) {
    final Object? sf = m['storefront'];
    return AppleMusicAccountState(
      status: AppleMusicAuthStatus.fromWire(m['status']),
      canPlayCatalogContent: m['canPlayCatalogContent'] == true,
      canBecomeSubscriber: m['canBecomeSubscriber'] == true,
      storefront: sf is String && RegExp(r'^[a-zA-Z]{2}$').hasMatch(sf)
          ? sf.toLowerCase()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppleMusicAccountState &&
      other.status == status &&
      other.canPlayCatalogContent == canPlayCatalogContent &&
      other.canBecomeSubscriber == canBecomeSubscriber &&
      other.storefront == storefront;

  @override
  int get hashCode => Object.hash(
    status,
    canPlayCatalogContent,
    canBecomeSubscriber,
    storefront,
  );
}

/// 播放器事件（相对当前这首）。
sealed class AppleMusicPlayerEvent {
  const AppleMusicPlayerEvent();
}

/// 进度（原生 ~250 ms 轮询、网页随 `playbackTimeDidChange`）。
final class AppleMusicProgress extends AppleMusicPlayerEvent {
  const AppleMusicProgress({
    required this.positionMs,
    this.durationMs,
    this.songId,
  });

  final int positionMs;
  final int? durationMs;
  final String? songId;
}

/// 出声 / 停住。
final class AppleMusicPlayingChanged extends AppleMusicPlayerEvent {
  const AppleMusicPlayingChanged(this.playing, {this.songId});

  final bool playing;
  final String? songId;
}

/// 这首自然播完。
final class AppleMusicEnded extends AppleMusicPlayerEvent {
  const AppleMusicEnded({this.songId});

  final String? songId;
}

/// 播放出错（取不到曲目 / DRM / 订阅失效 …）。
final class AppleMusicPlaybackError extends AppleMusicPlayerEvent {
  const AppleMusicPlaybackError(this.message, {this.songId});

  final String message;
  final String? songId;
}

/// 桥这一代播放器没了（网页桥的隐藏 WebView renderer 崩溃、登录后重建）：之前排进 MusicKit 的
/// 那首已经不在了，`resume` / `seek` 不会再让它出声。播放后端据此把当前曲判失败、让引擎下次
/// 按播放时重新打开（重新 setQueue），而不是对着一个没 configure 过的新页面发 resume。
final class AppleMusicSessionLost extends AppleMusicPlayerEvent {
  const AppleMusicSessionLost(this.reason);

  /// `renderer_gone` / `reauthorized` 等，只用于日志与提示。
  final String reason;
}

/// 授权 / 订阅状态变了。
final class AppleMusicAccountChanged extends AppleMusicPlayerEvent {
  const AppleMusicAccountChanged(this.state);

  final AppleMusicAccountState state;
}

/// 桥上的调用失败（[AppleMusicBridge.play] 打不开等）。
class AppleMusicBridgeException implements Exception {
  const AppleMusicBridgeException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() =>
      'AppleMusicBridgeException($code${message == null ? '' : ': $message'})';
}

abstract interface class AppleMusicBridge {
  Stream<AppleMusicPlayerEvent> get events;

  /// 读当前授权 / 订阅状态（不弹任何界面）。
  Future<AppleMusicAccountState> accountState();

  /// 请求授权：原生弹系统授权框；网页桥推一个可见的 Apple ID 登录页（所以要 [context]）。
  Future<AppleMusicAccountState> authorize(BuildContext context);

  /// 退出：网页桥清掉 Music-User-Token；原生无法代用户撤销（系统设置里撤），只停止使用。
  Future<void> unauthorize();

  /// 访问资料库的一对 token；未授权回 null。
  Future<AppleMusicUserCredentials?> userCredentials();

  /// 放一首 catalog 曲目（替换掉 MusicKit 里原有的那首）。
  Future<void> play(String songId, {int startMs = 0, bool autoplay = true});

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(int positionMs);

  /// 0–1；原生 `ApplicationMusicPlayer` 没有应用级音量，忽略。
  Future<void> setVolume(double volume);

  Future<void> dispose();
}

/// 本平台的桥；没有能整曲播放的 MusicKit 播放器（Linux、macOS 13）回 null。
AppleMusicBridge? createAppleMusicBridge() {
  if (Platform.isIOS) return AppleMusicNativeBridge();
  if (Platform.isMacOS) {
    return macOSMajorVersion(Platform.operatingSystemVersion) >= 14
        ? AppleMusicNativeBridge()
        : null;
  }
  if (Platform.isWindows || Platform.isAndroid) return AppleMusicWebBridge();
  return null;
}

/// `Platform.operatingSystemVersion`（macOS 形如 `Version 14.5 (Build 23F79)`）的主版本号；
/// 解析不了回 0（按不支持处理）。
int macOSMajorVersion(String raw) {
  final RegExpMatch? m = RegExp(r'(\d+)\.\d+').firstMatch(raw);
  return m == null ? 0 : int.parse(m.group(1)!);
}
