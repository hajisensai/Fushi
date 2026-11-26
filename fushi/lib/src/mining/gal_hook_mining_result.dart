/// gal 场景卡一次制卡的结果值类型（[GalHookMiningResult] / [GalHookMiningFailureStage] /
/// [GalHookRetryWrite]）。
///
/// 单独成叶子文件：提示文案分流（`gal_hook_mining_failure_text.dart`）等只读结果的件不该为了
/// 这几个值类型 import 整个编排器（`gal_hook_mining_coordinator.dart` 在 lib/ 的 import 大环里，
/// 见 `test/build/import_cycle_guard_test.dart`）。编排器原样 re-export，既有调用方不变。
library;

import 'package:fushi_anki/fushi_anki.dart'
    show BaseAnkiRepository, MineOutcome, MineResult;

/// 一次 gal 场景卡**没走到制卡结局**（[GalHookMiningResult.aborted]）时停在哪一步。
///
/// 提示文案按它分流（[GalHookMiningResult.failureStage]）：写卡阶段被引擎中止、行已失效
/// 这些都不是「窗口截图失败」，不能一律报成截图失败（#4362 审查遗留）。
enum GalHookMiningFailureStage {
  /// 采样前这句台词已失效：不在当前会话、出现位置已变、或冻结截图与该行对不上。
  lineUnavailable,

  /// 没有绑定游戏窗口（或不在外部窗口模式）。
  windowUnbound,

  /// 抓游戏窗口画面失败。
  capture,

  /// 「只用游戏原始资源」的音频门禁：没拿到对应语音，按设置拒绝制卡。
  audioGate,

  /// 画面与句音都已到手，写卡阶段被制卡引擎中止（缺必需音频 / 封面与音频都没产出等）。
  write,

  /// 编排本身抛了未预期的异常（串行队列兜底）。
  internal,
}

class GalHookMiningResult {
  const GalHookMiningResult({
    this.outcome,
    this.failureStage,
    this.failureReason,
    this.sentenceAudioMissing = false,
    this.degradedToStill = false,
    this.degradedToAnimated = false,
    this.staleScene = false,
    this.unmappedTokens = const <String>[],
    this.retryWrite,
  }) : assert(
         (outcome == null) == (failureStage != null),
         'an aborted result must say which stage stopped it; '
         'a result with an outcome has no failure stage',
       );

  final MineOutcome? outcome;

  /// [aborted] 时非空：停在哪一步。有 [outcome]（含失败结局）时为空。
  final GalHookMiningFailureStage? failureStage;
  final String? failureReason;
  final bool sentenceAudioMissing;
  final bool degradedToStill;

  /// 用户选了「视频片段」但片段没做出来（录制未启动 / 帧不足 2 张 / ffmpeg 失败），
  /// 退回动图成卡时置真。再退到静图时置的是 [degradedToStill]（两者互斥）。
  final bool degradedToAnimated;

  /// 制卡的是**历史行**（非当前最新行）时置真：画面截图只能抓 mine 时刻的当前窗口帧，
  /// 无法重建历史行当时的画面，故显式标注「画面可能与该台词不对应」，供调用方提示用户
  /// （BUG-955：禁止把当前画面冒充成历史台词的画面而不告知）。
  final bool staleScene;

  /// 被「只用游戏原始资源」音频门禁拒绝（[GalHookMiningFailureStage.audioGate]）。
  bool get audioFallbackDisabled =>
      failureStage == GalHookMiningFailureStage.audioGate;
  final List<String> unmappedTokens;

  /// 反馈 y90oiVojic：写卡这一步失败（Anki 没开 / 没配置 / 引擎中止）时非空。用**这一次
  /// 已经做好的**画面与句音重新写卡，不重新抓窗口——后台落地时那句台词早已不在屏上，
  /// 重抓只会抓到别的画面。重复卡片、音频门禁、画面失败不给重试（重来结果不会变）。
  ///
  /// [repo] 是**点重试这一刻**的制卡仓库：失败多半是「没配置 / 后端没开」，用户改完
  /// 设置（可能换了制卡目标）再点重试，要写进现在的目标，而不是失败那一刻的旧仓库。
  final GalHookRetryWrite? retryWrite;

  bool get aborted => outcome == null;
  bool get success => outcome?.result == MineResult.success;

  /// BUG-1908：制卡失败是不是**因为 Anki 里已经有这张卡**。见
  /// `MinePopupResult.duplicate` —— 浮窗据它区分「卡已存在」与「真的没制成」，
  /// 不必回查 Anki（TODO-448 禁止失败后回查把按钮翻成 ✓）。
  bool get duplicate => outcome?.result == MineResult.duplicate;

  /// 后端暂不可达（或批量制卡），卡进了本机待发队列、之后补发。浮窗画 ✓ 不回查
  /// （popup.js `reply.queued`），也不带失败原因——卡没有丢。
  bool get queued => outcome?.result == MineResult.queued;

  /// BUG-1908：[message] 是**失败时给用户看的原因**，由调用方（浮窗控制器）填入
  /// 已本地化的文案。
  ///
  /// 此前这个回程只有两个字段，宿主即便算出了「没选卡组 / 字段映射对不上 / 截图
  /// 失败」也没地方放；浮窗那边 `ankiConnect:false` 是正常 resolve、不抛，
  /// 既不进 catch 也不进 if —— 整段没有 else，用户零反馈。而 galgame 浮窗是独立的
  /// native WebView2 窗口，宿主的 Flutter toast 画在主 app 窗口的 Overlay 上，
  /// 游戏全屏时主窗在后台，那些 toast 一个也看不见。
  Map<String, Object?> toPopupReply({String? message}) => <String, Object?>{
    'ankiConnect': success,
    'noteId': success ? outcome?.noteId : null,
    if (!success && !queued && message != null && message.isNotEmpty)
      'message': message,
    if (duplicate) 'duplicate': true,
    if (queued) 'queued': true,
  };

  /// 反馈 y90oiVojic：新卡采样完成、写卡转后台时立刻回给查词弹窗的回包。popup.js 据
  /// `queued` 把按钮画成「已加入制卡队列」的 ✓ 并解锁（与在线视频后台制卡同一形态），
  /// 用户可以马上挖下一个词；结局由宿主在落地时报。
  static const Map<String, Object?> queuedPopupReply = <String, Object?>{
    'ankiConnect': false,
    'noteId': null,
    'queued': true,
  };
}

/// 写卡失败后的重写入口（见 [GalHookMiningResult.retryWrite]）。
typedef GalHookRetryWrite =
    Future<GalHookMiningResult> Function({required BaseAnkiRepository repo});
