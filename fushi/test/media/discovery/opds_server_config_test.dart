/// `OpdsServerConfig` 的校验与清单 codec 契约。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/opds_server_config.dart';

OpdsServerConfig _config({
  String id = 'a',
  String name = 'My Books',
  String url = 'https://books.example.com/api/v1/opds',
  String username = 'reader',
  String password = 'pw',
  bool enabled = true,
  bool allowInsecureHttp = false,
}) =>
    OpdsServerConfig(
      id: id,
      name: name,
      catalogUrl: Uri.parse(url),
      username: username,
      password: password,
      enabled: enabled,
      allowInsecureHttp: allowInsecureHttp,
    );

void main() {
  group('校验', () {
    test('HTTPS 恒可用；空 id / 非 http scheme / 带 userInfo 的地址被拒', () {
      expect(_config, returnsNormally);
      expect(() => _config(id: '  '), throwsArgumentError);
      expect(() => _config(url: 'ftp://h/opds'), throwsArgumentError);
      expect(
        () => _config(url: 'https://user:pw@h/opds'),
        throwsArgumentError,
        reason: '凭据必须走 username/password 字段，不能藏在 URL 里',
      );
    });

    test('明文 HTTP 需要显式放行；loopback 例外', () {
      // 自建 OPDS 常年跑在局域网 http://192.168.x.x:8080——不给放行开关等于
      // 把最主流的自建场景挡在门外；但放行必须是用户勾的。
      expect(() => _config(url: 'http://192.168.1.10:8080/opds'),
          throwsArgumentError);
      expect(
        () => _config(
            url: 'http://192.168.1.10:8080/opds', allowInsecureHttp: true),
        returnsNormally,
      );
      expect(() => _config(url: 'http://127.0.0.1:8080/opds'), returnsNormally);
    });
  });

  group('认证头', () {
    test('有用户名 → Basic；无用户名 → null（匿名目录不该发认证头）', () {
      final String? header =
          _config(username: 'u', password: 'p').authorizationHeader;
      expect(header, 'Basic ${base64Encode(utf8.encode('u:p'))}');
      expect(_config(username: '', password: 'p').authorizationHeader, isNull);
    });

    test('非 ASCII 密码按 UTF-8 编码（不是 latin1）', () {
      final String? header =
          _config(username: 'u', password: '密码').authorizationHeader;
      expect(header, 'Basic ${base64Encode(utf8.encode('u:密码'))}');
    });
  });

  test('displayName 空名回退主机名', () {
    expect(_config(name: '  ').displayName, 'books.example.com');
    expect(_config(name: 'Shelf').displayName, 'Shelf');
  });

  group('清单 codec', () {
    test('往返保真（含密码与两个布尔位）', () {
      final List<OpdsServerConfig> original = <OpdsServerConfig>[
        _config(id: 'a'),
        _config(
          id: 'b',
          name: 'LAN',
          url: 'http://192.168.1.10:8080/opds',
          username: '',
          password: '',
          enabled: false,
          allowInsecureHttp: true,
        ),
      ];
      final List<OpdsServerConfig> decoded =
          decodeOpdsServerConfigs(encodeOpdsServerConfigs(original));
      expect(decoded, hasLength(2));
      expect(decoded[0].password, 'pw');
      expect(decoded[0].username, 'reader');
      expect(decoded[1].enabled, isFalse);
      expect(decoded[1].allowInsecureHttp, isTrue);
      expect(decoded[1].catalogUrl.toString(), 'http://192.168.1.10:8080/opds');
    });

    test('密码不以明文出现在序列化结果里', () {
      // base64 是遮蔽不是加密（见 toJson 的注释），但至少不该在偏好表里
      // 一眼可读。
      final String raw = encodeOpdsServerConfigs(
          <OpdsServerConfig>[_config(password: 'hunter2')]);
      expect(raw.contains('hunter2'), isFalse);
      expect(decodeOpdsServerConfigs(raw).single.password, 'hunter2');
    });

    test('一条记录坏掉只丢那一条，不让整份清单消失', () {
      // 这是「我的书库全没了」和「有一台服务器没了」的分界。
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{'id': 'good', 'url': 'https://h/opds'},
        <String, Object?>{'id': 'bad', 'url': 'ftp://h/opds'}, // scheme 非法
        <String, Object?>{'id': 'nourl'}, // 缺 url
        'not-an-object',
        <String, Object?>{'id': 'good2', 'url': 'https://h2/opds'},
      ]);
      final List<OpdsServerConfig> decoded = decodeOpdsServerConfigs(raw);
      expect(
        decoded.map((OpdsServerConfig c) => c.id),
        <String>['good', 'good2'],
      );
    });

    test('id 撞车时丢弃后来者', () {
      // 两个源共用一个 id 会让 sourceById 只认得到第一个，而「停用」开关
      // 同时作用到两台服务器上。
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{'id': 'x', 'url': 'https://a/opds', 'name': 'first'},
        <String, Object?>{'id': 'x', 'url': 'https://b/opds', 'name': 'second'},
      ]);
      final List<OpdsServerConfig> decoded = decodeOpdsServerConfigs(raw);
      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'first');
    });

    test('空串 / 非数组 / 畸形 JSON 都回退空清单而不是抛', () {
      expect(decodeOpdsServerConfigs(null), isEmpty);
      expect(decodeOpdsServerConfigs('   '), isEmpty);
      expect(decodeOpdsServerConfigs('{"not":"a list"}'), isEmpty);
      expect(decodeOpdsServerConfigs('][ broken'), isEmpty);
    });

    test('坏 base64 密码降级成空密码，不拖垮整条记录', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'a',
          'url': 'https://h/opds',
          'username': 'u',
          'passwordB64': '!!!not-base64!!!',
        },
      ]);
      final OpdsServerConfig decoded = decodeOpdsServerConfigs(raw).single;
      expect(decoded.username, 'u');
      expect(decoded.password, '');
    });
  });
}
