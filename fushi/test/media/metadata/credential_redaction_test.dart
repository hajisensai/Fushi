import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';

/// BUG-1219 审查发现的凭据泄露守卫。
///
/// PR#548 把刮削失败的完整异常文本摆进弹窗（可选中 + 一键复制）。而 TMDB 是
/// key-in-query，`package:http` 的 `ClientException.toString()` 会把整个请求 URL
/// （含 `api_key`）拼进异常。于是用户的 TMDB key 会同时出现在：界面、剪贴板、
/// 错误日志文件、日志上传。这里钉住「抛出去的异常文本里没有 key 值」。
void main() {
  const String key = 'SECRET_TMDB_KEY_1234567890';

  /// 复刻 package:http `IOClient` 在 DNS 失败时的真实抛法：
  /// `_ClientSocketException extends ClientException`，`super(e.message, request.url)`，
  /// 其 `toString()` 是 `'ClientException: $message, uri=$uri'`。
  TmdbClient clientThatFailsTransport() => TmdbClient(
        apiKey: key,
        client: MockClient((http.Request req) async {
          throw http.ClientException(
              "Failed host lookup: 'api.themoviedb.org'", req.url);
        }),
      );

  test('TMDB 传输失败：抛出的异常文本不含 api_key 值，但保留参数名与主机名', () async {
    try {
      await clientThatFailsTransport().search('Yani Neko');
      fail('should throw');
    } on ScrapeNetworkException catch (e) {
      final String text = e.toString();
      // 🔴 核心：用户的 key 一个字符都不能出现。
      expect(text.contains(key), isFalse, reason: 'api_key 值泄露进了异常文本：$text');
      // 仍要留下可排查的信息：知道带了 api_key、知道是哪个主机、知道底层原因。
      expect(text, contains('api_key=$kRedactedPlaceholder'));
      expect(text, contains('api.themoviedb.org'));
      expect(text, contains('Failed host lookup'));
    }
  });

  test('纯函数：各类凭据参数被脱敏，非凭据参数原样保留', () {
    const String raw = 'uri=https://h/p?query=Yani+Neko&api_key=AAA&token=BBB'
        '&password=CCC&client_secret=DDD&language=zh-CN&page=2';
    final String out = redactCredentialsInText(raw);
    for (final String secret in <String>['AAA', 'BBB', 'CCC', 'DDD']) {
      expect(out.contains(secret), isFalse, reason: '$secret 未被脱敏：$out');
    }
    // 非凭据参数不动（否则排查信息被无谓抹掉）。
    expect(out, contains('query=Yani+Neko'));
    expect(out, contains('language=zh-CN'));
    expect(out, contains('page=2'));
  });

  test('纯函数：值终止符覆盖引号/括号/空白包裹的真实拼法', () {
    expect(redactCredentialsInText('a?api_key=XYZ was refused'),
        'a?api_key=$kRedactedPlaceholder was refused');
    expect(redactCredentialsInText('("https://h/p?token=XYZ")'),
        '("https://h/p?token=$kRedactedPlaceholder")');
    expect(redactCredentialsInText('h/p?key=XYZ&next=1'),
        'h/p?key=$kRedactedPlaceholder&next=1');
  });

  test('纯函数：空值与无 query 文本不被破坏', () {
    expect(redactCredentialsInText(''), '');
    expect(redactCredentialsInText('SocketException: no route to host'),
        'SocketException: no route to host');
    // 空值参数保持原样（没有值可泄露，也不该凭空插入占位符）。
    expect(redactCredentialsInText('?api_key=&x=1'), '?api_key=&x=1');
  });
}
