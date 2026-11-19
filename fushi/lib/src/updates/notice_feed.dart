// 服务端通知：按构建信息向 rank.fushi.moe 拉取要展示的通知（`POST /v1/notices`，服务端
// services/leaderboard），展示层见 notice_layer.dart。
//
// 请求体（字段名与服务端约定一致）：v 运行中的构建版本、p 平台键、c 更新通道、l App 界面语言、
// id Android applicationId、h / k 签名证书摘要（见 build_info.dart）。不带安装 id、设备 id
// 或账户，所以这条请求**不受**「使用统计」开关（`usage_stats_enabled`）约束；服务端也不存 IP。
// 通知的文字、级别和链接全部由服务端决定，客户端只负责展示。
//
// 节奏：启动后（首帧之后，不挡启动）拉一次，之后按服务端给的 ttl 再拉；失败等下一个 [NoticeFeed.retry]
// 间隔。上一次成功的结果缓存在设备本地偏好里，离线重启后照常展示；服务端返回空列表即清掉缓存。
// 发心跳的平台才拉（[usageHeartbeatPlatformFor]，iOS 不拉）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/leaderboard/leaderboard_endpoint.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/build_info.dart';
import 'package:fushi/src/updates/usage_heartbeat_platform.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 上一次成功响应里的通知（JSON 数组字符串），设备本地。
const String kNoticesCachePrefKey = 'notices_cache';

/// 已经弹过的对话框级通知 id（JSON 数组字符串），设备本地。
const String kNoticesSeenPrefKey = 'notices_seen';

/// 一次响应最多收几条通知。
const int kNoticeMaxCount = 8;

/// 各字段的长度上限（超出截断；id / url 超长整条丢弃）。
const int kNoticeMaxIdLength = 128;
const int kNoticeMaxTitleLength = 200;
const int kNoticeMaxBodyLength = 4000;
const int kNoticeMaxUrlLength = 2048;

/// 记住多少个已弹过的对话框 id（超出丢最早的）。
const int kNoticeSeenCap = 200;

/// ttl 的取值范围与缺省值。
const Duration kNoticeMinTtl = Duration(minutes: 5);
const Duration kNoticeMaxTtl = Duration(days: 7);
const Duration kNoticeDefaultTtl = Duration(hours: 6);

/// 通知的展示方式。
enum RemoteNoticeLevel {
  /// 主界面顶部的常驻横幅（不可关闭）。
  banner,

  /// 对话框：同一 id 只弹一次。
  dialog,

  /// 盖住整个主界面的全屏层（不可关闭）。
  block;

  /// wire 值 → 级别；未知值返回 null（整条通知丢弃）。
  static RemoteNoticeLevel? fromWire(Object? raw) {
    for (final RemoteNoticeLevel level in values) {
      if (level.name == raw) return level;
    }
    return null;
  }
}

/// 一条服务端下发的通知。文字已由服务端按界面语言选好。
@immutable
class RemoteNotice {
  const RemoteNotice({
    required this.id,
    required this.level,
    required this.title,
    required this.body,
    this.url,
  });

  final String id;
  final RemoteNoticeLevel level;
  final String title;
  final String body;

  /// 点击打开的 https 链接；没有则 null。
  final Uri? url;

