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

  group('parseScutilProxy（解析 macOS scutil --proxy 输出，纯函数）', () {
    test('HTTPS Enable=1 有 host+port → 填 https/http_proxy，非 PAC', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7890
}
''');
      expect(pac, isFalse);
      expect(env['https_proxy'], '127.0.0.1:7890');
      // findProxyFromEnvironment 对 https URL 读 https_proxy，回退 http_proxy 都填。
      expect(env['http_proxy'], '127.0.0.1:7890');
    });

    test('只 HTTP Enable=1（无 HTTPS）→ 回退 http 代理', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 1080
  HTTPSEnable : 0
}
''');
      expect(pac, isFalse);
      expect(env['http_proxy'], '127.0.0.1:1080');
      expect(env['https_proxy'], '127.0.0.1:1080');
    });

    test('HTTPS 与 HTTP 都启用 → https_proxy 取 HTTPS、http_proxy 取 HTTP', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 1080
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7890
}
''');
      expect(pac, isFalse);
      expect(env['https_proxy'], '127.0.0.1:7890');
      expect(env['http_proxy'], '127.0.0.1:1080');
    });

    test('ProxyAutoConfigEnable=1（PAC）→ 空 map + pacDowngraded=true（降级直连）', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://wpad/wpad.dat
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7890
}
''');
      expect(pac, isTrue);
      expect(env, isEmpty);
    });

    test('全 0 / 无代理 → 空 map，非 PAC', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  HTTPEnable : 0
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 0
}
''');
      expect(pac, isFalse);
      expect(env, isEmpty);
    });

    test('Enable=1 但缺 host/port → 不采用（空 map）', () {
      final (Map<String, String> env, bool pac) = parseScutilProxy('''
<dictionary> {
  HTTPSEnable : 1
}
''');
      expect(pac, isFalse);
      expect(env, isEmpty);
    });

    test('畸形 / 空输出不抛异常，返回空 map 非 PAC', () {
      final (Map<String, String> env1, bool pac1) = parseScutilProxy('');
      expect(env1, isEmpty);
      expect(pac1, isFalse);
      final (Map<String, String> env2, bool pac2) =
          parseScutilProxy('garbage no colon here\n}{][');
      expect(env2, isEmpty);
      expect(pac2, isFalse);
    });

    test('解析结果可直接喂给 HttpClient.findProxyFromEnvironment 得到 PROXY 指令', () {
      final (Map<String, String> env, _) = parseScutilProxy('''
