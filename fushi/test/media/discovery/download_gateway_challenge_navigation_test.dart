// BUG-4339：WebView 解题页的「解完」判据。网关脚本解完题后写一次性 cookie
// （或拼 `__ct` 查询参数）并 `location.replace` 回原资源 URL；脚本自己的
// 「题目过期 → reload」也回跳同一 URL，但不会多出任何凭据。判据必须分得开。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/download_gateway_challenge_page.dart';
import 'package:fushi_engine/media/discovery/download_gateway_challenge.dart';

final Uri _challenge = Uri.parse(
  'https://gate.example.net/worker/P/file.rar?sign=abc:1794402936',
);

void main() {
  test('回跳同一资源且新增了 cookie → 放行凭据（URL + 全部 cookie + UA）', () {
    final DownloadGatewayClearance? clearance =
        downloadGatewayClearanceForNavigation(
          challengeUrl: _challenge,
          navigation: _challenge,
          baselineCookies: const <String, String>{'other': '1'},
          currentCookies: const <String, String>{
            'other': '1',
            '__Secure-pow_a': '1|c||consume',
          },
          userAgent: 'Mozilla/5.0 Test',
        );
    expect(clearance, isNotNull);
    expect(clearance!.url, _challenge);
    expect(clearance.headers['Cookie'], 'other=1; __Secure-pow_a=1|c||consume');
    expect(clearance.headers['User-Agent'], 'Mozilla/5.0 Test');
  });

  test('回跳同一资源且多了查询参数（cookie 写不进时的退路）→ 放行凭据', () {
    final Uri withToken = _challenge.replace(
      queryParameters: <String, String>{
        ..._challenge.queryParameters,
        '__ct': 'consume',
      },
    );
    final DownloadGatewayClearance? clearance =
        downloadGatewayClearanceForNavigation(
          challengeUrl: _challenge,
          navigation: withToken,
          baselineCookies: const <String, String>{},
          currentCookies: const <String, String>{},
        );
    expect(clearance, isNotNull);
    expect(clearance!.url.queryParameters['__ct'], 'consume');
    expect(clearance.headers.containsKey('Cookie'), isFalse);
    expect(clearance.headers.containsKey('User-Agent'), isFalse);
  });

  test('回跳同一资源但什么凭据都没多（脚本的过期重载）→ 放行导航', () {
    expect(
      downloadGatewayClearanceForNavigation(
        challengeUrl: _challenge,
        navigation: _challenge,
        baselineCookies: const <String, String>{'x': '1'},
        currentCookies: const <String, String>{'x': '1'},
      ),
      isNull,
    );
  });

  test('导航去别的路径 / 别的 host（解题脚本的子资源、验证接口）→ 放行导航', () {
    const Map<String, String> fresh = <String, String>{'__Secure-pow_a': 'v'};
    expect(
      downloadGatewayClearanceForNavigation(
        challengeUrl: _challenge,
        navigation: Uri.parse('https://gate.example.net/__pow/verify'),
        baselineCookies: const <String, String>{},
        currentCookies: fresh,
      ),
      isNull,
    );
    expect(
      downloadGatewayClearanceForNavigation(
        challengeUrl: _challenge,
        navigation: Uri.parse(
          'https://other.example.net/worker/P/file.rar?sign=abc:1794402936',
        ),
        baselineCookies: const <String, String>{},
        currentCookies: fresh,
      ),
      isNull,
    );
  });

  test('值被改写的同名 cookie 也算新凭据', () {
    expect(
      downloadGatewayClearanceForNavigation(
        challengeUrl: _challenge,
        navigation: _challenge,
        baselineCookies: const <String, String>{'__Secure-pow_a': 'old'},
        currentCookies: const <String, String>{'__Secure-pow_a': 'new'},
      ),
      isNotNull,
    );
  });
}
