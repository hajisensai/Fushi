import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/manga_cover_failure.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

/// Aidoku 源封面：浏览器 UA（+ 源站 Referer）经应用代理出口取图。
///
/// BUG-2450 之前这里是纯内存的 `AppHttpImage`，每次进页面都重下一遍，失败态还是
/// 一个不可点的破图。现在走 [AppCachedHttpImage]（磁盘缓存 + 文件服务层的退避
/// 重试），失败态给 [MangaCoverFailure] 的重试入口；单源浏览页与全源搜索页共用。
class AidokuCoverImage extends StatefulWidget {
  const AidokuCoverImage({required this.url, this.referer, super.key});

  final String? url;
  final String? referer;

  @override
  State<AidokuCoverImage> createState() => _AidokuCoverImageState();
}

class _AidokuCoverImageState extends State<AidokuCoverImage> {
  /// 每次手动重试 +1：作为 [Image] 的 key 让它重新 resolve。provider 本身按
  /// url+headers 判等，同值的新实例不会触发 `Image.didUpdateWidget` 重新加载。
  int _attempt = 0;

  AppCachedHttpImage _provider(String url) => AppCachedHttpImage(
        url,
        headers: <String, String>{
          'User-Agent': kAidokuUserAgent,
          if (widget.referer != null) 'Referer': widget.referer!,
        },
      );

  void _retry(String url) {
    // 失败的加载本已被 provider 从全局 ImageCache 驱逐（否则一次瞬断会把这张图
    // 钉死成永久破图）；这里再驱逐一次只是兜住驱逐微任务尚未跑到的窗口。
    PaintingBinding.instance.imageCache.evict(_provider(url));
    setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final String value = widget.url?.trim() ?? '';
    if (value.isEmpty) {
      // 占位底跟随主题中性色：此前的黑 7% 在深色主题下等于没有底。
      final ColorScheme cs = Theme.of(context).colorScheme;
      return ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: FushiIcon(
            Icons.image_not_supported_outlined,
            color: cs.onSurfaceVariant,
          ),
        ),
      );
    }
    return Image(
      key: ValueKey<int>(_attempt),
      image: _provider(value),
      fit: BoxFit.cover,
      errorBuilder: (BuildContext _, Object error, StackTrace? __) =>
          MangaCoverFailure(
        error: error,
        onRetry: () => _retry(value),
      ),
    );
  }
}
