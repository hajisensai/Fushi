import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

/// BUG-1219 审查发现的凭据泄露守卫。
///
/// PR#548 把刮削失败的完整异常文本摆进弹窗（可选中 + 一键复制）。而 TMDB 是
/// key-in-query，`package:http` 的 `ClientException.toString()` 会把整个请求 URL
/// （含 `api_key`）拼进异常。于是用户的 TMDB key 会同时出现在：界面、剪贴板、
/// 错误日志文件、日志上传。这里钉住「抛出去的异常文本里没有 key 值」。
void main() {
  const String key = 'SECRET_TMDB_KEY_1234567890';

  test('metadata_v2 TMDB 传输失败不泄露 query 中的 api_key', () async {
    final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
      client: MockClient((http.Request request) async {
        throw http.ClientException(
          "Failed host lookup: 'api.themoviedb.org'",
          request.url,
        );
      }),
      maxAttempts: 1,
    );
    addTearDown(transport.close);
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: key,
      transport: transport,
    );
    try {
      await provider.search(
        const VideoMetadataSearchRequest(
          title: 'Yani Neko',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      );
      fail('should throw');
    } on VideoMetadataNetworkException catch (error) {
      final String text = error.toString();
      expect(text.contains(key), isFalse, reason: 'api_key 值泄露进了异常文本：$text');
      expect(text, isNot(contains('api_key=')));
      expect(text, contains('TMDB search'));
      expect(text, contains('ClientException'));
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
    expect(
      redactCredentialsInText('a?api_key=XYZ was refused'),
      'a?api_key=$kRedactedPlaceholder was refused',
    );
    expect(
      redactCredentialsInText('("https://h/p?token=XYZ")'),
      '("https://h/p?token=$kRedactedPlaceholder")',
    );
    expect(
      redactCredentialsInText('h/p?key=XYZ&next=1'),
      'h/p?key=$kRedactedPlaceholder&next=1',
    );
  });

  test('纯函数：空值与无 query 文本不被破坏', () {
    expect(redactCredentialsInText(''), '');
    expect(
      redactCredentialsInText('SocketException: no route to host'),
      'SocketException: no route to host',
    );
    // 空值参数保持原样（没有值可泄露，也不该凭空插入占位符）。
    expect(redactCredentialsInText('?api_key=&x=1'), '?api_key=&x=1');
  });
}
