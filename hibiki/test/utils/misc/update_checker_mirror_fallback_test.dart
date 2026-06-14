import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('updateCheckUrls (候选 URL 列表，纯函数)', () {
    test('首项是用户/直连 URL 本身（有 VPN/系统代理时直连优先）', () {
      const String direct = 'https://api.github.com/repos/x/y/releases/latest';
      final List<String> urls = updateCheckUrls(direct);
      expect(urls.first, direct);
    });

    test('其余项把每个 gh 代理前缀套在直连 URL 前（GFW 兜底）', () {
      const String direct = 'https://api.github.com/repos/x/y/releases/latest';
      final List<String> urls = updateCheckUrls(direct);
      // 至少应包含多个镜像（不止一个），保证单点不可达仍有后备。
      expect(urls.length, greaterThan(2));
      for (final String prefix in updateCheckProxyPrefixes) {
        expect(urls, contains('$prefix$direct'));
      }
    });

    test('候选列表里直连只出现一次且无重复', () {
      const String direct = 'https://api.github.com/repos/x/y/releases/latest';
      final List<String> urls = updateCheckUrls(direct);
      expect(urls.toSet().length, urls.length, reason: '不应有重复候选');
      expect(urls.where((String u) => u == direct).length, 1);
    });

    test('镜像前缀清单是可维护常量且包含已知可用候选', () {
      // 用户日志里连不上的 ghproxy.cc 仍作为多候选之一保留（轮换名单，多备几个）。
      expect(updateCheckProxyPrefixes, isNotEmpty);
      expect(
        updateCheckProxyPrefixes.every((String p) => p.endsWith('/')),
        isTrue,
        reason: '前缀必须以 / 结尾才能直接拼接 URL',
      );
    });
  });

  group('fetchFirstSuccessfulBody (逐候选回退执行，注入 fetcher)', () {
    test('首候选成功则直接返回，不再尝试后续', () async {
      final List<String> attempted = <String>[];
      final String? body = await fetchFirstSuccessfulBody(
        <String>['a', 'b', 'c'],
        fetch: (String url) async {
          attempted.add(url);
          return 'BODY($url)';
        },
      );
      expect(body, 'BODY(a)');
      expect(attempted, <String>['a'], reason: '首个成功后不应再试 b/c');
    });

    test('首候选失败(null)自动试下一个，任一成功则整体成功', () async {
      final List<String> attempted = <String>[];
      final String? body = await fetchFirstSuccessfulBody(
        <String>['a', 'b', 'c'],
        fetch: (String url) async {
          attempted.add(url);
          if (url == 'a' || url == 'b') return null; // a/b 不可达
          return 'BODY($url)';
        },
      );
      expect(body, 'BODY(c)');
      expect(attempted, <String>['a', 'b', 'c']);
    });

    test('首候选抛异常也继续试下一个（异常不冒泡终止回退）', () async {
      final List<String> attempted = <String>[];
      final String? body = await fetchFirstSuccessfulBody(
        <String>['a', 'b'],
        fetch: (String url) async {
          attempted.add(url);
          if (url == 'a') throw const FormatException('boom');
          return 'BODY(b)';
        },
      );
      expect(body, 'BODY(b)');
      expect(attempted, <String>['a', 'b']);
    });

    test('全部候选失败才返回 null（整体失败）', () async {
      final List<String> attempted = <String>[];
      final String? body = await fetchFirstSuccessfulBody(
        <String>['a', 'b', 'c'],
        fetch: (String url) async {
          attempted.add(url);
          return null;
        },
      );
      expect(body, isNull);
      expect(attempted, <String>['a', 'b', 'c'], reason: '全失败前必须把每个都试过');
    });

    test('每个失败的候选都通过 onFailure 回调记录其主机标签', () async {
      final List<String> failedHosts = <String>[];
      await fetchFirstSuccessfulBody(
        <String>[
          'https://api.github.com/x',
          'https://ghfast.top/https://api.github.com/x',
        ],
        fetch: (String url) async => null, // 全失败
        onFailure: (String host, Object? error) => failedHosts.add(host),
      );
      expect(
        failedHosts,
        <String>['api.github.com', 'ghfast.top'],
        reason: '日志要能看出连不上哪个源（hostLabelForUpdateUrl）',
      );
    });

    test('成功的候选不会触发 onFailure', () async {
      final List<String> failedHosts = <String>[];
      final String? body = await fetchFirstSuccessfulBody(
        <String>['a', 'b'],
        fetch: (String url) async => url == 'a' ? null : 'ok',
        onFailure: (String host, Object? error) => failedHosts.add(host),
      );
      expect(body, 'ok');
      expect(failedHosts, <String>[hostLabelForUpdateUrl('a')]);
    });
  });
}
