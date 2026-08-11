import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:fushi/src/utils/net/app_http.dart';

class BangumiApiException implements Exception {
  const BangumiApiException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'Bangumi API $statusCode: $message';
}

class BangumiSubject {
  const BangumiSubject({
    required this.id,
    required this.type,
    required this.name,
    required this.nameCn,
    required this.platform,
    required this.episodeCount,
    required this.volumeCount,
    this.coverUrl,
  });

  final int id;
  final int type;
  final String name;
  final String nameCn;
  final String platform;
  final int episodeCount;
  final int volumeCount;
  final String? coverUrl;

  String get displayName => nameCn.trim().isNotEmpty ? nameCn : name;
  String get secondaryName =>
      nameCn.trim().isNotEmpty && nameCn != name ? name : '';
}

class BangumiEpisode {
  const BangumiEpisode({
    required this.id,
    required this.type,
    required this.sort,
  });

  final int id;
  final int type;
  final double sort;
}

class BangumiUser {
  const BangumiUser({required this.username, required this.nickname});

  final String username;
  final String nickname;
}

class BangumiUserCollection {
  const BangumiUserCollection({
    required this.type,
    required this.episodeProgress,
    required this.volumeProgress,
  });

  final int type;
  final int episodeProgress;
  final int volumeProgress;
}

/// Bangumi 账号收藏列表中的一条「看过」动画。
///
/// 这不是本地映射：用户在接入 Hibiki 之前已经在 Bangumi 标记过的条目也会出现，
/// 正是首页账号入口需要展示的完整远端历史。
class BangumiWatchedItem {
  const BangumiWatchedItem({
    required this.subject,
    required this.episodeProgress,
    required this.updatedAt,
  });

  final BangumiSubject subject;
  final int episodeProgress;
  final DateTime? updatedAt;
}

typedef BangumiWatchedPage = ({
  List<BangumiWatchedItem> items,
  int total,
  int limit,
  int offset,
});

Map<String, dynamic>? _map(dynamic value) {
  if (value is! Map) return null;
  return value.map(
    (dynamic key, dynamic value) => MapEntry<String, dynamic>(
      key.toString(),
      value,
    ),
  );
}

