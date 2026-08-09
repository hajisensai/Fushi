import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/mining/gal_hook_activity_accumulator.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_char_count.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_hook_code_profile.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';
import 'package:fushi/src/mining/galgame_system_ui_filter.dart';
import 'package:fushi/src/mining/magpie_upscaling_service.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/sync/texthooker_ws_client_manager.dart';
import 'package:fushi/src/utils/misc/fushi_time_format.dart';

/// 落 `activity_events` 的一条游戏活动写入契约。默认实现走 [FushiDatabase.
/// addActivityEvent]（[kActivityGame] / [kActivityMediaGame]）；单测可注入假写入方
/// 断言 flush 时机与聚合值，无需真实 DB。
///
/// **只写字符数，不写 `durationMs`**（契约 §3.1）：游玩时长的真相源已经是
/// `GalgamePlayTracker`（前台窗口 + 候选进程组计时），hook 文本这条路径再写一份
/// 时长就是同一次游玩被计两遍。hook 文本字符数仍然有价值（喂首页「今日字符数」），
/// 所以这条写入保留，只是不再携带时长。
typedef GalHookActivityWriter = Future<void> Function({
  required String title,
  String? mediaKey,
  required String dateKey,
  required int timestampMs,
  required int charsDelta,
});

enum GalHookSessionPhase {
  idle,
  resolving,
  launching,
  attaching,
  injecting,
  waitingSignals,
  running,
  degraded,
  stopping,
  error,
}

enum GalHookAudioBackend { none, gameResource, enginePcm, systemLoopback }

/// 「活跃音轨」空列表时的解释分支（BUG-1027，纯函数可单测）。
///
/// gameResource 模式语音按句直接提取资源文件、不进共享内存 PCM 环（native
/// `ListAudioTracks` 只枚举 PCM 环，voice_hook_reader.cpp:546），空列表是**常态**
/// 而非故障；systemLoopback 是整机混音单流，同样没有逐轨枚举。只有引擎 PCM /
/// 无音频后端时才保留通用「尚无音轨数据」空态。
///
/// BUG-1102：这个解释**不是空列表专用**。用户机器上列表非空（残留 PCM 环仍能枚举）
/// 却照样点不动选轨，原因就是当前后端根本不消费 `selectedAudioSourcePtr`。判据必须是
/// 「后端是不是引擎 PCM」（[galTrackSelectionAffectsCapture]），不是「列表空不空」。
enum GalTrackEmptyHint { generic, resourceMode, loopbackMode }

/// 单句语音的合理时长上限（毫秒）。超过它的切片多半不是「一句台词」而是长段混音
/// （典型：制卡时才收束的 loopback 回取，见 [_flushLoopbackFreeze]），入卡前换成
/// [kGalOverlongSliceSuspectReason] 让 UI 亮黄提醒，而不是静默当正常语音。
const int kGalOverlongSliceSuspectMs = 20000;

/// 自动降级链允许走到哪一级（取代旧的 bool `allowAudioFallback`）。
///
/// 旧 bool 把两件不同的事捆成一个开关：`false` 既禁掉了**整机混音**（真会混进 BGM），
/// 也顺手禁掉了**引擎 PCM**（混音前抓的干净语音，物理上不含 BGM），于是没有资源
/// hook 的引擎一关就一句音频都没有。三态把「干净与否」和「有没有原件」拆开：
///
/// - [full]：资源 → 引擎 PCM → 系统混音。抓不到就拿混音兜底（旧 `allow=true`）。
/// - [cleanOnly]：资源 → 引擎 PCM，**绝不碰系统混音**。都没有 = 这句没配音，
///   灰标 + 无音频成卡（旁白/心理描写句本来就该是这个结果）。
/// - [resourceOnly]：只认游戏原始资源文件；缺音频时拒绝制卡（旧 `allow=false`）。
///
/// 用户**显式裁决**（浮窗「重播并录音」、逐行选轨）不受本策略约束——那不是降级，
/// 是用户指定音源，见 [GalHookSessionController._captureAudioBytesNow] 的裁决分支。
enum GalAudioFallbackPolicy {
  full,
  cleanOnly,
  resourceOnly;

  /// 是否允许把引擎 PCM（混音前的干净语音）当作资源缺失时的兜底。
  bool get allowsEnginePcm => this != GalAudioFallbackPolicy.resourceOnly;

  /// 是否允许把系统 loopback 整机混音当作兜底（唯一会混进 BGM/SE 的一路）。
  bool get allowsLoopback => this == GalAudioFallbackPolicy.full;

  /// 抓不到音频时是否拒绝制卡。只有最严格的 [resourceOnly] 拒绝——[cleanOnly] 的
  /// 立场是「这句没配音很正常」，卡照做、只是不带音频。
  bool get blocksMiningWhenMissing =>
      this == GalAudioFallbackPolicy.resourceOnly;

  /// 偏好/记忆里的稳定存储名（枚举 index 会随重排漂移，不入库）。
  String get storageKey => name;

  static GalAudioFallbackPolicy fromStorageKey(String? key) {
    for (final GalAudioFallbackPolicy policy in GalAudioFallbackPolicy.values) {
      if (policy.storageKey == key) return policy;
    }
    return GalAudioFallbackPolicy.full;
  }
}

/// 每个游戏的捕获选择记忆（跨会话持久化的真值放偏好表）。
///
/// 三项都用**弱指纹**而非会话内 id：`source_ptr` 每次启动都变、native 文本
/// `thread_id` 混了 processId 同样每次都变，能跨会话锚住的只有
/// [GalHookSessionController.trackFingerprint]（音轨创建序 + PCM 格式）与
/// [GalHookSessionController.textThreadFingerprint]（LunaHook 的 hook code /
/// 标签）。指纹可能漂或撞，因此恢复必须是**可见且一键可改**的：三项恢复各记一条
/// 结构化事件，且工作台面板实时显示当前生效的选择。
@immutable
class GalCaptureMemory {
  const GalCaptureMemory({
    this.excludedTrackFingerprints = const <String>[],
    this.voiceTrackFingerprint,
    this.textThreadFingerprint,
    this.audioFallbackPolicy = GalAudioFallbackPolicy.full,
  });

  factory GalCaptureMemory.fromJson(Map<Object?, Object?> json) {
    final Object? excluded = json['excludedTracks'];
    return GalCaptureMemory(
      excludedTrackFingerprints: excluded is List
          ? excluded.whereType<String>().toList(growable: false)
          : const <String>[],
      voiceTrackFingerprint: json['voiceTrack'] as String?,
      textThreadFingerprint: json['textThread'] as String?,
      audioFallbackPolicy: GalAudioFallbackPolicy.fromStorageKey(
        json['audioFallback'] as String?,
      ),
    );
  }

  /// 用户标记为 BGM 的音轨指纹集合。
  final List<String> excludedTrackFingerprints;

  /// 用户选定的会话语音轨指纹；null = 自动选源。
  final String? voiceTrackFingerprint;

  /// 用户选定的文本线程指纹；null = 自动选线程。
  final String? textThreadFingerprint;

  /// 用户为这个游戏选定的降级策略。与「标记 BGM」同规格按游戏记住——两者都是
  /// 「这个游戏的音频该怎么抓」的判断，只记一半会让用户每次开游戏重设一遍。
  final GalAudioFallbackPolicy audioFallbackPolicy;

  bool get isEmpty =>
      excludedTrackFingerprints.isEmpty &&
      voiceTrackFingerprint == null &&
      textThreadFingerprint == null &&
      audioFallbackPolicy == GalAudioFallbackPolicy.full;

  GalCaptureMemory copyWith({
    List<String>? excludedTrackFingerprints,
    String? voiceTrackFingerprint,
    String? textThreadFingerprint,
    GalAudioFallbackPolicy? audioFallbackPolicy,
    bool clearVoiceTrack = false,
    bool clearTextThread = false,
  }) =>
      GalCaptureMemory(
        excludedTrackFingerprints:
            excludedTrackFingerprints ?? this.excludedTrackFingerprints,
        voiceTrackFingerprint: clearVoiceTrack
            ? null
            : voiceTrackFingerprint ?? this.voiceTrackFingerprint,
        textThreadFingerprint: clearTextThread
            ? null
            : textThreadFingerprint ?? this.textThreadFingerprint,
        audioFallbackPolicy: audioFallbackPolicy ?? this.audioFallbackPolicy,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'excludedTracks': excludedTrackFingerprints,
        if (voiceTrackFingerprint != null) 'voiceTrack': voiceTrackFingerprint,
        if (textThreadFingerprint != null) 'textThread': textThreadFingerprint,
        if (audioFallbackPolicy != GalAudioFallbackPolicy.full)
          'audioFallback': audioFallbackPolicy.storageKey,
      };
}

/// [GalCaptureMemory] 的持久化端口（由
/// [GalHookSessionController.attachCaptureMemory] 注入）。gameKey 是启动 exe
/// 全路径小写——只有 launch 路径有稳定游戏身份，attach（绑窗口）没有，不猜。
typedef GalCaptureMemoryLoad = GalCaptureMemory Function(String gameKey);
typedef GalCaptureMemorySave = void Function(
  String gameKey,
  GalCaptureMemory memory,
);

/// 会话级选轨 / 排除是否真的影响取音（纯函数，可单测）。
///
/// 只有引擎 PCM 后端会走 `grabUtterance`，也只有它读
/// [EngineHookGalAudioSource.selectedAudioSourcePtr] / `excludedAudioSourcePtrs`；
/// 资源模式按句取原始资源文件、Loopback 是整机混音，两者都与轨选择无关。UI 据此禁用
/// 控件并说清原因，而不是让用户点一个不会生效的按钮（BUG-1102）。
/// 单条台词的选轨是另一回事——那是用户裁决，走
/// [GalHookSessionController.setLineVoiceTrack]。
bool galTrackSelectionAffectsCapture(GalHookAudioBackend backend) =>
    backend == GalHookAudioBackend.enginePcm;

/// 按音频后端返回音轨空态解释分支。
GalTrackEmptyHint galTrackEmptyHintFor(GalHookAudioBackend backend) =>
    switch (backend) {
      GalHookAudioBackend.gameResource => GalTrackEmptyHint.resourceMode,
      GalHookAudioBackend.systemLoopback => GalTrackEmptyHint.loopbackMode,
      _ => GalTrackEmptyHint.generic,
    };

/// 一次启动失败的**结构化原因**（BUG-1142）。
///
/// 存在的理由：[GalHookSessionController.launchGame] 曾经返回 `bool`，而它有五条
/// `return false` 出口，其中四条**根本不设置任何原因**——会话被抢占那几条连
/// [GalHookSessionState] 都不碰。于是 UI 只能事后去 state 里翻，翻到的是
/// `injectorFailure == none` + `lastError == null`，最终甩给用户一句「游戏启动或捕获
/// 失败」：一个字的可执行信息都没有，用户无法自愈，排障时也判断不出到底停在哪一步。
///
/// 原因是在 `return false` 那一刻被丢掉的，任何下游补丁都救不回来（下游只能拿到一个
/// 比特）。所以修在返回类型上：**每条失败出口必须携带一个原因，由编译期强制**。
/// 本枚举**只列失败**，刻意不含 `none` 之类「未失败」哨兵（BUG-1169）：成功由
/// [GalHookLaunchResult.reason] 取 `null` 表达。哨兵留在值域里就等于允许构造
/// `failed(none)`——一个 `launched` 读起来是 `true` 的失败。当初拦住它的只有一个
/// `assert`，而 release 构建会把 assert 整个剥掉：最需要它的那个构建里它恰好不在。
enum GalHookLaunchFailureReason {
  /// 非 Windows 平台，整条 Hook 链不可用。
  unsupportedPlatform,

  /// 找不到与游戏架构匹配的 injector helper。
  helperMissing,

  /// 游戏没能起来，或早期注入失败且拿不到运行中的 PID。
  /// native 诊断在 [GalHookLaunchResult.diagnostics] 里，必须一路带到 UI。
  injectionFailed,

  /// **这不是失败**：本次启动被更新的会话操作取代（用户又点了一次、切到附着捕获、
  /// 或停止了捕获）。旧实现把它和真失败压成同一个 `false`，于是被取代的那次会抢先
  /// 弹一句「启动失败」，把真正生效的那次结果盖掉——用户看到的失败其实来自一次
  /// 已经作废的操作。
  superseded,
}

/// [GalHookSessionController.launchGame] 的结构化结果（BUG-1142）。
///
/// 取代原来的 `bool`：成功只有一种，失败必须说明是哪一种，并把 native 诊断一起带走。
@immutable
class GalHookLaunchResult {
  /// 启动成功（含「游戏在跑但音频降级」——那仍然是启动成功，降级由 outcome 分级表达）。
  const GalHookLaunchResult.launched() : this._();

  /// 启动未成功。[reason] 形参是**非空**的 [GalHookLaunchFailureReason]：该枚举已不含
  /// 「未失败」哨兵，`null` 又被空安全在编译期挡住，所以「没有原因的失败」在这里
  /// 根本构造不出来（BUG-1169）。这是类型约束而非运行期检查，不随 release 剥离 assert
  /// 而失效——上一版的 `assert` 恰恰在用户实际运行的构建里不存在。
  const GalHookLaunchResult.failed(
    GalHookLaunchFailureReason reason, {
    GalHookInjectorDiagnostics diagnostics = const GalHookInjectorDiagnostics(),
  }) : this._(reason: reason, diagnostics: diagnostics);

  /// 唯一的生成式构造器。私有：外部只能经 [launched]（reason 恒为 null）或
  /// [failed]（reason 恒非 null）二选一进入，两条路都写不出第三种状态。
  const GalHookLaunchResult._({
    this.reason,
    this.diagnostics = const GalHookInjectorDiagnostics(),
  });

  /// 失败原因；`null` **就是**「启动成功」这一个事实的唯一表示。
  ///
  /// 用 `null` 而不是枚举里的哨兵值：哨兵会同时出现在 `failed()` 的入参值域和
  /// `launched` 的判据里，两边一旦对不上就产生「读起来像成功的失败」。`null` 只能由
  /// [GalHookLaunchResult.launched] 写入，失败构造器压根拿不到它。
  final GalHookLaunchFailureReason? reason;

  /// injector 的结构化诊断（分类原因 + 退出码 + stderr 尾部原文）。
  /// 即便 [GalHookInjectorFailure] 归类不出来，这里的 stderr 尾部仍是唯一的一手证据，
  /// 必须让它到达用户和日志，而不是像旧实现那样停在 controller 内部。
  final GalHookInjectorDiagnostics diagnostics;

  /// 启动是否成功。判据是「没有失败原因」，而**每一个**失败原因都让它为 false——
  /// 这由值域本身保证（枚举里没有任何值代表成功），不依赖任何运行期断言。
  bool get launched => reason == null;
}

/// 一次「启动游戏」结束后**必须**告知用户的结果分级（BUG-1089，纯函数可单测）。
///
/// 存在的理由：[GalHookSessionController.launchGame] 返回 `bool`，把三种结果压成两个值
/// ——「彻底失败」「游戏在跑但注入降级」「完全成功」。于是每个调用方都得自己去
/// [GalHookSessionState] 里翻，结果两个调用方翻得不一样：texthooker 翻了 `boundWindow`，
/// 游戏库页**一个字都不提示**，用户点完「启动游戏」看不到游戏也看不到任何报错。
/// 把「结果分级」收成这一个判定，两个调用方共用，消灭那处不一致。
enum GalHookLaunchOutcome {
  /// 启动彻底失败：游戏进程都没起来。
  failed,

  /// 游戏进程起来了，但窗口始终没出现。**用户眼里就是「点了没反应、游戏没打开」**，
  /// 所以它比 [degradedLoopback] 更严重：注入恢复失败会让游戏主线程停在挂起态，
  /// 进程在、CPU 有、窗口永不出现。这种情况绝不能只说「捕获已运行」。
  windowMissing,

  /// 游戏在跑、窗口也绑上了，但引擎注入失败，只能拿整机混音兜底（会混入 BGM/音效）。
  degradedLoopback,

  /// 注入成功、窗口已绑定。
  running,

  /// 本次启动被更新的操作取代：**不得向用户播报任何结果**。取代它的那次操作会播报
  /// 自己的结果；这里再弹一句只会用一个作废操作的结局盖掉真实结局。
  superseded,
}

/// 把一次启动的结果判成 [GalHookLaunchOutcome]（纯函数，无 i18n、无 IO）。
///
/// 判「注入链通不通」用 [injectorFailure] 而不是 `phase == degraded`：
/// `_activateTextWithLoopback`（文本 hook 就绪、音频用 Loopback）同样把 phase 设成
/// `degraded`，但它显式把 injectorFailure 清成 [GalHookInjectorFailure.none]——那是
/// 「有台词、音频兜底」的可接受模式，不该报成降级去烦用户。
/// 被取代（[GalHookLaunchFailureReason.superseded]）先于一切判定：它既不是失败也不是
/// 成功，而是「这次操作的结论已经作废」，唯一正确的处置是闭嘴。
GalHookLaunchOutcome classifyGalHookLaunchOutcome({
  required GalHookLaunchResult result,
  required bool hasBoundWindow,
  required GalHookInjectorFailure injectorFailure,
}) {
  if (result.reason == GalHookLaunchFailureReason.superseded) {
    return GalHookLaunchOutcome.superseded;
  }
  if (!result.launched) return GalHookLaunchOutcome.failed;
  if (!hasBoundWindow) return GalHookLaunchOutcome.windowMissing;
  if (injectorFailure != GalHookInjectorFailure.none) {
    return GalHookLaunchOutcome.degradedLoopback;
  }
  return GalHookLaunchOutcome.running;
}

/// [GalHookSessionController.exportTrackPreview] 的产物：临时 WAV 路径 + 时长。
@immutable
class GalTrackPreview {
  const GalTrackPreview({required this.filePath, required this.durationMs});

  final String filePath;
  final int durationMs;
}

/// 试听临时 WAV 的文件名（纯函数，可单测）：轨指针十六进制 + 抓取用文本时间戳。
String galTrackPreviewFileName({
  required int sourcePtr,
  required int timestampMs,
}) =>
    'gal_track_preview_${sourcePtr.toRadixString(16)}_$timestampMs.wav';

enum GalHookEventSeverity { info, success, warning, error }

@immutable
class GalHookEvent {
  const GalHookEvent({
    required this.id,
    required this.timestamp,
    required this.severity,
    required this.stage,
    required this.code,
    required this.summary,
    this.details = const <String, Object?>{},
  });

  final int id;
  final DateTime timestamp;
  final GalHookEventSeverity severity;
  final String stage;
  final String code;
  final String summary;
  final Map<String, Object?> details;
}

@immutable
class GalHookSessionState {
  const GalHookSessionState({
    this.phase = GalHookSessionPhase.idle,
    this.externalWindowMode = false,
    this.audioFallbackPolicy = GalAudioFallbackPolicy.full,
    this.boundWindow,
    this.gamePid,
    this.launchExe,
    this.sessionStartedAt,
    this.audioBackend = GalHookAudioBackend.none,
    this.audioFormat,
    this.fallbackReason,
    this.injectorFailure = GalHookInjectorFailure.none,
    this.injectorDetail = '',
    this.lastError,
    this.textSignalReceived = false,
    this.textGapCount = 0,
    this.textDuplicateCount = 0,
    this.audioTracks = const <GalAudioTrack>[],
    this.selectedAudioSourcePtr = 0,
    this.excludedAudioSourcePtrs = const <int>{},
  });

  final GalHookSessionPhase phase;
  final bool externalWindowMode;

  /// 自动降级链的上限（见 [GalAudioFallbackPolicy]）。会话内可改，按游戏持久化到
  /// [GalCaptureMemory]。
  final GalAudioFallbackPolicy audioFallbackPolicy;
  final ExternalWindowInfo? boundWindow;
  final int? gamePid;
  final String? launchExe;
  final DateTime? sessionStartedAt;
  final GalHookAudioBackend audioBackend;
  final PcmFormat? audioFormat;
  final String? fallbackReason;

  /// 降级/失败的**结构化**原因。[fallbackReason] 是给日志的内部代码（UI 曾经原样
  /// 把 `engine_attach_failed` 甩给用户）；本字段才是 UI 该翻译成人话并给出处置的依据。
  final GalHookInjectorFailure injectorFailure;

  /// 与 [injectorFailure] 同生共死的**一手证据**（`exit=<码>` + native 诊断末行，例如
  /// `voice_hook open access_denied name=Local\FushiVoiceHook_1234 win32=5`）。
  ///
  /// 降级路径的启动结果是「已启动」，诊断挂不到 `GalHookLaunchResult` 上；没有这个字段，
  /// 用户在降级 toast 里只看得到一句归类结论，另一台机器上跑得通/跑不通无从对比
  /// （BUG-1216）。空串表示本次没有 native 证据，绝不编造。
  final String injectorDetail;
  final String? lastError;
  final bool textSignalReceived;
  final int textGapCount;
  final int textDuplicateCount;
  final List<GalAudioTrack> audioTracks;
  final int selectedAudioSourcePtr;
  final Set<int> excludedAudioSourcePtrs;

  bool get isActive =>
      phase != GalHookSessionPhase.idle && phase != GalHookSessionPhase.error;
  bool get hasText => textSignalReceived;
  bool get hasAudio => audioBackend != GalHookAudioBackend.none;
  bool get hasWindow => boundWindow != null;
  bool get isDegraded => phase == GalHookSessionPhase.degraded;

  GalHookSessionState copyWith({
    GalHookSessionPhase? phase,
    bool? externalWindowMode,
    GalAudioFallbackPolicy? audioFallbackPolicy,
    ExternalWindowInfo? boundWindow,
    bool clearBoundWindow = false,
    int? gamePid,
    bool clearGamePid = false,
    String? launchExe,
    bool clearLaunchExe = false,
    DateTime? sessionStartedAt,
    bool clearSessionStartedAt = false,
    GalHookAudioBackend? audioBackend,
    PcmFormat? audioFormat,
    bool clearAudioFormat = false,
    String? fallbackReason,
    bool clearFallbackReason = false,
    GalHookInjectorFailure? injectorFailure,
    String? injectorDetail,
    String? lastError,
    bool clearLastError = false,
    bool? textSignalReceived,
    int? textGapCount,
    int? textDuplicateCount,
    List<GalAudioTrack>? audioTracks,
    int? selectedAudioSourcePtr,
    Set<int>? excludedAudioSourcePtrs,
  }) {
    return GalHookSessionState(
      phase: phase ?? this.phase,
      externalWindowMode: externalWindowMode ?? this.externalWindowMode,
      audioFallbackPolicy: audioFallbackPolicy ?? this.audioFallbackPolicy,
      boundWindow: clearBoundWindow ? null : boundWindow ?? this.boundWindow,
      gamePid: clearGamePid ? null : gamePid ?? this.gamePid,
      launchExe: clearLaunchExe ? null : launchExe ?? this.launchExe,
      sessionStartedAt: clearSessionStartedAt
          ? null
          : sessionStartedAt ?? this.sessionStartedAt,
      audioBackend: audioBackend ?? this.audioBackend,
      audioFormat: clearAudioFormat ? null : audioFormat ?? this.audioFormat,
      fallbackReason:
          clearFallbackReason ? null : fallbackReason ?? this.fallbackReason,
      // 降级原因与降级本身同生共死：clearFallbackReason 时必须一起复位，否则会话恢复后
      // 还挂着上一次的失败原因。
      injectorFailure: clearFallbackReason
          ? GalHookInjectorFailure.none
          : injectorFailure ?? this.injectorFailure,
      // 证据跟着原因走：原因复位了还留着上一次的 win32 码只会误导排障。
      injectorDetail:
          clearFallbackReason ? '' : injectorDetail ?? this.injectorDetail,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      textSignalReceived: textSignalReceived ?? this.textSignalReceived,
      textGapCount: textGapCount ?? this.textGapCount,
      textDuplicateCount: textDuplicateCount ?? this.textDuplicateCount,
      audioTracks: audioTracks ?? this.audioTracks,
      selectedAudioSourcePtr:
          selectedAudioSourcePtr ?? this.selectedAudioSourcePtr,
      excludedAudioSourcePtrs:
          excludedAudioSourcePtrs ?? this.excludedAudioSourcePtrs,
    );
  }
}

