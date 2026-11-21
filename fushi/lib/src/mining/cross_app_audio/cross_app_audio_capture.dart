/// 跨应用语音缓存（拍板 oqk37s3QFL / design-cross-app-audio-desktop）的 Dart 门面。
///
/// - Android：`app.fushi.reader/cross_app_audio`。原生（`CrossAppAudioChannel.java`）在主进程
///   跑 AudioPlaybackCapture 前台服务，把其他 app 的声音循环写进最近 60 秒的内存环；主引擎
///   和查词窗引擎（`:popup` 进程）都注册了这条通道，状态与快照经主进程的 provider 跨进程
///   取，所以两边调法一样。
/// - Windows：复用 galgame 的 WASAPI 系统混音 loopback（`audio_loopback_capture.cpp`，
///   [LoopbackGalAudioSource]）。本门面持有那一路的一张租约，与 galgame 会话共用同一个环；
///   谁停都只交回自己的租约，不会把对方的环停掉。查词那一刻只在原生内存里钉住最近一段
///   （[CrossAppAudioPinnedSnapshot]），制卡时才落盘，编码走 ffmpeg。
///
/// 其他平台（或原生缺失）时所有方法收敛成「不可用」：开关不显示、查词不取快照。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart'
    show PcmFormat, pcmSliceToAacBytes;
import 'package:fushi/src/mining/galgame_audio_source.dart'
    show GalAudioSlice, LoopbackGalAudioSource;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show immersionMiningAudioExtension;
import 'package:path/path.dart' as p;

/// [CrossAppAudioCapture.start] 的结果：是否录起来了 + 没录起来的原因码
/// （`denied` / `unsupported` / `busy` / `start_failed` / `missing_plugin`）。
typedef CrossAppAudioStartResult = ({bool running, String? error});

class CrossAppAudioCapture {
  CrossAppAudioCapture._(
    this._channel, {
    required bool platformAvailable,
    MethodChannel? desktopLoopbackChannel,
    CrossAppAudioEncoder? desktopEncoder,
  }) : _platformAvailable = platformAvailable,
       _loopbackChannel = desktopLoopbackChannel,
       _desktopEncoder = desktopEncoder;

  /// 测试用：注入通道与平台判定。[desktopLoopbackChannel] 非空 = Windows 形态（走
  /// loopback 通道而不是 [channel]）。
  @visibleForTesting
  CrossAppAudioCapture.forTesting(
    MethodChannel channel, {
    bool platformAvailable = true,
    MethodChannel? desktopLoopbackChannel,
    CrossAppAudioEncoder? desktopEncoder,
  }) : this._(
         channel,
         platformAvailable: platformAvailable,
         desktopLoopbackChannel: desktopLoopbackChannel,
         desktopEncoder: desktopEncoder,
       );

  static const MethodChannel kChannel = MethodChannel(
    'app.fushi.reader/cross_app_audio',
  );

  static final CrossAppAudioCapture _platformInstance = CrossAppAudioCapture._(
    kChannel,
    platformAvailable: !kIsWeb && (Platform.isAndroid || Platform.isWindows),
    desktopLoopbackChannel: !kIsWeb && Platform.isWindows
        ? LoopbackGalAudioSource.kAudioLoopbackChannel
        : null,
  );

  static CrossAppAudioCapture? _debugInstance;

  /// 全进程唯一门面（测试可经 [debugInstance] 换成注入通道 / 编码器的实例）。
  static CrossAppAudioCapture get instance =>
      _debugInstance ?? _platformInstance;

  /// 测试用：让应用外查词制卡链路（[instance] 的消费方）走注入的实例；null 复原。
  @visibleForTesting
  static set debugInstance(CrossAppAudioCapture? value) =>
      _debugInstance = value;

  final MethodChannel _channel;
  final bool _platformAvailable;
  bool _handlerInstalled = false;

  /// Windows：系统混音 loopback 通道（非空即桌面形态）。
  final MethodChannel? _loopbackChannel;
  final CrossAppAudioEncoder? _desktopEncoder;

  /// Windows：本门面持有的那张 loopback 租约（在录时非空）。
  LoopbackGalAudioSource? _loopback;

  /// Windows：起停串行化——设置页连点、启动恢复与用户操作交错时不起两路、不漏停。
  Future<void> _desktopOps = Future<void>.value();

  bool get _desktop => _loopbackChannel != null;

  /// 是不是桌面形态（Windows loopback）：设置页据此换文案、持久化开关。
  bool get isDesktop => _platformAvailable && _desktop;

  /// 主引擎里服务是否在录（设置页开关的值）。原生推 `onState` 时更新。
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  /// 本平台有没有这项能力（只看平台，不看系统版本——那个由 [isSupported] 问原生）。
  bool get platformAvailable => _platformAvailable;

