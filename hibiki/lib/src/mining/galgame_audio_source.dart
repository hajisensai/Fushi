import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart' show PcmFormat;

/// galgame 一键制卡（docs/specs/galgame-mining）的音频来源抽象。
///
/// 只暴露一个能力：**开一路采集 → 需要时取「最近 N 毫秒」的 PCM**。波形选区对话框、VAD、
/// 制卡出口都只认这个抽象，不关心音频哪来的——A 阶段是 WASAPI loopback 混音
/// （[LoopbackGalAudioSource]），C 阶段换成引擎级 voice hook 的干净语音轨（同一接口，
/// 换一个实现，不动上层）。
abstract interface class GalAudioSource {
  /// 开始采集到环形缓冲。成功返回 PCM 格式（采样率/声道/位深），失败（native 缺失 /
  /// 无采集设备）返回 null（fail-open，调用方降级提示，不崩）。
  Future<PcmFormat?> start();

  /// 停止采集并释放环形缓冲。
  Future<void> stop();

  /// 取「当前时刻往前 [backMs] 毫秒」的 PCM 切片。缓冲不足 [backMs] 时返回现有全部；
  /// native 缺失 / 未 start / 无数据返回 null。
  Future<GalAudioSlice?> grabRecent(int backMs);
}

/// 一段裸 PCM 切片 + 它的格式。
class GalAudioSlice {
  const GalAudioSlice({required this.pcm, required this.format});

  final Uint8List pcm;
  final PcmFormat format;

  bool get isEmpty => pcm.isEmpty;
}

/// A 阶段实现：WASAPI loopback 抓系统混音（含 BGM/SE/语音，混音后）。环形缓冲在 native
/// 侧（内存有界、不持续 IPC），Dart 只在热键那一刻按 [backMs] 拉最近一段。
///
/// native 侧（`hibiki/windows/runner/audio_loopback_capture.cpp`）注册 `audio_loopback`
/// MethodChannel，方法：
///   - `start` -> `Map`：`{sampleRate, channels, bitsPerSample, isFloat}` 或 `{error}`。
///   - `stop` -> void。
///   - `grabRecent` `{backMs}` -> `Map`：`{pcm:Uint8List, sampleRate, channels,
///     bitsPerSample, isFloat}` 或 `{error}`。
///
/// native 缺失（未构建 / 非 Windows）时所有方法以 [MissingPluginException] /
/// [PlatformException] 收敛为 null（调用方降级）。
class LoopbackGalAudioSource implements GalAudioSource {
  LoopbackGalAudioSource({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('app.hibiki.reader/audio_loopback');

  final MethodChannel _channel;

  @override
  Future<PcmFormat?> start() async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>('start');
      if (r == null || r['error'] != null) {
        return null;
      }
      return _parseFormat(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // 停不掉不该崩上层（native 会在进程退出兜底释放）。
    } on MissingPluginException {
      // native 缺失：本就没开，无操作。
    }
  }

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    if (backMs <= 0) {
      return null;
    }
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabRecent',
        <String, Object?>{'backMs': backMs},
      );
      if (r == null || r['error'] != null) {
        return null;
      }
      final Uint8List? pcm = r['pcm'] as Uint8List?;
      final PcmFormat? fmt = _parseFormat(r);
      if (pcm == null || pcm.isEmpty || fmt == null) {
        return null;
      }
      return GalAudioSlice(pcm: pcm, format: fmt);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 从 native map 解析 [PcmFormat]；缺任一必需字段返回 null。
  static PcmFormat? _parseFormat(Map<Object?, Object?> m) =>
      parseGalPcmFormat(m);
}

/// 从 native map（`{sampleRate,channels,bitsPerSample,isFloat}`）解析 [PcmFormat]；缺任一
/// 必需字段 / 非正值返回 null（loopback 与引擎-hook 两个源共用同一格式契约）。
PcmFormat? parseGalPcmFormat(Map<Object?, Object?> m) {
  final Object? sampleRate = m['sampleRate'];
  final Object? channels = m['channels'];
  final Object? bitsPerSample = m['bitsPerSample'];
  if (sampleRate is! int ||
      channels is! int ||
      bitsPerSample is! int ||
      sampleRate <= 0 ||
      channels <= 0 ||
      bitsPerSample <= 0) {
    return null;
  }
  return PcmFormat(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
    isFloat: m['isFloat'] == true,
  );
}

