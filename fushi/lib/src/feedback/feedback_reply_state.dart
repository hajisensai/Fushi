// 「开发者回复了我的反馈」的提醒状态——前台 snackbar、桌面运行中的系统通知、移动端
// 后台任务（WorkManager / BGTaskScheduler）三条路径共用的**唯一**持久化水位。
//
// 文件 `<数据根>/feedback/poll_state.json`，与 tickets.json 同目录、同样与 Profile 无关。
// 字段：
// - lastRefreshAt：主 isolate 上次**成功**刷新进度的时刻（节流用，失败不记）；
// - notifiedReplyAt：已经提醒过的最新开发者回复时刻。三条路径谁先提醒谁推进它，
//   后到的看到回复不比它新就不再提醒——同一条回复系统通知和 snackbar 不会各来一次；
// - serverUrl / alertTitle：主 isolate 每次同步后台调度时写下的「后台运行环境」：
//   后台 isolate 拉不起 AppModel（读不到 Drift 偏好、排行榜账户的服务器覆盖、slang
//   的当前语言），这两样只能由主 isolate 交给它；
// - permissionAsked：首次提交反馈后已经向系统申请过一次通知权限，之后不再追着要。
// - pushToken / pushRegistered / pushDelivering：iOS 远程推送（feedback_push.dart）的
//   登记状态——当前 APNs 令牌、已用它登记过的反馈 id、服务端登记时是否答复「会推送」。
//   被推送覆盖的反馈（[FeedbackReplyState.pushCovered]）的新回复由服务端推送提醒，
//   前台 snackbar 与后台本地通知都不再提醒它，只推进水位——同一条回复不会提醒两次。
//
// **后台 isolate 只写本文件，绝不写 tickets.json**：主 isolate 随时可能在写清单
// （提交 / 看详情 / 标已读），两个 isolate 各自读改写同一份清单会丢更新。后台只读清单、
// 只推进水位；清单（红点）留给主 isolate 下次前台刷新时更新。
//
// 本文件是纯 Dart（不 import Flutter / 插件 / AppModel），后台 isolate 与单测都直接用。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:path/path.dart' as p;

/// 两次进度刷新之间的最小间隔（前台节流 = 后台周期 = 桌面定时器周期）。
/// Android WorkManager 的周期任务下限也是 15 分钟。
const Duration kFeedbackReplyPollInterval = Duration(minutes: 15);

/// 后台任务的唯一名（Android unique work 名 = iOS BGTaskScheduler identifier，后者必须
/// 同时登记在 `ios/Runner/Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 与
/// `AppDelegate.swift`）。**发布后不可改**：改了旧任务成孤儿，iOS 上还会因 identifier
/// 未登记而崩。
const String kFeedbackReplyTaskName = 'app.fushi.feedback-reply-check';

/// 系统通知的载荷前缀：点通知时据此认出是反馈（而不是更新中心的 JSON 载荷）。
const String _kPayloadPrefix = 'fushi-feedback:';

/// 反馈回复通知的载荷：`fushi-feedback:<反馈 id>`。
String encodeFeedbackNotificationPayload(String feedbackId) =>
    '$_kPayloadPrefix$feedbackId';

/// 认出反馈回复通知并取回反馈 id；不是（更新中心等别的通知 / 空 / 坏）返回 null。
String? decodeFeedbackNotificationPayload(String? payload) {
  if (payload == null || !payload.startsWith(_kPayloadPrefix)) return null;
  final String id = payload.substring(_kPayloadPrefix.length);
  return id.isEmpty ? null : id;
}

/// 反馈回复通知的平台通知 id：按反馈 id 派生、稳定（同一条反馈又有新回复 = 替换而
/// 不是叠一条）。落在 2^30 以上的区间，避开更新中心按域派生的那批 id。
int feedbackNotificationId(String feedbackId) {
  int h = 0;
  for (final int c in feedbackId.codeUnits) {
    h = (h * 31 + c) & 0x3fffffff;
  }
  return 0x40000000 | h;
}

/// 一条需要提醒的新回复（通知正文用标题，点击用 id）。
class FeedbackReplyAlert {
  const FeedbackReplyAlert({
    required this.id,
    required this.title,
    required this.devReplyAt,
  });

  final String id;
  final String title;
  final int devReplyAt;
}

/// 在「开发者最近回复时刻」里挑出比用户看过的更新、且比已提醒水位更新的那些。
/// 三条路径同一判据（[FeedbackTicket.hasUnseenReply] 再加水位）。
List<FeedbackReplyAlert> selectNewReplies(
  Iterable<FeedbackReplyAlert> candidates, {
  required Map<String, int> seenAt,
  required int notifiedReplyAt,
}) => <FeedbackReplyAlert>[
  for (final FeedbackReplyAlert c in candidates)
    if (c.devReplyAt > (seenAt[c.id] ?? 0) && c.devReplyAt > notifiedReplyAt) c,
];

