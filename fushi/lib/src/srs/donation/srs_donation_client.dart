/// 复习历史捐赠的 HTTP 客户端：`rank.fushi.moe` 上的 `/v1/srs-donations/:donorId`
/// （设计 `docs/specs/2026-11-26-srs-review-donation.md`「服务端」）。
///
/// - `PUT`：body 是 apkg 原始字节（流式上传，带进度），头 `x-donation-reviews` /
///   `x-donation-cards` / `x-donation-app-version`；
/// - `GET`：查状态；
/// - `DELETE`：撤回（幂等）。
///
/// 三个请求都带 `Authorization: Bearer <donorKey>`。失败抛 [SrsDonationHttpException]，
/// 不自动重试（界面给「重试」按钮）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/leaderboard/leaderboard_endpoint.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';

/// 查询 / 撤回的超时。
const Duration kSrsDonationRequestTimeout = Duration(seconds: 30);

/// 上传的超时（整包上传 + 服务端写 R2；包上限 64 MiB）。
const Duration kSrsDonationUploadTimeout = Duration(minutes: 10);

/// 服务端状态（GET 与 PUT 成功响应同一形状：`{donated: false}` 或
/// `{donated: true, reviews, cards, updatedAt}`）。捐过时三项都必须有，缺了按坏响应处理，
/// 不拿 0 / 现在时刻顶上（那样会显示「捐出 0 次」）。
class SrsDonationStatus {
  const SrsDonationStatus.none() : donation = null;
  const SrsDonationStatus.donated(SrsDonationRecord this.donation);

  /// null = 没捐过 / 已撤回。
  final SrsDonationRecord? donation;

  bool get donated => donation != null;

  /// 解析服务端 JSON；`donated == true` 却缺字段时抛 [FormatException]。
  factory SrsDonationStatus.fromJson(Map<String, Object?> json) {
    if (json['donated'] != true) return const SrsDonationStatus.none();
    final int? reviews = _int(json['reviews']);
    final int? cards = _int(json['cards']);
    final DateTime? updatedAt = _time(json['updatedAt']);
    if (reviews == null || cards == null || updatedAt == null) {
      throw const FormatException('incomplete donation status');
    }
    return SrsDonationStatus.donated((
      reviews: reviews,
      cards: cards,
      updatedAt: updatedAt,
    ));
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static DateTime? _time(Object? v) {
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if (v is String) return DateTime.tryParse(v);
    return null;
  }
}

/// 请求失败：[statusCode] 为 null 表示网络层失败（连不上 / 超时 / 响应不是 JSON）。
class SrsDonationHttpException implements Exception {
  const SrsDonationHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'SrsDonationHttpException: $message'
      : 'SrsDonationHttpException($statusCode): $message';
}

/// 上传进度：已发送字节、总字节。
typedef SrsDonationProgress = void Function(int sent, int total);

/// 捐赠接口客户端。[clientFactory] 每次请求建一个 [http.Client]、用完关掉（生产是
/// [createAppHttpIoClient]，走全应用代理装配；测试注入 `MockClient`）。
class SrsDonationClient {
  SrsDonationClient({http.Client Function()? clientFactory, Uri? baseUrl})
    : _clientFactory = clientFactory ?? createAppHttpIoClient,
      _baseUrl = baseUrl ?? Uri.parse(kLeaderboardDefaultBaseUrl);

  final http.Client Function() _clientFactory;
  final Uri _baseUrl;

  Uri _uri(String donorId) =>
      _baseUrl.resolve('/v1/srs-donations/${Uri.encodeComponent(donorId)}');

  static Map<String, String> _auth(String donorKey) => <String, String>{
    'Authorization': 'Bearer $donorKey',
    'Accept': 'application/json',
  };

  /// 查状态；无记录时 `donated == false`。
  Future<SrsDonationStatus> status({
    required String donorId,
    required String donorKey,
  }) => _run((http.Client client) async {
    final http.Response res = await client
        .get(_uri(donorId), headers: _auth(donorKey))
        .timeout(kSrsDonationRequestTimeout);
    return _parse(res.statusCode, res.bodyBytes);
  });

  /// 上传（同一 donorId 覆盖旧文件）。
  Future<SrsDonationStatus> upload({
    required String donorId,
    required String donorKey,
    required File file,
    required int reviews,
    required int cards,
    required String appVersion,
    SrsDonationProgress? onProgress,
  }) => _run((http.Client client) async {
    final int total = await file.length();
    final http.StreamedRequest req = http.StreamedRequest('PUT', _uri(donorId))
      ..contentLength = total
      ..headers.addAll(<String, String>{
        ..._auth(donorKey),
        'Content-Type': 'application/octet-stream',
        'x-donation-reviews': '$reviews',
        'x-donation-cards': '$cards',
        'x-donation-app-version': appVersion,
      });
    onProgress?.call(0, total);
    // 先发请求再灌 body：StreamedRequest 的 body 由 send 消费。
    final Future<http.StreamedResponse> sent = client.send(req);
    unawaited(() async {
      int done = 0;
      try {
        await for (final List<int> chunk in file.openRead()) {
          req.sink.add(chunk);
          done += chunk.length;
          onProgress?.call(done, total);
        }
      } catch (e, stack) {
        req.sink.addError(e, stack);
      } finally {
        await req.sink.close();
      }
    }());
    final http.StreamedResponse res = await sent.timeout(
      kSrsDonationUploadTimeout,
    );
    final List<int> body = await res.stream.toBytes().timeout(
      kSrsDonationRequestTimeout,
    );
    return _parse(res.statusCode, body);
  });

  /// 撤回：服务端删文件、记撤回清单；无记录也成功。
  Future<void> withdraw({required String donorId, required String donorKey}) =>
      _run((http.Client client) async {
        final http.Response res = await client
            .delete(_uri(donorId), headers: _auth(donorKey))
            .timeout(kSrsDonationRequestTimeout);
        _parse(res.statusCode, res.bodyBytes);
      });

  Future<T> _run<T>(Future<T> Function(http.Client client) body) async {
    final http.Client client = _clientFactory();
    try {
      return await body(client);
    } on SrsDonationHttpException {
      rethrow;
    } on TimeoutException catch (e) {
      throw SrsDonationHttpException('timeout: ${e.message ?? ''}');
    } on Object catch (e) {
      throw SrsDonationHttpException('$e');
    } finally {
      client.close();
    }
  }

  static SrsDonationStatus _parse(int statusCode, List<int> body) {
    final String text = utf8.decode(body, allowMalformed: true);
    if (statusCode < 200 || statusCode >= 300) {
      throw SrsDonationHttpException(
        text.length > 200 ? text.substring(0, 200) : text,
        statusCode: statusCode,
      );
    }
    try {
      final Object? json = jsonDecode(text);
      if (json is Map<String, Object?>) return SrsDonationStatus.fromJson(json);
    } on FormatException {
      // 落到下面统一报错。
    }
    throw SrsDonationHttpException('unexpected response: $statusCode');
  }
}