int _int(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

String _string(dynamic value) => value is String ? value : '';

/// 本层支持的 Bangumi 条目类型：1 书籍（含漫画/轻小说）/ 2 动画 / 4 游戏。
/// 音乐(3)与三次元(6)没有对应的本地媒体，解析阶段丢弃。
const Set<int> kSupportedBangumiSubjectTypes = <int>{1, 2, 4};

BangumiSubject? _parseBangumiSubjectValue(dynamic item) {
  final Map<String, dynamic>? value = _map(item);
  if (value == null) return null;
  final int id = _int(value['id']);
  final int type = _int(value['type']);
  if (id <= 0 || !kSupportedBangumiSubjectTypes.contains(type)) return null;
  final Map<String, dynamic>? images = _map(value['images']);
  return BangumiSubject(
    id: id,
    type: type,
    name: _string(value['name']),
    nameCn: _string(value['name_cn']),
    platform: _string(value['platform']),
    episodeCount: _int(value['eps']),
    volumeCount: _int(value['volumes']),
    coverUrl: _string(images?['medium']).isNotEmpty
        ? _string(images?['medium'])
        : null,
  );
}

List<BangumiSubject> parseBangumiSubjectSearch(String body) {
  final dynamic decoded = jsonDecode(body);
  final Map<String, dynamic>? root = _map(decoded);
  final dynamic data = root?['data'];
  if (data is! List) return const <BangumiSubject>[];
  final List<BangumiSubject> subjects = <BangumiSubject>[];
  for (final dynamic item in data) {
    final BangumiSubject? subject = _parseBangumiSubjectValue(item);
    if (subject != null) subjects.add(subject);
  }
  return subjects;
}

BangumiSubject parseBangumiSubject(String body) {
  final BangumiSubject? subject = _parseBangumiSubjectValue(jsonDecode(body));
  if (subject == null) throw const FormatException('Invalid Bangumi subject');
  return subject;
}

BangumiUser parseBangumiUser(String body) {
  final Map<String, dynamic>? json = _map(jsonDecode(body));
  if (json == null) throw const FormatException('Invalid Bangumi user');
  final String username = _string(json['username']);
  if (username.isEmpty) {
    throw const FormatException('Bangumi user has no username');
  }
  return BangumiUser(
    username: username,
    nickname: _string(json['nickname']),
  );
}

BangumiUserCollection parseBangumiCollection(String body) {
  final Map<String, dynamic>? json = _map(jsonDecode(body));
  if (json == null) throw const FormatException('Invalid Bangumi collection');
  return BangumiUserCollection(
    type: _int(json['type']),
    episodeProgress: _int(json['ep_status']),
    volumeProgress: _int(json['vol_status']),
  );
}

BangumiWatchedPage parseBangumiWatchedPage(String body) {
  final Map<String, dynamic>? root = _map(jsonDecode(body));
  if (root == null) {
    throw const FormatException('Invalid Bangumi collection page');
  }
  final List<BangumiWatchedItem> items = <BangumiWatchedItem>[];
  final dynamic data = root['data'];
  if (data is List) {
    for (final dynamic item in data) {
      final Map<String, dynamic>? collection = _map(item);
      if (collection == null || _int(collection['type']) != 2) continue;
      final Map<String, dynamic>? subjectValue = _map(collection['subject']);
      if (subjectValue == null) continue;
      final BangumiSubject? subject = _parseBangumiSubjectValue(subjectValue);
      if (subject == null || subject.type != 2) continue;
      items.add(
        BangumiWatchedItem(
          subject: subject,
          episodeProgress: _int(collection['ep_status']),
          updatedAt: DateTime.tryParse(_string(collection['updated_at'])),
        ),
      );
    }
  }
  return (
    items: items,
    total: _int(root['total'], items.length),
    limit: _int(root['limit'], items.length),
    offset: _int(root['offset']),
  );
}

({List<BangumiEpisode> episodes, int total}) parseBangumiEpisodes(String body) {
  final Map<String, dynamic>? root = _map(jsonDecode(body));
  if (root == null) throw const FormatException('Invalid Bangumi episodes');
  final dynamic data = root['data'];
  final List<BangumiEpisode> episodes = <BangumiEpisode>[];
  if (data is List) {
    for (final dynamic item in data) {
      final Map<String, dynamic>? value = _map(item);
      if (value == null) continue;
      final int id = _int(value['id']);
      final num? sort = value['sort'] is num ? value['sort'] as num : null;
      if (id <= 0 || sort == null) continue;
      episodes.add(
        BangumiEpisode(
          id: id,
          type: _int(value['type']),
          sort: sort.toDouble(),
        ),
      );
    }
  }
  return (episodes: episodes, total: _int(root['total'], episodes.length));
}

abstract interface class BangumiTrackingApi {
  Future<BangumiUser> getMe();

  Future<List<BangumiWatchedItem>> getWatchedAnime(String username);

  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  });

  Future<BangumiSubject> getSubject(int subjectId);

  Future<BangumiUserCollection?> getCollection(
    String username,
    int subjectId,
  );

  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  });

  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  });

  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId);

  Future<void> markEpisodesDone(int subjectId, List<int> episodeIds);

  void close();
}

/// Bangumi v0 API 的窄客户端。token 只进 Authorization header，从不拼 URL/异常文本。
class BangumiApiClient implements BangumiTrackingApi {
  BangumiApiClient({
    required String accessToken,
    required String userAgent,
    http.Client? client,
  })  : _accessToken = accessToken.trim(),
        _userAgent = userAgent,
        _client = client ?? createAppHttpIoClient();

  static const String apiBase = 'https://api.bgm.tv';
  static const String accessTokenUrl = 'https://next.bgm.tv/demo/access-token';

  /// 注册入口。[accessTokenUrl] 需要先登录才能生成令牌，没有账号的用户在那里会被
  /// 挡在登录页，因此另给一个注册入口，两者并存而不是互相替代。
  static const String signupUrl = 'https://bgm.tv/signup';

  /// 条目网页地址（首页/设置页「在 Bangumi 打开」用；api.bgm.tv 是纯 JSON 接口，
  /// 给用户看的必须是 bgm.tv 的人类页面）。
  static String subjectUrl(int subjectId) =>
      'https://bgm.tv/subject/$subjectId';