/// C 阶段实现：引擎级 voice hook 的**干净语音**源（混音前抓，无 BGM/SE）。
///
/// 隔离红线（docs/specs/galgame-mining）：注入进游戏、装 XAudio2/DirectSound hook 的代码在
/// **独立 helper 组件** `hibiki_voice_injector.exe` + `hibiki_voice_hook.dll`（注入必被杀软启发式
/// 报毒，绝不进 hibiki.exe）。本实现只做两件被视为无害的事：
///   ① 把 injector **当子进程拉起**（`--pid <PID> --hold`）——注入那步的报毒代码只待在子进程；
///   ② 经 `app.hibiki.reader/voice_hook` MethodChannel 让 hibiki.exe 自己的 native **读**注入
///      组件建好的共享内存（读共享内存不是注入、不被杀软标记，见 voice_hook_reader.cpp）。
/// 和 [LoopbackGalAudioSource] **同接口**——波形选区/制卡出口零改动；不可用（无 injector /
/// 未注入 / 无该引擎 / 超时）时 [start] 返回 null，调用方自动回退 loopback（Never break）。
class EngineHookGalAudioSource implements GalAudioSource {
  EngineHookGalAudioSource({
    required this.targetPid,
    required this.injectorPath,
    MethodChannel? channel,
    Duration readyTimeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 200),
  })  : _channel =
            channel ?? const MethodChannel('app.hibiki.reader/voice_hook'),
        _readyTimeout = readyTimeout,
        _pollInterval = pollInterval;

  /// 目标游戏进程 PID（注入对象）。<=0 视为无目标 -> 源不可用。
  final int targetPid;

  /// injector 可执行文件绝对路径（随 app 分发 / 按需下载）；null 或文件不存在 -> 源不可用
  /// （降级回 loopback，绝不假装注入成功）。
  final String? injectorPath;

  final MethodChannel _channel;
  final Duration _readyTimeout;
  final Duration _pollInterval;

  /// 拉起的 injector 子进程句柄（[stop] 时杀掉）。
  Process? _injector;

  @override
  Future<PcmFormat?> start() async {
    final String? path = injectorPath;
    if (targetPid <= 0 || path == null || !File(path).existsSync()) {
      return null; // 无 injector / 无目标 -> 降级
    }
    // 1. 拉起 injector 子进程（注入报毒代码只在这个隔离子进程里执行）。
    try {
      _injector = await Process.start(
        path,
        <String>['--pid', '$targetPid', '--hold'],
      );
    } on ProcessException {
      return null;
    }
    // 2. open 共享内存（injector 已创建），成功后轮询 status 等 hook DLL 注入 + 拿到语音格式。
    try {
      final Map<Object?, Object?>? opened =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'open',
        <String, Object?>{'pid': targetPid},
      );
      if (opened == null || opened['error'] != null) {
        await stop();
        return null;
      }
    } on PlatformException {
      await stop();
      return null;
    } on MissingPluginException {
      await stop();
      return null;
    }
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < _readyTimeout) {
      final PcmFormat? fmt = await _pollFormat();
      if (fmt != null) {
        return fmt;
      }
      await Future<void>.delayed(_pollInterval);
    }
    // 超时未就绪（未注入成功 / 该引擎无捕获）：降级。
    await stop();
    return null;
  }

  /// 轮询 native `status`：hook 就绪（ready）且格式有效时返回 [PcmFormat]，否则 null。
  Future<PcmFormat?> _pollFormat() async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>('status');
      if (r == null || r['ready'] != true) {
        return null;
      }
      return parseGalPcmFormat(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    if (backMs <= 0) {
      return null;
    }
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabRecent',
        <String, Object?>{'backMs': backMs},
      );
      if (r == null || r['error'] != null) {
        return null;
      }
      final Uint8List? pcm = r['pcm'] as Uint8List?;
      final PcmFormat? fmt = parseGalPcmFormat(r);
      if (pcm == null || pcm.isEmpty || fmt == null) {
        return null;
      }
      return GalAudioSlice(pcm: pcm, format: fmt);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // 关不掉不该崩上层。
    } on MissingPluginException {
      // native 缺失：本就没开。
    }
    _injector?.kill();
    _injector = null;
  }
}
