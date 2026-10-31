import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/word_audio_resolver.dart';

/// 反馈 uY5I6JRU39：安卓上配了 `localhost` 音源、本机没有服务在听时，错误日志写的是
/// 「无法解析 "localhost"」——真实错误是 `Connection refused`（解析早就成功了）。
/// 连接级失败必须按套接字错误的实际种类出文案。
DioError _dio(Object inner) => DioError(
  requestOptions: RequestOptions(path: 'http://localhost:5050/'),
  error: inner,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('Connection refused (Android errno 111) is not reported as DNS', () {
    final String text = WordAudioResolver.describeAudioSourceFetchError(
      _dio(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
          port: 40134,
        ),
      ),
      'localhost',
    );
    expect(text, t.audio_source_connection_refused(host: 'localhost'));
    expect(text, isNot(t.audio_source_dns_error(host: 'localhost')));
  });

  test('macOS / Windows refused codes map to the same text', () {
    for (final int code in <int>[61, 10061]) {
      expect(
        WordAudioResolver.describeAudioSourceFetchError(
          _dio(SocketException('x', osError: OSError('refused', code))),
          'h',
        ),
        t.audio_source_connection_refused(host: 'h'),
      );
    }
  });

  test('Failed host lookup stays the DNS text', () {
    expect(
      WordAudioResolver.describeAudioSourceFetchError(
        _dio(
          const SocketException(
            "Failed host lookup: 'nope.invalid'",
            osError: OSError('No address associated with hostname', 7),
          ),
        ),
        'nope.invalid',
      ),
      t.audio_source_dns_error(host: 'nope.invalid'),
    );
  });

  test('other socket errors surface the OS message, not DNS', () {
    expect(
      WordAudioResolver.describeAudioSourceFetchError(
        _dio(
          const SocketException(
            'x',
            osError: OSError('Network is unreachable', 101),
          ),
        ),
        'h',
      ),
      t.audio_source_request_error(detail: 'Network is unreachable'),
    );
  });

  test('connect timeout keeps the timeout text', () {
    expect(
      WordAudioResolver.describeAudioSourceFetchError(
        DioError(
          requestOptions: RequestOptions(path: 'http://h/'),
          type: DioErrorType.connectionTimeout,
        ),
        'h',
      ),
      t.audio_source_timeout(host: 'h'),
    );
  });
}
