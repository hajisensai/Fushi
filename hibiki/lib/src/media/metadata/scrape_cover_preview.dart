import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

const double kScrapeCoverPreviewWidth = 80;
const double kScrapeCoverPreviewHeight = 112;

/// 书籍、漫画、视频、游戏刮削候选共用的可辨识封面预览。
class ScrapeCoverPreview extends StatelessWidget {
  const ScrapeCoverPreview({
    super.key,
    required this.url,
  });

  final String? url;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget placeholder = ColoredBox(
      color: tokens.surfaces.overlay,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 28,
          color: tokens.surfaces.onVariant,
        ),
      ),
    );
    final String? normalized =
        url?.trim().isEmpty == false ? url!.trim() : null;
    return SizedBox(
      width: kScrapeCoverPreviewWidth,
      height: kScrapeCoverPreviewHeight,
      child: ClipRRect(
        borderRadius: HibikiBorderRadius.chip,
        child: normalized == null
            ? placeholder
            : Image.network(
                normalized,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}
