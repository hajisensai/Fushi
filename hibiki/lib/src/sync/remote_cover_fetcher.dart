import 'dart:typed_data';

/// 能用「与互联其余流量相同的钉扎客户端」拉取远端封面字节的能力。
///
/// TODO-1235（TODO-961 回归）：TLS 默认开后对端封面 URL 变成
/// `https://host/api/library/{videos|books}/<id>/cover`，自签证书只能靠 TOFU 钉扎
/// 指纹接受。`Image.network` 走 Flutter 内部 HttpClient，没有
/// `HttpClient.badCertificateCallback`、拿不到钉扎指纹 → https 握手必失败 → 空封面
/// （视频流/字幕已走 pinned client 故能播放，封面却漏了）。故封面必须复用互联的
/// pinned client：实现（`HibikiClientSyncBackend`）用 `_ops.buildRequest` 发 GET，
/// https 走 pinned client（证书指纹相等才接受自签），明文 http 走裸 client（老路径
/// 字节不变），并补 Basic auth。
abstract class RemoteCoverFetcher {
  /// 拉取 [coverUrl] 指向的封面为字节。失败（非 2xx / 握手失败 / 网络异常）抛异常，
  /// 由 [RemoteCoverImage] 转成占位图。
  Future<Uint8List> fetchRemoteCover(String coverUrl);
}

/// 若 [client] 具备封面拉取能力则返回它，否则 null（调用方退回占位图）。
RemoteCoverFetcher? remoteCoverFetcherFor(Object? client) =>
    client is RemoteCoverFetcher ? client : null;
