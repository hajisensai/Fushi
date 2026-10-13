// 「开发者回复了我的反馈」的提醒状态——前台 snackbar、桌面运行中的系统通知、移动端
// 后台任务（WorkManager / BGTaskScheduler）三条路径共用的**唯一**持久化水位。
//
// 文件 `<数据根>/feedback/poll_state.json`，与 tickets.json 同目录、同样与 Profile 无关。
// 字段：
// - lastRefreshAt：主 isolate 上次**成功**刷新进度的时刻（节流用，失败不记）；
// - notified：反馈 id → 已经提醒过的该条最新开发者回复时刻。三条路径谁先提醒谁推进
//   那一条，后到的看到回复不比它新就不再提醒——同一条回复系统通知和 snackbar 不会各来
//   一次。**按条记**：后台只查本机回执、主 isolate 还查账户条目，两路发现时机不同；
//   全局只记一个「最新时刻」时，后发现但回复时刻更早的那条会被永远吞掉；
// - notifiedReplyAt：旧版的全局水位（只读不再推进）。升级前已经提醒过的回复都不晚于它，
//   [notified] 里没有的条目以它为下限，升级后旧回复不会重新弹一遍；
// - serverUrl / alertTitle：主 isolate 每次同步后台调度时写下的「后台运行环境」：
//   后台 isolate 拉不起 AppModel（读不到 Drift 偏好、排行榜账户的服务器覆盖、slang
//   的当前语言），这两样只能由主 isolate 交给它；
// - permissionAsked：首次提交反馈后已经向系统申请过一次通知权限，之后不再追着要。
// - pushToken / pushRegistrations：iOS 远程推送（feedback_push.dart）的登记状态——当前
//   APNs 令牌，和反馈 id → 最近一次**成功**登记的结果（服务端是否答复「会推送」、登记
//   时刻）。被推送覆盖的反馈（[FeedbackReplyState.pushCovered]）的新回复由服务端推送
//   提醒，前台 snackbar 与后台本地通知都不再提醒它，只推进水位——同一条回复不会提醒两次。
//
// 两个 isolate 都会改本文件：所有写入都经 [FeedbackReplyStateStore.update]，在跨 isolate
// 的排他锁里「读最新 → 改自己负责的字段 → 写回」，谁也不会把对方刚写的字段整份盖掉。
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

/// 这条反馈还在等开发者处理（非结案状态、服务端没标 missing）。
bool feedbackAwaitingReply(FeedbackTicket t) =>
    !t.status.isClosed && !t.missing;

/// 后台 isolate 能替这条反馈检查新回复：只有本机回执（tickets.json，带 ticket）。
/// 凭账户列出的条目（[FeedbackTicket.viaAccount]）要账户签名，后台 isolate 拿不到账户
/// 钥匙，只能由主 isolate 在前台 / 桌面运行中检查。后台检查的范围与「要不要排后台
/// 任务」用的是这同一个判据，不会为后台查不了的条目白拉起 app。
bool feedbackBackgroundPollable(FeedbackTicket t) =>
    !t.viaAccount && feedbackAwaitingReply(t);

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

/// 在「开发者最近回复时刻」里挑出比用户看过的更新、且比**该条**已提醒水位
/// （[FeedbackReplyState.notifiedAt]）更新的那些。三条路径同一判据
/// （[FeedbackTicket.hasUnseenReply] 再加水位）。
List<FeedbackReplyAlert> selectNewReplies(
  Iterable<FeedbackReplyAlert> candidates, {
  required Map<String, int> seenAt,
  required FeedbackReplyState state,
}) => <FeedbackReplyAlert>[
  for (final FeedbackReplyAlert c in candidates)
    if (c.devReplyAt > (seenAt[c.id] ?? 0) &&
        c.devReplyAt > state.notifiedAt(c.id))
      c,
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

/// 一条反馈最近一次**成功**的远程推送登记（服务端 PUT 返回 200）。
class FeedbackPushRegistration {
  const FeedbackPushRegistration({
    required this.delivering,
    required this.confirmedAt,
  });

  factory FeedbackPushRegistration.fromJson(Map<String, dynamic> j) =>
      FeedbackPushRegistration(
        delivering: j['delivering'] == true,
        confirmedAt: (j['at'] as num?)?.toInt() ?? 0,
      );

  /// 服务端答复此刻真的会推送（APNs 已配置）。
  final bool delivering;

  /// 登记成功的时刻（本机时钟）；0 = 旧版状态迁移过来、没有时刻（下次 sync 立即复核）。
  final int confirmedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'delivering': delivering,
    'at': confirmedAt,
  };
}

