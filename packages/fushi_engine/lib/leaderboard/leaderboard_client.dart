// 排行榜 Worker 的 HTTP 客户端（路由表：services/leaderboard/src/worker.js 文件头）。
//
// 签名：有 [LeaderboardIdentity] 时，每个请求（读也签，服务端按观看者身份套好友 / 屏蔽 /
// 「我的名次」）都带 X-Fushi-Account / X-Fushi-Time / X-Fushi-Sig（例外：邮箱验证码请求
// 不签；注册 / 登录自签但不带 X-Fushi-Account）。X-Fushi-Account 发的是本机**设备钥匙 id**
// （sha256(spki) 前 16 位），服务端据此查所属账户——换设备登录后它与账户 id 不同。签名串见
// leaderboard_signing.dart。写请求服务端按签名串哈希去重，所以同一客户端连发两个同内容
// 请求必须错开时刻：签名时刻取 max(clock, 上次 + 1)，严格单调。
//
// 出站 http.Client 由调用方注入（app 侧必须经全应用代理装配），每个请求取一个、用完即关。
// 非 2xx 抛 [LeaderboardApiException]；网络层异常原样透出，由调用方决定是否下次再传。
//
// 每个请求有整体超时（默认 30 秒，书架 / 封面上传 60 秒）：到点关掉 http.Client 并抛
// [LeaderboardTimeoutException]。签名时刻 = 本地时钟 + [LeaderboardServerClock] 记下的
// 服务器偏移（取自每个响应的 `Date` 头）；服务端判 401 `stale_time`（|偏移| > 5 分钟）时
// 用该响应刚校准的偏移重签、重发一次。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';

/// 服务端返回的非 2xx。[code] 取响应 JSON 的 `error`（如 `bad_signature` / `rate_limited`），
/// 响应不是约定形状时为 `http_<status>`。
class LeaderboardApiException implements Exception {
  const LeaderboardApiException(this.status, this.code, [this.detail]);

  final int status;
  final String code;
  final String? detail;

  @override
  String toString() =>
      'LeaderboardApiException($status $code${detail == null ? '' : ': $detail'})';
}

/// 请求整体超时（[LeaderboardClient] 到点关闭连接后抛出）。继承 [TimeoutException]，
/// 调用方按「网络问题」处理即可。
class LeaderboardTimeoutException extends TimeoutException {
  LeaderboardTimeoutException(this.method, this.path, Duration timeout)
    : super('leaderboard $method $path timed out', timeout);

  final String method;
  final String path;
}

/// 服务器时钟偏移（毫秒，服务器 − 本地）。取自响应的 `Date` 头（秒精度），同一服务的
/// 多个 [LeaderboardClient] 共用一个实例，换账户 / 重建客户端时不丢校准。
class LeaderboardServerClock {
  int _offsetMs = 0;

  int get offsetMs => _offsetMs;

  /// 本地时刻 [localMs] 对应的服务器时刻。
  int serverNow(int localMs) => localMs + _offsetMs;

  /// 用响应的 `Date` 头校准；头缺失或格式不对时不变。返回是否校准了。
  bool observe(String? dateHeader, int localMs) {
    if (dateHeader == null || dateHeader.isEmpty) return false;
    final DateTime server;
    try {
      server = HttpDate.parse(dateHeader);
    } on Object {
      return false;
    }
    _offsetMs = server.millisecondsSinceEpoch - localMs;
    return true;
  }
}

/// 签名请求的设备钥匙在服务端不存在（401）：账户已删除或本设备已被解绑。
const String kLeaderboardAccountGoneCode = 'unknown_account';

/// 默认请求整体超时。
const Duration kLeaderboardRequestTimeout = Duration(seconds: 30);

/// 书架批 / 封面上传的整体超时。
const Duration kLeaderboardUploadTimeout = Duration(seconds: 60);

