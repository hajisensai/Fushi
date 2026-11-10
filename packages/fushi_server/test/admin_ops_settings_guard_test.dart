// 远端 AI 助手的 `server.settings.set` 只许改 [kServerAgentSettingKeys]：
// `/api/admin/settings` 同一个端点还收凭据（TMDB / AI / qBittorrent 的 key 与密码）和
// 要重启的项（端口、监听地址…）。
//
// 两道闸：模型实际走的 [OpInvoker] 先按操作声明的参数拒掉未声明的键（`未知参数`），
// 路由 handler 再按白名单兜底（直接调 handler、绕过目录校验时也不转发）。声明的参数
// 必须与白名单逐项一致，否则两道闸会悄悄分叉。
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String kSecret = 'agent-guard-secret-value';

void main() {
  late List<String> forwarded;
  late CtlRoute route;

  setUp(() {
    forwarded = <String>[];
    route =
        buildServerAdminOps(
          () => (shelf.Request request) async {
            forwarded.add(await request.readAsString());
            return shelf.Response.ok(
              '{}',
              headers: const <String, String>{
                'Content-Type': 'application/json',
              },
            );
          },
        ).routes.firstWhere(
          (CtlRoute r) =>
              r.method == 'PUT' && r.pattern == '/api/admin/settings',
        );
  });

  Future<Object?> invoke(Map<String, Object?> body) => route.handler(
    CtlCall(
      method: 'PUT',
      path: '/api/admin/settings',
      body: body,
      fromModel: true,
    ),
  );

  test('凭据 / 要重启的项一律 400、不转发、消息不带值', () async {
    for (final Map<String, Object?> body in <Map<String, Object?>>[
      <String, Object?>{'tmdbApiKey': kSecret},
      <String, Object?>{
        'subtitleLanguage': 'en',
        'ai': <String, Object?>{'apiKey': kSecret},
      },
      <String, Object?>{
        'qbittorrent': <String, Object?>{'password': kSecret},
      },
      <String, Object?>{'port': 1},
      <String, Object?>{'bind': '0.0.0.0'},
    ]) {
      await expectLater(
        invoke(body),
        throwsA(
          isA<CtlFailure>()
              .having((CtlFailure f) => f.status, 'status', 400)
              .having(
                (CtlFailure f) => f.message ?? '',
                'message',
                isNot(contains(kSecret)),
              ),
        ),
        reason: '$body',
      );
    }
    expect(forwarded, isEmpty);
  });

  test('模型经 OpInvoker 调用：凭据 / 要重启的项 400、不转发', () async {
    final OpInvoker invoker = OpInvoker(
      buildServerAdminOpCatalog(
        () => (shelf.Request request) async {
          forwarded.add(await request.readAsString());
          return shelf.Response.ok(
            '{}',
            headers: const <String, String>{'Content-Type': 'application/json'},
          );
        },
      ),
    );
    for (final Map<String, Object?> args in <Map<String, Object?>>[
      <String, Object?>{'tmdbApiKey': kSecret},
      <String, Object?>{
        'subtitleLanguage': 'en',
        'ai': <String, Object?>{'apiKey': kSecret},
      },
      <String, Object?>{'port': 1},
    ]) {
      await expectLater(
        invoker.invoke('server.settings.set', args, caller: OpCaller.model),
        throwsA(
          isA<CtlFailure>()
              .having((CtlFailure f) => f.status, 'status', 400)
              .having(
                (CtlFailure f) => f.message ?? '',
                'message',
                isNot(contains(kSecret)),
              ),
        ),
        reason: '$args',
      );
    }
    expect(forwarded, isEmpty);
    await invoker.invoke('server.settings.set', <String, Object?>{
      'scanPrune': true,
    }, caller: OpCaller.model);
    expect(forwarded, hasLength(1));
  });

  test('server.settings.set 声明的参数与白名单逐项一致', () {
    final OpDescription description =
        buildServerAdminOps(
          () =>
              (shelf.Request request) async => shelf.Response.ok('{}'),
        ).descriptions.firstWhere(
          (OpDescription d) => d.id == 'server.settings.set',
        );
    expect(
      description.params.map((OpParam p) => p.name).toSet(),
      kServerAgentSettingKeys.toSet(),
    );
  });

  test('白名单里的每一项照常转发', () async {
    for (final String key in kServerAgentSettingKeys) {
      forwarded.clear();
      await invoke(<String, Object?>{key: 'x'});
      expect(forwarded, hasLength(1), reason: key);
    }
  });
}
