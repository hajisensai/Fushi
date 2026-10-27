// 共享 Audiobookshelf 协议层实例注册表：同一台服务器全 app 只有一个实例（refresh
// token 轮换不能被多个实例互相作废），自己刷新后写回偏好的回声不会把令牌回滚，
// 用户在别处重新登录的令牌则会被采用。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/audiobook/remote/audiobookshelf_api_registry.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

const AudiobookshelfTokens _a = AudiobookshelfTokens(
  accessToken: 'a',
  refreshToken: 'ra',
);
const AudiobookshelfTokens _b = AudiobookshelfTokens(
  accessToken: 'b',
  refreshToken: 'rb',
);
const AudiobookshelfTokens _c = AudiobookshelfTokens(
  accessToken: 'c',
  refreshToken: 'rc',
);
const AudiobookshelfTokens _d = AudiobookshelfTokens(
  accessToken: 'd',
  refreshToken: 'rd',
);

AudiobookshelfServerConfig _config({
  String id = 'srv',
  String url = 'https://abs.example.com',
  AudiobookshelfTokens? tokens = _a,
  bool enabled = true,
}) => AudiobookshelfServerConfig(
  id: id,
  name: 'Home',
  serverUrl: Uri.parse(url),
  username: 'me',
  tokens: tokens,
  enabled: enabled,
);

/// 每次登录依次回 b、c、d 令牌的假服务器。
http.Client _loginClient(List<AudiobookshelfTokens> queue) =>
    MockClient((http.Request request) async {
      final AudiobookshelfTokens next = queue.removeAt(0);
      return http.Response(
        jsonEncode(<String, Object?>{
          'user': <String, Object?>{
            'id': 'u',
            'username': 'me',
            'accessToken': next.accessToken,
            'refreshToken': next.refreshToken,
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

void main() {
  late List<(String, AudiobookshelfTokens)> persisted;
  late AudiobookshelfApiRegistry registry;

  AudiobookshelfApiRegistry build([List<AudiobookshelfTokens>? logins]) =>
      AudiobookshelfApiRegistry(
        persistTokens: (String id, AudiobookshelfTokens tokens) async =>
            persisted.add((id, tokens)),
        clientFactory: () => _loginClient(logins ?? <AudiobookshelfTokens>[]),
      );

  setUp(() {
    persisted = <(String, AudiobookshelfTokens)>[];
    registry = build();
  });
  tearDown(() => registry.close());

  test('同一台服务器反复借到同一个实例', () {
    final AudiobookshelfApi? first = registry.apiFor(_config());
    expect(first, isNotNull);
    expect(registry.apiFor(_config()), same(first));
  });

  test('不同服务器各有各的实例', () {
    expect(
      registry.apiFor(_config(id: 'one')),
      isNot(same(registry.apiFor(_config(id: 'two')))),
    );
  });

  test('未登录 → null，并丢掉旧实例（再登录得到新实例）', () {
    final AudiobookshelfApi? signedIn = registry.apiFor(_config());
    expect(registry.apiFor(_config(tokens: null)), isNull);
    expect(registry.apiFor(_config()), isNot(same(signedIn)));
  });

  test('服务器地址变了 = 另一台服务器，重建实例', () {
    final AudiobookshelfApi? old = registry.apiFor(_config());
    final AudiobookshelfApi? moved = registry.apiFor(
      _config(url: 'https://other.example.com'),
    );
    expect(moved, isNot(same(old)));
    expect(moved!.serverUrl.host, 'other.example.com');
  });

  test('实例自己换出的令牌交给持久化回调', () async {
    registry = build(<AudiobookshelfTokens>[_b]);
    final AudiobookshelfApi api = registry.apiFor(_config())!;
    await api.login('me', 'pw');
    expect(persisted, <(String, AudiobookshelfTokens)>[('srv', _b)]);
    expect(api.tokens, _b);
  });

  test('写回偏好的回声不会把令牌回滚成旧值', () async {
    // 连换两次令牌 a → b → c；偏好里先落地的 b 才到（持久化是异步的、会晚到）。
    registry = build(<AudiobookshelfTokens>[_b, _c]);
    final AudiobookshelfApi api = registry.apiFor(_config())!;
    await api.login('me', 'pw');
    await api.login('me', 'pw');
    expect(api.tokens, _c);

    registry.apiFor(_config(tokens: _b)); // 迟到的 b 回声
    expect(api.tokens, _c, reason: 'b 是本实例自己换出的，不能回滚');

    registry.apiFor(_config(tokens: _c));
    expect(api.tokens, _c);
  });

  test('用户在别处重新登录（外来令牌）→ 实例采用新令牌，且不回写', () {
    final AudiobookshelfApi api = registry.apiFor(_config())!;
    final AudiobookshelfApi same = registry.apiFor(_config(tokens: _d))!;
    expect(same, api);
    expect(api.tokens, _d);
    expect(persisted, isEmpty, reason: '令牌本来就来自偏好，回写只会造成回声');
  });

  test('retainOnly：删除 / 停用 / 登出的服务器丢掉实例', () {
    final AudiobookshelfApi? keep = registry.apiFor(_config(id: 'keep'));
    registry.apiFor(_config(id: 'gone'));
    registry.apiFor(_config(id: 'off'));
    registry.retainOnly(<AudiobookshelfServerConfig>[
      _config(id: 'keep'),
      _config(id: 'off', enabled: false),
    ]);
    expect(registry.apiFor(_config(id: 'keep')), same(keep));
    // 丢掉后再借是新实例。
    expect(registry.apiFor(_config(id: 'gone')), isNotNull);
  });
}
