import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

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
    final String? normalized =
        url?.trim().isEmpty == false ? url!.trim() : null;
    final Widget preview = SizedBox(
      width: kScrapeCoverPreviewWidth,
      height: kScrapeCoverPreviewHeight,
      child: ClipRRect(
        borderRadius: HibikiBorderRadius.chip,
        child: normalized == null
            ? _buildPlaceholder(tokens)
            : Image.network(
                normalized,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildPlaceholder(tokens),
              ),
      ),
    );
    if (normalized == null) return preview;
    return Tooltip(
      message: t.preview,
      child: Semantics(
        button: true,
        label: t.preview,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          borderRadius: HibikiBorderRadius.chip,
          onTap: () => _showLargePreview(context, normalized),
          child: preview,
        ),
      ),
    );
  }
}

Widget _buildPlaceholder(
  HibikiDesignTokens tokens, {
  double iconSize = 28,
}) {
  return ColoredBox(
    color: tokens.surfaces.overlay,
    child: Center(
      child: Icon(
        Icons.image_not_supported_outlined,
        size: iconSize,
        color: tokens.surfaces.onVariant,
      ),
    ),
  );
}

Future<void> _showLargePreview(BuildContext context, String url) async {
  final Size viewport = MediaQuery.sizeOf(context);
  final double width = math.max(0, math.min(viewport.width - 48, 720));
  final double height = math.max(0, math.min(viewport.height - 48, 760));
  await showAppDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.82),
    builder: (BuildContext dialogContext) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(dialogContext);
      return HibikiDialogFrame(
        key: const ValueKey<String>('scrape_cover_large_preview'),
        maxWidth: 720,
        maxHeightFactor: 0.9,
        insetPadding: const EdgeInsets.all(24),
        scrollable: false,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(
                color: Theme.of(dialogContext).colorScheme.surface,
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        _buildPlaceholder(tokens, iconSize: 48),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  key: const ValueKey<String>(
                    'scrape_cover_large_preview_close',
                  ),
                  tooltip: t.dialog_close,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
