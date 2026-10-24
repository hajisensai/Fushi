// Android 系统代理（Wi-Fi「代理：手动」）进 Dart 出站代理层。
//
// 原始失败（2026-10-24，SM-X716B 真机）：Wi-Fi 配了 HTTP 代理 192.168.1.88:7890，
// WebView 走它能打开 YouTube；Dart HttpClient 不认 Android 系统代理，自动模式在 Android
// 上恒为 DIRECT——`adb shell curl https://www.youtube.com/sw.js_data` 直连超时、
// 带 `-x http://192.168.1.88:7890` 回 200。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/android_system_proxy.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

bool _envHasProxy() => Platform.environment.keys.any((String k) {
  final String lower = k.toLowerCase();
  return lower == 'https_proxy' || lower == 'http_proxy';
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('androidSystemProxyEnvironment', () {
    test('host + port → https_proxy / http_proxy 同一出口', () {
      expect(
        androidSystemProxyEnvironment(host: '192.168.1.88', port: 7890),
        <String, String>{
          'https_proxy': '192.168.1.88:7890',
          'http_proxy': '192.168.1.88:7890',
        },
      );
    });

    test('没配代理（host 空 / port 非法）→ 空 map', () {
      expect(androidSystemProxyEnvironment(host: null, port: null), isEmpty);
      expect(androidSystemProxyEnvironment(host: '', port: 8080), isEmpty);
      expect(androidSystemProxyEnvironment(host: 'p', port: 0), isEmpty);
      expect(androidSystemProxyEnvironment(host: 'p', port: 70000), isEmpty);
    });

    test('exclusionList 换成 no_proxy 后缀写法', () {
      final Map<String, String> env = androidSystemProxyEnvironment(
        host: 'proxy.lan',
        port: 3128,
        exclusionList: 'localhost, *.corp.example ,example.org',
      );
      expect(env['no_proxy'], 'localhost,.corp.example,example.org');
    });

    test('IPv6 字面量代理加方括号', () {
      expect(
        androidSystemProxyEnvironment(
          host: 'fd00::1',
          port: 8080,
        )['http_proxy'],
        '[fd00::1]:8080',
      );
    });

    test('装进 findProxyFromEnvironment 后公网走代理、排除项直连', () {
      final Map<String, String> env = androidSystemProxyEnvironment(
        host: '192.168.1.88',
        port: 7890,
        exclusionList: '*.corp.example',
      );
      expect(
        resolveAppProxyDirective(
          Uri.parse('https://www.youtube.com/youtubei/v1/player'),
          systemEnvOverride: env,
        ),
        startsWith('PROXY 192.168.1.88:7890'),
      );
      expect(
        resolveAppProxyDirective(
          Uri.parse('https://git.corp.example/'),
          systemEnvOverride: env,
        ),
        'DIRECT',
      );
    }, skip: _envHasProxy() ? 'env 已设代理，env 优先于系统代理，判别不了' : false);
  });

  group('readAndroidSystemProxyEnvironment（平台通道）', () {
    const MethodChannel channel = MethodChannel('test/system_proxy');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('原生回 {host, port, exclusionList} → environment 片段', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'getHttpProxy');
            return <String, Object?>{
              'host': '192.168.1.88',
              'port': 7890,
              'exclusionList': 'localhost',
            };
          });
      expect(
        await readAndroidSystemProxyEnvironment(channel: channel),
        <String, String>{
          'https_proxy': '192.168.1.88:7890',
          'http_proxy': '192.168.1.88:7890',
          'no_proxy': 'localhost',
        },
      );
    });

    test('原生回 null（没配代理）→ 空 map', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async => null);
      expect(
        await readAndroidSystemProxyEnvironment(channel: channel),
        isEmpty,
      );
    });
  });
}
