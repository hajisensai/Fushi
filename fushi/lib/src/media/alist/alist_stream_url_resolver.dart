/// AList / OpenList 来源的播放期直链解析：条目地址 `<根>/d/<路径>` → 经
/// `/api/fs/get` 换成带临期签名的 `raw_url`。
///
/// 只认本站点 `/d/` 命名空间下的地址；其它地址原样放行（见 [StreamUrlResolver]）。
library;

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/alist/alist_api_client.dart';
import 'package:fushi/src/media/alist/alist_source_url.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';

class AListStreamUrlResolver implements StreamUrlResolver {
  AListStreamUrlResolver({
    required String baseUrl,
    String? username,
    String? password,
    http.Client? client,
  })  : _baseUrl = normalizeAListBaseUrl(baseUrl),
        _api = AListApiClient(
          baseUrl: baseUrl,
          providerId: 'alist-source',
          username: username,
          password: password,
          client: client,
        );

  final String _baseUrl;
  final AListApiClient _api;

  @override
  Future<String> resolve(String url) async {
    final String? path = alistPathFromSourceUrl(baseUrl: _baseUrl, url: url);
    if (path == null) return url;
    final AListFileLink link = await _api.getFile(path);
    return link.rawUrl;
  }

  @override
  void close() => _api.close();
}
