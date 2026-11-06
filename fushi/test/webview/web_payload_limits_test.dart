import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/webview/untrusted_page_urls.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';

void main() {
  group('webPayloadWithinLimit', () {
    test('字符串、map、list 都计入；恰好到上限仍放行，超一个字符就拒', () {
      expect(webPayloadWithinLimit('a' * 10, maxChars: 10), isTrue);
      expect(webPayloadWithinLimit('a' * 11, maxChars: 10), isFalse);
      expect(
        webPayloadWithinLimit(<String, Object?>{
          'k': 'v' * 1000,
        }, maxChars: 500),
        isFalse,
      );
      expect(
        webPayloadWithinLimit(<Object?>[
          'x' * 300,
          <Object?>['y' * 300],
        ], maxChars: 500),
        isFalse,
      );
      expect(
        webPayloadWithinLimit(<Object?>[
          <String, Object?>{'type': 'state', 't': 12, 'paused': true},
        ], maxChars: kWebPayloadSmallMaxChars),
        isTrue,
      );
    });

    test('嵌套过深直接拒', () {
      Object? deep = 'leaf';
      for (int i = 0; i < kWebPayloadMaxDepth + 2; i++) {
        deep = <Object?>[deep];
      }
      expect(
        webPayloadWithinLimit(deep, maxChars: kWebPayloadLargeMaxChars),
        isFalse,
      );
    });

    test('limitWebPayload：超限不进回调、回 null；未超限原样转发', () {
      int calls = 0;
      final dynamic Function(List<dynamic>) handler = limitWebPayload(
        'test',
        16,
        (List<dynamic> args) {
          calls++;
          return 'ok';
        },
      );
      expect(handler(<dynamic>['short']), 'ok');
      expect(handler(<dynamic>['x' * 100]), isNull);
      expect(calls, 1);
    });
  });

  group('trustedPageHref', () {
    test('同主机采信上报值；换主机 / 非 http(s) 退回 WebView 地址', () {
      const String page = 'https://www.netflix.com/browse';
      expect(
        trustedPageHref('https://www.netflix.com/watch/81', page),
        'https://www.netflix.com/watch/81',
      );
      expect(
        trustedPageHref('https://WWW.NETFLIX.COM/watch/81', page),
        'https://WWW.NETFLIX.COM/watch/81',
      );
      expect(trustedPageHref('https://evil.example/watch/81', page), page);
      expect(trustedPageHref('javascript:alert(1)', page), page);
      expect(trustedPageHref('', page), page);
    });

    test('WebView 地址未知时只保留 http(s) 上报值', () {
      expect(trustedPageHref('https://a.test/x', null), 'https://a.test/x');
      expect(trustedPageHref('file:///etc/passwd', null), '');
    });
  });

  group('safeRemoteImageUrl', () {
    test('只收 https 远端地址', () {
      expect(
        safeRemoteImageUrl('https://occ.nflxso.net/a.jpg').toString(),
        'https://occ.nflxso.net/a.jpg',
      );
      expect(safeRemoteImageUrl('http://cdn.test/a.jpg'), isNull);
      expect(safeRemoteImageUrl('https://localhost/a.jpg'), isNull);
      expect(safeRemoteImageUrl('https://127.0.0.1:8080/a.jpg'), isNull);
      expect(safeRemoteImageUrl('https://[::1]/a.jpg'), isNull);
      expect(safeRemoteImageUrl('file:///c:/a.jpg'), isNull);
      expect(safeRemoteImageUrl('data:image/png;base64,AAAA'), isNull);
      expect(safeRemoteImageUrl(''), isNull);
    });
  });
}
