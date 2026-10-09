// 反馈：提交（正文 + 设备信息 + 压缩日志 + 截图）与本机提交记录的进度跟踪。
//
// 服务端是 fushi.moe 的账户服务（services/leaderboard，路由见 src/feedback.js）。
// 反馈不要求账户：提交拿到一次性回执（ticket）立刻落盘（FeedbackTicketStore），之后凭它
// 查进度、追加说明。已登录排行榜账户时默认带签名提交，开发者那边能看到是谁。
// 网络请求只在用户打开反馈中心 / 提交 / 看详情时发出，不在后台轮询。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';

/// 用户在提交页填写 / 勾选的内容。
class FeedbackDraft {
  const FeedbackDraft({
    required this.category,
    required this.title,
    required this.body,
    this.contact = '',
    this.includeLogs = true,
    this.includeDeviceInfo = true,
    this.linkAccount = true,
    this.screenshots = const <Uint8List>[],
  });

  final FeedbackCategory category;
  final String title;
  final String body;
  final String contact;
  final bool includeLogs;
  final bool includeDeviceInfo;

  /// 已登录排行榜账户时是否关联账户提交（开发者能看到昵称）。
  final bool linkAccount;

  /// PNG / JPEG / WebP 字节，最多 [FeedbackLimits.screenshots] 张。
  final List<Uint8List> screenshots;
}

/// 提交进行到哪一步（提交页的进度文案）。
enum FeedbackSubmitStage { sending, screenshots, logs }

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
    String Function()? logText,
    Uint8List Function(String log)? logEncoder,
  }) : _supportRoot = supportRoot,
       _client = client,
       _meta = meta ?? collectFeedbackMeta,
       _logText = logText ?? collectFeedbackLogText,
       _logEncoder = logEncoder ?? buildFeedbackLogGzip;

  final Future<Directory> Function() _supportRoot;
  final LeaderboardClient Function() _client;
  final Future<Map<String, Object?>> Function() _meta;
  final String Function() _logText;
  final Uint8List Function(String log) _logEncoder;

  FeedbackTicketStore? _store;
  List<FeedbackTicket> _tickets = <FeedbackTicket>[];
  bool _loaded = false;
  bool _refreshing = false;
  Future<void>? _loading;

  /// 本机提交过的反馈（新的在前）。
  List<FeedbackTicket> get tickets =>
      List<FeedbackTicket>.unmodifiable(_tickets);

  bool get loaded => _loaded;
  bool get refreshing => _refreshing;

  /// 有开发者新进展、用户还没看过的条数（入口红点）。
  int get unseenCount =>
      _tickets.where((FeedbackTicket t) => t.hasUnseenReply).length;

  Future<FeedbackTicketStore> _storeFor() async =>
      _store ??= FeedbackTicketStore(await _supportRoot());

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    _tickets = await (await _storeFor()).read();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    await (await _storeFor()).write(_tickets);
    notifyListeners();
  }

  /// 拉全部记录的最新进度（每批 ≤ 50）。查不到的条目标 missing（保留，由用户删）。
  /// 网络错误原样抛给调用方（反馈中心显示「刷新失败」）。
  Future<void> refresh() async {
    await load();
    if (_tickets.isEmpty || _refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
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
      _tickets = <FeedbackTicket>[
        for (final FeedbackTicket t in _tickets)
          if (fresh[t.id] case final FeedbackSummary s)
            t.mergeSummary(s)
          else
            t.copyWith(missing: true),
      ];
      await _persist();
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  /// 提交反馈：先发正文（拿回执并立刻落盘），再逐个补传截图与日志。附件失败不影响
  /// 反馈本身，计入 [FeedbackSubmitResult.failedAttachments]。正文提交失败原样抛出。
  Future<FeedbackSubmitResult> submit(
    FeedbackDraft draft, {
    void Function(FeedbackSubmitStage stage)? onStage,
  }) async {
    await load();
    final LeaderboardClient client = _client();
    onStage?.call(FeedbackSubmitStage.sending);
    final Map<String, Object?> meta = draft.includeDeviceInfo
        ? await _meta()
        : const <String, Object?>{};
    final FeedbackReceipt receipt = await client.submitFeedback(
      category: draft.category,
      title: draft.title.trim(),
      body: draft.body.trim(),
      contact: draft.contact.trim(),
      meta: <String, Object?>{
        ...meta,
        'logs_attached': draft.includeLogs,
        'screenshots': draft.screenshots.length,
      },
      linkAccount: draft.linkAccount,
    );
    final FeedbackTicket ticket = FeedbackTicket(
      id: receipt.id,
      ticket: receipt.ticket,
      title: draft.title.trim(),
      category: draft.category,
      createdAt: receipt.createdAt,
      status: FeedbackStatus.open,
      updatedAt: receipt.createdAt,
      seenAt: receipt.createdAt,
    );
    _tickets = <FeedbackTicket>[ticket, ..._tickets];
    await _persist();

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
      }
    }
    if (draft.includeLogs) {
      onStage?.call(FeedbackSubmitStage.logs);
      try {
        final Uint8List gz = await compute(_logEncoder, _logText());
        await client.uploadFeedbackAttachment(
          receipt.id,
          receipt.ticket,
          'log',
          gz,
        );
      } on Object catch (e, st) {
        failed++;
        ErrorLogService.instance.log('feedback.upload_log', e, st);
      }
    }
    return FeedbackSubmitResult(ticket, failedAttachments: failed);
  }

  FeedbackTicket? byId(String id) {
    for (final FeedbackTicket t in _tickets) {
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
    await _replace(t.mergeSummary(d.summary).copyWith(seenAt: seen));
  }

  Future<void> _replace(FeedbackTicket next) async {
    _tickets = <FeedbackTicket>[
      for (final FeedbackTicket t in _tickets) t.id == next.id ? next : t,
    ];
    await _persist();
  }

  /// 从本机清单里删掉（服务端记录不受影响；删了就看不到这条的进度了）。
  Future<void> forget(String id) async {
    _tickets = <FeedbackTicket>[
      for (final FeedbackTicket t in _tickets)
        if (t.id != id) t,
    ];
    await _persist();
  }
}

/// 全应用一份（反馈属于这台设备，与 Profile 无关）。客户端每次用时现取：已登录排行榜
/// 账户就带签名，换 Profile / 登录登出后自然跟着变。
final ChangeNotifierProvider<FeedbackService> feedbackServiceProvider =
    ChangeNotifierProvider<FeedbackService>((ref) {
      final AppModel app = ref.read(appProvider);
      final FeedbackService service = FeedbackService(
        supportRoot: () async => app.databaseDirectory,
        client: () => ref.read(leaderboardServiceProvider).feedbackClient(),
      );
      unawaited(
        service.load().catchError((Object e, StackTrace st) {
          ErrorLogService.instance.log('FeedbackService.load', e, st);
        }),
      );
      return service;
    });
