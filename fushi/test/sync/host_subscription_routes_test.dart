import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart';
import 'package:shelf/shelf.dart' as shelf;

/// `/api/subscriptions` 路由层：请求形状校验、分发、错误映射（host 实现用假的）。
class _FakeHost implements HostSubscriptionHost {
  final List<String> calls = <String>[];
  final Map<String, VideoDownloadSubscriptionRow> rows =
      <String, VideoDownloadSubscriptionRow>{};
  HostSubscriptionCreateRequest? lastCreate;

  VideoDownloadSubscriptionRow _row(
          String id, HostSubscriptionCreateRequest r) =>
      VideoDownloadSubscriptionRow(
        subscriptionId: id,
        resourceProvider: r.resourceProvider,
        mediaKind: r.mediaKind,
        title: r.title,
        identityJson: r.identityJson,
        searchQuery: r.searchQuery,
        filterJson: r.filterJson,
        mode: r.effectiveMode,
        startAfterEpisode: r.startAfterEpisode,
        backendKind: 'embedded',
        backendProfileId: 'embedded',
        fingerprint: 'fp',
        category: 'fushi',
        targetSourceId: 1,
        organizationPolicy: 'library',
        subtitlePolicy: r.subtitlePolicy,
        enabled: true,
        retryCount: 0,
        createdAt: 1,
        updatedAt: 1,
      );

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
        'supported': true,
        'backend': 'embedded',
        'providers': <String>['nyaa']
      };

  @override
  Future<List<VideoDownloadSubscriptionRow>> list() async =>
      rows.values.toList();

  @override
  Future<Map<String, Map<String, int>>> itemCounts() async =>
      <String, Map<String, int>>{
        for (final String id in rows.keys) id: <String, int>{'queued': 2},
      };

  @override
  Future<VideoDownloadSubscriptionRow> create(
      HostSubscriptionCreateRequest request) async {
    calls.add('create');
    lastCreate = request;
    if (!request.resourceProvider.startsWith('nyaa')) {
      throw HostSubscriptionRejected(
          400, 'provider_unavailable', 'no ${request.resourceProvider}');
    }
    final String id = request.subscriptionId ?? 'gen';
    return rows[id] = _row(id, request);
  }

  @override
  Future<void> setEnabled(String subscriptionId, bool enabled) async {
    calls.add('enable:$subscriptionId:$enabled');
    if (!rows.containsKey(subscriptionId)) {
      throw const HostSubscriptionRejected(404, 'not_found', 'nope');
    }
  }

  @override
  Future<void> checkNow(String? subscriptionId) async =>
      calls.add('check:${subscriptionId ?? '*'}');

  @override
  Future<void> delete(String subscriptionId) async {
    calls.add('delete:$subscriptionId');
    rows.remove(subscriptionId);
  }
}

Future<shelf.Response> _call(
  _FakeHost host,
  String method,
  String path, {
  Object? body,
}) {
  final shelf.Request request = shelf.Request(
    method,
    Uri.parse('http://h$path'),
    body: body == null ? null : jsonEncode(body),
    headers: const <String, String>{'content-type': 'application/json'},
  );
  return handleHostSubscriptionRequest(host, request, method, path);
}

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map);

