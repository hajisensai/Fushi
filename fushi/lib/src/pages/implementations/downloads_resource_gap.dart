import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';

/// 下载页「资源」标签的前置条件缺口：缺的到底是哪一环。
///
/// BUG-1706：这三种情况此前在页面里一律折叠成一个 `null`，于是「下载后端配得
/// 好好的、只是还没有受管视频来源」也被报成「请先配置下载后端」。用户照提示跳
/// 到下载设置页，看见 qBittorrent 地址账密俱全、连接正常，就此卡死——提示把他
/// 指向了一个根本没问题的地方。原因分开，提示和按钮才能各自指对地方。
///
/// 判定顺序本身也是契约（见 [findDownloadsResourceGap]），所以整段决策收在这个
/// 纯函数里，不掺 I/O、不依赖数据库，便于钉住。
sealed class DownloadsResourceGap {
  const DownloadsResourceGap();
}

/// 下载后端没配好，或配了但连不上 → 该去「下载设置」。
class DownloadsResourceNoBackend extends DownloadsResourceGap {
  const DownloadsResourceNoBackend({this.detail});

  /// 后端自己给出的不可用原因（如内置引擎缺运行时）；null = 压根还没配置。
  final String? detail;
}

/// 后端没问题，缺的是下载完成后落地用的受管视频来源 → 该去加一个本地视频文件夹。
class DownloadsResourceNoManagedSource extends DownloadsResourceGap {
  const DownloadsResourceNoManagedSource();
}

/// 判断「资源」标签缺哪一环；返回 null = 前置条件齐备，可以搜资源。
///
/// 顺序是有意的：先问后端在不在（不在就谈不上别的），再问有没有落地用的受管
/// 视频来源，最后才去解析后端身份——身份解析要连真后端，没来源时白连一趟。
///
/// [backendReady]：资源注册表与下载流水线都已就绪。
/// [managedSourceCount]：`getManagedVideoDownloadSources()` 过滤后的来源条数
/// （必须是真实存在的本地绝对路径目录，网络来源不算）。
/// [identityError]：解析后端身份时抛出的异常；null = 没抛。
DownloadsResourceGap? findDownloadsResourceGap({
  required bool backendReady,
  required int managedSourceCount,
  required Object? identityError,
}) {
  if (!backendReady) return const DownloadsResourceNoBackend();
  if (managedSourceCount <= 0) return const DownloadsResourceNoManagedSource();
  if (identityError == null) return null;
  // 后端配了但连不上：把后端自己给出的原因透传，别退化成「请先配置」——
  // 用户已经配过了，再叫他去配一遍只会让他反复确认同一份正确配置。
  if (identityError is VideoDownloadBackendUnavailable) {
    return DownloadsResourceNoBackend(detail: identityError.message);
  }
  return const DownloadsResourceNoBackend();
}
