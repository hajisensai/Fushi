import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';

const int kDandanplayHashPrefixBytes = 16 * 1024 * 1024;

enum DandanplayFetchStatus {
  hit,
  noMatch,
  needsSelection,
  networkError,
  serverError,
}

class DandanplayMatch {
  const DandanplayMatch({
    required this.episodeId,
    this.animeTitle,
    this.episodeTitle,
    this.shiftSeconds = 0,
  });

  final int episodeId;
  final String? animeTitle;
  final String? episodeTitle;
  final double shiftSeconds;

  static DandanplayMatch? fromJson(Map<dynamic, dynamic> json) {
    final Object? id = json['episodeId'];
    if (id is! num) return null;
    return DandanplayMatch(
      episodeId: id.toInt(),
      animeTitle: json['animeTitle']?.toString(),
      episodeTitle: json['episodeTitle']?.toString(),
      shiftSeconds:
          json['shift'] is num ? (json['shift'] as num).toDouble() : 0,
    );
  }
}

class DandanplayFetchResult {
  const DandanplayFetchResult({
    required this.status,
    this.items = const <VideoDanmakuItem>[],
    this.matches = const <DandanplayMatch>[],
    this.match,
    this.error,
  });

  final DandanplayFetchStatus status;
  final List<VideoDanmakuItem> items;
  final List<DandanplayMatch> matches;
  final DandanplayMatch? match;
  final Object? error;
}

class DandanplayClient {
  DandanplayClient({
    http.Client? httpClient,
    Uri? baseUri,
    Duration timeout = const Duration(seconds: 8),
  })  : _client = httpClient ?? http.Client(),
        _baseUri = baseUri ?? Uri.parse('https://api.dandanplay.net'),
        _timeout = timeout;

  final http.Client _client;
  final Uri _baseUri;
  final Duration _timeout;

  void close() => _client.close();

  Future<DandanplayFetchResult> fetchBestDanmakuForFile(File file) async {
    try {
      final DandanplayFetchResult matched = await matchFile(file);
      if (matched.status != DandanplayFetchStatus.hit ||
          matched.match == null) {
        return matched;
      }
      final List<VideoDanmakuItem> items =
          await fetchCommentsForMatch(matched.match!);
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.hit,
        items: items,
        match: matched.match,
        matches: matched.matches,
      );
    } on SocketException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } on http.ClientException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } on TimeoutException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: e,
      );
    }
  }

  Future<DandanplayFetchResult> matchFile(File file) async {
    final Uri uri = _baseUri.replace(path: '/api/v2/match');
    final Map<String, dynamic> body = <String, dynamic>{
      'fileName': p.basenameWithoutExtension(file.path),
      'fileHash': await dandanplayFileHash(file),
      'fileSize': file.lengthSync(),
      'matchMode': 'hashAndFileName',
    };
    final http.Response response = await _client
        .post(
          uri,
          headers: const <String, String>{
            HttpHeaders.contentTypeHeader: 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: response.statusCode,
      );
    }
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return const DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
      );
    }
    if (decoded['success'] == false) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: decoded['errorMessage'],
      );
    }
    final List<DandanplayMatch> matches = _matchesFromJson(decoded['matches']);
    if (matches.isEmpty) {
      return const DandanplayFetchResult(status: DandanplayFetchStatus.noMatch);
    }
    if (decoded['isMatched'] == true && matches.length == 1) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.hit,
        matches: matches,
        match: matches.single,
      );
    }
    return DandanplayFetchResult(
      status: DandanplayFetchStatus.needsSelection,
      matches: matches,
    );
  }

  Future<List<VideoDanmakuItem>> fetchCommentsForMatch(
    DandanplayMatch match,
  ) async {
    final Uri uri = _baseUri.replace(
      path: '/api/v2/comment/${match.episodeId}',
      queryParameters: const <String, String>{
        'withRelated': 'true',
      },
    );
    final http.Response response = await _client.get(uri).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const <VideoDanmakuItem>[];
    }
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) return const <VideoDanmakuItem>[];
    final dynamic comments = decoded['comments'];
    if (comments is! List) return const <VideoDanmakuItem>[];
    return dandanplayCommentsToDanmaku(
      comments,
      shiftMs: (match.shiftSeconds * 1000).round(),
    );
  }
}

Future<String> dandanplayFileHash(File file) async {
  final int length = file.lengthSync();
  final int end = math.min(length, kDandanplayHashPrefixBytes);
  final Digest digest = await md5.bind(file.openRead(0, end)).first;
  return digest.toString();
}

List<DandanplayMatch> _matchesFromJson(Object? raw) {
  if (raw is! List) return const <DandanplayMatch>[];
  return raw
      .whereType<Map>()
      .map(DandanplayMatch.fromJson)
      .whereType<DandanplayMatch>()
      .toList(growable: false);
}
