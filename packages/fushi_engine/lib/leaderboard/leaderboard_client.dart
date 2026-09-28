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

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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

/// 增量上报单批上限（与服务端一致；分批由调用方做）。
const int kLeaderboardMaxPut = 500;
const int kLeaderboardMaxRemove = 500;
const int kLeaderboardMaxDaily = 400;

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
  }) : _baseUrl = baseUrl,
       _httpClientFactory = httpClientFactory,
       _identity = identity,
       _clockMs = clockMs ?? _systemClockMs;

  final Uri _baseUrl;
  final Future<http.Client> Function() _httpClientFactory;
  final LeaderboardIdentity? _identity;
  final int Function() _clockMs;
  int _lastSignedAt = 0;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  LeaderboardIdentity? get identity => _identity;

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
    final int t = max(_clockMs(), _lastSignedAt + 1);
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
  }) async {
    final http.Response res = await _send(
      method,
      path,
      query: query,
      bytes: body != null ? _encodeJson(body) : bytes,
      contentType: body != null ? _json : contentType,
      withAccount: withAccount,
    );
    try {
      final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return (decoded as Map<Object?, Object?>).cast<String, dynamic>();
    } on Object {
      throw LeaderboardApiException(res.statusCode, 'bad_response');
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Uint8List? bytes,
    String? contentType,
    bool withAccount = true,
    bool signed = true,
  }) async {
    final Uri url = _endpoint(path, query);
    final List<int> body = bytes ?? const <int>[];
    final http.Request req = http.Request(method, url);
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
      final http.Response res = await http.Response.fromStream(
        await client.send(req),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _apiError(res);
      }
      return res;
    } finally {
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