<dictionary> {
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7890
}
''');
      final String directive = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
        environment: env,
      );
      expect(directive, contains('PROXY 127.0.0.1:7890'));
    });
  });

  group('parseGsettingsProxy（解析 Linux GNOME gsettings 代理，纯函数）', () {
    test('mode=manual + https host+port → 填 https/http_proxy，非 PAC', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'manual'",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      expect(pac, isFalse);
      expect(env['https_proxy'], '127.0.0.1:7890');
      expect(env['http_proxy'], '127.0.0.1:7890');
    });

    test('mode=manual 只 http 配置 → 回退 http 代理', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'manual'",
        httpsHost: '',
        httpsPort: '0',
        httpHost: '127.0.0.1',
        httpPort: '1080',
      );
      expect(pac, isFalse);
      expect(env['http_proxy'], '127.0.0.1:1080');
      expect(env['https_proxy'], '127.0.0.1:1080');
    });

    test('mode=auto（PAC）→ 空 map + pacDowngraded=true（降级直连）', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'auto'",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      expect(pac, isTrue);
      expect(env, isEmpty);
    });

    test('mode=none → 空 map 非 PAC（回退 env/直连）', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'none'",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      expect(pac, isFalse);
      expect(env, isEmpty);
    });

    test('mode=manual 但 host 为空 → 空 map（不采用）', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'manual'",
        httpsHost: '',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      expect(pac, isFalse);
      expect(env, isEmpty);
    });

    test('mode=manual 但 port=0/空 → 空 map（视为未配置）', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'manual'",
        httpsHost: '127.0.0.1',
        httpsPort: '0',
        httpHost: '127.0.0.1',
        httpPort: '',
      );
      expect(pac, isFalse);
      expect(env, isEmpty);
    });

    test('mode 带换行/未知值当 none', () {
      final (Map<String, String> env, bool pac) = parseGsettingsProxy(
        mode: "'manual'\n",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      // 带换行的 'manual' 仍应正确剥引号识别为 manual。
      expect(pac, isFalse);
      expect(env['https_proxy'], '127.0.0.1:7890');

      final (Map<String, String> env2, bool pac2) = parseGsettingsProxy(
        mode: "'mystery'",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      expect(pac2, isFalse);
      expect(env2, isEmpty);
    });

    test('解析结果可直接喂给 HttpClient.findProxyFromEnvironment 得到 PROXY 指令', () {
      final (Map<String, String> env, _) = parseGsettingsProxy(
        mode: "'manual'",
        httpsHost: '127.0.0.1',
        httpsPort: '7890',
        httpHost: '',
        httpPort: '0',
      );
      final String directive = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
        environment: env,
      );
      expect(directive, contains('PROXY 127.0.0.1:7890'));
    });
  });

  group('normalizeUserProxyHostPort（归一用户手填代理，纯函数 TODO-871/862）', () {
    test('裸 host:port → 原样返回', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:7890'), '127.0.0.1:7890');
    });

    test('带 http:// 前缀 → 剥前缀', () {
      expect(normalizeUserProxyHostPort('http://127.0.0.1:7890'),
          '127.0.0.1:7890');
    });

    test('带 https:// 前缀 → 剥前缀', () {
      expect(normalizeUserProxyHostPort('https://127.0.0.1:7890'),
          '127.0.0.1:7890');
    });

    test('前后空格 → trim 后合法', () {
      expect(
          normalizeUserProxyHostPort('  127.0.0.1:7890  '), '127.0.0.1:7890');
    });

    test('主机名 host:port → 合法', () {
      expect(
          normalizeUserProxyHostPort('proxy.local:1080'), 'proxy.local:1080');
    });

    test('端口边界 1 / 65535 合法', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:1'), '127.0.0.1:1');
      expect(normalizeUserProxyHostPort('127.0.0.1:65535'), '127.0.0.1:65535');
    });

    test('空串 → null', () {
      expect(normalizeUserProxyHostPort(''), isNull);
      expect(normalizeUserProxyHostPort('   '), isNull);
    });

    test('缺端口（无冒号）→ null', () {
      expect(normalizeUserProxyHostPort('127.0.0.1'), isNull);
    });

    test('非数字端口 → null', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:abc'), isNull);
      expect(normalizeUserProxyHostPort(':abc'), isNull);
    });

    test('端口 0 → null（越界）', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:0'), isNull);
    });

    test('端口 70000 → null（越界）', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:70000'), isNull);
    });

    test('带路径 → null', () {
      expect(normalizeUserProxyHostPort('127.0.0.1:7890/path'), isNull);
      expect(normalizeUserProxyHostPort('http://127.0.0.1:7890/x?y'), isNull);
    });

    test('空 host（仅冒号端口）→ null', () {
      expect(normalizeUserProxyHostPort(':7890'), isNull);
    });

    test('IPv4 段越界（>255）→ null', () {
      expect(normalizeUserProxyHostPort('999.0.0.1:7890'), isNull);
    });

    test('【必改④】IPv6 字面量 [::1]:7890 → null（本期不支持）', () {
      expect(normalizeUserProxyHostPort('[::1]:7890'), isNull);
      expect(normalizeUserProxyHostPort('::1:7890'), isNull);
      expect(normalizeUserProxyHostPort('fe80::1:7890'), isNull);
    });

    test('合法手填代理经 _buildProxyEnv 同范式装配后能被 findProxyFromEnvironment 识别', () {
      // 复用 Windows 注册表纯函数把同一 host:port 装配成 env（与短路路径等价目标：
      // 最终生成 PROXY 指令），验证归一结果是 findProxyFromEnvironment 可消费的形态。
      final String? normalized = normalizeUserProxyHostPort('127.0.0.1:7890');
      expect(normalized, '127.0.0.1:7890');
      final Map<String, String> env = parseWindowsRegistryProxy(
        proxyEnableOutput: _regEnable('0x1'),
        proxyServerOutput: _regServer(normalized!),
      );
      final String directive = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
        environment: env,
      );
      expect(directive, contains('PROXY 127.0.0.1:7890'));
    });
  });
}
