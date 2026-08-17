/// shinnku.com（真红小站）的发现源 adapter。
///
/// 该站没有公开 JSON API：搜索走 Next.js `/search?q=` 页面的 RSC 载荷
/// （`RSC: 1` 请求头），从流里按括号配平抽出 `"answer":[...]` 数组——站点
/// 前后端开源（shinnku-nikaidou/shinnku-com），条目结构
/// `{id, info:{file_path, upload_timestamp, file_size}}` 与下载直链推导规则
/// 均以其 `frontend/lib/url.ts` 为准：
///
/// - `合集系列/...` → `https://galgamedownload.date/`（B2 桶，首段带反引号前缀）
/// - 其余 → `https://zd.shinnku.top/file/shinnku/<路径>`
///
/// RSC 解析天生脆弱（站点改版即断）：解析不出按 invalidResponse 失败亮在
/// 源徽标上，不影响其它源。直链列表阶段即可推导 → payload 随条目带，
/// 不需要 resolvePayload。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/utils/net/app_http.dart';

class ShinnkuDiscoverySource extends MediaDiscoverySource {
  ShinnkuDiscoverySource({
    this.id = 'shinnku',
    this.displayName = '真红小站',
    this.priority = 30,
    String baseUrl = 'https://www.shinnku.com',
    http.Client? client,
  })  : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? createAppHttpIoClient();

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  final String _baseUrl;
  final http.Client _client;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: const <DiscoveryMediaKind>{DiscoveryMediaKind.game},
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    // 站点搜索无翻页（后端 n 上限一次给齐）；第 2 页起直接空页收尾。
    if (request.page > 1) {
      return ProviderBatchResult<DiscoveryResultPage>.success(
        <DiscoveryResultPage>[
          DiscoveryResultPage(
            entries: const <DiscoveryEntry>[],
            page: request.page,
            hasMore: false,
          ),
        ],
      );
    }
    final Uri uri = Uri.parse('$_baseUrl/search').replace(
      queryParameters: <String, String>{'q': request.query!.trim()},
    );
    final http.Response response = await _client.get(
      uri,
      headers: const <String, String>{'RSC': '1'},
    );
    if (response.statusCode != 200) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'search',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'http status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final String body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final List<dynamic>? answer = extractShinnkuAnswer(body);
    if (answer == null) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'search',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'RSC payload has no parsable answer array (site changed?)',
      );
    }
    final List<DiscoveryEntry> entries = <DiscoveryEntry>[];
    for (final dynamic raw in answer) {
      if (raw is! Map<String, dynamic>) continue;
      final Map<String, dynamic>? info = (raw['info'] as Map<String, dynamic>?);
      final String? filePath =
          info?['file_path'] as String? ?? raw['id'] as String?;
      if (filePath == null || filePath.trim().isEmpty) continue;
      final List<String> segments = filePath.split('/');
      final int? timestamp = (info?['upload_timestamp'] as num?)?.toInt();
      entries.add(
        DiscoveryResourceItem(
          sourceId: id,
          id: filePath,
          title: segments.last,
          kind: DiscoveryMediaKind.game,
          payloadKind: DiscoveryPayloadKind.httpFile,
          payload: DiscoveryHttpPayload(
            url: shinnkuDownloadUrl(filePath),
            fileName: segments.last,
            sizeBytes: (info?['file_size'] as num?)?.toInt(),
          ),
          sizeBytes: (info?['file_size'] as num?)?.toInt(),
          dateText: timestamp == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(timestamp)
                  .toLocal()
                  .toString()
                  .split(' ')
                  .first,
          detailUrl:
              '$_baseUrl/files/${segments.map(Uri.encodeComponent).join('/')}',
          note: shinnkuGameTypeNote(filePath),
        ),
      );
    }
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(entries: entries, page: 1, hasMore: false),
      ],
    );
  }

  @override
  void close() => _client.close();
}

/// 从 RSC 流里抽出第一个能解析的 `"answer":[...]` JSON 数组；抽不出返回 null。
///
/// RSC 载荷是多行 `序号:JSON` 流，答案数组内嵌其中。字符串内的 `[`/`]` 与
/// 转义符按 JSON 词法跳过，括号配平截取后交给 jsonDecode 复核。
List<dynamic>? extractShinnkuAnswer(String body) {
  const String marker = '"answer":';
  int searchFrom = 0;
  while (true) {
    final int markerIndex = body.indexOf(marker, searchFrom);
    if (markerIndex < 0) return null;
    searchFrom = markerIndex + marker.length;
    final int start = body.indexOf('[', markerIndex + marker.length);
    if (start < 0) return null;
    // marker 与 '[' 之间只允许空白，否则这不是数组值。
    if (body.substring(markerIndex + marker.length, start).trim().isNotEmpty) {
      continue;
    }
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (int i = start; i < body.length; i++) {
      final String ch = body[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) {
          try {
            final dynamic decoded = jsonDecode(body.substring(start, i + 1));
            if (decoded is List<dynamic>) return decoded;
          } on FormatException {
            // 配平截取的片段不是合法 JSON：继续找下一个 marker。
          }
          break;
        }
      }
    }
  }
}

/// 按上游 `frontend/lib/url.ts` 的规则推导下载直链。
String shinnkuDownloadUrl(String filePath) {
  final List<String> segments = filePath.split('/');
  if (segments.first == '合集系列') {
    // 上游 B2 桶路径首段字面量就带反引号前缀（照抄，别「修正」它）。
    final List<String> b2Path = <String>['`【合集系列】', ...segments.skip(1)];
    return 'https://galgamedownload.date/'
        '${b2Path.map(Uri.encodeComponent).join('/')}';
  }
  return 'https://zd.shinnku.top/file/shinnku/'
      '${segments.map(Uri.encodeComponent).join('/')}';
}

/// 按上游 `get_game_type` 的路径前缀规则给类型标注。
String shinnkuGameTypeNote(String filePath) {
  if (filePath.startsWith('合集系列')) return '生肉';
  if (filePath.startsWith('zd') || filePath.startsWith('0/win')) return '熟肉';
  return '手机';
}
