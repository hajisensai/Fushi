import 'package:flutter/foundation.dart';

/// 一台媒体服务器的 URL 凭据换算：给相对地址补上「当前线路 + 令牌」，以及反过来把
/// 带令牌的绝对地址还原成不含线路、不含令牌的相对地址。
///
/// 纯数据（只有字符串字段），可以整个交给后台 isolate 用。
///
/// **为什么两个方向放在一处**：Jellyfin / Emby 的封面 / 字幕地址一律用 `api_key`
/// 查询参数带令牌（见 `jellyfin_video_client.dart` 文件头）。远端清单落盘时必须把
/// 令牌去掉（缓存文件不许含凭据），读回来时再按此刻的线路与令牌补回去
/// （[authorize]）。补与去是同一条规则的两面，分开写迟早一边改了另一边没改，
/// 落盘的地址读回来就拼不对了。
@immutable
class ServerUrlCredentials {
  const ServerUrlCredentials({
    required this.baseUrl,
    required this.token,
    this.queryKey = 'api_key',
  });

  /// 当前线路的根地址（含 scheme、无尾斜杠）。
  final String baseUrl;

  /// 访问令牌；空串 = 没有令牌（[authorize] 不追加查询参数）。
  final String token;

  /// 令牌所在的查询参数名（大小写不敏感地识别）。
  final String queryKey;

  /// 把服务器签发的地址（相对根路径或绝对地址）补成可直接请求的绝对 URL，缺令牌时
  /// 追加 `[queryKey]=<token>`；已经带了就原样返回。
  String authorize(String pathOrUrl) {
    final String absolute =
        pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')
        ? pathOrUrl
        : '$baseUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
    final Uri uri = Uri.parse(absolute);
    if (token.isEmpty ||
        uri.queryParameters.keys.any((String k) => _isCredentialKey(k))) {
      return absolute;
    }
    return '$absolute${uri.hasQuery ? '&' : '?'}$queryKey=$token';
  }

  /// [authorize] 的逆：本线路下的绝对地址 → 去掉令牌参数的相对地址（以 `/` 开头）。
  ///
  /// 不在本线路下的地址（别的主机、换线路之前拼出来的）返回 null：它的根地址无从
  /// 还原，调用方按「没有这个地址」处理，不把它原样落盘。只删令牌参数，其余查询
  /// 参数逐字保留、顺序不变，所以 `authorize(strip(url)!) == url`。
  String? strip(String url) {
    if (!url.startsWith('$baseUrl/')) return null;
    final String rest = url.substring(baseUrl.length);
    final int query = rest.indexOf('?');
    if (query < 0) return rest;
    final List<String> kept = <String>[
      for (final String pair in rest.substring(query + 1).split('&'))
        if (pair.isNotEmpty && !_isCredentialKey(pair.split('=').first)) pair,
    ];
    final String path = rest.substring(0, query);
    return kept.isEmpty ? path : '$path?${kept.join('&')}';
  }

  bool _isCredentialKey(String key) =>
      key.toLowerCase() == queryKey.toLowerCase();
}
