import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// 引擎 helper 的文本能力握手。PCM `ready` 可以为 false；只要 DLL proof-of-life
/// (`hooked`) 与文本 hook 都已就绪，上层就应保留 helper 并组合其它音频源。
bool parseEngineTextHookReady(Map<Object?, Object?> m) =>
    m['hooked'] == true && m['textHooked'] == true;

/// DLL 已完成首轮音频导出 hook 安装。Luna 文本线程可能比 DLL 工作线程更早写入共享
/// 内存；只有看到这个信号后，才能把“文本已就绪但音频未就绪”判定为真正的混合模式，
/// 否则会在 Siglus OVK / Unity 资源 hook 即将就绪前过早切到 Loopback。
bool parseEngineAudioHooksReady(Map<Object?, Object?> m) =>
    m['audioHooksReady'] == true;

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

/// galgame 纯人声配对（真机验证，docs/specs/galgame-mining）：具有运行时契约的引擎把
/// `TextSlot.seq` 写进资源名并优先按该稳定 ID 配对；显式 ID 不匹配时禁止回退时间猜测。
/// 旧资源仍是 `%TEMP%\hibiki_gal_voice\<tickMs>_<basename>.ogg`
///（tickMs=GetTickCount64，与文本环 `TextSlot.timestamp_ms` 同源）。新版 Siglus
/// 资源导出会直接沿用当前文本 tick，
/// 因此先取 [exactToleranceMs] 内的同 tick 文件；旧引擎仍可能让语音先开流、文本约 220ms
/// 后显示，精确 tick 不存在时再在 `[textTsMs-windowHighMs, textTsMs-windowLowMs]` 内取离
/// `textTsMs-expectedOffsetMs` 最近者。BGM/SE/系统音始终排除。
///
/// 纯函数（只吃文件名列表 [oggFileNames]，不碰文件系统），可单测。无匹配返回 null。
String? pickPairedVoiceOgg({
  required List<String> oggFileNames,
  required int textTsMs,
  int? textEventId,
  int windowLowMs = 130,
  int windowHighMs = 330,
  int expectedOffsetMs = 220,
  int exactToleranceMs = 0,
  int eventIdToleranceMs = 1000,
}) {
  final int lo = textTsMs - windowHighMs;
  final int hi = textTsMs - windowLowMs;
  final int target = textTsMs - expectedOffsetMs;
  String? eventBest;
  int eventBestDist = 1 << 62;
  String? exactBest;
  int exactBestDist = 1 << 62;
  String? offsetBest;
  int offsetBestDist = 1 << 62;
  for (final String name in oggFileNames) {
    final _ParsedVoiceOgg? parsed = _parseVoiceOggName(name);
    if (parsed == null) {
      continue;
    }
    if (_isNonVoiceBasename(parsed.basename)) {
      continue;
    }
    final int tick = parsed.tick;
    if (parsed.textEventId != null) {
      final int eventDist = (tick - textTsMs).abs();
      if (textEventId != null &&
          parsed.textEventId == textEventId &&
          eventDist <= eventIdToleranceMs &&
          eventDist < eventBestDist) {
        eventBestDist = eventDist;
        eventBest = name;
      }
      // 显式携带事件 ID 的资源不能再降级成“附近最新文件”猜给另一条文本。
      continue;
    }
    final int exactDist = (tick - textTsMs).abs();
    if (exactDist <= exactToleranceMs && exactDist < exactBestDist) {
      exactBestDist = exactDist;
      exactBest = name;
      continue;
    }
    if (tick < lo || tick > hi) {
      continue;
    }
    final int dist = (tick - target).abs();
    if (dist < offsetBestDist) {
      offsetBestDist = dist;
      offsetBest = name;
    }
  }
  return eventBest ?? exactBest ?? offsetBest;
}

/// Unity 资源提取器在 AudioSource 播放入口以同一个 GetTickCount64 时钟写 WAV。相较 Siglus
/// 的 OGG 会固定早于文本约 220ms，Unity 文本/AudioClip 调用先后由引擎脚本决定，因此在
/// `T-1000..T+500ms` 内取离文本最近者。调用方始终先选资源 WAV，再退 Siglus OGG。
String? pickPairedUnityVoiceWav({
  required List<String> wavFileNames,
  required int textTsMs,
  int beforeMs = 1000,
  int afterMs = 500,
}) {
  String? best;
  int bestDistance = 1 << 62;
  for (final String name in wavFileNames) {
    final _ParsedVoiceOgg? parsed = _parseVoiceOggName(name);
    if (parsed == null || _isNonVoiceBasename(parsed.basename)) continue;
    if (parsed.tick < textTsMs - beforeMs || parsed.tick > textTsMs + afterMs) {
      continue;
    }
    final int distance = (parsed.tick - textTsMs).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = name;
    }
  }
  return best;
}

