import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('isExpectedUpdateNetworkFailure', () {
    test('SocketException (含连接超时) 视为预期网络失败，不进错误日志', () {
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

    test('非网络异常（解析/逻辑错误）仍应记入错误日志', () {
      expect(isExpectedUpdateNetworkFailure(const FormatException('bad json')),
          isFalse);
      expect(isExpectedUpdateNetworkFailure(Exception('All sources failed')),
          isFalse);
      expect(isExpectedUpdateNetworkFailure(ArgumentError('nope')), isFalse);
    });
  });
}
