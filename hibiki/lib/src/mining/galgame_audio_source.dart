import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart'
    show PcmFormat, transcodeVoiceOggToMiningAudio;

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

/// 引擎 hook 的就绪 map 转格式。常规路径返回共享内存 PCM 格式；Siglus 的晚附着路径只
/// 导出原始 OVK Ogg、没有已错过的 DirectSound PCM，此时用其已验证的解码格式作为会话
/// 能力标记，让上层保留 [EngineHookGalAudioSource] 并走 [grabPairedVoiceBytes]。
PcmFormat? parseEngineHookReadyFormat(Map<Object?, Object?> m) {
  if (m['ready'] != true) {
    return null;
  }
  final PcmFormat? pcm = parseGalPcmFormat(m);
  if (pcm != null) {
    return pcm;
  }
  if (m['rawVoiceReady'] == true) {
    return const PcmFormat(
      sampleRate: 44100,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    );
  }
  return null;
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

/// galgame 纯人声配对（真机验证，docs/specs/galgame-mining）：注入 hook DLL 把每句原始语音
/// OGG dump 到 `%TEMP%\hibiki_gal_voice\<tickMs>_<basename>.ogg`（tickMs=GetTickCount64，与
/// 文本环 `TextSlot.timestamp_ms` 同源）。实测语音**先**开流、文本约 220ms **后**才显示，故某
/// 条文本行（时间戳 [textTsMs]）对应的语音 = 文件名 tick 落在 `[textTsMs-windowHighMs,
/// textTsMs-windowLowMs]` 内、离期望偏移（`textTsMs-expectedOffsetMs`，窗口中心附近）最近的
/// 那个 OGG。BGM/SE/系统音（basename 以 bgm/se/sys/amb/env/title/logo/movie/jingle 起头）排除
/// ——语音是角色名（yui/osy/aka/hea…）。
///
/// 纯函数（只吃文件名列表 [oggFileNames]，不碰文件系统），可单测。无匹配返回 null。
String? pickPairedVoiceOgg({
  required List<String> oggFileNames,
  required int textTsMs,
  int windowLowMs = 130,
  int windowHighMs = 330,
  int expectedOffsetMs = 220,
}) {
  final int lo = textTsMs - windowHighMs;
  final int hi = textTsMs - windowLowMs;
  final int target = textTsMs - expectedOffsetMs;
  String? best;
  int bestDist = 1 << 62;
  for (final String name in oggFileNames) {
    final _ParsedVoiceOgg? parsed = _parseVoiceOggName(name);
    if (parsed == null) {
      continue;
    }
    if (_isNonVoiceBasename(parsed.basename)) {
      continue;
    }
    final int tick = parsed.tick;
    if (tick < lo || tick > hi) {
      continue;
    }
    final int dist = (tick - target).abs();
    if (dist < bestDist) {
      bestDist = dist;
      best = name;
    }
  }
  return best;
}

/// [pickPairedVoiceOgg] 解析出的一条 dump 文件名：`<tick>_<basename>` 的 tick（GetTickCount64）
/// 与 basename（`<tick>_` 之后的部分，含扩展名）。
class _ParsedVoiceOgg {
  const _ParsedVoiceOgg({required this.tick, required this.basename});
  final int tick;
  final String basename;
}

/// 解析 `<tick>_<basename>` 文件名。tick 必须是纯数字前缀、`_` 分隔；解析失败返回 null。
_ParsedVoiceOgg? _parseVoiceOggName(String fileName) {
  final int underscore = fileName.indexOf('_');
  if (underscore <= 0) {
    return null;
  }
  final int? tick = int.tryParse(fileName.substring(0, underscore));
  if (tick == null) {
    return null;
  }
  final String basename = fileName.substring(underscore + 1);
  if (basename.isEmpty) {
    return null;
  }
  return _ParsedVoiceOgg(tick: tick, basename: basename);
}

/// BGM / 音效 / 系统音的 basename 前缀（不区分大小写）——这些不是角色语音，配对时排除。
final RegExp _nonVoiceBasenamePattern = RegExp(
  r'^(bgm|se|sys|amb|env|title|logo|movie|jingle)',
  caseSensitive: false,
);

/// basename（去掉 `<tick>_` 前缀后）是否 BGM/SE/系统音（要排除）。
bool _isNonVoiceBasename(String basename) =>
    _nonVoiceBasenamePattern.hasMatch(basename);

/// Unity/Mono/IL2CPP 游戏的文本通常不走 GDI 渲染，LunaHook 的通用 PC hooks 需要显式补装。
/// 先覆盖已验证需要的 `manosaba.exe`，再用 Unity 目录布局兜住同类目标。
bool shouldUseLunaPcHooksForExecutable(String executablePath) {
  final String basename = EngineHookGalAudioSource._fileBaseName(
    executablePath,
  );
  final String lowerBasename = basename.toLowerCase();
  if (lowerBasename == 'manosaba.exe') {
    return true;
  }

  final Directory directory = File(executablePath).parent;
  final String separator = Platform.pathSeparator;
  final bool hasUnityPlayer =
      File('${directory.path}${separator}UnityPlayer.dll').existsSync();
  if (!hasUnityPlayer) {
    return false;
  }

  final String stem = lowerBasename.endsWith('.exe')
      ? basename.substring(0, basename.length - 4)
      : basename;
  final String dataPath = '${directory.path}${separator}${stem}_Data';
  final bool il2cpp =
      File('${directory.path}${separator}GameAssembly.dll').existsSync() ||
          File('$dataPath${separator}il2cpp_data${separator}Metadata'
                  '${separator}global-metadata.dat')
              .existsSync();
  final bool mono = Directory('$dataPath${separator}Managed').existsSync() ||
      Directory('$dataPath${separator}MonoBleedingEdge').existsSync() ||
      File('${directory.path}${separator}mono-2.0-bdwgc.dll').existsSync();
  return il2cpp || mono;
}

/// 构造 voice injector 命令行参数。保持 `--hold` 默认开启，让共享内存与 LunaHost
/// 在游戏会话期间存活。
List<String> buildEngineHookInjectorArguments({
  required int targetPid,
  required String? launchExe,
  bool lunaPcHooks = false,
  int? lunaCodepage,
}) {
  final String? exe = launchExe;
  final bool launchMode = exe != null && exe.isNotEmpty;
  final List<String> args = launchMode
      ? <String>['--launch', exe, '--hold']
      : <String>['--pid', '$targetPid', '--hold'];
  if (lunaPcHooks) {
    args.add('--luna-pchooks');
  }
  if (lunaCodepage != null && lunaCodepage > 0) {
    args.addAll(<String>['--luna-codepage', '$lunaCodepage']);
  }
  return args;
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
///   - **launch**（给 [launchExe]）：由 Hibiki **拉起游戏** exe（`injector --launch <exe>`）。
///     通常 CREATE_SUSPENDED 早注入，在游戏 WinMain 前把 hook 装好——**KiriKiriZ 等「启动即建
///     DirectSound 设备」的引擎必须走这条**（attach 会漏掉启动时创建的设备）。子进程 PID 由
///     injector stdout 的 `OK hooked pid=<N>` 回报（[parseInjectorHookedPid] 解析）。Siglus 的
///     Enigma 保护壳例外：injector 会先正常启动、等游戏窗口出现后再附着，捕获后续 OVK 原始语音。
class EngineHookGalAudioSource implements GalAudioSource {
  EngineHookGalAudioSource({
    this.targetPid = 0,
    this.launchExe,
    required this.injectorPath,
    this.lunaPcHooks = false,
    this.lunaCodepage,
    MethodChannel? channel,
    Duration readyTimeout = const Duration(seconds: 30),
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

  /// 是否让 LunaHook 连接后额外插入通用 PC hooks。Unity/Mono/IL2CPP 这类自绘文本路径需要它，
  /// 经典 GDI/KiriKiri/Siglus 默认关闭以减少重复线程。
  final bool lunaPcHooks;

  /// LunaHook 默认文本代码页。null 时沿用 injector 默认值（日文 Shift-JIS/932）。
  final int? lunaCodepage;

  final MethodChannel _channel;
  final Duration _readyTimeout;
  final Duration _pollInterval;

  /// 拉起的 injector 子进程句柄（[stop] 时杀掉）。
  Process? _injector;

  /// 实际注入命中的游戏 PID：attach=`targetPid`；launch=从 injector stdout 解析出的子进程 PID。
  /// [grabRecent]/`open` 都用它开共享内存。
  int _effectivePid = 0;

  /// 本次 injector 会话起点。Siglus 晚附着可能抓不到文本时间戳，制卡时只允许用本会话之后
  /// 新落盘的最新 Ogg，避免误配上一局残留。
  DateTime? _sessionStartedAt;

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
    _sessionStartedAt = DateTime.now();
    // 1. 拉起 injector 子进程（注入报毒代码只在这个隔离子进程里执行）。
    //    launch 模式：`--launch <exe>` CREATE_SUSPENDED 早注入，从 stdout 解析子进程 PID；
    //    attach 模式：`--pid <PID>` 附着已运行进程。
    try {
      _injector = await Process.start(
        path,
        buildEngineHookInjectorArguments(
          targetPid: targetPid,
          launchExe: exe,
          lunaPcHooks: lunaPcHooks,
          lunaCodepage: lunaCodepage,
        ),
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
      if (r == null) {
        return null;
      }
      return parseEngineHookReadyFormat(r);
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

  /// v2 文本 hook：取序号在 `(fromSeq, count]` 的新台词行（我们注入 DLL 的文本 hook 抓的），
  /// 供喂 Hibiki texthooker。返回 `count`(当前总行数) + `lines`(每行 seq/ts(GetTickCount64)/text)。
  /// native 缺失 / 失败返回 null。
  Future<GalTextPoll?> pollText(int fromSeq) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'pollText',
        <String, Object?>{'fromSeq': fromSeq},
      );
      if (r == null) {
        return null;
      }
      final int count = (r['count'] as int?) ?? 0;
      final List<Object?> raw =
          (r['lines'] as List<Object?>?) ?? const <Object?>[];
      final List<GalHookedLine> lines = <GalHookedLine>[];
      for (final Object? e in raw) {
        if (e is Map) {
          final Object? seq = e['seq'];
          final Object? ts = e['ts'];
          final Object? text = e['text'];
          if (seq is int && ts is int && text is String) {
            lines.add(GalHookedLine(
              seq: seq,
              timestampMs: ts,
              text: text,
              threadId: (e['threadId'] as int?) ?? 0,
              threadAddress: (e['threadAddress'] as int?) ?? 0,
              threadContext: (e['threadContext'] as int?) ?? 0,
              threadContext2: (e['threadContext2'] as int?) ?? 0,
              processId: (e['processId'] as int?) ?? 0,
              sourceKind: (e['sourceKind'] as int?) ?? 0,
              hookName: (e['hookName'] as String?) ?? '',
              hookCode: (e['hookCode'] as String?) ?? '',
            ));
          }
        }
      }
      return GalTextPoll(count: count, lines: lines);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 选择 Luna 文本线程。null/0 恢复 helper 自动选择；非 0 时 helper 只发布该线程。
  Future<bool> selectTextThread(int? threadId) async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'selectTextThread',
        <String, Object?>{'threadId': threadId ?? 0},
      );
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// v2 **按句取语音**：取时间戳与 [tsMs]（GetTickCount64，来自 [pollText] 的行 ts）最近、差
  /// <= [tolMs] 的语音 clip PCM —— 就是「这句台词对应的那段语音」，**自动选取、替代手动波形
  /// 选区**。找不到返回 null。
  Future<GalAudioSlice?> grabClipNear(int tsMs, {int tolMs = 8000}) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabClipNear',
        <String, Object?>{'tsMs': tsMs, 'tolMs': tolMs},
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

  /// **会话内**用户手动选定的语音源指针（[grabUtterance] 默认用它，跳过能量自动选源）。0=自动。
  /// 真机上自动能量选源可能误选 BGM，故让用户从 [listAudioTracks] 里挑一条语音轨。
  /// TODO(galgame-mining): source_ptr 每次启动会变，UI 侧应把用户选择最终映射到「创建顺序
  /// orderIndex」或格式签名，下次启动自动套用；本轮先支持会话内按 source_ptr 选。
  int selectedAudioSourcePtr = 0;

  /// **会话内**用户标记为 BGM（要排除）的源指针集合（[grabUtterance] 自动选源时排除）。
  final Set<int> excludedAudioSourcePtrs = <int>{};

  /// v2 **按句取「整句」语音**：把同一语音源在该句时刻附近的所有段拼成整句（替代 [grabClipNear]
  /// 的 ~125ms 碎片）。[sourcePtr] 指定用哪条源（缺省用 [selectedAudioSourcePtr]，0=能量自动选）；
  /// [exclude] 自动选源时排除的源（缺省用 [excludedAudioSourcePtrs]，标记 BGM）。找不到返回 null
  /// （调用方回退 [grabClipNear]）。
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async {
    final int src = sourcePtr ?? selectedAudioSourcePtr;
    final List<int> ex = exclude ?? excludedAudioSourcePtrs.toList();
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabUtterance',
        <String, Object?>{'tsMs': tsMs, 'sourcePtr': src, 'exclude': ex},
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

  /// galgame **纯人声**取语音（真机验证路径，Windows 桌面专属）：按文本行时间戳 [textTsMs]
  /// （GetTickCount64，来自 [pollText] 的行 ts）在 injector hook DLL dump 的语音 OGG 目录
  /// （`%TEMP%\hibiki_gal_voice`）里配对出**这句台词对应的原始语音**（配对规则见
  /// [pickPairedVoiceOgg]），转码成制卡管线容器 [outputExtension]（桌面 `aac`）字节，直接作
  /// `providedAudioBytes`。这是引擎级最干净的语音（混音前、无 BGM/SE），优先于共享内存里的
  /// [grabUtterance]/[grabClipNear]。非 Windows / 目录不存在 / 无匹配 / 转码失败返回 null
  /// （调用方回退 grabUtterance→grabClipNear→grabRecent 采集链，Never break）。
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
  }) async {
    if (!Platform.isWindows) {
      return null;
    }
    final Directory dir = _galVoiceDumpDir();
    if (!dir.existsSync()) {
      return null;
    }
    final List<String> oggNames = <String>[];
    final List<File> oggFiles = <File>[];
    try {
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File) {
          continue;
        }
        final String name = _fileBaseName(e.path);
        if (name.toLowerCase().endsWith('.ogg')) {
          oggNames.add(name);
          oggFiles.add(e);
        }
      }
    } catch (_) {
      return null;
    }
    String? picked = textTsMs > 0
        ? pickPairedVoiceOgg(oggFileNames: oggNames, textTsMs: textTsMs)
        : null;
    // Siglus 的 Enigma-safe 晚附着可能没有文本 hook 时间戳。此时（或精确窗口未命中时）只在
    // 本会话新文件里选修改时间最新的一条；跨会话旧 dump 绝不参与。
    if (picked == null && _sessionStartedAt != null) {
      File? latest;
      DateTime? latestModified;
      final DateTime floor =
          _sessionStartedAt!.subtract(const Duration(seconds: 2));
      for (final File file in oggFiles) {
        final String name = _fileBaseName(file.path);
        final _ParsedVoiceOgg? parsed = _parseVoiceOggName(name);
        if (parsed == null || _isNonVoiceBasename(parsed.basename)) {
          continue;
        }
        DateTime modified;
        try {
          modified = file.statSync().modified;
        } catch (_) {
          continue;
        }
        if (modified.isBefore(floor)) {
          continue;
        }
        if (latestModified == null || modified.isAfter(latestModified)) {
          latest = file;
          latestModified = modified;
        }
      }
      if (latest != null) {
        picked = _fileBaseName(latest.path);
      }
    }
    if (picked == null) {
      return null;
    }
    final String oggPath = '${dir.path}${Platform.pathSeparator}$picked';
    return transcodeVoiceOggToMiningAudio(
      oggPath: oggPath,
      tempDir: Directory.systemTemp.path,
      outputExtension: outputExtension,
    );
  }

  /// 轻量清理语音 dump 目录（[_galVoiceDumpDir]）：hook DLL 持续 dump，跨会话会无限增长。删
  /// 掉超过 [maxAge] 的旧文件、并把总数压到最新 [keepNewest] 个（按修改时间保新弃旧）。在引擎
  /// -hook 就绪时调一次即可（本会话新 dump 都留着，清的是上一局残留）。非 Windows / 目录不存在
  /// / 任何 IO 异常静默返回（清理失败不该影响制卡）。
  Future<void> pruneVoiceDump({
    int keepNewest = 400,
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    final Directory dir = _galVoiceDumpDir();
    if (!dir.existsSync()) {
      return;
    }
    try {
      final DateTime now = DateTime.now();
      final List<File> survivors = <File>[];
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File) {
          continue;
        }
        bool tooOld = false;
        try {
          tooOld = now.difference(e.statSync().modified) > maxAge;
        } catch (_) {
          tooOld = false;
        }
        if (tooOld) {
          try {
            e.deleteSync();
          } catch (_) {}
        } else {
          survivors.add(e);
        }
      }
      if (survivors.length > keepNewest) {
        survivors.sort(
          (File a, File b) => _safeModified(b).compareTo(_safeModified(a)),
        );
        for (int i = keepNewest; i < survivors.length; i++) {
          try {
            survivors[i].deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 清理是尽力而为，绝不影响制卡。
    }
  }

  /// hook DLL dump 语音 OGG 的目录：`<GetTempPath>hibiki_gal_voice`（hook DLL 用 `GetTempPathW`
  /// 落盘，Dart [Directory.systemTemp] 同走 GetTempPath，路径一致）。仅在 Windows 调用。
  Directory _galVoiceDumpDir() => Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}hibiki_gal_voice',
      );

  /// 取路径 [path] 的文件名（最后一段，兼容 `\` 与 `/` 分隔）。
  static String _fileBaseName(String path) {
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// 安全取修改时间（stat 失败回退 epoch，排序时视为最旧）。
  static DateTime _safeModified(File f) {
    try {
      return f.statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// v2 **枚举活跃语音源**：列 [tsMs] 附近各 source_ptr 及元数据（格式/平均缓冲/近窗平均能量/
  /// 创建顺序），供 app UI 显示「音轨列表」让用户手动选（[selectedAudioSourcePtr]）/排除
  /// （[excludedAudioSourcePtrs]）语音源。native 缺失 / 无源返回空列表。
  Future<List<GalAudioTrack>> listAudioTracks(int tsMs) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'listAudioTracks',
        <String, Object?>{'tsMs': tsMs},
      );
      if (r == null) {
        return const <GalAudioTrack>[];
      }
      final List<Object?> raw =
          (r['tracks'] as List<Object?>?) ?? const <Object?>[];
      final List<GalAudioTrack> tracks = <GalAudioTrack>[];
      for (final Object? e in raw) {
        if (e is Map) {
          final GalAudioTrack? tk =
              GalAudioTrack.fromMap(Map<Object?, Object?>.from(e));
          if (tk != null) {
            tracks.add(tk);
          }
        }
      }
      return tracks;
    } on PlatformException {
      return const <GalAudioTrack>[];
    } on MissingPluginException {
      return const <GalAudioTrack>[];
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
    _effectivePid = 0;
    _sessionStartedAt = null;
  }
}

/// [EngineHookGalAudioSource.pollText] 的结果：当前文本行总数 + 本次取到的新行。
class GalTextPoll {
  const GalTextPoll({required this.count, required this.lines});
  final int count;
  final List<GalHookedLine> lines;
}

/// 一条文本 hook 抓到的台词行：单调 [seq]、hook 写入时刻 [timestampMs]（GetTickCount64，与语音
/// clip 同一时钟，供 [EngineHookGalAudioSource.grabClipNear] 按句配对语音）、[text]。
class GalHookedLine {
  const GalHookedLine({
    required this.seq,
    required this.timestampMs,
    required this.text,
    this.threadId = 0,
    this.threadAddress = 0,
    this.threadContext = 0,
    this.threadContext2 = 0,
    this.processId = 0,
    this.sourceKind = 0,
    this.hookName = '',
    this.hookCode = '',
  });
  final int seq;
  final int timestampMs;
  final String text;
  final int threadId;
  final int threadAddress;
  final int threadContext;
  final int threadContext2;
  final int processId;
  final int sourceKind;
  final String hookName;
  final String hookCode;

  String? get textThreadKey {
    if (threadId == 0) return null;
    final String source = switch (sourceKind) {
      1 => 'gdi',
      2 => 'luna',
      _ => 'hook',
    };
    return '$source:${threadId.toUnsigned(64).toRadixString(16)}';
  }

  String? get textThreadLabel {
    if (threadId == 0) return null;
    final String source = hookName.trim().isNotEmpty
        ? hookName.trim()
        : switch (sourceKind) {
            1 => 'GDI fallback',
            2 => 'LunaHook',
            _ => 'Text hook',
          };
    if (threadAddress == 0) return source;
    return '$source · 0x${threadAddress.toUnsigned(64).toRadixString(16)}';
  }
}

/// [EngineHookGalAudioSource.listAudioTracks] 的一条：一个活跃语音源（source voice / DS buffer）
/// 及其元数据快照，供 UI 音轨列表让用户手动选/排除语音源。
class GalAudioTrack {
  const GalAudioTrack({
    required this.sourcePtr,
    required this.format,
    required this.avgBytes,
    required this.avgEnergy,
    required this.orderIndex,
    required this.clipCount,
  });

  /// 源指针（会话内稳定；跨启动会变——UI 宜把用户选择映射到 [orderIndex] 或格式签名）。
  final int sourcePtr;

  /// 该源 PCM 格式（采样率/声道/位深）；解析失败该轨被丢弃。
  final PcmFormat format;

  /// 近窗内该源每段平均字节数（缓冲规模）。
  final int avgBytes;

  /// 文本时刻窗平均能量（16-bit 平均绝对幅值；非 16-bit 为 -1）。越高越可能是当前在说话的语音源。
  final double avgEnergy;

  /// 近窗内按首次出现排的创建顺序，0-based（跨启动相对稳定，宜作用户选择的持久锚）。
  final int orderIndex;

  /// 近窗内该源的段数。
  final int clipCount;

  /// 从 native map 解析；缺格式（sr/ch/bits 非法）或缺 sourcePtr 返回 null。
  static GalAudioTrack? fromMap(Map<Object?, Object?> m) {
    final PcmFormat? fmt = parseGalPcmFormat(m);
    final Object? sp = m['sourcePtr'];
    if (fmt == null || sp is! int) {
      return null;
    }
    return GalAudioTrack(
      sourcePtr: sp,
      format: fmt,
      avgBytes: (m['avgBytes'] as int?) ?? 0,
      avgEnergy: (m['avgEnergy'] as num?)?.toDouble() ?? -1.0,
      orderIndex: (m['orderIndex'] as int?) ?? 0,
      clipCount: (m['clipCount'] as int?) ?? 0,
    );
  }
}
