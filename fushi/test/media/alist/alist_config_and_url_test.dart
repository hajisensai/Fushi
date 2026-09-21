/// AList 站点配置 codec + 来源条目地址映射的纯函数契约。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import 'package:fushi/src/media/alist/alist_source_url.dart';
import 'package:fushi/src/media/discovery/alist_site_config.dart';

void main() {
  group('AListSiteConfig', () {
    test('codec 往返；密码不明文；kinds 随行', () {
      final AListSiteConfig site = AListSiteConfig(
        id: 'site-1',
        name: 'OD',
        baseUrl: Uri.parse('https://od.example.com/'),
        kinds: const <DiscoveryMediaKind>{
          DiscoveryMediaKind.game,
          DiscoveryMediaKind.manga,
        },
        username: 'u',
        password: 'p@ss',
      );
      final String raw = encodeAListSiteConfigs(<AListSiteConfig>[site]);
      expect(raw, isNot(contains('p@ss')));
      final List<AListSiteConfig> back = decodeAListSiteConfigs(raw);
      expect(back, hasLength(1));
      expect(back.single.id, 'site-1');
      expect(back.single.password, 'p@ss');
      expect(back.single.origin, 'https://od.example.com');
      expect(back.single.kinds, <DiscoveryMediaKind>{
        DiscoveryMediaKind.game,
        DiscoveryMediaKind.manga
      });
    });

    test('kinds 缺省/未知名：缺省走默认，未知名只丢那一个', () {
      final List<AListSiteConfig> decoded = decodeAListSiteConfigs(jsonEncode(
        <Map<String, Object?>>[
          <String, Object?>{'id': 'a', 'url': 'https://a.example.com'},
          <String, Object?>{
            'id': 'b',
            'url': 'https://b.example.com',
            'kinds': <String>['novel', 'future-kind'],
          },
          // 一个都不认识 → 整条无效（构造器拒空 kinds），不让整份清单消失。
          <String, Object?>{
            'id': 'c',
            'url': 'https://c.example.com',
            'kinds': <String>['nope'],
          },
        ],
      ));
      expect(decoded.map((AListSiteConfig s) => s.id), <String>['a', 'b']);
      expect(decoded[0].kinds, kDefaultAListSiteKinds);
      expect(decoded[1].kinds, <DiscoveryMediaKind>{DiscoveryMediaKind.novel});
    });

    test('明文 HTTP 未放行拒绝，loopback 与显式放行通过', () {
      expect(
        () => AListSiteConfig(
          id: 'x',
          name: '',
          baseUrl: Uri.parse('http://192.168.1.2:5244'),
        ),
        throwsArgumentError,
      );
      expect(
        AListSiteConfig(
          id: 'x',
          name: '',
          baseUrl: Uri.parse('http://192.168.1.2:5244'),
          allowInsecureHttp: true,
        ).origin,
        'http://192.168.1.2:5244',
      );
      expect(
        AListSiteConfig(
          id: 'x',
          name: '',
          baseUrl: Uri.parse('http://127.0.0.1:5244'),
        ).displayName,
        '127.0.0.1',
      );
    });
  });

  group('alist source url', () {
    test('path ↔ url 往返，解码态、保留 # 与空格', () {
      const String base = 'https://od.example.com/';
      const String path = '/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv';
      final String url = alistSourceUrlFor(baseUrl: base, path: path);
      expect(url, 'https://od.example.com/d/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv');
      expect(alistPathFromSourceUrl(baseUrl: base, url: url), path);
    });

    test('根目录与尾斜杠归一；带子路径的站点根', () {
      expect(
          alistSourceUrlFor(baseUrl: 'https://x.example.com/alist', path: '/'),
          'https://x.example.com/alist/d/');
      expect(
        alistPathFromSourceUrl(
          baseUrl: 'https://x.example.com/alist',
          url: 'https://x.example.com/alist/d',
        ),
        '/',
      );
      expect(
        alistPathFromSourceUrl(
          baseUrl: 'https://x.example.com/alist',
          url: 'https://x.example.com/alist/d/a/b/',
        ),
        '/a/b',
      );
    });

    test('不在本站 /d/ 命名空间下返回 null（不做前缀蒙混）', () {
      const String base = 'https://od.example.com';
      expect(
          alistPathFromSourceUrl(
              baseUrl: base, url: 'https://od.example.com/GD-3/x.mkv'),
          isNull);
      expect(
          alistPathFromSourceUrl(
              baseUrl: base, url: 'https://od.example.com/dd/x.mkv'),
          isNull);
      expect(
          alistPathFromSourceUrl(
              baseUrl: base, url: 'https://other.example.com/d/x.mkv'),
          isNull);
    });
  });
}
