import 'dart:typed_data';

/// 能用「与互联其余流量相同的钉扎客户端」拉取远端封面字节的能力。
///
/// TODO-1235（TODO-961 回归）：TLS 默认开后对端封面 URL 变成
/// `https://host/api/library/{videos|books}/<id>/cover`，自签证书只能靠 TOFU 钉扎
/// 指纹接受。`Image.network` 走 Flutter 内部 HttpClient，没有
/// `HttpClient.badCertificateCallback`、拿不到钉扎指纹 → https 握手必失败 → 空封面
/// （视频流/字幕已走 pinned client 故能播放，封面却漏了）。故封面必须复用互联的
/// pinned client：实现（`InterconnectSyncBackend`）用 `_ops.buildRequest` 发 GET，
/// https 走 pinned client（证书指纹相等才接受自签），明文 http 走裸 client（老路径
/// 字节不变），并补 Basic auth。
abstract class RemoteCoverFetcher {
  /// 拉取 [coverUrl] 指向的封面为字节。失败（非 2xx / 握手失败 / 网络异常）抛异常，
  /// 由 [RemoteCoverImage] 转成占位图。
  Future<Uint8List> fetchRemoteCover(String coverUrl);

  /// 本取图器的**磁盘缓存命名空间**（BUG-1693 批审计：封面缓存串味）。
  ///
  /// 磁盘封面缓存跨重启存活，键此前只有裸 id（video.id / 书名）——两台不同对端、
  /// 或重新配对后的新对端，同名条目会共用同一个缓存文件（与 `RemoteLibraryCache`
  /// 按 sourceId 分槽的纪律相反，BUG-1202 的教训在磁盘层重演）。命名空间由来源
  /// 自己申报（与 [RemoteLibrarySource.remoteLibrarySourceId] 同款「编译器强制
  /// 登记」），实现应取**配对身份级**的值：换 IP 不该变（封面没变，别白白重下，
  /// BUG-847），换对端 / 重新配对必须变。
  String get coverCacheNamespace;
}

/// 若 [client] 具备封面拉取能力则返回它，否则 null（调用方退回占位图）。
RemoteCoverFetcher? remoteCoverFetcherFor(Object? client) =>
    client is RemoteCoverFetcher ? client : null;