class FeedbackReplyState {
  const FeedbackReplyState({
    this.lastRefreshAt = 0,
    this.legacyNotifiedReplyAt = 0,
    this.notified = const <String, int>{},
    this.serverUrl,
    this.alertTitle,
    this.permissionAsked = false,
    this.pushToken,
    this.pushRegistrations = const <String, FeedbackPushRegistration>{},
  });

  factory FeedbackReplyState.fromJson(Map<String, dynamic> j) {
    final String? token = j['pushToken'] as String?;
    return FeedbackReplyState(
      lastRefreshAt: (j['lastRefreshAt'] as num?)?.toInt() ?? 0,
      legacyNotifiedReplyAt: (j['notifiedReplyAt'] as num?)?.toInt() ?? 0,
      notified: <String, int>{
        for (final MapEntry<Object?, Object?> e
            in ((j['notified'] as Map<Object?, Object?>?) ??
                    const <Object?, Object?>{})
                .entries)
          if (e.key is String && e.value is num)
            e.key! as String: (e.value! as num).toInt(),
      },
      serverUrl: j['serverUrl'] as String?,
      alertTitle: j['alertTitle'] as String?,
      permissionAsked: j['permissionAsked'] == true,
      pushToken: token,
      pushRegistrations: token == null
          ? const <String, FeedbackPushRegistration>{}
          : _readRegistrations(j),
    );
  }

  /// 新格式 `pushRegistrations: {id: {delivering, at}}`；旧版只有 `pushRegistered`（id 列表）
  /// + 全局 `pushDelivering`，迁移成没有登记时刻的条目——下次 sync 立即向服务端复核。
  static Map<String, FeedbackPushRegistration> _readRegistrations(
    Map<String, dynamic> j,
  ) {
    final Object? regs = j['pushRegistrations'];
    if (regs is Map<Object?, Object?>) {
      return <String, FeedbackPushRegistration>{
        for (final MapEntry<Object?, Object?> e in regs.entries)
          if (e.key is String && e.value is Map<Object?, Object?>)
            e.key! as String: FeedbackPushRegistration.fromJson(
              (e.value! as Map<Object?, Object?>).cast<String, dynamic>(),
            ),
      };
    }
    final bool delivering = j['pushDelivering'] == true;
    return <String, FeedbackPushRegistration>{
      for (final Object? e
          in (j['pushRegistered'] as List<Object?>?) ?? const <Object?>[])
        if (e is String)
          e: FeedbackPushRegistration(delivering: delivering, confirmedAt: 0),
    };
  }

  final int lastRefreshAt;

  /// 旧版全局水位（见文件头），[notified] 里没有的条目以它为下限。
  final int legacyNotifiedReplyAt;

  /// 反馈 id → 已提醒过的该条最新回复时刻。
  final Map<String, int> notified;
  final String? serverUrl;
  final String? alertTitle;
  final bool permissionAsked;

  /// 当前登记用的 APNs 令牌（十六进制）；null = 没有远程推送。
  final String? pushToken;

  /// 已用 [pushToken] 成功登记过的反馈。
  final Map<String, FeedbackPushRegistration> pushRegistrations;