  /// 宽松解析一条通知：缺 id、级别未知、标题与正文都为空时返回 null；超长字段截断；
  /// url 不是 https 时当作没有。
  static RemoteNotice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty || id.length > kNoticeMaxIdLength) {
      return null;
    }
    final RemoteNoticeLevel? level = RemoteNoticeLevel.fromWire(raw['level']);
    if (level == null) return null;
    final String title = _text(raw['title'], kNoticeMaxTitleLength);
    final String body = _text(raw['body'], kNoticeMaxBodyLength);
    if (title.isEmpty && body.isEmpty) return null;
    return RemoteNotice(
      id: id,
      level: level,
      title: title,
      body: body,
      url: _httpsUrl(raw['url']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'level': level.name,
    'title': title,
    'body': body,
    'url': url?.toString(),
  };

  static String _text(Object? raw, int max) {
    if (raw is! String) return '';
    final String text = raw.trim();
    return text.length <= max ? text : text.substring(0, max);
  }

  static Uri? _httpsUrl(Object? raw) {
    if (raw is! String || raw.isEmpty || raw.length > kNoticeMaxUrlLength) {
      return null;
    }
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteNotice &&
      other.id == id &&
      other.level == level &&
      other.title == title &&
      other.body == body &&
      other.url == url;

  @override
  int get hashCode => Object.hash(id, level, title, body, url);
}

/// 一次 `/v1/notices` 响应。
@immutable
class NoticeResponse {
  const NoticeResponse({required this.notices, required this.ttl});

  final List<RemoteNotice> notices;

  /// 多久之后再拉（已夹在 [kNoticeMinTtl]..[kNoticeMaxTtl]）。
  final Duration ttl;
}

/// **纯函数**：解析通知数组（响应的 `notices` 或缓存）。逐条宽松解析，坏条目跳过，
/// id 重复只留第一条，最多 [kNoticeMaxCount] 条。
List<RemoteNotice> parseRemoteNotices(Object? raw) {
  if (raw is! List) return const <RemoteNotice>[];
  final List<RemoteNotice> out = <RemoteNotice>[];
  final Set<String> ids = <String>{};
  for (final Object? item in raw) {
    final RemoteNotice? notice = RemoteNotice.fromJson(item);
    if (notice == null || !ids.add(notice.id)) continue;
    out.add(notice);
    if (out.length >= kNoticeMaxCount) break;
  }
  return List<RemoteNotice>.unmodifiable(out);
}

/// **纯函数**：解析响应体。不是 JSON 对象、或没有 `notices` 数组时返回 null（当作这次没拉成，
/// 保留现有通知与缓存）。
NoticeResponse? parseNoticeResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['notices'] is! List) return null;
  final Object? ttl = decoded['ttl'];
  final Duration parsedTtl = ttl is num && ttl.isFinite
      ? Duration(seconds: ttl.round())
      : kNoticeDefaultTtl;
  return NoticeResponse(
    notices: parseRemoteNotices(decoded['notices']),
    ttl: _clampDuration(parsedTtl, kNoticeMinTtl, kNoticeMaxTtl),
  );
}

Duration _clampDuration(Duration value, Duration min, Duration max) =>
    value < min ? min : (value > max ? max : value);

/// **纯函数**：请求体（字段名见文件头）。
Map<String, Object?> buildNoticeRequest({
  required String version,
  required String platform,
  required String channel,
  required String locale,
  required BuildInfo info,
}) => <String, Object?>{
  'v': version,
  'p': platform,
  'c': channel,
  'l': locale,
  'id': info.id,
  'h': List<String>.of(info.h),
  'k': List<String>.of(info.k),
};

/// **纯函数**：缓存里的通知（偏好值是 [kNoticesCachePrefKey] 的 JSON 字符串）。
List<RemoteNotice> decodeCachedNotices(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <RemoteNotice>[];
  try {
    return parseRemoteNotices(jsonDecode(raw));
  } on FormatException {
    return const <RemoteNotice>[];
  }
}

/// **纯函数**：通知写进缓存的 JSON 字符串。
String encodeCachedNotices(List<RemoteNotice> notices) =>
    jsonEncode(notices.map((RemoteNotice notice) => notice.toJson()).toList());

/// **纯函数**：已弹过的对话框 id（偏好值是 [kNoticesSeenPrefKey] 的 JSON 字符串）。
List<String> decodeSeenNoticeIds(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return decoded.whereType<String>().toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}

/// **纯函数**：把 [id] 记进已弹过的列表（已在则原样返回），超过 [cap] 丢最早的。
List<String> rememberSeenNoticeId(
  List<String> seen,
  String id, {
  int cap = kNoticeSeenCap,
}) {
  if (seen.contains(id)) return seen;
  final List<String> next = <String>[...seen, id];
  return next.length <= cap ? next : next.sublist(next.length - cap);
}

/// **纯函数**：[notices] 里还没弹过的对话框级通知（按下发顺序）。
List<RemoteNotice> pendingDialogNotices(
  List<RemoteNotice> notices,
  Iterable<String> seen,
) {
  final Set<String> seenIds = seen.toSet();
  return notices
      .where(
        (RemoteNotice notice) =>
            notice.level == RemoteNoticeLevel.dialog &&
            !seenIds.contains(notice.id),
      )
      .toList(growable: false);
}

/// 发出一次请求，返回响应体；非 2xx / 网络失败抛异常。
typedef NoticePoster = Future<String> Function(Map<String, Object?> body);

/// 请求超时。
const Duration kNoticeRequestTimeout = Duration(seconds: 20);