/// 增量上报单批上限（与服务端一致；分批由调用方做）。
const int kLeaderboardMaxPut = 500;
const int kLeaderboardMaxRemove = 500;
const int kLeaderboardMaxDaily = 400;

/// 单账户服务端书架行数上限（shelf.js `MAX_SHELF_ROWS`；超了整批 413 `shelf_full`）。
const int kLeaderboardMaxShelfRows = 8000;

/// 游标分页接口（用户书架 / 作品读者）单页上限。
const int kLeaderboardMaxPageLimit = 50;

const String _json = 'application/json; charset=utf-8';

final RegExp _emailShape = RegExp(r'^[^\s@]{1,64}@[^\s@]+\.[^\s@]{2,}$');

/// 客户端的基本邮箱形状校验（服务端另有权威校验）：`local@domain.tld`、无空白、
/// 总长 ≤ 254。给 UI 做即时提示用，不做 DNS / 国际化域名细判。
bool isPlausibleLeaderboardEmail(String email) {
  final String e = email.trim();
  return e.length <= 254 && _emailShape.hasMatch(e);
}

class LeaderboardClient {
  LeaderboardClient({
    required Uri baseUrl,
    required Future<http.Client> Function() httpClientFactory,
    LeaderboardIdentity? identity,
    int Function()? clockMs,
    LeaderboardServerClock? serverClock,
    Duration requestTimeout = kLeaderboardRequestTimeout,
    Duration uploadTimeout = kLeaderboardUploadTimeout,
    FutureOr<void> Function(LeaderboardApiException error)? onAccountGone,
  }) : _baseUrl = baseUrl,
       _httpClientFactory = httpClientFactory,
       _identity = identity,
       _clockMs = clockMs ?? _systemClockMs,
       serverClock = serverClock ?? LeaderboardServerClock(),
       _requestTimeout = requestTimeout,
       _uploadTimeout = uploadTimeout,
       _onAccountGone = onAccountGone;

  /// 带 X-Fushi-Account 的签名请求收到 401 [kLeaderboardAccountGoneCode]（设备钥匙在服务端
  /// 已不存在：账户在别的设备删了，或本设备被解绑）时，在异常抛给调用方**之前**调用，并
  /// **等它返回的 Future 完成**再抛。不论请求是从哪条路径发出的（同步 / 读榜 / 好友），持有
  /// 者都在这一处得知本机账户已失效；调用方一接到异常，持有者的退出已经落定（不能是
  /// fire-and-forget：否则调用方看到的状态取决于异步落盘赶没赶上，BUG-2801）。
  final FutureOr<void> Function(LeaderboardApiException error)? _onAccountGone;

  final Uri _baseUrl;
  final Future<http.Client> Function() _httpClientFactory;
  final LeaderboardIdentity? _identity;
  final int Function() _clockMs;
  final Duration _requestTimeout;
  final Duration _uploadTimeout;
  int _lastSignedAt = 0;

  /// 服务器时钟偏移（签名时刻与书架「读完时刻」上界都按它算）。
  final LeaderboardServerClock serverClock;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  LeaderboardIdentity? get identity => _identity;

  /// 服务地址（拼分享链接 [shareUserUrl] / [shareWorkUrl] 用）。
  Uri get baseUrl => _baseUrl;

  /// 按已校准偏移估计的服务器当前时刻（毫秒）。
  int serverNowMs() => serverClock.serverNow(_clockMs());

  // ---- 账户 ----

  /// 请求邮箱验证码（[purpose] = `register` | `login`；[lang] = `zh` | `en` | `ja`）。
  /// 不签名；为防探测，服务端不论邮箱是否存在都回 202。邮箱形状不对抛 [ArgumentError]
  /// （服务端同样校验，400 `bad_email`）。
  Future<void> requestEmailCode({
    required String email,
    required String purpose,
    String? lang,
  }) async {
    final String normalized = _requireEmail(email);
    if (purpose != 'register' && purpose != 'login') {
      throw ArgumentError.value(purpose, 'purpose', 'register | login');
    }
    await _send(
      'POST',
      '/v1/email/code',
      bytes: _encodeJson(<String, dynamic>{
        'email': normalized,
        'purpose': purpose,
        if (lang != null) 'lang': lang,
      }),
      contentType: _json,
      signed: false,
    );
  }