  /// 这条反馈已经提醒到的回复时刻。
  int notifiedAt(String id) => notified[id] ?? legacyNotifiedReplyAt;

  /// 新回复由服务端远程推送提醒的反馈：用当前令牌登记成功 **且** 服务端答复会推送。
  Set<String> get pushCovered => pushToken == null
      ? const <String>{}
      : <String>{
          for (final MapEntry<String, FeedbackPushRegistration> e
              in pushRegistrations.entries)
            if (e.value.delivering) e.key,
        };

  /// 把 [alerts] 各条的水位推进到它们的回复时刻（只增不减，其余条目不动）。
  FeedbackReplyState withNotified(Iterable<FeedbackReplyAlert> alerts) {
    if (alerts.isEmpty) return this;
    final Map<String, int> next = <String, int>{...notified};
    for (final FeedbackReplyAlert a in alerts) {
      next[a.id] = math.max(a.devReplyAt, notifiedAt(a.id));
    }
    return _with(notified: next);
  }

  /// 整组替换远程推送登记状态（[token] 为 null = 清空）。
  FeedbackReplyState withPush({
    required String? token,
    required Map<String, FeedbackPushRegistration> registrations,
  }) => FeedbackReplyState(
    lastRefreshAt: lastRefreshAt,
    legacyNotifiedReplyAt: legacyNotifiedReplyAt,
    notified: notified,
    serverUrl: serverUrl,
    alertTitle: alertTitle,
    permissionAsked: permissionAsked,
    pushToken: token,
    pushRegistrations: token == null
        ? const <String, FeedbackPushRegistration>{}
        : registrations,
  );

  FeedbackReplyState copyWith({
    int? lastRefreshAt,
    String? serverUrl,
    String? alertTitle,
    bool? permissionAsked,
  }) => _with(
    lastRefreshAt: lastRefreshAt,
    serverUrl: serverUrl,
    alertTitle: alertTitle,
    permissionAsked: permissionAsked,
  );

  FeedbackReplyState _with({
    int? lastRefreshAt,
    Map<String, int>? notified,
    String? serverUrl,
    String? alertTitle,
    bool? permissionAsked,
  }) => FeedbackReplyState(
    lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
    legacyNotifiedReplyAt: legacyNotifiedReplyAt,
    notified: notified ?? this.notified,
    serverUrl: serverUrl ?? this.serverUrl,
    alertTitle: alertTitle ?? this.alertTitle,
    permissionAsked: permissionAsked ?? this.permissionAsked,
    pushToken: pushToken,
    pushRegistrations: pushRegistrations,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lastRefreshAt': lastRefreshAt,
    if (legacyNotifiedReplyAt != 0) 'notifiedReplyAt': legacyNotifiedReplyAt,
    if (notified.isNotEmpty) 'notified': notified,
    if (serverUrl != null) 'serverUrl': serverUrl,
    if (alertTitle != null) 'alertTitle': alertTitle,
    if (permissionAsked) 'permissionAsked': true,
    if (pushToken != null) 'pushToken': pushToken,
    if (pushRegistrations.isNotEmpty)
      'pushRegistrations': <String, dynamic>{
        for (final MapEntry<String, FeedbackPushRegistration> e
            in pushRegistrations.entries)
          e.key: e.value.toJson(),
      },
  };
}

/// [FeedbackReplyState] 的落盘。读失败（不存在 / 损坏）按初始状态处理；写走「临时文件 +
/// rename」，读到的永远是某一份完整内容，不会是半截。
///
/// 读改写（[update]）在跨 isolate 的排他锁里做：锁是同目录的 `poll_state.json.lock`，
/// 以「独占创建」（O_EXCL）取得、做完删除。不用 `RandomAccessFile.lock`——Android / iOS /
/// macOS / Linux 上那是 fcntl 建议锁，**按进程**持有：后台任务（WorkManager / BGTask）
/// 的 isolate 与主 isolate 在同一个进程里，两边都能同时「拿到」它，等于没锁。
class FeedbackReplyStateStore {
  FeedbackReplyStateStore(this.supportRoot);