  /// 主引擎启动时调一次：接原生的状态推送，并读一次当前状态（引擎重建而服务还在跑）。
  Future<void> init() async {
    if (!_platformAvailable) return;
    if (_desktop) {
      // 上次制卡中途进程被杀留下的临时目录（Windows 没有原生状态要读回）。
      unawaited(sweepStaleCrossAppAudioDirs());
      return;
    }
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
    if (_desktop) return true;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 服务此刻是否在录。
  Future<bool> status() async {
    if (!_platformAvailable) return false;
    if (_desktop) return _loopback?.holdsLease ?? false;
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
    if (_desktop) return _serialDesktop(_startDesktop);
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
    if (_desktop) return _serialDesktop(_stopDesktop);
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
    if (_desktop) return _snapshotDesktop(backMs);
    try {
      final Object? r = await _channel.invokeMethod<Object>(
        'snapshot',
        <String, Object?>{'backMs': backMs},
      );
      return CrossAppAudioFileSnapshot.fromNative(r);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('CrossAppAudio.snapshot', error, stack);
      return null;
    }
  }

  /// 制卡时把 [snapshot] 截出最后一句、按本平台的编码器写成句子音频（Android 系统 AAC
  /// 编码器写 m4a；Windows 走 ffmpeg，扩展名与其他制卡音频一致）。调用方制卡后删 `dir`。
  Future<({String path, Directory dir})?> prepareSentenceAudio(
    CrossAppAudioSnapshot snapshot,
  ) {
    if (_desktop) {
      return prepareCrossAppSentenceAudio(
        snapshot,
        encode: _desktopEncoder ?? encodeCrossAppAudioWithFfmpeg,
        extension: immersionMiningAudioExtension(),
      );
    }
    return prepareCrossAppSentenceAudio(snapshot, encode: encodeAac);
  }

  Future<T> _serialDesktop<T>(Future<T> Function() op) {
    final Future<T> result = _desktopOps.then((_) => op());
    _desktopOps = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<CrossAppAudioStartResult> _startDesktop() async {
    final LoopbackGalAudioSource? current = _loopback;
    if (current != null && current.holdsLease) {
      return (running: true, error: null);
    }
    final LoopbackGalAudioSource source = LoopbackGalAudioSource(
      channel: _loopbackChannel,
    );
    final PcmFormat? format = await source.start();
    if (format == null) {
      running.value = false;
      return (running: false, error: source.lastStartError ?? 'start_failed');
    }
    _loopback = source;
    running.value = true;
    return (running: true, error: null);
  }

  Future<void> _stopDesktop() async {
    final LoopbackGalAudioSource? source = _loopback;
    _loopback = null;
    running.value = false;
    // 只交回自己的租约：galgame 会话同时在用系统混音时，它的环照常转。
    await source?.stop();
    unawaited(sweepStaleCrossAppAudioDirs());
  }

  /// 采集线程已退出的那一路：用本门面持有的同一个 source 重新 start（native 同来源
  /// 重起、旧租约迁过去，再发一张新租约后交回旧的）。期间被用户关掉 / 换了 source 就
  /// 不动。起不来（此刻没有输出设备）只留痕：租约照旧挂在那一路上，下次查词再发现、
  /// 再起。
  Future<void> _reviveDesktop(LoopbackGalAudioSource source) async {
    if (!identical(_loopback, source) || !source.holdsLease) return;
    final PcmFormat? format = await source.start();
    if (format == null) {
      ErrorLogService.instance.log(
        'CrossAppAudio.reviveDesktop',
        'loopback restart failed: ${source.lastStartError}',
      );
    }
  }

  Future<CrossAppAudioSnapshot?> _snapshotDesktop(int backMs) async {
    final LoopbackGalAudioSource? source = _loopback;
    if (source == null) return null;
    final ({int? id, bool captureStopped}) pinned = await source.pinSnapshot(
      backMs,
    );
    if (pinned.captureStopped) {
      // 常驻录环的采集线程已退出（输出设备被拔掉等）：这次查词没有可信的声音；
      // 对同一来源重新 start 把这一路重起（旧租约在 native 迁到新的一路），之后的
      // 查词照常取得到。
      unawaited(_serialDesktop(() => _reviveDesktop(source)));
    }
    final int? id = pinned.id;
    if (id == null) return null;
    final MethodChannel channel = _loopbackChannel!;
    return CrossAppAudioPinnedSnapshot(
      id: id,
      save: (int snapshotId, String path) =>
          LoopbackGalAudioSource.saveSnapshot(
            snapshotId,
            path,
            channel: channel,
          ),
    );
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

/// [CrossAppAudioEncoder] 的桌面实现：裸 PCM（loopback 混音格式，常见 48k 立体声 float32）
/// 拼 WAV 后交 ffmpeg 转成 [outputPath] 扩展名对应的格式（与 galgame 制卡音频同一条编码
/// 路径 [pcmSliceToAacBytes]）。ffmpeg 不可用 / 转码失败返回 false（这张卡不带句子音频）。
Future<bool> encodeCrossAppAudioWithFfmpeg(
  GalAudioSlice clip,
  String outputPath,
) async {
  final String extension = p.extension(outputPath).replaceFirst('.', '');
  final Uint8List? bytes = await pcmSliceToAacBytes(
    pcm: clip.pcm,
    format: clip.format,
    tempDir: p.dirname(outputPath),
    outputExtension: extension.isEmpty ? 'aac' : extension,
  );
  if (bytes == null || bytes.isEmpty) return false;
  await File(outputPath).writeAsBytes(bytes, flush: true);
  return true;
}
