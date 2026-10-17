/// 封面左下角的规格角标（v95）：`4K` / `HDR10` / `Atmos`（或 `7.1` / `5.1`）。
///
/// 单独一个 widget 而不是在 `_buildCard` 里内联，是为了**把重建面钉死在角标本身**。
/// [VideoSpecsService] 每探完一个文件就通知一次（滚一屏几十次），如果在库页
/// `build` 顶部订阅，那 3000 行的整页会跟着反复重建。这里自己订阅、自己重建，
/// 卡片其余部分一动不动。
///
/// 探测也由它发起：卡片进入视口才 build，于是天然只探可见的那些——库里有几千个
/// 文件也不会一次全 ffprobe。
///
/// **服务由调用方注入，本 widget 不碰 riverpod。** 规格 UI 要落在几个不同宿主上，
/// 其中 `MediaCollectionDetailPage` / `VideoWorkDetailPage` 是普通 StatefulWidget，
/// 它们的既有 widget 测试没有（也不需要）`ProviderScope`——在里面塞 ConsumerWidget
/// 会让那些测试全部抛。注入让依赖显式，也让「不传就不显示」成为测试宿主的默认行为。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/video_specs_display.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi_engine/media/video/strm_file.dart'
    show lacksLocalMediaFile;

/// 压在封面左下角的规格角标条。规格未知时**整个不占位**（返回 SizedBox.shrink）。
///
/// 宿主要给它**有界宽度**（左右都钉住）：窄卡（约 154px）放不下三个角标时，排不下的
/// 往**上**换一行，而不是溢出卡边——首行贴底的仍是清晰度 / HDR。
class VideoSpecsBadgeStrip extends StatefulWidget {
  const VideoSpecsBadgeStrip({
    required this.service,
    required this.filePath,
    super.key,
  });

  /// 规格服务；null = 宿主没提供（测试或未接线），不显示也不探测。
  final VideoSpecsService? service;

  /// 视频文件绝对路径。null / 空（流媒体条目、远端占位卡）时不探也不显示。
  final String? filePath;

  @override
  State<VideoSpecsBadgeStrip> createState() => _VideoSpecsBadgeStripState();
}

class _VideoSpecsBadgeStripState extends State<VideoSpecsBadgeStrip> {
  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(VideoSpecsBadgeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GridView 复用 element：同一个 widget 位置可能换成另一个文件。
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.service != widget.service) {
      _unprime(oldWidget.service);
      _prime();
    }
  }

  @override
  void dispose() {
    _unprime(widget.service);
    super.dispose();
  }

  /// 本 widget 当前持有的路径（已 retain 过的那个），用于换路径 / 卸载时精确撤回。
  String? _held;

  void _prime() {
    final VideoSpecsService? service = widget.service;
    final String? path = widget.filePath;
    if (service == null || path == null || path.isEmpty) return;
    // 流 URL 不是本地文件，ffprobe 探不了，别白起进程。
    if (isProbableStreamUrl(path)) return;
    service.retain(path);
    _held = path;
    service.prime(<String>[path]);
  }

  /// 撤回 [_prime] 的 retain。**必须走 [_held] 而不是当前 `widget.filePath`**：
  /// didUpdateWidget 里要撤的是**旧**路径，而那时 widget 已经换成新的了。
  void _unprime(VideoSpecsService? service) {
    final String? held = _held;
    if (held == null) return;
    _held = null;
    service?.release(held);
  }

  @override
  Widget build(BuildContext context) {
    final VideoSpecsService? service = widget.service;
    final String? path = widget.filePath;
    if (service == null || path == null || path.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final List<String> badges =
            videoSpecsCoverBadges(service.specsFor(path));
        if (badges.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          verticalDirection: VerticalDirection.up,
          children: <Widget>[
            for (final String badge in badges) CoverBadge(label: badge),
          ],
        );
      },
    );
  }
}

/// 是不是 http(s) 流地址（`VideoBooks.videoPath` 的三态之一）。
///
/// 放在这里而不是 service 里：service 拿到什么探什么，「这条路径值不值得探」是调用
/// 侧的判断。流地址 ffprobe 理论上能探，但那会在滚动列表时对每个远端条目发起网络
/// 请求——库页绝不做这种事。
bool isProbableStreamUrl(String path) =>
    // http(s)、IPTV 频道（rtsp / rtmp / udp …）与 `.strm` 流指针同属「不值得在
    // 库页探」：前两者是网络流，后者是一行文本，真正的流要起播时才读出来。
    lacksLocalMediaFile(path);