  final Directory supportRoot;

  /// 锁文件比这更旧 = 持锁的 isolate 在临界区里被杀了（临界区只有一次小文件读写，
  /// 正常持锁是毫秒级），可以收走。
  static const Duration staleLockAge = Duration(seconds: 10);

  /// 等锁时两次探测之间的间隔。
  static const Duration _lockPoll = Duration(milliseconds: 15);

  File get file =>
      File(p.join(supportRoot.path, 'feedback', 'poll_state.json'));

  File get lockFile => File('${file.path}.lock');

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

  /// 读改写：[change] 拿**锁内现读**的最新状态返回新状态，只改调用方自己负责的字段。
  /// [change] 是同步的——临界区里不联网、不等别的 IO，挑选（[selectNewReplies]）也在
  /// 这里做，两个 isolate 就不会各自凭旧水位提醒同一条回复。
  Future<FeedbackReplyState> update(
    FeedbackReplyState Function(FeedbackReplyState current) change,
  ) async {
    final File f = file;
    await f.parent.create(recursive: true);
    await _acquire();
    try {
      final FeedbackReplyState next = change(await read());
      final File tmp = File(
        '${f.path}.${math.Random().nextInt(1 << 32).toRadixString(16)}.tmp',
      );
      await tmp.writeAsString(jsonEncode(next.toJson()), flush: true);
      await tmp.rename(f.path);
      return next;
    } finally {
      await _release();
    }
  }

  Future<void> _acquire() async {
    final File lock = lockFile;
    while (true) {
      try {
        await lock.create(exclusive: true);
        return;
      } on FileSystemException {
        if (_isStale(lock)) {
          await _release();
          continue;
        }
        await Future<void>.delayed(_lockPoll);
      }
    }
  }

  static bool _isStale(File lock) {
    try {
      return DateTime.now().difference(lock.lastModifiedSync()) > staleLockAge;
    } on FileSystemException {
      // 刚被持有者删掉：下一轮直接再抢。
      return false;
    }
  }

  Future<void> _release() async {
    try {
      await lockFile.delete();
    } on FileSystemException {
      // 已经不在了（被当作过期锁收走）。
    }
  }
}

/// 后台 isolate 的一次检查（Android WorkManager / iOS BGAppRefresh 调它）：
///
/// 1. 读本机清单；没有后台能查的未结案反馈（[feedbackBackgroundPollable]）→ 不发请求；
/// 2. 主 isolate [kFeedbackReplyPollInterval] 内刚刷新过 → 交给它，不发请求；
/// 3. 按批问进度（与 `FeedbackService.refresh` 同一个接口、同一个服务器——服务器取主
///    isolate 写下的 `serverUrl`，没写过就用 [defaultBaseUrl]）；
/// 4. 在锁内用**最新**的状态挑出新回复（[selectNewReplies]），只推进这些条目的水位；
///    联网的那几秒里主 isolate 可能已经提醒过同一条、或改了别的字段，都不会被覆盖。
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
      if (feedbackBackgroundPollable(t)) t,
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
  if (candidates.isEmpty) return const <FeedbackReplyAlert>[];

  final Map<String, int> seenAt = <String, int>{
    for (final FeedbackTicket t in active) t.id: t.seenAt,
  };
  List<FeedbackReplyAlert> fresh = const <FeedbackReplyAlert>[];
  Set<String> pushCovered = const <String>{};
  // 水位按全部新回复推进（含远程推送已提醒的），通知只发没被推送覆盖的。
  await store.update((FeedbackReplyState latest) {
    fresh = selectNewReplies(candidates, seenAt: seenAt, state: latest);
    pushCovered = latest.pushCovered;
    return latest.withNotified(fresh);
  });
  return withoutPushCovered(fresh, pushCovered);
}
