// 远端 AI 助手的 `server.settings.set` 只许改 [kServerAgentSettingKeys]：
// `/api/admin/settings` 同一个端点还收凭据（TMDB / AI / qBittorrent 的 key 与密码）和
// 要重启的项（端口、监听地址…）。之前这条操作把整个 body 原样转发，描述里列的白名单
// 没有任何地方执行。
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

  test('白名单里的每一项照常转发', () async {
    for (final String key in kServerAgentSettingKeys) {
      forwarded.clear();
      await invoke(<String, Object?>{key: 'x'});
      expect(forwarded, hasLength(1), reason: key);
    }
  });
}