void main() {
  test('POST 创建：必填校验 400，成功回 subscription，可选字段原样透传', () async {
    final _FakeHost host = _FakeHost();
    expect(
        (await _call(host, 'POST', '/api/subscriptions',
                body: <String, Object?>{'title': 'x'}))
            .statusCode,
        400);
    expect(
      (await _call(host, 'POST', '/api/subscriptions', body: <String, Object?>{
        'title': 'x',
        'searchQuery': 'q',
        'mediaKind': 'ova',
        'resourceProvider': 'nyaa:nyaa.si',
      }))
          .statusCode,
      400,
      reason: 'mediaKind 只认 movie / tv',
    );
    expect(
      (await _call(host, 'POST', '/api/subscriptions', body: <String, Object?>{
        'title': 'x',
        'searchQuery': 'q',
        'mediaKind': 'tv',
        'resourceProvider': 'nyaa:nyaa.si',
        'metadataProvider': 'mal',
      }))
          .statusCode,
      400,
      reason: 'metadataProvider / externalId 必须成对',
    );
    final shelf.Response ok =
        await _call(host, 'POST', '/api/subscriptions', body: <String, Object?>{
      'title': 'Frieren',
      'searchQuery': 'Frieren 1080p',
      'mediaKind': 'tv',
      'resourceProvider': 'nyaa:nyaa.si',
      'subscriptionId': 'video-discovery-abc',
      'identityJson': '{"providerId":"mal"}',
      'metadataProvider': 'mal',
      'externalId': '52991',
      'startAfterEpisode': 3,
      'subtitlePolicy': 'required',
      'year': 2023,
    });
    expect(ok.statusCode, 200);
    final Map<String, dynamic> body = await _json(ok);
    expect(body['subscription']['subscriptionId'], 'video-discovery-abc');
    expect(body['subscription']['mode'], 'ongoing', reason: 'tv 缺省 ongoing');
    expect(host.lastCreate!.startAfterEpisode, 3);
    expect(host.lastCreate!.subtitlePolicy, 'required');
    expect(host.lastCreate!.year, 2023);
    expect(host.lastCreate!.identityJson, '{"providerId":"mal"}');
  });

  test('provider 不在 host 上 → 400 + reason=provider_unavailable', () async {
    final _FakeHost host = _FakeHost();
    final shelf.Response r =
        await _call(host, 'POST', '/api/subscriptions', body: <String, Object?>{
      'title': 'x',
      'searchQuery': 'q',
      'mediaKind': 'movie',
      'resourceProvider': 'torznab:jackett',
    });
    expect(r.statusCode, 400);
    expect((await _json(r))['reason'], 'provider_unavailable');
  });

  test('GET 列表带 itemCounts；enable/check/delete 分发；未知 id 404', () async {
    final _FakeHost host = _FakeHost();
    await _call(host, 'POST', '/api/subscriptions', body: <String, Object?>{
      'title': 'x',
      'searchQuery': 'q',
      'mediaKind': 'movie',
      'resourceProvider': 'nyaa:nyaa.si',
      'subscriptionId': 's1',
    });
    final Map<String, dynamic> list =
        await _json(await _call(host, 'GET', '/api/subscriptions'));
    expect(list['subscriptions'], hasLength(1));
    expect(
        list['subscriptions'][0]['itemCounts'], <String, Object?>{'queued': 2});
    expect(list['subscriptions'][0].containsKey('fingerprint'), isFalse,
        reason: '后端四元组是 host 内部事，不出 wire');

    expect(
        (await _call(host, 'POST', '/api/subscriptions/s1/enable',
                body: <String, Object?>{'enabled': false}))
            .statusCode,
        200);
    expect(
        (await _call(host, 'POST', '/api/subscriptions/s1/enable',
                body: <String, Object?>{'enabled': 'no'}))
            .statusCode,
        400);
    expect(
        (await _call(host, 'POST', '/api/subscriptions/s1/check')).statusCode,
        200);
    expect((await _call(host, 'POST', '/api/subscriptions/check')).statusCode,
        200);
    expect(
        (await _call(host, 'POST', '/api/subscriptions/nope/enable',
                body: <String, Object?>{'enabled': true}))
            .statusCode,
        404);
    expect(
        (await _call(host, 'DELETE', '/api/subscriptions/s1')).statusCode, 200);
    expect((await _call(host, 'GET', '/api/subscriptions/s1')).statusCode, 405);
    expect(host.calls, <String>[
      'create',
      'enable:s1:false',
      'check:s1',
      'check:*',
      'enable:nope:true',
      'delete:s1'
    ]);
  });
}
