import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_japanese_locale_probe.dart';
import 'package:fushi/src/mining/galgame_hook_runtime_stage.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart'
    show PcmFormat, transcodeVoiceResourcesToMiningAudio;
import 'package:fushi/src/mining/gal_voice_dump_index.dart';

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
/// native 侧（`fushi/windows/runner/audio_loopback_capture.cpp`）注册 `audio_loopback`
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
            channel ?? const MethodChannel('app.fushi.reader/audio_loopback');

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
/// 必需字段 / 不可编码的 PCM 格式返回 null（loopback 与引擎-hook 两个源共用同一格式契约）。
///
/// helper 读到尚未稳定或并非 `WAVEFORMATEX` 的内存时，字段可能全部为正数却仍然是
/// 垃圾格式。典型现场是 SGRE/M2 启动后误报 `47968 Hz / 2 ch / 4 bit`：旧判断把它
/// 当作引擎 PCM 就绪，从而阻止已经可用的 WASAPI Loopback 接管，最终每句都落成
/// `line_has_no_voice`。这里只接受 WAV/编码链路实际支持的、按整字节存储的常见位深；
/// 浮点 PCM 目前只支持 float32。
PcmFormat? parseGalPcmFormat(Map<Object?, Object?> m) {
  final Object? sampleRate = m['sampleRate'];
  final Object? channels = m['channels'];
  final Object? bitsPerSample = m['bitsPerSample'];
  final bool isFloat = m['isFloat'] == true;
  if (sampleRate is! int ||
      channels is! int ||
      bitsPerSample is! int ||
      sampleRate < 8000 ||
      sampleRate > 384000 ||
      channels < 1 ||
      channels > 8 ||
      !const <int>{8, 16, 24, 32}.contains(bitsPerSample) ||
      (isFloat && bitsPerSample != 32)) {
    return null;
  }
  return PcmFormat(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
    isFloat: isFloat,
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

/// 从 injector stdout 解析 `LAUNCH pid=<N>`：injector 在 `CreateProcess` 成功后立刻回报的
/// 游戏 PID，**先于**注入结果。旧 helper 不打印这行（返回 null），新 helper 打印后，
/// 即使随后注入失败，Hibiki 也知道「游戏其实已经起来了」，可以改走附着重试而不是把
/// 一个正在运行的游戏报成「启动失败」。纯函数，可单测。
int? parseInjectorLaunchedPid(String stdout) {
  final RegExpMatch? m = RegExp(r'LAUNCH pid=(\d+)').firstMatch(stdout);
  if (m == null) {
    return null;
  }
  final int? pid = int.tryParse(m.group(1)!);
  return (pid != null && pid > 0) ? pid : null;
}

/// injector 启动/附着失败的结构化原因。
///
/// 旧实现把 injector 的 stdout/stderr 只丢给 `debugPrint`：release 包没有控制台，用户
/// 与开发者都只能看到一句 `engine_attach_failed`，无法区分「游戏以管理员身份运行导致
/// OpenProcess 被拒」「位数不符」「杀软拦下注入」「DLL 还在加载就超时」。这些原因的
/// 处置完全不同（前两类重试无意义、后两类值得重试），因此必须结构化。
enum GalHookInjectorFailure {
  /// 未失败。
  none,

  /// 没有可用的 injector 可执行文件（未安装 / 架构目录缺失）。
  helperMissing,

  /// 既无 launchExe 也无有效 targetPid。
  targetMissing,

  /// injector 进程根本拉不起来（文件被杀软删除/锁定、权限不足）。
  spawnFailed,

  /// 注入器位数与目标进程不符。
  bitnessMismatch,

  /// `OpenProcess` 被拒：目标进程完整性级别更高（多为游戏以管理员身份运行）。
  accessDenied,

  /// `CreateProcess` 需要提权（ERROR_ELEVATION_REQUIRED=740）。
  elevationRequired,

  /// 其它 `CreateProcess` 失败。
  createProcessFailed,

  /// helper 目录缺 hook DLL（安装包不完整）。
  hookDllMissing,

  /// 游戏 exe 路径不存在（被移动/删除/盘符变化）。
  gameExeMissing,

  /// 已有共享映射暂不可复用，但尚未证明驻留 DLL 确实不同。旧 injector 退出、
  /// Toolhelp/文件系统竞态或 hooked 发布中的短窗口可能自愈，因此允许有界重试。
  staleSession,

  /// 已证明目标进程驻留的 hook DLL 路径或摘要与本次请求不同。
  /// Windows 不会卸载已注入 DLL；同一 PID 原地重试无效，必须重启游戏。
  residentHookMismatch,

  /// 注入完成但 DLL 未在超时内发出就绪信号。
  readyTimeout,

  /// native loopback 策略的**确认**未在超时内到达。
  ///
  /// 与 [readyTimeout] 分开是因为两者的事实完全不同：那条是「hook DLL 根本没跑到通知点」
  /// （架构/契约/权限），本条是「DLL 活着、就绪事件已收到，只是 loopback 这一项能力的
  /// 确认慢了一拍」。injector 只在 **deny**（隐私边界，必须证明没有 worker 在录）时才
  /// 因此判失败；**allow** 只是能力未就绪，已改为降级继续、不再中止注入（BUG-2131）。
  nativeLoopbackAckTimeout,

  /// 远程线程注入本身失败（`VirtualAllocEx` / `WriteProcessMemory` / `CreateRemoteThread`）。
  injectionFailed,

  /// 精确 profile 要求先移除危险自动 hook，但守卫安装未在超时内确认。
  guardedHookFailed,

  /// 恢复挂起的游戏主线程失败：该进程已不可用，injector 会结束它以免留下僵尸。
  resumeFailed,

  /// Steam 客户端接受了启动请求但未在超时内出现目标进程。
  steamTimeout,

  /// injector 已宣告 hooked，但共享内存打不开（native 通道不可用）。
  sharedMemoryUnavailable,

  /// 共享内存打开了，但契约版本与本体不一致：捕获组件与 Hibiki 本体漂开。
  ///
  /// 与 [sharedMemoryUnavailable] 分开是因为**处置相反**：后者重试/重开游戏有可能好，
  /// 前者重启多少次都不会好（BUG-1216）。
  ///
  /// 处置只有「更新本体」一条：捕获组件自 BUG-1196 起随主包内置（`galgame_helper/` 里的
  /// 已校验归档，由 [GalgameHelperInstaller] 在每次启动前按摘要自动换入），**没有独立于
  /// app 的更新通道**，所以旧文案里的「重新安装捕获组件」是个不存在的动作。真能落到这里
  /// 只剩两种局面：① 本包没随附归档（开发构建 / 早于随包发布的旧包），用的是历史遗留的
  /// 组件目录；② 随附了但仍不匹配 = 本体与组件不同源构建，属发布包缺陷。两者用户能做的
  /// 都是「换一个新版本的 Hibiki」，具体是哪一种由诊断行里的双方版本号（`shm=11/want 12`）
  /// 和安装器日志分辨。
  protocolMismatch,

  /// injector 已 hooked、共享内存已开，但超时内既没有 PCM 格式也没有文本 hook。
  handshakeTimeout,

  /// capability 探测没能给出答案：helper 拉不起来、崩了、或超时没退出。
  ///
  /// 与 [protocolMismatch] 分开是因为**处置相反**：那条是组件比本体旧、只能换版本；
  /// 这条是这台机器上 helper 根本没跑起来或没响应（多为杀软删档/锁定、权限不足、
  /// 进程挂住），换多少个版本都不会好。
  capabilityProbeFailed,

  /// 有失败但无法归类（保留原始 stderr 尾巴供诊断）。
  unknown,
}

/// 该失败原因是否值得原地重试。
///
/// 判据是「同一台机器、同一个游戏、什么都不做的情况下再试一次有没有可能成功」：
/// 引擎初始化竞态、DLL 加载慢、暂不可复用的 staleSession 可能随时间自愈；
/// 架构不符、缺文件、需要提权不会。residentHookMismatch 里的旧 hook DLL 会驻留到
/// 游戏退出，对同一 PID 原地重试也不会改变。
/// 重试不能用来掩盖这些必须说给用户的可执行处置。
bool galHookFailureIsRetryable(GalHookInjectorFailure failure) =>
    switch (failure) {
      GalHookInjectorFailure.readyTimeout ||
      // 纯时序竞态（worker 起流慢于注入预算），原地重试有机会赶上。
      GalHookInjectorFailure.nativeLoopbackAckTimeout ||
      GalHookInjectorFailure.injectionFailed ||
      GalHookInjectorFailure.guardedHookFailed ||
      GalHookInjectorFailure.staleSession ||
      GalHookInjectorFailure.handshakeTimeout ||
      GalHookInjectorFailure.sharedMemoryUnavailable ||
      GalHookInjectorFailure.steamTimeout ||
      GalHookInjectorFailure.unknown =>
        true,
      _ => false,
    };

/// injector 失败诊断：结构化原因 + 退出码 + stderr 尾部原文。
@immutable
class GalHookInjectorDiagnostics {
  const GalHookInjectorDiagnostics({
    this.failure = GalHookInjectorFailure.none,
    this.exitCode,
    this.stderrTail = '',
  });

  final GalHookInjectorFailure failure;
  final int? exitCode;
  final String stderrTail;

  bool get isFailure => failure != GalHookInjectorFailure.none;
  bool get isRetryable => galHookFailureIsRetryable(failure);

  /// 事件详情用的可序列化摘要（不含用户路径以外的敏感信息；stderr 尾部截断）。
  Map<String, Object?> toDetails() => <String, Object?>{
        'reason': failure.name,
        if (exitCode != null) 'exitCode': exitCode,
        if (stderrTail.isNotEmpty) 'detail': stderrTail,
      };
}

/// 旧 helper 人类可读诊断里的一个失败标记，以及它对应的结构化原因。
///
/// [marker] 是在 injector stderr 里要找的子串；[sourceLiteral] 是这条诊断在
/// `native/galgame_hook/injector/injector_main.cpp` 里的**逐字**产出锚点（含 `%lu`
/// 这类格式化占位符——锚点比对的是源码，不是运行期输出）。[sourceLiteral] 为空表示
/// 产出方已从当前 injector 移除，这条仅为兼容仍在用户机上的旧 helper 二进制保留。
///
/// 守卫测试 `test/mining/gal_injector_diagnostics_marker_guard_test.dart` 按这两项
/// 逐条复核，把「靠自然语言串识别 native 失败」这个本就脆的判据钉回真相源：injector
/// 一改文案，锚点先红，而不是等用户拿到一句与事实相反的处置建议。
typedef GalHookDiagnosticsMarker = ({
  String marker,
  String sourceLiteral,
  GalHookInjectorFailure failure,
});

/// 旧 helper 诊断 → 结构化失败原因的**有序**匹配表（先命中的先返回）。
///
/// 顺序是硬约束：`已存在但不可复用的 hook 会话` 是
/// `已存在但不可复用的 hook 会话（驻留 DLL …）` 的子串，泛串排到具体串之前，会把
/// 「必须重启游戏才能卸载驻留旧 DLL」的 [GalHookInjectorFailure.residentHookMismatch]
/// 误判成「等一下会自愈」的 [GalHookInjectorFailure.staleSession]——两者的处置正好相反，
/// 还会让 [galHookFailureIsRetryable] 对一个永远好不了的现场反复重试。
///
/// 表里没有英文 `bitness mismatch`：全仓历史上从没有哪个 injector 打过这句（`git log
/// --all -S` 在 `native/` 下零命中），它只是一个从未命中的幻影分支。
@visibleForTesting
const List<GalHookDiagnosticsMarker> galHookLegacyDiagnosticsMarkers =
    <GalHookDiagnosticsMarker>[
  // 740 = ERROR_ELEVATION_REQUIRED。错误码由 `%lu` 填，源码里只有格式串可锚。
  (
    marker: 'CreateProcessW failed: 740',
    sourceLiteral: 'CreateProcessW failed: %lu',
    failure: GalHookInjectorFailure.elevationRequired,
  ),
  (
    marker: 'CreateProcessW failed',
    sourceLiteral: 'CreateProcessW failed: %lu',
    failure: GalHookInjectorFailure.createProcessFailed,
  ),
  (
    marker: '位数不匹配',
    sourceLiteral: '位数不匹配：目标是 %s 进程，请改用对应 arch 的注入器 ',
    failure: GalHookInjectorFailure.bitnessMismatch,
  ),
  (
    marker: 'OpenProcess(',
    sourceLiteral: 'OpenProcess(%lu) failed: %lu (需管理员/相同完整性级别?)',
    failure: GalHookInjectorFailure.accessDenied,
  ),
  (
    marker: 'hook DLL not found',
    sourceLiteral: 'hook DLL not found (pass --dll <path>)',
    failure: GalHookInjectorFailure.hookDllMissing,
  ),
  (
    marker: '目标 exe 不存在',
    sourceLiteral: '目标 exe 不存在（--launch <exe路径>）',
    failure: GalHookInjectorFailure.gameExeMissing,
  ),
  // 旧映射暂不可复用：宿主有界重试即可，用户什么都不用做。
  (
    marker: '已存在但暂不可复用的 hook 会话',
    sourceLiteral:
        '已存在但暂不可复用的 hook 会话（契约、hooked 或驻留 DLL 身份暂不可确认）；',
    failure: GalHookInjectorFailure.staleSession,
  ),
  // 驻留 DLL 已被证明不同：Windows 不卸载已注入 DLL，同一 PID 重试永远无效。
  (
    marker: '已存在但不可复用的 hook 会话（驻留 DLL',
    sourceLiteral:
        '已存在但不可复用的 hook 会话（驻留 DLL 路径或摘要与本次请求不匹配）；',
    failure: GalHookInjectorFailure.residentHookMismatch,
  ),
  // 拆分前（injector 打的是「契约不匹配或 hooked=0」）这句就是可重试的 staleSession。
  // 当前 injector 不再产出它，只为旧 helper 二进制保留原语义。
  (
    marker: '已存在但不可复用的 hook 会话',
    sourceLiteral: '',
    failure: GalHookInjectorFailure.staleSession,
  ),
  (
    marker: '未收到就绪信号',
    sourceLiteral: '注入完成但未收到就绪信号（%lums 超时）；hooked=%u',
    failure: GalHookInjectorFailure.readyTimeout,
  ),
  (
    marker: 'injection failed',
    sourceLiteral: 'injection failed',
    failure: GalHookInjectorFailure.injectionFailed,
  ),
  (
    marker: 'CreateRemoteThread failed',
    sourceLiteral: 'CreateRemoteThread failed: %lu',
    failure: GalHookInjectorFailure.injectionFailed,
  ),
  (
    marker: 'WriteProcessMemory failed',
    sourceLiteral: 'WriteProcessMemory failed: %lu',
    failure: GalHookInjectorFailure.injectionFailed,
  ),
  (
    marker: 'VirtualAllocEx failed',
    sourceLiteral: 'VirtualAllocEx failed: %lu',
    failure: GalHookInjectorFailure.injectionFailed,
  ),
  (
    marker: 'resolve LoadLibraryW failed',
    sourceLiteral: 'resolve LoadLibraryW failed',
    failure: GalHookInjectorFailure.injectionFailed,
  ),
  (
    marker: 'Steam 已接受启动请求',
    sourceLiteral: 'Steam 已接受启动请求，但 45 秒内未发现目标进程：%ls',
    failure: GalHookInjectorFailure.steamTimeout,
  ),
];

/// injector 诊断输出 → 结构化失败原因（纯函数，可单测）。
///
/// 优先认新 helper 的机器可读行 `ERR reason=<token>`：当前 injector 的**每一条**失败
/// 出口都会打这一行（`ReportFailureReason` 统一出口 + elevationRequired / accessDenied
/// 两处直写），所以正常链路上根本走不到下面的自然语言匹配。旧 helper 二进制只有人类
/// 可读诊断，因此保留 [galHookLegacyDiagnosticsMarkers] 这张有序表兜底——它是**兼容层**，
/// 不是判据主路，任何新增失败原因都必须先走结构化 token。
///
/// 两条路都命不中时返回 [fallback]，绝不假装知道原因。
GalHookInjectorFailure classifyGalHookInjectorFailure(
  String diagnostics, {
  GalHookInjectorFailure fallback = GalHookInjectorFailure.unknown,
}) {
  if (diagnostics.trim().isEmpty) {
    return fallback;
  }
  final RegExpMatch? structured =
      RegExp(r'ERR reason=([a-zA-Z_]+)').firstMatch(diagnostics);
  if (structured != null) {
    final String token = structured.group(1)!.toLowerCase();
    for (final GalHookInjectorFailure candidate
        in GalHookInjectorFailure.values) {
      if (candidate.name.toLowerCase() == token) {
        return candidate;
      }
    }
  }
  for (final GalHookDiagnosticsMarker entry
      in galHookLegacyDiagnosticsMarkers) {
    if (diagnostics.contains(entry.marker)) {
      return entry.failure;
    }
  }
  return fallback;
}

/// native 诊断压成一行可展示的证据：`exit=<码> <stderr 最后一行非空内容>`。
///
/// 取**最后一行**：injector 失败即退，最后写出的那行就是它停下的地方；早期的
/// `[luna] ... 已注入` 之类是进度而非结论。读侧失败（共享内存打不开）的一手事实也由
/// [EngineHookGalAudioSource] 追加在末行，同样落进这里。长诊断从尾部截断（保留结论侧）。
String galHookDiagnosticsDetail(GalHookInjectorDiagnostics diagnostics) {
  const int maxLength = 160;
  final List<String> parts = <String>[];
  if (diagnostics.exitCode != null) {
    parts.add('exit=${diagnostics.exitCode}');
  }
  final List<String> lines = diagnostics.stderrTail
      .split(RegExp(r'[\r\n]+'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
  if (lines.isNotEmpty) {
    final String last = lines.last;
    parts.add(
      last.length <= maxLength
          ? last
          : '…${last.substring(last.length - maxLength)}',
    );
  }
  return parts.join(' ');
}

/// `voice_hook` 通道 `open` 失败 token → 结构化失败原因（纯函数，可单测）。
///
/// token 是 native `VoiceHookOpenErrorToken`（`windows/runner/voice_hook_reader.cpp`）的
/// 唯一输出，是**跨语言契约的名字**——两侧必须同名，由
/// `test/mining/gal_shm_open_error_test.dart` 扫源码守卫。
///
/// 分开归类的理由是**处置完全不同**，而旧实现把它们全压成一句「捕获通道无法打开，请重启
/// Hibiki」（BUG-1216）：
///   - `access_denied`：游戏跑在更高完整性级别 → 要以管理员身份运行 Hibiki，重启没用；
///   - `protocol_mismatch`：捕获组件与本体版本漂开 → 组件随本体内置更新，只能更新本体，重启更没用；
///   - 其余（映射不存在 / MapView 失败 / pid 非法）→ native 只知道「映射不在那儿」，
///     **不知道为什么**，此处返回 null。
///
/// 返回 null 表示「native 没定出具体处置」，调用方据此回退到 injector stderr 归类
/// （[classifyGalHookInjectorFailure]）。这是有意的：`mapping_not_found` 这类 token 只说明
/// 读侧没找到映射，而 injector 的 stderr 往往正好写着**为什么**没建起来（hook DLL 缺失 /
/// 位数不匹配 / 陈旧会话 / 需要提权…）。若在这里一律返回
/// [GalHookInjectorFailure.sharedMemoryUnavailable]，那些更可执行的原因就被这层压掉了——
/// 那正是 BUG-1216 要消灭的「信息在返回值处被丢弃」，只是换个地方重犯。
/// 只有 native **真的定出**处置的两条（拒绝访问 / 契约不符）才盖过 stderr 归类：那两条
/// injector 侧可能一路全绿，拿它的日志猜只会把确定的事实退化成 fallback。
GalHookInjectorFailure? galHookFailureFromVoiceHookOpenError(String? token) =>
    switch (token?.trim().toLowerCase()) {
      'access_denied' => GalHookInjectorFailure.accessDenied,
      'protocol_mismatch' => GalHookInjectorFailure.protocolMismatch,
      _ => null,
    };

/// 把 `open` 失败的 native 一手事实压成一行诊断（token + win32 码 + 映射名/版本对照 +
/// 本次用的 helper 架构）。
///
/// 这一行会经 `GalHookInjectorDiagnostics.stderrTail` 的**最后一行**进入用户可见文案
/// （`galHookDiagnosticsDetail`），是「用户在另一台机器上截个图就能确诊」的唯一依据。
///
/// [injectorPath] 带上是因为 helper 是**按目标架构分目录**装的（`.../x86/` 与 `.../x64/`）：
/// 「同一台机器上一个游戏能捕获、另一个不能」最典型的成因就是两套 helper 只更新了一套，
/// 只有把这次实际用的那套架构打出来，才分得清是引擎问题还是装配问题。
String galHookOpenFailureDetail(
  Map<Object?, Object?>? response, {
  String? injectorPath,
}) {
  final Object? token = response?['error'];
  final Object? detail = response?['detail'];
  final List<String> parts = <String>['voice_hook open'];
  if (token is String && token.trim().isNotEmpty) {
    parts.add(token.trim());
  }
  if (detail is String && detail.trim().isNotEmpty) {
    parts.add(detail.trim());
  }
  final String arch = galHookHelperArchTag(injectorPath);
  if (arch.isNotEmpty) {
    parts.add('helper=$arch');
  }
  return parts.join(' ');
}

/// injector 可执行文件路径 → 它所属的 helper 架构目录名（`x86` / `x64`）。
///
/// 认不出来（路径为空、没有分目录）返回空串，绝不猜一个架构出来。
String galHookHelperArchTag(String? injectorPath) {
  final String path = injectorPath?.trim() ?? '';
  if (path.isEmpty) return '';
  final List<String> segments = path
      .split(RegExp(r'[\\/]'))
      .where((String segment) => segment.isNotEmpty)
      .toList();
  if (segments.length < 2) return '';
  final String parent = segments[segments.length - 2].toLowerCase();
  return (parent == 'x86' || parent == 'x64') ? parent : '';
}

/// 资源↔文本配对的时间窗（毫秒），**必须与 native 侧
/// `native/galgame_hook/hook/voice_resource_pairing.h` 的
/// `kKirikiriFollowingTextWindowMs` 同值**。
///
/// BUG-1159：两侧原本各写各的（native 1500 / Dart 1000），中间 500ms 是死区——native
/// 在 1500ms 内配上就把 `TextSlot::seq` 写进资源文件名，消费端却因为超出 1000ms 拒收；
/// 而带 marker 的资源**又被明确禁止**回退到时间窗兜底（见下方 `continue`），于是
/// 「打了标」反而比「没打标」更容易失败。两个常数没有任何交叉引用，漂移不会被发现，
/// 故在此固化同值并由 `test/mining/gal_voice_pairing_window_parity_test.dart`
/// 扫描 native 头文件守卫。
const int kGalVoicePairingWindowMs = kGalVoiceResourcePairingWindowMs;

/// galgame 纯人声配对（真机验证，docs/specs/galgame-mining）：具有运行时契约的引擎把
/// `TextSlot.seq` 写进资源名并优先按该稳定 ID 配对；显式 ID 不匹配时禁止回退时间猜测。
/// 旧资源仍是 `%TEMP%\fushi_gal_voice\<tickMs>_<basename>.ogg`
///（tickMs=GetTickCount64，与文本环 `TextSlot.timestamp_ms` 同源）。新版 Siglus
/// 资源导出会直接沿用当前文本 tick，
/// 因此先取 [exactToleranceMs] 内的同 tick 文件；旧引擎仍可能让语音先开流、文本约 220ms
/// 后显示，精确 tick 不存在时再在 `[textTsMs-windowHighMs, textTsMs-windowLowMs]` 内取离
/// `textTsMs-expectedOffsetMs` 最近者。BGM/SE/系统音始终排除。
///
/// 纯函数（只吃文件名列表 [oggFileNames]，不碰文件系统），可单测。无匹配返回 null。
///
/// 单值版 = [pickPairedVoiceOggs] 的首选那一个（判据完全同一份，不另写一套）。
String? pickPairedVoiceOgg({
  required List<String> oggFileNames,
  required int textTsMs,
  int? textEventId,
  int windowLowMs = 130,
  int windowHighMs = 330,
  int expectedOffsetMs = 220,
  int exactToleranceMs = 0,
  int eventIdToleranceMs = kGalVoicePairingWindowMs,
}) =>
    _firstOrNull(pickPairedVoiceOggs(
      oggFileNames: oggFileNames,
      textTsMs: textTsMs,
      textEventId: textEventId,
      windowLowMs: windowLowMs,
      windowHighMs: windowHighMs,
      expectedOffsetMs: expectedOffsetMs,
      exactToleranceMs: exactToleranceMs,
      eventIdToleranceMs: eventIdToleranceMs,
    ));

/// [pickPairedVoiceOgg] 的**全量**版本：同一句台词可能同时读入多个语音资源（BUG-1605
/// ——男女声优同台，引擎逐个打开各自的 OGG，hook 逐个 dump 成独立文件）。旧实现每层只
/// 留一个候选，于是制卡永远只带其中一个人的声音。
///
/// 「同一句」的判据分证据等级，**只有被证明的层才允许全取**：
///  - 事件 ID 层：文件名里带 native 写入的稳定 `TextSlot::seq`，等于引擎侧已经证明这些
///    资源属于这条文本 → 全取，按与文本时间戳的距离升序（同距按文件名，保证确定性）；
///  - 精确 tick 层：tick 与文本时间戳的差在 [exactToleranceMs]（默认 0，即同一毫秒）
///    之内 → 全取，同一毫秒读入多个资源本身就是同句同时播放的强证据；
///  - 偏移窗层：纯时间猜测（`[textTsMs-windowHighMs, textTsMs-windowLowMs]` 内离
///    `textTsMs-expectedOffsetMs` 最近者）→ **仍然只取一个**。没有归属证据就把窗内所有
///    文件都塞进卡里，只会把上一句的尾音、旁白、系统音一起带进来。
///
/// 层间仍是「高证据层命中就不看低层」，与单值版完全一致。无匹配返回空列表。
List<String> pickPairedVoiceOggs({
  required List<String> oggFileNames,
  required int textTsMs,
  int? textEventId,
  int windowLowMs = 130,
  int windowHighMs = 330,
  int expectedOffsetMs = 220,
  int exactToleranceMs = 0,
  int eventIdToleranceMs = kGalVoicePairingWindowMs,
}) {
  final int lo = textTsMs - windowHighMs;
  final int hi = textTsMs - windowLowMs;
  final int target = textTsMs - expectedOffsetMs;
  final List<_VoiceCandidate> eventHits = <_VoiceCandidate>[];
  final List<_VoiceCandidate> exactHits = <_VoiceCandidate>[];
  String? offsetBest;
  int offsetBestDist = 1 << 62;
  for (final String name in oggFileNames) {
    final GalVoiceResourceName? parsed = parseGalVoiceResourceName(name);
    if (parsed == null) {
      continue;
    }
    if (isGalNonVoiceBasename(parsed.basename)) {
      continue;
    }
    final int tick = parsed.tick;
    if (parsed.textEventId != null) {
      // KiriKiri 的资源先于文本，AI6 的 voice.arc 读取晚于文本；两者都由 native
      // 写入同一个稳定 TextSlot::seq。只有事件 ID 精确相等时才接受双向窄窗，
      // 带标资源仍绝不降级成“附近最新文件”猜给另一条文本。
      final int eventDist = (textTsMs - tick).abs();
      if (textEventId != null &&
          parsed.textEventId == textEventId &&
          eventDist <= eventIdToleranceMs) {
        eventHits.add(_VoiceCandidate(name, eventDist));
      }
      // 显式携带事件 ID 的资源不能再降级成“附近最新文件”猜给另一条文本。
      continue;
    }
    final int exactDist = (tick - textTsMs).abs();
    if (exactDist <= exactToleranceMs) {
      exactHits.add(_VoiceCandidate(name, exactDist));
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
  if (eventHits.isNotEmpty) return _rankedVoiceNames(eventHits);
  if (exactHits.isNotEmpty) return _rankedVoiceNames(exactHits);
  return offsetBest == null ? const <String>[] : <String>[offsetBest];
}

/// 以 [primaryName] 为主语音，从 [candidateNames] 里挑出**同一句台词**的其余配音
/// （BUG-1605）。纯函数（只吃文件名，不碰文件系统），可单测。
///
/// 归属证据分两级，都不是时间邻近猜测：
///  - 主资源带稳定事件 ID（`<tick>_fushi_textseq<seq>_<basename>`）→ 收同一事件 ID 的；
///  - 主资源没有事件 ID → 只收 tick **完全相同**、且同样没有事件 ID 的（同一毫秒被读入
///    等于同时播放）。带事件 ID 的资源在这条分支里被排除：它已被 native 绑给某条具体
///    文本，凑巧同 tick 不构成归属。
///
/// 返回**不含**主语音自身，按文件名升序（目录枚举顺序不保证，排序才让制卡结果可复现）。
/// 主资源名不可解析、或是 BGM/SE/系统音时返回空。
List<String> companionVoiceResourceNames({
  required String primaryName,
  required List<String> candidateNames,
}) {
  final GalVoiceResourceName? primary =
      parseGalVoiceResourceName(primaryName);
  if (primary == null || isGalNonVoiceBasename(primary.basename)) {
    return const <String>[];
  }
  final List<String> companions = <String>[];
  for (final String name in candidateNames) {
    if (name == primaryName) continue;
    final GalVoiceResourceName? other = parseGalVoiceResourceName(name);
    if (other == null || isGalNonVoiceBasename(other.basename)) continue;
    final bool sameEvent =
        primary.textEventId != null && other.textEventId == primary.textEventId;
    final bool sameTick = primary.textEventId == null &&
        other.textEventId == null &&
        other.tick == primary.tick;
    if (sameEvent || sameTick) companions.add(name);
  }
  companions.sort();
  return companions;
}

/// 配对候选：文件名 + 与文本时间戳的距离（越小越像“主语音”）。
class _VoiceCandidate {
  const _VoiceCandidate(this.name, this.distance);
  final String name;
  final int distance;
}

/// 距离升序、同距按文件名升序。第二判据不是洁癖：目录枚举顺序本就不保证，没有它
/// 「哪个是主语音」会随文件系统心情变，制卡结果就不可复现。
List<String> _rankedVoiceNames(List<_VoiceCandidate> candidates) {
  final List<_VoiceCandidate> sorted = List<_VoiceCandidate>.of(candidates)
    ..sort((_VoiceCandidate a, _VoiceCandidate b) => a.distance != b.distance
        ? a.distance.compareTo(b.distance)
        : a.name.compareTo(b.name));
  return <String>[for (final _VoiceCandidate c in sorted) c.name];
}

T? _firstOrNull<T>(List<T> items) => items.isEmpty ? null : items.first;

/// Unity 资源提取器在 AudioSource 播放入口以同一个 GetTickCount64 时钟写 WAV。相较 Siglus
/// 的 OGG 会固定早于文本约 220ms，Unity 文本/AudioClip 调用先后由引擎脚本决定，因此在
/// `T-1000..T+500ms` 内取离文本最近者。调用方始终先选资源 WAV，再退 Siglus OGG。
String? pickPairedUnityVoiceWav({
  required List<String> wavFileNames,
  required int textTsMs,
  int? textEventId,
  int beforeMs = 1000,
  int afterMs = 500,
  int eventIdToleranceMs = kGalVoicePairingWindowMs,
}) =>
    _firstOrNull(pickPairedUnityVoiceWavs(
      wavFileNames: wavFileNames,
      textTsMs: textTsMs,
      textEventId: textEventId,
      beforeMs: beforeMs,
      afterMs: afterMs,
      eventIdToleranceMs: eventIdToleranceMs,
    ));

/// [pickPairedUnityVoiceWav] 的全量版本（BUG-1605）。证据分层与
/// [pickPairedVoiceOggs] 同一纪律：带稳定事件 ID 的资源全取，纯时间窗只取最近一个。
///
/// 这里的时间窗刻意宽（`T-1000..T+500`，Unity 的文本/AudioClip 先后由引擎脚本决定），
/// 正因为宽，窗内多文件更可能混进上一句尾音或 SE——所以无标记时坚持单取。
List<String> pickPairedUnityVoiceWavs({
  required List<String> wavFileNames,
  required int textTsMs,
  int? textEventId,
  int beforeMs = 1000,
  int afterMs = 500,
  int eventIdToleranceMs = kGalVoicePairingWindowMs,
}) {
  final List<_VoiceCandidate> eventHits = <_VoiceCandidate>[];
  String? best;
  int bestDistance = 1 << 62;
  for (final String name in wavFileNames) {
    final GalVoiceResourceName? parsed = parseGalVoiceResourceName(name);
    if (parsed == null || isGalNonVoiceBasename(parsed.basename)) continue;
    final int distance = (parsed.tick - textTsMs).abs();
    if (parsed.textEventId != null &&
        textEventId != null &&
        parsed.textEventId == textEventId &&
        distance <= eventIdToleranceMs) {
      eventHits.add(_VoiceCandidate(name, distance));
    }
    // 注意这里**没有** OGG 层那句「带标资源不再降级成时间窗」：Unity 层一直是纯时间窗
    // 判定，把带标资源排除出兜底会让现有配对凭空失败。事件层只做加法。
    if (parsed.tick < textTsMs - beforeMs || parsed.tick > textTsMs + afterMs) {
      continue;
    }
    if (distance < bestDistance) {
      bestDistance = distance;
      best = name;
    }
  }
  if (eventHits.isNotEmpty) return _rankedVoiceNames(eventHits);
  return best == null ? const <String>[] : <String>[best];
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
}) =>
    _firstOrNull(pickPairedGameResources(
      oggFileNames: oggFileNames,
      wavFileNames: wavFileNames,
      textTsMs: textTsMs,
      textEventId: textEventId,
      latestSessionVoiceName: latestSessionVoiceName,
    ));

/// [pickPairedGameResource] 的全量版本（BUG-1605）：一句台词同时有多个角色配音时，
/// 引擎会为同一条文本读入多个语音资源，全部都属于这句话。
///
/// 容器层优先级不变（先 Unity WAV，再 Siglus/KiriKiri OGG）；层内是否允许全取由证据
/// 等级决定，见 [pickPairedVoiceOggs] / [pickPairedUnityVoiceWavs]。返回列表的**首元素
/// 就是单值版会选中的那一个**（主语音），后续元素是同句的其余配音。
List<String> pickPairedGameResources({
  required List<String> oggFileNames,
  required List<String> wavFileNames,
  required int textTsMs,
  int? textEventId,
  String? latestSessionVoiceName,
}) {
  if (textTsMs <= 0) {
    return latestSessionVoiceName == null
        ? const <String>[]
        : <String>[latestSessionVoiceName];
  }
  final List<String> wavs = pickPairedUnityVoiceWavs(
    wavFileNames: wavFileNames,
    textTsMs: textTsMs,
    textEventId: textEventId,
  );
  if (wavs.isNotEmpty) return wavs;
  return pickPairedVoiceOggs(
    oggFileNames: oggFileNames,
    textTsMs: textTsMs,
    textEventId: textEventId,
  );
}

/// 资源语音 dump 文件的**写入收敛门**（BUG-1109）。
///
/// hook DLL 在游戏读取语音资源时把原件写进 dump 目录：文件**出现**不等于**写完**。
/// 一看见文件就转码（[EngineHookGalAudioSource.grabPairedVoiceBytes]）或试听
/// （[EngineHookGalAudioSource.pairedVoiceFilePathForResourceId]），在流式落盘的引擎下
/// 只会拿到前半段——OGG 是分页容器，截断的文件照样能解码出前半段，于是表现为「有音频，
/// 但莫名少一截」而不是报错。
///
/// 因此转码/试听前先盯着文件大小，直到它**静默** [quietPeriod] 这么久才算写完。
///
/// 判据刻意不是「连续两次采样一致」：hook 是分块写的，块与块之间的间隙很容易比一个
/// 采样间隔长，两次相同只能证明「这一瞬间没在写」，照样会放行一个写到一半的文件。要
/// 求一整段静默期才是「写完了」的可落地近似。真正的根治要 hook 侧写 `.part` 再原子
/// rename（在独立仓 `hajisensai/hibiki-hook`，本仓消费端够不着），所以这里是消费端能
/// 做到的最强判据。
///
/// [staleAge] 是「早就写完了」的短路：dump 目录里绝大多数原件是历史文件（翻回旧台词
/// 试听、同一句重复播放），mtime 已经老过 [staleAge] 就直接放行，不必每次都白付一个
/// 静默期。阈值刻意远大于 [quietPeriod]：Windows 上正在被写的文件其目录项时间戳更新
/// 是懒惰的（句柄未关闭时按路径 stat 可能读到偏旧的 mtime），阈值太小会把「正在写」
/// 误判成「早写完」，反而把本函数短路成空操作。单句语音的落盘突发远短于 2s。
///
/// 到 [timeout] 仍在增长就 fail-open 用当前内容（Never break：宁可短一点，也不能一声
/// 不出）。stat 失败（文件被 [EngineHookGalAudioSource.pruneVoiceDump] 清掉等）立即
/// 返回，交调用方按缺文件处理。
Future<void> awaitStableVoiceDumpFile(
  File file, {
  Duration pollInterval = const Duration(milliseconds: 60),
  Duration quietPeriod = const Duration(milliseconds: 240),
  Duration timeout = const Duration(milliseconds: 1500),
  Duration staleAge = const Duration(seconds: 2),
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  int previous = -1;
  Duration lastChange = Duration.zero;
  while (elapsed.elapsed < timeout) {
    final int size;
    final DateTime modified;
    try {
      final FileStat stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound) return;
      size = stat.size;
      modified = stat.modified;
    } catch (_) {
      return;
    }
    if (size > 0 && DateTime.now().difference(modified) >= staleAge) {
      return;
    }
    if (size != previous) {
      previous = size;
      lastChange = elapsed.elapsed;
    } else if (size > 0 && elapsed.elapsed - lastChange >= quietPeriod) {
      return;
    }
    await Future<void>.delayed(pollInterval);
  }
}

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
  final bool hasSiglusLayout =
      File('${directory.path}${separator}Gameexe.dat').existsSync() &&
      File('${directory.path}${separator}Scene.pck').existsSync();
  if (hasSiglusLayout) {
    return true;
  }
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
///
/// [readyTimeoutMs] 必须来自调用方的握手超时（[EngineHookGalAudioSource] 的
/// `readyTimeout`）。injector 的 `--wait-ms` 默认只有 5000ms，而 Dart 侧等 30s：
/// 两个截止时间各自为政时，杀软扫描下的大 hook DLL 常在 native 先超时（native 此时
/// 还会把 CREATE_SUSPENDED 拉起的游戏丢在挂起态），Dart 却仍在傻等，最终只报一个
/// 没有原因的失败。超时只能有一个真相源，故显式下发。
///
/// [gameArguments] 是用户为该游戏配置的启动参数，**一个 token 一个 `--arg`**：
/// injector 按 Windows 规则重新转义后拼进 `CreateProcessW` 的 `lpCommandLine`，
/// 所以含空格/引号的参数也会原样成为游戏的一个 argv。空列表时**一个 `--arg` 都不发**，
/// 命令行与旧版逐字节相同 —— 老 injector（用户尚未更新 helper）遇到不认识的 flag 是
/// 静默忽略而非报错，但「不配置就不发」仍是更硬的兼容保证。
///
/// [workdir] 是游戏工作目录；空串时不发 `--workdir`，由 injector 缺省成 exe 所在目录
/// （与旧行为一致）。
List<String> buildEngineHookInjectorArguments({
  required int targetPid,
  required String? launchExe,
  GalNativeLoopbackPolicy nativeLoopbackPolicy = GalNativeLoopbackPolicy.deny,
  List<String> gameArguments = const <String>[],
  String workdir = '',
  bool japaneseLocale = false,
  bool lunaPcHooks = false,
  int? lunaCodepage,
  String? lunaHookProfilePath,
  List<String> lunaHookCodes = const <String>[],
  int readyTimeoutMs = 30000,
  String? unityRuntimeDirectory,
}) {
  final String? exe = launchExe;
  final bool launchMode = exe != null && exe.isNotEmpty;
  final List<String> args = launchMode
      ? <String>['--launch', exe, '--hold']
      : <String>['--pid', '$targetPid', '--hold'];
  // v16 fail-closed contract: the helper default is deny, but the host still
  // spells out every decision. This keeps launch/attach/retry auditable and
  // prevents an old implicit default from silently becoming capture-capable.
  args.addAll(<String>[
    '--native-loopback-policy',
    nativeLoopbackPolicy.cliValue,
  ]);
  if (readyTimeoutMs > 0) {
    args.addAll(<String>['--wait-ms', '$readyTimeoutMs']);
  }
  // Unity 资源提取运行时留在安装目录（140 MB，不进注入运行时副本），所以 injector 不能
  // 再按「自身目录」去找它——它自身现在跑在副本目录里（BUG-1708）。位置显式下发。
  // 不传 = 该架构没有提取运行时，injector 按无提取能力运行（与 x86 分发包一致）。
  if (unityRuntimeDirectory != null && unityRuntimeDirectory.isNotEmpty) {
    args.addAll(<String>['--unity-runtime', unityRuntimeDirectory]);
  }
  if (launchMode && japaneseLocale) {
    args.add('--japanese-locale');
  }
  // workdir / --arg 都是 launch 专用：attach 模式游戏已经在跑，进程创建参数无从谈起。
  if (launchMode && workdir.isNotEmpty) {
    args.addAll(<String>['--workdir', workdir]);
  }
  if (launchMode) {
    for (final String argument in gameArguments) {
      args.addAll(<String>['--arg', argument]);
    }
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

/// capability 探测的三态结果。
///
/// 「答了但没这个能力」和「根本没答上来」必须分开：前者是组件版本旧、只能换版本；
/// 后者是这台机器上 helper 拉不起来或没响应（杀软删档/权限不足/进程挂住），换版本
/// 一点用没有。合成一个 bool 就只能二选一地误报，而误报的那一半会把用户引向一个
/// 做了也没用的动作。
enum GalHookCapabilityProbeResult {
  /// helper 跑起来了，并明确应答了 v16 capability。
  supported,

  /// helper 跑起来也答了，但答案里没有这个 capability——组件比本体旧。
  unsupported,

  /// helper 没能给出答案：拉不起来、崩了、或超时没退出。
  probeFailed,
}

/// capability 探测的硬上限。探测是**目标无关**的一次性子进程调用，正常在毫秒级返回；
/// 没有这个上限，helper 一挂住 `start()` 就永不返回，`_audioFallbackPolicyQueue`
/// 随之永久堵死（串行队列在等这一个 job）。
const Duration kGalHookCapabilityProbeTimeout = Duration(seconds: 5);

/// Whether the installed injector proves the v16 fail-closed native loopback
/// contract without opening or injecting any target process.
typedef GalHookCapabilitiesProbe = Future<GalHookCapabilityProbeResult>
    Function(String executable);

enum GalNativeLoopbackPolicy {
  deny,
  allow;

  String get cliValue => name;
}

const String kGalNativeLoopbackPolicyCapability = 'native_loopback_policy_v1';

/// The capability output is deliberately an exact, single-token contract.
/// Accepting a substring would let an error message or an older multi-line
/// helper accidentally pass the safety gate.
bool hasGalNativeLoopbackPolicyCapability({
  required int exitCode,
  required Object? stdout,
}) =>
    exitCode == 0 &&
    stdout is String &&
    stdout.trim() == kGalNativeLoopbackPolicyCapability;

Future<GalHookCapabilityProbeResult> _probeGalHookCapabilities(
  String executable,
) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      const <String>['--capabilities'],
      runInShell: false,
    );
  } on ProcessException {
    return GalHookCapabilityProbeResult.probeFailed;
  }
  // 必须自己起进程而不是用 Process.run：`Process.run(...).timeout(...)` 只是放弃
  // 等待，子进程照样活着、管道照样被引用，挂住的 helper 会一直挂着。这里超时后
  // 真的把它杀掉。
  final Future<String> stdoutText =
      process.stdout.transform(utf8.decoder).join();
  final Future<void> drainedStderr = process.stderr.drain<void>();
  try {
    final int exitCode =
        await process.exitCode.timeout(kGalHookCapabilityProbeTimeout);
    final String stdout =
        await stdoutText.timeout(kGalHookCapabilityProbeTimeout);
    await drainedStderr.timeout(kGalHookCapabilityProbeTimeout);
    return hasGalNativeLoopbackPolicyCapability(
      exitCode: exitCode,
      stdout: stdout,
    )
        ? GalHookCapabilityProbeResult.supported
        : GalHookCapabilityProbeResult.unsupported;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return GalHookCapabilityProbeResult.probeFailed;
  } on ProcessException {
    return GalHookCapabilityProbeResult.probeFailed;
  }
}

typedef GalHookProcessOutputSink = void Function(
  bool isStderr,
  String chunk,
);

/// 转区 `auto` 的证据探测器签名（BUG-2047）。[exePath] 是 launch 的 exe，[language]
/// 是该游戏声明的内容语言（null = 未声明）。
typedef GalJapaneseLocaleNeedProbe = Future<GalJapaneseLocaleVerdict> Function(
  String exePath,
  String? language,
);

Future<GalJapaneseLocaleVerdict> _defaultJapaneseLocaleNeedProbe(
  String exePath,
  String? language,
) =>
    probeGalJapaneseLocaleNeed(exePath: exePath, language: language);

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
///   ② 经 `app.fushi.reader/voice_hook` MethodChannel 让 hibiki.exe 自己的 native **读**注入
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
    this.launchArguments = const <String>[],
    this.launchWorkdir = '',
    required this.injectorPath,
    this.japaneseLocaleMode = kGalDefaultJapaneseLocaleMode,
    this.contentLanguage,
    this.systemAnsiCodePageProbe = readSystemAnsiCodePage,
    this.japaneseLocaleNeedProbe = _defaultJapaneseLocaleNeedProbe,
    this.lunaPcHooks = false,
    this.lunaCodepage,
    this.lunaHookProfilePath,
    this.lunaHookCodes = const <String>[],
    GalNativeLoopbackPolicy nativeLoopbackPolicy = GalNativeLoopbackPolicy.deny,
    MethodChannel? channel,
    GalHookProcessStarter? processStarter,
    GalHookCapabilitiesProbe? capabilitiesProbe,
    GalHookProcessOutputSink? processOutputSink,
    GalVoiceDumpIndex? voiceDumpIndex,
    Duration readyTimeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(milliseconds: 200),
    Duration nativeLoopbackPolicyTimeout = const Duration(seconds: 5),
  })  : _channel =
            channel ?? const MethodChannel('app.fushi.reader/voice_hook'),
        _processStarter = processStarter ?? _startGalHookProcess,
        _capabilitiesProbe = capabilitiesProbe ?? _probeGalHookCapabilities,
        _processOutputSink = processOutputSink ?? _logGalHookProcessOutput,
        _voiceDumpIndex = voiceDumpIndex ??
            GalVoiceDumpIndex(directory: _defaultGalVoiceDumpDirectory()),
        _readyTimeout = readyTimeout,
        _pollInterval = pollInterval,
        _nativeLoopbackPolicyTimeout = nativeLoopbackPolicyTimeout,
        _nativeLoopbackPolicy = nativeLoopbackPolicy;

  /// **attach 模式**目标游戏进程 PID（注入对象）。仅 [launchExe] 为空时用；<=0 且无
  /// [launchExe] 视为无目标 -> 源不可用。
  final int targetPid;

  /// **launch 模式**要拉起的游戏 exe 绝对路径。非空即走 `injector --launch`，从 injector
  /// stdout 解析子进程 PID。null -> 走 attach（[targetPid]）。
  final String? launchExe;

  /// **launch 模式**追加给游戏 exe 的命令行参数，一个元素 = 游戏侧一个 argv。
  /// 空列表（默认）= 不发任何 `--arg`，启动命令行与旧版逐字节相同。
  final List<String> launchArguments;

  /// **launch 模式**游戏工作目录；空串（默认）= 不发 `--workdir`，由 injector 缺省成
  /// exe 所在目录（旧行为）。
  final String launchWorkdir;

  /// injector 可执行文件绝对路径（随 app 分发 / 按需下载）；null 或文件不存在 -> 源不可用
  /// （降级回 loopback，绝不假装注入成功）。**位数必须匹配目标游戏**（KiriKiriZ 多 32 位 -> x86）。
  final String? injectorPath;

  /// 该游戏的日语区域（转区）档位。转区只影响 injector 创建的游戏进程，不修改
  /// Windows 全局区域设置；attach 模式必然短路。运行库缺失时 native helper 会记录
  /// 诊断并安全回退普通启动。
  ///
  /// BUG-1477：这里以前是一个恒为 true 且**没有任何实例化点会传**的 bool，判据是
  /// 「launch && 该 bool && exe 是 32 位」——「32 位」被当成了「日文原版」的代理。
  /// 汉化版恰好落在最坏格（32 位老引擎 + 已转成 GBK/UTF-8 的字符串），套 CP932
  /// 让游戏 `MultiByteToWideChar(CP_ACP, ...)` 解出非法序列，字体/字表索引越界闪退，
  /// 而用户没有任何开关可以关掉它。
  final GalJapaneseLocaleMode japaneseLocaleMode;

  /// 该游戏的内容语言（`GalgameEntry.language`，BCP-47；null = 未声明）。
  /// 转区 `auto` 判定里唯一的人工真值：声明了就压过一切自动证据（BUG-2047）。
  final String? contentLanguage;

  /// 读宿主机 ANSI 代码页（可注入，便于单测）。
  final int? Function() systemAnsiCodePageProbe;

  /// 「这个游戏需不需要 CP932」的证据探测（可注入，便于单测）。默认走
  /// [probeGalJapaneseLocaleNeed] 的有界离线探测；只在 launch + `auto` 时调用。
  final GalJapaneseLocaleNeedProbe japaneseLocaleNeedProbe;

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
  final GalHookCapabilitiesProbe _capabilitiesProbe;
  final GalHookProcessOutputSink _processOutputSink;
  final GalVoiceDumpIndex _voiceDumpIndex;
  final Duration _readyTimeout;
  final Duration _pollInterval;
  final Duration _nativeLoopbackPolicyTimeout;

  GalNativeLoopbackPolicy _nativeLoopbackPolicy;
  bool _mappingOpen = false;
  bool _startInProgress = false;
  Completer<bool>? _mappingOpenCompleter;
  Future<void>? _stopInFlight;

  GalNativeLoopbackPolicy get nativeLoopbackPolicy => _nativeLoopbackPolicy;

  /// Remember a policy before [start] builds the injector command line.
  /// This is synchronous by design so the controller can restore per-game
  /// settings before launch/attach/retry without opening any native resource.
  void rememberNativeLoopbackPolicy(GalNativeLoopbackPolicy policy) {
    _nativeLoopbackPolicy = policy;
  }

  /// 拉起的 injector 子进程句柄（[stop] 时杀掉）。
  Process? _injector;
  final List<StreamSubscription<String>> _injectorOutputSubscriptions =
      <StreamSubscription<String>>[];
  Completer<int?>? _hookedPidCompleter;

  /// injector 诊断输出尾部（stdout+stderr 合流，有界）。失败时唯一的证据来源：
  /// native 早就把「位数不匹配 / OpenProcess 失败 / 未收到就绪信号」打出来了，
  /// 旧实现只送进 debugPrint，release 包等于丢弃。
  final StringBuffer _diagnosticsBuffer = StringBuffer();
  static const int _diagnosticsTailMax = 2048;

  GalHookInjectorDiagnostics _lastFailure = const GalHookInjectorDiagnostics();

  /// 最近一次 [start] 失败的结构化诊断；成功后为 [GalHookInjectorFailure.none]。
  GalHookInjectorDiagnostics get lastFailure => _lastFailure;

  bool _japaneseLocaleApplied = false;

  /// 本局**实际**是否给游戏套了日文区域（CP932），而不是用户选了哪个档位。
  ///
  /// 两者不是一回事：`auto` 下真正的结果由 [resolveJapaneseLocale] 现算（系统 ACP +
  /// 目标位数），用户在设置里看到的只是「自动」。而 `auto` 判错的代价是不对称的——
  /// 多语言版 / 汉化版被误转区时，游戏自己的 GBK/UTF-8 字符串会被按 CP932 解出非法
  /// 序列，症状从窗口标题乱码到脚本加载失败都有，且**没有一处告诉用户是转区干的**。
  ///
  /// [resolveJapaneseLocale] 的注释已经论证过 `auto` 不可能总判对、真正兜底的是用户
  /// 手动选 [GalJapaneseLocaleMode.off]。可兜底的前提是用户够得着：先得知道本局到底
  /// 转没转。所以这个事实必须离开本类，一路走到会话状态与诊断里。
  bool get japaneseLocaleApplied => _japaneseLocaleApplied;

  GalJapaneseLocaleVerdict? _japaneseLocaleVerdict;

  /// `auto` 档本局的判定结论与证据；attach / `on` / `off` 不判定，为 null。
  ///
  /// 与 [japaneseLocaleApplied] 在 [start] 的同一处赋值：命令行里的 `--japanese-locale`
  /// 是按这个结论算出来的，会话卡上列的「判据」必须就是它，不能另算一份。
  GalJapaneseLocaleVerdict? get japaneseLocaleVerdict => _japaneseLocaleVerdict;

  GalJapaneseLocaleSkipReason? _japaneseLocaleSkipReason;

  /// `auto` 档判定后没转区的原因（语义门 / 工程门）；转了、或不是 `auto`，为 null。
  /// 与 [japaneseLocaleVerdict] 同处赋值、同处复位。
  GalJapaneseLocaleSkipReason? get japaneseLocaleSkipReason =>
      _japaneseLocaleSkipReason;

  /// 探测器抛了也只是「没答上来」：结论 unknown ⇒ 不转区，启动照常。
  Future<GalJapaneseLocaleVerdict> _judgeJapaneseLocaleNeed(String exe) async {
    try {
      return await japaneseLocaleNeedProbe(exe, contentLanguage);
    } on Object {
      return GalJapaneseLocaleVerdict.unknown;
    }
  }

  int _launchedPid = 0;

  /// launch 模式下 injector 回报的**已创建**游戏 PID（`LAUNCH pid=`）。注入是否成功
  /// 与此无关：拿到它就说明游戏进程真的起来了，调用方据此改走附着重试，而不是把
  /// 正在运行的游戏报成启动失败。旧 helper 不回报时为 null。
  int? get launchedPid => _launchedPid > 0 ? _launchedPid : null;

  /// 实际注入命中的游戏 PID：attach=`targetPid`；launch=从 injector stdout 解析出的子进程 PID。
  /// [grabRecent]/`open` 都用它开共享内存。
  int _effectivePid = 0;

  /// 本次 injector 会话起点。Siglus 晚附着可能抓不到文本时间戳，制卡时只允许用本会话之后
  /// 新落盘的最新 Ogg，避免误配上一局残留。
  DateTime? _sessionStartedAt;

  static const int _voicePairingCacheLimit = 512;
  int _voicePairingCacheRevision = -1;
  final Map<
      ({
        int textTsMs,
        int? textEventId,
        bool allowLatestSessionFallback,
      }), List<String>> _voicePairingCache = <
      ({
        int textTsMs,
        int? textEventId,
        bool allowLatestSessionFallback,
      }), List<String>>{};

  /// 注入命中的游戏进程 PID（[start] 成功后有效）；未就绪返回 null。launch 模式下调用方据此
  /// 找游戏主窗口（截图用），因为拉起游戏的是本源、PID 只有它知道。
  int? get gamePid => _effectivePid > 0 ? _effectivePid : null;

  /// helper 已完成注入且文本 hook 可用，但当前引擎没有暴露可读 PCM/原始语音时为 true。
  /// 上层据此保留本实例继续轮询文本，同时另启系统 Loopback 作为音频源。
  bool get textHookReady => _textHookReady;
  bool get rawVoiceReady => _rawVoiceReady;

  /// v13 文本分道的容量事实（native 累计计数）。
  ///
  /// [textLaneOverflows] 大于 0 = 道用尽且连可回收的道都没有，**有台词被丢了**。它必须
  /// 一路走到诊断里：道满的症状（某些线程的台词就是不来）与 v13 要根治的 256 槽挤压
  /// 完全同形，真机上没有这个数就分不出「分道没生效」和「道不够用」，而放开非胜出线程
  /// 本身就抬高了道满概率。[textLaneRecycles] 是降级但未丢行的那一级（回收了最久没写的
  /// 非选定道），单独计数才能看出压力是从哪一级开始的。
  int get textLaneRecycles => _textLaneRecycles;
  int get textLaneOverflows => _textLaneOverflows;

  /// 引擎侧两个 XAudio2 诊断字的原样快照（粘性 or 位，只会置位不会清零）。
  ///
  /// [xaudioDiagnostics2] 是第二个字，装的不是队列状态而是**身份分型位**：SGRE 家族/
  /// 锚点是否解出、Leaf 的 exe 摘要是否匹配、结构门断在哪一组（section roles / 各锚点 /
  /// return sites）。没有它，「这台机器为什么整场语音降级 Loopback」在真机上只能猜——
  /// 而 hook 侧每一条失败路径都老老实实置了位。
  int get xaudioDiagnostics => _xaudioDiagnostics;
  int get xaudioDiagnostics2 => _xaudioDiagnostics2;

  /// 共享内存已通过与 [start] **完全相同**的就绪门（`ready` + 有效 PCM 格式）时的格式。
  ///
  /// null 只说明「游戏还没播过语音」，不说明 hook 没装上（那看 [textHookReady] 与 native
  /// 的 `audioHooksReady`）。控制器据此在会话运行中把降级的 Loopback 升格回引擎 PCM
  /// （BUG-1100）。判据必须是这道就绪门：直接看 `parseGalPcmFormat` 会把未过门的残留
  /// 碎片当成可用 PCM，那正是 BUG-1060 已修掉的回归。
  PcmFormat? get readyPcmFormat => _readyFormat;

  /// [readyPcmFormat] 的布尔别名。
  bool get pcmReady => _readyFormat != null;
  bool _textHookReady = false;
  bool _audioHooksReady = false;
  bool _rawVoiceReady = false;
  int _textLaneRecycles = 0;
  int _textLaneOverflows = 0;
  int _xaudioDiagnostics = 0;
  int _xaudioDiagnostics2 = 0;
  PcmFormat? _readyFormat;

  /// 查目标进程 [pid] 是否 32 位（WOW64）。hibiki.exe 是 64 位，故 native `IsWow64Process`
  /// 为 true 即目标为 32 位（多数 KiriKiri galgame），调用方据此选 x86 注入器（DLL 位数必须
  /// 匹配目标进程，否则注入失败）。native 缺失 / 查询失败 / pid<=0 返回 null（调用方降级）。
  static Future<bool?> targetIsWow64(int pid, {MethodChannel? channel}) async {
    if (pid <= 0) {
      return null;
    }
    final MethodChannel ch =
        channel ?? const MethodChannel('app.fushi.reader/voice_hook');
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

  static int _nativePolicyWord(Map<Object?, Object?> status, String key) {
    final Object? value = status[key];
    return value is int ? value : -1;
  }

  static bool _nativePolicyAcknowledged(
    Map<Object?, Object?> status, {
    required GalNativeLoopbackPolicy policy,
    required int requestSeq,
  }) {
    if (requestSeq <= 0 ||
        _nativePolicyWord(status, 'nativeLoopbackRequestSeq') != requestSeq ||
        _nativePolicyWord(status, 'nativeLoopbackAppliedSeq') != requestSeq) {
      return false;
    }
    final int requested = _nativePolicyWord(status, 'nativeLoopbackRequested');
    final int state = _nativePolicyWord(status, 'nativeLoopbackState');
    return switch (policy) {
      GalNativeLoopbackPolicy.deny => requested == 0 && state == 0,
      GalNativeLoopbackPolicy.allow => requested == 1 && state == 2,
    };
  }

  /// Publish a runtime native-loopback policy and wait for the DLL lifecycle
  /// acknowledgement. `deny` completes only after the worker is stopped and
  /// reaped; `allow` completes only when it is running. This method controls
  /// capture only—it never touches the game's render/output audio API.
  ///
  /// During injection, callers wait for [open] instead of returning early, so
  /// a full→clean switch cannot lose the source merely because it is between
  /// process spawn and shared-memory open. A newer request supersedes an older
  /// waiter; the older waiter then exits without re-publishing stale policy.
  Future<bool> requestNativeLoopbackPolicy(
    GalNativeLoopbackPolicy policy,
  ) async {
    _nativeLoopbackPolicy = policy;
    if (!_mappingOpen) {
      final Completer<bool>? opened = _mappingOpenCompleter;
      if (!_startInProgress || opened == null) {
        return true; // remembered for the next injector command line
      }
      if (!await opened.future || !_mappingOpen) {
        return policy == GalNativeLoopbackPolicy.deny;
      }
    }

    while (_mappingOpen && _nativeLoopbackPolicy == policy) {
      Map<Object?, Object?>? requested;
      try {
        requested = await _channel.invokeMethod<Map<Object?, Object?>>(
          'requestNativeLoopbackPolicy',
          <String, Object?>{'policy': policy.cliValue},
        );
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false;
      }
      if (requested == null || requested['error'] != null) return false;
      final int requestSeq =
          _nativePolicyWord(requested, 'nativeLoopbackRequestSeq');
      if (requestSeq <= 0) return false;

      final Stopwatch wait = Stopwatch()..start();
      Map<Object?, Object?> status = requested;
      while (_mappingOpen && wait.elapsed < _nativeLoopbackPolicyTimeout) {
        if (_nativePolicyAcknowledged(
          status,
          policy: policy,
          requestSeq: requestSeq,
        )) {
          return true;
        }
        // The applied generation reached this request but allow failed. The
        // helper has already cleaned up; do not pretend capture is running.
        if (policy == GalNativeLoopbackPolicy.allow &&
            _nativePolicyWord(status, 'nativeLoopbackAppliedSeq') ==
                requestSeq &&
            _nativePolicyWord(status, 'nativeLoopbackState') == 4) {
          return false;
        }
        if (_nativeLoopbackPolicy != policy) return true;
        final int observedRequest =
            _nativePolicyWord(status, 'nativeLoopbackRequestSeq');
        if (observedRequest > 0 && observedRequest != requestSeq) {
          break; // superseded externally; re-publish only if still desired
        }
        if (_pollInterval > Duration.zero) {
          await Future<void>.delayed(_pollInterval);
        }
        try {
          final Map<Object?, Object?>? next =
              await _channel.invokeMethod<Map<Object?, Object?>>('status');
          if (next == null || next['error'] != null) return false;
          status = next;
        } on PlatformException {
          return false;
        } on MissingPluginException {
          return false;
        }
      }
      if (_nativeLoopbackPolicy != policy) return true;
      if (!_mappingOpen) return policy == GalNativeLoopbackPolicy.deny;
      if (wait.elapsed >= _nativeLoopbackPolicyTimeout) return false;
    }
    return policy == GalNativeLoopbackPolicy.deny ||
        _nativeLoopbackPolicy != policy;
  }

  void _finishStartWait({required bool opened}) {
    _startInProgress = false;
    final Completer<bool>? completer = _mappingOpenCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(opened);
    }
  }

  @override
  Future<PcmFormat?> start() async {
    _startInProgress = true;
    await _voiceDumpIndex.stopSession();
    _clearVoicePairingCache();
    _mappingOpen = false;
    _mappingOpenCompleter = Completer<bool>();
    _textHookReady = false;
    _audioHooksReady = false;
    _rawVoiceReady = false;
    _readyFormat = null;
    _launchedPid = 0;
    _japaneseLocaleApplied = false;
    _japaneseLocaleVerdict = null;
    _japaneseLocaleSkipReason = null;
    _diagnosticsBuffer.clear();
    _lastFailure = const GalHookInjectorDiagnostics();
    final String? path = injectorPath;
    if (path == null || !File(path).existsSync()) {
      _lastFailure = const GalHookInjectorDiagnostics(
        failure: GalHookInjectorFailure.helperMissing,
      );
      _finishStartWait(opened: false);
      return null; // 无 injector -> 降级
    }
    final String? exe = launchExe;
    final bool launchMode = exe != null && exe.isNotEmpty;
    if (!launchMode && targetPid <= 0) {
      _lastFailure = const GalHookInjectorDiagnostics(
        failure: GalHookInjectorFailure.targetMissing,
      );
      _finishStartWait(opened: false);
      return null; // 既无 launchExe 又无有效 targetPid -> 无目标
    }
    // Safety gate: old helpers silently ignore unknown flags. Prove the exact
    // v16 capability in a target-free process before we ever spawn an
    // injection command; no capability means no launch, attach, or retry.
    GalHookCapabilityProbeResult capability =
        GalHookCapabilityProbeResult.probeFailed;
    try {
      capability = await _capabilitiesProbe(path);
    } on Object {
      // 探测器自身抛出（含注入的测试替身）也只是「没答上来」，不是「组件太老」。
      // 兜住异常是为了不毒化调用它的串行队列，但兜住之后必须如实归类。
      capability = GalHookCapabilityProbeResult.probeFailed;
    }
    if (capability != GalHookCapabilityProbeResult.supported) {
      final bool tooOld =
          capability == GalHookCapabilityProbeResult.unsupported;
      _lastFailure = GalHookInjectorDiagnostics(
        // 处置相反：unsupported 只能换版本；probeFailed 要查杀软/权限/挂住的进程。
        failure: tooOld
            ? GalHookInjectorFailure.protocolMismatch
            : GalHookInjectorFailure.capabilityProbeFailed,
        stderrTail: tooOld
            ? 'injector capability native_loopback_policy_v1 unavailable'
            : 'injector capability probe produced no answer',
      );
      _finishStartWait(opened: false);
      return null;
    }
    _sessionStartedAt = DateTime.now();
    // `auto` 先问语义（BUG-2047）：只有 launch 模式才可能转区，也只有 auto 才需要证据；
    // 探测是有界离线 IO，失败一律当 unknown ⇒ 不转区，绝不阻塞启动。
    final GalJapaneseLocaleVerdict? verdict =
        launchMode && japaneseLocaleMode == GalJapaneseLocaleMode.auto
            ? await _judgeJapaneseLocaleNeed(exe)
            : null;
    final bool is32Bit = launchMode && await exeIs32Bit(exe) == true;
    final int? systemAnsiCodePage = systemAnsiCodePageProbe();
    final bool japaneseLocale = resolveJapaneseLocale(
      mode: japaneseLocaleMode,
      launchMode: launchMode,
      is32Bit: is32Bit,
      systemAnsiCodePage: systemAnsiCodePage,
      need: verdict?.need ?? GalJapaneseLocaleNeed.unknown,
    );
    // 在传给 injector 的同一处记账：命令行里的 `--japanese-locale` 与这三个字段必须同源，
    // 否则「诊断说没转区、进程其实转了」这种分叉比不诊断更糟。
    _japaneseLocaleApplied = japaneseLocale;
    _japaneseLocaleVerdict = verdict;
    _japaneseLocaleSkipReason = verdict == null || japaneseLocale
        ? null
        : resolveJapaneseLocaleSkipReason(
            need: verdict.need,
            is32Bit: is32Bit,
            systemAnsiCodePage: systemAnsiCodePage,
          );
    // 1. 拉起 injector 子进程（注入报毒代码只在这个隔离子进程里执行）。
    //    launch 模式：`--launch <exe>` CREATE_SUSPENDED 早注入，从 stdout 解析子进程 PID；
    //    attach 模式：`--pid <PID>` 附着已运行进程。
    try {
      _injector = await _processStarter(
        path,
        buildEngineHookInjectorArguments(
          targetPid: targetPid,
          launchExe: exe,
          nativeLoopbackPolicy: _nativeLoopbackPolicy,
          gameArguments: launchArguments,
          workdir: launchWorkdir,
          japaneseLocale: japaneseLocale,
          lunaPcHooks: lunaPcHooks,
          lunaCodepage: lunaCodepage,
          lunaHookProfilePath: lunaHookProfilePath,
          lunaHookCodes: lunaHookCodes,
          readyTimeoutMs: _readyTimeout.inMilliseconds,
          unityRuntimeDirectory:
              GalgameHookRuntimeStage.instance.unityRuntimeDirectory(
            arch: galHookHelperArchTag(path),
          ),
        ),
      );
    } on ProcessException catch (error) {
      _lastFailure = GalHookInjectorDiagnostics(
        failure: GalHookInjectorFailure.spawnFailed,
        stderrTail: error.message,
      );
      _finishStartWait(opened: false);
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
      // 启动/注入失败（目标不符 / 位数不符 / 超时）。先把 native 的诊断和退出码
      // 定格成结构化原因，再 stop()——stop 会杀掉进程并清空缓冲，顺序反了就没证据了。
      await _captureFailure(
        fallback: hookedPid == null
            ? GalHookInjectorFailure.readyTimeout
            : GalHookInjectorFailure.unknown,
      );
      await stop();
      return null;
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
        // native 已经说清是哪一种打不开（拒绝访问 / 版本不符 / 映射不存在），这里**只转述
        // 不猜测**：原因取 token 归类，一手事实（win32 码 / 映射名 / 双方版本）原样带进诊断。
        await _captureFailure(
          fallback: GalHookInjectorFailure.sharedMemoryUnavailable,
          resolved: galHookFailureFromVoiceHookOpenError(
            opened?['error'] as String?,
          ),
          nativeDetail: opened == null
              ? ''
              : galHookOpenFailureDetail(opened, injectorPath: path),
        );
        await stop();
        return null;
      }
      _mappingOpen = true;
      // Arm the dump index only after this engine session owns a live native
      // mapping. stopSession is terminal for the session: late poll/prune
      // futures may synchronize, but cannot resurrect its watcher.
      unawaited(_voiceDumpIndex.startSession());
      final Completer<bool>? mappingOpen = _mappingOpenCompleter;
      if (mappingOpen != null && !mappingOpen.isCompleted) {
        mappingOpen.complete(true);
      }
    } on PlatformException catch (error) {
      await _captureFailure(
        fallback: GalHookInjectorFailure.sharedMemoryUnavailable,
        nativeDetail: 'voice_hook open platform_exception '
                '${error.code} ${error.message ?? ''}'
            .trim(),
      );
      await stop();
      return null;
    } on MissingPluginException {
      await _captureFailure(
        fallback: GalHookInjectorFailure.sharedMemoryUnavailable,
        nativeDetail: 'voice_hook open missing_plugin',
      );
      await stop();
      return null;
    }
    // Re-publish after Open even though the injector set the initial CLI
    // policy. A policy change while injection was in flight must win, and the
    // returned acknowledgement is the only proof of the DLL's actual state.
    final GalNativeLoopbackPolicy desiredPolicy = _nativeLoopbackPolicy;
    if (!await requestNativeLoopbackPolicy(desiredPolicy)) {
      await _captureFailure(
        fallback: GalHookInjectorFailure.handshakeTimeout,
        nativeDetail:
            'native loopback policy ${desiredPolicy.cliValue} was not applied',
      );
      await stop();
      return null;
    }
    _finishStartWait(opened: true);
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < _readyTimeout) {
      final PcmFormat? fmt = await _pollFormat();
      if (fmt != null) {
        return fmt;
      }
      // Luna 文本线程可能先于 DLL 音频工作线程出现。必须等首轮音频探针完成后，才把
      // “文本-only”交给控制器组合 Loopback；否则 Siglus 原始 OVK hook 会被启动竞态
      // 误判为不可用。helper 仍会保留，因此后续资源语音始终优先于 Loopback。
      //
      // BUG-1100：这里返回 null **只代表「此刻还没有可用 PCM」**，不代表这局都没有。
      // 游戏刚启动、一句语音都还没播时共享内存里本就没有格式，等满 [_readyTimeout]
      // 只会白白拖慢文本上屏。控制器据此先用 Loopback 顶着，并在会话运行中持续复查
      // [readyPcmFormat]，首句语音出现即把主音源升格回引擎 PCM。
      if (_textHookReady && _audioHooksReady) {
        return null;
      }
      await Future<void>.delayed(_pollInterval);
    }
    // 超时未就绪（未注入成功 / 该引擎无捕获）：降级。
    await _captureFailure(fallback: GalHookInjectorFailure.handshakeTimeout);
    await stop();
    return null;
  }

  /// 定格本次失败：把 injector 诊断尾部分类成结构化原因，并尽力取回退出码。
  ///
  /// injector 在 `--hold` 模式下失败即退出，因此这里等一个很短的窗口取 exitCode；
  /// 进程仍存活（例如握手超时但 helper 还在跑）时退出码为 null，不阻塞调用方。
  /// [resolved] 非空表示**原因已由 native 一手确定**（`open` 返回的结构化 token），此时
  /// 不再拿 injector stderr 去猜：injector 那边可能一路 `OK hooked` 全绿，失败发生在它之后
  /// 的读侧边界上，用它的日志分类只会把确定的事实退化成 fallback。
  ///
  /// [nativeDetail] 追加到诊断**末行**：`galHookDiagnosticsDetail` 取最后一行作结论，这样
  /// 读侧失败的一手证据（win32 码 / 双方版本）能一路走到用户看见的那句话里。
  Future<void> _captureFailure({
    required GalHookInjectorFailure fallback,
    GalHookInjectorFailure? resolved,
    String nativeDetail = '',
  }) async {
    final Process? process = _injector;
    int? exitCode;
    if (process != null) {
      exitCode = await process.exitCode
          .timeout(const Duration(milliseconds: 400), onTimeout: () => -1)
          .then((int code) => code == -1 ? null : code)
          .catchError((Object _) => null);
    }
    final String injectorTail = _diagnosticsBuffer.toString().trim();
    final String detail = nativeDetail.trim();
    final String tail = <String>[injectorTail, detail]
        .where((String part) => part.isNotEmpty)
        .join('\n');
    _lastFailure = GalHookInjectorDiagnostics(
      failure:
          resolved ?? classifyGalHookInjectorFailure(tail, fallback: fallback),
      exitCode: exitCode,
      stderrTail: tail,
    );
  }

  /// injector 是常驻 helper，stdout/stderr 也必须贯穿会话持续排空。只在解析到 launch PID
  /// 后取消 stdout 订阅会让后续输出填满匿名管道；完全不订阅 stderr 更会使 native 卡死在
  /// `fprintf(stderr, ...)`，Unity 资源事件队列随之停止消费但进程仍显示存活。
  ///
  /// **编码契约是 UTF-8，不是系统 ANSI 代码页。** injector 的 `CMakeLists.txt` 无条件加了
  /// MSVC `/utf-8`，它同时把 execution-charset 设成 UTF-8，所以诸如
  /// `[luna] LunaHook32.dll 已注入 pid=...` 这类中文字面量在二进制里就是 UTF-8 字节，
  /// `fprintf(stderr, ...)` 原样写出。旧实现用 [SystemEncoding]（中文 Windows 上是 CP936）
  /// 解码，后果有两层，第二层比乱码严重得多：
  ///   1. 会话事件里的 native 诊断显示成「宸叉敞鍏?」这类乱码；
  ///   2. [classifyGalHookInjectorFailure] 靠中文串（`位数不匹配` / `目标 exe 不存在` /
  ///      `已存在但不可复用的 hook 会话` / `未收到就绪信号`）识别旧 helper 的失败原因，
  ///      解错码后这些分支**永远匹配不上**，失败分类永久退化成 fallback，用户拿不到
  ///      「需要管理员 / 位数不符 / 缺文件」这类可执行处置。
  /// [allowMalformed] 是必须的：stderr 里 `%ls` 宽字符经 C locale 转换后可能夹带非法字节，
  /// 单个坏字节不得让整条诊断流抛异常而丢掉全部证据。
  static const Converter<List<int>, String> _injectorOutputDecoder =
      Utf8Decoder(allowMalformed: true);

  void _beginInjectorOutputDrain(Process process) {
    final Completer<int?> pidCompleter = Completer<int?>();
    final StringBuffer stdoutBuffer = StringBuffer();
    _hookedPidCompleter = pidCompleter;
    _injectorOutputSubscriptions.add(
      process.stdout.transform(_injectorOutputDecoder).listen(
        (String chunk) {
          _emitInjectorOutput(isStderr: false, chunk: chunk);
          stdoutBuffer.write(chunk);
          // `LAUNCH pid=` 先于注入结果到达，且在 hooked 之后仍要保留：注入失败时
          // 它是「游戏已经起来了」的唯一证据，不能因为 pidCompleter 已完成就不解析。
          final int? launched =
              parseInjectorLaunchedPid(stdoutBuffer.toString());
          if (launched != null) _launchedPid = launched;
          if (pidCompleter.isCompleted) return;
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
      process.stderr.transform(_injectorOutputDecoder).listen(
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
    // 有界留存：failure 分类与用户可见诊断都只看尾部，长会话不能无限增长。
    _diagnosticsBuffer.write(chunk);
    if (_diagnosticsBuffer.length > _diagnosticsTailMax * 2) {
      final String kept = _diagnosticsBuffer.toString();
      _diagnosticsBuffer
        ..clear()
        ..write(kept.substring(kept.length - _diagnosticsTailMax));
    }
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
      _textLaneRecycles = (r['textLaneRecycles'] as int?) ?? _textLaneRecycles;
      _textLaneOverflows =
          (r['textLaneOverflows'] as int?) ?? _textLaneOverflows;
      _xaudioDiagnostics =
          (r['xaudioDiagnostics'] as int?) ?? _xaudioDiagnostics;
      _xaudioDiagnostics2 =
          (r['xaudioDiagnostics2'] as int?) ?? _xaudioDiagnostics2;
      // 就绪门只有一处真相源：start() 与运行中的 refreshReadiness() 必须用同一判据，
      // 否则「启动时不算就绪、运行中却算就绪」会让两条路径对同一份共享内存给出
      // 互相矛盾的结论（BUG-1100）。
      _readyFormat = parseEngineHookReadyFormat(r);
      return _readyFormat;
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
  ///
  /// 同一次刷新也更新 [readyPcmFormat]：引擎 PCM 与资源语音是两条各自会「晚到」的能力，
  /// 升格判据必须对称（BUG-1100）。返回值仍是资源语音就绪与否，PCM 侧读 [readyPcmFormat]。
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
              faceId: (e['faceId'] as int?) ?? 0,
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

  /// v12 线程预览区：取**每条线程**的最近一行与观测行数，含尚未被选中的线程。
  ///
  /// 与 [pollText] 的区别是数据来源不同，不是同一份数据的两种视图：[pollText] 读文本环
  /// （只有当前生效线程的行），本方法读按线程分槽的预览区（所有线程都有）。全量快照、
  /// 无游标——预览槽按 thread id 寻址，不存在「漏读就被覆盖」的问题。
  Future<List<GalTextThreadPreview>?> pollThreadPreviews() async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'pollThreadPreviews',
      );
      if (r == null) return null;
      final List<Object?> raw =
          (r['previews'] as List<Object?>?) ?? const <Object?>[];
      final List<GalTextThreadPreview> previews = <GalTextThreadPreview>[];
      for (final Object? e in raw) {
        if (e is! Map) continue;
        final Object? threadId = e['threadId'];
        if (threadId is! int || threadId == 0) continue;
        previews.add(GalTextThreadPreview(
          threadId: threadId,
          text: (e['text'] as String?) ?? '',
          timestampMs: (e['ts'] as int?) ?? 0,
          lineCount: (e['lineCount'] as int?) ?? 0,
          artifactCount: (e['artifactCount'] as int?) ?? 0,
          eventFlags: (e['eventFlags'] as int?) ?? 0,
        ));
      }
      return previews;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 选择 Luna 文本线程。0/null 清除选择（v12 起清除后不再发布任何行，**不会**回到
  /// 自动选择）；非 0 时 helper 只发布该线程。
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
  ///
  /// 选轨/排除契约与 [grabUtterance] 一致：缺省沿用 [selectedAudioSourcePtr] /
  /// [excludedAudioSourcePtrs]。本方法是 grabUtterance 的兜底（BUG-1118）——兜底若不认
  /// 排除集，用户在工作台标掉的 BGM 轨会从这里绕回制卡链。
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
  }) async {
    final int src = sourcePtr ?? selectedAudioSourcePtr;
    final List<int> ex = exclude ?? excludedAudioSourcePtrs.toList();
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabClipNear',
        <String, Object?>{
          'tsMs': tsMs,
          'tolMs': tolMs,
          'sourcePtr': src,
          'exclude': ex,
        },
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
  ///
  /// [endTsMs] 非 null 时把前向窗口右界收到那里（BUG-1475：收敛因「下一句到达」而
  /// 收手时补最后一次 grab，用下一句的时间戳当上界，既拿回尾巴又不会把下一句的段
  /// 拼进上一句）。缺省 null ⇒ 与旧行为逐字等价。
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async {
    final int src = sourcePtr ?? selectedAudioSourcePtr;
    final List<int> ex = exclude ?? excludedAudioSourcePtrs.toList();
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabUtterance',
        <String, Object?>{
          'tsMs': tsMs,
          'sourcePtr': src,
          'exclude': ex,
          'endTsMs': endTsMs ?? 0,
        },
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
  /// （`%TEMP%\fushi_gal_voice`）里配对出**这句台词对应的原始语音**（配对规则见
  /// [pickPairedVoiceOgg]），转码成制卡管线容器 [outputExtension]（桌面 `aac`）字节，直接作
  /// `providedAudioBytes`。这是引擎级最干净的语音（混音前、无 BGM/SE），优先于共享内存里的
  /// [grabUtterance]/[grabClipNear]。非 Windows / 目录不存在 / 无匹配 / 转码失败返回 null
  /// （调用方回退 grabUtterance→grabClipNear→grabRecent 采集链，Never break）。
  File? _findPairedVoiceFile(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) =>
      _firstOrNull(_findPairedVoiceFiles(
        textTsMs,
        textEventId: textEventId,
        allowLatestSessionFallback: allowLatestSessionFallback,
      ));

  /// [_findPairedVoiceFile] 的全量版本：同一句台词可能同时有多个角色配音（BUG-1605），
  /// 引擎为同一条文本读入多个资源、hook 各 dump 一个文件。列表首元素是主语音（单值版
  /// 选中的那一个），其余是同句伴音。判据与全取条件见 [pickPairedGameResources]。
  List<File> _findPairedVoiceFiles(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) {
    if (!Platform.isWindows) return const <File>[];
    _voiceDumpIndex.requestFreshness();
    final GalVoiceDumpSnapshot snapshot = _voiceDumpIndex.snapshot;
    if (_voicePairingCacheRevision != snapshot.revision) {
      _clearVoicePairingCache(revision: snapshot.revision);
    }
    final ({
      int textTsMs,
      int? textEventId,
      bool allowLatestSessionFallback,
    }) query = (
      textTsMs: textTsMs,
      textEventId: textEventId,
      allowLatestSessionFallback: allowLatestSessionFallback,
    );
    final List<String>? cached = _voicePairingCache[query];
    if (cached != null) return _voiceFilesForNames(snapshot, cached);

    List<String> picked = _voiceDumpIndex.findPairedResourceNames(
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
        picked.isEmpty &&
        textTsMs <= 0 &&
        _sessionStartedAt != null) {
      final DateTime floor =
          _sessionStartedAt!.subtract(const Duration(seconds: 2));
      final GalVoiceDumpEntry? latest =
          _voiceDumpIndex.latestPairableVoice(notBefore: floor);
      if (latest != null) {
        picked = <String>[latest.name];
      }
    }
    _cacheVoicePairing(query, picked);
    return _voiceFilesForNames(snapshot, picked);
  }

  List<File> _voiceFilesForNames(
    GalVoiceDumpSnapshot snapshot,
    List<String> names,
  ) =>
      <File>[
        for (final String name in names)
          if (snapshot.byName[name] case final GalVoiceDumpEntry entry)
            File(entry.path),
      ];

  void _cacheVoicePairing(
    ({
      int textTsMs,
      int? textEventId,
      bool allowLatestSessionFallback,
    }) query,
    List<String> names,
  ) {
    if (!_voicePairingCache.containsKey(query) &&
        _voicePairingCache.length >= _voicePairingCacheLimit) {
      _voicePairingCache.remove(_voicePairingCache.keys.first);
    }
    _voicePairingCache[query] = List<String>.unmodifiable(names);
  }

  void _clearVoicePairingCache({int revision = -1}) {
    _voicePairingCache.clear();
    _voicePairingCacheRevision = revision;
  }

  /// 以 [resourceId] 为**主语音**，找出同一句台词里其余角色的配音文件（BUG-1605）。
  ///
  /// 为什么不直接重跑一次时间戳配对：捕获期已经把主资源固化到该行（`audioResourceId`），
  /// 那是「这句话的语音是哪一个」的既定答案，重新按时间戳猜可能给出另一个主语音，等于把
  /// 已冻结的配对推翻。这里只做加法——沿主资源的**归属证据**向外扩：
  ///  - 主资源带稳定事件 ID（`fushi_textseq<seq>`）→ 收同一事件 ID 的其余资源；
  ///  - 主资源没有事件 ID → 只收 tick **完全相同**的其余资源（同一毫秒读入 = 同时播放）。
  ///
  /// 两条都不是时间邻近猜测：没有归属证据就只有主资源自己（判据本身是纯函数
  /// [companionVoiceResourceNames]，这里只负责枚举目录和落回 [File]）。返回列表首元素
  /// 恒为主资源。
  List<File> _companionVoiceFiles(String resourceId) {
    final File? primary = _voiceFileForResourceId(resourceId);
    if (primary == null) return const <File>[];
    _voiceDumpIndex.requestFreshness();
    final GalVoiceDumpSnapshot snapshot = _voiceDumpIndex.snapshot;
    return <File>[
      primary,
      for (final String name in companionVoiceResourceNames(
        primaryName: resourceId,
        candidateNames: <String>[
          for (final GalVoiceDumpEntry entry in snapshot.voiceEntries)
            entry.name,
        ],
      ))
        if (snapshot.byName[name] case final GalVoiceDumpEntry entry)
          File(entry.path),
    ];
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
    if (!lower.endsWith('.ogg') &&
        !lower.endsWith('.wav') &&
        !lower.endsWith('.xwma')) {
      return null;
    }
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

  /// [pairedVoiceFilePathForResourceId] 的**等写完**版本（BUG-1109）：试听走的是原件，
  /// hook 还在写就播会听到被截断的半句。等文件大小停止增长后再交出路径；等待期间文件被
  /// 清理掉则返回 null（与同步版对缺文件的语义一致）。
  Future<String?> settledPairedVoiceFilePathForResourceId(
    String resourceId,
  ) async {
    final String? path = pairedVoiceFilePathForResourceId(resourceId);
    if (path == null) return null;
    final File file = File(path);
    await awaitStableVoiceDumpFile(file);
    return file.existsSync() ? path : null;
  }

  /// 取这句台词的制卡语音字节。OGG/WAV/xWMA 都统一转成 [outputExtension] 对应的
  /// 手机可播放容器；原始 xWMA 不能直接写进 Anki 媒体。
  ///
  /// BUG-1605：同一句可能有多个角色同时配音，引擎为同一条文本读入多个资源。这里取的是
  /// **全部**（主语音在前），交给 [transcodeVoiceResourcesToMiningAudio] 合成一段音频；
  /// 只取其中一个就等于制卡时丢掉另一个人的声音。哪些资源算「同一句」由归属证据决定，
  /// 见 [pickPairedGameResources] / [_companionVoiceFiles]——纯时间邻近不算。
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async {
    if (Platform.isWindows) {
      _voiceDumpIndex.requestFreshness();
      await _voiceDumpIndex.synchronize();
    }
    final List<File> picked = resourceId == null
        ? _findPairedVoiceFiles(
            textTsMs,
            textEventId: textEventId,
            allowLatestSessionFallback: allowLatestSessionFallback,
          )
        : _companionVoiceFiles(resourceId);
    if (picked.isEmpty) return null;
    // BUG-1109：hook 可能还在往这些文件里写。转码截断的原件会得到「有音频但少一截」
    // 的卡，比报错更难发现，所以先等它们写完。
    for (final File file in picked) {
      await awaitStableVoiceDumpFile(file);
    }
    return transcodeVoiceResourcesToMiningAudio(
      resourcePaths: <String>[for (final File file in picked) file.path],
      tempDir: Directory.systemTemp.path,
      outputExtension: outputExtension,
    );
  }

  /// 轻量清理语音 dump 目录（[_galVoiceDumpDir]）：hook DLL 持续 dump，跨会话会无限增长。删
  /// 掉超过 [maxAge] 的旧文件、并把总数压到最新 [keepNewest] 个（按修改时间保新弃旧）。在引擎
  /// -hook 就绪时调一次即可。保留窗口必须长于一次常规视觉小说游戏会话：Fushi 在
  /// 游戏仍运行时重启会回放文本环，历史台词仍需要之前落盘的原始资源。30 分钟/400 个会把
  /// 这些有效证据误删，使同一句在 UI 重启后变成 `line_audio_not_cached`。非 Windows /
  /// 目录不存在 / 任何 IO 异常静默返回（清理失败不该影响制卡）。
  Future<void> pruneVoiceDump({
    int keepNewest = 5000,
    Duration maxAge = const Duration(hours: 24),
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _voiceDumpIndex.synchronize();
      final DateTime now = DateTime.now();
      final List<GalVoiceDumpEntry> survivors = <GalVoiceDumpEntry>[];
      bool mutated = false;
      for (final GalVoiceDumpEntry entry
          in _voiceDumpIndex.snapshot.entries) {
        final bool tooOld = now.difference(entry.modified) > maxAge;
        if (tooOld) {
          try {
            await File(entry.path).delete();
            mutated = true;
          } catch (_) {}
        } else {
          survivors.add(entry);
        }
      }
      if (survivors.length > keepNewest) {
        survivors.sort(
          (GalVoiceDumpEntry a, GalVoiceDumpEntry b) =>
              b.modified.compareTo(a.modified),
        );
        for (int i = keepNewest; i < survivors.length; i++) {
          try {
            await File(survivors[i].path).delete();
            mutated = true;
          } catch (_) {}
        }
      }
      if (mutated) {
        _voiceDumpIndex.invalidate();
        await _voiceDumpIndex.synchronize();
      }
    } catch (_) {
      // 清理是尽力而为，绝不影响制卡。
    }
  }

  /// hook DLL dump 语音 OGG 的目录：`<GetTempPath>fushi_gal_voice`（hook DLL 用 `GetTempPathW`
  /// 落盘，Dart [Directory.systemTemp] 同走 GetTempPath，路径一致）。仅在 Windows 调用。
  Directory _galVoiceDumpDir() => _voiceDumpIndex.directory;

  static Directory _defaultGalVoiceDumpDirectory() => Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fushi_gal_voice',
      );

  /// 取路径 [path] 的文件名（最后一段，兼容 `\` 与 `/` 分隔）。
  static String _fileBaseName(String path) {
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
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
  Future<void> stop() {
    final Future<void>? inFlight = _stopInFlight;
    if (inFlight != null) return inFlight;
    final Future<void> stopping = _stopInternal();
    _stopInFlight = stopping;
    return stopping.whenComplete(() {
      if (identical(_stopInFlight, stopping)) _stopInFlight = null;
    });
  }

  Future<void> _stopInternal() async {
    // Stop is a capture-policy transaction: publish deny and wait until the
    // injected worker confirms stopped/reaped before closing the mapping or
    // killing its keeper process. No playback/XAudio engine method is called.
    _nativeLoopbackPolicy = GalNativeLoopbackPolicy.deny;
    if (_mappingOpen) {
      await requestNativeLoopbackPolicy(GalNativeLoopbackPolicy.deny);
    }
    _mappingOpen = false;
    _finishStartWait(opened: false);
    await _voiceDumpIndex.stopSession();
    _clearVoicePairingCache();
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
    _rawVoiceReady = false;
    _readyFormat = null;
  }
}

/// [EngineHookGalAudioSource.pollText] 的结果：当前文本行总数 + 本次取到的新行。
class GalTextPoll {
  const GalTextPoll({required this.count, required this.lines});
  final int count;
  final List<GalHookedLine> lines;
}

/// v12 线程预览区里的一条快照：某条 Luna 文本线程的最近一行 + 观测统计。
///
/// [lineCount] 是 native 观测到的**全部**行数（含被伪影过滤和线程门控丢弃的），与
/// 「已发布行数」不是一回事。v12 取消自动选线程后，用户选定之前已发布行数对所有线程
/// 恒为 0，凡是判断线程活跃度/可选性/记忆恢复都必须用本字段。
class GalTextThreadPreview {
  const GalTextThreadPreview({
    required this.threadId,
    required this.text,
    this.timestampMs = 0,
    this.lineCount = 0,
    this.artifactCount = 0,
    this.eventFlags = 0,
  });

  /// native 侧 `ThreadPreviewSlot::event_flags` 的伪影位。
  static const int flagArtifact = 0x1;

  final int threadId;
  final String text;
  final int timestampMs;
  final int lineCount;
  final int artifactCount;
  final int eventFlags;

  bool get isArtifact => (eventFlags & flagArtifact) != 0;
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
  /// Native event flag: this Luna engine keeps semantic lanes separated by
  /// ThreadParam.ctx, so the consumer must not accept a sibling thread merely
  /// because its hook-face id matches the selected thread.
  static const int flagExactThreadContext = 0x2;

  const GalHookedLine({
    required this.seq,
    required this.timestampMs,
    required this.text,
    this.threadId = 0,
    this.faceId = 0,
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

  /// hook「面」id（native 算好的、不含 ctx 的身份，见 luna_text_selector.h）。
  ///
  /// v13 起 native 采集期不再按选定线程丢行，过滤挪到消费期；这个字段是**挪过去仍然等价**
  /// 的前提：同一 hook 面在不同剧情分支下调用点 ctx 会变、[threadId] 随之变，只按 threadId
  /// 精确匹配会把整段台词丢掉（BUG-1159）。0 = 写者没提供（GDI/Unity 等）。
  final int faceId;
  final int threadAddress;
  final int threadContext;
  final int threadContext2;
  final int processId;
  final int sourceKind;
  final GalTextEventKind eventKind;
  final int eventFlags;
  final String hookName;
  final String hookCode;

  bool get requiresExactThreadContext =>
      (eventFlags & flagExactThreadContext) != 0;

  String? get textThreadKey {
    if (threadId == 0) return null;
    final String source = switch (sourceKind) {
      1 => 'gdi',
      2 => 'luna',
      3 => 'unity_tmp',
      4 => 'siglus',
      5 => 'sgre',
      6 => 'smash',
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
            5 => 'SGRE exact',
            6 => 'smash exact',
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
    this.clipCountAtCue = -1,
  });

  /// 源指针（会话内稳定；跨启动会变——UI 宜把用户选择映射到 [orderIndex] 或格式签名）。
  final int sourcePtr;

  /// 该源 PCM 格式（采样率/声道/位深）；解析失败该轨被丢弃。
  final PcmFormat format;

  /// **环内**该源每段平均字节数（缓冲规模）。
  final int avgBytes;

  /// 文本时刻窗（native `[ts-150, ts+450]`）平均能量：16-bit 平均绝对幅值。
  /// **-1 有两义**，别只判正负——见 [isSilentAtCue] / [energyUnknown]：
  /// ① 该窗内这条轨一个片段都没有（真·此刻没响）；② 该轨不是 16-bit，
  /// native `ClipEnergy16Locked` 算不了能量。
  final double avgEnergy;

  /// **环内**按首次出现排的创建顺序，0-based（跨启动相对稳定，宜作用户选择的持久锚）。
  final int orderIndex;

  /// **环内**该源的段数——注意是整个环形缓冲的累计，不是「当前这句附近」。
  ///
  /// 一条轨能出现在列表里，前提就是环里至少有它的一个片段，所以这个值恒 >= 1：
  /// 拿它判「这条轨此刻有没有声音」永远为假（BUG-1165 的原判据就栽在这）。
  /// 判「此刻有没有响」只能用 [isSilentAtCue]。
  final int clipCount;

  /// 文本时刻窗（native `[ts-150, ts+450]`）内该源的段数——**与位深无关**。
  ///
  /// native `VoiceTrackInfo::clip_count_at_cue`。这是「此刻这条轨响没响」的唯一
  /// 正确依据：[avgEnergy] 只在 16-bit 上算得出来，用它兼作有无判据会误伤非 16-bit
  /// 的可用轨（BUG-1165）。老版本 runner 不发这个字段 → 解析为 -1（未知）。
  final int clipCountAtCue;

  /// 该轨的能量是否**无法判定**（非 16-bit 轨，native 不计能量）。
  /// 能量只用来排语音/BGM 的可能性次序，不参与「有没有声音」的判断。
  bool get energyUnknown => format.bitsPerSample != 16;

  /// 该轨在**当前这句的时刻窗**内是否一个片段都没有（试听必然抓不到）。
  ///
  /// 试听走 `grabUtterance(该句时刻, sourcePtr)`，与 native 统计这个窗用的是同一个
  /// 区间，所以「窗内无片段」与「试听出不了声」是同一件事。
  ///
  /// [clipCountAtCue] < 0 表示 runner 没发这个字段（老版本）——此时退回能量判据，
  /// 且只对能算出能量的 16-bit 轨下结论，宁可不置灰也不误伤（向后兼容）。
  bool get isSilentAtCue => clipCountAtCue >= 0
      ? clipCountAtCue == 0
      : !energyUnknown && avgEnergy < 0;

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
      // 缺字段 = 老 runner，用 -1 显式表达「未知」，别拿 0 冒充「窗内没段」。
      clipCountAtCue: (m['clipCountAtCue'] as int?) ?? -1,
    );
  }
}
