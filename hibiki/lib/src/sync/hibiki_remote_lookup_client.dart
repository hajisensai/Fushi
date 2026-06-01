import 'dart:convert';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:http/http.dart' as http;

class HibikiRemoteLookupClient {
  HibikiRemoteLookupClient({
    required SyncRepository repo,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 3),
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final SyncRepository _repo;
  final http.Client _httpClient;
  final Duration _timeout;

  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final Map<String, dynamic>? json = await _postLookup(
      path: '/api/lookup/dictionary',
      body: <String, dynamic>{
        'term': term,
        'wildcards': wildcards,
        'maximumTerms': maximumTerms,
      },
    );
    if (json == null || json['type'] != 'dictionaryResult') return null;
    final dynamic resultJson = json['result'];
    if (resultJson is! Map) return null;
    final DictionarySearchResult result =
        _parseDictionaryResult(Map<String, dynamic>.from(resultJson));
    result.popupJson = json['popupJson']?.toString();
    return result.entries.isEmpty ? null : result;
  }

  DictionarySearchResult _parseDictionaryResult(Map<String, dynamic> json) {
    final List<DictionaryEntry> entries = <DictionaryEntry>[];
    final dynamic entriesJson = json['entries'];
    if (entriesJson is List) {
      for (final dynamic entry in entriesJson) {
        if (entry is String) {
          entries.add(DictionaryEntry.fromJson(entry));
        } else if (entry is Map) {
          entries.add(DictionaryEntry.fromJson(jsonEncode(entry)));
        }
      }
    }
    return DictionarySearchResult(
      searchTerm: json['searchTerm']?.toString() ?? '',
      bestLength: (json['bestLength'] as num?)?.toInt() ?? 0,
      scrollPosition: (json['scrollPosition'] as num?)?.toInt() ?? 0,
      entries: entries,
    );
  }

  Future<String?> lookupAudioUrl({
    required String expression,
    required String reading,
  }) async {
    final Map<String, dynamic>? json = await _postLookup(
      path: '/api/lookup/audio',
      body: <String, dynamic>{
        'expression': expression,
        'reading': reading,
      },
    );
    if (json == null || json['type'] != 'audioResult') return null;
    final String? url = json['url'] as String?;
    return (url == null || url.isEmpty) ? null : url;
  }

  Future<Map<String, dynamic>?> _postLookup({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    if (candidates.isEmpty || token == null || token.isEmpty) return null;

    for (final HibikiClientUrl candidate in candidates) {
      final Uri? uri = _lookupUri(candidate.url, path);
      if (uri == null) continue;
      try {
        final http.Response response = await _httpClient
            .post(
              uri,
              headers: <String, String>{
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(_timeout);
        if (response.statusCode == 401) {
          throw SyncAuthError('Hibiki server rejected remote lookup token');
        }
        if (response.statusCode == 404 || response.statusCode == 405) {
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on SyncAuthError {
        rethrow;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Uri? _lookupUri(String baseUrl, String path) {
    try {
      final Uri base = Uri.parse(WebDavOps.normalizeUrl(baseUrl));
      return base
          .replace(path: path, queryParameters: const <String, String>{});
    } catch (_) {
      return null;
    }
  }
}