  /// 用邮箱验证码注册（幂等：同一把钥匙重复注册返回已有账户，200/201 都算成功）。
  /// 用本机钥匙自签，不带 X-Fushi-Account（账户还不存在，公钥在 body 里）。
  Future<LeaderboardSelf> register({
    required String nickname,
    required String email,
    required String code,
  }) async {
    final LeaderboardIdentity id = _requireIdentity();
    final JsonMap j = await _sendJson(
      'POST',
      '/v1/register',
      body: <String, dynamic>{
        'pubkey': id.pubkeyBase64Url,
        'nickname': nickname,
        'email': _requireEmail(email),
        'code': code.trim(),
      },
      withAccount: false,
    );
    return LeaderboardSelf.fromJson(j);
  }

  /// 换设备登录：把本机（新）钥匙绑到该邮箱的已有账户上。返回的 [LeaderboardSelf]
  /// 的 `account.id` 是**真实账户 id**，不再等于本机钥匙推出来的 id。
  Future<LeaderboardSelf> login({
    required String email,
    required String code,
  }) async {
    final LeaderboardIdentity id = _requireIdentity();
    final JsonMap j = await _sendJson(
      'POST',
      '/v1/login',
      body: <String, dynamic>{
        'pubkey': id.pubkeyBase64Url,
        'email': _requireEmail(email),
        'code': code.trim(),
      },
      withAccount: false,
    );
    return LeaderboardSelf.fromJson(j);
  }

  Future<LeaderboardSelf> me() async {
    _requireIdentity();
    return LeaderboardSelf.fromJson(await _sendJson('GET', '/v1/me'));
  }

  /// [visibility] = `public` | `friends`；null 字段不改。
  Future<LeaderboardSelf> updateProfile({
    String? nickname,
    String? visibility,
  }) async {
    _requireIdentity();
    final JsonMap j = await _sendJson(
      'PATCH',
      '/v1/me',
      body: <String, dynamic>{
        if (nickname != null) 'nickname': nickname,
        if (visibility != null) 'visibility': visibility,
      },
    );
    return LeaderboardSelf.fromJson(j);
  }

  /// 删除账户与服务端全部数据（含头像与只有自己读过的作品）。
  Future<void> deleteAccount() async {
    _requireIdentity();
    await _send('DELETE', '/v1/me');
  }

