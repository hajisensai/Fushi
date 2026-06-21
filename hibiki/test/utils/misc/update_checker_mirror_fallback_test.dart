import 'dart:io';

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

    test(
        '已 DNS 失效的死域名 ghproxy.homeboyc.cn 不得再出现在镜像清单里'
        '（TODO-666：用户真机 Failed host lookup errno=7）', () {
      // 守卫：该公共 gh 代理域名已不再解析（用户日志 errno=7），留着只会在
      // 下载全失败时贡献误导性 host-lookup 报错。任何复活它的改动都应红。
      expect(
        updateCheckProxyPrefixes.any(
          (String p) => p.contains('ghproxy.homeboyc.cn'),
        ),
        isFalse,
        reason: 'ghproxy.homeboyc.cn DNS 已失效，必须保持移除',
      );
    });

    test(
        '直连 URL 恒为首候选（BUG-292：检查命中 api.github.com，'
        '公共 gh 代理一律 403/限流，唯一可成功路径是直连）', () {
      const String api = 'https://api.github.com/repos/x/y/releases/latest';
      final List<String> urls = updateCheckUrls(api);
      expect(
        urls.first,
        api,
        reason: 'api.github.com 经任何镜像都被 GitHub 限流 403，'
            '检查阶段只有直连能成功，故直连必须排第一',
      );
      // 镜像候选仍保留多个（对「下载」阶段有用：实测 ghfast.top/ghproxy.net 返回 206）。
      expect(
        urls.length,
        greaterThan(updateCheckProxyPrefixes.length),
        reason: '直连 + 全部镜像前缀，候选数应 = 1 + 镜像数',
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

  group('selectRepresentativeDownloadFailure (全失败时抛哪个错，纯函数 TODO-666)', () {
    UpdateDownloadAttemptFailure failure(String url, Object error) =>
        UpdateDownloadAttemptFailure(
          url: url,
          error: error,
          stack: StackTrace.current,
        );

    test('全失败时优先返回直连(首候选)的错误，而非列表末尾的死镜像错误', () {
      const String direct =
          'https://github.com/x/y/releases/download/v1/app.apk';
      final Object directError = Exception('direct github unreachable');
      const Object deadMirrorError = SocketException(
        "Failed host lookup: 'ghproxy.homeboyc.cn'",
      );
      final List<UpdateDownloadAttemptFailure> failures =
          <UpdateDownloadAttemptFailure>[
        failure(direct, directError),
        failure('https://ghfast.top/$direct', Exception('mirror timeout')),
        // 列表末尾恰是已失效死镜像：原实现会把它当整轮失败原因展示（误导）。
        failure('https://ghproxy.homeboyc.cn/$direct', deadMirrorError),
      ];
      final UpdateDownloadAttemptFailure? chosen =
          selectRepresentativeDownloadFailure(failures, directUrl: direct);
      expect(chosen, isNotNull);
      expect(
        chosen!.error,
        same(directError),
        reason: '应锚定直连失败（真问题=需代理），不取末尾死镜像 host-lookup 失败',
      );
    });

    test('没有直连候选失败记录时，回退到首个失败（仍不取末尾死镜像）', () {
      const String direct =
          'https://github.com/x/y/releases/download/v1/app.apk';
      final Object firstMirrorError = Exception('first mirror failed');
      final List<UpdateDownloadAttemptFailure> failures =
          <UpdateDownloadAttemptFailure>[
        failure('https://ghfast.top/$direct', firstMirrorError),
        failure(
          'https://ghproxy.homeboyc.cn/$direct',
          const SocketException("Failed host lookup: 'ghproxy.homeboyc.cn'"),
        ),
      ];
      final UpdateDownloadAttemptFailure? chosen =
          selectRepresentativeDownloadFailure(failures, directUrl: direct);
      expect(chosen, isNotNull);
      expect(chosen!.error, same(firstMirrorError));
    });

    test('无任何失败记录返回 null（调用方用通用兜底文案）', () {
      final UpdateDownloadAttemptFailure? chosen =
          selectRepresentativeDownloadFailure(
        const <UpdateDownloadAttemptFailure>[],
        directUrl: 'https://github.com/x/y/z',
      );
      expect(chosen, isNull);
    });
  });
}