  final String _accessToken;
  final String _userAgent;
  final http.Client _client;

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
        if (_accessToken.isNotEmpty) 'Authorization': 'Bearer $_accessToken',
      };

  @override
  Future<BangumiUser> getMe() async {
    final http.Response response = await _client.get(
      Uri.parse('$apiBase/v0/me'),
      headers: _headers,
    );
    _require(response, const <int>{200});
    return parseBangumiUser(_body(response));
  }

  @override
  Future<List<BangumiWatchedItem>> getWatchedAnime(String username) async {
    const int pageSize = 50;
    int offset = 0;
    int total = pageSize;
    final List<BangumiWatchedItem> all = <BangumiWatchedItem>[];
    final String encodedUsername = Uri.encodeComponent(username);
    while (offset < total) {
      final Uri uri = Uri.parse(
        '$apiBase/v0/users/$encodedUsername/collections',
      ).replace(
        queryParameters: <String, String>{
          'subject_type': '2',
          'type': '2',
          'limit': '$pageSize',
          'offset': '$offset',
        },
      );
      final http.Response response = await _client.get(uri, headers: _headers);
      _require(response, const <int>{200});
      final BangumiWatchedPage page = parseBangumiWatchedPage(_body(response));
      all.addAll(page.items);
      total = page.total;
      if (page.items.isEmpty) break;
      offset += page.limit > 0 ? page.limit : page.items.length;
    }
    return all;
  }

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async {
    final String query = keyword.trim();
    if (query.isEmpty) return const <BangumiSubject>[];
    final http.Response response = await _client.post(
      Uri.parse('$apiBase/v0/search/subjects?limit=20&offset=0'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'keyword': query,
        'sort': 'match',
        'filter': <String, dynamic>{
          'type': <int>[subjectType],
        },
      }),
    );
    _require(response, const <int>{200});
    return parseBangumiSubjectSearch(_body(response));
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    final http.Response response = await _client.get(
      Uri.parse('$apiBase/v0/subjects/$subjectId'),
      headers: _headers,
    );
    _require(response, const <int>{200});
    return parseBangumiSubject(_body(response));
  }

  @override
  Future<BangumiUserCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    final String encodedUsername = Uri.encodeComponent(username);
    final http.Response response = await _client.get(
      Uri.parse('$apiBase/v0/users/$encodedUsername/collections/$subjectId'),
      headers: _headers,
    );
    if (response.statusCode == 404) return null;
    _require(response, const <int>{200});
    return parseBangumiCollection(_body(response));
  }

  @override
  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    final http.Response response = await _client.post(
      Uri.parse('$apiBase/v0/users/-/collections/$subjectId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _require(response, const <int>{204});
  }

  @override
  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    final http.Response response = await _client.patch(
      Uri.parse('$apiBase/v0/users/-/collections/$subjectId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _require(response, const <int>{204});
  }

  @override
  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId) async {
    const int pageSize = 200;
    int offset = 0;
    int total = pageSize;
    final List<BangumiEpisode> all = <BangumiEpisode>[];
    while (offset < total) {
      final http.Response response = await _client.get(
        Uri.parse(
          '$apiBase/v0/episodes?subject_id=$subjectId'
          '&type=0&limit=$pageSize&offset=$offset',
        ),
        headers: _headers,
      );
      _require(response, const <int>{200});
      final ({List<BangumiEpisode> episodes, int total}) page =
          parseBangumiEpisodes(_body(response));
      all.addAll(page.episodes.where((BangumiEpisode e) => e.type == 0));
      total = page.total;
      if (page.episodes.isEmpty) break;
      offset += page.episodes.length;
    }
    all.sort((BangumiEpisode a, BangumiEpisode b) => a.sort.compareTo(b.sort));
    return all;
  }

  @override
  Future<void> markEpisodesDone(
    int subjectId,
    List<int> episodeIds,
  ) async {
    if (episodeIds.isEmpty) return;
    final http.Response response = await _client.patch(
      Uri.parse('$apiBase/v0/users/-/collections/$subjectId/episodes'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'episode_id': episodeIds,
        'type': 2,
      }),
    );
    _require(response, const <int>{204});
  }

  String _body(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  void _require(http.Response response, Set<int> accepted) {
    if (accepted.contains(response.statusCode)) return;
    final String body = _body(response).trim();
    String message = body;
    try {
      final Map<String, dynamic>? json = _map(jsonDecode(body));
      message = _string(json?['description']);
      if (message.isEmpty) message = _string(json?['title']);
    } catch (_) {
      // 保留截断后的原始文本；token 从未进入 URL/body，故不会被带入异常。
    }
    if (message.isEmpty) message = response.reasonPhrase ?? 'Request failed';
    if (message.length > 300) message = message.substring(0, 300);
    throw BangumiApiException(
      statusCode: response.statusCode,
      message: message,
    );
  }

  @override
  void close() => _client.close();
}
