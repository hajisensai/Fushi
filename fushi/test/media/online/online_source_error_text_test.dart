import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';

/// 2026-10 体验优化：在线源失败不再把原始异常 toString 甩给用户。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('超时类映射到超时文案', () {
    expect(
      describeOnlineSourceError(TimeoutException('x')),
      t.online_source_error_timeout,
    );
    expect(
      describeOnlineSourceError(
        Exception('java.net.SocketTimeoutException: timeout'),
      ),
      t.online_source_error_timeout,
    );
  });

  test('网络类映射到网络文案', () {
    expect(
      describeOnlineSourceError(const SocketException('Failed host lookup')),
      t.online_source_error_network,
    );
    expect(
      describeOnlineSourceError(
        Exception('ClientException: Connection refused'),
      ),
      t.online_source_error_network,
    );
  });

  test('HTTP 状态码映射到带状态码的文案', () {
    expect(
      describeOnlineSourceError(Exception('HTTP error 503')),
      t.online_source_error_http(code: '503'),
    );
    expect(
      describeOnlineSourceError(StateError('STORE_HTTP_404 for x')),
      t.online_source_error_http(code: '404'),
    );
  });

  test('其余只去掉异常类型前缀、保留源自己的说明', () {
    expect(
      describeOnlineSourceError(Exception('Log in via WebView to read')),
      'Log in via WebView to read',
    );
    expect(
      describeOnlineSourceError(StateError('No chapters')),
      'No chapters',
    );
    expect(
      describeOnlineSourceError(
        const FormatException('Exception: unexpected token'),
      ),
      'unexpected token',
    );
  });

  test('空消息落到通用文案', () {
    expect(describeOnlineSourceError(Exception()), t.online_source_error_generic);
    expect(describeOnlineSourceError(''), t.online_source_error_generic);
  });

  group('字符串入口（已持久化的原始异常串）', () {
    test('网络类原始串映射到网络文案', () {
      expect(
        describeOnlineSourceErrorText(
          "SocketException: Failed host lookup: 'example.org' "
          '(OS Error: No address associated with hostname, errno = 7)',
        ),
        t.online_source_error_network,
      );
      expect(
        describeOnlineSourceErrorText(
          'Exception: HandshakeException: Connection terminated',
        ),
        t.online_source_error_network,
      );
    });

    test('超时类原始串映射到超时文案', () {
      expect(
        describeOnlineSourceErrorText(
          'TimeoutException after 0:00:30.000000: Future not completed',
        ),
        t.online_source_error_timeout,
      );
    });

    test('HTTP 状态原始串映射到带状态码的文案', () {
      expect(
        describeOnlineSourceErrorText(
          'HttpException: HTTP 403 for https://example.org/p/1.jpg',
        ),
        t.online_source_error_http(code: '403'),
      );
      expect(
        describeOnlineSourceErrorText(
          'MihonRuntimeException(BRIDGE_HTTP_503): upstream failed',
        ),
        t.online_source_error_http(code: '503'),
      );
    });

    test('包装异常的 toString 前缀被剥掉，留下源自己的说明', () {
      expect(
        describeOnlineSourceErrorText(
          'OnlineMangaUnavailable(OnlineMangaUnavailableReason.runtimeFailure):'
          ' The peer has not downloaded this chapter yet',
        ),
        'The peer has not downloaded this chapter yet',
      );
      expect(
        describeOnlineSourceErrorText(
          'Exception: Exception: Log in via WebView to read',
        ),
        'Log in via WebView to read',
      );
    });

    test('只剩类型名 / 空白落到通用文案', () {
      expect(
        describeOnlineSourceErrorText('Exception'),
        t.online_source_error_generic,
      );
      expect(
        describeOnlineSourceErrorText('   '),
        t.online_source_error_generic,
      );
    });

    test('与异常对象入口结论一致', () {
      final List<Object> errors = <Object>[
        Exception('ClientException: Connection reset by peer'),
        StateError('STORE_HTTP_404 for x'),
        Exception('Log in via WebView to read'),
      ];
      for (final Object error in errors) {
        expect(
          describeOnlineSourceErrorText('$error'),
          describeOnlineSourceError(error),
        );
      }
    });
  });
}