/// 在同一条文本时间戳下选择游戏资源语音。
///
/// 有有效 [textTsMs] 时只接受时间窗内的 Unity WAV / Siglus-KiriKiri OGG；即使调用方
/// 提供了 [latestSessionVoiceName]，精确配对失败也必须返回 null，交给上层明确降级到
/// PCM/Loopback，不能把本会话另一句“最新语音”冒充成当前句。只有没有文本时间戳的
/// Siglus 晚附着兼容路径才允许使用会话内最新资源。
String? pickPairedGameResource({
  required List<String> oggFileNames,
  required List<String> wavFileNames,
  required int textTsMs,
  int? textEventId,
  String? latestSessionVoiceName,
}) {
  if (textTsMs <= 0) return latestSessionVoiceName;
  return pickPairedUnityVoiceWav(
        wavFileNames: wavFileNames,
        textTsMs: textTsMs,
      ) ??
      pickPairedVoiceOgg(
        oggFileNames: oggFileNames,
        textTsMs: textTsMs,
        textEventId: textEventId,
      );
}

/// 旧资源名为 `<tick>_<basename>`；具有运行时顺序证据的引擎可写
/// `<tick>_hibiki_textseq<textSeq>_<basename>`，把资源绑定到稳定的
/// TextSlot::seq。
class _ParsedVoiceOgg {
  const _ParsedVoiceOgg({
    required this.tick,
    required this.basename,
    this.textEventId,
  });
  final int tick;
  final String basename;
  final int? textEventId;
}

/// 解析 `<tick>_[hibiki_textseq<textSeq>_]<basename>`。显式标记损坏时整条
/// 拒绝，不得把它当普通 basename 再走时间窗。
_ParsedVoiceOgg? _parseVoiceOggName(String fileName) {
  final int underscore = fileName.indexOf('_');
  if (underscore <= 0) {
    return null;
  }
  final int? tick = int.tryParse(fileName.substring(0, underscore));
  if (tick == null) {
    return null;
  }
  String basename = fileName.substring(underscore + 1);
  if (basename.isEmpty) {
    return null;
  }
  int? textEventId;
  if (basename.startsWith('hibiki_textseq')) {
    final RegExpMatch? match =
        RegExp(r'^hibiki_textseq(\d+)_(.+)$').firstMatch(basename);
    if (match == null) {
      return null;
    }
    textEventId = int.tryParse(match.group(1)!);
    if (textEventId == null || textEventId <= 0) {
      return null;
    }
    basename = match.group(2)!;
  }
  return _ParsedVoiceOgg(
    tick: tick,
    basename: basename,
    textEventId: textEventId,
  );
}

/// BGM / 音效 / 系统音的 basename 前缀（不区分大小写）——这些不是角色语音，配对时排除。
final RegExp _nonVoiceBasenamePattern = RegExp(
  r'^(bgm|se|sys|amb|env|title|logo|movie|jingle)',
  caseSensitive: false,
);

/// basename（去掉 `<tick>_` 前缀后）是否 BGM/SE/系统音（要排除）。
bool _isNonVoiceBasename(String basename) =>
    _nonVoiceBasenamePattern.hasMatch(basename);

/// Unity/Mono/IL2CPP 游戏的文本通常不走 GDI 渲染；Siglus 的 GDI 输出则会包含描边
/// 重画伪影。两类目标都显式补装 LunaHook 通用 PC hooks，让 UI 能选择干净文本线程。
bool shouldUseLunaPcHooksForExecutable(String executablePath) {
  final String basename = EngineHookGalAudioSource._fileBaseName(
    executablePath,
  );
  final String lowerBasename = basename.toLowerCase();
  if (lowerBasename == 'manosaba.exe' || lowerBasename == 'siglusengine.exe') {
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
  final String dataPath = '${directory.path}$separator$stem' '_Data';
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
  bool japaneseLocale = false,
  bool lunaPcHooks = false,
  int? lunaCodepage,
  String? lunaHookProfilePath,
  List<String> lunaHookCodes = const <String>[],
}) {
  final String? exe = launchExe;
  final bool launchMode = exe != null && exe.isNotEmpty;
  final List<String> args = launchMode
      ? <String>['--launch', exe, '--hold']
      : <String>['--pid', '$targetPid', '--hold'];
  if (launchMode && japaneseLocale) {
    args.add('--japanese-locale');
  }
  if (lunaPcHooks) {
    args.add('--luna-pchooks');
  }
  if (lunaCodepage != null && lunaCodepage > 0) {
    args.addAll(<String>['--luna-codepage', '$lunaCodepage']);
  }
  if (lunaHookProfilePath != null && lunaHookProfilePath.isNotEmpty) {
    args.addAll(<String>['--luna-hook-profile', lunaHookProfilePath]);
  }
  for (final String hookCode in lunaHookCodes) {
    if (hookCode.trim().isNotEmpty) {
      args.addAll(<String>['--luna-hook-code', hookCode]);
    }
  }
  return args;
}