/// 引擎 hook 失败后的重试退避表。
///
/// 只对**可能自愈**的失败生效（见 [galHookFailureIsRetryable]）：引擎初始化竞态、
/// DLL 加载慢、上一局残留会话。位数不符 / 需要提权 / 缺文件这类不会随时间改变的
/// 失败一次都不重试——重试只会掩盖必须告诉用户的处置。
///
/// 步长按「Unity/IL2CPP 游戏从进程创建到音频子系统就位」的量级取：首轮 3s 覆盖普通
/// 竞态，最后一轮 20s 覆盖带壳解包与首次着色器编译；再长就该让用户手动重来了。
const List<Duration> kGalEngineRetryBackoff = <Duration>[
  Duration(seconds: 3),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

typedef GalEngineSourceFactory = EngineHookGalAudioSource Function({
  required int targetPid,
  required String? launchExe,
  required String injectorPath,
  required bool lunaPcHooks,
  int? lunaCodepage,
  // launch 专用且可选：attach 路径（引擎重试、窗口绑定）不传，行为不变。
  List<String> launchArguments,
  String launchWorkdir,
  // BUG-1477：该游戏的日语区域（转区）档位。以前整条 UI→source 的通路上**根本没有
  // 这个形参**，所以不是「忘了传」而是没有这个自由度——汉化版被强制转区后闪退，
  // 用户无法自救。attach 路径不传，转区在 source 侧必然短路（launchMode 为首个合取项）。
  GalJapaneseLocaleMode japaneseLocaleMode,
});
typedef GalLoopbackSourceFactory = LoopbackGalAudioSource Function();
typedef GalTargetWow64Probe = Future<bool?> Function(int pid);
typedef GalExe32BitProbe = Future<bool?> Function(String path);

/// BUG-1267 — 由 **PID** 反查目标进程的 exe 绝对路径。
///
/// attach（捕获窗口 / 引擎重试）路径此前没有这条查询，于是
/// [shouldUseLunaPcHooksForExecutable] 唯一的输入拿不到，两个调用点就把
/// `lunaPcHooks` 直接写死成 `false`——**「判据取不到」被实现成了「判为否」**。
/// 后果是 Unity/IL2CPP 与 Siglus 目标只要不是由 Hibiki 亲自拉起，就永远不补装
/// LunaHook 通用 PC hooks，文本线程一条都抓不到（injector 报 `text=0`）。
/// exe 路径本来就能从 PID 拿到（`QueryFullProcessImageNameW`），补上这条查询即可
/// 让两条路径共用同一套判据，而不是各自猜。
typedef GalTargetImagePathProbe = String? Function(int pid);
typedef GalWindowListLoader = Future<List<ExternalWindowInfo>> Function();
typedef GalInjectorResolver = String? Function({required bool is32Bit});

/// App 级 galgame 捕获会话真相源。
///
/// 页面只发送 bind/launch/stop/select-track intent。音频源、文本轮询、稳定台词 id、
/// 句音缓存和结构化事件都在这里跨页面存活，避免切换侧边栏时隐式停止捕获。
class GalHookSessionController extends ChangeNotifier {
  GalHookSessionController({
    TexthookerService? textService,
    GalEngineSourceFactory? engineSourceFactory,
    GalLoopbackSourceFactory? loopbackSourceFactory,
    GalTargetWow64Probe? targetWow64Probe,
    GalTargetImagePathProbe? targetImagePathProbe,
    GalExe32BitProbe? exe32BitProbe,
    GalWindowListLoader? windowListLoader,
    GalInjectorResolver? injectorResolver,
    DateTime Function()? now,
    bool? isWindows,
    // 台词显示延迟直接由本间隔决定（浮窗只在 append 触发的 notify 后刷新）。native
    // `pollText` 只读共享内存环并拷贝新行，无 IO、无锁等待，400ms 纯粹是人为的
    // 感知延迟（平均 +200ms、最坏 +400ms）。降到 80ms 后仍是每秒 12.5 次廉价调用。
    Duration textPollInterval = const Duration(milliseconds: 80),
    Duration windowPollInterval = const Duration(milliseconds: 500),
    Duration resourceAudioWait = const Duration(milliseconds: 1200),
    Duration resourceAudioPollInterval = const Duration(milliseconds: 80),
    int windowPollAttempts = 20,
    Duration windowRebindInterval = const Duration(seconds: 2),
    Duration trackRefreshInterval = const Duration(seconds: 5),
    // BUG-1101：Loopback 是**纯后向**的环形缓冲，而 galgame 的时序永远是「文本先绘制
    // → 语音随后播放」。台词一到就 grabRecent 只会取到上一句 + BGM，错位一句是必然。
    // 因此台词到达后先延后这么久再冻结，让本句语音真的进环。默认 4s 覆盖绝大多数单句
    // 语音；文本仍立刻上屏，只有音频后补。
    Duration loopbackFreezeDelay = const Duration(milliseconds: 4000),
    // BUG-1109：引擎 PCM 的整句拼接窗口在 native 是前向的（`[ts-200, ts+6000]`），
    // 但台词一到就读，窗口的前向部分还是空的——只能拼到这句语音**已提交给混音器**的
    // 开头。因此按这个间隔重取，把更长的结果写回缓存（见 [_settleLineUtterance]）。
    Duration utteranceSettleInterval = const Duration(milliseconds: 250),
    // 收敛上限：与 native 拼接窗口的前向长度（ts+6000）对齐，超过就不可能再拼到新段。
    // 也是收敛的**唯一**时长判据：缓存单调变长，「连续 N 轮没变长」只会被句中的长停顿
    // 骗成早收敛，删掉它比调参更正确（收敛提前收手只靠下一句到达 / 会话与用户裁决）。
    Duration utteranceSettleMax = const Duration(milliseconds: 6000),
    List<Duration> engineRetryBackoff = kGalEngineRetryBackoff,
    Listenable? endpointListenable,
    List<TexthookerEndpointStatus> Function()? endpointStatusLoader,
    GalHookActivityWriter? activityWriter,
  })  : _textService = textService ?? TexthookerService.instance,
        _activityWriter = activityWriter,
        _engineSourceFactory = engineSourceFactory ?? _defaultEngineFactory,
        _loopbackSourceFactory =
            loopbackSourceFactory ?? LoopbackGalAudioSource.new,
        _targetWow64Probe =
            targetWow64Probe ?? EngineHookGalAudioSource.targetIsWow64,
        _targetImagePathProbe = targetImagePathProbe ?? _defaultTargetImagePath,
        _exe32BitProbe = exe32BitProbe ?? EngineHookGalAudioSource.exeIs32Bit,
        _windowListLoader =
            windowListLoader ?? WindowCaptureChannel.listWindows,
        _injectorResolver = injectorResolver ?? defaultInjectorResolver,
        _now = now ?? DateTime.now,
        _isWindows = isWindows ?? Platform.isWindows,
        _textPollInterval = textPollInterval,
        _windowPollInterval = windowPollInterval,
        _resourceAudioWait = resourceAudioWait,
        _resourceAudioPollInterval = resourceAudioPollInterval,
        _windowPollAttempts = windowPollAttempts,
        _windowRebindInterval = windowRebindInterval,
        _trackRefreshInterval = trackRefreshInterval,
        _loopbackFreezeDelay = loopbackFreezeDelay,
        _utteranceSettleInterval = utteranceSettleInterval,
        _utteranceSettleMax = utteranceSettleMax,
        _engineRetryBackoff = engineRetryBackoff,
        _endpointListenable =
            endpointListenable ?? TexthookerWsClientManager.instance,
        _endpointStatusLoader = endpointStatusLoader ??
            (() => TexthookerWsClientManager.instance.endpointStatuses) {
    final List<TexthookerLineEntry> initialEntries = _textService.entries;
    _lastObservedLineId =
        initialEntries.isEmpty ? null : initialEntries.last.id;
    _state = _state.copyWith(textSignalReceived: initialEntries.isNotEmpty);
    _textService.addListener(_onTextBufferChanged);
    _endpointListenable.addListener(_onEndpointStatusChanged);
  }

  static final GalHookSessionController instance = GalHookSessionController();
  static const int _voiceCacheMax = 200;

  /// Loopback 环形缓冲的**真实**容量：native `kRingSeconds = 60`
  /// （fushi/windows/runner/audio_loopback_capture.cpp:21）。
  /// 这是 `grabRecent` 回取长度的唯一硬上限，与任何窗口时长无关（BUG-1094）。
  static const int _loopbackRingCapacityMs = 60000;

  /// 逐行 loopback 冻结时额外向前多取的余量：少数引擎的语音会略早于文本落地。
  static const int _loopbackPreRollMs = 1000;

  /// 提前收束（制卡/升格）时的最小回取长度，避免取出一段空 PCM。
  static const int _loopbackMinBackMs = 800;

  /// 资源语音就绪查询的最小间隔（见 [_lastReadinessRefreshAt]）。
  static const Duration _readinessRefreshInterval = Duration(milliseconds: 500);
  static const int _eventLimit = 400;

  final TexthookerService _textService;
  final GalEngineSourceFactory _engineSourceFactory;
  final GalLoopbackSourceFactory _loopbackSourceFactory;
  final GalTargetWow64Probe _targetWow64Probe;
  final GalTargetImagePathProbe _targetImagePathProbe;
  final GalExe32BitProbe _exe32BitProbe;
  final GalWindowListLoader _windowListLoader;
  final GalInjectorResolver _injectorResolver;
  final DateTime Function() _now;
  final bool _isWindows;
  final Duration _textPollInterval;
  final Duration _windowPollInterval;
  final Duration _resourceAudioWait;
  final Duration _resourceAudioPollInterval;
  final int _windowPollAttempts;
  final Duration _windowRebindInterval;
  final Duration _trackRefreshInterval;
  final Duration _loopbackFreezeDelay;
  final Duration _utteranceSettleInterval;
  final Duration _utteranceSettleMax;
  final List<Duration> _engineRetryBackoff;
  final Listenable _endpointListenable;
  final List<TexthookerEndpointStatus> Function() _endpointStatusLoader;

  GalHookSessionState _state = const GalHookSessionState();
  GalHookSessionState get state => _state;
  List<TexthookerLineEntry> get lines => _textService.entries;
  List<TexthookerTextThread> get textThreads =>
      _textService.textThreadsSince(_state.sessionStartedAt);

  /// 这一行能否进入正式消费面（工作台 / 浮窗 / 配对 / 制卡）。
  ///
  /// v12 起「未选线程」不再等于「全部线程」：**带线程身份的行**必须由用户显式
  /// 选中才发布（BUG-1193），没选就只在下拉的候选预览里可见，底层诊断 buffer
  /// 不删。
  ///
  /// 但判据是「这一行归不归一条被排除的线程」，而不是「有没有选过线程」。
  /// **不带线程身份的行**（`textThreadKey == null`：WebSocket / Textractor 端点
  /// 的行，以及 `threadId == 0` 的降级 hook 行）从来不进线程目录，也就永远不会
  /// 出现在选择器里——拿选择状态去门控它们等于永久丢弃，而且用户无法自救（下拉
  /// 本身按 `textThreads.isNotEmpty` 置灰）。所以**未选线程时**它们放行。
  ///
  /// 反过来，用户**已经选定**一条线程时无身份行必须让位：那是一句「我的正文来自
  /// 这条线程」的显式声明。此时再混进 Textractor 端点的平行文本，浮窗的 `latest`
  /// 会在两个来源之间跳，且无身份行没有 `textEventId`/`hookTimestampMs`
  /// （只有引擎行会写 `_lineTextEventIdCache`），逐句配对只能退回时间戳兜底窗
  /// —— 正是 BUG-1159 的失败链。这一支保持与 v12 之前逐字节同一行为。
  ///
  /// 有身份行的判据是「这条 key 被本次选择认领过」（见 [_selectedThreadClaimedKeys]），
  /// 而不是与选定 key 逐字节相等——后者会在剧情分支换调用点时把整段台词丢在发布期。
  static bool _publishesUnderSelection(
    TexthookerLineEntry entry,
    String? selectedKey,
    Set<String> claimedKeys,
  ) {
    final String? key = entry.textThreadKey;
    if (key == null || key.isEmpty) return selectedKey == null;
    if (selectedKey == null) return false;
    return key == selectedKey || claimedKeys.contains(key);
  }

  /// 捕获工作台当前应展示的正式行。过滤判据见 [_publishesUnderSelection]；
  /// 捕获中额外只看本次会话，避免上一个进程的台词混进当前工作台。
  List<TexthookerLineEntry> get workbenchLines {
    final String? selectedKey = selectedTextThreadKey;
    final DateTime? startedAt = _state.sessionStartedAt;
    Iterable<TexthookerLineEntry> scoped = _textService.entries.where(
      (TexthookerLineEntry entry) => _publishesUnderSelection(
          entry, selectedKey, _selectedThreadClaimedKeys),
    );
    if (startedAt != null) {
      scoped = scoped.where(
        (TexthookerLineEntry entry) => !entry.receivedAt.isBefore(startedAt),
      );
    }
    return List<TexthookerLineEntry>.unmodifiable(scoped);
  }

  String? get selectedTextThreadKey {
    final String? selected = _selectedTextThreadKey;
    if (selected == null) return null;
    return textThreads.any((thread) => thread.key == selected)
        ? selected
        : null;
  }

  int? get selectedNativeTextThreadId => _selectedNativeTextThreadId;
  String? get currentLaunchExecutable => _state.launchExe;
  TexthookerTextThread? get selectedTextThread {
    final String? key = selectedTextThreadKey;
    if (key == null) return null;
    for (final TexthookerTextThread thread in textThreads) {
      if (thread.key == key) return thread;
    }
    return null;
  }

  /// 当前捕获会话、当前线程的有效行。历史缓冲仍保留在 [lines]，但浮窗和场景
  /// 制卡只允许消费这里的行，防止跨会话或跨线程借用上下文。
  List<TexthookerLineEntry> get selectedSessionLines {
    final DateTime? startedAt = _state.sessionStartedAt;
    if (startedAt == null) return const <TexthookerLineEntry>[];
    final String? selectedKey = selectedTextThreadKey;
    return List<TexthookerLineEntry>.unmodifiable(
      _textService.entries.where(
        (TexthookerLineEntry entry) =>
            _publishesUnderSelection(
              entry,
              selectedKey,
              _selectedThreadClaimedKeys,
            ) &&
            !entry.receivedAt.isBefore(startedAt),
      ),
    );
  }

  TexthookerLineEntry? entryById(String lineId) =>
      _textService.entryById(lineId);

  bool isLineInCurrentSession(TexthookerLineEntry entry) {
    final DateTime? startedAt = _state.sessionStartedAt;
    return startedAt != null && !entry.receivedAt.isBefore(startedAt);
  }

  List<TexthookerEndpointStatus> get endpointStatuses =>
      _endpointStatusLoader();

  /// 当前是否存在引擎 hook 源。音轨选择 / 排除 / 试听等能力只在此时有意义；
  /// 诊断页据此把「选轨不生效」显式提示给用户（BUG-1027），不再静默失败。
  bool get hasEngineSource => _engineSource != null;

  final List<GalHookEvent> _events = <GalHookEvent>[];
  List<GalHookEvent> get events => List<GalHookEvent>.unmodifiable(_events);

  GalAudioSource? _audioSource;
  EngineHookGalAudioSource? _engineSource;
  Timer? _textPollTimer;
  Timer? _trackRefreshTimer;
  // BUG-1049：launch 后游戏窗口尚未出现时的重绑监视（见 [_startWindowRebindWatch]）。
  Timer? _windowRebindTimer;
  bool _windowRebindInFlight = false;
  // 引擎 hook 失败后的有界重试（见 [_scheduleEngineRecovery]）。降级到 Loopback 曾是
  // 终态：一次注入竞态就让整局只剩整机混音、没有台词，用户只能重启游戏。
  Timer? _engineRetryTimer;
  int _engineRetryAttempt = 0;
  bool _engineRetryInFlight = false;
  bool _pollInFlight = false;

  /// 上次向 native 问「资源语音是否就绪」的时刻。文本轮询降到 80ms 后不能每 tick
  /// 都跟着做一次 IPC 往返——就绪状态是秒级变化的会话属性，与单行台词无关。
  DateTime? _lastReadinessRefreshAt;
  int _lastTextSeq = 0;
  int _eventId = 0;
  int _operationGeneration = 0;
  String? _lastObservedLineId;
  String? _selectedTextThreadKey;
  int? _selectedNativeTextThreadId;

  /// 选定线程的 hook「面」id（native 算好的，随文本行带上来）。
  ///
  /// v13 起 native 采集期不再按选定线程丢行（每条线程写自己那条道，挤压结构上不可能），
  /// 过滤挪到本类的文本消费点。要**等价**替换旧的 native 过滤，就必须复刻它的判据：
  /// 精确 threadId 命中，或同一 hook 面命中——同一 hook 面在不同剧情分支下调用点 ctx 会变、
  /// thread_id 随之变，只按 threadId 精确匹配会把整段台词丢掉（BUG-1159 的原始症状）。
  /// face 从选定线程自己的行里学到，未见过为 0（此时退化为精确匹配，与旧实现同语义）。
  int _selectedTextThreadFaceId = 0;

  /// 本次选择已认领的线程 key 集合——发布期过滤器的唯一判据来源。
  ///
  /// 为什么不能让发布期自己再写一份判据（BUG-1470）：采集期 [_acceptsLineFromSelectedThread]
  /// 的判据是 `(threadId, faceId)`，带 BUG-1159 的同 hook 面兜底；发布期
  /// [_publishesUnderSelection] 拿到的却是字符串 `textThreadKey`，它由 threadId 派生
  /// （见 [GalHookedLine.textThreadKey]）。剧情一分支 ctx 变 → threadId 变 → key 变，
  /// 于是同一句台词**过了采集、被发布全丢**：工作台正文与游戏窗浮窗同时空白，
  /// 而线程预览区不受选择门控、照常有字——正是「预览有字、选进去没文字」的现场。
  ///
  /// 修法是让发布期成为采集期的**投影**而不是平行实现：采集放行一行就认领它的 key，
  /// 发布只查集合。选择时用选定 key 自身播种，使直接往 [TexthookerService] 塞行、
  /// 绕过采集期的调用方（既有测试与 WebSocket/剪贴板等无 helper 来源）保持原行为。
  final Set<String> _selectedThreadClaimedKeys = <String>{};
  final SerialJobQueue _audioQueue = SerialJobQueue();
  final Set<String> _loopbackCacheInFlight = <String>{};

  /// 逐行 loopback「延迟冻结」定时器（BUG-1101）：lineId → 到点后把环形缓冲冻结成该行
  /// 语音的定时器。等待必须在队列**之外**——在串行音频队列里 sleep 会把后续台词的抓取
  /// 和制卡全部堵住。
  final Map<String, Timer> _loopbackFreezeTimers = <String, Timer>{};

  /// 每条待冻结行的台词到达时刻，用于提前收束（制卡 / 升格）时算真实已等待长度。
  final Map<String, DateTime> _loopbackFreezeStartedAt = <String, DateTime>{};

  final Map<String, GalAudioSlice> _lineVoiceCache = <String, GalAudioSlice>{};

  // 每游戏捕获选择记忆（见 [attachCaptureMemory]）。
  GalCaptureMemoryLoad? _captureMemoryLoad;
  GalCaptureMemorySave? _captureMemorySave;
  bool _captureMemoryLoaded = false;
  String? _captureMemoryGameKey;
  GalCaptureMemory _captureMemory = const GalCaptureMemory();

  /// 音轨记忆（排除集 + 语音轨）已对本会话首个非空快照应用过。
  bool _trackMemoryApplied = false;

  /// 文本线程记忆已在本会话应用过（或用户已手动选过线程）——两者都终止自动恢复。
  bool _textThreadMemoryApplied = false;

  /// 记忆恢复文本线程所需的最小行数：native 线程 id 混了 processId，跨会话不稳定，
  /// 同一 hook 往往有多条并行线程共用同一指纹，只能靠「真的在出台词」来消歧。
  /// 门限设 3 行而不是 1 行，避免开局个别 UI 线程抢先蹦一行就把选择钉死。
  static const int _textThreadRestoreMinLines = 3;
  final Map<String, int> _lineTimestampCache = <String, int>{};
  final Map<String, int> _lineTextEventIdCache = <String, int>{};
  final Map<String, ({int timestampMs, int textEventId})>
      _pendingResourceMatches =
      <String, ({int timestampMs, int textEventId})>{};

  // ── 游戏活动记账（首页「游戏」活动 = activity_events 的唯一写入方）─────────
  /// 纯累计器：把 hook 文本行累计成活跃时长 + 字符数（挂机间隔封顶，见其实现）。
  final GalHookActivityAccumulator _activityAccumulator =
      GalHookActivityAccumulator();

  /// 统计字数的唯一计数口径（相邻去重 + 递增增量 + 标点剔除 + CJK 每字/西文
  /// 每词 + 超长垃圾行门），见 [GalgameLineCharCounter]。
  final GalgameLineCharCounter _activityCharCounter = GalgameLineCharCounter();

  /// 本会话是否已有引擎 hook 台词计入统计。置位后外部 WS/剪贴板行不再计数——
  /// 同一游戏同时开着 LunaTranslator 等外部 hook 时，每句台词会从两条通道各到
  /// 一次，一个会话只允许一个计数源。引擎侧一直无文本时（仅用外部工具喂文本、
  /// hibiki 只管音频的场景）外部行仍照常计数。
  bool _engineTextCounted = false;

  /// 可注入的落库写入方（单测用假实现）；为 null 时经 [_activityDatabaseResolver]
  /// 惰性取 DB 走默认写入。
  final GalHookActivityWriter? _activityWriter;

  /// 由桌面启动流程注入的 DB 惰性解析器（见 [attachActivityDatabase]）。flush 时才
  /// 解析——App 未初始化完/未注入时解析到 null 静默不落库（累计保留，下次再试），
  /// 避免 start 时急切解引用未初始化的 late 字段。
  FushiDatabase? Function()? _activityDatabaseResolver;

  /// 由桌面启动流程注入的窗口超分编排器（见 [attachMagpieUpscaling]）。
  ///
  /// 可空是刻意的：超分是**纯附加能力**，未注入（测试替身、非 Windows、用户没开）时
  /// 整条链路是 `?.` 空操作，会话行为与没有它时逐字节一致。
  MagpieUpscalingService? _magpieUpscaling;

  /// 已经告诉超分编排器「挂上去」的窗口 hwnd；null = 当前没挂。
  /// 开与关都只看它和 [magpieUpscalingTargetHwnd] 判据之间的差。
  int? _magpieArmedHwnd;

  /// 超分开 / 关边沿的串行队列。状态更新永不 await 它（超分不许拖慢 UI），但退出与
  /// [close] 路径 await 它排空，保证「先关干净再让进程死」。
  Future<void> _magpieWork = Future<void>.value();

  /// 登记进 [ExitFlushRegistry] 的退出清理回调；未注入超分时为 null。
  ExitFlushCallback? _magpieExitFlush;

  /// 当前会话归属的游戏显示名（窗口标题 / 可执行文件名）；null = 无可归属标题。
  String? _activityGameTitle;

  /// 当前会话的稳定游戏 id（launch 模式为可执行文件路径），无稳定 id 时为 null。
  String? _activityGameKey;

  static EngineHookGalAudioSource _defaultEngineFactory({
    required int targetPid,
    required String? launchExe,
    required String injectorPath,
    required bool lunaPcHooks,
    int? lunaCodepage,
    List<String> launchArguments = const <String>[],
    String launchWorkdir = '',
    GalJapaneseLocaleMode japaneseLocaleMode = kGalDefaultJapaneseLocaleMode,
  }) {
    return EngineHookGalAudioSource(
      targetPid: targetPid,
      launchExe: launchExe,
      launchArguments: launchArguments,
      launchWorkdir: launchWorkdir,
      injectorPath: injectorPath,
      lunaPcHooks: lunaPcHooks,
      lunaCodepage: lunaCodepage,
      japaneseLocaleMode: japaneseLocaleMode,
    );
  }

  /// 复用 [GalgameWindowsProcessProbe]（`QueryFullProcessImageNameW`）而不是再写
  /// 第四份 FFI 封装。probe 会 `DynamicLibrary.open`，因此**只在真的要查时**才实例化
  /// 并缓存——非 Windows 直接返回 null，让判据回落到与旧行为一致的「不装 PC hooks」。
  static GalgameProcessProbe? _sharedProcessProbe;

  static String? _defaultTargetImagePath(int pid) {
    if (!Platform.isWindows || pid <= 0) return null;
    try {
      return (_sharedProcessProbe ??= GalgameWindowsProcessProbe())
          .processImagePath(pid);
    } on Object {
      return null;
    }
  }

  /// BUG-1267 — attach 路径的 `lunaPcHooks` 判据。
  ///
  /// 与 launch 路径**共用** [shouldUseLunaPcHooksForExecutable]：判据本身只认 exe
  /// 路径（basename 白名单 + 同目录 `UnityPlayer.dll`），launch 有路径、attach 也能
  /// 从 PID 查到，没有任何理由让两条路径给出不同答案。查不到路径时返回 false —— 这
  /// 与修复前的硬编码行为一致，所以「探测失败」不会比旧版更糟，只会不再更好。
  bool _lunaPcHooksForPid(int pid) {
    final String? imagePath = _targetImagePathProbe(pid);
    if (imagePath == null || imagePath.isEmpty) return false;
    return shouldUseLunaPcHooksForExecutable(imagePath);
  }

  static String? defaultInjectorResolver({required bool is32Bit}) {
    if (!Platform.isWindows) return null;
    try {
      final String directory = File(Platform.resolvedExecutable).parent.path;
      final String arch = is32Bit ? 'x86' : 'x64';
      final String path =
          '$directory\\voice_hook\\$arch\\fushi_voice_injector.exe';
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _attachPersistedHookProfiles(
    EngineHookGalAudioSource engine,
  ) async {
    try {
      final LunaHookCodeProfileStore store =
          await LunaHookCodeProfileStore.openDefault();
      engine.lunaHookProfilePath = store.file.path;
    } catch (_) {
      // Profile persistence must never prevent capture; injector built-ins and
      // automatic Luna engine detection remain available.
    }
  }

  Future<void> setExternalWindowMode(bool enabled) async {
    if (!enabled) {
      await stopCapture(keepBinding: true);
      return;
    }
    _setState(_state.copyWith(externalWindowMode: true));
    final ExternalWindowInfo? bound = _state.boundWindow;
    if (bound == null) {
      _record(
        GalHookEventSeverity.info,
        'window',
        'window.binding_required',
        'Capture enabled; waiting for a game window binding',
      );
      return;
    }
    await startAttachedCapture(bound);
  }

  Future<void> bindWindow(ExternalWindowInfo? window) async {
    if (window == null) {
      _setState(_state.copyWith(clearBoundWindow: true));
      _record(
        GalHookEventSeverity.warning,
        'window',
        'window.unbound',
        'Game window binding was removed',
      );
      if (_state.externalWindowMode) await stopCapture(keepBinding: false);
      return;
    }
    _setState(_state.copyWith(boundWindow: window, gamePid: window.pid));
    _record(
      GalHookEventSeverity.success,
      'window',
      'window.bound',
      'Bound game window',
      details: <String, Object?>{
        'pid': window.pid,
        'hwnd': window.hwnd,
        'title': window.title,
      },
    );
    if (_state.externalWindowMode) await startAttachedCapture(window);
  }

  Future<void> startAttachedCapture(ExternalWindowInfo window) async {
    final int generation = ++_operationGeneration;
    await _stopSources();
    if (!_isWindows || generation != _operationGeneration) return;
    _selectedTextThreadKey = null;
    _selectedNativeTextThreadId = null;
    _selectedTextThreadFaceId = 0;
    _selectedThreadClaimedKeys.clear();
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.resolving,
        externalWindowMode: true,
        boundWindow: window,
        gamePid: window.pid,
        sessionStartedAt: _now(),
        clearLaunchExe: true,
        clearLastError: true,
        clearFallbackReason: true,
        textSignalReceived: false,
      ),
    );
    // attach 模式无稳定可执行文件 id：以窗口标题作为游戏名，mediaKey 留空。
    _beginActivitySession(title: window.title, mediaKey: null);
    _record(
      GalHookEventSeverity.info,
      'resolve',
      'session.attach_resolving',
      'Resolving target process architecture',
      details: <String, Object?>{'pid': window.pid},
    );
    final bool? is32Bit = await _targetWow64Probe(window.pid);
    if (generation != _operationGeneration) return;
    final String? injector = _injectorResolver(is32Bit: is32Bit ?? false);
    if (injector != null && window.pid > 0) {
      _setState(_state.copyWith(phase: GalHookSessionPhase.injecting));
      final EngineHookGalAudioSource engine = _engineSourceFactory(
        targetPid: window.pid,
        launchExe: null,
        injectorPath: injector,
        // BUG-1267 — 从 PID 反查 exe 后走与 launch 相同的判据，别再写死 false。
        lunaPcHooks: _lunaPcHooksForPid(window.pid),
      );
      await _attachPersistedHookProfiles(engine);
      final PcmFormat? format = await engine.start();
      if (generation != _operationGeneration) {
        await engine.stop();
        return;
      }
      if (format != null) {
        if (engine.rawVoiceReady) {
          await _activateResourceWithLoopback(
            generation,
            engine,
            gamePid: window.pid,
          );
        } else {
          _activateEngine(engine, format, gamePid: window.pid);
        }
        return;
      }
      if (engine.textHookReady) {
        await _activateTextWithLoopback(
          generation,
          engine,
          gamePid: window.pid,
        );
        return;
      }
      // 诊断必须在 stop() 之前取：stop 只负责杀进程，失败原因由本次 start 定格。
      final GalHookInjectorDiagnostics diagnostics = engine.lastFailure;
      await engine.stop();
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.engine_attach_failed',
        'Engine audio hook failed; falling back to system loopback',
        details: diagnostics.toDetails(),
      );
      await _activateLoopback(
        generation,
        fallbackReason: 'engine_attach_failed',
        failure: diagnostics.failure,
        detail: galHookDiagnosticsDetail(diagnostics),
      );
      _scheduleEngineRecovery(
        generation,
        pid: window.pid,
        diagnostics: diagnostics,
      );
      return;
    }
    // 走到这里只有两种可能，原因不同、处置也不同：helper 没装（要装组件），或者这个
    // 窗口根本没带有效 PID（拿不到注入目标）。不能笼统都说成 helper 缺失。
    final bool helperMissing = injector == null;
    _record(
      GalHookEventSeverity.warning,
      'helper',
      helperMissing ? 'helper.missing' : 'window.pid_unavailable',
      helperMissing
          ? 'Matching voice-hook helper is unavailable; using loopback'
          : 'The bound window exposes no process id; using loopback',
      details: <String, Object?>{
        'arch': is32Bit == true ? 'x86' : 'x64',
        'pid': window.pid,
      },
    );
    await _activateLoopback(
      generation,
      fallbackReason: helperMissing ? 'helper_missing' : 'target_missing',
      failure: helperMissing
          ? GalHookInjectorFailure.helperMissing
          : GalHookInjectorFailure.targetMissing,
    );
  }

  /// 拉起游戏并注入。
  ///
  /// [launchArguments] 是用户为该游戏配置的启动参数（已按 Windows 规则拆成 argv
  /// token，见 `parseGameLaunchArguments`），[workdir] 是工作目录。[gameId] 必须是
  /// `galgames.id`，[gameTitle] 是当前库内显示名；游戏库入口应同时传入，使活动事件
  /// 使用与封面/详情反查相同的稳定身份。裸 exe 启动可以省略二者，此时活动仍保留
  /// exe 文件名快照，但 mediaKey 留空，不能再把路径伪装成 `galgames.id`。
  Future<GalHookLaunchResult> launchGame(
    String executablePath, {
    List<String> launchArguments = const <String>[],
    String workdir = '',
    String? gameId,
    String? gameTitle,

    /// 该游戏的日语区域（转区）档位（BUG-1477）。缺省 auto = 与旧行为等价。
    GalJapaneseLocaleMode japaneseLocaleMode = kGalDefaultJapaneseLocaleMode,
  }) async {
    final int generation = ++_operationGeneration;
    await _stopSources();
    // 两种早退原因必须分开：非 Windows 是「这台机器不支持」，被抢占是「这次操作作废」。
    // 旧实现用同一个 `false` 表达，于是 UI 对二者说同一句无信息的话。
    if (!_isWindows) {
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.unsupportedPlatform,
      );
    }
    if (generation != _operationGeneration) {
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.superseded,
      );
    }
    _selectedTextThreadKey = null;
    _selectedNativeTextThreadId = null;
    _selectedTextThreadFaceId = 0;
    _selectedThreadClaimedKeys.clear();
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.resolving,
        externalWindowMode: true,
        launchExe: executablePath,
        sessionStartedAt: _now(),
        clearBoundWindow: true,
        clearGamePid: true,
        clearLastError: true,
        clearFallbackReason: true,
        textSignalReceived: false,
      ),
    );
    final String normalizedTitle = gameTitle?.trim() ?? '';
    // 活动 mediaKey 的跨层契约统一为 galgames.id。历史版本写过 exePath，读取侧保留
    // 兼容；新写入不再延续一字段两种身份的歧义。
    _beginActivitySession(
      title: normalizedTitle.isEmpty
          ? _displayNameForExecutable(executablePath)
          : normalizedTitle,
      mediaKey: gameId,
    );
    // 降级策略必须在这里恢复，不能搭 [_applyTrackMemory] 的便车：资源模式压根不枚举
    // 音轨（native 只枚举 PCM 环），等音轨快照就等不到，用户上次选的「禁止降级」会
    // 在最需要它的资源模式游戏里静默失效。
    _restoreAudioFallbackPolicy();
    final bool? is32Bit = await _exe32BitProbe(executablePath);
    final String? injector = _injectorResolver(is32Bit: is32Bit ?? false);
    if (injector == null) {
      _fail(
        'helper',
        'helper.missing',
        'Voice-hook helper is missing for the selected executable architecture',
        details: <String, Object?>{'arch': is32Bit == true ? 'x86' : 'x64'},
        failure: GalHookInjectorFailure.helperMissing,
      );
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.helperMissing,
      );
    }
    final bool lunaPcHooks = shouldUseLunaPcHooksForExecutable(executablePath);
    _setState(_state.copyWith(phase: GalHookSessionPhase.launching));
    _record(
      GalHookEventSeverity.info,
      'launch',
      'game.launch_started',
      'Launching game with early injection',
      details: <String, Object?>{
        'exe': executablePath,
        'arch': is32Bit == true ? 'x86' : 'x64',
        'lunaPcHooks': lunaPcHooks,
        'gameArgCount': launchArguments.length,
        'hasWorkdir': workdir.isNotEmpty,
      },
    );
    final EngineHookGalAudioSource engine = _engineSourceFactory(
      targetPid: 0,
      launchExe: executablePath,
      launchArguments: launchArguments,
      launchWorkdir: workdir,
      injectorPath: injector,
      lunaPcHooks: lunaPcHooks,
      japaneseLocaleMode: japaneseLocaleMode,
    );
    await _attachPersistedHookProfiles(engine);
    _setState(_state.copyWith(phase: GalHookSessionPhase.injecting));
    final PcmFormat? format = await engine.start();
    if (generation != _operationGeneration) {
      await engine.stop();
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.superseded,
      );
    }
    if (format == null && !engine.textHookReady) {
      final GalHookInjectorDiagnostics diagnostics = engine.lastFailure;
      // injector 在 CreateProcess 成功后即回报 `LAUNCH pid=`，这个 PID 与注入是否成功
      // 无关。拿得到它就说明**游戏已经在跑**：此时把整个会话判成「启动失败」是错的——
      // 用户面前明明有个游戏窗口，Hibiki 却停在终态错误，只能手动去「捕获目标」重绑。
      // 改为保留会话、降级到 Loopback，并按退避表重试附着。
      final int? runningPid = engine.launchedPid;
      await engine.stop();
      if (runningPid != null) {
        _record(
          GalHookEventSeverity.warning,
          'inject',
          'engine.launch_injection_degraded',
          'Game is running, but early engine injection failed; '
              'falling back to system loopback',
          details: <String, Object?>{
            'pid': runningPid,
            ...diagnostics.toDetails(),
          },
        );
        _setState(_state.copyWith(gamePid: runningPid));
        await _activateLoopback(
          generation,
          fallbackReason: 'launch_injection_failed',
          failure: diagnostics.failure,
          detail: galHookDiagnosticsDetail(diagnostics),
        );
        if (generation != _operationGeneration) {
          return const GalHookLaunchResult.failed(
            GalHookLaunchFailureReason.superseded,
          );
        }
        _startWindowRebindWatch(generation, runningPid);
        _scheduleEngineRecovery(
          generation,
          pid: runningPid,
          diagnostics: diagnostics,
        );
        return const GalHookLaunchResult.launched();
      }
      _fail(
        'inject',
        'engine.launch_or_inject_failed',
        'Game launch or early engine injection failed',
        details: diagnostics.toDetails(),
        failure: diagnostics.failure,
        detail: galHookDiagnosticsDetail(diagnostics),
      );
      // 诊断随结果一起返回：`diagnostics.failure` 归类不出来时（unknown），stderr 尾部
      // 就是唯一的一手证据，绝不能停在这里。
      return GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.injectionFailed,
        diagnostics: diagnostics,
      );
    }
    final int? gamePid = engine.gamePid;
    if (format != null) {
      if (engine.rawVoiceReady) {
        await _activateResourceWithLoopback(
          generation,
          engine,
          gamePid: gamePid,
        );
      } else {
        _activateEngine(engine, format, gamePid: gamePid);
      }
    } else if (!await _activateTextWithLoopback(
      generation,
      engine,
      gamePid: gamePid,
    )) {
      // _activateTextWithLoopback 只在会话被抢占时返回 false（音频源起不来它仍返回
      // true，走 all_audio_sources_failed 降级）。所以这里唯一的语义就是「已作废」。
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.superseded,
      );
    }
    ExternalWindowInfo? window;
    if (gamePid != null) {
      for (int attempt = 0;
          attempt < _windowPollAttempts && window == null;
          attempt++) {
        final List<ExternalWindowInfo> windows = await _windowListLoader();
        for (final ExternalWindowInfo candidate in windows) {
          if (candidate.pid == gamePid) {
            window = candidate;
            break;
          }
        }
        if (window == null && attempt + 1 < _windowPollAttempts) {
          await Future<void>.delayed(_windowPollInterval);
        }
      }
    }
    if (generation != _operationGeneration) {
      return const GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.superseded,
      );
    }
    if (window != null) {
      _setState(_state.copyWith(boundWindow: window, gamePid: gamePid));
      _record(
        GalHookEventSeverity.success,
        'window',
        'window.auto_bound',
        'Automatically bound the launched game window',
      );
    } else {
      _setState(
        _state.copyWith(
          phase: GalHookSessionPhase.degraded,
          gamePid: gamePid,
          fallbackReason: 'window_not_found',
        ),
      );
      _record(
        GalHookEventSeverity.warning,
        'window',
        'window.not_found',
        'Audio hook is active, but no game window was found for screenshots',
      );
      // BUG-1049：开场那 10 秒只是「窗口通常多快出现」的经验值，不是硬事实——带启动器 /
      // 壳解包 / 首次着色器编译的游戏常常更慢，而首帧一旦错过，旧实现就永久停在
      // window_not_found，用户只能自己去点「捕获目标」条手动选窗口（明明是 Hibiki 自己
      // 启动的进程）。绑定因此改成会话级监视：只要这条会话还活着且仍没有窗口，就继续
      // 按同一个 pid 找，找到即自动绑上。
      // gamePid 为空表示 hook 根本没拿到目标进程，没有可重试的匹配依据。
      if (gamePid != null) _startWindowRebindWatch(generation, gamePid);
    }
    return const GalHookLaunchResult.launched();
  }

  /// launch 会话的窗口重绑监视：周期性按 [gamePid] 找顶层窗口，找到就补上绑定并把
  /// 因 `window_not_found` 降级的会话恢复回真实 phase（文本信号来了就是 running，
  /// 否则还在等信号）。绑定成功 / 会话被换代（stop、重启、attach）即自停。
  ///
  /// 只更新状态，不走 [bindWindow]——那条路径是给「用户手动改绑另一个窗口」用的，
  /// 会 [startAttachedCapture] 重启整条会话；这里 hook 已经在跑，重启只会丢台词。
  void _startWindowRebindWatch(int generation, int gamePid) {
    _windowRebindTimer?.cancel();
    _windowRebindTimer = Timer.periodic(_windowRebindInterval, (Timer timer) {
      if (generation != _operationGeneration ||
          _state.boundWindow != null ||
          _state.gamePid != gamePid) {
        timer.cancel();
        _windowRebindTimer = null;
        return;
      }
      if (_windowRebindInFlight) return;
      _windowRebindInFlight = true;
      unawaited(
        _tryRebindWindow(generation, gamePid).whenComplete(() {
          _windowRebindInFlight = false;
        }),
      );
    });
  }

  Future<void> _tryRebindWindow(int generation, int gamePid) async {
    final List<ExternalWindowInfo> windows = await _windowListLoader();
    if (generation != _operationGeneration ||
        _state.boundWindow != null ||
        _state.gamePid != gamePid) {
      return;
    }
    for (final ExternalWindowInfo candidate in windows) {
      if (candidate.pid != gamePid) continue;
      _windowRebindTimer?.cancel();
      _windowRebindTimer = null;
      final bool degradedForWindow =
          _state.phase == GalHookSessionPhase.degraded &&
              _state.fallbackReason == 'window_not_found';
      _setState(
        _state.copyWith(
          boundWindow: candidate,
          gamePid: gamePid,
          phase: degradedForWindow
              ? (_state.textSignalReceived
                  ? GalHookSessionPhase.running
                  : GalHookSessionPhase.waitingSignals)
              : _state.phase,
          clearFallbackReason: degradedForWindow,
        ),
      );
      _record(
        GalHookEventSeverity.success,
        'window',
        'window.auto_bound_late',
        'Bound the launched game window once it appeared',
        details: <String, Object?>{'pid': gamePid, 'hwnd': candidate.hwnd},
      );
      return;
    }
  }

  Future<void> stopCapture({bool keepBinding = true}) async {
    ++_operationGeneration;
    // 会话结束先把剩余累计落库，再复位记账并解除游戏归属（防停后串扰）。
    _flushGameActivity();
    _activityAccumulator.reset();
    _activityGameTitle = null;
    _activityGameKey = null;
    if (_state.phase == GalHookSessionPhase.idle && _audioSource == null) {
      _setState(
        _state.copyWith(
          externalWindowMode: false,
          clearBoundWindow: !keepBinding,
          textSignalReceived: false,
        ),
      );
      return;
    }
    _setState(_state.copyWith(phase: GalHookSessionPhase.stopping));
    _record(
      GalHookEventSeverity.info,
      'session',
      'session.stop_listening',
      'Stopping listeners and helper; injected game code may remain until exit',
    );
    // 超分的关闭**不在这里手写**：它跟着下面 phase → idle 的状态跃迁自动发生
    // （见 [_syncMagpieUpscaling]）。手写调用点正是早退分支漏关的根因。
    await _stopSources();
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.idle,
        externalWindowMode: false,
        audioBackend: GalHookAudioBackend.none,
        clearAudioFormat: true,
        clearGamePid: true,
        clearLaunchExe: true,
        clearSessionStartedAt: true,
        clearFallbackReason: true,
        clearLastError: true,
        textSignalReceived: false,
        clearBoundWindow: !keepBinding,
        audioTracks: const <GalAudioTrack>[],
        selectedAudioSourcePtr: 0,
        excludedAudioSourcePtrs: const <int>{},
      ),
    );
    _resetCaptureMemorySession();
    _record(
      GalHookEventSeverity.success,
      'session',
      'session.listeners_stopped',
      'Capture listeners stopped',
    );
  }

  /// 两份音轨快照的「轨成员」是否一致（只比 sourcePtr 序列）。低频自动刷新下
  /// clipCount / 能量持续变化，若纳入判等，事件日志会被每轮刷新刷成噪音——
  /// 只有轨的出现/消失才值得记一条结构化事件。
  @visibleForTesting
  static bool sameTrackMembership(
    List<GalAudioTrack> a,
    List<GalAudioTrack> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].sourcePtr != b[i].sourcePtr) return false;
    }
    return true;
  }

  Future<void> refreshAudioTracks() async {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) {
      if (_state.audioTracks.isNotEmpty) {
        _setState(_state.copyWith(audioTracks: const <GalAudioTrack>[]));
      }
      return;
    }
    final int timestamp = _lineTimestampCache.values.isEmpty
        ? 0
        : _lineTimestampCache.values.last;
    final List<GalAudioTrack> tracks = await engine.listAudioTracks(timestamp);
    // await 期间会话可能已停止/重启：旧 engine 的快照不落地（同 BUG-950 范式）。
    if (engine != _engineSource) return;
    final bool membershipChanged =
        !sameTrackMembership(_state.audioTracks, tracks);
    _setState(_state.copyWith(audioTracks: tracks));
    if (tracks.isNotEmpty && !_trackMemoryApplied) {
      _trackMemoryApplied = true;
      _applyTrackMemory(engine, tracks);
    }
    // BUG-1027：刷新已由定时器/状态迁移自动驱动，只有轨成员变化才记事件，
    // 避免 5s 一条「已刷新」把事件日志淹掉。
    if (membershipChanged) {
      _record(
        GalHookEventSeverity.info,
        'audio',
        'audio.tracks_refreshed',
        'Audio track snapshot refreshed',
        details: <String, Object?>{'count': tracks.length},
      );
    }
  }

  /// BUG-1027：音轨快照不再依赖诊断页手动刷新。
  ///
  /// 每次会话激活 / 音频后端切换后（含 [_promoteLateResourceAudio]）先立即刷一次；
  /// 引擎 PCM 与「文本 + Loopback 混合」（engine 仍存活）两种形态另起**会话级**低频
  /// 定时器持续刷新。定时器挂在会话生命周期而非诊断页可见性上：控制器不感知页面
  /// 路由，且 [_trackRefreshInterval]（默认 5s）一次的共享内存枚举成本可忽略，为可见性
  /// 门控引入页面回调只会增加状态同步面。gameResource 模式语音走逐句资源文件、不进
  /// PCM 环（voice_hook_reader.cpp:546 只枚举 PCM 环），刷一次保持快照一致即可，不开
  /// 定时器。[_stopSources] 统一回收定时器。
  void _syncTrackAutoRefresh() {
    _trackRefreshTimer?.cancel();
    _trackRefreshTimer = null;
    if (_engineSource == null) return;
    unawaited(refreshAudioTracks());
    final GalHookAudioBackend backend = _state.audioBackend;
    if (backend == GalHookAudioBackend.enginePcm ||
        backend == GalHookAudioBackend.systemLoopback) {
      _trackRefreshTimer = Timer.periodic(
        _trackRefreshInterval,
        (_) => unawaited(refreshAudioTracks()),
      );
    }
  }

  /// 试听指定音轨（BUG-1027）：按最近一条 hook 台词时间戳，经既有 `grabUtterance`
  /// IPC 抓取该 [sourcePtr] 在 `[ts-200, ts+6000]` 窗口内的整句 PCM（native
  /// `GrabUtterance`，voice_hook_reader.cpp:408——`target_source` 非 0 时直接按轨过滤；
  /// exclude 传空集，试听已标记 BGM 的轨同样允许），拼成 WAV 写入系统临时目录，播放
  /// 器可直接播（无需 ffmpeg 转码）。无 engine / 尚无台词时间戳 / 该轨窗口内无 PCM /
  /// 写盘失败时返回 null 并记结构化事件（调用方 toast 提示，不静默）。
  Future<GalTrackPreview?> exportTrackPreview(int sourcePtr) async {
    final int timestamp = _lineTimestampCache.values.isEmpty
        ? 0
        : _lineTimestampCache.values.last;
    return _exportTrackPreviewAt(sourcePtr, timestamp);
  }

  /// 逐句选轨弹窗的试听必须与确认选轨共用同一 [lineId] 时间戳。旧实现调用
  /// [exportTrackPreview] 偷用了最新一句，导致用户能听见最新句，却为较早行确认时收到
  /// 「该句没有音轨」。
  Future<GalTrackPreview?> exportLineTrackPreview(
    String lineId,
    int sourcePtr,
  ) async {
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (entry == null || !isLineInCurrentSession(entry) || timestamp <= 0) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.line_track_preview_unavailable',
        'Per-line track preview needs a current hooked line timestamp',
        details: <String, Object?>{
          'lineId': lineId,
          'sourcePtr': sourcePtr,
          'tsMs': timestamp,
        },
      );
      return null;
    }
    return _exportTrackPreviewAt(sourcePtr, timestamp, lineId: lineId);
  }

  Future<GalTrackPreview?> _exportTrackPreviewAt(
    int sourcePtr,
    int timestamp, {
    String? lineId,
  }) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return null;
    final GalAudioSlice? slice = await engine.grabUtterance(
      timestamp,
      sourcePtr: sourcePtr,
      exclude: const <int>[],
    );
    if (slice == null || slice.isEmpty) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.track_preview_empty',
        'No recent PCM was available on the selected track',
        details: <String, Object?>{
          'sourcePtr': sourcePtr,
          'tsMs': timestamp,
          if (lineId != null) 'lineId': lineId,
        },
      );
      return null;
    }
    try {
      final Directory dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'hibiki_gal_track_preview',
      );
      await dir.create(recursive: true);
      final File out = File(
        '${dir.path}${Platform.pathSeparator}'
        '${galTrackPreviewFileName(sourcePtr: sourcePtr, timestampMs: timestamp)}',
      );
      await out.writeAsBytes(buildWavBytes(slice.pcm, slice.format),
          flush: true);
      final int durationMs =
          pcmDurationMs(slice.pcm.length, slice.format.byteRate);
      _record(
        GalHookEventSeverity.info,
        'audio',
        'audio.track_preview_ready',
        'Track preview clip exported',
        details: <String, Object?>{
          'sourcePtr': sourcePtr,
          'durationMs': durationMs,
        },
      );
      return GalTrackPreview(filePath: out.path, durationMs: durationMs);
    } catch (error, stack) {
      _record(
        GalHookEventSeverity.error,
        'audio',
        'audio.track_preview_failed',
        'Track preview export failed',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
      );
      return null;
    }
  }

  /// 测试缝：向行级 PCM 缓存注入一条冻结切片（[exportLineAudioPreview] 的 ② 路径
  /// 依赖会话期缓存，单测无真实引擎会话）。
  @visibleForTesting
  void debugCacheLineVoice(String lineId, GalAudioSlice slice) {
    _lineVoiceCache[lineId] = slice;
  }

  /// 试听指定台词行已配的音频（实时台词列表行内播放按钮）：
  ///  ① `game_resource` 行 → 直接返回 dump 目录里的原始资源文件路径（OGG/WAV，
  ///     播放器原生可解，**不走** ffmpeg 转码链；时长未知记 0，调用方按上限兜底复位）；
  ///  ② 引擎 PCM / loopback 兜底行 → [_lineVoiceCache] 冻结切片拼 WAV 写临时目录。
  /// 只读既有配对结果，不改行状态、不影响制卡链路；取不到返回 null 并记结构化事件。
  Future<GalTrackPreview?> exportLineAudioPreview(String lineId) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    // 用户裁决过的行只播它自己的冻结切片，绝不回头播资源原件。
    final String? resourceId =
        _isUserAdjudicated(lineId) ? null : _resourceIdForLine(lineId);
    if (engine != null && resourceId != null) {
      // BUG-1109：hook 可能还在写这个原件，直接播会听到被截断的半句。
      final String? path =
          await engine.settledPairedVoiceFilePathForResourceId(resourceId);
      if (path != null) {
        return GalTrackPreview(filePath: path, durationMs: 0);
      }
    }
    final GalAudioSlice? slice = _lineVoiceCache[lineId];
    if (slice != null && !slice.isEmpty) {
      try {
        final Directory dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'hibiki_gal_track_preview',
        );
        await dir.create(recursive: true);
        final File out = File(
          '${dir.path}${Platform.pathSeparator}gal_line_preview_$lineId.wav',
        );
        await out.writeAsBytes(buildWavBytes(slice.pcm, slice.format),
            flush: true);
        return GalTrackPreview(
          filePath: out.path,
          durationMs: pcmDurationMs(slice.pcm.length, slice.format.byteRate),
        );
      } catch (error) {
        _record(
          GalHookEventSeverity.error,
          'audio',
          'audio.line_preview_failed',
          'Line preview export failed',
          details: <String, Object?>{'lineId': lineId, 'error': '$error'},
        );
        return null;
      }
    }
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.line_preview_unavailable',
      'No playable audio for the selected line',
      details: <String, Object?>{'lineId': lineId},
    );
    return null;
  }

  // ── 手动补录（浮窗「重播并录音」）────────────────────────────────────────
  /// 补录窗口上限：够用户在游戏里找到并触发一次「重播这句语音」、再等它播完；到点自动收束。
  ///
  /// BUG-1094：旧值是 8000ms，注释说这是因为「loopback 环只保留这么长」——**那是错的**。
  /// native 环形缓冲实际保留 60 秒（audio_loopback_capture.cpp:21 `kRingSeconds = 60`）。
  /// 「补录窗口时长」与「回取长度上限」是两个互不相干的量：前者只由「用户要多久才能
  /// 去游戏里点一次重播」决定，后者是环的真实容量 [_loopbackRingCapacityMs]。把二者
  /// 绑在一个常量上，等于用一个不存在的存储限制去砍用户的操作时间。
  ///
  /// 窗口并非唯一收束源：再点一次 ⏺ 立即收束（[toggleLineRecapture]），
  /// 新台词到达（玩家已经翻页）也收束（见 [_pollHookedText]）。
  static const Duration _recaptureWindow = Duration(seconds: 20);

  /// 补录至少回取的毫秒数：用户手速极快时也别取出一段空 PCM。
  static const int _recaptureMinBackMs = 500;

  String? _recapturingLineId;
  Timer? _recaptureTimer;
  Stopwatch? _recaptureElapsed;

  /// 引擎资源/PCM 会话里临时拉起的 loopback 源（会话本身没有 loopback 时才有），
  /// 补录结束即停——不改变会话的常驻音源。
  LoopbackGalAudioSource? _recaptureTempSource;

  /// 手动补录过的行：制卡与试听时其冻结切片**优先于**资源配对。用户手动补录本身
  /// 就是「自动配对的结果不对」的判据，绝不能再被 game_resource 覆盖回去。
  final Set<String> _manualRecaptureLines = <String>{};

  /// 用户为**单条台词**显式指定的语音轨（会话内 source_ptr，见 [setLineVoiceTrack]）。
  /// 与 [_manualRecaptureLines] 同级的用户裁决：制卡、试听、延迟资源匹配都必须让路。
  /// 两者互斥——后做的那一次覆盖前一次。
  final Map<String, int> _lineVoiceSourcePtr = <String, int>{};

  String? get recapturingLineId => _recapturingLineId;
  bool get isRecapturing => _recapturingLineId != null;

  @visibleForTesting
  bool debugIsManualRecapture(String lineId) =>
      _manualRecaptureLines.contains(lineId);

  /// 浮窗「重播并录音」：正在补录同一行 → 立即收束；否则为 [lineId] 开一段补录窗口。
  Future<bool> toggleLineRecapture(String lineId) async {
    if (_recapturingLineId == lineId) {
      return finishLineRecapture();
    }
    if (_recapturingLineId != null) {
      await finishLineRecapture();
    }
    return startLineRecapture(lineId);
  }

  /// 开始为 [lineId] 补录：确保有一个在录的 loopback 环，随后等用户在游戏里重播该句
  /// 语音。到 [_recaptureWindow] 自动收束，也可再点一次按钮提前收束。
  Future<bool> startLineRecapture(String lineId) async {
    if (_recapturingLineId != null) return false;
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    if (entry == null || !isLineInCurrentSession(entry)) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.recapture_line_unavailable',
        'Recapture target line is not part of the current session',
        details: <String, Object?>{'lineId': lineId},
      );
      return false;
    }
    LoopbackGalAudioSource? temp;
    if (_audioSource is! LoopbackGalAudioSource) {
      temp = _loopbackSourceFactory();
      final PcmFormat? format = await temp.start();
      if (format == null) {
        await temp.stop();
        _record(
          GalHookEventSeverity.error,
          'audio',
          'audio.recapture_source_unavailable',
          'System loopback could not be started for manual recapture',
          details: <String, Object?>{'lineId': lineId},
        );
        return false;
      }
    }
    _recaptureTempSource = temp;
    _recapturingLineId = lineId;
    // 这行的自动延迟冻结已被用户裁决取代，别让它到点后再盖一次。
    _loopbackFreezeTimers.remove(lineId)?.cancel();
    _loopbackFreezeStartedAt.remove(lineId);
    _recaptureElapsed = Stopwatch()..start();
    _recaptureTimer = Timer(
      _recaptureWindow,
      () => unawaited(finishLineRecapture()),
    );
    _textService.updateLineAudio(
      lineId,
      status: TexthookerLineAudioStatus.pending,
      backend: 'system_loopback',
      fallbackReason: 'manual_recapture_recording',
    );
    _record(
      GalHookEventSeverity.info,
      'audio',
      'audio.recapture_started',
      'Manual voice recapture window opened',
      details: <String, Object?>{'lineId': lineId},
    );
    notifyListeners();
    return true;
  }

  /// 收束当前补录窗口：把窗口内的 loopback 环冻结成该行的语音（[discard] 时只收束
  /// 不取音，用于会话结束）。取不到声音时把行标成 missing，不留“录了但没有”的假象。
  Future<bool> finishLineRecapture({bool discard = false}) async {
    final String? lineId = _recapturingLineId;
    if (lineId == null) return false;
    _recaptureTimer?.cancel();
    _recaptureTimer = null;
    final int elapsedMs = _recaptureElapsed?.elapsedMilliseconds ?? 0;
    _recaptureElapsed = null;
    _recapturingLineId = null;
    final LoopbackGalAudioSource? temp = _recaptureTempSource;
    _recaptureTempSource = null;
    final GalAudioSource? live = _audioSource;
    final LoopbackGalAudioSource? source =
        temp ?? (live is LoopbackGalAudioSource ? live : null);
    notifyListeners();
    try {
      if (discard || source == null) {
        if (!discard) _markLineAudioMissing(lineId, 'manual_recapture_empty');
        return false;
      }
      // 回取长度只由本次窗口的**真实已用时间**决定，上限是环的真实容量。
      final int backMs =
          elapsedMs.clamp(_recaptureMinBackMs, _loopbackRingCapacityMs).toInt();
      final GalAudioSlice? slice = await _audioQueue.enqueue<GalAudioSlice?>(
        () => source.grabRecent(backMs),
        buildFailure: (Object error, StackTrace stack) => null,
        onError: (Object error, StackTrace stack) => _record(
          GalHookEventSeverity.error,
          'audio',
          'audio.recapture_exception',
          'Manual voice recapture failed',
          details: <String, Object?>{'lineId': lineId, 'error': '$error'},
        ),
      );
      if (slice == null || slice.isEmpty) {
        _markLineAudioMissing(lineId, 'manual_recapture_empty');
        return false;
      }
      _lineVoiceCache[lineId] = slice;
      _trimCache(_lineVoiceCache);
      _manualRecaptureLines.add(lineId);
      // 补录即用户裁决：清掉这行的资源配对与逐行选轨，也别让延迟资源匹配改回去。
      _pendingResourceMatches.remove(lineId);
      _lineVoiceSourcePtr.remove(lineId);
      _textService.updateLineAudio(
        lineId,
        status: TexthookerLineAudioStatus.fallback,
        backend: 'system_loopback',
        durationMs: (slice.pcm.length * 1000) ~/ slice.format.byteRate,
        fallbackReason: 'manual_recapture',
        clearResourceId: true,
      );
      _record(
        GalHookEventSeverity.success,
        'match',
        'audio.recapture_locked',
        'Manually recaptured audio locked to the line',
        details: <String, Object?>{'lineId': lineId, 'backMs': backMs},
      );
      return true;
    } finally {
      await temp?.stop();
      notifyListeners();
    }
  }

  void selectVoiceTrack(int sourcePtr) {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) {
      // BUG-1027：此前静默 return，诊断页点 radio 毫无反馈。记结构化警告事件，
      // 页面另以 toast 明示「选轨需要引擎 hook 会话」。
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.voice_track_select_unavailable',
        'Voice-track selection requires an active engine hook session',
        details: <String, Object?>{'sourcePtr': sourcePtr},
      );
      return;
    }
    engine.selectedAudioSourcePtr = sourcePtr;
    _setState(_state.copyWith(selectedAudioSourcePtr: sourcePtr));
    _persistVoiceTrack(sourcePtr);
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.voice_track_selected',
      sourcePtr == 0
          ? 'Automatic voice-track selection enabled'
          : 'Voice track selected',
      details: <String, Object?>{'sourcePtr': sourcePtr},
    );
  }

  /// 本行是否属于当前选定的文本线程（v13 消费期过滤，等价于旧的 native 采集期门控）。
  ///
  /// 判据逐条对应 native 的 `LunaSelectedThreadAccepts`：
  /// * 未选定线程 → 一行都不放行（与 v12 起的 UX 一致：由 UI 引导用户从线程预览里挑）；
  /// * 精确 threadId 命中 → 放行，并顺手记下它的 hook 面；
  /// * 同一 hook 面命中 → 放行（BUG-1159：同 hook 面换调用点会让 threadId 变）。
  bool _acceptsLineFromSelectedThread(GalHookedLine line) {
    final int? selected = _selectedNativeTextThreadId;
    if (selected == null || selected == 0) return false;
    if (line.threadId == selected) {
      if (line.faceId != 0) _selectedTextThreadFaceId = line.faceId;
      _claimThreadKey(line);
      return true;
    }
    if (_selectedTextThreadFaceId != 0 &&
        line.faceId == _selectedTextThreadFaceId) {
      _claimThreadKey(line);
      return true;
    }
    return false;
  }

  /// 采集期放行一行 ⇒ 认领它的线程 key，供发布期 [_publishesUnderSelection] 查表。
  void _claimThreadKey(GalHookedLine line) {
    final String? key = line.textThreadKey;
    if (key != null && key.isNotEmpty) _selectedThreadClaimedKeys.add(key);
  }

  /// v13 文本分道的容量压力上报（每次计数增长各播一次，不刷屏）。
  ///
  /// 为什么必须报：道用尽时的症状——某些线程的台词就是不来——与 v13 要根治的 256 槽挤压
  /// **完全同形**，真机上光看现象分不出「分道没生效」还是「64 条道不够用」。而放开非胜出
  /// 线程本身就抬高了道满概率（以前只有选定线程占道，现在每条线程都占一条），把它做成
  /// 静默丢弃等于把要修的病换个地方藏起来。
  ///
  /// 两级分开报：`recycle` 是降级但没丢行（顶掉了最久没写的非选定道），`overflow` 是**真丢了行**。
  int _reportedLaneRecycles = 0;
  int _reportedLaneOverflows = 0;

  void _reportTextLanePressure(EngineHookGalAudioSource engine) {
    final int recycles = engine.textLaneRecycles;
    final int overflows = engine.textLaneOverflows;
    if (recycles > _reportedLaneRecycles) {
      _reportedLaneRecycles = recycles;
      _record(
        GalHookEventSeverity.info,
        'text',
        'text.lane_recycled',
        'Text lanes exhausted; recycled the least recently used non-selected lane',
        details: <String, Object?>{'recycles': recycles},
      );
    }
    if (overflows > _reportedLaneOverflows) {
      _reportedLaneOverflows = overflows;
      _record(
        GalHookEventSeverity.warning,
        'text',
        'text.lane_overflow',
        'Text lanes exhausted with nothing recyclable; lines were dropped',
        details: <String, Object?>{'overflows': overflows},
      );
    }
  }

  /// 换线程后，把该线程留在**自己那条道**里的历史行补进工作台（v13 分道的直接收益）。
  ///
  /// v12 之前非选定线程的行在采集期就被丢了，选错线程 = 那段台词永远追不回来，只能重打
  /// 一遍剧情。v13 每条线程都在写自己的道，所以「刚才漏掉的那几句」其实还在共享内存里：
  /// 选中它的那一刻按道回捞即可。回捞只补**文本**（游标之前的行），不重放音频抓取——
  /// 那些行的时刻早已过去，硬跑一遍只会给每句都盖上「疑似漏抓」的红标；真要补音频，
  /// 逐句重录（[startLineRecapture]）是既有且更准的入口。
  Future<void> _recoverSelectedThreadHistory() async {
    final EngineHookGalAudioSource? engine = _engineSource;
    final int? selected = _selectedNativeTextThreadId;
    if (engine == null || selected == null || selected == 0) return;
    if (_lastTextSeq <= 0) return; // 还没消费过任何行，没有「之前」可补
    final GalTextPoll? poll = await engine.pollText(0);
    if (poll == null || engine != _engineSource) return;
    final Set<int> appended = _lineTextEventIdCache.values.toSet();
    // 两趟：先把整批的 hook 面学完，再筛。
    // 单趟不行——[_acceptsLineFromSelectedThread] 是带副作用的判据（精确命中时才学 face），
    // 而 native 按 seq 升序返回，排在第一条精确命中**之前**的同 hook 面兄弟行会被判 false
    // 且不再复评，静默漏捞。回捞本身就是"补回选中之前的行"，这个顺序依赖必然踩中。
    for (final GalHookedLine line in poll.lines) {
      if (line.eventKind != GalTextEventKind.line) continue;
      if (line.threadId == selected && line.faceId != 0) {
        _selectedTextThreadFaceId = line.faceId;
      }
    }
    final List<GalHookedLine> history = poll.lines
        .where((GalHookedLine line) =>
            line.eventKind == GalTextEventKind.line &&
            line.seq <= _lastTextSeq &&
            !appended.contains(line.seq) &&
            line.text.trim().isNotEmpty &&
            !isGalgameSystemUiLine(line.text) &&
            _acceptsLineFromSelectedThread(line))
        .toList()
      ..sort((GalHookedLine a, GalHookedLine b) => a.seq.compareTo(b.seq));
    if (history.isEmpty) return;
    for (final GalHookedLine line in history) {
      final TexthookerLineEntry? entry = _textService.appendLine(
        line.text,
        source: TexthookerLineSource.engineHook,
        sourceLabel: 'engine_hook',
        sourceSequence: line.seq,
        hookTimestampMs: line.timestampMs,
        textThreadKey: line.textThreadKey,
        textThreadLabel: line.textThreadLabel,
        textHookCode: line.hookCode.isEmpty ? null : line.hookCode,
        nativeTextThreadId: line.threadId == 0 ? null : line.threadId,
        audioStatus: TexthookerLineAudioStatus.unavailable,
      );
      if (entry == null) continue;
      _lineTimestampCache[entry.id] = line.timestampMs;
      _lineTextEventIdCache[entry.id] = line.seq;
    }
    _trimCache(_lineTimestampCache);
    _trimCache(_lineTextEventIdCache);
    _record(
      GalHookEventSeverity.info,
      'text',
      'text.thread_history_recovered',
      'Recovered buffered lines from the newly selected text thread',
      details: <String, Object?>{
        'threadId': selected,
        'lines': history.length,
      },
    );
  }

  /// 选择文本线程。
  ///
  /// [remember] = true（用户在 UI 里主动选）时把选择写进每游戏记忆，并锁死本会话的
  /// 自动恢复；记忆恢复自身调用时传 false，免得把「恢复」当成一次新的用户选择再写回。
  Future<bool> selectTextThread(
    int? threadId, {
    String? threadKey,
    bool remember = false,
  }) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    // WebSocket/剪贴板等外部 Hook 线程没有 native helper，也仍需由 app 级状态
    // 驱动工作台与浮窗过滤；有 helper 时再同步其 native thread id。
    final bool selected =
        engine == null || await engine.selectTextThread(threadId);
    if (selected) {
      _selectedTextThreadKey =
          threadKey == null || threadKey.isEmpty ? null : threadKey;
      _selectedNativeTextThreadId =
          threadId == null || threadId == 0 ? null : threadId;
      // 换线程就必须丢掉上一条线程的 hook 面，否则旧 face 会继续放行旧线程的行。
      _selectedTextThreadFaceId = 0;
      // 认领集合用选定 key 自身播种：绕过采集期直接塞行的来源（无 helper 的
      // WebSocket/剪贴板线程）据此保持原行为，引擎行则由采集期继续追加同 hook 面的
      // 兄弟 key。换线程必须整体重置，否则上一条线程的 key 会继续放行它的行。
      _selectedThreadClaimedKeys
        ..clear()
        ..addAll(<String>{
          if (_selectedTextThreadKey != null) _selectedTextThreadKey!,
        });
      // 有 helper 却拿不到 native thread id：采集期判据 (_selectedNativeTextThreadId)
      // 会对**所有**行返回 false，而 selectedTextThreadKey 非空又让就绪态判成
      // 「正在监听」——弹窗关掉、状态条正常、一行文本都不来的静默死态。显式报出来。
      if (engine != null &&
          _selectedTextThreadKey != null &&
          _selectedNativeTextThreadId == null) {
        _record(
          GalHookEventSeverity.warning,
          'text',
          'text.thread_selection_without_native_id',
          'Selected text thread has no native thread id; no lines will arrive',
          details: <String, Object?>{'threadKey': _selectedTextThreadKey},
        );
      }
      // 新线程在被选中之前写进自己那条道的行，现在补回来（v13 分道的直接收益）。
      await _recoverSelectedThreadHistory();
      if (remember) {
        // 用户已亲自表态：本会话不再自动恢复，并把这次选择记成新的真值。
        _textThreadMemoryApplied = true;
        TexthookerTextThread? chosen;
        for (final TexthookerTextThread thread in _textService.textThreads) {
          if (thread.key == _selectedTextThreadKey) {
            chosen = thread;
            break;
          }
        }
        _persistTextThread(chosen);
      }
    }
    _record(
      selected ? GalHookEventSeverity.success : GalHookEventSeverity.warning,
      'text',
      selected ? 'text.thread_selected' : 'text.thread_select_failed',
      threadId == null || threadId == 0
          ? 'Text thread selection cleared'
          : 'Text thread selected',
      details: <String, Object?>{
        'threadId': threadId ?? 0,
        if (threadKey != null) 'threadKey': threadKey,
      },
    );
    if (selected) notifyListeners();
    return selected;
  }

  /// 单条台词改用指定音轨重抓语音（BUG-1102 的真正出口）。
  ///
  /// 会话级 [selectVoiceTrack] 只改自动选源的默认值，且只在引擎 PCM 是当前音源时生效；
  /// 用户在实时台词列表里对**某一句**说「这句应该用这条轨」是与手动补录同级的裁决，
  /// 因此这里显式绕开 `identical(_audioSource, engine)` 那道自动门（那道门防的是**自动**
  /// 误配，BUG-1060，不能因为本需求就放宽它），直接按 [sourcePtr] 重抓整句。
  ///
  /// 抓不到（该轨在该句窗口内无 PCM）返回 false 并记结构化事件，绝不静默改状态。
  /// 注意 source_ptr 只在**本次会话内**稳定（见 [EngineHookGalAudioSource.
  /// selectedAudioSourcePtr] 的 TODO），因此本映射刻意只活在内存里，不做跨会话持久化。
  Future<bool> setLineVoiceTrack(String lineId, int sourcePtr) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (engine == null ||
        entry == null ||
        !isLineInCurrentSession(entry) ||
        timestamp <= 0) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.line_track_unavailable',
        'Per-line voice-track override needs a live engine session and a hooked '
            'line timestamp',
        details: <String, Object?>{
          'lineId': lineId,
          'sourcePtr': sourcePtr,
          'tsMs': timestamp,
        },
      );
      return false;
    }
    final GalAudioSlice? slice = await _audioQueue.enqueue<GalAudioSlice?>(
      () => engine.grabUtterance(
        timestamp,
        sourcePtr: sourcePtr,
        exclude: const <int>[],
      ),
      buildFailure: (Object error, StackTrace stack) => null,
      onError: (Object error, StackTrace stack) => _record(
        GalHookEventSeverity.error,
        'audio',
        'audio.line_track_exception',
        'Per-line voice-track grab failed',
        details: <String, Object?>{'lineId': lineId, 'error': '$error'},
      ),
    );
    // BUG-950 范式：入队到执行之间可能夹一次 stop/重启，旧会话的结果不落地。
    if (engine != _engineSource) return false;
    if (slice == null || slice.isEmpty) {
      _record(
        GalHookEventSeverity.warning,
        'audio',
        'audio.line_track_empty',
        'The selected track has no PCM around this line',
        details: <String, Object?>{
          'lineId': lineId,
          'sourcePtr': sourcePtr,
          'tsMs': timestamp,
        },
      );
      return false;
    }
    _lineVoiceCache[lineId] = slice;
    _trimCache(_lineVoiceCache);
    _lineVoiceSourcePtr[lineId] = sourcePtr;
    _trimCache(_lineVoiceSourcePtr);
    // 选轨与补录互斥，且都要挡住延迟资源匹配 / 延迟 loopback 冻结把结果改回去。
    _manualRecaptureLines.remove(lineId);
    _pendingResourceMatches.remove(lineId);
    _loopbackFreezeTimers.remove(lineId)?.cancel();
    _loopbackFreezeStartedAt.remove(lineId);
    _textService.updateLineAudio(
      lineId,
      status: TexthookerLineAudioStatus.matched,
      backend: 'engine_pcm',
      durationMs: (slice.pcm.length * 1000) ~/ slice.format.byteRate,
      fallbackReason: 'manual_track_override',
      clearResourceId: true,
    );
    _record(
      GalHookEventSeverity.success,
      'match',
      'audio.line_track_selected',
      'User-selected voice track locked to the line',
      details: <String, Object?>{'lineId': lineId, 'sourcePtr': sourcePtr},
    );
    notifyListeners();
    return true;
  }

  /// **这一句**当前生效的音轨（用户逐行选轨的结果）；null = 未逐行指定，走会话
  /// 级选轨 / 自动选源。捕获工作台的逐句音轨面板据此显示"本句用的是哪条轨"。
  int? lineVoiceSourcePtr(String lineId) => _lineVoiceSourcePtr[lineId];

  /// 取**这一句时刻**的音轨快照（工作台逐句音轨面板的数据源）。
  ///
  /// 与会话级 [refreshAudioTracks] 的区别只在时间戳：那个用最近一条台词的 ts
  /// 做会话级概览，这里必须用该行自己的 ts——不然用户看到的能量/片段数属于别的
  /// 句子，"排除这句里的 BGM"就成了盲操作。行不属于当前会话 / 无时间戳时返回空。
  Future<List<GalAudioTrack>> tracksForLine(String lineId) async {
    final EngineHookGalAudioSource? engine = _engineSource;
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (engine == null ||
        entry == null ||
        !isLineInCurrentSession(entry) ||
        timestamp <= 0) {
      return const <GalAudioTrack>[];
    }
    final List<GalAudioTrack> tracks = await engine.listAudioTracks(timestamp);
    // await 期间会话可能已停止/重启：旧 engine 的快照不落地（同 BUG-950 范式）。
    if (engine != _engineSource) return const <GalAudioTrack>[];
    return tracks;
  }

  /// 本行的语音是否由用户显式裁决过（手动补录或逐行选轨）。自动配对一律让路。
  bool _isUserAdjudicated(String lineId) =>
      _manualRecaptureLines.contains(lineId) ||
      _lineVoiceSourcePtr.containsKey(lineId);

  @visibleForTesting
  int? debugLineVoiceSourcePtr(String lineId) => _lineVoiceSourcePtr[lineId];

  void setTrackExcluded(int sourcePtr, bool excluded) {
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
    if (excluded) {
      engine.excludedAudioSourcePtrs.add(sourcePtr);
    } else {
      engine.excludedAudioSourcePtrs.remove(sourcePtr);
    }
    _setState(
      _state.copyWith(
        excludedAudioSourcePtrs: Set<int>.unmodifiable(
          engine.excludedAudioSourcePtrs,
        ),
      ),
    );
    _persistTrackExclusion(sourcePtr, excluded);
    _record(
      GalHookEventSeverity.info,
      'audio',
      excluded ? 'audio.track_excluded' : 'audio.track_restored',
      excluded ? 'Audio track marked as BGM/excluded' : 'Audio track restored',
      details: <String, Object?>{'sourcePtr': sourcePtr},
    );
  }

  /// 注入每游戏捕获选择记忆的持久化端口（桌面启动流程
  /// [GalHookTextOverlayController.start] 调用一次，真值落偏好表）。不注入 =
  /// 选择只活在会话内，行为与旧版一致。
  void attachCaptureMemory({
    required GalCaptureMemoryLoad load,
    required GalCaptureMemorySave save,
  }) {
    _captureMemoryLoad = load;
    _captureMemorySave = save;
  }

  /// 音轨的跨会话弱指纹。`source_ptr` 只在会话内稳定（跨启动是新指针），能锚的只有
  /// [GalAudioTrack.orderIndex]（创建顺序，跨启动相对稳定）+ PCM 格式。指纹可能撞/漂
  /// ——所以记忆只恢复用户显式选择的排除项和语音轨；排除优先，恢复结果在工作台可见，
  /// 用户可在映射漂移时立即纠正。
  @visibleForTesting
  static String trackFingerprint(GalAudioTrack track) =>
      '${track.orderIndex}:${track.format.sampleRate}:'
      '${track.format.channels}:${track.format.bitsPerSample}:'
      '${track.format.isFloat ? 1 : 0}';

  /// 文本线程的跨会话弱指纹。native `thread_id` 混了 processId（injector 侧
  /// FNV-1a），跨启动必变；能锚的只有 LunaHook 的 hook code（同一 hook 稳定）。
  /// 没有 hook code 的来源（GDI / Unity / WebSocket）退回标签。
  ///
  /// 同一 hook code 常有多条并行线程（ctx/ctx2 不同，未透出到 Dart），因此指纹
  /// **不足以唯一定位线程**——恢复时还要靠「谁真的在出台词」消歧，见
  /// [_maybeRestoreTextThread]。
  @visibleForTesting
  static String? textThreadFingerprint(TexthookerTextThread thread) {
    final String? code = thread.hookCode?.trim();
    if (code != null && code.isNotEmpty) return 'code:$code';
    final String label = thread.label.trim();
    return label.isEmpty ? null : 'label:$label';
  }

  String? _captureMemoryKeyForGame() {
    final String? exe = _state.launchExe;
    if (exe == null || exe.isEmpty) return null;
    return exe.toLowerCase();
  }

  /// 惰性加载当前游戏的记忆（每会话一次）。没有游戏身份（窗口附着、非启动路径）
  /// 就没有记忆——宁可少记，不猜身份。
  bool _ensureCaptureMemoryLoaded() {
    if (_captureMemoryLoaded) return _captureMemoryGameKey != null;
    _captureMemoryLoaded = true;
    final GalCaptureMemoryLoad? load = _captureMemoryLoad;
    final String? gameKey = _captureMemoryKeyForGame();
    if (load == null || gameKey == null) return false;
    _captureMemoryGameKey = gameKey;
    _captureMemory = load(gameKey);
    return true;
  }

  void _saveCaptureMemory(GalCaptureMemory memory) {
    _captureMemory = memory;
    final GalCaptureMemorySave? save = _captureMemorySave;
    final String? gameKey = _captureMemoryGameKey;
    if (save == null || gameKey == null) return;
    save(gameKey, memory);
  }

  /// 首个非空音轨快照到达时，把上次会话的排除集与语音轨按指纹套回当前轨。
  /// 只应用一次：环形越新鲜 orderIndex 越贴近真实创建序，越晚匹配越容易漂。
  void _applyTrackMemory(
    EngineHookGalAudioSource engine,
    List<GalAudioTrack> tracks,
  ) {
    if (!_ensureCaptureMemoryLoaded() || _captureMemory.isEmpty) return;
    final Set<String> excludedFps =
        _captureMemory.excludedTrackFingerprints.toSet();
    final String? voiceFp = _captureMemory.voiceTrackFingerprint;
    int excluded = 0;
    int? restoredVoicePtr;
    for (final GalAudioTrack track in tracks) {
      final String fingerprint = trackFingerprint(track);
      if (excludedFps.contains(fingerprint) &&
          engine.excludedAudioSourcePtrs.add(track.sourcePtr)) {
        excluded++;
      }
      if (voiceFp != null && fingerprint == voiceFp) {
        restoredVoicePtr ??= track.sourcePtr;
      }
    }
    // 被排除的轨不能同时是语音轨（用户后来把它标成了 BGM）：排除优先。
    if (restoredVoicePtr != null &&
        engine.excludedAudioSourcePtrs.contains(restoredVoicePtr)) {
      restoredVoicePtr = null;
    }
    if (excluded == 0 && restoredVoicePtr == null) return;
    if (restoredVoicePtr != null) {
      engine.selectedAudioSourcePtr = restoredVoicePtr;
    }
    _setState(
      _state.copyWith(
        excludedAudioSourcePtrs: Set<int>.unmodifiable(
          engine.excludedAudioSourcePtrs,
        ),
        selectedAudioSourcePtr:
            restoredVoicePtr ?? _state.selectedAudioSourcePtr,
      ),
    );
    _record(
      GalHookEventSeverity.info,
      'audio',
      'audio.track_memory_restored',
      'Restored per-game track choices from the previous session',
      details: <String, Object?>{
        'excluded': excluded,
        if (restoredVoicePtr != null) 'voiceSourcePtr': restoredVoicePtr,
      },
    );
  }

  /// 用户显式排除/恢复后同步持久化。恢复会把指纹从记忆里删掉——用户说了这条轨
  /// 不是 BGM，下次会话不得再自动排除它。
  void _persistTrackExclusion(int sourcePtr, bool excluded) {
    if (!_ensureCaptureMemoryLoaded()) return;
    final String? fingerprint = _fingerprintForSourcePtr(sourcePtr);
    if (fingerprint == null) return; // 快照里已不存在的轨谈不上指纹。
    final Set<String> fingerprints =
        _captureMemory.excludedTrackFingerprints.toSet();
    final bool changed = excluded
        ? fingerprints.add(fingerprint)
        : fingerprints.remove(fingerprint);
    if (!changed) return;
    _saveCaptureMemory(
      _captureMemory.copyWith(
        excludedTrackFingerprints: fingerprints.toList()..sort(),
      ),
    );
  }

  /// 用户显式选定/取消会话语音轨后同步持久化（0 = 自动选源，清掉记忆）。
  void _persistVoiceTrack(int sourcePtr) {
    if (!_ensureCaptureMemoryLoaded()) return;
    if (sourcePtr == 0) {
      if (_captureMemory.voiceTrackFingerprint == null) return;
      _saveCaptureMemory(_captureMemory.copyWith(clearVoiceTrack: true));
      return;
    }
    final String? fingerprint = _fingerprintForSourcePtr(sourcePtr);
    if (fingerprint == null ||
        _captureMemory.voiceTrackFingerprint == fingerprint) {
      return;
    }
    _saveCaptureMemory(
      _captureMemory.copyWith(voiceTrackFingerprint: fingerprint),
    );
  }

  String? _fingerprintForSourcePtr(int sourcePtr) {
    for (final GalAudioTrack track in _state.audioTracks) {
      if (track.sourcePtr == sourcePtr) return trackFingerprint(track);
    }
    return null;
  }

  /// 每次线程目录变动时尝试恢复上次会话选定的文本线程。
  ///
  /// 只在**用户本会话尚未手动选过**且恢复尚未发生时生效，且要求候选线程已出
  /// [_textThreadRestoreMinLines] 行——指纹只能锚到 hook 而锚不到具体并行线程
  /// （ctx 未透出），靠「谁真的在出台词」消歧。选中后本会话不再自动改，避免
  /// 行数此消彼长导致选择反复跳动。
  void _maybeRestoreTextThread() {
    if (_textThreadMemoryApplied || _selectedTextThreadKey != null) return;
    if (!_ensureCaptureMemoryLoaded()) return;
    final String? wanted = _captureMemory.textThreadFingerprint;
    if (wanted == null) return;
    TexthookerTextThread? best;
    for (final TexthookerTextThread thread in _textService.textThreads) {
      if (textThreadFingerprint(thread) != wanted) continue;
      // 🔴 判据必须用 observedLineCount（native 观测总行数），**不能**用 lineCount
      // （已发布行数）。v12 取消自动选线程后，用户选定之前文本环恒空、lineCount 对所有
      // 线程都是 0，用它做判据会让这里永远选不出候选 → 记忆永远恢复不了 → 每次开游戏
      // 都要重新手选。这正是「第一次由用户选」与「之后自动恢复」能同时成立的关键。
      if (thread.observedLineCount < _textThreadRestoreMinLines) continue;
      if (best == null || thread.observedLineCount > best.observedLineCount) {
        best = thread;
      }
    }
    if (best == null) return;
    _textThreadMemoryApplied = true;
    unawaited(
      selectTextThread(best.nativeThreadId, threadKey: best.key).then((
        bool selected,
      ) {
        if (!selected) return;
        _record(
          GalHookEventSeverity.info,
          'text',
          'text.thread_memory_restored',
          'Restored the text thread remembered for this game',
          details: <String, Object?>{'threadKey': best!.key},
        );
      }),
    );
  }

  /// 用户显式选定/取消文本线程后同步持久化（null = 未选择，清掉记忆）。
  void _persistTextThread(TexthookerTextThread? thread) {
    if (!_ensureCaptureMemoryLoaded()) return;
    final String? fingerprint =
        thread == null ? null : textThreadFingerprint(thread);
    if (fingerprint == null) {
      if (_captureMemory.textThreadFingerprint == null) return;
      _saveCaptureMemory(_captureMemory.copyWith(clearTextThread: true));
      return;
    }
    if (_captureMemory.textThreadFingerprint == fingerprint) return;
    _saveCaptureMemory(
      _captureMemory.copyWith(textThreadFingerprint: fingerprint),
    );
  }

  /// 会话结束时复位记忆的会话内状态（持久化真值不动）。
  void _resetCaptureMemorySession() {
    _trackMemoryApplied = false;
    _textThreadMemoryApplied = false;
    _captureMemoryLoaded = false;
    _captureMemoryGameKey = null;
    _captureMemory = const GalCaptureMemory();
  }

  Future<Uint8List?> captureAudioBytes({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) {
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    if (entry == null ||
        entry.text != sentence ||
        !isLineInCurrentSession(entry)) {
      _markLineAudioMissing(lineId, 'line_context_unavailable');
      return Future<Uint8List?>.value(null);
    }
    // 串行化 + 永不毒化（BUG-956）：单次语音采集异常（含事件记录自身抛）不得让后续采集永久挂起。
    return _audioQueue.enqueue<Uint8List?>(
      () => _captureAudioBytesNow(
        lineId: lineId,
        sentence: sentence,
        outputExtension: outputExtension,
      ),
      buildFailure: (Object error, StackTrace stack) => null,
      onError: (Object error, StackTrace stack) => _record(
        GalHookEventSeverity.error,
        'card',
        'card.audio_capture_exception',
        'Audio capture job failed',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
      ),
    );
  }

  Future<Uint8List?> _captureAudioBytesNow({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) async {
    final GalAudioSource? source = _audioSource;
    final EngineHookGalAudioSource? engine = _engineSource;
    if (source == null && engine == null) {
      _markLineAudioMissing(lineId, 'audio_source_unavailable');
      return null;
    }
    // 用户裁决优先于一切自动配对：点了浮窗「重播并录音」或为这句选了音轨，都说明
    // 自动结果不对；这里再去等资源配对会把用户选定的那段直接顶掉。两种裁决共用一条
    // 分支，只有 backend 标签不同——它必须如实说明字节到底来自哪条链路。
    final int? overriddenTrack = _lineVoiceSourcePtr[lineId];
    final GalAudioSlice? adjudicated =
        _isUserAdjudicated(lineId) ? _lineVoiceCache[lineId] : null;
    if (adjudicated != null && !adjudicated.isEmpty) {
      return _encodeLineSlice(
        lineId: lineId,
        slice: adjudicated,
        backend: overriddenTrack != null ? 'engine_pcm' : 'system_loopback',
        outputExtension: outputExtension,
        fallbackReason: overriddenTrack != null
            ? 'manual_track_override'
            : 'manual_recapture',
      );
    }
    final int timestamp = _lineTimestampCache[lineId] ?? 0;
    if (engine != null && _isWindows) {
      final Uint8List? paired = await _waitForPairedResourceAudio(
        engine,
        lineId: lineId,
        timestamp: timestamp,
        outputExtension: outputExtension,
      );
      if (paired != null && paired.isNotEmpty) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.encoded,
          // 资源来源可能是 Siglus OVK OGG，也可能是 Unity Addressables WAV；
          // 统一用不泄漏容器格式的名称，避免把 Unity 资源误报成 OGG。
          backend: 'game_resource',
        );
        _record(
          GalHookEventSeverity.success,
          'match',
          'audio.paired_voice_encoded',
          'Paired original voice audio encoded for mining',
          details: <String, Object?>{
            'lineId': lineId,
            'chars': sentence.length,
          },
        );
        return paired;
      }
      if (timestamp > 0) {
        _record(
          GalHookEventSeverity.warning,
          'match',
          'audio.paired_voice_not_found',
          'No paired original voice candidate; falling back to PCM',
          details: <String, Object?>{'lineId': lineId},
        );
      }
      if (!_state.audioFallbackPolicy.allowsEnginePcm) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.missing,
          backend: 'game_resource',
          fallbackReason: 'paired_voice_not_found_fallback_disabled',
        );
        _record(
          GalHookEventSeverity.warning,
          'match',
          'audio.fallback_disabled',
          'No paired game resource audio and fallback is disabled',
          details: <String, Object?>{'lineId': lineId},
        );
        return null;
      }
    }
    // 干净源策略：会话音源是 Loopback 就说明下面整条兜底链只能取到**整机混音**
    // （资源模式把 `_audioSource` 指向 loopback，降级会话更是如此）。用户已经说了
    // 不要混音，就不能拿一段 BGM 冒充这句的语音——这条兜底链到此为止，卡以「无音频」落地。
    // 判据用音源类型而不是「缓存里有没有东西」：策略中途改时，早先冻结的切片同样
    // 是混音，必须一并失效。用户显式裁决（补录/选轨）走上面的分支，不受此限。
    // 但**报什么**必须按证据来：抑制掉唯一可用音源不等于「这句没配音」，
    // 见 [_classifySuppressedLoopbackMiss]。
    final bool loopbackSourced = source is LoopbackGalAudioSource;
    if (loopbackSourced && !_state.audioFallbackPolicy.allowsLoopback) {
      final String reason = await _classifySuppressedLoopbackMiss(
        lineId: lineId,
        engine: engine,
        timestampMs: timestamp,
      );
      _markLineAudioMissing(lineId, reason);
      _record(
        GalHookEventSeverity.info,
        'match',
        'audio.loopback_suppressed',
        'System loopback audio was suppressed by the clean-source policy',
        details: <String, Object?>{
          'lineId': lineId,
          'policy': _state.audioFallbackPolicy.storageKey,
          'reason': reason,
        },
      );
      return null;
    }
    // BUG-1101：这行的 loopback 冻结可能还在等窗口到点。制卡就是「现在就要这段声音」，
    // 因此提前收束（按真实已等待时长回取），而不是拿一份还没冻的空缓存报 missing。
    await _flushLoopbackFreeze(lineId);
    GalAudioSlice? slice = _lineVoiceCache[lineId];
    // 会话已经选用 Loopback 时，engine 仍需保活来提供文本/资源事件，但它的 PCM
    // 明确没有通过 readiness 门。此时绝不能因为共享内存里残留着可读 clip 就重新
    // 借用 engine PCM；否则会把错误格式/碎片缓存伪装成 system_loopback。
    if ((slice == null || slice.isEmpty) &&
        engine != null &&
        identical(source, engine) &&
        timestamp > 0) {
      slice = await engine.grabUtterance(timestamp) ??
          await engine.grabClipNear(timestamp);
    }
    if (slice == null || slice.isEmpty) {
      // 制卡时刻仍两手空空：能给证据就给证据——引擎 PCM 会话下按「该句时刻
      // 是否有候选轨在响」区分无配音与疑似漏抓，别一律顶红标。
      final String reason =
          engine != null && identical(source, engine) && timestamp > 0
              ? await _classifyEnginePcmMiss(engine, timestamp)
              : 'line_audio_not_cached';
      _markLineAudioMissing(lineId, reason);
      return null;
    }
    return _encodeLineSlice(
      lineId: lineId,
      slice: slice,
      backend: identical(source, engine) ? 'engine_pcm' : 'system_loopback',
      outputExtension: outputExtension,
      fallbackReason:
          timestamp > 0 ? 'paired_voice_not_found' : 'no_engine_timestamp',
    );
  }

  /// 超长切片门（纯函数）：一句台词的语音极少超过 [kGalOverlongSliceSuspectMs]。
  /// 超长的多半是「制卡时才收束的 loopback 回取」把几十秒混音整段塞了进来
  /// （[_flushLoopbackFreeze] 的 backMs 上限是环容量 60s）。不丢数据——照样入卡，
  /// 但把 fallbackReason 换成明确的可疑标注让 UI 亮黄，别让一段混着 BGM 的长音频
  /// 顶着正常标签混过去。用户显式裁决（补录/选轨）是有意为之，不二次质疑。
  @visibleForTesting
  static String? sliceFallbackReasonFor({
    required int durationMs,
    required String? fallbackReason,
  }) {
    final bool userAdjudicated = fallbackReason == 'manual_recapture' ||
        fallbackReason == 'manual_track_override';
    if (!userAdjudicated && durationMs > kGalOverlongSliceSuspectMs) {
      return kGalOverlongSliceSuspectReason;
    }
    return fallbackReason;
  }

  /// 把一段冻结 PCM 切片转成制卡容器字节，并把该行标成 encoded。
  /// 制卡链路上「有切片了」之后的收尾只有这一份实现（PCM 兜底与手动补录共用）。
  Future<Uint8List?> _encodeLineSlice({
    required String lineId,
    required GalAudioSlice slice,
    required String backend,
    required String outputExtension,
    required String? fallbackReason,
  }) async {
    final int durationMs = (slice.pcm.length * 1000) ~/ slice.format.byteRate;
    final String? effectiveReason = sliceFallbackReasonFor(
      durationMs: durationMs,
      fallbackReason: fallbackReason,
    );
    if (effectiveReason != fallbackReason) {
      _record(
        GalHookEventSeverity.warning,
        'encode',
        'audio.slice_overlong',
        'Captured slice is suspiciously long for a single line',
        details: <String, Object?>{'lineId': lineId, 'durationMs': durationMs},
      );
    }
    final Directory jobDirectory = await Directory.systemTemp.createTemp(
      'hibiki-gal-mining-job-',
    );
    try {
      final Uint8List? encoded = await pcmSliceToAacBytes(
        pcm: slice.pcm,
        format: slice.format,
        tempDir: jobDirectory.path,
        outputExtension: outputExtension,
      );
      if (encoded == null || encoded.isEmpty) {
        _markLineAudioMissing(lineId, 'pcm_encode_failed');
        return null;
      }
      _textService.updateLineAudio(
        lineId,
        status: TexthookerLineAudioStatus.encoded,
        backend: backend,
        durationMs: durationMs,
        fallbackReason: effectiveReason,
      );
      _record(
        GalHookEventSeverity.success,
        'encode',
        'audio.pcm_encoded',
        'PCM fallback audio encoded for mining',
        details: <String, Object?>{'lineId': lineId, 'backend': backend},
      );
      return encoded;
    } finally {
      try {
        await jobDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 资源 hook 已就绪时，资源文件仍可能比文本环晚几十到几百毫秒落盘。制卡不能在第一次
  /// 未命中后立刻录 Loopback；先给资源一个短暂、有上限的等待窗口，超时后才走既有降级链。
  Future<Uint8List?> _waitForPairedResourceAudio(
    EngineHookGalAudioSource engine, {
    required String lineId,
    required int timestamp,
    required String outputExtension,
  }) async {
    final Stopwatch elapsed = Stopwatch()..start();
    final int waitUs = _resourceAudioWait.inMicroseconds;
    final int pollUs = _resourceAudioPollInterval.inMicroseconds;
    while (true) {
      String? resourceId = _resourceIdForLine(lineId);
      // BUG-955：mine 阶段解析具体某行，绝不走「最新语音」兜底——历史行时间戳被淘汰后 timestamp=0，
      // 借最新语音会把当前语音错配给旧台词。晚附着 live 行的资源已在捕获期固化到 _resourceIdForLine，
      // 这里只按精确 resourceId / 正时间戳窗口取，取不到就交给下游 PCM/loopback 或明确 missing。
      resourceId ??= engine.findPairedVoiceResourceId(
        timestamp,
        textEventId: _lineTextEventIdCache[lineId],
        allowLatestSessionFallback: false,
      );
      if (resourceId != null && _resourceIdForLine(lineId) == null) {
        _textService.updateLineAudio(
          lineId,
          status: TexthookerLineAudioStatus.matched,
          backend: 'game_resource',
          resourceId: resourceId,
        );
      }
      final Uint8List? bytes = await engine.grabPairedVoiceBytes(
        timestamp,
        outputExtension: outputExtension,
        textEventId: _lineTextEventIdCache[lineId],
        resourceId: resourceId,
        allowLatestSessionFallback: false,
      );
      if (bytes != null && bytes.isNotEmpty) return bytes;
      if (!engine.rawVoiceReady ||
          waitUs <= 0 ||
          elapsed.elapsedMicroseconds >= waitUs) {
        return null;
      }
      final int remainingUs = waitUs - elapsed.elapsedMicroseconds;
      final int delayUs = pollUs <= 0
          ? remainingUs
          : (pollUs < remainingUs ? pollUs : remainingUs);
      if (delayUs <= 0) return null;
      await Future<void>.delayed(Duration(microseconds: delayUs));
    }
  }

  String? _resourceIdForLine(String lineId) {
    for (final TexthookerLineEntry line in _textService.entries) {
      if (line.id == lineId) return line.audioResourceId;
    }
    return null;
  }

  /// 用户切换降级策略：立即生效 + 按游戏记住。已排定的 loopback 冻结定时器必须
  /// 一并取消——策略改成「不许混音」的那一刻，还在等窗口到点的冻结就是待落地的
  /// 混音，留着等于让用户的选择晚一句才生效。
  void setAudioFallbackPolicy(GalAudioFallbackPolicy policy) {
    if (_state.audioFallbackPolicy == policy) return;
    _setState(_state.copyWith(audioFallbackPolicy: policy));
    if (!policy.allowsLoopback) _cancelLoopbackFreezes();
    _persistAudioFallbackPolicy(policy);
    _record(
      GalHookEventSeverity.info,
      'audio',
      'audio.fallback_policy_changed',
      'Audio fallback policy changed to ${policy.storageKey}',
      details: <String, Object?>{'policy': policy.storageKey},
    );
  }

  /// 会话启动时把上次为这个游戏选的策略套回来（没有记忆 = 保持 [GalAudioFallbackPolicy.full]）。
  void _restoreAudioFallbackPolicy() {
    if (!_ensureCaptureMemoryLoaded()) return;
    final GalAudioFallbackPolicy remembered =
        _captureMemory.audioFallbackPolicy;
    if (remembered == _state.audioFallbackPolicy) return;
    _setState(_state.copyWith(audioFallbackPolicy: remembered));
    _record(
      GalHookEventSeverity.info,
      'audio',
      'audio.fallback_policy_restored',
      'Restored the audio fallback policy remembered for this game',
      details: <String, Object?>{'policy': remembered.storageKey},
    );
  }

  void _persistAudioFallbackPolicy(GalAudioFallbackPolicy policy) {
    if (!_ensureCaptureMemoryLoaded()) return;
    if (_captureMemory.audioFallbackPolicy == policy) return;
    _saveCaptureMemory(_captureMemory.copyWith(audioFallbackPolicy: policy));
  }

  void clearEvents() {
    if (_events.isEmpty) return;
    _events.clear();
    notifyListeners();
  }

  Future<void> close() async {
    ++_operationGeneration;
    _flushGameActivity();
    _activityAccumulator.reset();
    _activityCharCounter.reset();
    _textService.removeListener(_onTextBufferChanged);
    _endpointListenable.removeListener(_onEndpointStatusChanged);
    final ExitFlushCallback? exitFlush = _magpieExitFlush;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _magpieExitFlush = null;
    }
    await shutdownMagpieUpscaling();
    await _stopSources();
    dispose();
  }

  /// 注入 activity_events 落库用的 DB 惰性解析器（桌面启动流程
  /// [GalHookTextOverlayController.start] 调用一次；解析在每次 flush 时发生，
  /// App 尚未初始化完则返回 null 跳过本次落库）。是首页「游戏」活动的唯一数据来源。
  void attachActivityDatabase(FushiDatabase? Function() resolve) {
    _activityDatabaseResolver = resolve;
  }

  /// 注入窗口超分编排器（桌面启动流程 [GalHookTextOverlayController.start] 调用一次）。
  ///
  /// 不注入 = 完全没有超分，会话逻辑不受任何影响。
  void attachMagpieUpscaling(MagpieUpscalingService service) {
    _magpieUpscaling = service;
    // **注入即登记退出清理**：桌面点 X 走 `exit(0)`，没有任何 dispose / close 会帮我们
    // 收。登记点必须就在这里而不是调用方，否则「以后谁再注入一次」就又会漏掉。
    _magpieExitFlush ??=
        ExitFlushRegistry.instance.register(shutdownMagpieUpscaling);
  }

  /// 窗口超分编排器（UI 订阅它显示超分状态）。未注入 / 非 Windows 时为 null，
  /// 调用方据此整行不显示。
  MagpieUpscalingService? get magpieUpscaling => _magpieUpscaling;

  /// 开始一段游戏活动记账：先把上一段残留 flush（防上次异常未落），再复位累计器并
  /// 绑定本会话的游戏标题/稳定 id。会话开始（attach / launch）时调用。
  void _beginActivitySession({required String title, String? mediaKey}) {
    _flushGameActivity();
    // 捕获记忆按**游戏身份**锚定，所以新会话必须重新加载：只在 [stopCapture] 里重置
    // 是漏的——用户不点「停止监听」直接从库里启动下一个游戏时，`_captureMemoryLoaded`
    // 还是 true，上一个游戏的排除集/语音轨/降级策略会原样套到新游戏上，而用户在新
    // 游戏里做的选择又会被写回**上一个游戏**的 key（`_captureMemoryGameKey` 没换）。
    _resetCaptureMemorySession();
    _activityAccumulator.reset();
    _activityCharCounter.reset();
    _engineTextCounted = false;
    final String trimmed = title.trim();
    _activityGameTitle = trimmed.isEmpty ? null : trimmed;
    _activityGameKey = mediaKey == null || mediaKey.isEmpty ? null : mediaKey;
  }

  /// 记一行 hook 文本到活动累计；命中中途 flush 阈值即落一条（防崩溃丢账）。
  /// 仅在已开始游戏活动会话（[_activityGameTitle] 非空）时记账——纯 WebSocket/剪贴板
  /// 文本流没有绑定游戏进程、无可归属标题，不计入「游戏」活动。
  ///
  /// 字数走 [_activityCharCounter] 统一口径（BUG-1085：裸 `text.length` 把标点、
  /// 相邻重发、打字机递增、外部工具双通道全算成字数，统计虚高）。计 0 的行仍
  /// [GalHookActivityAccumulator.recordLine] 记时间戳——行到达本身是"人在读"
  /// 的活跃信号，flush 节奏不受去重影响。
  void _recordActivityLine(String text, {required bool fromEngineHook}) {
    if (text.isEmpty || _activityGameTitle == null) return;
    if (fromEngineHook) {
      _engineTextCounted = true;
    } else if (_engineTextCounted) {
      return; // 引擎 hook 是本会话计数源，外部通道的同句不再计（防双计）。
    }
    _activityAccumulator.recordLine(
      _activityCharCounter.countLine(text),
      _now().millisecondsSinceEpoch,
    );
    if (_activityAccumulator.shouldFlush) _flushGameActivity();
  }

  /// 可执行文件路径 → 展示用游戏名：取文件名去扩展名（跨平台按 `/` 或 `\` 切分）。
  String _displayNameForExecutable(String path) {
    final String name = path.split(RegExp(r'[\\/]')).last;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 把当前累计的**字符数**落一条 activity_events。无可归属标题、无 DB/写入方或无
  /// 字符累计时不落（保留累计，等下一行或会话结束再试）；落库失败静默（try/catch）。
  ///
  /// 契约 §3.1：时长不再从这里写（真相源是 `GalgamePlayTracker`）。累计器内部仍算
  /// 活跃时长，但那只是 [GalHookActivityAccumulator.shouldFlush] 的节奏信号；没有
  /// 字符就没有可记的事实，直接不落行，免得产生一堆全 null 的空活动。
  void _flushGameActivity() {
    final String? title = _activityGameTitle;
    final GalHookActivityWriter? writer = _resolveActivityWriter();
    if (title == null || writer == null) return;
    if (_activityAccumulator.pendingChars <= 0) return;
    final (int charsDelta, _) = _activityAccumulator.drain();
    final String? mediaKey = _activityGameKey;
    final DateTime now = _now();
    unawaited(
      _safeWriteActivity(
        writer: writer,
        title: title,
        mediaKey: mediaKey,
        charsDelta: charsDelta,
        now: now,
      ),
    );
  }

  GalHookActivityWriter? _resolveActivityWriter() {
    final GalHookActivityWriter? injected = _activityWriter;
    if (injected != null) return injected;
    final FushiDatabase? database = _activityDatabaseResolver?.call();
    if (database == null) return null;
    return ({
      required String title,
      String? mediaKey,
      required String dateKey,
      required int timestampMs,
      required int charsDelta,
    }) =>
        database.addActivityEvent(
          eventType: kActivityGame,
          mediaType: kActivityMediaGame,
          title: title,
          mediaKey: mediaKey,
          dateKey: dateKey,
          timestampMs: timestampMs,
          // durationMs 刻意不传（留 null）：时长由 GalgamePlayTracker 独立写行。
          charsDelta: charsDelta,
        );
  }

  Future<void> _safeWriteActivity({
    required GalHookActivityWriter writer,
    required String title,
    required String? mediaKey,
    required int charsDelta,
    required DateTime now,
  }) async {
    try {
      await writer(
        title: title,
        mediaKey: mediaKey,
        dateKey: FushiTimeFormat.dayKey(now),
        timestampMs: now.millisecondsSinceEpoch,
        charsDelta: charsDelta,
      );
    } catch (error, stack) {
      _record(
        GalHookEventSeverity.warning,
        'activity',
        'activity.write_failed',
        'Failed to persist game activity event',
        details: <String, Object?>{'error': '$error', 'stack': '$stack'},
        notify: false,
      );
    }
  }

  void _activateEngine(
    EngineHookGalAudioSource engine,
    PcmFormat format, {
    int? gamePid,
  }) {
    _audioSource = engine;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.enginePcm,
        audioFormat: format,
        gamePid: gamePid,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'inject',
      'engine.hook_ready',
      'Engine hook and IPC are ready; waiting for text signals',
      details: <String, Object?>{
        'pid': gamePid,
        'sampleRate': format.sampleRate,
        'channels': format.channels,
      },
    );
    _syncTrackAutoRefresh();
  }

  /// 原始游戏资源音频是首选，系统回环只作为某句没有资源文件时的兜底。资源 hook 本身
  /// 不提供 PCM 环，因此两条来源必须同时保活：[_engineSource] 负责文本/资源配对，
  /// [_audioSource] 优先持回环（启动失败则保留 engine 空 PCM 源，资源制卡仍可继续）。
  Future<void> _activateResourceWithLoopback(
    int generation,
    EngineHookGalAudioSource engine, {
    int? gamePid,
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? fallbackFormat = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      await engine.stop();
      return;
    }
    if (fallbackFormat == null) await loopback.stop();
    _audioSource = fallbackFormat == null ? engine : loopback;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.gameResource,
        clearAudioFormat: true,
        gamePid: gamePid,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.game_resource_ready',
      'Game resource audio is primary; system loopback is fallback only',
      details: <String, Object?>{
        'pid': gamePid,
        'loopbackAvailable': fallbackFormat != null,
      },
    );
    _syncTrackAutoRefresh();
  }

  /// 保留已就绪的引擎文本 helper，同时以系统 Loopback 作为独立音频源。
  ///
  /// Unity/IL2CPP 游戏可能让 Luna 文本 hook 正常工作，却不经过当前 XAudio2/
  /// DirectSound PCM 钩子。文本与音频是两项独立能力，不能因为引擎 PCM 缺失就关闭
  /// helper、退化成“只有混音但没有台词”。
  ///
  /// BUG-1100：本状态是**临时**的。走到这里最常见的原因不是「这个引擎没有 PCM」，而是
  /// 「游戏刚启动、一句语音都还没播过」——共享内存里当然没有格式。`engine_pcm_unavailable`
  /// 因此只是当前事实，不是终局判决：[_refreshReadinessThrottled] 会持续复查
  /// [EngineHookGalAudioSource.readyPcmFormat]，首句语音出现即 [_promoteLateEnginePcm]。
  Future<bool> _activateTextWithLoopback(
    int generation,
    EngineHookGalAudioSource engine, {
    int? gamePid,
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? format = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      await engine.stop();
      return false;
    }
    if (format == null) {
      await loopback.stop();
    }
    _audioSource = format == null ? null : loopback;
    _startEngineTextPolling(engine);
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.degraded,
        audioBackend: format == null
            ? GalHookAudioBackend.none
            : GalHookAudioBackend.systemLoopback,
        audioFormat: format,
        clearAudioFormat: format == null,
        gamePid: gamePid,
        fallbackReason: format == null
            ? 'all_audio_sources_failed'
            : 'engine_pcm_unavailable',
        // 文本 hook 已就绪 = 注入这条链是通的：不能把上一次注入失败的原因留在状态里，
        // 否则 UI 会一直显示「需要管理员权限」之类早已不成立的处置。
        injectorFailure: GalHookInjectorFailure.none,
        lastError: format == null
            ? 'Text hook is ready, but no audio capture source could be started'
            : null,
        clearLastError: format != null,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'text',
      'engine.text_hook_ready',
      'Engine text hook is ready',
      details: <String, Object?>{'pid': gamePid, 'audioMode': 'text_only'},
    );
    _record(
      format == null
          ? GalHookEventSeverity.error
          : GalHookEventSeverity.warning,
      'audio',
      format == null
          ? 'audio.all_sources_failed'
          : 'audio.hybrid_loopback_active',
      format == null
          ? 'Text capture is active, but no audio source is available'
          : 'Text hook is active with system loopback audio',
      details: <String, Object?>{
        if (format != null) 'sampleRate': format.sampleRate,
        if (format != null) 'channels': format.channels,
      },
    );
    _syncTrackAutoRefresh();
    return true;
  }

  void _startEngineTextPolling(EngineHookGalAudioSource engine) {
    _engineSource = engine;
    _lastTextSeq = 0;
    _pollInFlight = false;
    _lastReadinessRefreshAt = null;
    _lineVoiceCache.clear();
    _manualRecaptureLines.clear();
    _lineVoiceSourcePtr.clear();
    _lineTimestampCache.clear();
    _lineTextEventIdCache.clear();
    _loopbackCacheInFlight.clear();
    _cancelLoopbackFreezes();
    _pendingResourceMatches.clear();
    unawaited(engine.pruneVoiceDump());
    _textPollTimer?.cancel();
    _textPollTimer = Timer.periodic(
      _textPollInterval,
      (_) => unawaited(_pollHookedText()),
    );
  }

  /// [detail] 是本次降级的 native 一手证据（见 [GalHookSessionState.injectorDetail]）。
  Future<void> _activateLoopback(
    int generation, {
    required String fallbackReason,
    GalHookInjectorFailure failure = GalHookInjectorFailure.none,
    String detail = '',
  }) async {
    final LoopbackGalAudioSource loopback = _loopbackSourceFactory();
    final PcmFormat? format = await loopback.start();
    if (generation != _operationGeneration) {
      await loopback.stop();
      return;
    }
    if (format == null) {
      await loopback.stop();
      _setState(
        _state.copyWith(
          phase: GalHookSessionPhase.degraded,
          audioBackend: GalHookAudioBackend.none,
          fallbackReason: 'all_audio_sources_failed',
          lastError: 'No audio capture source could be started',
          clearAudioFormat: true,
        ),
      );
      _record(
        GalHookEventSeverity.error,
        'audio',
        'audio.all_sources_failed',
        'Engine hook and system loopback are both unavailable',
      );
      return;
    }
    _audioSource = loopback;
    _engineSource = null;
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.degraded,
        audioBackend: GalHookAudioBackend.systemLoopback,
        audioFormat: format,
        fallbackReason: fallbackReason,
        injectorFailure: failure,
        injectorDetail: detail,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.loopback_active',
      'System loopback is active; captured audio may include BGM and effects',
      details: <String, Object?>{
        'fallbackReason': fallbackReason,
        'sampleRate': format.sampleRate,
        'channels': format.channels,
      },
    );
  }

  /// 引擎 hook 失败后的**有界恢复**调度。
  ///
  /// 旧实现里 `_activateLoopback` 是终态：一次注入竞态（DLL 还在加载、上一局残留会话、
  /// 引擎音频子系统尚未建好）就让整局只剩整机混音，用户只能关掉游戏重来。真实失败里
  /// 相当一部分会自愈，因此按退避表重试；不会自愈的失败（位数不符 / 需要提权 / 缺文件）
  /// 一次都不试，直接把原因留在事件里让 UI 说清处置。
  void _scheduleEngineRecovery(
    int generation, {
    required int pid,
    required GalHookInjectorDiagnostics diagnostics,
  }) {
    _engineRetryTimer?.cancel();
    _engineRetryTimer = null;
    if (!_isWindows || pid <= 0) return;
    if (!diagnostics.isRetryable) {
      _record(
        GalHookEventSeverity.info,
        'inject',
        'engine.retry_skipped',
        'Engine hook failure needs user action; not retrying',
        details: diagnostics.toDetails(),
      );
      return;
    }
    if (_engineRetryAttempt >= _engineRetryBackoff.length) {
      _record(
        GalHookEventSeverity.warning,
        'inject',
        'engine.retry_exhausted',
        'Engine hook retries are exhausted; staying on system loopback',
        details: <String, Object?>{
          'attempts': _engineRetryAttempt,
          'reason': diagnostics.failure.name,
        },
      );
      return;
    }
    final Duration delay = _engineRetryBackoff[_engineRetryAttempt];
    final int attempt = _engineRetryAttempt + 1;
    _record(
      GalHookEventSeverity.info,
      'inject',
      'engine.retry_scheduled',
      'Retrying the engine hook while system loopback keeps running',
      details: <String, Object?>{
        'attempt': attempt,
        'delayMs': delay.inMilliseconds,
        'reason': diagnostics.failure.name,
      },
    );
    _engineRetryTimer = Timer(delay, () {
      _engineRetryTimer = null;
      unawaited(_retryEngineAttach(generation, pid: pid, attempt: attempt));
    });
  }

  Future<void> _retryEngineAttach(
    int generation, {
    required int pid,
    required int attempt,
  }) async {
    if (generation != _operationGeneration || _engineRetryInFlight) return;
    // 只在仍处降级态时打扰：用户手动重绑、重启会话或引擎已自行恢复都不该被覆盖。
    if (_state.phase != GalHookSessionPhase.degraded) return;
    _engineRetryInFlight = true;
    _engineRetryAttempt = attempt;
    try {
      final bool? is32Bit = await _targetWow64Probe(pid);
      if (generation != _operationGeneration) return;
      final String? injector = _injectorResolver(is32Bit: is32Bit ?? false);
      if (injector == null) return; // helper 缺失：重试不可能变好
      final EngineHookGalAudioSource engine = _engineSourceFactory(
        targetPid: pid,
        launchExe: null,
        injectorPath: injector,
        // BUG-1267 — 引擎重试同样走 PID→exe 判据，否则重试会把首次的 PC hooks 丢掉。
        lunaPcHooks: _lunaPcHooksForPid(pid),
      );
      await _attachPersistedHookProfiles(engine);
      final PcmFormat? format = await engine.start();
      if (generation != _operationGeneration) {
        await engine.stop();
        return;
      }
      if (format != null || engine.textHookReady) {
        await _swapLoopbackForEngine(
          generation,
          engine,
          format: format,
          gamePid: pid,
          attempt: attempt,
        );
        return;
      }
      final GalHookInjectorDiagnostics diagnostics = engine.lastFailure;
      await engine.stop();
      _record(
        GalHookEventSeverity.warning,
        'inject',
        'engine.retry_failed',
        'Engine hook retry failed; still on system loopback',
        details: <String, Object?>{
          'attempt': attempt,
          ...diagnostics.toDetails(),
        },
      );
      _scheduleEngineRecovery(
        generation,
        pid: pid,
        diagnostics: diagnostics,
      );
    } finally {
      _engineRetryInFlight = false;
    }
  }

  /// 重试成功：停掉降级中的 Loopback，把音源升级回引擎 hook。
  Future<void> _swapLoopbackForEngine(
    int generation,
    EngineHookGalAudioSource engine, {
    required PcmFormat? format,
    required int gamePid,
    required int attempt,
  }) async {
    // 先停旧 Loopback：_activate* 会各自新建来源，两个 WASAPI 捕获并存只会白耗资源。
    final GalAudioSource? previous = _audioSource;
    _audioSource = null;
    await previous?.stop();
    if (generation != _operationGeneration) {
      await engine.stop();
      return;
    }
    _engineRetryAttempt = 0;
    _record(
      GalHookEventSeverity.success,
      'inject',
      'engine.attach_recovered',
      'Engine hook recovered after a bounded retry',
      details: <String, Object?>{'attempt': attempt, 'pid': gamePid},
    );
    if (format != null) {
      if (engine.rawVoiceReady) {
        await _activateResourceWithLoopback(
          generation,
          engine,
          gamePid: gamePid,
        );
      } else {
        _activateEngine(engine, format, gamePid: gamePid);
      }
      return;
    }
    await _activateTextWithLoopback(generation, engine, gamePid: gamePid);
  }

  Future<void> _stopSources() async {
    // 补录窗口挂在会话音源上，会话停就必须先收束（丢弃取音）：否则临时 loopback
    // 源泄漏，超时回调还会往已结束的会话行里写状态。
    await finishLineRecapture(discard: true);
    _textPollTimer?.cancel();
    _textPollTimer = null;
    _trackRefreshTimer?.cancel();
    _trackRefreshTimer = null;
    _windowRebindTimer?.cancel();
    _windowRebindTimer = null;
    _engineRetryTimer?.cancel();
    _engineRetryTimer = null;
    _engineRetryAttempt = 0;
    _engineRetryInFlight = false;
    _windowRebindInFlight = false;
    _pollInFlight = false;
    _lastReadinessRefreshAt = null;
    final EngineHookGalAudioSource? engine = _engineSource;
    _engineSource = null;
    _lastTextSeq = 0;
    _lineVoiceCache.clear();
    _manualRecaptureLines.clear();
    _lineVoiceSourcePtr.clear();
    _lineTimestampCache.clear();
    _lineTextEventIdCache.clear();
    _loopbackCacheInFlight.clear();
    _cancelLoopbackFreezes();
    _pendingResourceMatches.clear();
    final GalAudioSource? source = _audioSource;
    _audioSource = null;
    if (engine != null && !identical(engine, source)) {
      await engine.stop();
    }
    await source?.stop();
  }

  /// 拉一次 native 线程预览快照并合进线程目录。
  ///
  /// 预览是**全量快照**，没有游标，漏一次不会丢数据；因此这里失败静默返回即可，不需要
  /// 补偿逻辑。native 不支持（旧 helper）返回 null，此时选择器退回旧行为（只有已发布
  /// 线程有内容）——不崩，只是选不动，与升级 helper 前的现状一致。
  Future<void> _pollThreadPreviews(EngineHookGalAudioSource engine) async {
    final List<GalTextThreadPreview>? previews =
        await engine.pollThreadPreviews();
    if (previews == null || engine != _engineSource) return;
    _textService.applyTextThreadPreviews(<TexthookerThreadPreview>[
      for (final GalTextThreadPreview preview in previews)
        TexthookerThreadPreview(
          nativeThreadId: preview.threadId,
          text: preview.text,
          observedLineCount: preview.lineCount,
          observedArtifactCount: preview.artifactCount,
          isArtifact: preview.isArtifact,
        ),
    ]);
    // 预览带来了新的观测行数，跨会话记忆的消歧条件可能刚刚成立。
    _maybeRestoreTextThread();
  }

  Future<void> _pollHookedText() async {
    if (_pollInFlight) return;
    final EngineHookGalAudioSource? engine = _engineSource;
    if (engine == null) return;
    _pollInFlight = true;
    try {
      await _refreshReadinessThrottled(engine);
      if (engine != _engineSource) return;
      _reportTextLanePressure(engine);
      // v12：预览区与文本环是两份独立数据，必须各poll各的。文本环在用户选定线程之前
      // 恒空，只轮询它会让选择器永远是一列空壳——那正是本次要修的症状。
      await _pollThreadPreviews(engine);
      if (engine != _engineSource) return;
      final GalTextPoll? poll = await engine.pollText(_lastTextSeq);
      if (poll == null || engine != _engineSource) return;
      final List<GalHookedLine> ordered = List<GalHookedLine>.from(poll.lines)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      int cursor = _lastTextSeq;
      bool receivedTextLine = false;
      for (final GalHookedLine line in ordered) {
        if (line.seq <= cursor) {
          _setState(
            _state.copyWith(textDuplicateCount: _state.textDuplicateCount + 1),
          );
          continue;
        }
        if (line.seq > cursor + 1) {
          _setState(
            _state.copyWith(
              textGapCount: _state.textGapCount + line.seq - cursor - 1,
            ),
          );
          _record(
            GalHookEventSeverity.warning,
            'text',
            'text.sequence_gap',
            'Text sequence gap detected',
            details: <String, Object?>{'from': cursor, 'to': line.seq},
          );
        }
        // v13 消费期线程过滤。native 现在把**每条线程**的行都写进各自的道（这正是"多抓
        // 文本"要的：换线程后旧行仍在、选错线程不再等于那段语音永久孤儿），所以喂进
        // texthooker / 配对 / 制卡之前必须在这里挑出选定线程的行——否则工作台会被所有
        // hook 线程的文本灌满。判据与旧 native 门控等价，见 [_selectedTextThreadFaceId]。
        if (line.eventKind == GalTextEventKind.line &&
            !_acceptsLineFromSelectedThread(line)) {
          cursor = line.seq;
          continue;
        }
        if (line.eventKind == GalTextEventKind.threadDiscovered) {
          final String? threadKey = line.textThreadKey;
          final String? threadLabel = line.textThreadLabel;
          if (threadKey != null && threadLabel != null) {
            _textService.registerTextThread(
              key: threadKey,
              label: threadLabel,
              hookCode: line.hookCode.isEmpty ? null : line.hookCode,
              nativeThreadId: line.threadId,
            );
          }
          cursor = line.seq;
          continue;
        }
        // 系统 UI 文字（读/存档菜单确认句、存档槽号/时间戳）在 native hook 侧无法与台词区分，
        // 会被 injector 的 hook 赢家选择放行——在喂进文本服务/查词面板前用实证启发式剔除。
        // 推进 cursor 消费掉该 seq，但不置 receivedTextLine（菜单文字不算收到台词信号）。
        if (isGalgameSystemUiLine(line.text)) {
          cursor = line.seq;
          continue;
        }
        final TexthookerLineEntry? entry = _textService.appendLine(
          line.text,
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook',
          sourceSequence: line.seq,
          hookTimestampMs: line.timestampMs,
          textThreadKey: line.textThreadKey,
          textThreadLabel: line.textThreadLabel,
          textHookCode: line.hookCode.isEmpty ? null : line.hookCode,
          nativeTextThreadId: line.threadId == 0 ? null : line.threadId,
          audioStatus: TexthookerLineAudioStatus.pending,
        );
        if (entry == null) {
          cursor = line.seq;
          continue;
        }
        receivedTextLine = true;
        _recordActivityLine(entry.text, fromEngineHook: true);
        _lineTimestampCache[entry.id] = line.timestampMs;
        _trimCache(_lineTimestampCache);
        _lineTextEventIdCache[entry.id] = line.seq;
        _trimCache(_lineTextEventIdCache);
        final bool resourceReady = engine.rawVoiceReady;
        final String? resourceId = resourceReady
            ? engine.findPairedVoiceResourceId(
                line.timestampMs,
                textEventId: line.seq,
              )
            : null;
        final bool resourceMatched = resourceId != null;
        if (resourceMatched) {
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.matched,
            backend: 'game_resource',
            resourceId: resourceId,
          );
          _record(
            GalHookEventSeverity.success,
            'match',
            'audio.game_resource_matched',
            'Original game resource audio matched to captured line',
            details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
          );
        } else if (resourceReady) {
          _pendingResourceMatches[entry.id] = (
            timestampMs: line.timestampMs,
            textEventId: line.seq,
          );
          _trimCache(_pendingResourceMatches);
          _textService.updateLineAudio(
            entry.id,
            status: TexthookerLineAudioStatus.pending,
            backend: 'game_resource',
          );
        }
        // BUG-1063：台词已进缓冲、UI 已被通知；余下的语音抓取（PCM 拷贝、loopback
        // 环冻结）一律离开文本主路径，改由串行音频队列执行。此前它们 await 在本循环
        // 里：同一批的后续台词要排在前一句语音抓取之后，且 _pollInFlight 会让下一个
        // tick 整轮跳过——台词显示被自己的语音配对拖慢。
        if (!resourceMatched) {
          _scheduleLineAudioAttach(
            engine: engine,
            entry: entry,
            line: line,
            resourceReady: resourceReady,
          );
        }
        cursor = line.seq;
      }
      _refreshPendingResourceMatches(engine);
      // 只推进到实际看见并处理完成的最大 seq；不能盲用 native header count 跳过未提交槽。
      if (cursor > _lastTextSeq) _lastTextSeq = cursor;
      // BUG-1094：新台词到达 = 玩家已经翻过这句，补录窗口没有继续开着的理由。
      // 定时器不再是唯一的自动收束源（另一个是用户再点一次 ⏺）。只认引擎 hook 的台词：
      // 剪贴板 / 外部 WS 通道可能与游戏进度无关，不该替用户结束录音。
      if (receivedTextLine && _recapturingLineId != null) {
        unawaited(finishLineRecapture());
      }
      if (receivedTextLine) {
        _setState(
          _state.copyWith(
            phase: _state.fallbackReason == null
                ? GalHookSessionPhase.running
                : GalHookSessionPhase.degraded,
            textSignalReceived: true,
          ),
        );
        // 行数变了才值得重评：恢复要求候选线程已出够行数（见 [_maybeRestoreTextThread]）。
        _maybeRestoreTextThread();
      }
    } finally {
      _pollInFlight = false;
    }
  }

  /// 资源语音就绪查询降频：文本轮询每 tick 都跑，但这一次 IPC 往返最多每
  /// [_readinessRefreshInterval] 做一次。首次调用（会话刚起）不节流；晚到的资源
  /// hook 仍在这里升格为主音源（[_promoteLateResourceAudio]），只是最迟晚半秒。
  Future<void> _refreshReadinessThrottled(
    EngineHookGalAudioSource engine,
  ) async {
    final DateTime now = _now();
    final DateTime? last = _lastReadinessRefreshAt;
    if (last != null && now.difference(last) < _readinessRefreshInterval) {
      return;
    }
    _lastReadinessRefreshAt = now;
    final bool hadResourceAudio = engine.rawVoiceReady;
    await engine.refreshReadiness();
    if (engine != _engineSource) return;
    if (!hadResourceAudio && engine.rawVoiceReady) {
      _promoteLateResourceAudio(engine);
      return;
    }
    // BUG-1100：引擎 PCM 与资源语音是两条各自会「晚到」的能力，升格必须对称。
    // 只有资源侧有升格分支时，「hook 装好了但游戏还没播过语音」这一条就是终态：
    // 第一个 poll tick 判死后，整局再也回不到引擎 PCM。
    final PcmFormat? readyFormat = engine.readyPcmFormat;
    if (readyFormat != null && !engine.rawVoiceReady) {
      await _promoteLateEnginePcm(engine, readyFormat);
    }
  }

  /// 引擎 PCM 晚到时把主音源从降级的 Loopback 升格回引擎（BUG-1100，与
  /// [_promoteLateResourceAudio] 对称）。
  ///
  /// [_activateTextWithLoopback] 之所以选 Loopback，只是因为握手那一刻共享内存里还没有
  /// 任何 PCM 格式——hook 本身早就装好了，游戏只是还没播过语音。这是**临时**状态：首句
  /// 语音一出现，helper 立刻通过与 [EngineHookGalAudioSource.start] 完全相同的就绪门给出
  /// 格式，此时必须把音源换回来。
  ///
  /// 刻意**不**走 [_activateEngine] / [_swapLoopbackForEngine]：engine 实例仍存活、不需要
  /// 重新注入，而 [_startEngineTextPolling] 会把文本轮询游标归零并清掉逐行缓存与用户裁决，
  /// 那会让整段历史台词重放一遍。
  Future<void> _promoteLateEnginePcm(
    EngineHookGalAudioSource engine,
    PcmFormat format,
  ) async {
    if (engine != _engineSource || identical(_audioSource, engine)) return;
    if (_state.audioBackend != GalHookAudioBackend.systemLoopback &&
        _state.audioBackend != GalHookAudioBackend.none) {
      return;
    }
    // 补录窗口正持有当前 Loopback：用户裁决优先，等它收束后的下一个 tick 再升格。
    if (_recapturingLineId != null) return;
    // 还在等窗口的行属于旧音源，先按真实已等待时长冻结，别把它们的声音丢掉。
    await _flushAllLoopbackFreezes();
    if (engine != _engineSource) return;
    final GalAudioSource? previous = _audioSource;
    _audioSource = engine;
    await previous?.stop();
    if (engine != _engineSource) return;
    _setState(
      _state.copyWith(
        phase: _state.textSignalReceived
            ? GalHookSessionPhase.running
            : GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.enginePcm,
        audioFormat: format,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.engine_pcm_late_ready',
      'Engine PCM became available and is now the primary audio source',
      details: <String, Object?>{
        'pid': _state.gamePid,
        'sampleRate': format.sampleRate,
        'channels': format.channels,
      },
    );
    _syncTrackAutoRefresh();
  }

  /// 把某行的语音抓取排进串行音频队列（BUG-1063）。与制卡采集共用同一队列：native
  /// 语音缓冲同一时刻只该有一个读取者，串行也保证补录/制卡不与逐行抓取交错。
  void _scheduleLineAudioAttach({
    required EngineHookGalAudioSource engine,
    required TexthookerLineEntry entry,
    required GalHookedLine line,
    required bool resourceReady,
  }) {
    unawaited(() async {
      await _audioQueue.enqueue<bool>(
        () async {
          await _attachLineAudio(
            engine: engine,
            entry: entry,
            line: line,
            resourceReady: resourceReady,
          );
          return true;
        },
        buildFailure: (Object error, StackTrace stack) => false,
        onError: (Object error, StackTrace stack) => _record(
          GalHookEventSeverity.error,
          'match',
          'audio.line_attach_exception',
          'Line audio attach job failed',
          details: <String, Object?>{
            'lineId': entry.id,
            'error': '$error',
          },
        ),
      );
      // BUG-1109：首取只拿到这句语音的开头，剩下的段还没进环。收敛必须在队列**之外**
      // 等待（队列里 sleep 会堵住后续台词抓取和制卡），只有单次 grab 入队。
      try {
        await _settleLineUtterance(
          engine: engine,
          entry: entry,
          line: line,
          resourceReady: resourceReady,
        );
      } catch (error) {
        _record(
          GalHookEventSeverity.error,
          'match',
          'audio.utterance_settle_exception',
          'Utterance settle loop failed',
          details: <String, Object?>{
            'lineId': entry.id,
            'error': '$error',
          },
        );
      }
    }());
  }

  /// 引擎 PCM 逐句语音的**增长收敛**（BUG-1109）。
  ///
  /// native `VoiceHookReader::GrabUtterance` 的拼接窗口是 `[ts-200, ts+6000]`
  /// （`windows/runner/voice_hook_reader.cpp`）——**前向 6 秒**是有意设计，等的就是这句
  /// 语音后续的段。但文本轮询 80ms 一跳，台词一到就读时窗口的前向部分还是空的，只能拼到
  /// 游戏**当时已经提交给混音器**的那一小段。整段一次性提交的引擎看不出问题；分块流式提交
  /// 的引擎必然缺尾巴。而 [_lineVoiceCache] 先到先得、制卡只读缓存，于是这句语音**永远**
  /// 停在被截断的版本，隔多久制卡都一样。
  ///
  /// 修法与 [_scheduleLoopbackFreeze] 同纪律（前向等待、等待在队列外）：按
  /// [_utteranceSettleInterval] 重取，每轮把**更长**的结果写回缓存——制卡随时都能取到
  /// 当前最完整的一段，不需要额外的收束通道。收敛只终止于两者之一：
  /// - [_canSettleLine] 不再成立（下一句到达 / 会话或音源换走 / 用户裁决 / 资源升格）；
  /// - 到 [_utteranceSettleMax]（越过 native 窗口，不可能再有新段）。
  ///
  /// 刻意**没有**「连续 N 轮没变长就算播完」：缓存单调变长，句中一个 >2 轮的停顿
  /// （换气、演出停顿）就会把收敛骗停在半句上，而多跑到上限的代价只是几次 grab。
  Future<void> _settleLineUtterance({
    required EngineHookGalAudioSource engine,
    required TexthookerLineEntry entry,
    required GalHookedLine line,
    required bool resourceReady,
  }) async {
    // 资源语音（原始 OGG/WAV）走的是文件链，与 PCM 环无关；Loopback 会话有自己的
    // 延迟冻结。只有「本会话确实在用这个 engine 的 PCM」时才需要收敛。
    if (resourceReady || !identical(_audioSource, engine)) {
      return;
    }
    int bestBytes = _lineVoiceCache[entry.id]?.pcm.length ?? 0;
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < _utteranceSettleMax) {
      if (!_canSettleLine(engine: engine, entry: entry, line: line)) {
        await _closingUtteranceGrab(
          engine: engine,
          entry: entry,
          line: line,
          bestBytes: bestBytes,
        );
        return;
      }
      await Future<void>.delayed(_utteranceSettleInterval);
      // 判据必须在**每个** await 之后复查：只在 delay 之前查一次时，下一句在 delay
      // 期间到达仍会多抓一次，把下一句的段拼进上一句（BUG-1109 审查实测）。
      if (!_canSettleLine(engine: engine, entry: entry, line: line)) {
        await _closingUtteranceGrab(
          engine: engine,
          entry: entry,
          line: line,
          bestBytes: bestBytes,
        );
        return;
      }
      final GalAudioSlice? next = await _audioQueue.enqueue<GalAudioSlice?>(
        () => engine.grabUtterance(line.timestampMs),
        buildFailure: (Object error, StackTrace stack) => null,
      );
      if (next == null || next.isEmpty || next.pcm.length <= bestBytes) {
        continue;
      }
      // grab 期间也可能夹一次 stop / 补录 / 选轨 / 资源升格。
      if (!_canSettleLine(engine: engine, entry: entry, line: line)) {
        await _closingUtteranceGrab(
          engine: engine,
          entry: entry,
          line: line,
          bestBytes: bestBytes,
        );
        return;
      }
      bestBytes = next.pcm.length;
      _lineVoiceCache[entry.id] = next;
      _trimCache(_lineVoiceCache);
      _textService.updateLineAudio(
        entry.id,
        status: TexthookerLineAudioStatus.matched,
        backend: 'engine_pcm',
        durationMs: (next.pcm.length * 1000) ~/ next.format.byteRate,
      );
    }
  }

  /// 收敛因「下一句到达」而收手时的**封口 grab**（BUG-1475）。
  ///
  /// 从最后一次成功 grab 到下一句到达之间，最多有一个 [_utteranceSettleInterval]
  /// （250ms）的 PCM 已经进了共享内存环、却从未被读出来。这段数据的时间戳**严格早于**
  /// 下一句的 ts，根本不属于 [[BUG-1109]] 要防的东西（那条防的是把**下一句**的段拼进
  /// 上一句），纯属误伤——用户报的「上一句音频没播完就切下一句会打断已捕获的音频」
  /// 丢的就是它。
  ///
  /// 三条纪律：
  /// * **只在「下一句到达」这一种终止原因下补**。会话/音源换走、用户裁决、补录窗口、
  ///   资源升格这几种终止意味着这行的所有权已经不在收敛手上，此时再写缓存就是越权。
  /// * 前向窗口用下一句的 ts 收口（`endTsMs`），BUG-1109 的不变量原样保住。
  /// * 仍然只在**更长**时才写回：缓存单调变长的性质不变。
  Future<void> _closingUtteranceGrab({
    required EngineHookGalAudioSource engine,
    required TexthookerLineEntry entry,
    required GalHookedLine line,
    required int bestBytes,
  }) async {
    // 除「下一句到达」之外的任何一条不成立 ⇒ 所有权已易主，不补。
    final bool onlyNextLineArrived = engine == _engineSource &&
        identical(_audioSource, engine) &&
        isLineInCurrentSession(entry) &&
        _recapturingLineId == null &&
        !_isUserAdjudicated(entry.id) &&
        _resourceIdForLine(entry.id) == null &&
        !_pendingResourceMatches.containsKey(entry.id) &&
        _lastTextSeq > line.seq;
    if (!onlyNextLineArrived) return;
    final int? nextTs = _nextLineTimestampAfter(line.seq);
    if (nextTs == null || nextTs <= line.timestampMs) return;
    final GalAudioSlice? closing = await _audioQueue.enqueue<GalAudioSlice?>(
      () => engine.grabUtterance(line.timestampMs, endTsMs: nextTs),
      buildFailure: (Object error, StackTrace stack) => null,
    );
    if (closing == null || closing.isEmpty) return;
    if (closing.pcm.length <= bestBytes) return;
    // 等待期间仍可能夹进一次易主，写回前再核一次。
    if (_recapturingLineId != null ||
        _isUserAdjudicated(entry.id) ||
        _resourceIdForLine(entry.id) != null ||
        _pendingResourceMatches.containsKey(entry.id) ||
        !identical(_audioSource, engine)) {
      return;
    }
    _lineVoiceCache[entry.id] = closing;
    _trimCache(_lineVoiceCache);
    _textService.updateLineAudio(
      entry.id,
      status: TexthookerLineAudioStatus.matched,
      backend: 'engine_pcm',
      durationMs: (closing.pcm.length * 1000) ~/ closing.format.byteRate,
    );
  }

  /// 已消费行里 seq **紧接** [seq] 之后那一行的时间戳；没有则 null。
  ///
  /// 取「最小的 seq > 传入 seq」而不是「最新一行」：一次轮询可能一口气交付好几行，
  /// 拿最新那行当上界会把中间那些行的语音一起圈进来。
  int? _nextLineTimestampAfter(int seq) {
    int? bestSeq;
    int? bestTs;
    for (final MapEntry<String, int> e in _lineTextEventIdCache.entries) {
      if (e.value <= seq) continue;
      if (bestSeq != null && e.value >= bestSeq) continue;
      final int? ts = _lineTimestampCache[e.key];
      if (ts == null) continue;
      bestSeq = e.value;
      bestTs = ts;
    }
    return bestTs;
  }

  /// 收敛循环每次 await 之后的存活判据（BUG-1109）。任一不成立就必须收手——收敛是
  /// 「best-effort 补齐」，绝不能反过来盖掉旧会话、用户裁决或更权威的音源。
  ///
  /// 判据都要**每轮**复查，不能只在进入循环前查一次：循环里的每个 await 都可能夹进
  /// 一次下一句到达、一次补录、一次延迟资源升格。
  bool _canSettleLine({
    required EngineHookGalAudioSource engine,
    required TexthookerLineEntry entry,
    required GalHookedLine line,
  }) =>
      engine == _engineSource &&
      identical(_audioSource, engine) &&
      isLineInCurrentSession(entry) &&
      // 下一句台词已经到了 = 这句语音要么播完、要么被玩家跳过。再等下去，下一句的段
      // 会落进同一个 `[ts-200, ts+6000]` 窗口被拼进上一句。
      _lastTextSeq <= line.seq &&
      // 补录窗口开着 = 用户正在为某行重录，此刻这行的状态由用户裁决拥有。窗口期内
      // `_manualRecaptureLines` 还没写（只有 [finishLineRecapture] 才 add），所以
      // `_isUserAdjudicated` 兜不住这一段，必须与 [_promoteLateEnginePcm] 的
      // `_recapturingLineId != null` 守卫对称显式挡掉，否则收敛会把「录音中」刷成
      // matched/engine_pcm。
      _recapturingLineId == null &&
      !_isUserAdjudicated(entry.id) &&
      // 这行已被延迟资源匹配升格成 game_resource（已配到原件，或正等着配）：原件永远
      // 优先于 PCM 拼接，收敛绝不能把 backend 改回 engine_pcm。与 [_cacheLoopbackForLine]
      // 里的同名判据同纪律。
      _resourceIdForLine(entry.id) == null &&
      !_pendingResourceMatches.containsKey(entry.id);

  /// 逐行语音抓取（原先内联在 [_pollHookedText] 循环里的三条降级分支，语义不变）：
  /// 引擎 PCM 整句 → 时间窗碎片 → loopback 环冻结 → 明确 missing。
  ///
  /// BUG-950：这里的 await 可能跨越一次 stop/重启，期间 engine 被换掉则本任务属于
  /// 旧会话，立即收手，绝不把旧数据写进新会话的行。
  Future<void> _attachLineAudio({
    required EngineHookGalAudioSource engine,
    required TexthookerLineEntry entry,
    required GalHookedLine line,
    required bool resourceReady,
  }) async {
    // BUG-950：入队到执行之间、以及下面每个 await 之间都可能夹一次 stop/重启。
    if (engine != _engineSource || !isLineInCurrentSession(entry)) return;
    GalAudioSlice? clip;
    // BUG-1060：只有 readiness 已选择 engine PCM 作为当前音频源时才读取 engine clip。
    // 文本 helper 在 Loopback 降级会话中仍然保活，但它暴露的残留/未通过门控 PCM 不能
    // 覆盖真正的逐行 Loopback 缓存（下方 _cacheLoopbackForLine 分支）。
    if (!resourceReady && identical(_audioSource, engine)) {
      clip = await engine.grabUtterance(line.timestampMs) ??
          await engine.grabClipNear(line.timestampMs);
      if (engine != _engineSource) return;
    }
    if (clip != null && !clip.isEmpty) {
      _lineVoiceCache[entry.id] = clip;
      _trimCache(_lineVoiceCache);
      _textService.updateLineAudio(
        entry.id,
        status: TexthookerLineAudioStatus.matched,
        backend: 'engine_pcm',
        durationMs: (clip.pcm.length * 1000) ~/ clip.format.byteRate,
      );
      _record(
        GalHookEventSeverity.success,
        'match',
        'audio.utterance_locked',
        'Audio utterance locked to captured line',
        details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
      );
      return;
    }
    final bool loopbackSourced = _audioSource is LoopbackGalAudioSource;
    // 干净源策略下这一步整个跳过：这里排的每一个定时器到点后都会把一段整机混音
    // 写进本行缓存，没配音的句子（旁白/心理描写）拿到的必然是纯 BGM。
    final bool loopbackSuppressed =
        loopbackSourced && !_state.audioFallbackPolicy.allowsLoopback;
    if (loopbackSourced && !loopbackSuppressed) {
      // Loopback 必须按本行自己的时间窗冻结环形片段；制卡时再抓“最近声音”会把
      // 后续台词/BGM 错配给旧行。BUG-1101：窗口必须是前向的，故只在这里排定时器，
      // 到点后才冻结（见 [_scheduleLoopbackFreeze]）。资源音频尚未落盘时也先保留这份
      // 逐行兜底，稍后若资源匹配成功会覆盖为 game_resource。
      _scheduleLoopbackFreeze(entry);
      return;
    }
    if (!resourceReady) {
      // 混音被策略挡掉时走「抑制」分类器：有证据才敢说无配音，没证据就如实说是
      // 策略抑制（见 [_classifySuppressedLoopbackMiss]）。引擎 PCM 会话仍走原分类器。
      final String reason = loopbackSuppressed
          ? await _classifySuppressedLoopbackMiss(
              lineId: entry.id,
              engine: engine,
              timestampMs: line.timestampMs,
            )
          : await _classifyEnginePcmMiss(engine, line.timestampMs);
      if (engine != _engineSource || !isLineInCurrentSession(entry)) return;
      _textService.updateLineAudio(
        entry.id,
        status: TexthookerLineAudioStatus.missing,
        fallbackReason: reason,
      );
      final (GalHookEventSeverity, String, String) event = switch (reason) {
        kGalLineNoVoiceReason => (
            GalHookEventSeverity.info,
            'audio.line_no_voice',
            'No PCM was active at this line; treating it as unvoiced',
          ),
        kGalCleanSourceSuppressedReason => (
            GalHookEventSeverity.info,
            'audio.loopback_suppressed',
            'System loopback audio was suppressed by the clean-source policy',
          ),
        _ => (
            GalHookEventSeverity.warning,
            'audio.utterance_not_found',
            'No engine utterance matched the captured line',
          ),
      };
      _record(
        event.$1,
        'match',
        event.$2,
        event.$3,
        details: <String, Object?>{'lineId': entry.id, 'seq': line.seq},
      );
    }
  }

  /// 引擎 PCM 窗口内没抓到这句语音时，区分「这句本来就没配音」与「疑似漏抓」。
  ///
  /// 证据来自 [EngineHookGalAudioSource.listAudioTracks]：`avgEnergy >= 0` 表示该轨
  /// 在**该句文本时刻窗**（native `[ts-150, ts+450]`）内确有 16-bit clip——
  /// - 候选轨（未被排除、且未被逐轨锁定到别的轨）在该时刻有能量 → 疑似漏抓，红标提醒；
  /// - 候选轨全部沉默（声音只在被排除的 BGM 轨上，或根本没有）→ 判无配音，灰标不告警。
  /// 这样旁白/选项句不再顶着「missing」红标吓人，真正的抓取失败也不会被无配音淹没。
  Future<String> _classifyEnginePcmMiss(
    EngineHookGalAudioSource engine,
    int timestampMs,
  ) async {
    if (timestampMs <= 0) return 'utterance_not_found';
    try {
      final List<GalAudioTrack> tracks =
          await engine.listAudioTracks(timestampMs);
      return _hasSoundingCandidateTrack(engine, tracks)
          ? 'utterance_not_found'
          : kGalLineNoVoiceReason;
    } catch (_) {
      return 'utterance_not_found';
    }
  }

  /// 候选轨（未被排除、且未被逐轨锁定到别的轨）在该句时刻窗内是否响过。抽出来供
  /// [_classifyEnginePcmMiss] 与 [_classifySuppressedLoopbackMiss] 共用，保证两条路径
  /// 用的是同一套「什么算候选轨」的定义。
  ///
  /// 判据用 [GalAudioTrack.isSilentAtCue] 而不是 `avgEnergy >= 0`：`avgEnergy == -1`
  /// 有两义（窗内无片段 / 该轨不是 16-bit 算不了能量，见 BUG-1165）。拿它当「有没有
  /// 声音」用，会把一条**真响过的非 16-bit 语音轨**判成静默，于是整句被宣布「无配音」
  /// ——和本 bug 要修的正是同一类错误：把「我判不出」说成「它没有」。
  bool _hasSoundingCandidateTrack(
    EngineHookGalAudioSource engine,
    List<GalAudioTrack> tracks,
  ) {
    final Set<int> excluded = engine.excludedAudioSourcePtrs;
    final int selected = engine.selectedAudioSourcePtr;
    return tracks.any(
      (GalAudioTrack track) =>
          !excluded.contains(track.sourcePtr) &&
          (selected == 0 || track.sourcePtr == selected) &&
          !track.isSilentAtCue,
    );
  }

  /// 干净源策略把整机混音挡掉之后，这一行到底该报什么。
  ///
  /// 铁律：**只有拿到证据才敢说「这句没配音」**。抑制掉唯一可用音源本身不是证据——
  /// 纯 loopback 降级会话里每一行都会走到这里，全标成「无配音」等于把用户的显式降级
  /// 说成「这游戏没配音」；资源模式下的真漏抓也会被同一句话盖掉。
  ///
  /// 证据只认两种：
  /// - 这行还挂着**原件配对在途**（[_pendingResourceMatches]）= 引擎原件通道是活的、
  ///   这行还在等配对，属于「抓过但没配上」，报疑似漏抓而不是没配音；
  /// - 引擎能枚举出该句时刻窗的**非空**候选轨列表 = 能用 [_hasSoundingCandidateTrack] 判有没有
  ///   声音。空列表不是证据（资源模式根本不枚举 PCM 环），不得据此宣称无配音。
  ///
  /// 两种都拿不到 → [kGalCleanSourceSuppressedReason]，如实说是策略挡掉了本会话唯一
  /// 可用的音源，而不是替游戏宣布这句没有配音。
  Future<String> _classifySuppressedLoopbackMiss({
    required String lineId,
    required EngineHookGalAudioSource? engine,
    required int timestampMs,
  }) async {
    if (_pendingResourceMatches.containsKey(lineId)) {
      return 'utterance_not_found';
    }
    if (engine != null && timestampMs > 0) {
      try {
        final List<GalAudioTrack> tracks =
            await engine.listAudioTracks(timestampMs);
        if (tracks.isNotEmpty) {
          return _hasSoundingCandidateTrack(engine, tracks)
              ? 'utterance_not_found'
              : kGalLineNoVoiceReason;
        }
      } catch (_) {
        // 枚举失败同样不是「没配音」的证据，落到下面的如实说明。
      }
    }
    return kGalCleanSourceSuppressedReason;
  }

  void _promoteLateResourceAudio(EngineHookGalAudioSource engine) {
    if (_state.audioBackend == GalHookAudioBackend.gameResource) return;
    for (final MapEntry<String, int> line in _lineTimestampCache.entries) {
      final int? textEventId = _lineTextEventIdCache[line.key];
      if (textEventId == null) continue;
      // 用户已经为这行裁决过音频（补录 / 选轨），晚到的资源不得改回去。
      if (_isUserAdjudicated(line.key)) continue;
      _pendingResourceMatches[line.key] = (
        timestampMs: line.value,
        textEventId: textEventId,
      );
    }
    _trimCache(_pendingResourceMatches);
    _setState(
      _state.copyWith(
        phase: _state.textSignalReceived
            ? GalHookSessionPhase.running
            : GalHookSessionPhase.waitingSignals,
        audioBackend: GalHookAudioBackend.gameResource,
        clearAudioFormat: true,
        clearFallbackReason: true,
        clearLastError: true,
      ),
    );
    _record(
      GalHookEventSeverity.success,
      'audio',
      'audio.game_resource_late_ready',
      'Late game resource hook is ready and is now the primary audio source',
      details: <String, Object?>{'pid': _state.gamePid},
    );
    _refreshPendingResourceMatches(engine);
    // audioBackend 已切到 gameResource：立即重刷一次音轨快照并停掉 PCM 低频定时器
    //（BUG-1027，资源模式不进 PCM 环，快照保持一致的空/残留态即可）。
    _syncTrackAutoRefresh();
  }

  void _refreshPendingResourceMatches(EngineHookGalAudioSource engine) {
    if (!engine.rawVoiceReady || _pendingResourceMatches.isEmpty) return;
    final List<String> matched = <String>[];
    for (final MapEntry<String, ({int timestampMs, int textEventId})> pending
        in _pendingResourceMatches.entries) {
      if (_isUserAdjudicated(pending.key)) {
        matched.add(pending.key); // 用户已裁决：撤出待匹配集合，不再自动改写。
        continue;
      }
      final String? resourceId = engine.findPairedVoiceResourceId(
        pending.value.timestampMs,
        textEventId: pending.value.textEventId,
      );
      if (resourceId == null) continue;
      _textService.updateLineAudio(
        pending.key,
        status: TexthookerLineAudioStatus.matched,
        backend: 'game_resource',
        resourceId: resourceId,
      );
      matched.add(pending.key);
    }
    for (final String lineId in matched) {
      _pendingResourceMatches.remove(lineId);
    }
  }

  void _onTextBufferChanged() {
    final List<TexthookerLineEntry> entries = _textService.entries;
    final String? latestId = entries.isEmpty ? null : entries.last.id;
    if (latestId != null && latestId != _lastObservedLineId) {
      final TexthookerLineEntry latest = entries.last;
      if (latest.source != TexthookerLineSource.engineHook) {
        _record(
          GalHookEventSeverity.success,
          'text',
          'text.external_line_received',
          'Text line received from external source',
          details: <String, Object?>{
            'lineId': latest.id,
            'source': latest.sourceLabel ?? latest.source.name,
          },
          notify: false,
        );
        if (_state.phase == GalHookSessionPhase.waitingSignals) {
          _state = _state.copyWith(
            phase: GalHookSessionPhase.running,
            textSignalReceived: true,
          );
        } else {
          _state = _state.copyWith(textSignalReceived: true);
        }
        _recordActivityLine(latest.text, fromEngineHook: false);
        _scheduleLoopbackFreeze(latest);
      }
    }
    _lastObservedLineId = latestId;
    notifyListeners();
  }

  void _onEndpointStatusChanged() => notifyListeners();

  /// 为 [entry] 排一次「延迟冻结」（BUG-1101）。
  ///
  /// `grabRecent(backMs)` 的语义是**当前时刻往前** backMs，纯后向、零前向等待
  /// （契约见 [GalAudioSource.grabRecent]）。galgame 的时序恒为「文本先绘制 → 语音随后
  /// 播放」，所以在台词到达那一刻抓，窗口里装的全是**上一句** + BGM，一个本句采样都没有
  /// ——错位一句是旧实现的设计必然，不是抖动。引擎 PCM 路径的 native 窗口本就是前向的
  /// （`grabUtterance`，`[ts-200, ts+6000]`；但**调用时刻**同样太早，见 BUG-1109 的
  /// [_settleLineUtterance]），Loopback 必须对称：记下 t0，等到
  /// t0+[_loopbackFreezeDelay] 再回取 `delay + preRoll`，等价于取 `[t0-preRoll, t0+delay]`。
  ///
  /// 等待刻意放在串行音频队列**之外**：在队列里 sleep 会把后续台词的抓取和制卡一起堵住。
  /// 文本上屏完全不受影响，只有音频后补。
  void _scheduleLoopbackFreeze(TexthookerLineEntry entry) {
    // 策略守卫放在这里而不是只放调用点：[_settleLineUtterance] 的收敛路径也会排
    // 冻结，漏一个调用点就等于「禁止降级」在某条路径上静默失效。
    if (!_state.audioFallbackPolicy.allowsLoopback ||
        _audioSource is! LoopbackGalAudioSource ||
        !isLineInCurrentSession(entry) ||
        _isUserAdjudicated(entry.id) ||
        _loopbackFreezeTimers.containsKey(entry.id) ||
        _loopbackCacheInFlight.contains(entry.id)) {
      return;
    }
    _loopbackFreezeStartedAt[entry.id] = _now();
    _trimCache(_loopbackFreezeStartedAt);
    final int backMs = _loopbackFreezeDelay.inMilliseconds + _loopbackPreRollMs;
    _loopbackFreezeTimers[entry.id] = Timer(_loopbackFreezeDelay, () {
      _loopbackFreezeTimers.remove(entry.id);
      unawaited(
        _audioQueue.enqueue<bool>(
          () async {
            await _cacheLoopbackForLine(entry, backMs: backMs);
            return true;
          },
          buildFailure: (Object error, StackTrace stack) => false,
          onError: (Object error, StackTrace stack) => _record(
            GalHookEventSeverity.error,
            'match',
            'audio.loopback_freeze_exception',
            'Delayed loopback freeze failed',
            details: <String, Object?>{'lineId': entry.id, 'error': '$error'},
          ),
        ),
      );
    });
  }

  /// 提前收束 [lineId] 的延迟冻结：按**真实已等待时长**回取，而不是白等满窗口。
  /// 制卡（用户现在就要这段声音）与引擎 PCM 升格（音源即将换走）都用它。
  /// 已经冻过 / 没排过的行是 no-op。
  ///
  /// BUG-1287 — 「现在就要」不等于「就此定格」。用户在台词播到中后段才查词/制卡时，
  /// elapsedMs 可能只有一秒多，回取到的自然只有这句语音的前半段。旧实现在这里
  /// `timer.cancel()` 之后就再也不碰这一行，那半句话被永久钉死。因此收束之后按**原
  /// 到期时刻**补排一次补全（[_scheduleLoopbackSettle]）：立刻给出能用的，窗口真正
  /// 到点后若拿到更长的再覆盖。这与引擎 PCM 路径的 [_settleLineUtterance] 是同一条
  /// 纪律，Loopback 此前缺了对称的这一半。
  Future<void> _flushLoopbackFreeze(String lineId, {bool settle = true}) async {
    final Timer? timer = _loopbackFreezeTimers.remove(lineId);
    if (timer == null) return;
    timer.cancel();
    final TexthookerLineEntry? entry = _textService.entryById(lineId);
    if (entry == null) {
      _loopbackFreezeStartedAt.remove(lineId);
      return;
    }
    final DateTime? startedAt = _loopbackFreezeStartedAt[lineId];
    final int elapsedMs =
        startedAt == null ? 0 : _now().difference(startedAt).inMilliseconds;
    final int backMs = (elapsedMs + _loopbackPreRollMs)
        .clamp(_loopbackMinBackMs, _loopbackRingCapacityMs)
        .toInt();
    await _cacheLoopbackForLine(entry, backMs: backMs);
    if (settle) {
      _scheduleLoopbackSettle(entry, elapsedMs: elapsedMs);
    }
  }

  /// BUG-1287 — 为提前收束过的 [entry] 补排「窗口到点再取一次完整长度」。
  ///
  /// 复用 [_loopbackFreezeTimers] 装这只定时器，因此会话结束 / 禁止降级
  /// （[_cancelLoopbackFreezes]）、用户补录与选轨（各自 remove 该 lineId）都能像取消
  /// 普通冻结一样把它取消掉，不需要第二套生命周期。
  void _scheduleLoopbackSettle(
    TexthookerLineEntry entry, {
    required int elapsedMs,
  }) {
    // 已经等满窗口才收束的，补全取不到任何新东西。
    final int remainingMs = _loopbackFreezeDelay.inMilliseconds - elapsedMs;
    if (remainingMs <= 0) return;
    if (!_state.audioFallbackPolicy.allowsLoopback ||
        _audioSource is! LoopbackGalAudioSource ||
        !isLineInCurrentSession(entry) ||
        _isUserAdjudicated(entry.id) ||
        _loopbackFreezeTimers.containsKey(entry.id)) {
      return;
    }
    // 完整窗口 = 原本延迟冻结会用的 backMs，等价于取 `[t0-preRoll, t0+delay]`。
    final int fullBackMs =
        _loopbackFreezeDelay.inMilliseconds + _loopbackPreRollMs;
    _loopbackFreezeTimers[entry.id] =
        Timer(Duration(milliseconds: remainingMs), () {
      _loopbackFreezeTimers.remove(entry.id);
      unawaited(
        _audioQueue.enqueue<bool>(
          () async {
            await _cacheLoopbackForLine(
              entry,
              backMs: fullBackMs,
              onlyIfLonger: true,
            );
            return true;
          },
          buildFailure: (Object error, StackTrace stack) => false,
          onError: (Object error, StackTrace stack) => _record(
            GalHookEventSeverity.error,
            'match',
            'audio.loopback_settle_exception',
            'Delayed loopback settle failed',
            details: <String, Object?>{'lineId': entry.id, 'error': '$error'},
          ),
        ),
      );
    });
  }

  /// 收束所有待冻结行（音源即将被换走时调用；此刻还持有旧 Loopback）。
  ///
  /// 这里**不补排** BUG-1287 的补全：补全靠的就是这个 Loopback 源再多录一会儿，而
  /// 调用方的下一步正是把它换掉——排了也只会在到点时被音源检查挡掉，白留一只定时器。
  Future<void> _flushAllLoopbackFreezes() async {
    for (final String lineId in _loopbackFreezeTimers.keys.toList()) {
      await _flushLoopbackFreeze(lineId, settle: false);
    }
  }

  /// 丢弃所有待冻结行（会话结束/重启）。
  void _cancelLoopbackFreezes() {
    for (final Timer timer in _loopbackFreezeTimers.values) {
      timer.cancel();
    }
    _loopbackFreezeTimers.clear();
    _loopbackFreezeStartedAt.clear();
  }

  Future<void> _cacheLoopbackForLine(
    TexthookerLineEntry entry, {
    required int backMs,
    // BUG-1287 — 补全模式（[_scheduleLoopbackSettle]）：这一取是**锦上添花**，只有
    // 拿到更长的切片才覆盖，取空或取短都保持已冻结的结果不动。普通冻结走 false。
    bool onlyIfLonger = false,
  }) async {
    final GalAudioSource? source = _audioSource;
    if (source is! LoopbackGalAudioSource ||
        !isLineInCurrentSession(entry) ||
        // 用户裁决与已配到的原始资源都优先：延迟冻结到点时它们可能已经落定，
        // 这一段回环混音绝不能反过来把它们盖掉。
        _isUserAdjudicated(entry.id) ||
        _resourceIdForLine(entry.id) != null ||
        !_loopbackCacheInFlight.add(entry.id)) {
      return;
    }
    try {
      final GalAudioSlice? slice = await source.grabRecent(backMs);
      if (slice == null || slice.isEmpty || _audioSource != source) {
        // BUG-1287 — 补全取空只说明「这次没拿到更好的」，提前收束时冻下来的那段短
        // 语音仍然有效。把它标 missing 等于用一次失败的加取，毁掉一份已经能用的音频。
        if (!onlyIfLonger) {
          _markLineAudioMissing(entry.id, 'loopback_line_slice_unavailable');
        }
        return;
      }
      if (onlyIfLonger) {
        final GalAudioSlice? existing = _lineVoiceCache[entry.id];
        if (existing != null && slice.pcm.length <= existing.pcm.length) {
          return;
        }
      }
      _lineVoiceCache[entry.id] = slice;
      _trimCache(_lineVoiceCache);
      _textService.updateLineAudio(
        entry.id,
        status: TexthookerLineAudioStatus.fallback,
        backend: 'system_loopback',
        durationMs: (slice.pcm.length * 1000) ~/ slice.format.byteRate,
        fallbackReason: 'engine_utterance_unavailable',
      );
      _record(
        GalHookEventSeverity.info,
        'match',
        'audio.loopback_line_locked',
        'System loopback audio was locked to the captured line',
        details: <String, Object?>{'lineId': entry.id, 'backMs': backMs},
      );
    } finally {
      _loopbackCacheInFlight.remove(entry.id);
      _loopbackFreezeStartedAt.remove(entry.id);
    }
  }

  void _markLineAudioMissing(String lineId, String reason) {
    _textService.updateLineAudio(
      lineId,
      status: TexthookerLineAudioStatus.missing,
      fallbackReason: reason,
    );
    _record(
      GalHookEventSeverity.warning,
      'audio',
      'audio.capture_missing',
      'No audio was available for the selected line',
      details: <String, Object?>{'lineId': lineId, 'reason': reason},
    );
  }

  void _fail(
    String stage,
    String code,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
    GalHookInjectorFailure failure = GalHookInjectorFailure.none,
    String detail = '',
  }) {
    _setState(
      _state.copyWith(
        phase: GalHookSessionPhase.error,
        lastError: message,
        injectorFailure: failure,
        injectorDetail: detail,
        audioBackend: GalHookAudioBackend.none,
        clearAudioFormat: true,
      ),
    );
    _record(GalHookEventSeverity.error, stage, code, message, details: details);
  }

  /// 超分**此刻应该挂在哪个游戏窗口上** —— 开与关唯一的共同判据。
  ///
  /// 这是本轮修复的核心。此前「开」挂在 `_setState` 的窗口「无 → 有」跃迁上、「关」
  /// 挂在 `stopCapture` / `close` 的方法调用点上，两边判据不同源，于是长出三个特殊
  /// 情况：① `stopCapture` 的 idle 早退分支在通知结束之前就 return，Magpie 成孤儿；
  /// ② `keepBinding: true` 保留 `boundWindow`，「无 → 有」跃迁第二局永远不再发生，
  /// 超分静默失效；③ 正常退出根本没人调 `close`。把两边收回同一个纯函数判据后，这三
  /// 类特殊情况一次性消失 —— 没有分支可漏，因为压根没有分支。
  ///
  /// 判据本身：**会话真的在跑**（phase 不是 idle）**且**绑定了游戏窗口。只在窗口列表
  /// 里选中一个窗口（phase 仍 idle）不算 —— 那时用户还没开始玩，没有理由动他的显示。
  @visibleForTesting
  static int? magpieUpscalingTargetHwnd(GalHookSessionState state) {
    final ExternalWindowInfo? window = state.boundWindow;
    if (window == null) return null;
    if (state.phase == GalHookSessionPhase.idle) return null;
    return window.hwnd;
  }

  void _setState(GalHookSessionState next) {
    _state = next;
    _syncMagpieUpscaling();
    notifyListeners();
  }

  /// 把超分的实际状态对齐到 [magpieUpscalingTargetHwnd]。开与关走**同一条**路，所以
  /// 不存在「某条早退分支忘了关」。fire-and-forget（超分绝不阻塞状态更新），但每条
  /// 边沿都排进 [_magpieWork]，退出 / [close] 可以 await 它真的收完。
  void _syncMagpieUpscaling() {
    final int? target = magpieUpscalingTargetHwnd(_state);
    final int? armed = _magpieArmedHwnd;
    if (target == armed) return;
    _magpieArmedHwnd = target;
    // 换窗口 = 先关旧的再开新的，顺序由队列保证。
    if (armed != null) _enqueueMagpieWork(_notifyMagpieSessionEnded);
    if (target != null) {
      _enqueueMagpieWork(() => _notifyMagpieWindowReady(target));
    }
  }

  /// 仅测试：等超分的开 / 关边沿队列排空。生产代码不该 await 它（那会让状态更新
  /// 等在一个跨进程操作上），退出路径用 [shutdownMagpieUpscaling]。
  @visibleForTesting
  Future<void> get magpieUpscalingSettled => _magpieWork;

  /// 仅测试：当前挂着超分的窗口 hwnd（null = 没挂）。
  @visibleForTesting
  int? get magpieArmedHwnd => _magpieArmedHwnd;

  void _enqueueMagpieWork(Future<void> Function() job) {
    final Future<void> next = _magpieWork.then((_) => job());
    _magpieWork = next.catchError((Object _) {});
    unawaited(next);
  }

  /// 退出 / 销毁前把超分收干净，并**等它真的收完**。
  ///
  /// 为什么必须显式登记进 [ExitFlushRegistry]：桌面点 X 走 `exit(0)` 快杀，[close] 在
  /// fushi/lib 里一次都没被调用过。不接这一步，我们 detached 起的 Magpie 会活过 Hibiki
  /// 的死亡，配置里那条 `autoScale=Fullscreen` 也留着 —— 用户下次**不经 Hibiki**双击
  /// 游戏就被自动全屏超分，那是我们没被授权做的事。
  Future<void> shutdownMagpieUpscaling() async {
    if (_magpieArmedHwnd != null) {
      _magpieArmedHwnd = null;
      _enqueueMagpieWork(() => _notifyMagpieSessionEnded(urgent: true));
    }
    await _magpieWork;
  }

  /// 把「游戏窗口就绪」转给超分编排器。**吞掉一切异常**：超分是锦上添花，它出问题
  /// 不能让 hook 会话跟着倒。
  Future<void> _notifyMagpieWindowReady(int hwnd) async {
    try {
      await _magpieUpscaling?.onGameWindowReady(hwnd: hwnd);
    } catch (_) {}
  }

  /// 会话收尾时关掉超分（关 autoScale profile + 退出我们自己起的 Magpie）。同样吞异常。
  Future<void> _notifyMagpieSessionEnded({bool urgent = false}) async {
    try {
      await _magpieUpscaling?.onSessionEnded(urgent: urgent);
    } catch (_) {}
  }

  void _record(
    GalHookEventSeverity severity,
    String stage,
    String code,
    String summary, {
    Map<String, Object?> details = const <String, Object?>{},
    bool notify = true,
  }) {
    _events.add(
      GalHookEvent(
        id: _eventId++,
        timestamp: _now(),
        severity: severity,
        stage: stage,
        code: code,
        summary: summary,
        details: Map<String, Object?>.unmodifiable(details),
      ),
    );
    if (_events.length > _eventLimit) {
      _events.removeRange(0, _events.length - _eventLimit);
    }
    if (notify) notifyListeners();
  }

  void _trimCache<T>(Map<String, T> cache) {
    while (cache.length > _voiceCacheMax) {
      cache.remove(cache.keys.first);
    }
  }
}
