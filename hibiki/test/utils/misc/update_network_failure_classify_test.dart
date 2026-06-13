import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('isExpectedUpdateNetworkFailure', () {
    // true → 日志只记 i18n 摘要（无堆栈）；false → 连堆栈一起记（真问题）。
    test('SocketException (含连接超时) 视为预期网络失败', () {
      // 实际日志里出现的正是这条："HTTP connection timed out"。
      expect(
        isExpectedUpdateNetworkFailure(
          const SocketException('HTTP connection timed out'),
        ),
        isTrue,
      );
      expect(
        isExpectedUpdateNetworkFailure(
          const SocketException('Failed host lookup: api.github.com'),
        ),
        isTrue,
      );
    });

    test('TLS 握手失败视为预期网络失败', () {
      expect(
        isExpectedUpdateNetworkFailure(const HandshakeException('bad cert')),
        isTrue,
      );
    });

    test('底层 HTTP 协议错误视为预期网络失败', () {
      expect(
        isExpectedUpdateNetworkFailure(const HttpException('broken pipe')),
        isTrue,
      );
    });

    test('非网络异常（解析/逻辑错误）应连堆栈记入错误日志', () {
      expect(isExpectedUpdateNetworkFailure(const FormatException('bad json')),
          isFalse);
      expect(isExpectedUpdateNetworkFailure(Exception('All sources failed')),
          isFalse);
      expect(isExpectedUpdateNetworkFailure(ArgumentError('nope')), isFalse);
    });
  });

  group('hostLabelForUpdateUrl', () {
    test('直连 GitHub 取 api.github.com', () {
      expect(
        hostLabelForUpdateUrl(
            'https://api.github.com/repos/x/y/releases/latest'),
        'api.github.com',
      );
    });

    test('代理 URL 取代理主机（真正发起连接、真正超时的那一跳）', () {
      // ghfast.top / gh-proxy.com 等前缀拼接的 URL，host 是代理本身。
      expect(
        hostLabelForUpdateUrl(
            'https://ghfast.top/https://api.github.com/repos/x/y'),
        'ghfast.top',
      );
      expect(
        hostLabelForUpdateUrl(
            'https://gh-proxy.com/https://api.github.com/repos/x/y'),
        'gh-proxy.com',
      );
    });

    test('畸形 URL 回退到原串而非抛错', () {
      expect(hostLabelForUpdateUrl('not a url'), 'not a url');
    });
  });
}