typedef GalHookProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

typedef GalHookProcessOutputSink = void Function(
  bool isStderr,
  String chunk,
);

Future<Process> _startGalHookProcess(
  String executable,
  List<String> arguments,
) =>
    Process.start(executable, arguments);

void _logGalHookProcessOutput(bool isStderr, String chunk) {
  final String message = chunk.trimRight();
  if (message.isEmpty) return;
  debugPrint('[gal-hook:${isStderr ? 'stderr' : 'stdout'}] $message');
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
    this.automaticJapaneseLocale = true,
    this.lunaPcHooks = false,
    this.lunaCodepage,
    this.lunaHookProfilePath,
    this.lunaHookCodes = const <String>[],
    MethodChannel? channel,
    GalHookProcessStarter? processStarter,
    GalHookProcessOutputSink? processOutputSink,
    Duration readyTimeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(milliseconds: 200),
  })  : _channel =
            channel ?? const MethodChannel('app.hibiki.reader/voice_hook'),
        _processStarter = processStarter ?? _startGalHookProcess,
        _processOutputSink = processOutputSink ?? _logGalHookProcessOutput,
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

  /// 32 位 launch 目标默认以 helper 随包提供的 Locale Emulator 建立日语 CP932
  /// 环境。它只影响 injector 创建的游戏进程，不修改 Windows 全局区域设置；64 位与
  /// attach 模式不启用。运行库缺失时 native helper 会记录诊断并安全回退普通启动。
  final bool automaticJapaneseLocale;

  /// 是否让 LunaHook 连接后额外插入通用 PC hooks。Unity/Mono/IL2CPP 这类自绘文本路径需要它，
  /// 经典 GDI/KiriKiri/Siglus 默认关闭以减少重复线程。
  final bool lunaPcHooks;

  /// LunaHook 默认文本代码页。null 时沿用 injector 默认值（日文 Shift-JIS/932）。
  final int? lunaCodepage;

  /// UTF-8 TSV profile file. The injector matches entries by executable/module
  /// SHA-256, so moving a game directory does not change the selected code.
  String? lunaHookProfilePath;

  /// Explicit one-shot codes, mainly for diagnostics. Persisted user codes use
  /// [lunaHookProfilePath] so they retain their SHA-256 identity guard.
  final List<String> lunaHookCodes;

  final MethodChannel _channel;
  final GalHookProcessStarter _processStarter;
  final GalHookProcessOutputSink _processOutputSink;
  final Duration _readyTimeout;
  final Duration _pollInterval;

  /// 拉起的 injector 子进程句柄（[stop] 时杀掉）。
  Process? _injector;
  final List<StreamSubscription<String>> _injectorOutputSubscriptions =
      <StreamSubscription<String>>[];
  Completer<int?>? _hookedPidCompleter;

  /// 实际注入命中的游戏 PID：attach=`targetPid`；launch=从 injector stdout 解析出的子进程 PID。
  /// [grabRecent]/`open` 都用它开共享内存。
  int _effectivePid = 0;

  /// 本次 injector 会话起点。Siglus 晚附着可能抓不到文本时间戳，制卡时只允许用本会话之后
  /// 新落盘的最新 Ogg，避免误配上一局残留。
  DateTime? _sessionStartedAt;

  /// 注入命中的游戏进程 PID（[start] 成功后有效）；未就绪返回 null。launch 模式下调用方据此
  /// 找游戏主窗口（截图用），因为拉起游戏的是本源、PID 只有它知道。
  int? get gamePid => _effectivePid > 0 ? _effectivePid : null;

  /// helper 已完成注入且文本 hook 可用，但当前引擎没有暴露可读 PCM/原始语音时为 true。
  /// 上层据此保留本实例继续轮询文本，同时另启系统 Loopback 作为音频源。
  bool get textHookReady => _textHookReady;
  bool get rawVoiceReady => _rawVoiceReady;
  bool get pcmReady => _pcmReady;
  bool _textHookReady = false;
  bool _audioHooksReady = false;
  bool _rawVoiceReady = false;
  bool _pcmReady = false;

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
    _textHookReady = false;
    _audioHooksReady = false;
    _rawVoiceReady = false;
    _pcmReady = false;
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
    final bool japaneseLocale =
        launchMode && automaticJapaneseLocale && await exeIs32Bit(exe) == true;
    // 1. 拉起 injector 子进程（注入报毒代码只在这个隔离子进程里执行）。
    //    launch 模式：`--launch <exe>` CREATE_SUSPENDED 早注入，从 stdout 解析子进程 PID；
    //    attach 模式：`--pid <PID>` 附着已运行进程。
    try {
      _injector = await _processStarter(
        path,
        buildEngineHookInjectorArguments(
          targetPid: targetPid,
          launchExe: exe,
          japaneseLocale: japaneseLocale,
          lunaPcHooks: lunaPcHooks,
          lunaCodepage: lunaCodepage,
          lunaHookProfilePath: lunaHookProfilePath,
          lunaHookCodes: lunaHookCodes,
        ),
      );
    } on ProcessException {
      return null;
    }
    _beginInjectorOutputDrain(_injector!);
    // launch 和 attach 都必须等 helper 宣告注入完成。attach 旧实现启动子进程后立即
    // `open`，共享内存通常还没创建，单次 OpenFileMapping 失败后便误降级到 loopback。
    // `OK hooked` 是 helper 创建共享会话后的 proof-of-life，也是两种模式共同的边界。
    final int? hookedPid = await _awaitHookedPid();
    if (hookedPid == null ||
        hookedPid <= 0 ||
        (!launchMode && hookedPid != targetPid)) {
      await stop();
      return null; // 启动/注入失败（目标不符 / 位数不符 / 超时）
    }
    _effectivePid = hookedPid;
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
      // Luna 文本线程可能先于 DLL 音频工作线程出现。必须等首轮音频探针完成后，才把
      // “文本-only”交给控制器组合 Loopback；否则 Siglus 原始 OVK hook 会被启动竞态
      // 误判为不可用。helper 仍会保留，因此后续资源语音始终优先于 Loopback。
      if (_textHookReady && _audioHooksReady) {
        return null;
      }
      await Future<void>.delayed(_pollInterval);
    }
    // 超时未就绪（未注入成功 / 该引擎无捕获）：降级。
    await stop();
    return null;
  }

  /// injector 是常驻 helper，stdout/stderr 也必须贯穿会话持续排空。只在解析到 launch PID
  /// 后取消 stdout 订阅会让后续输出填满匿名管道；完全不订阅 stderr 更会使 native 卡死在
  /// `fprintf(stderr, ...)`，Unity 资源事件队列随之停止消费但进程仍显示存活。
  void _beginInjectorOutputDrain(Process process) {
    final Completer<int?> pidCompleter = Completer<int?>();
    final StringBuffer stdoutBuffer = StringBuffer();
    _hookedPidCompleter = pidCompleter;
    _injectorOutputSubscriptions.add(
      process.stdout.transform(const SystemEncoding().decoder).listen(
        (String chunk) {
          _emitInjectorOutput(isStderr: false, chunk: chunk);
          if (pidCompleter.isCompleted) return;
          stdoutBuffer.write(chunk);
          final int? pid = parseInjectorHookedPid(stdoutBuffer.toString());
          if (pid != null) pidCompleter.complete(pid);
        },
        onDone: () {
          if (!pidCompleter.isCompleted) {
            pidCompleter
                .complete(parseInjectorHookedPid(stdoutBuffer.toString()));
          }
        },
        onError: (Object _) {
          if (!pidCompleter.isCompleted) {
            pidCompleter.complete(null);
          }
        },
      ),
    );
    _injectorOutputSubscriptions.add(
      process.stderr.transform(const SystemEncoding().decoder).listen(
            (String chunk) => _emitInjectorOutput(isStderr: true, chunk: chunk),
            onError: (Object error) => _emitInjectorOutput(
              isStderr: true,
              chunk: 'stderr stream error: $error',
            ),
          ),
    );
  }

  void _emitInjectorOutput({
    required bool isStderr,
    required String chunk,
  }) {
    try {
      _processOutputSink(isStderr, chunk);
    } catch (_) {
      // 诊断输出消费者不得反向阻塞 helper 管道。
    }
  }

  /// 等 stdout 中的 `OK hooked pid=<N>`；订阅本身不会在解析成功后取消，仍负责排空
  /// helper 余生的输出。launch 用返回 PID 发现新游戏，attach 用它避免抢跑共享内存。
  Future<int?> _awaitHookedPid() async {
    final Completer<int?>? completer = _hookedPidCompleter;
    if (completer == null) return null;
    return completer.future.timeout(_readyTimeout, onTimeout: () => null);
  }

  /// 轮询 native `status`：hook 就绪（ready）且格式有效时返回 [PcmFormat]，否则 null。
  Future<PcmFormat?> _pollFormat() async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>('status');
      if (r == null) {
        return null;
      }
      _textHookReady = parseEngineTextHookReady(r);
      _audioHooksReady = parseEngineAudioHooksReady(r);
      _rawVoiceReady = r['rawVoiceReady'] == true;
      _pcmReady = parseGalPcmFormat(r) != null;
      return parseEngineHookReadyFormat(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 刷新运行中 helper 的能力状态。
  ///
  /// KiriKiriZ 的 `TVPCreateStream` 等资源层可能晚于 Luna 文本管线初始化；启动阶段
  /// 因此会先进入“文本 + Loopback”。控制器在后续文本轮询中调用此方法，才能在资源
  /// hook 晚到后把原始游戏语音提升为主来源。
  Future<bool> refreshReadiness() async {
    await _pollFormat();
    return _rawVoiceReady;
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

  /// v7 文本 hook：取序号在 `(fromSeq, count]` 的新台词/线程发现事件，供喂 Hibiki
  /// texthooker 与线程选择器。native 缺失 / 失败返回 null。
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
              eventKind: GalTextEventKind.fromNative(
                (e['eventKind'] as int?) ?? 0,
              ),
              eventFlags: (e['eventFlags'] as int?) ?? 0,
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
  File? _findPairedVoiceFile(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) {
    if (!Platform.isWindows) return null;
    final Directory dir = _galVoiceDumpDir();
    if (!dir.existsSync()) return null;
    final List<String> oggNames = <String>[];
    final List<String> wavNames = <String>[];
    final List<File> voiceFiles = <File>[];
    try {
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File) {
          continue;
        }
        final String name = _fileBaseName(e.path);
        final String lower = name.toLowerCase();
        if (lower.endsWith('.ogg')) {
          oggNames.add(name);
          voiceFiles.add(e);
        } else if (lower.endsWith('.wav')) {
          wavNames.add(name);
          voiceFiles.add(e);
        }
      }
    } catch (_) {
      return null;
    }
    String? picked = pickPairedGameResource(
      oggFileNames: oggNames,
      wavFileNames: wavNames,
      textTsMs: textTsMs,
      textEventId: textEventId,
    );
    // Siglus 的 Enigma-safe 晚附着可能没有文本 hook 时间戳。只有这种无时间戳路径才在本会话
    // 新文件里选修改时间最新的一条；有时间戳但窗口未命中必须返回 null，让上层明确降级，
    // 否则会把别句资源语音错配给当前文本。跨会话旧 dump 始终不参与。
    //
    // BUG-955：mine 阶段（解析某条具体行的语音）绝不允许「最新语音」兜底——历史行的时间戳
    // 被 _lineTimestampCache 淘汰后也会以 textTsMs=0 落到这里，若借最新语音就把当前语音错配给
    // 旧台词并谎报 game_resource。晚附着 live 行的最新语音兜底只发生在捕获期（poll，默认允许），
    // 且已在捕获时固化到该行；mine 路径传 allowLatestSessionFallback=false 明确禁用。
    if (allowLatestSessionFallback &&
        picked == null &&
        textTsMs <= 0 &&
        _sessionStartedAt != null) {
      File? latest;
      DateTime? latestModified;
      final DateTime floor =
          _sessionStartedAt!.subtract(const Duration(seconds: 2));
      for (final File file in voiceFiles) {
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
        picked = pickPairedGameResource(
          oggFileNames: oggNames,
          wavFileNames: wavNames,
          textTsMs: textTsMs,
          latestSessionVoiceName: _fileBaseName(latest.path),
        );
      }
    }
    if (picked == null) {
      return null;
    }
    return File('${dir.path}${Platform.pathSeparator}$picked');
  }

  /// 只检查资源文件是否已落盘，不提前做转码。捕获工作台的文本轮询用它把逐行状态从
  /// “等待音频”推进到 `game_resource`；真正制卡时仍由 [grabPairedVoiceBytes] 读取并转码。
  bool hasPairedVoiceCandidate(int textTsMs,
          {int? textEventId, bool allowLatestSessionFallback = true}) =>
      _findPairedVoiceFile(
        textTsMs,
        textEventId: textEventId,
        allowLatestSessionFallback: allowLatestSessionFallback,
      ) !=
      null;

  /// 返回与文本时间戳精确配对的资源 ID（dump 目录内的 basename）。控制器在台词刚到达时
  /// 把它固化到该行；之后即使用户从历史列表制卡，也不再按“当前最新资源”重新猜测。
  String? findPairedVoiceResourceId(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) {
    final File? file = _findPairedVoiceFile(
      textTsMs,
      textEventId: textEventId,
      allowLatestSessionFallback: allowLatestSessionFallback,
    );
    return file == null ? null : _fileBaseName(file.path);
  }

  File? _voiceFileForResourceId(String resourceId) {
    if (!Platform.isWindows ||
        resourceId.isEmpty ||
        _fileBaseName(resourceId) != resourceId) {
      return null;
    }
    final String lower = resourceId.toLowerCase();
    if (!lower.endsWith('.ogg') && !lower.endsWith('.wav')) return null;
    final File file = File(
      '${_galVoiceDumpDir().path}${Platform.pathSeparator}$resourceId',
    );
    return file.existsSync() ? file : null;
  }

  /// 已配对语音资源文件（dump 目录里的 OGG/WAV 原件）的绝对路径。列表行试听直接
  /// 播原文件（media_kit 原生可解），**不走** [grabPairedVoiceBytes] 的 ffmpeg
  /// 转码链。文件不存在（已被 [pruneVoiceDump] 清理）返回 null。
  String? pairedVoiceFilePathForResourceId(String resourceId) {
    final File? file = _voiceFileForResourceId(resourceId);
    return (file != null && file.existsSync()) ? file.path : null;
  }

  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async {
    final File? picked = resourceId == null
        ? _findPairedVoiceFile(
            textTsMs,
            textEventId: textEventId,
            allowLatestSessionFallback: allowLatestSessionFallback,
          )
        : _voiceFileForResourceId(resourceId);
    if (picked == null) return null;
    return transcodeVoiceOggToMiningAudio(
      oggPath: picked.path,
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
    final List<StreamSubscription<String>> outputSubscriptions =
        List<StreamSubscription<String>>.of(_injectorOutputSubscriptions);
    _injectorOutputSubscriptions.clear();
    final Completer<int?>? pidCompleter = _hookedPidCompleter;
    _hookedPidCompleter = null;
    if (pidCompleter != null && !pidCompleter.isCompleted) {
      pidCompleter.complete(null);
    }
    await Future.wait(
      outputSubscriptions.map(
        (StreamSubscription<String> subscription) => subscription.cancel(),
      ),
    );
    _effectivePid = 0;
    _sessionStartedAt = null;
    _textHookReady = false;
    _audioHooksReady = false;
  }
}

/// [EngineHookGalAudioSource.pollText] 的结果：当前文本行总数 + 本次取到的新行。
class GalTextPoll {
  const GalTextPoll({required this.count, required this.lines});
  final int count;
  final List<GalHookedLine> lines;
}

enum GalTextEventKind {
  line,
  threadDiscovered;

  static GalTextEventKind fromNative(int value) => switch (value) {
        1 => GalTextEventKind.threadDiscovered,
        _ => GalTextEventKind.line,
      };
}

/// 一条文本 hook 事件：台词行携带 [text]；线程发现事件的 [text] 为空，只携带 Luna
/// ThreadParam/hook 元数据。所有事件共享单调 [seq] 与 [timestampMs]（GetTickCount64）。
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
    this.eventKind = GalTextEventKind.line,
    this.eventFlags = 0,
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
  final GalTextEventKind eventKind;
  final int eventFlags;
  final String hookName;
  final String hookCode;

  String? get textThreadKey {
    if (threadId == 0) return null;
    final String source = switch (sourceKind) {
      1 => 'gdi',
      2 => 'luna',
      3 => 'unity_tmp',
      4 => 'siglus',
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
            3 => 'Unity TMP_Text',
            4 => 'Siglus exact',
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
