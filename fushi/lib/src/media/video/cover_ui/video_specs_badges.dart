/// 封面左下角的规格角标（v95）：`4K` / `HDR10`。
///
/// 单独一个 widget 而不是在 `_buildCard` 里内联，是为了**把重建面钉死在角标本身**。
/// [VideoSpecsService] 每探完一个文件就通知一次（滚一屏几十次），如果在库页
/// `build` 顶部 `ref.watch(videoSpecsProvider)`，那 3000 行的整页会跟着反复重建。
/// 这里自己订阅、自己重建，卡片其余部分一动不动。
///
/// 探测也由它发起：卡片进入视口才 build，于是天然只探可见的那些——库里有几千个
/// 文件也不会一次全 ffprobe。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_specs_display.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';

/// 压在封面左下角的规格角标条。规格未知时**整个不占位**（返回 SizedBox.shrink）。
class VideoSpecsBadgeStrip extends ConsumerStatefulWidget {
  const VideoSpecsBadgeStrip({required this.filePath, super.key});

  /// 视频文件绝对路径。null / 空（流媒体条目、远端占位卡）时不探也不显示。
  final String? filePath;

  @override
  ConsumerState<VideoSpecsBadgeStrip> createState() =>
      _VideoSpecsBadgeStripState();
}

class _VideoSpecsBadgeStripState extends ConsumerState<VideoSpecsBadgeStrip> {
  @override
  void initState() {
    super.initState();
    // initState 里不能 ref.watch，用 read 拿服务发起探测即可——结果通过 build 里的
    // watch 回来。prime 幂等，已知/在队列里的路径会短路。
    _prime();
  }

  @override
  void didUpdateWidget(VideoSpecsBadgeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GridView 复用 element：同一个 widget 位置可能换成另一个文件。
    if (oldWidget.filePath != widget.filePath) _prime();
  }

  void _prime() {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty) return;
    // 流 URL 不是本地文件，ffprobe 探不了，别白起进程。
    if (isProbableStreamUrl(path)) return;
    ref.read(videoSpecsProvider).prime(<String>[path]);
  }

  @override
  Widget build(BuildContext context) {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    final VideoProbeFacts? facts = ref.watch(videoSpecsProvider).specsFor(path);
    final List<String> badges = videoSpecsCoverBadges(facts);
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
