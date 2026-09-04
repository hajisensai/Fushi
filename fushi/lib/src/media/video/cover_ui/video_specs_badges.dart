/// 封面左下角的规格角标（v95）：`4K` / `HDR10`。
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

import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/video_specs_display.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';

/// 压在封面左下角的规格角标条。规格未知时**整个不占位**（返回 SizedBox.shrink）。
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
      _prime();
    }
  }

  void _prime() {
    final VideoSpecsService? service = widget.service;
    final String? path = widget.filePath;
    if (service == null || path == null || path.isEmpty) return;
    // 流 URL 不是本地文件，ffprobe 探不了，别白起进程。
    if (isProbableStreamUrl(path)) return;
    service.prime(<String>[path]);
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String badge in badges) ...<Widget>[
              if (badge != badges.first) const SizedBox(width: 4),
              CoverBadge(label: badge),
            ],
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
bool isProbableStreamUrl(String path) {
  final String lower = path.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}
