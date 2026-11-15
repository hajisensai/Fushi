/// 「试听」标记（反馈 okvRZINcQU，哈吉 2026-11 拍板「和 BD 标记类似」）：Apple Music 没有整曲
/// 播放（未登录 / 无订阅 / 本平台没有 MusicKit 播放器）时只放约 30 秒的预览片段，曲目行、
/// 单曲 / 专辑 / 歌单卡、正在播放条与歌词页都挂同一枚角标，与原盘规格角标（BD / UHD / DVD）
/// 同一个 [CoverBadge]（MD3 与 Apple 两套观感由它分）。
///
/// 判据只有两处、各管一层：浏览器层 [musicServerPreviewOnly]（列表 / 卡片，还没起播），
/// 播放项层 [MusicPlayItem.isPreview]（取到的流本身是试听片段，见 `MusicServerStream.isPreview`）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show AppleMusicCatalogClient;
import 'package:fushi_engine/media/music/server/music_server.dart'
    show MusicServerBrowser;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 这个来源只能放试听片段（列出的曲目点开都是约 30 秒的预览）。
bool musicServerPreviewOnly(MusicServerBrowser browser) =>
    browser is AppleMusicCatalogClient && browser.previewOnly;

/// 「试听」角标。读屏读完整说明（「仅试听片段，不是整首」），角标文字本身不进语义树。
class MusicPreviewBadge extends StatelessWidget {
  const MusicPreviewBadge({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: t.music_preview_badge_semantics,
    child: ExcludeSemantics(child: CoverBadge(label: t.music_preview_badge)),
  );
}

/// 随当前曲目切换显隐的「试听」角标（正在播放条 / 歌词页）：换曲时淡入淡出，墨水屏 /
/// 减弱动态效果下瞬间到位（[fushiMotionDuration]）。不显示时不占位。
class MusicPreviewBadgeSwitcher extends StatelessWidget {
  const MusicPreviewBadgeSwitcher({
    super.key,
    required this.visible,
    this.padding = const EdgeInsetsDirectional.only(start: 6),
  });

  final bool visible;

  /// 显示时与左侧文字的间距（不显示时不留）。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: fushiMotionDuration(context, FushiMotion.short),
    child: visible
        ? Padding(
            key: const ValueKey<String>('music-preview-badge'),
            padding: padding,
            child: const MusicPreviewBadge(),
          )
        : const SizedBox.shrink(key: ValueKey<String>('music-preview-none')),
  );
}
