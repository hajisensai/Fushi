// 反馈：提交（正文 + 设备信息 + 压缩日志 + 截图）与本机提交记录的进度跟踪。
//
// 服务端是 fushi.moe 的账户服务（services/leaderboard，路由见 src/feedback.js）。
// 反馈不要求账户：提交拿到一次性回执（ticket）立刻落盘（FeedbackTicketStore），之后凭它
// 查进度、追加说明。已登录排行榜账户时默认带签名提交，开发者那边能看到是谁。
// 本服务的网络请求只在用户打开反馈中心 / 提交 / 看详情时发出；「有新回复」的被动检查
// （启动 / 回前台 / 桌面定时 / 移动端系统后台任务，都要有未结案反馈且 15 分钟节流）见
// feedback_reply_notifier.dart 与 feedback_reply_background.dart。
//
// 附件没传上去（网络中断等）时字节落盘到 FeedbackPendingStore，详情页可「重试上传」；
// 服务端 24 小时内允许补传空闲槽位（与 PR #2090 的待传重试是同一机制）。视频（槽位 v0，
// ≤ 50 MB）先在本机转码成 720p / 1080p H.264（feedback_video.dart），从待传区的文件流式上传。
//
// 「我的反馈」= 本机回执 ∪ 账户列表：已登录排行榜账户时另拉 GET /v1/feedback/mine
// （别的设备带账户提交的也在里面），按 id 去重、本机回执优先；账户列表里的条目没有 ticket
// （[FeedbackTicket.viaAccount]），看详情 / 追加说明 / 标记完成都用账户签名。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_draft_store.dart';
import 'package:fushi/src/feedback/feedback_reply_alerts.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/updates/usage_heartbeat.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/install_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:path/path.dart' as p;

/// 用户在提交页填写 / 勾选的内容。
class FeedbackDraft {
  const FeedbackDraft({
    required this.category,
    required this.title,
    required this.body,
    this.contact = '',
    this.includeLogs = true,
    this.includeDeviceInfo = true,
    this.includeDebugLog = true,
    this.linkAccount = true,
    this.screenshots = const <Uint8List>[],
    this.video,
    this.reopenOf,
    this.submissionKey,
  });

  final FeedbackCategory category;
  final String title;
  final String body;
  final String contact;
  final bool includeLogs;
  final bool includeDeviceInfo;

  /// [includeLogs] 时是否连调试日志一起带（仍要用户开着「调试日志」才有内容）。手动反馈
  /// 默认带；闪退自动报告不带（[buildCrashReportDraft]），只发错误日志与退出摘要。
  final bool includeDebugLog;

  /// 已登录排行榜账户时是否关联账户提交（开发者能看到昵称）。
  final bool linkAccount;

  /// PNG / JPEG / WebP 字节，最多 [FeedbackLimits.screenshots] 张。
  final List<Uint8List> screenshots;

  /// 用户选的视频文件（原件不动；上传前在本机转码）。每条反馈最多一个。
  final File? video;

  /// 「问题没解决，重新提交」：原反馈 id（必须是本机清单里的、带 ticket 的那条）。
  final String? reopenOf;

  /// 提交幂等键（[newFeedbackSubmissionKey]）：**同一次提交**的重试必须带同一个键。
  /// 请求其实到了服务端、回执却没收到（超时 / 断网）时，重试拿回的是同一条反馈的回执，
  /// 而不是再建一条重复反馈。null = 不要幂等（每次都是新提交）。
  final String? submissionKey;
}

