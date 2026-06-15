import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// 构造一条 `reg query ... /v ProxyEnable` 的典型输出。
String _regEnable(String value) {
  const String key =
      r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  return '\r\n$key\r\n    ProxyEnable    REG_DWORD    $value\r\n';
}

/// 构造一条 `reg query ... /v ProxyServer` 的典型输出。
String _regServer(String value) {
  const String key =
      r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  return '\r\n$key\r\n    ProxyServer    REG_SZ    $value\r\n';
}

void main() {
  group('parseWindowsRegistryProxy（解析 Windows 系统代理注册表输出，纯函数）', () {
    test('系统代理启用 + 全局 host:port → 填 https_proxy/http_proxy', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer('127.0.0.1:34151'),
      );
      expect(env['https_proxy'], '127.0.0.1:34151');
      expect(env['http_proxy'], '127.0.0.1:34151');
    });

    test('系统代理未启用（0x0）→ 空 map（不补代理，回退直连）', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x0'),
        proxyServerOutput: _regServer('127.0.0.1:34151'),
      );
      expect(env, isEmpty);
    });

    test('ProxyEnable 缺失 → 空 map', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: 'ERROR: registry value not found.',
        proxyServerOutput: _regServer('127.0.0.1:34151'),
      );
      expect(env, isEmpty);
    });

    test('启用但 ProxyServer 缺失/为空 → 空 map', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: 'ERROR: registry value not found.',
      );
      expect(env, isEmpty);
    });

    test('分协议串（http=/https=）分别取对应段', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer(
          'http=127.0.0.1:7890;https=127.0.0.1:7891;ftp=127.0.0.1:7892',
        ),
      );
      expect(env['https_proxy'], '127.0.0.1:7891');
      expect(env['http_proxy'], '127.0.0.1:7890');
    });

    test('分协议串只给 https → http_proxy 回退到 https 段', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer('https=127.0.0.1:7891'),
      );
      expect(env['https_proxy'], '127.0.0.1:7891');
      expect(env['http_proxy'], '127.0.0.1:7891');
    });

    test('分协议串只给 http → https_proxy 回退到 http 段', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer('http=127.0.0.1:7890'),
      );
      expect(env['http_proxy'], '127.0.0.1:7890');
      expect(env['https_proxy'], '127.0.0.1:7890');
    });

    test('ProxyEnable 大小写不敏感（0X1）仍视为启用', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0X1'),
        proxyServerOutput: _regServer('127.0.0.1:34151'),
      );
      expect(env['https_proxy'], '127.0.0.1:34151');
    });

    test('解析结果可直接喂给 HttpClient.findProxyFromEnvironment 得到 PROXY 指令', () {
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer('127.0.0.1:34151'),
      );
      // 不实际建连，只验证生成的 environment 能被 findProxyFromEnvironment 识别为代理。
      final String directive = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
        environment: env,
      );
      expect(directive, contains('PROXY 127.0.0.1:34151'));
    });

    test('无代理环境（空 map）→ findProxyFromEnvironment 返回 DIRECT（不破坏直连）', () {
      final String directive = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
        environment: const <String, String>{},
      );
      expect(directive, 'DIRECT');
    });
  });
}