  /// 本账户已绑定的设备（本机标 `current`）。
  Future<List<LeaderboardDevice>> devices() async {
    _requireIdentity();
    final JsonMap j = await _sendJson('GET', '/v1/me/devices');
    return List<LeaderboardDevice>.unmodifiable(
      ((j['devices'] as List<Object?>?) ?? const <Object?>[]).map(
        (Object? e) => LeaderboardDevice.fromJson(
          (e as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      ),
    );
  }

  /// 解绑一台设备（204）。不能解绑本机（400 `cannot_remove_current`）；解绑的若是上传
  /// 设备，服务端清空上传设备。
  Future<void> removeDevice(String keyId) async {
    _requireIdentity();
    await _send('DELETE', '/v1/me/devices/${_segment(keyId)}');
  }

  /// 上传头像（客户端已裁成小 JPEG），返回 `/img/...` 相对路径。
  Future<String> setAvatar(Uint8List jpeg) async {
    _requireIdentity();
    final JsonMap j = await _sendJson(
      'PUT',
      '/v1/me/avatar',
      bytes: jpeg,
      contentType: 'image/jpeg',
    );
    return j['avatar'] as String;
  }

  Future<void> clearAvatar() async {
    _requireIdentity();
    await _send('DELETE', '/v1/me/avatar');
  }

  // ---- 书架上报 ----

  /// 增量上报。[reset] = 先清空本账户书架与每日字数；[put] 每条是该作品合并后的完整值；
  /// [remove] 是要删掉的 workId；[daily] 按日期覆盖（chars 0 = 删除该日）。
  /// [claim] = 由本设备接管上传（必须同时 [reset]）。超过单批上限、或 claim 未带 reset
  /// 抛 [ArgumentError]。
  ///
  /// 409 `upload_owned_by_other_device` = 上传设备是另一台；409 `conflict` = 并发写入
  /// 改了书架版本、本批已整体回滚（可原样重发）。
  Future<ShelfUploadResult> uploadShelfDelta({
    bool reset = false,
    bool claim = false,
    List<ShelfEntryUpload> put = const <ShelfEntryUpload>[],
    List<String> remove = const <String>[],
    List<DailyCharsUpload> daily = const <DailyCharsUpload>[],
  }) async {
    _requireIdentity();
    _checkBatch('put', put.length, kLeaderboardMaxPut);
    _checkBatch('remove', remove.length, kLeaderboardMaxRemove);
    _checkBatch('daily', daily.length, kLeaderboardMaxDaily);
    if (claim && !reset) {
      throw ArgumentError.value(claim, 'claim', 'requires reset');
    }
    final JsonMap j = await _sendJson(
      'POST',
      '/v1/shelf',
      body: <String, dynamic>{
        'reset': reset,
        if (claim) 'claim': true,
        'put': put.map((ShelfEntryUpload e) => e.toJson()).toList(),
        'remove': remove,
        'daily': daily.map((DailyCharsUpload d) => d.toJson()).toList(),
      },
      timeout: _uploadTimeout,
    );
    return ShelfUploadResult.fromJson(j);
  }

  /// 给缺封面的作品补传缩略图，返回封面路径；别人已抢先传过（409 cover_exists）返回 null。
  Future<String?> uploadCover(
    String workId,
    Uint8List bytes, {
    String contentType = 'image/jpeg',
  }) async {
    _requireIdentity();
    try {
      final JsonMap j = await _sendJson(
        'PUT',
        '/v1/works/${_segment(workId)}/cover',
        bytes: bytes,
        contentType: contentType,
        timeout: _uploadTimeout,
      );
      return j['cover'] as String?;
    } on LeaderboardApiException catch (e) {
      if (e.status == 409 && e.code == 'cover_exists') return null;
      rethrow;
    }
  }

  // ---- 读 ----

  Future<RankPage> rank({
    LeaderboardMetric metric = LeaderboardMetric.book,
    LeaderboardWindow window = LeaderboardWindow.week,
    LeaderboardScope scope = LeaderboardScope.global,
    int limit = 50,
    int offset = 0,
  }) async {
    final JsonMap j = await _sendJson(
      'GET',
      '/v1/rank',
      query: <String, String>{
        'metric': metric.wire,
        'window': window.wire,
        'scope': scope.wire,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return RankPage.fromJson(j);
  }

  Future<PopularPage> popular({
    LeaderboardWindow window = LeaderboardWindow.month,
    LeaderboardKind? kind,
    int limit = 50,
    int offset = 0,
  }) async {
    final JsonMap j = await _sendJson(
      'GET',
      '/v1/works/popular',
      query: <String, String>{
        'window': window.wire,
        if (kind != null) 'kind': kind.wire,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return PopularPage.fromJson(j);
  }

  Future<UserCard> user(String id) async =>
      UserCard.fromJson(await _sendJson('GET', '/v1/users/${_segment(id)}'));

  /// [status] = `finished` | `reading`。书架对观看者不可见时抛 403 `shelf_private`。
  /// 游标分页：[cursor] 取上一页的 [ShelfPage.next]（首页省略），`next == null` = 没有更多。
  Future<ShelfPage> userShelf(
    String id, {
    String status = 'finished',
    LeaderboardKind? kind,
    int limit = kLeaderboardMaxPageLimit,
    String? cursor,
  }) async {
    final JsonMap j = await _sendJson(
      'GET',
      '/v1/users/${_segment(id)}/shelf',
      query: <String, String>{
        'status': status,
        if (kind != null) 'kind': kind.wire,
        'limit': '${_cursorLimit(limit)}',
        if (cursor != null) 'cursor': cursor,
      },
    );
    return ShelfPage.fromJson(j);
  }

  /// 作品页（读者列表游标分页，同 [userShelf]）。
  Future<WorkPage> work(
    String id, {
    int limit = kLeaderboardMaxPageLimit,
    String? cursor,
  }) async {
    final JsonMap j = await _sendJson(
      'GET',
      '/v1/works/${_segment(id)}',
      query: <String, String>{
        'limit': '${_cursorLimit(limit)}',
        if (cursor != null) 'cursor': cursor,
      },
    );
    return WorkPage.fromJson(j);
  }

  // ---- 反馈（services/leaderboard/src/feedback.js） ----
  //
  // 反馈人接口不要求账户：凭提交时拿到的 ticket（X-Fushi-Ticket）读进度、追加说明、补传附件。
  // 本客户端没有 identity 时同样可用（匿名）。开发者接口要求签名且账户 role = dev。

  static final RegExp _feedbackSlot = RegExp(r'^(log|s[0-2])$');

  static String _feedbackSlotOf(String slot) {
    if (!_feedbackSlot.hasMatch(slot)) {
      throw ArgumentError.value(slot, 'slot', 'log | s0..s2');
    }
    return slot;
  }

  /// 提交反馈。[linkAccount] 且本客户端有账户时带签名提交（开发者能看到反馈人昵称）；
  /// 否则匿名。返回的 [FeedbackReceipt.ticket] 只给这一次。
  Future<FeedbackReceipt> submitFeedback({
    required FeedbackCategory category,
    required String title,
    required String body,
    String contact = '',
    Map<String, Object?> meta = const <String, Object?>{},
    bool linkAccount = true,
  }) async {
    final bool signs = linkAccount && _identity != null;
    final JsonMap j = await _sendJson(
      'POST',
      '/v1/feedback',
      body: <String, dynamic>{
        'category': category.wire,
        'title': title,
        'body': body,
        if (contact.isNotEmpty) 'contact': contact,
        'meta': meta,
      },
      signed: signs,
    );
    return FeedbackReceipt.fromJson(j);
  }

  /// 补传附件：[slot] = `log`（gzip 字节）/ `s0`..`s2`（PNG / JPEG / WebP）。
  /// 同一槽位服务端只收一次：重试撞上 409 `slot_taken` 说明上次其实已传成功，按成功返回。
  Future<void> uploadFeedbackAttachment(
    String id,
    String ticket,
    String slot,
    Uint8List bytes,
  ) async {
    try {
      await _send(
        'PUT',
        '/v1/feedback/${_segment(id)}/attachments/${_feedbackSlotOf(slot)}',
        bytes: bytes,
        contentType: slot == 'log'
            ? 'application/gzip'
            : 'application/octet-stream',
        signed: false,
        headers: <String, String>{'X-Fushi-Ticket': ticket},
        timeout: _uploadTimeout,
      );
    } on LeaderboardApiException catch (e) {
      if (e.status == 409 && e.code == 'slot_taken') return;
      rethrow;
    }
  }

  /// 批量查进度（每批 ≤ [FeedbackLimits.statusBatch]）。ticket 对不上 / 已不存在的条目不返回。
  Future<List<FeedbackSummary>> feedbackStatuses(
    List<({String id, String ticket})> items,
  ) async {
    if (items.length > FeedbackLimits.statusBatch) {
      throw ArgumentError.value(items.length, 'items', 'too many');
    }
    if (items.isEmpty) return const <FeedbackSummary>[];
    final JsonMap j = await _sendJson(
      'POST',
      '/v1/feedback/status',
      body: <String, dynamic>{
        'items': <Map<String, String>>[
          for (final ({String id, String ticket}) it in items)
            <String, String>{'id': it.id, 'ticket': it.ticket},
        ],
      },
      signed: false,
    );
    return List<FeedbackSummary>.unmodifiable(
      ((j['items'] as List<Object?>?) ?? const <Object?>[]).map(
        (Object? e) => FeedbackSummary.fromJson(
          (e as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      ),
    );
  }

  /// 反馈人看详情与处理时间线。
  Future<FeedbackDetail> feedbackDetail(String id, String ticket) async =>
      FeedbackDetail.fromJson(
        await _sendJson(
          'GET',
          '/v1/feedback/${_segment(id)}',
          signed: false,
          headers: <String, String>{'X-Fushi-Ticket': ticket},
        ),
      );

  /// 反馈人追加说明；结案后追加会把状态拉回待处理。返回更新后的详情。
  Future<FeedbackDetail> addFeedbackMessage(
    String id,
    String ticket,
    String body,
  ) async => FeedbackDetail.fromJson(
    await _sendJson(
      'POST',
      '/v1/feedback/${_segment(id)}/messages',
      body: <String, dynamic>{'body': body},
      signed: false,
      headers: <String, String>{'X-Fushi-Ticket': ticket},
    ),
  );

  /// 开发者：反馈列表。[status] = `active`（未结案，默认）/ 某个状态 wire 值 / null（全部）。
  Future<FeedbackInboxPage> devFeedbackList({
    String? status = 'active',
    String? cursor,
    int? limit,
  }) async {
    _requireIdentity();
    return FeedbackInboxPage.fromJson(
      await _sendJson(
        'GET',
        '/v1/dev/feedback',
        query: <String, String>{
          if (status != null) 'status': status,
          if (cursor != null) 'cursor': cursor,
          if (limit != null) 'limit': '$limit',
        },
      ),
    );
  }

  /// 开发者：详情（含联系方式、设备信息、反馈人）。
  Future<FeedbackDetail> devFeedback(String id) async {
    _requireIdentity();
    return FeedbackDetail.fromJson(
      await _sendJson('GET', '/v1/dev/feedback/${_segment(id)}'),
    );
  }

  /// 开发者：改状态和 / 或回复（至少一个，否则服务端 400 `nothing_to_update`）。
  Future<FeedbackDetail> devUpdateFeedback(
    String id, {
    FeedbackStatus? status,
    String reply = '',
  }) async {
    _requireIdentity();
    return FeedbackDetail.fromJson(
      await _sendJson(
        'POST',
        '/v1/dev/feedback/${_segment(id)}',
        body: <String, dynamic>{
          if (status != null) 'status': status.wire,
          if (reply.isNotEmpty) 'reply': reply,
        },
      ),
    );
  }

  /// 开发者：取附件字节。日志 [asText] 时服务端解压成 UTF-8 文本。
  Future<Uint8List> devFeedbackAttachment(
    String id,
    String slot, {
    bool asText = false,
  }) async {
    _requireIdentity();
    final http.Response res = await _send(
      'GET',
      '/v1/dev/feedback/${_segment(id)}/attachments/${_feedbackSlotOf(slot)}',
      query: asText ? <String, String>{'view': 'text'} : null,
      timeout: _uploadTimeout,
    );
    return res.bodyBytes;
  }

  // ---- 社交 ----

  Future<FriendList> friends() async {
    _requireIdentity();
    return FriendList.fromJson(await _sendJson('GET', '/v1/friends'));
  }

  /// 发申请 / 接受对方申请，返回服务端给出的关系状态（如 `pending` / `accepted`）。
  Future<String> addFriend(String id) async {
    _requireIdentity();
    final JsonMap j = await _sendJson('POST', '/v1/friends/${_segment(id)}');
    return j['state'] as String;
  }

  /// 删除好友 / 撤回或拒绝申请。
  Future<void> removeFriend(String id) async {
    _requireIdentity();
    await _send('DELETE', '/v1/friends/${_segment(id)}');
  }

  Future<List<LeaderboardAccount>> blocks() async {
    _requireIdentity();
    final JsonMap j = await _sendJson('GET', '/v1/blocks');
    return List<LeaderboardAccount>.unmodifiable(
      ((j['blocked'] as List<Object?>?) ?? const <Object?>[]).map(
        (Object? e) => LeaderboardAccount.fromJson(
          (e as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      ),
    );
  }

  Future<void> block(String id) async {
    _requireIdentity();
    await _send('POST', '/v1/blocks/${_segment(id)}');
  }

  Future<void> unblock(String id) async {
    _requireIdentity();
    await _send('DELETE', '/v1/blocks/${_segment(id)}');
  }

  /// 举报账户或作品。[targetKind] = `account` | `work`。
  Future<void> report({
    required String targetKind,
    required String targetId,
    required String reason,
  }) async {
    _requireIdentity();
    await _send(
      'POST',
      '/v1/reports',
      bytes: _encodeJson(<String, dynamic>{
        'targetKind': targetKind,
        'targetId': targetId,
        'reason': reason,
      }),
      contentType: _json,
    );
  }

  // ---- URL ----

  /// 把 `/img/...` 之类的相对路径拼到服务地址上；已是绝对 URL 的原样返回。
  Uri resolveMedia(String relativeOrAbsolute) {
    final Uri u = Uri.parse(relativeOrAbsolute);
    if (u.hasScheme) return u;
    return _endpoint(relativeOrAbsolute, null);
  }

  /// 可分享的用户主页（Worker 只读网页 `/u/<id>`）。
  static Uri shareUserUrl(Uri base, String id) =>
      _join(base, '/u/${_segment(id)}', null);

  /// 可分享的作品页（`/w/<id>`）。
  static Uri shareWorkUrl(Uri base, String id) =>
      _join(base, '/w/${_segment(id)}', null);

  // ---- 内部 ----

  LeaderboardIdentity _requireIdentity() {
    final LeaderboardIdentity? id = _identity;
    if (id == null) {
      throw StateError('this leaderboard call needs an account identity');
    }
    return id;
  }

  static String _requireEmail(String email) {
    final String e = email.trim();
    if (!isPlausibleLeaderboardEmail(e)) {
      throw ArgumentError.value(email, 'email', 'not an email address');
    }
    return e;
  }

  static int _cursorLimit(int limit) {
    if (limit < 1 || limit > kLeaderboardMaxPageLimit) {
      throw ArgumentError.value(limit, 'limit', '1..$kLeaderboardMaxPageLimit');
    }
    return limit;
  }

  static void _checkBatch(String name, int n, int max) {
    if (n > max) {
      throw ArgumentError.value(n, name, 'at most $max per request');
    }
  }

  /// 路径段只允许服务端 id 字符集（`[A-Za-z0-9_-]`），杜绝拼出别的路由。
  static String _segment(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a leaderboard id');
    }
    return id;
  }

  static Uri _join(Uri base, String path, Map<String, String>? query) {
    String prefix = base.path;
    while (prefix.endsWith('/')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$prefix${path.startsWith('/') ? path : '/$path'}',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Uri _endpoint(String path, Map<String, String>? query) =>
      _join(_baseUrl, path, query);

  int _nextSignTime() {
    final int t = max(serverNowMs(), _lastSignedAt + 1);
    _lastSignedAt = t;
    return t;
  }

  static Uint8List _encodeJson(Object body) =>
      Uint8List.fromList(utf8.encode(jsonEncode(body)));

  Future<JsonMap> _sendJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Uint8List? bytes,
    String? contentType,
    bool withAccount = true,
    bool signed = true,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final http.Response res = await _send(
      method,
      path,
      query: query,
      bytes: body != null ? _encodeJson(body) : bytes,
      contentType: body != null ? _json : contentType,
      withAccount: withAccount,
      signed: signed,
      headers: headers,
      timeout: timeout,
    );
    try {
      final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return (decoded as Map<Object?, Object?>).cast<String, dynamic>();
    } on Object {
      throw LeaderboardApiException(res.statusCode, 'bad_response');
    }
  }

  /// 发一个请求；签名请求遇 401 `stale_time` 时按该响应校准过的服务器偏移重签重发一次。
  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Uint8List? bytes,
    String? contentType,
    bool withAccount = true,
    bool signed = true,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final bool signs = signed && _identity != null;
    for (int attempt = 0; ; attempt++) {
      try {
        return await _sendOnce(
          method,
          path,
          query: query,
          bytes: bytes,
          contentType: contentType,
          withAccount: withAccount,
          signed: signed,
          headers: headers,
          timeout: timeout ?? _requestTimeout,
        );
      } on LeaderboardApiException catch (e) {
        if (signs &&
            withAccount &&
            e.status == 401 &&
            e.code == kLeaderboardAccountGoneCode) {
          await _onAccountGone?.call(e);
          rethrow;
        }
        if (!signs ||
            attempt > 0 ||
            e.status != 401 ||
            e.code != 'stale_time') {
          rethrow;
        }
        // 偏移刚由这个 401 的 Date 头校准；单调下界是按旧偏移推出来的，钟快时它仍停在
        // 未来，丢掉它。被判 stale 的请求服务端没有登记，不会与重签撞重放。
        _lastSignedAt = 0;
      }
    }
  }

  Future<http.Response> _sendOnce(
    String method,
    String path, {
    required Map<String, String>? query,
    required Uint8List? bytes,
    required String? contentType,
    required bool withAccount,
    required bool signed,
    required Map<String, String>? headers,
    required Duration timeout,
  }) async {
    final Uri url = _endpoint(path, query);
    final List<int> body = bytes ?? const <int>[];
    final http.Request req = http.Request(method, url);
    if (headers != null) req.headers.addAll(headers);
    if (bytes != null) req.bodyBytes = bytes;
    if (contentType != null) req.headers['Content-Type'] = contentType;
    req.headers['Accept'] = 'application/json';
    final LeaderboardIdentity? id = signed ? _identity : null;
    if (id != null) {
      final int time = _nextSignTime();
      final String pathWithQuery = url.hasQuery
          ? '${url.path}?${url.query}'
          : url.path;
      final String message = leaderboardSigningString(
        method,
        pathWithQuery,
        time,
        body,
      );
      if (withAccount) req.headers['X-Fushi-Account'] = id.accountId;
      req.headers['X-Fushi-Time'] = '$time';
      req.headers['X-Fushi-Sig'] = id.sign(message);
    }
    final http.Client client = await _httpClientFactory();
    try {
      final http.Response res;
      try {
        res = await Future<http.Response>(
          () async => http.Response.fromStream(await client.send(req)),
        ).timeout(timeout);
      } on TimeoutException {
        throw LeaderboardTimeoutException(method, path, timeout);
      }
      final String? date = res.headers['date'];
      if (date != null) serverClock.observe(date, _clockMs());
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _apiError(res);
      }
      return res;
    } finally {
      // 超时时关掉 client 同时中止还挂着的连接。
      client.close();
    }
  }

  static LeaderboardApiException _apiError(http.Response res) {
    try {
      final Object? j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['error'] is String) {
        final Object? detail = j['detail'];
        return LeaderboardApiException(
          res.statusCode,
          j['error'] as String,
          detail is String ? detail : null,
        );
      }
    } on FormatException {
      // 非 JSON（网关页 / 空体）：落到下面的通用码。
    }
    return LeaderboardApiException(res.statusCode, 'http_${res.statusCode}');
  }
}
