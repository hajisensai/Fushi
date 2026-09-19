/// 播放前把条目地址换成**此刻**真正可播的 URL。
///
/// 来源库条目落库的是稳定地址（改密码 / 签名过期都不该让行级数据失效），而有些
/// 来源（AList / OpenList）的可播地址带临期签名，只能在起播那一刻现取。
/// `UrlStreamVideoClient` 在每次 `remoteVideoStreamUrls` / 字幕下载前调一次
/// [resolve]，与 YouTube 的「播放前重解析」同一挂点。
library;

abstract class StreamUrlResolver {
  /// [url] 是落库的条目地址（视频流或 sidecar 字幕）。不归本解析器管的地址
  /// **原样返回**，不抛——来源根下的 m3u8 清单可以指向第三方主机。
  Future<String> resolve(String url);

  /// 释放底层连接；幂等。
  void close() {}
}