/// 从 [selectNewReplies] 的结果里去掉由远程推送提醒的反馈（[pushCovered]）：它们已经由
/// 服务端推送提醒过，本机路径再提醒就是重复。水位仍按完整结果推进（调用方负责）。
List<FeedbackReplyAlert> withoutPushCovered(
  List<FeedbackReplyAlert> fresh,
  Set<String> pushCovered,
) => pushCovered.isEmpty
    ? fresh
    : <FeedbackReplyAlert>[
        for (final FeedbackReplyAlert a in fresh)
          if (!pushCovered.contains(a.id)) a,
      ];

class FeedbackReplyState {
  const FeedbackReplyState({
    this.lastRefreshAt = 0,
    this.notifiedReplyAt = 0,
    this.serverUrl,
    this.alertTitle,
    this.permissionAsked = false,
    this.pushToken,
    this.pushRegistered = const <String>[],
    this.pushDelivering = false,
  });

  factory FeedbackReplyState.fromJson(Map<String, dynamic> j) =>
      FeedbackReplyState(
        lastRefreshAt: (j['lastRefreshAt'] as num?)?.toInt() ?? 0,
        notifiedReplyAt: (j['notifiedReplyAt'] as num?)?.toInt() ?? 0,
        serverUrl: j['serverUrl'] as String?,
        alertTitle: j['alertTitle'] as String?,
        permissionAsked: j['permissionAsked'] == true,
        pushToken: j['pushToken'] as String?,
        pushRegistered: <String>[
          for (final Object? e
              in (j['pushRegistered'] as List<Object?>?) ?? const <Object?>[])
            if (e is String) e,
        ],
        pushDelivering: j['pushDelivering'] == true,
      );

  final int lastRefreshAt;
  final int notifiedReplyAt;
  final String? serverUrl;
  final String? alertTitle;
  final bool permissionAsked;

  /// 当前登记用的 APNs 令牌（十六进制）；null = 没有远程推送。
  final String? pushToken;

  /// 已用 [pushToken] 登记过的反馈 id。
  final List<String> pushRegistered;

  /// 最近一次登记时服务端答复「会推送」（APNs 已配置）。
  final bool pushDelivering;

  /// 新回复由服务端远程推送提醒的反馈：登记过 **且** 服务端确认会推送。
  Set<String> get pushCovered => pushToken != null && pushDelivering
      ? pushRegistered.toSet()
      : const <String>{};

  /// 整组替换远程推送登记状态（[token] 为 null = 清空）。
  FeedbackReplyState withPush({
    required String? token,
    required List<String> registered,
    required bool delivering,
  }) => FeedbackReplyState(
    lastRefreshAt: lastRefreshAt,
    notifiedReplyAt: notifiedReplyAt,
    serverUrl: serverUrl,
    alertTitle: alertTitle,
    permissionAsked: permissionAsked,
    pushToken: token,
    pushRegistered: token == null ? const <String>[] : registered,
    pushDelivering: token != null && delivering,
  );

  FeedbackReplyState copyWith({
    int? lastRefreshAt,
    int? notifiedReplyAt,
    String? serverUrl,
    String? alertTitle,
    bool? permissionAsked,
  }) => FeedbackReplyState(
    lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
    notifiedReplyAt: notifiedReplyAt ?? this.notifiedReplyAt,
    serverUrl: serverUrl ?? this.serverUrl,
    alertTitle: alertTitle ?? this.alertTitle,
    permissionAsked: permissionAsked ?? this.permissionAsked,
    pushToken: pushToken,
    pushRegistered: pushRegistered,
    pushDelivering: pushDelivering,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lastRefreshAt': lastRefreshAt,
    'notifiedReplyAt': notifiedReplyAt,
    if (serverUrl != null) 'serverUrl': serverUrl,
    if (alertTitle != null) 'alertTitle': alertTitle,
    if (permissionAsked) 'permissionAsked': true,
    if (pushToken != null) 'pushToken': pushToken,
    if (pushRegistered.isNotEmpty) 'pushRegistered': pushRegistered,
    if (pushDelivering) 'pushDelivering': true,
  };
}

/// [FeedbackReplyState] 的落盘。读失败（不存在 / 损坏）按初始状态处理；写走「临时文件 +
/// rename」，主 isolate 与后台 isolate 同时写也只会是某一份完整内容，不会读到半截。
class FeedbackReplyStateStore {
  FeedbackReplyStateStore(this.supportRoot);

  final Directory supportRoot;