/// 生产发送器：固定发往 [kLeaderboardDefaultBaseUrl]（与安装统计同一个服务），经
/// [createAppHttpIoClient] 走全应用代理装配。
Future<String> postNoticesToFushi(Map<String, Object?> body) async {
  final http.Client client = createAppHttpIoClient();
  try {
    final http.Response res = await client
        .post(
          Uri.parse('$kLeaderboardDefaultBaseUrl/v1/notices'),
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(kNoticeRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('notices: HTTP ${res.statusCode}');
    }
    return utf8.decode(res.bodyBytes);
  } finally {
    client.close();
  }
}

/// 读本构建的构建信息（生产是 [readBuildInfo]）。
typedef NoticeBuildInfoResolver = Future<BuildInfo> Function();

/// 服务端通知的拉取与缓存。[notices] 是当前要展示的通知；幂等的 [start] / [stop]。
class NoticeFeed {
  NoticeFeed({
    required PreferencesRepository prefs,
    required NoticePoster post,
    required String Function() version,
    required String Function() channel,
    required String Function() locale,
    NoticeBuildInfoResolver buildInfo = readBuildInfo,
    String? operatingSystem,
    this.retry = const Duration(hours: 1),
  }) : _prefs = prefs,
       _post = post,
       _version = version,
       _channel = channel,
       _locale = locale,
       _buildInfo = buildInfo,
       _platform = usageHeartbeatPlatformFor(
         operatingSystem ?? Platform.operatingSystem,
       );

  /// 生产装配：发往 Fushi 自己的服务，版本取运行中代码的构建版本（同安装统计心跳）。
  factory NoticeFeed.forFushi({
    required PreferencesRepository prefs,
    required String executableVersion,
    required String Function() channel,
  }) => NoticeFeed(
    prefs: prefs,
    post: postNoticesToFushi,
    version: () => resolveCurrentAppVersion(executableVersion),
    channel: channel,
    locale: () => LocaleSettings.currentLocale.languageTag,
  );

  final PreferencesRepository _prefs;
  final NoticePoster _post;
  final String Function() _version;
  final String Function() _channel;
  final String Function() _locale;
  final NoticeBuildInfoResolver _buildInfo;
  final String? _platform;

  /// 拉取失败后多久再试。
  final Duration retry;

  final ValueNotifier<List<RemoteNotice>> _notices =
      ValueNotifier<List<RemoteNotice>>(const <RemoteNotice>[]);

  /// 当前要展示的通知。
  ValueListenable<List<RemoteNotice>> get notices => _notices;

  /// 本平台是否拉取通知。
  bool get isSupported => _platform != null;

  Timer? _timer;
  Future<bool>? _active;
  bool _started = false;

  bool get isRunning => _started;

  /// 先展示缓存，再立刻拉一次。不支持的平台什么都不做。
  void start() {
    if (_started || _platform == null) return;
    _started = true;
    _notices.value = decodeCachedNotices(_prefs.getPref(kNoticesCachePrefKey));
    unawaited(refresh());
  }

  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    _timer = null;
    await _active;
  }

  void dispose() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    _notices.dispose();
  }

  /// 拉一次；返回是否拿到了有效响应。并发调用共享同一次请求。
  Future<bool> refresh() {
    final Future<bool>? active = _active;
    if (active != null) return active;
    final Future<bool> run = _refresh().whenComplete(() => _active = null);
    _active = run;
    return run;
  }

  Future<bool> _refresh() async {
    final String? platform = _platform;
    if (platform == null) return false;
    NoticeResponse? response;
    try {
      final Map<String, Object?> body = buildNoticeRequest(
        version: _version(),
        platform: platform,
        channel: _channel(),
        locale: _locale(),
        info: await _buildInfo(),
      );
      response = parseNoticeResponse(await _post(body));
    } catch (error) {
      // 断网 / 服务端不可用：保留现有通知与缓存，等 [retry] 后再试。
      debugPrint('NoticeFeed: fetch failed. $error');
    }
    if (response == null) {
      _schedule(retry);
      return false;
    }
    if (!_started) return true;
    if (response.notices.isEmpty) {
      await _prefs.removePref(kNoticesCachePrefKey);
    } else {
      await _prefs.setPref(
        kNoticesCachePrefKey,
        encodeCachedNotices(response.notices),
      );
    }
    if (!listEquals(_notices.value, response.notices)) {
      _notices.value = response.notices;
    }
    _schedule(response.ttl);
    return true;
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    _timer = null;
    if (!_started) return;
    _timer = Timer(after, () => unawaited(refresh()));
  }

  /// 已弹过的对话框级通知 id。
  List<String> get seenDialogIds =>
      decodeSeenNoticeIds(_prefs.getPref(kNoticesSeenPrefKey));

  /// 当前还没弹过的对话框级通知。
  List<RemoteNotice> get pendingDialogs =>
      pendingDialogNotices(_notices.value, seenDialogIds);

  /// 记下 [id] 已弹过（以后不再弹）。
  Future<void> markDialogSeen(String id) async {
    final List<String> seen = seenDialogIds;
    final List<String> next = rememberSeenNoticeId(seen, id);
    if (identical(next, seen)) return;
    await _prefs.setPref(kNoticesSeenPrefKey, jsonEncode(next));
  }
}