/// 新的提交幂等键：24 字节安全随机数的 base64url（32 位，服务端要求 32–64 位）。
/// 键只经 TLS 发给服务端、服务端只存哈希，回执 ticket 由它派生——等价于本机自己出
/// ticket，所以必须用安全随机数。
String newFeedbackSubmissionKey([Random? random]) {
  final Random r = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(24, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

/// 提交进行到哪一步（提交页的进度文案）。[videoPrepare] 在发正文之前（转码失败 / 太大
/// 要在反馈交上去之前告诉用户），[video] 是最后一步（最大的附件最后传）。
enum FeedbackSubmitStage { videoPrepare, sending, screenshots, logs, video }

/// 视频附件正在做什么（详情页「追加视频」/「重试上传」的进度）。
enum FeedbackVideoStage { preparing, uploading }

/// 一条反馈的视频附件进度：[fraction] 0..1，未知（转码拿不到时长）为 null。
class FeedbackVideoTransfer {
  const FeedbackVideoTransfer(this.stage, [this.fraction]);

  final FeedbackVideoStage stage;
  final double? fraction;
}

/// 一次补传的结果。
class FeedbackRetryResult {
  const FeedbackRetryResult({
    this.uploaded = 0,
    this.remaining = 0,
    this.dropped = 0,
  });

  /// 这次传成功的附件数。
  final int uploaded;

  /// 仍然没传上去、留在本机待重试的附件数（网络类失败）。
  final int remaining;

  /// 服务端明确拒收、不会再重试而丢掉的附件数（超过 24 小时补传窗口等）。
  final int dropped;
}

/// 一次视频准备的选项：压缩档位、取消、选 1080p 却退回 720p 时的通知。
class FeedbackVideoPrepareOptions {
  const FeedbackVideoPrepareOptions({
    this.quality = FeedbackVideoQuality.p720,
    this.cancel,
    this.onDowngraded,
  });

  final FeedbackVideoQuality quality;

  /// 完成即中止压缩（强杀 ffmpeg、删半成品），准备函数抛 [FeedbackVideoCancelledException]。
  final Future<void>? cancel;

  final void Function()? onDowngraded;
}

/// 视频准备函数（默认 [prepareFeedbackVideo]；测试注入假转码）。
typedef FeedbackVideoPreparer =
    Future<PreparedFeedbackVideo> Function(
      File source,
      Directory workDir,
      void Function(double fraction) onProgress,
      FeedbackVideoPrepareOptions options,
    );

Future<PreparedFeedbackVideo> _defaultPrepareVideo(
  File source,
  Directory workDir,
  void Function(double fraction) onProgress,
  FeedbackVideoPrepareOptions options,
) => prepareFeedbackVideo(
  source,
  workDir: workDir,
  onProgress: onProgress,
  quality: options.quality,
  cancel: options.cancel,
  onDowngraded: options.onDowngraded,
);

/// 提交前已在本机压好的视频（[FeedbackService.stageVideo]）。工作目录归它：交给
/// [FeedbackService.submit] 后由提交清理，没交出去（放弃 / 出错）时调用方 [discard]。
class FeedbackStagedVideo {
  FeedbackStagedVideo._(this.video, this._work);

  final PreparedFeedbackVideo video;
  final Directory _work;

  /// 删掉压缩产物与工作目录（可重复调）。
  Future<void> discard() => FeedbackService._deleteQuietly(_work);
}

class FeedbackSubmitResult {
  const FeedbackSubmitResult(this.ticket, {this.failedAttachments = 0});

  final FeedbackTicket ticket;

  /// 正文已提交、但没传上去的附件数（网络中断等）。
  final int failedAttachments;
}

class FeedbackService extends ChangeNotifier {
  FeedbackService({
    required Future<Directory> Function() supportRoot,
    required LeaderboardClient Function() client,
    Future<Map<String, Object?>> Function()? meta,
    Future<InstallAttestation?> Function()? installId,
    String Function({required bool includeDebugLog})? logText,
    Uint8List Function(String log)? logEncoder,
    FeedbackVideoPreparer? prepareVideo,
    this.onSubmitted,
  }) : _supportRoot = supportRoot,
       _client = client,
       _meta = meta ?? collectFeedbackMeta,
       _installId = installId ?? _noInstallId,
       _logText = logText ?? collectFeedbackLogText,
       _logEncoder = logEncoder ?? buildFeedbackLogGzip,
       _prepareVideo = prepareVideo ?? _defaultPrepareVideo;

  final Future<Directory> Function() _supportRoot;
  final LeaderboardClient Function() _client;
  final Future<Map<String, Object?>> Function() _meta;

  /// 安装统计的本机安装证明（[usageStatsInstallIdForFeedback]）；null = 不附带。只在勾选
  /// 「附带设备信息」时取，开发者处理台据此关联该安装的版本轨迹与它的其它反馈；带了证明的
  /// 服务端标「已验证」。
  final Future<InstallAttestation?> Function() _installId;

  static Future<InstallAttestation?> _noInstallId() async => null;

  /// 取安装证明；机器标识读取 / 工作量证明出错时记错误日志并按不附带处理——安装关联只是
  /// 辅助信息，不能让它挡住反馈本身的提交。
  Future<InstallAttestation?> _installIdOrNull() async {
    try {
      return await _installId();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.install_attestation', e, st);
      return null;
    }
  }

  final String Function({required bool includeDebugLog}) _logText;
  final Uint8List Function(String log) _logEncoder;
  final FeedbackVideoPreparer _prepareVideo;

  /// 一条反馈提交成功（已拿到回执落盘）之后：生产装配用它排上「有新回复时通知我」的
  /// 后台检查、首次提交时申请通知权限（见 feedback_reply_alerts.dart）。不等它完成。
  final Future<void> Function()? onSubmitted;

  FeedbackTicketStore? _store;
  FeedbackPendingStore? _pendingStore;

  /// 反馈 id → 还没传上去的附件槽位（磁盘上的 [FeedbackPendingStore] 的内存镜像）。
  final Map<String, Set<String>> _pending = <String, Set<String>>{};

  /// 反馈 id → 视频附件进行中的转码 / 上传进度。
  final Map<String, FeedbackVideoTransfer> _transfers =
      <String, FeedbackVideoTransfer>{};
  List<FeedbackTicket> _tickets = <FeedbackTicket>[];

  /// 账户列表里、本机没有回执的条目（ticket 为空串），见 [refreshAccount]。
  List<FeedbackTicket> _accountTickets = <FeedbackTicket>[];

  /// [_accountTickets] 属于哪个账户（设备钥匙 id）；换账户 / 退出登录时整份丢掉。
  String? _accountKey;
  bool _loaded = false;

  /// 进行中的那次 [refresh]；没有时为 null。并发的 [refresh] 合并到它上面。
  Future<void>? _refreshInFlight;
  Future<void>? _loading;

  /// 「我的反馈」：本机回执在前（新的在前），再接账户列表里本机没有回执的（新的在前）。
  List<FeedbackTicket> get tickets => List<FeedbackTicket>.unmodifiable(
    <FeedbackTicket>[..._tickets, ..._accountTickets],
  );

  bool get loaded => _loaded;
  bool get refreshing => _refreshInFlight != null;

  /// 有开发者新进展、用户还没看过的条数（入口红点）。
  int get unseenCount =>
      tickets.where((FeedbackTicket t) => t.hasUnseenReply).length;

  Future<FeedbackTicketStore> _storeFor() async =>
      _store ??= FeedbackTicketStore(await _supportRoot());

  Future<FeedbackPendingStore> _pendingFor() async =>
      _pendingStore ??= FeedbackPendingStore(await _supportRoot());

  /// 这条反馈还没传上去的附件槽位（`s0`..`s2` / `log` / `v0`）。
  Set<String> pendingSlots(String id) =>
      Set<String>.unmodifiable(_pending[id] ?? const <String>{});

  /// 视频附件进行中的转码 / 上传（没有返回 null）。
  FeedbackVideoTransfer? videoTransfer(String id) => _transfers[id];

  /// 这条反馈还在服务端的补传窗口内（见 [FeedbackLimits.attachWindow]），且是本机回执
  /// （账户列表里的条目不能补传：补传只认 ticket）。
  bool canAttach(FeedbackTicket t) =>
      !t.viaAccount &&
      DateTime.now().millisecondsSinceEpoch - t.createdAt <=
          FeedbackLimits.attachWindow.inMilliseconds;

  /// 上次提交填的联系方式（新反馈预填用）；没有 / 读失败返回空串。
  Future<String> lastContact() async {
    try {
      return await FeedbackContactStore(await _supportRoot()).read();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.last_contact_read', e, st);
      return '';
    }
  }

  FeedbackDraftStore? _draftStore;

  /// 提交页草稿（本机一份，见 [FeedbackDraftStore]）。
  Future<FeedbackDraftStore> draftStore() async =>
      _draftStore ??= FeedbackDraftStore(await _supportRoot());

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    _tickets = await (await _storeFor()).read();
    try {
      final Map<String, Set<String>> pending = await (await _pendingFor())
          .scan();
      _pending
        ..clear()
        ..addAll(pending);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.pending_scan', e, st);
    }
    final String? key = _client().identity?.accountId;
    if (key != null) {
      try {
        _accountKey = key;
        _accountTickets = _withoutLocal(
          await FeedbackTicketStore.account(await _supportRoot(), key).read(),
        );
      } on Object catch (e, st) {
        ErrorLogService.instance.log('feedback.account_cache_read', e, st);
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 去掉本机已有回执的条目（同一条以本机回执为准：它能补传附件）。
  List<FeedbackTicket> _withoutLocal(List<FeedbackTicket> items) {
    final Set<String> local = <String>{
      for (final FeedbackTicket t in _tickets) t.id,
    };
    return <FeedbackTicket>[
      for (final FeedbackTicket t in items)
        if (!local.contains(t.id)) t,
    ];
  }

  Future<void> _persistAccount() async {
    final String? key = _accountKey;
    if (key == null) return;
    try {
      await FeedbackTicketStore.account(
        await _supportRoot(),
        key,
      ).write(_accountTickets);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.account_cache_write', e, st);
    }
  }

  Future<void> _persist() async {
    await (await _storeFor()).write(_tickets);
    notifyListeners();
  }

  /// 拉全部记录的最新进度（每批 ≤ 50）。查不到的条目标 missing（保留，由用户删）。
  /// 网络错误原样抛给调用方（反馈中心显示「刷新失败」）。
  ///
  /// 换账户 / 退出登录后旧账户的列表在联网之前就丢掉（[_dropStaleAccountTickets]）：
  /// 它只取决于本机身份，不该等批量查进度成功——断网时那一步就抛了，旧账户的工单标题
  /// 会一直挂在列表里。
  ///
  /// 已有一次刷新在进行时**合并**到那一次：返回它的 Future，等它真正结束、拿到同一个
  /// 成败。不能直接返回——调用方（`FeedbackReplyNotifier`）会把「立刻返回、没抛」
  /// 当成刷新成功，记下刷新时刻后 15 分钟内不再查，而那次刷新可能随后失败，或者它的
  /// 结果在调用方读 [tickets] 时还没落下。
  Future<void> refresh() async {
    await load();
    _dropStaleAccountTickets(_client().identity?.accountId);
    final Future<void>? running = _refreshInFlight;
    if (running != null) return running;
    // _fetchProgress 是 async：同步调用不会立刻跑完，whenComplete 一定晚于下面的赋值。
    final Future<void> run = _fetchProgress().whenComplete(() {
      _refreshInFlight = null;
      notifyListeners();
    });
    _refreshInFlight = run;
    notifyListeners();
    return run;
  }

  /// 一次刷新的实际工作：批量查本机回执的进度，再拉账户列表。错误原样抛。
  Future<void> _fetchProgress() async {
    final LeaderboardClient client = _client();
    final Map<String, FeedbackSummary> fresh = <String, FeedbackSummary>{};
    for (int i = 0; i < _tickets.length; i += FeedbackLimits.statusBatch) {
      final List<FeedbackTicket> batch = _tickets.sublist(
        i,
        (i + FeedbackLimits.statusBatch).clamp(0, _tickets.length),
      );
      final List<FeedbackSummary> got = await client.feedbackStatuses(
        <({String id, String ticket})>[
          for (final FeedbackTicket t in batch) (id: t.id, ticket: t.ticket),
        ],
      );
      for (final FeedbackSummary s in got) {
        fresh[s.id] = s;
      }
    }
    if (_tickets.isNotEmpty) {
      _tickets = <FeedbackTicket>[
        for (final FeedbackTicket t in _tickets)
          if (fresh[t.id] case final FeedbackSummary s)
            t.mergeSummary(s)
          else
            t.copyWith(missing: true),
      ];
      await _persist();
    }
    await _refreshAccount();
  }

  /// 账户列表只属于 [_accountKey]：当前身份 [key] 不是它（换账户 / 退出登录）就整份丢掉。
  void _dropStaleAccountTickets(String? key) {
    if (key == _accountKey) return;
    _accountKey = key;
    _accountTickets = <FeedbackTicket>[];
    notifyListeners();
  }

  /// 账户列表最多拉几页（每页 [FeedbackLimits.minePage] 条）。
  static const int _kMinePages = 5;

  /// 已登录排行榜账户时拉 GET /v1/feedback/mine，替换账户列表（保留各条的已读时刻）。
  /// 没登录 / 换了账户：丢掉旧账户的列表。网络错误原样抛（与 [refresh] 同口径）。
  Future<void> _refreshAccount() async {
    final LeaderboardClient client = _client();
    final String? key = client.identity?.accountId;
    // 批量查进度的那段时间里也可能换了账户：这里再核对一次。
    _dropStaleAccountTickets(key);
    if (key == null) return;
    final List<FeedbackSummary> items = <FeedbackSummary>[];
    String? cursor;
    for (int page = 0; page < _kMinePages; page++) {
      final FeedbackInboxPage got = await client.myFeedback(
        cursor: cursor,
        limit: FeedbackLimits.minePage,
      );
      items.addAll(got.items);
      cursor = got.next;
      if (cursor == null) break;
    }
    // 拉的过程中换了账户：结果作废。
    if (_client().identity?.accountId != key) return;
    final Map<String, FeedbackTicket> previous = <String, FeedbackTicket>{
      for (final FeedbackTicket t in _accountTickets) t.id: t,
    };
    // 本机有回执的那条顺便刷新进度（status 批量接口只认 ticket，这里多一个来源无妨）。
    _accountTickets = _withoutLocal(<FeedbackTicket>[
      for (final FeedbackSummary s in items)
        previous[s.id]?.mergeSummary(s) ?? FeedbackTicket.fromAccount(s),
    ]);
    await _persistAccount();
    notifyListeners();
  }

  /// 提交反馈：先发正文（拿回执并立刻落盘），再逐个补传截图与日志。附件失败不影响
  /// 反馈本身，计入 [FeedbackSubmitResult.failedAttachments]。正文提交失败原样抛出。
  ///
  /// 带视频时先在本机转码（[FeedbackSubmitStage.videoPrepare]，[onVideoProgress] 回报
  /// 0..1；太大 / 不是视频直接抛，反馈不提交），正文与其它附件交完后最后传视频
  /// （[FeedbackSubmitStage.video]）；视频传失败留在待传区，详情页可重试。
  ///
  /// [stagedVideo] 非空 = 调用方已用 [stageVideo] 压好（提交页选完视频就在后台压）：直接用它、
  /// 不再转码，[FeedbackDraft.video] 不再看。它的工作目录仍归调用方：正文没发出去时留着可以
  /// 原样再提交，提交成功后由调用方 [FeedbackStagedVideo.discard]（视频已挪进待传区）。
  Future<FeedbackSubmitResult> submit(
    FeedbackDraft draft, {
    void Function(FeedbackSubmitStage stage)? onStage,
    void Function(double? fraction)? onVideoProgress,
    FeedbackStagedVideo? stagedVideo,
  }) async {
    if (stagedVideo != null) {
      await load();
      return _submit(draft, onStage, stagedVideo.video, onVideoProgress);
    }
    await load();
    final File? source = draft.video;
    if (source == null) return _submit(draft, onStage, null, null);
    final Directory work = await _videoWorkDir();
    try {
      onStage?.call(FeedbackSubmitStage.videoPrepare);
      onVideoProgress?.call(null);
      final PreparedFeedbackVideo video = await _prepareVideo(
        source,
        work,
        (double f) => onVideoProgress?.call(f),
        const FeedbackVideoPrepareOptions(),
      );
      return await _submit(draft, onStage, video, onVideoProgress);
    } finally {
      await _deleteQuietly(work);
    }
  }

  /// 提交页选完视频就调：在本机把视频压好（[onProgress] 回报 0..1），用户同时写反馈；
  /// [FeedbackVideoPrepareOptions.cancel] 完成即中止并清掉工作目录，抛
  /// [FeedbackVideoCancelledException]。太大 / 不是视频照常抛（工作目录同样清掉）。
  /// 返回值交给 [submit] 的 `stagedVideo`，不提交时调用方负责 [FeedbackStagedVideo.discard]。
  Future<FeedbackStagedVideo> stageVideo(
    File source, {
    FeedbackVideoPrepareOptions options = const FeedbackVideoPrepareOptions(),
    void Function(double fraction)? onProgress,
  }) async {
    final Directory work = await _videoWorkDir();
    try {
      final PreparedFeedbackVideo video = await _prepareVideo(
        source,
        work,
        (double f) => onProgress?.call(f),
        options,
      );
      return FeedbackStagedVideo._(video, work);
    } on Object {
      await _deleteQuietly(work);
      rethrow;
    }
  }

  Future<FeedbackSubmitResult> _submit(
    FeedbackDraft draft,
    void Function(FeedbackSubmitStage stage)? onStage,
    PreparedFeedbackVideo? video,
    void Function(double? fraction)? onVideoProgress,
  ) async {
    final LeaderboardClient client = _client();
    onStage?.call(FeedbackSubmitStage.sending);
    final Map<String, Object?> meta = draft.includeDeviceInfo
        ? await _meta()
        : const <String, Object?>{};
    final InstallAttestation? install = draft.includeDeviceInfo
        ? await _installIdOrNull()
        : null;
    // 重新提交：凭原反馈自己的 ticket 证明是本人的反馈（服务端还会核对原反馈已结案）。
    FeedbackTicket? parent;
    if (draft.reopenOf != null) {
      parent = byId(draft.reopenOf!);
      if (parent == null) {
        throw StateError('unknown feedback ${draft.reopenOf}');
      }
    }
    final FeedbackReceipt receipt = await client.submitFeedback(
      category: draft.category,
      title: draft.title.trim(),
      body: draft.body.trim(),
      contact: draft.contact.trim(),
      meta: <String, Object?>{
        ...meta,
        'logs_attached': draft.includeLogs,
        'screenshots': draft.screenshots.length,
        if (video != null) 'video': true,
      },
      linkAccount: draft.linkAccount,
      reopenOf: parent == null ? null : (id: parent.id, ticket: parent.ticket),
      install: install,
      submissionKey: draft.submissionKey,
    );
    // 从这里起反馈**已经交上去了**：之后任何一步（落盘、补传附件）出错都不能再让调用方
    // 以为「提交失败」——用户会再点一次，生成一条重复反馈（BUG-3489 审查）。
    final FeedbackTicket ticket = FeedbackTicket(
      id: receipt.id,
      ticket: receipt.ticket,
      title: draft.title.trim(),
      category: draft.category,
      createdAt: receipt.createdAt,
      status: FeedbackStatus.open,
      updatedAt: receipt.createdAt,
      seenAt: receipt.createdAt,
      body: draft.body.trim(),
      parentId: parent?.id,
    );
    // 幂等重试拿回的是同一条（同 id）：替换而不是再插一条。
    _tickets = <FeedbackTicket>[
      ticket,
      for (final FeedbackTicket t in _tickets)
        if (t.id != receipt.id) t,
    ];
    try {
      await _persist();
    } on Object catch (e, st) {
      // 回执落盘失败：回执仍在内存清单里（反馈中心看得到），下一次任何落盘都会把它一起写下；
      // 绝不把它报成提交失败。
      ErrorLogService.instance.log('feedback.persist_after_submit', e, st);
      notifyListeners();
    }
    if (onSubmitted case final Future<void> Function() hook) unawaited(hook());
    if (draft.contact.trim().isNotEmpty) {
      try {
        await FeedbackContactStore(
          await _supportRoot(),
        ).write(draft.contact.trim());
      } on Object catch (e, st) {
        ErrorLogService.instance.log('feedback.last_contact_write', e, st);
      }
    }

    int failed = 0;
    final List<Uint8List> shots = draft.screenshots
        .take(FeedbackLimits.screenshots)
        .toList();
    if (shots.isNotEmpty) onStage?.call(FeedbackSubmitStage.screenshots);
    for (int i = 0; i < shots.length; i++) {
      try {
        await client.uploadFeedbackAttachment(
          receipt.id,
          receipt.ticket,
          's$i',
          shots[i],
        );
      } on Object catch (e, st) {
        failed++;
        ErrorLogService.instance.log('feedback.upload_screenshot', e, st);
        await _stash(receipt.id, 's$i', shots[i]);
      }
    }
    if (draft.includeLogs) {
      onStage?.call(FeedbackSubmitStage.logs);
      Uint8List? gz;
      try {
        final Uint8List encoded = await compute(
          _logEncoder,
          _logText(includeDebugLog: draft.includeDebugLog),
        );
        gz = encoded;
        await client.uploadFeedbackAttachment(
          receipt.id,
          receipt.ticket,
          'log',
          encoded,
        );
      } on Object catch (e, st) {
        failed++;
        ErrorLogService.instance.log('feedback.upload_log', e, st);
        if (gz != null) await _stash(receipt.id, 'log', gz);
      }
    }
    if (video != null) {
      onStage?.call(FeedbackSubmitStage.video);
      onVideoProgress?.call(0);
      // 先挪进待传区再传：传失败（网络中断）时文件已经在那里，详情页可以重试。
      final bool stashed = await _stashVideo(receipt.id, video);
      final bool ok =
          stashed &&
          await _uploadPendingVideo(
                ticket,
                onProgress: (double f) => onVideoProgress?.call(f),
              ) ==
              _SlotOutcome.uploaded;
      if (!ok) failed++;
    }
    return FeedbackSubmitResult(ticket, failedAttachments: failed);
  }

  /// 本机转码用的临时目录（`<数据根>/feedback/video_work/<时刻>`，用完即删）。
  Future<Directory> _videoWorkDir() async => Directory(
    p.join(
      (await _supportRoot()).path,
      'feedback',
      'video_work',
      '${DateTime.now().microsecondsSinceEpoch}',
    ),
  ).create(recursive: true);

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.video_work_cleanup', e, st);
    }
  }

  /// 附件没传上去：字节落盘留着，之后可手动补传（[retryPending]）。
  Future<void> _stash(String id, String slot, Uint8List bytes) async {
    try {
      await (await _pendingFor()).put(id, slot, bytes);
      (_pending[id] ??= <String>{}).add(slot);
      notifyListeners();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.stash_attachment', e, st);
    }
  }

  /// 每条反馈一条附件操作链：[retryPending] 与 [addScreenshots] 都读写同一批待传槽位
  /// 和同一个待传目录（「重试上传」与「追加截图」两个按钮可以同时按），排成一队依次跑。
  final Map<String, Future<void>> _attachChains = <String, Future<void>>{};

  /// 反馈 id → 链上排着 / 正在跑的附件操作个数（见 [attachInFlight]）。
  final Map<String, int> _attachBusy = <String, int>{};

  /// 这条反馈有附件操作排着或正在跑（[addScreenshots] / [retryPending] / [addVideo] 的上传段）。
  ///
  /// [pendingSlots] 同时装着「正在传」与「上次传失败」两种槽位（追加截图是先落盘进待传、
  /// 再上传）：只有本值为 false 时，待传槽位才是真的「没传上去」。界面拿它区分「正在上传」
  /// 与「上传失败，重试」——不区分时，追加截图上传的那一两秒里就显示「没上传成功 + 重试」，
  /// 反馈人以为第一下必定失败（#aiRZmYl5zS）。
  bool attachInFlight(String id) => (_attachBusy[id] ?? 0) > 0;

  /// 把 [task] 接到反馈 [id] 的附件操作链末尾；前一个失败不影响后一个。
  Future<T> _serialAttach<T>(String id, Future<T> Function() task) {
    _attachBusy[id] = (_attachBusy[id] ?? 0) + 1;
    notifyListeners();
    final Future<void> previous = _attachChains[id] ?? Future<void>.value();
    final Future<T> result = previous.then<T>((_) => task());
    // 链尾只管「轮到下一个」：结果与异常照常交给调用方 [result]。
    final Future<void> tail = result.then<void>(
      (T _) {},
      onError: (Object _) {},
    );
    _attachChains[id] = tail;
    unawaited(
      tail.then<void>((_) {
        if (identical(_attachChains[id], tail)) _attachChains.remove(id);
        final int left = (_attachBusy[id] ?? 1) - 1;
        if (left > 0) {
          _attachBusy[id] = left;
        } else {
          _attachBusy.remove(id);
        }
        notifyListeners();
      }),
    );
    return result;
  }

  /// 服务端对这次上传的拒绝是不是永久的（再传同样的字节也只会得到同样的结果）。
  ///
  /// 4xx 是「请求本身不被接受」：补传窗口已过（403）、反馈不存在（404）、太大（413）、
  /// 不是图片 / 宽高超限（415）……都丢弃。例外的 4xx 是暂时的：408 请求超时、429 限流、
  /// 409 `conflict`（并发写附件列表时输了，重传就行；`slot_taken` 在客户端已当成功）。
  /// 5xx 与网络异常不归这里管，留着下次再试。
  @visibleForTesting
  static bool isPermanentAttachmentRejection(int status) =>
      status >= 400 &&
      status < 500 &&
      !const <int>{408, 409, 429}.contains(status);

  /// 准备好的视频挪进待传区（槽位 `v0`）。挪不进去返回 false（磁盘满等，原因进日志）。
  Future<bool> _stashVideo(String id, PreparedFeedbackVideo video) async {
    try {
      await (await _pendingFor()).putFile(
        id,
        FeedbackLimits.videoSlot,
        video.file,
        contentType: video.contentType,
      );
      (_pending[id] ??= <String>{}).add(FeedbackLimits.videoSlot);
      notifyListeners();
      return true;
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.stash_video', e, st);
      return false;
    }
  }

  void _setTransfer(String id, FeedbackVideoTransfer? next) {
    final FeedbackVideoTransfer? prev = _transfers[id];
    if (next == null) {
      if (_transfers.remove(id) != null) notifyListeners();
      return;
    }
    // 进度每变 1% 才通知一次：上传回调按块来，几十 MB 是上千次。
    final double? a = prev?.fraction;
    final double? b = next.fraction;
    final bool same =
        prev != null &&
        prev.stage == next.stage &&
        (a == null) == (b == null) &&
        (a == null || ((a * 100).floor() == (b! * 100).floor()));
    _transfers[id] = next;
    if (!same) notifyListeners();
  }

  /// 传待传区里的视频；成功 / 被拒都删掉待传文件。
  Future<_SlotOutcome> _uploadPendingVideo(
    FeedbackTicket t, {
    void Function(double fraction)? onProgress,
  }) async {
    final FeedbackPendingStore store = await _pendingFor();
    const String slot = FeedbackLimits.videoSlot;
    final ({File file, String contentType})? pending = await store.fileOf(
      t.id,
      slot,
    );
    if (pending == null) {
      _pending[t.id]?.remove(slot);
      return _SlotOutcome.dropped;
    }
    _SlotOutcome outcome = _SlotOutcome.failed;
    try {
      final int length = await pending.file.length();
      _setTransfer(
        t.id,
        const FeedbackVideoTransfer(FeedbackVideoStage.uploading, 0),
      );
      await _client().uploadFeedbackVideo(
        t.id,
        t.ticket,
        body: pending.file.openRead(),
        length: length,
        contentType: pending.contentType,
        onProgress: (int sent) {
          final double f = length == 0 ? 1 : sent / length;
          onProgress?.call(f);
          _setTransfer(
            t.id,
            FeedbackVideoTransfer(FeedbackVideoStage.uploading, f),
          );
        },
      );
      outcome = _SlotOutcome.uploaded;
    } on LeaderboardApiException catch (e, st) {
      ErrorLogService.instance.log('feedback.upload_video', e, st);
      if (isPermanentAttachmentRejection(e.status)) {
        outcome = _SlotOutcome.dropped;
      }
    } on ArgumentError catch (e, st) {
      // 待传文件大小越界（被别的程序改过）：再传也一样，丢掉。
      ErrorLogService.instance.log('feedback.upload_video', e, st);
      outcome = _SlotOutcome.dropped;
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.upload_video', e, st);
    } finally {
      _setTransfer(t.id, null);
    }
    if (outcome != _SlotOutcome.failed) {
      await store.remove(t.id, slot);
      _pending[t.id]?.remove(slot);
      if (_pending[t.id]?.isEmpty ?? false) _pending.remove(t.id);
      notifyListeners();
    }
    return outcome;
  }

  /// 把这条反馈所有待传附件再传一遍。服务端同一槽位只收一次（重复传拿到 409
  /// `slot_taken` 已按成功处理）；被服务端永久拒收的（[isPermanentAttachmentRejection]）
  /// 不会再有机会，直接丢弃并计入 [FeedbackRetryResult.dropped]；其余（5xx、网络类）
  /// 错误留着下次再试。与同一条反馈的 [addScreenshots] 串行。
  Future<FeedbackRetryResult> retryPending(String id) =>
      _serialAttach<FeedbackRetryResult>(id, () => _retryPendingNow(id));

  Future<FeedbackRetryResult> _retryPendingNow(String id) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    final FeedbackPendingStore store = await _pendingFor();
    final LeaderboardClient client = _client();
    int uploaded = 0;
    int dropped = 0;
    final List<String> slots = (_pending[id] ?? <String>{}).toList()..sort();
    for (final String slot in slots) {
      if (slot == FeedbackLimits.videoSlot) {
        switch (await _uploadPendingVideo(t)) {
          case _SlotOutcome.uploaded:
            uploaded++;
          case _SlotOutcome.dropped:
            dropped++;
          case _SlotOutcome.failed:
            break;
        }
        continue;
      }
      final Uint8List? bytes = await store.read(id, slot);
      bool done = bytes == null;
      if (bytes != null) {
        try {
          await client.uploadFeedbackAttachment(t.id, t.ticket, slot, bytes);
          uploaded++;
          done = true;
        } on LeaderboardApiException catch (e, st) {
          ErrorLogService.instance.log('feedback.retry_attachment', e, st);
          if (isPermanentAttachmentRejection(e.status)) {
            dropped++;
            done = true;
          }
        } on Object catch (e, st) {
          ErrorLogService.instance.log('feedback.retry_attachment', e, st);
        }
      }
      if (done) {
        await store.remove(id, slot);
        _pending[id]?.remove(slot);
      }
    }
    if (_pending[id]?.isEmpty ?? false) _pending.remove(id);
    notifyListeners();
    return FeedbackRetryResult(
      uploaded: uploaded,
      remaining: _pending[id]?.length ?? 0,
      dropped: dropped,
    );
  }

  /// 给已提交的反馈追加截图：占用 [usedSlots]（服务端已有的附件槽位）和本机待传之外
  /// 的空闲截图槽位，超出空位的丢弃。字节先落盘再传，传失败也留在待传里。与同一条
  /// 反馈的 [retryPending] 串行。
  ///
  /// 已占用的槽位 = [usedSlots] ∪ 调用这一刻的待传槽位 ∪ 排到自己时的待传槽位：前面
  /// 排着的补传会把调用时还在待传的槽位传上去并移出待传清单，它们在服务端已被占用，
  /// 只看排到时的待传清单会把新截图塞进去、被服务端当成 `slot_taken` 静默吞掉。
  Future<FeedbackRetryResult> addScreenshots(
    String id,
    List<Uint8List> shots, {
    required Set<String> usedSlots,
  }) {
    final Set<String> takenAtCall = <String>{...usedSlots, ...pendingSlots(id)};
    return _serialAttach<FeedbackRetryResult>(
      id,
      () => _addScreenshotsNow(id, shots, takenAtCall),
    );
  }

  Future<FeedbackRetryResult> _addScreenshotsNow(
    String id,
    List<Uint8List> shots,
    Set<String> takenAtCall,
  ) async {
    final Set<String> taken = <String>{...takenAtCall, ...pendingSlots(id)};
    final List<String> free = <String>[
      for (int i = 0; i < FeedbackLimits.screenshots; i++)
        if (!taken.contains('s$i')) 's$i',
    ];
    for (int i = 0; i < shots.length && i < free.length; i++) {
      await _stash(id, free[i], shots[i]);
    }
    return _retryPendingNow(id);
  }

  /// 给已提交的反馈追加视频（只有本机回执、补传窗口内、服务端还没有视频时才该调）：
  /// 本机转码 → 挪进待传区 → 上传。转码阶段的「太大 / 不是视频」原样抛给调用方；上传
  /// 失败留在待传区，结果里 `remaining` > 0。
  Future<FeedbackRetryResult> addVideo(String id, File source) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    final Directory work = await _videoWorkDir();
    try {
      _setTransfer(
        id,
        const FeedbackVideoTransfer(FeedbackVideoStage.preparing),
      );
      final PreparedFeedbackVideo video;
      try {
        video = await _prepareVideo(
          source,
          work,
          (double f) => _setTransfer(
            id,
            FeedbackVideoTransfer(FeedbackVideoStage.preparing, f),
          ),
          const FeedbackVideoPrepareOptions(),
        );
      } finally {
        _setTransfer(id, null);
      }
      // 暂存与上传与同一条反馈的 [retryPending] / [addScreenshots] 串行（它们读写同一批
      // 待传槽位与同一个待传目录）；转码在链外，几十秒的转码不该堵住别的附件操作。
      return await _serialAttach<FeedbackRetryResult>(id, () async {
        if (!await _stashVideo(id, video)) {
          throw StateError('could not stage the video for upload');
        }
        return _retryPendingNow(id);
      });
    } finally {
      await _deleteQuietly(work);
    }
  }

  FeedbackTicket? byId(String id) {
    for (final FeedbackTicket t in tickets) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 看详情：顺带刷新本条进度并记为已读。
  Future<FeedbackDetail> detail(String id) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    final FeedbackDetail d;
    try {
      d = await _client().feedbackDetail(t.id, t.ticket);
    } on LeaderboardApiException catch (e) {
      if (e.status == 404) await _replace(t.copyWith(missing: true));
      rethrow;
    }
    await _applyDetail(t, d);
    return d;
  }

  /// 取回自己这条反馈的一张截图（凭本机 ticket；服务端只给截图槽位）。
  Future<Uint8List> screenshot(String id, String slot) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    return _client().feedbackScreenshot(t.id, t.ticket, slot);
  }

  /// 反馈人把自己这条标为已关闭（问题已解决 / 不再需要），返回更新后的详情。
  Future<FeedbackDetail> markDone(String id) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    final FeedbackDetail d = await _client().closeFeedback(t.id, t.ticket);
    await _applyDetail(t, d);
    return d;
  }

  /// 追加说明，返回更新后的详情。
  Future<FeedbackDetail> reply(String id, String body) async {
    final FeedbackTicket? t = byId(id);
    if (t == null) throw StateError('unknown feedback $id');
    final FeedbackDetail d = await _client().addFeedbackMessage(
      t.id,
      t.ticket,
      body.trim(),
    );
    await _applyDetail(t, d);
    return d;
  }

  Future<void> _applyDetail(FeedbackTicket t, FeedbackDetail d) async {
    final int seen = <int>[
      t.seenAt,
      d.summary.devReplyAt ?? 0,
      d.summary.updatedAt,
    ].reduce((int a, int b) => a > b ? a : b);
    await _replace(
      t.mergeSummary(d.summary).copyWith(seenAt: seen, body: d.body),
    );
  }

  Future<void> _replace(FeedbackTicket next) async {
    if (next.viaAccount) {
      _accountTickets = <FeedbackTicket>[
        for (final FeedbackTicket t in _accountTickets)
          t.id == next.id ? next : t,
      ];
      await _persistAccount();
      notifyListeners();
      return;
    }
    _tickets = <FeedbackTicket>[
      for (final FeedbackTicket t in _tickets) t.id == next.id ? next : t,
    ];
    await _persist();
  }

  /// 从本机清单里删掉（服务端记录不受影响；删了就看不到这条的进度了）。账户列表里的
  /// 条目删不掉（下次刷新还会列出来），调用方不该给它们「从本机移除」。
  Future<void> forget(String id) async {
    _pending.remove(id);
    try {
      await (await _pendingFor()).removeAll(id);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.pending_forget', e, st);
    }
    _tickets = <FeedbackTicket>[
      for (final FeedbackTicket t in _tickets)
        if (t.id != id) t,
    ];
    await _persist();
  }

  /// 把另一处数据根（[spoolRoot]，结构同 `<数据根>`）里提交的反馈并进本机清单：回执
  /// 插到最前（同 id 以 spool 里的为准——那是刚提交的），没传上去的截图 / 日志挪进本机
  /// 待传区，然后删掉 [spoolRoot]。返回并入的条数。
  ///
  /// 用于启动即闪退时的闪退报告（crash_report.dart）：那时数据库还没打开、数据根未解析，
  /// 提交先落在错误日志目录下，初始化完成后由这里接手，反馈中心照常看得到进度、能重试。
  Future<int> adoptSpool(Directory spoolRoot) async {
    if (!spoolRoot.existsSync()) return 0;
    await load();
    final List<FeedbackTicket> adopted = await FeedbackTicketStore(
      spoolRoot,
    ).read();
    if (adopted.isNotEmpty) {
      final Set<String> ids = <String>{
        for (final FeedbackTicket t in adopted) t.id,
      };
      _tickets = <FeedbackTicket>[
        ...adopted,
        for (final FeedbackTicket t in _tickets)
          if (!ids.contains(t.id)) t,
      ];
      _accountTickets = _withoutLocal(_accountTickets);
      await _persist();
    }
    final FeedbackPendingStore from = FeedbackPendingStore(spoolRoot);
    final FeedbackPendingStore to = await _pendingFor();
    final Map<String, Set<String>> pending = await from.scan();
    for (final MapEntry<String, Set<String>> e in pending.entries) {
      for (final String slot in e.value) {
        final Uint8List? bytes = await from.read(e.key, slot);
        if (bytes == null) continue;
        await to.put(e.key, slot, bytes);
        (_pending[e.key] ??= <String>{}).add(slot);
      }
    }
    await spoolRoot.delete(recursive: true);
    notifyListeners();
    return adopted.length;
  }
}

/// 一个附件槽位这次上传的结局。
enum _SlotOutcome { uploaded, failed, dropped }

/// 全应用一份（反馈属于这台设备，与 Profile 无关）。客户端每次用时现取：已登录排行榜
/// 账户就带签名，换 Profile / 登录登出后自然跟着变。
final ChangeNotifierProvider<FeedbackService> feedbackServiceProvider =
    ChangeNotifierProvider<FeedbackService>((ref) {
      final AppModel app = ref.read(appProvider);
      final FeedbackService service = FeedbackService(
        supportRoot: () async => app.databaseDirectory,
        client: () => ref.read(leaderboardServiceProvider).feedbackClient(),
        installId: () => usageStatsInstallIdForFeedback(app.prefsRepo),
        // 用时现取（不在建 provider 时读）：提醒编排反过来依赖本服务。
        onSubmitted: () async {
          final FeedbackReplyAlerts alerts = ref.read(
            feedbackReplyAlertsProvider,
          );
          await alerts.syncSchedule();
          await alerts.requestPermissionAfterSubmit();
        },
      );
      unawaited(
        service.load().catchError((Object e, StackTrace st) {
          ErrorLogService.instance.log('FeedbackService.load', e, st);
        }),
      );
      return service;
    });
