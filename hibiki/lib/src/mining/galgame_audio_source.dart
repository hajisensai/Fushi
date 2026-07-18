import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// 从 injector 子进程 stdout 解析 `OK hooked pid=<N> ...` 里的游戏子进程 PID（launch 模式）。
/// 纯函数，可单测。未匹配 / 无效返回 null。
int? parseInjectorHookedPid(String stdout) {
  final RegExpMatch? m = RegExp(r'OK hooked pid=(\d+)').firstMatch(stdout);
  if (m == null) {
    return null;
  }
  final int? pid = int.tryParse(m.group(1)!);
  return (pid != null && pid > 0) ? pid : null;
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
///
/// **两种模式**（二选一）：
///   - **attach**（给 [targetPid]）：附着**已运行**的游戏进程（`injector --pid`）。适合已在跑、
///     且引擎在注入时刻**之后**才建音频对象的场景。
///   - **launch**（给 [launchExe]）：由 Hibiki **拉起游戏** exe（`injector --launch <exe>`，
///     CREATE_SUSPENDED 早注入），在游戏 WinMain 前把 hook 装好——**KiriKiriZ 等「启动即建
///     DirectSound 设备」的引擎必须走这条**（attach 会漏掉启动时创建的设备）。子进程 PID 由
///     injector stdout 的 `OK hooked pid=<N>` 回报（[parseInjectorHookedPid] 解析）。
class EngineHookGalAudioSource implements GalAudioSource {
  EngineHookGalAudioSource({
    this.targetPid = 0,
    this.launchExe,
    required this.injectorPath,
    MethodChannel? channel,
    Duration readyTimeout = const Duration(seconds: 12),
    Duration pollInterval = const Duration(milliseconds: 200),
  })  : _channel =
            channel ?? const MethodChannel('app.hibiki.reader/voice_hook'),
        _readyTimeout = readyTimeout,
        _pollInterval = pollInterval;

  /// **attach 模式**目标游戏进程 PID（注入对象）。仅 [launchExe] 为空时用；<=0 且无
  /// [launchExe] 视为无目标 -> 源不可用。
  final int targetPid;

  /// **launch 模式**要拉起的游戏 exe 绝对路径。非空即走 `injector --launch`，从 injector
  /// stdout 解析子进程 PID。null -> 走 attach（[targetPid]）。
  final String? launchExe;

  /// injector 可执行文件绝对路径（随 app 分发 / 按需下载）；null 或文件不存在 -> 源不可用
  /// （降级回 loopback，绝不假装注入成功）。**位数必须匹配目标游戏**（KiriKiriZ 多 32 位 -> x86）。
  final String? injectorPath;

  final MethodChannel _channel;
  final Duration _readyTimeout;
  final Duration _pollInterval;

  /// 拉起的 injector 子进程句柄（[stop] 时杀掉）。
  Process? _injector;

  /// 实际注入命中的游戏 PID：attach=`targetPid`；launch=从 injector stdout 解析出的子进程 PID。
  /// [grabRecent]/`open` 都用它开共享内存。
  int _effectivePid = 0;

  /// 注入命中的游戏进程 PID（[start] 成功后有效）；未就绪返回 null。launch 模式下调用方据此
  /// 找游戏主窗口（截图用），因为拉起游戏的是本源、PID 只有它知道。
  int? get gamePid => _effectivePid > 0 ? _effectivePid : null;

  /// 查目标进程 [pid] 是否 32 位（WOW64）。hibiki.exe 是 64 位，故 native `IsWow64Process`
  /// 为 true 即目标为 32 位（多数 KiriKiri galgame），调用方据此选 x86 注入器（DLL 位数必须
  /// 匹配目标进程，否则注入失败）。native 缺失 / 查询失败 / pid<=0 返回 null（调用方降级）。
  static Future<bool?> targetIsWow64(int pid, {MethodChannel? channel}) async {
    if (pid <= 0) {
      return null;
    }
    final MethodChannel ch =
        channel ?? const MethodChannel('app.hibiki.reader/voice_hook');
    try {
      final Map<Object?, Object?>? r =
          await ch.invokeMethod<Map<Object?, Object?>>(
        'processIsWow64',
        <String, Object?>{'pid': pid},
      );
      if (r == null || r['error'] != null) {
        return null;
      }
      final Object? v = r['isWow64'];
      return v is bool ? v : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 读 PE 头判断 exe 是否 32 位（launch 模式选 x86/x64 注入器用——待启动的游戏还没进程，只能
  /// 从文件的 COFF `Machine` 字段判：`0x014c`=x86(32 位,返 true)、`0x8664`=x64(返 false)。
  /// 文件不存在 / 头损坏 / 非 PE / 未知 machine 返回 null（调用方降级）。
  static Future<bool?> exeIs32Bit(String path) async {
    RandomAccessFile? raf;
    try {
      final File f = File(path);
      if (!await f.exists()) {
        return null;
      }
      raf = await f.open();
      // DOS 头：偏移 0x3c 处 4 字节小端 = PE 头（IMAGE_NT_HEADERS）偏移。
      await raf.setPosition(0x3c);
      final Uint8List lfa = await raf.read(4);
      if (lfa.length < 4) {
        return null;
      }
      final int peOff = lfa.buffer.asByteData().getUint32(0, Endian.little);
      // PE 头：'PE\0\0'(4) + COFF Machine(2, 小端)。
      await raf.setPosition(peOff);
      final Uint8List head = await raf.read(6);
      if (head.length < 6 ||
          head[0] != 0x50 || // 'P'
          head[1] != 0x45 || // 'E'
          head[2] != 0 ||
          head[3] != 0) {
        return null;
      }
      final int machine = head.buffer.asByteData().getUint16(4, Endian.little);
      if (machine == 0x014c) {
        return true; // IMAGE_FILE_MACHINE_I386
      }
      if (machine == 0x8664) {
        return false; // IMAGE_FILE_MACHINE_AMD64
      }
      return null; // 其它（ARM64 等）暂不支持
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<PcmFormat?> start() async {
    final String? path = injectorPath;
    if (path == null || !File(path).existsSync()) {
      return null; // 无 injector -> 降级
    }
    final String? exe = launchExe;
    final bool launchMode = exe != null && exe.isNotEmpty;
    if (!launchMode && targetPid <= 0) {
      return null; // 既无 launchExe 又无有效 targetPid -> 无目标
    }
    // 1. 拉起 injector 子进程（注入报毒代码只在这个隔离子进程里执行）。
    //    launch 模式：`--launch <exe>` CREATE_SUSPENDED 早注入，从 stdout 解析子进程 PID；
    //    attach 模式：`--pid <PID>` 附着已运行进程。
    try {
      _injector = await Process.start(
        path,
        launchMode
            ? <String>['--launch', exe, '--hold']
            : <String>['--pid', '$targetPid', '--hold'],
      );
    } on ProcessException {
      return null;
    }
    if (launchMode) {
      // 等 injector 打印 `OK hooked pid=<子进程>`（注入成功 proof-of-life）解析出游戏 PID。
      final int? childPid = await _awaitLaunchedPid();
      if (childPid == null || childPid <= 0) {
        await stop();
        return null; // 启动/注入失败（exe 起不来 / 位数不符 / 超时）
      }
      _effectivePid = childPid;
    } else {
      _effectivePid = targetPid;
    }
    // 2. open 共享内存（injector 已创建），成功后轮询 status 等 hook DLL 注入 + 拿到语音格式。
    try {
      final Map<Object?, Object?>? opened =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'open',
        <String, Object?>{'pid': _effectivePid},
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

  /// launch 模式：读 injector 子进程 stdout，等到 `OK hooked pid=<N>` 解析出游戏子进程 PID。
  /// [_readyTimeout] 内没等到（exe 起不来 / 注入失败 / injector 提前退出）返回 null。
  Future<int?> _awaitLaunchedPid() async {
    final Process? proc = _injector;
    if (proc == null) {
      return null;
    }
    final Completer<int?> completer = Completer<int?>();
    final StringBuffer buf = StringBuffer();
    late final StreamSubscription<String> sub;
    sub = proc.stdout.transform(const SystemEncoding().decoder).listen(
      (String chunk) {
        buf.write(chunk);
        final int? pid = parseInjectorHookedPid(buf.toString());
        if (pid != null && !completer.isCompleted) {
          completer.complete(pid);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(parseInjectorHookedPid(buf.toString()));
        }
      },
      onError: (Object _) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
    );
    final int? pid =
        await completer.future.timeout(_readyTimeout, onTimeout: () => null);
    await sub.cancel();
    return pid;
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
