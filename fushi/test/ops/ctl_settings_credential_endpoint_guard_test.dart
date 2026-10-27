import 'package:flutter/services.dart' show TextInputType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_settings_credential_endpoints.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_cli/fushi_cli.dart';

/// 走到「建设置索引」就说明模型这一关放行了（守卫只关心放没放行）。
class _PassedGate implements Exception {}

class _GateProbeRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw _PassedGate();
}

/// 带凭据服务的地址：模型（AI 助手）不可写（2026-10-27 审查，见
/// `lib/src/ops/ctl_settings_credential_endpoints.dart`）。
///
/// 保护集合**按结构自动枚举**（同一配置里有凭据 + 地址），本守卫不手列被保护的项：
/// 它对枚举出的**每一项**都实打实调一次路由，模型调用必须被拒、用户调用必须放行。
/// 新增带凭据的服务配置会自动进集合、自动被这里验到。
void main() {
  final CtlCredentialEndpoints endpoints = ctlCredentialEndpoints();
  final List<CtlRoute> routes = buildSettingsCtlRoutes(
    OpContext(ref: _GateProbeRef()),
  );

  CtlRoute route(String method, String pattern) => routes.singleWhere(
    (CtlRoute r) => r.method == method && r.pattern == pattern,
  );

  final CtlRoute set = route('PUT', '/api/admin/settings/:key');
  final CtlRoute update = route('PUT', '/api/admin/settings/:key/items/:id');
  final CtlRoute run = route('POST', '/api/admin/settings/:key/run');

  Future<void> expectModelRefused(
    CtlRoute r,
    String key,
    Map<String, Object?> body,
  ) async {
    await expectLater(
      r.handler(
        CtlCall(
          method: r.method,
          path: r.pattern,
          params: <String, String>{'key': key, 'id': 'x'},
          body: body,
          fromModel: true,
        ),
      ),
      throwsA(
        isA<CtlFailure>().having(
          (CtlFailure f) => f.message,
          'message',
          contains('凭据'),
        ),
      ),
      reason: '$key：模型改带凭据服务的地址必须被拒',
    );
  }

  Future<void> expectPassed(
    CtlRoute r,
    String key,
    Map<String, Object?> body, {
    bool fromModel = false,
  }) async {
    await expectLater(
      r.handler(
        CtlCall(
          method: r.method,
          path: r.pattern,
          params: <String, String>{'key': key, 'id': 'x'},
          body: body,
          fromModel: fromModel,
        ),
      ),
      throwsA(isA<_PassedGate>()),
      reason: '$key：这次调用不该被凭据地址门拦下',
    );
  }

  test('枚举不是空的，且覆盖已知的几类服务（防判据退化）', () {
    expect(
      endpoints.valueKeys,
      containsAll(<String>[
        'downloads.cli.qb_url',
        'system.network_proxy',
        'card_creation.anki.cli.connect_host',
        'services.opensubtitles.cli.endpoint',
      ]),
    );
    expect(endpoints.listFields['services.opds_servers.cli.servers'], {'url'});
    expect(endpoints.listFields['services.alist_sites.cli.sites'], {'url'});
    // 列表本身不带密码、登录动作带：照样算。
    expect(
      endpoints.listFields['services.audiobookshelf_servers.cli.servers'],
      {'url'},
    );
    expect(endpoints.listFields['services.media_server.jellyfin'], {'url'});
    expect(endpoints.listFields['services.media_server.plex'], {'url'});
    expect(endpoints.listFields['services.torznab.cli.indexers'], {'endpoint'});
    expect(endpoints.actionParams['card_creation.anki.sync_client.sign_in'], {
      'server',
    });
    // 没有凭据的地址不拦（弹幕服务器、联网资料站点）。
    expect(endpoints.valueKeys, isNot(contains('services.danmaku.server_url')));
    expect(
      endpoints.listFields.keys,
      isNot(contains('ai.web_knowledge.custom')),
    );
  });

  test('枚举出的每个值设置项：模型 settings.set 被拒，用户照常', () async {
    for (final String key in endpoints.valueKeys) {
      await expectModelRefused(set, key, <String, Object?>{
        'value': 'https://evil.example/',
      });
      await expectPassed(set, key, <String, Object?>{
        'value': 'https://nas.local/',
      });
    }
  });

  test('枚举出的每个记录列表：模型改地址字段被拒，改别的字段 / 用户改照常', () async {
    for (final MapEntry<String, Set<String>> e
        in endpoints.listFields.entries) {
      for (final String field in e.value) {
        await expectModelRefused(update, e.key, <String, Object?>{
          'args': <String, Object?>{field: 'https://evil.example/'},
        });
        // spread 写法（字段铺在 body 顶层）同样拦。
        await expectModelRefused(update, e.key, <String, Object?>{
          field: 'https://evil.example/',
        });
        await expectPassed(update, e.key, <String, Object?>{
          'args': <String, Object?>{field: 'https://nas.local/'},
        });
      }
      await expectPassed(update, e.key, <String, Object?>{
        'args': <String, Object?>{'name': 'renamed'},
      }, fromModel: true);
    }
  });

  test('枚举出的每个动作：模型给地址参数被拒，用户照常', () async {
    for (final MapEntry<String, Set<String>> e
        in endpoints.actionParams.entries) {
      for (final String param in e.value) {
        await expectModelRefused(run, e.key, <String, Object?>{
          'args': <String, Object?>{param: 'https://evil.example/'},
        });
        await expectPassed(run, e.key, <String, Object?>{
          'args': <String, Object?>{param: 'https://nas.local/'},
        });
      }
    }
  });

  group('判据（纯函数）', () {
    SettingsTextItem text(
      String id, {
      bool secret = false,
      TextInputType? keyboardType,
    }) => SettingsTextItem(
      id: id,
      title: id,
      secret: secret,
      keyboardType: keyboardType,
      value: (_) => '',
      onChanged: (_, _) {},
    );

    test('同一配置有凭据 → 地址项（按名字或 URL 键盘）被保护；没凭据的配置不管', () {
      final CtlCredentialEndpoints c =
          classifyCtlCredentialEndpoints(<CtlSettingRow>[
            (breadcrumb: 'A', item: text('a.server_url')),
            (
              breadcrumb: 'A',
              item: text('a.gateway', keyboardType: TextInputType.url),
            ),
            (breadcrumb: 'A', item: text('a.title')),
            (breadcrumb: 'A', item: text('a.secret_value', secret: true)),
            (breadcrumb: 'B', item: text('b.server_url')),
          ]);
      expect(c.valueKeys, <String>{'a.server_url', 'a.gateway'});
    });

    test('名字判据：尾段整词，不误伤', () {
      for (final String yes in <String>[
        'x.qb_url',
        'x.connect_host',
        'x.endpoint',
        'x.network_proxy',
        'baseUrl',
        'serverAddress',
        'url',
      ]) {
        expect(isCtlAddressName(yes), isTrue, reason: yes);
      }
      for (final String no in <String>[
        'x.network_proxy_mode',
        'x.url_style',
        'x.ghosted',
        'x.transcode_host_enabled',
        'name',
      ]) {
        expect(isCtlAddressName(no), isFalse, reason: no);
      }
    });
  });
}