  File get file =>
      File(p.join(supportRoot.path, 'feedback', 'poll_state.json'));

  Future<FeedbackReplyState> read() async {
    try {
      final File f = file;
      if (!f.existsSync()) return const FeedbackReplyState();
      return FeedbackReplyState.fromJson(
        (jsonDecode(await f.readAsString()) as Map<Object?, Object?>)
            .cast<String, dynamic>(),
      );
    } on Object {
      return const FeedbackReplyState();
    }
  }

  /// 读改写：[change] 拿当前状态返回新状态。临时文件名带随机后缀——两个 isolate
  /// 同时写时各写各的临时文件，不会互相截断。
  Future<FeedbackReplyState> update(
    FeedbackReplyState Function(FeedbackReplyState current) change,
  ) async {
    final FeedbackReplyState next = change(await read());
    final File f = file;
    await f.parent.create(recursive: true);
    final File tmp = File(
      '${f.path}.${math.Random().nextInt(1 << 32).toRadixString(16)}.tmp',
    );
    await tmp.writeAsString(jsonEncode(next.toJson()), flush: true);
    await tmp.rename(f.path);
    return next;
  }
}

/// 后台 isolate 的一次检查（Android WorkManager / iOS BGAppRefresh 调它）：
///
/// 1. 读本机清单；没有未结案（非 closed、没标 missing）的反馈 → 不发请求；
/// 2. 主 isolate [kFeedbackReplyPollInterval] 内刚刷新过 → 交给它，不发请求；
/// 3. 按批问进度（与 `FeedbackService.refresh` 同一个接口、同一个服务器——服务器取主
///    isolate 写下的 `serverUrl`，没写过就用 [defaultBaseUrl]）；
/// 4. 挑出新回复（[selectNewReplies]），有就推进水位并返回，调用方据此发通知。
///
/// 网络错误原样抛给调用方（后台任务记一次失败，下个周期再来）。**不写 tickets.json**，
/// 服务端查不到的条目也不标 missing——那是主 isolate 的事（见文件头）。
Future<List<FeedbackReplyAlert>> pollFeedbackRepliesInBackground({
  required Directory supportRoot,
  required LeaderboardClient Function(Uri baseUrl) client,
  required Uri defaultBaseUrl,
  required int nowMs,
  Duration minInterval = kFeedbackReplyPollInterval,
}) async {
  final List<FeedbackTicket> active = <FeedbackTicket>[
    for (final FeedbackTicket t in await FeedbackTicketStore(
      supportRoot,
    ).read())
      if (!t.status.isClosed && !t.missing) t,
  ];
  if (active.isEmpty) return const <FeedbackReplyAlert>[];

  final FeedbackReplyStateStore store = FeedbackReplyStateStore(supportRoot);
  final FeedbackReplyState state = await store.read();
  final bool recentlyRefreshed =
      state.lastRefreshAt <= nowMs &&
      nowMs - state.lastRefreshAt < minInterval.inMilliseconds;
  if (recentlyRefreshed) return const <FeedbackReplyAlert>[];

  final String? server = state.serverUrl;
  final LeaderboardClient c = client(
    server == null ? defaultBaseUrl : Uri.parse(server),
  );
  final List<FeedbackReplyAlert> candidates = <FeedbackReplyAlert>[];
  for (int i = 0; i < active.length; i += FeedbackLimits.statusBatch) {
    final List<FeedbackTicket> batch = active.sublist(
      i,
      math.min(i + FeedbackLimits.statusBatch, active.length),
    );
    final List<FeedbackSummary> got = await c.feedbackStatuses(
      <({String id, String ticket})>[
        for (final FeedbackTicket t in batch) (id: t.id, ticket: t.ticket),
      ],
    );
    for (final FeedbackSummary s in got) {
      final int? at = s.devReplyAt;
      if (at != null) {
        candidates.add(
          FeedbackReplyAlert(id: s.id, title: s.title, devReplyAt: at),
        );
      }
    }
  }

  final List<FeedbackReplyAlert> fresh = selectNewReplies(
    candidates,
    seenAt: <String, int>{
      for (final FeedbackTicket t in active) t.id: t.seenAt,
    },
    notifiedReplyAt: state.notifiedReplyAt,
  );
  if (fresh.isEmpty) return fresh;
  // 水位按全部新回复推进（含远程推送已提醒的），通知只发没被推送覆盖的。
  final int newest = fresh
      .map((FeedbackReplyAlert a) => a.devReplyAt)
      .reduce(math.max);
  await store.update(
    (FeedbackReplyState s) =>
        s.copyWith(notifiedReplyAt: math.max(newest, s.notifiedReplyAt)),
  );
  return withoutPushCovered(fresh, state.pushCovered);
}
