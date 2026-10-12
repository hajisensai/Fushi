// 开发者回复 / 改状态后的「被动发现」：启动与回到前台时，若本机有未结案反馈，就（节流地）
// 刷新一次进度，并在出现新进展时告诉调用方提示几条。
//
// 之前唯一调用 FeedbackService.refresh() 的是打开反馈中心——用户不进去，首页红点
// （只读本机缓存的 unseenCount）永远不会亮，开发者的回复等于石沉大海。
//
// 规则：
// - 没有未结案（非 closed 状态、服务端没标 missing）的反馈 = 完全不发请求；
// - 距上次**成功**刷新不足 [minInterval] 不发请求（时间戳落盘，重启不重置）；刷新失败
//   不记时间戳，下次前台还会再试；
// - 同一批新回复只提示一次：落盘记下已提示过的最新开发者回复时刻，只有出现更新的回复才再提示。
// 不做系统推送（没有推送基础设施）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

class FeedbackReplyNotifier {
  FeedbackReplyNotifier({
    required this.service,
    required Future<Directory> Function() supportRoot,
    int Function()? nowMs,
    this.minInterval = const Duration(minutes: 15),
  }) : _supportRoot = supportRoot,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FeedbackService service;
  final Future<Directory> Function() _supportRoot;
  final int Function() _nowMs;
  final Duration minInterval;

  bool _running = false;

  Future<File> _stateFile() async =>
      File(p.join((await _supportRoot()).path, 'feedback', 'poll_state.json'));

  Future<({int lastRefreshAt, int notifiedReplyAt})> _readState() async {
    try {
      final File f = await _stateFile();
      if (!f.existsSync()) return (lastRefreshAt: 0, notifiedReplyAt: 0);
      final Map<String, dynamic> j =
          (jsonDecode(await f.readAsString()) as Map<Object?, Object?>)
              .cast<String, dynamic>();
      return (
        lastRefreshAt: (j['lastRefreshAt'] as num?)?.toInt() ?? 0,
        notifiedReplyAt: (j['notifiedReplyAt'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return (lastRefreshAt: 0, notifiedReplyAt: 0);
    }
  }

  Future<void> _writeState(int lastRefreshAt, int notifiedReplyAt) async {
    final File f = await _stateFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode(<String, int>{
        'lastRefreshAt': lastRefreshAt,
        'notifiedReplyAt': notifiedReplyAt,
      }),
      flush: true,
    );
  }

  /// 该刷新就刷新一次；返回需要提示用户的「有新进展的反馈条数」（0 = 不提示）。
  Future<int> check() async {
    if (_running) return 0;
    _running = true;
    try {
      await service.load();
      final bool hasActive = service.tickets.any(
        (FeedbackTicket t) => !t.status.isClosed && !t.missing,
      );
      if (!hasActive) return 0;

      final ({int lastRefreshAt, int notifiedReplyAt}) state =
          await _readState();
      final int now = _nowMs();
      // 时钟被往回拨时（last > now）不能被永久节流住。
      final bool throttled =
          state.lastRefreshAt <= now &&
          now - state.lastRefreshAt < minInterval.inMilliseconds;
      if (throttled) return 0;

      try {
        await service.refresh();
      } on Object catch (e, st) {
        ErrorLogService.instance.log('feedback.reply_check', e, st);
        return 0;
      }

      final List<FeedbackTicket> unseen = service.tickets
          .where((FeedbackTicket t) => t.hasUnseenReply)
          .toList();
      int newest = state.notifiedReplyAt;
      for (final FeedbackTicket t in unseen) {
        if (t.devReplyAt! > newest) newest = t.devReplyAt!;
      }
      final bool announce = unseen.isNotEmpty && newest > state.notifiedReplyAt;
      await _writeState(now, newest);
      return announce ? unseen.length : 0;
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.reply_check', e, st);
      return 0;
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
