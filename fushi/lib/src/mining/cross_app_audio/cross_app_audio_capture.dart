/// 跨应用语音缓存（拍板 oqk37s3QFL）的 Dart 门面：`app.fushi.reader/cross_app_audio`。
///
/// 原生（Android `CrossAppAudioChannel.java`）在主进程跑 AudioPlaybackCapture 前台服务，
/// 把其他 app 的声音循环写进最近 60 秒的内存环；主引擎和查词窗引擎（`:popup` 进程）
/// 都注册了这条通道，状态与快照经主进程的 provider 跨进程取，所以两边调法一样。
///
/// 不在 Android（或原生缺失）时所有方法收敛成「不可用」：开关不显示、查词不取快照。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// [CrossAppAudioCapture.start] 的结果：是否录起来了 + 没录起来的原因码
/// （`denied` / `unsupported` / `busy` / `start_failed` / `missing_plugin`）。
typedef CrossAppAudioStartResult = ({bool running, String? error});

class CrossAppAudioCapture {
  CrossAppAudioCapture._(this._channel, {required bool platformAvailable})
    : _platformAvailable = platformAvailable;

  /// 测试用：注入通道与平台判定。
  @visibleForTesting
  CrossAppAudioCapture.forTesting(
    MethodChannel channel, {
    bool platformAvailable = true,
  }) : this._(channel, platformAvailable: platformAvailable);

  static const MethodChannel kChannel = MethodChannel(
    'app.fushi.reader/cross_app_audio',
  );

  static final CrossAppAudioCapture instance = CrossAppAudioCapture._(
    kChannel,
    platformAvailable: !kIsWeb && Platform.isAndroid,
  );

  final MethodChannel _channel;
  final bool _platformAvailable;
  bool _handlerInstalled = false;

  /// 主引擎里服务是否在录（设置页开关的值）。原生推 `onState` 时更新。
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  /// 本平台有没有这项能力（只看平台，不看系统版本——那个由 [isSupported] 问原生）。
  bool get platformAvailable => _platformAvailable;

  /// 主引擎启动时调一次：接原生的状态推送，并读一次当前状态（引擎重建而服务还在跑）。
  Future<void> init() async {
    if (!_platformAvailable) return;
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'onState') {
          final Object? args = call.arguments;
          if (args is Map<Object?, Object?>) {
            running.value = args['running'] == true;
            if (!running.value) unawaited(sweepStaleCrossAppAudioDirs());
          }
        }
        return null;
      });
    }
    running.value = await status();
    unawaited(sweepStaleCrossAppAudioDirs());
  }

  /// 系统支不支持（Android 10+）。
  Future<bool> isSupported() async {
    if (!_platformAvailable) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 服务此刻是否在录。
  Future<bool> status() async {
    if (!_platformAvailable) return false;
    try {
      return await _channel.invokeMethod<bool>('status') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('CrossAppAudio.status', error, stack);
      return false;
    }
  }

  /// 弹授权流程（录音权限 + 屏幕共享确认）并开始录；等到真的录起来或被拒才返回。
  /// [labels] 是通知文案（`notification` / `stop`），原生缺省回退英文。
  Future<CrossAppAudioStartResult> start({
    Map<String, String> labels = const <String, String>{},
  }) async {
    if (!_platformAvailable) return (running: false, error: 'unsupported');
    try {
      final Map<Object?, Object?>? r = await _channel
          .invokeMethod<Map<Object?, Object?>>('start', <String, Object?>{
            'labels': labels,
          });
      final bool ok = r?['running'] == true;
      running.value = ok;
      return (
        running: ok,
        error: ok ? null : (r?['error'] as String?) ?? 'start_failed',
      );
    } on MissingPluginException {
      return (running: false, error: 'missing_plugin');
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('CrossAppAudio.start', error, stack);
      return (running: false, error: 'start_failed');
    }
  }

  /// 停止录（没在录时无操作）。
  Future<void> stop() async {
    if (!_platformAvailable) return;
    try {
      await _channel.invokeMethod<void>('stop');
      running.value = false;
    } on MissingPluginException {
      running.value = false;
    }
  }

  /// 查词那一刻：把最近 [backMs] 毫秒的声音落成文件。没在录 / 环里没东西返回 null。
  Future<CrossAppAudioSnapshot?> snapshot({
    int backMs = kCrossAppAudioLookbackMs,
  }) async {
    if (!_platformAvailable) return null;
    try {
      final Object? r = await _channel.invokeMethod<Object>(
        'snapshot',
        <String, Object?>{'backMs': backMs},
      );
      return CrossAppAudioSnapshot.fromNative(r);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('CrossAppAudio.snapshot', error, stack);
      return null;
    }
  }

  /// [CrossAppAudioEncoder] 的 Android 实现：系统 AAC 编码器写 m4a（查词窗进程没有
  /// ffmpeg-kit）。只收 16-bit 整型 PCM（原生采集就是这个格式）。
  Future<bool> encodeAac(GalAudioSlice clip, String outputPath) async {
    if (!_platformAvailable) return false;
    if (clip.format.isFloat || clip.format.bitsPerSample != 16) return false;
    try {
      return await _channel.invokeMethod<bool>('encodeAac', <String, Object?>{
            'pcm': clip.pcm,
            'sampleRate': clip.format.sampleRate,
            'channels': clip.format.channels,
            'outputPath': outputPath,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('CrossAppAudio.encodeAac', error, stack);
      return false;
    }
  }
}
