import 'dart:async';
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

  group('describeUpdateNetworkFailureReason (TODO-371)', () {
    test('连接被拒（瞬时失败）报「connection refused」+ errno，绝不说超时', () {
      final String reason = describeUpdateNetworkFailureReason(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      );
      expect(reason, contains('connection refused'));
      expect(reason, contains('errno=111'));
      expect(reason.toLowerCase(), isNot(contains('timed out')));
      expect(reason.toLowerCase(), isNot(contains('timeout')));
    });

    test('DNS 解析失败报「DNS lookup failed」，不说超时', () {
      final String reason = describeUpdateNetworkFailureReason(
        const SocketException('Failed host lookup: api.github.com'),
      );
      expect(reason, contains('DNS lookup failed'));
      expect(reason.toLowerCase(), isNot(contains('timed out')));
    });

    test('真超时类异常才报超时', () {
      expect(
        describeUpdateNetworkFailureReason(
          TimeoutException('attempt timed out'),
        ),
        contains('timed out'),
      );
      expect(
        describeUpdateNetworkFailureReason(
          const SocketException('HTTP connection timed out'),
        ).toLowerCase(),
        contains('timed out'),
      );
    });

    test('TLS 握手失败报握手而非超时', () {
      final String reason = describeUpdateNetworkFailureReason(
          const HandshakeException('bad cert'));
      expect(reason, contains('TLS handshake failed'));
      expect(reason.toLowerCase(), isNot(contains('timed out')));
    });

    test('底层 HTTP 协议错误报协议错误', () {
      expect(
        describeUpdateNetworkFailureReason(const HttpException('broken pipe')),
        contains('HTTP protocol error'),
      );
    });

    test('无异常（HTTP 非 200 的失败回退）报「无有效响应」，不谎称超时', () {
      final String reason = describeUpdateNetworkFailureReason(null);
      expect(reason, contains('no valid response'));
      expect(reason.toLowerCase(), isNot(contains('timed out')));
    });

    test('未知异常回退 toString，不再无条件谎称超时', () {
      final String reason =
          describeUpdateNetworkFailureReason(const FormatException('weird'));
      expect(reason, contains('weird'));
      expect(reason.toLowerCase(), isNot(contains('timed out')));
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
