import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 防自环：本进程挂着 Fushi 的 AnkiConnect 兼容端点时，推 Anki 的地址若指回它自己就拒绝。
void main() {
  tearDown(() => fushiAnkiConnectCompatInstanceId = null);

  MockClient server({required Object? identify, List<String>? seen}) =>
      MockClient((http.Request req) async {
        final Map<String, Object?> body = (jsonDecode(req.body) as Map)
            .cast<String, Object?>();
        seen?.add(body['action']! as String);
        if (body['action'] == 'fushiIdentify') {
          return http.Response(jsonEncode(identify), 200);
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'result': <String>['Default'],
            'error': null,
          }),
          200,
        );
      });

  test('目标的 fushiIdentify 回本实例 id → 拒绝且不发真正的请求', () async {
    fushiAnkiConnectCompatInstanceId = 'me';
    final List<String> seen = <String>[];
    final AnkiConnectService s = AnkiConnectService(
      port: 18765,
      client: server(
        identify: <String, Object?>{
          'result': <String, Object?>{'fushi': true, 'instance': 'me'},
          'error': null,
        },
        seen: seen,
      ),
    );
    await expectLater(
      s.getDeckNames(),
      throwsA(
        isA<AnkiConnectSelfLoopException>().having(
          (AnkiConnectSelfLoopException e) => e.message,
          'message',
          contains('推 Anki 的地址指向了 Fushi 自己的兼容端点'),
        ),
      ),
    );
    expect(seen, <String>['fushiIdentify']);
    // 判定被缓存：第二次不再探测。
    await expectLater(
      s.getDeckNames(),
      throwsA(isA<AnkiConnectSelfLoopException>()),
    );
    expect(seen, <String>['fushiIdentify']);
  });

  test('真 AnkiConnect（unsupported action）与别的 Fushi 实例照常放行', () async {
    fushiAnkiConnectCompatInstanceId = 'me';
    final List<String> seen = <String>[];
    final AnkiConnectService real = AnkiConnectService(
      port: 18766,
      client: server(
        identify: <String, Object?>{
          'result': null,
          'error': 'unsupported action',
        },
        seen: seen,
      ),
    );
    expect(await real.getDeckNames(), <String>['Default']);
    expect(await real.getDeckNames(), <String>['Default']);
    expect(seen, <String>['fushiIdentify', 'deckNames', 'deckNames']);

    final AnkiConnectService other = AnkiConnectService(
      port: 18767,
      client: server(
        identify: <String, Object?>{
          'result': <String, Object?>{'fushi': true, 'instance': 'other'},
          'error': null,
        },
      ),
    );
    expect(await other.getDeckNames(), <String>['Default']);
  });

  test('没挂兼容端点时不探测（零开销）', () async {
    final List<String> seen = <String>[];
    final AnkiConnectService s = AnkiConnectService(
      port: 18768,
      client: server(identify: null, seen: seen),
    );
    await s.getDeckNames();
    expect(seen, <String>['deckNames']);
  });
}
