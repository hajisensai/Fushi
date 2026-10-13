// 开发者回复 / 改状态后的「被动发现」（主 isolate）：启动、回到前台、桌面运行中定时，
// 若本机有未结案反馈，就（节流地）刷新一次进度，告诉调用方有哪些**还没提醒过**的新回复。
//
// 之前唯一调用 FeedbackService.refresh() 的是打开反馈中心——用户不进去，首页红点
// （只读本机缓存的 unseenCount）永远不会亮，开发者的回复等于石沉大海。
//
// 规则：
// - 没有未结案（非 closed 状态、服务端没标 missing）的反馈 = 完全不发请求；
// - 距上次**成功**刷新不足 [minInterval] 不发请求（时间戳落盘，重启不重置）；刷新失败
//   不记时间戳，下次还会再试；
// - 同一条回复只提醒一次：提醒水位落盘在 [FeedbackReplyStateStore]，与移动端后台任务
//   共用——后台已经发过系统通知的回复，回到前台不会再弹 snackbar，反之亦然。
// 怎么提醒（snackbar / 系统通知）由调用方决定，见 feedback_reply_alerts.dart。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一次检查的结论。
class FeedbackReplyCheck {
  const FeedbackReplyCheck({
    this.unseen = 0,
    this.fresh = const <FeedbackReplyAlert>[],
  });

  static const FeedbackReplyCheck none = FeedbackReplyCheck();

  /// 有新进展、用户还没看过的反馈总条数（应用内提示的数字，与红点同口径）。
  final int unseen;

  /// 这次才出现、还没提醒过的新回复（已推进水位）；空 = 不提醒。
  final List<FeedbackReplyAlert> fresh;

  bool get announce => fresh.isNotEmpty;
}

class FeedbackReplyNotifier {
  FeedbackReplyNotifier({
    required this.service,
    required Future<Directory> Function() supportRoot,
    int Function()? nowMs,
    this.minInterval = kFeedbackReplyPollInterval,
  }) : _supportRoot = supportRoot,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FeedbackService service;
  final Future<Directory> Function() _supportRoot;
  final int Function() _nowMs;
  final Duration minInterval;

  bool _running = false;

  /// 提醒状态（水位 / 节流 / 后台运行环境）的落盘。
  Future<FeedbackReplyStateStore> stateStore() async =>
      FeedbackReplyStateStore(await _supportRoot());

  /// 「我的反馈」（本机回执 + 账户条目）里有没有还在等开发者处理的（决定前台 / 桌面
  /// 要不要刷新）。
  Future<bool> hasActiveTickets() async {
    await service.load();
    return service.tickets.any(feedbackAwaitingReply);
  }

  /// 有没有**后台 isolate 查得了**的未结案反馈（决定要不要排后台检查）。与后台检查本身
  /// 同一个判据 [feedbackBackgroundPollable]：只有账户条目时排了任务也只会被系统白拉起、
  /// 永远发不出通知。
  Future<bool> hasBackgroundPollableTickets() async {
    await service.load();
    return service.tickets.any(feedbackBackgroundPollable);
  }

  /// 该刷新就刷新一次，返回要提醒的新回复（见 [FeedbackReplyCheck]）。
  /// [force]：不看节流（前台收到了远程推送——服务端刚说有新进展，立刻刷新红点）。
  Future<FeedbackReplyCheck> check({bool force = false}) async {
    if (_running) return FeedbackReplyCheck.none;
    _running = true;
    try {
      if (!await hasActiveTickets()) return FeedbackReplyCheck.none;

      final FeedbackReplyStateStore store = await stateStore();
      final FeedbackReplyState state = await store.read();
      final int now = _nowMs();
      // 时钟被往回拨时（last > now）不能被永久节流住。
      final bool throttled =
          !force &&
          state.lastRefreshAt <= now &&
          now - state.lastRefreshAt < minInterval.inMilliseconds;
      if (throttled) return FeedbackReplyCheck.none;

      try {
        await service.refresh();
      } on Object catch (e, st) {
        ErrorLogService.instance.log('feedback.reply_check', e, st);
        return FeedbackReplyCheck.none;
      }

      final List<FeedbackTicket> unseen = service.tickets
          .where((FeedbackTicket t) => t.hasUnseenReply)
          .toList();
      // 判据在锁内现读水位：刷新的那几秒里后台 isolate 可能已经提醒过同一条。
      List<FeedbackReplyAlert> fresh = const <FeedbackReplyAlert>[];
      Set<String> pushCovered = const <String>{};
      await store.update((FeedbackReplyState s) {
        pushCovered = s.pushCovered;
        fresh = selectNewReplies(
          <FeedbackReplyAlert>[
            for (final FeedbackTicket t in unseen)
              FeedbackReplyAlert(
                id: t.id,
                title: t.title,
                devReplyAt: t.devReplyAt!,
              ),
          ],
          seenAt: <String, int>{
            for (final FeedbackTicket t in unseen) t.id: t.seenAt,
          },
          state: s,
        );
        return s.withNotified(fresh).copyWith(lastRefreshAt: now);
      });
      // 由远程推送提醒的反馈（iOS，feedback_push.dart）已经弹过系统通知：水位照推，
      // 应用内提示不再重复。
      return FeedbackReplyCheck(
        unseen: unseen.length,
        fresh: withoutPushCovered(fresh, pushCovered),
      );
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.reply_check', e, st);
      return FeedbackReplyCheck.none;
    } finally {
      _running = false;
    }
  }
}

final Provider<FeedbackReplyNotifier> feedbackReplyNotifierProvider =
    Provider<FeedbackReplyNotifier>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      return FeedbackReplyNotifier(
        service: ref.read(feedbackServiceProvider),
        supportRoot: () async => app.databaseDirectory,
      );
    });
