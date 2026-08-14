import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// Shared visual contract for Mihon APK and Aidoku AIX extension rows.
/// Runtime-specific pages supply metadata and actions; spacing, icon fallback,
/// warning badge, progress, enable switch and buttons stay identical.
class MangaExtensionManagementTile extends StatelessWidget {
  const MangaExtensionManagementTile({
    required this.title,
    required this.subtitle,
    super.key,
    this.iconUrl,
    this.contentWarning = false,
    this.busy = false,
    this.enabled,
    this.onEnabledChanged,
    this.secondaryLabel,
    this.onSecondary,
    this.primaryLabel,
    this.onPrimary,
  });

  final String title;
  final Widget subtitle;
  final String? iconUrl;
  final bool contentWarning;
  final bool busy;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        leading: _ExtensionIcon(url: iconUrl ?? ''),
        title: Row(
          children: <Widget>[
            Flexible(child: Text(title)),
            if (contentWarning) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: FushiDesignTokens.of(context).radii.chipRadius,
                ),
                child: Text(
                  '18+',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: subtitle,
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (enabled != null)
              Switch.adaptive(
                value: enabled!,
                onChanged: onEnabledChanged,
              ),
            if (secondaryLabel != null)
              TextButton(
                onPressed: onSecondary,
                child: Text(secondaryLabel!),
              ),
            if (primaryLabel != null)
              TextButton(
                onPressed: onPrimary,
                child: Text(primaryLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const Icon(Icons.extension_outlined);
    return SizedBox(
      width: 32,
      height: 32,
      child: Image.network(
        url,
        width: 32,
        height: 32,
        errorBuilder: (_, __, ___) => const Icon(Icons.extension_outlined),
        loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
            progress == null ? child : const Icon(Icons.extension_outlined),
      ),
    );
  }
}
