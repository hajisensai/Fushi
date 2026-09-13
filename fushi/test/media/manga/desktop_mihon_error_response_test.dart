import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:http/http.dart' as http;

void main() {
  MihonRuntimeException decode(int status, Object? body) =>
      DesktopMihonRuntime.decodeErrorResponse(
        http.Response(jsonEncode(body), status),
      );

  test('source HTTP failures retain source status and diagnostic stack', () {
    for (final int status in <int>[403, 429, 500, 502, 503, 599]) {
      final MihonRuntimeException error = decode(status, <String, Object>{
        'errorKind': 'sourceHttp',
        'sourceStatusCode': status,
        'error': 'HTTP error $status',
        'errorType': 'eu.kanade.tachiyomi.network.HttpException',
        'stackTrace': 'source fixture stack',
      });
      expect(error.code, 'SOURCE_HTTP_$status');
      expect(error.message, 'Manga source returned HTTP $status');
      expect(error.details, contains('source fixture stack'));
    }
  });

  test(
    'older typed sidecar envelopes recover source 502 from transport 500',
    () {
      final MihonRuntimeException error = decode(500, <String, Object>{
        'errorType': 'eu.kanade.tachiyomi.network.HttpException',
        'code': 502,
        'error': 'HTTP error 502',
      });
      expect(error.code, 'SOURCE_HTTP_502');
    },
  );

  test(
    'internal failure text and untyped code cannot impersonate a source',
    () {
      for (final Map<String, Object> envelope in <Map<String, Object>>[
        <String, Object>{'error': 'HTTP error 502', 'code': 502},
        <String, Object>{
          'errorKind': 'bridge',
          'sourceStatusCode': 502,
          'errorType': 'eu.kanade.tachiyomi.network.HttpException',
          'code': 502,
        },
        <String, Object>{'errorKind': 'sourceHttp', 'sourceStatusCode': '502'},
        <String, Object>{'errorKind': 'sourceHttp', 'sourceStatusCode': 200},
        <String, Object>{'errorKind': 'sourceHttp', 'sourceStatusCode': 600},
      ]) {
        expect(decode(500, envelope).code, 'BRIDGE_HTTP_500');
      }
    },
  );

  test(
    'non-JSON gateway response retains transport error instead of IO error',
    () {
      for (final String body in <String>[
        '',
        '<html>Bad Gateway</html>',
        'null',
      ]) {
        final MihonRuntimeException error =
            DesktopMihonRuntime.decodeErrorResponse(http.Response(body, 502));
        expect(error.code, 'BRIDGE_HTTP_502');
        expect(error.message, 'Mihon bridge request failed');
      }
    },
  );
}
