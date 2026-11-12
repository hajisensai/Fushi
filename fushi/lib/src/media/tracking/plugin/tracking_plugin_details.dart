/// What a tracking plugin package is and may do: shown before install
/// (with Install / Update) and read-only for an installed plugin.
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_labels.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Asks before installing [info]. [update]: a plugin with this id is already
/// installed ([installedVersion]: its version, shown as "old -> new").
/// [signerChanged]: installing erases its saved sign-in and data. Returns
/// true when the user confirmed.
Future<bool> confirmTrackingPluginInstall(
  BuildContext context, {
  required TrackingPluginInfo info,
  required bool update,
  required bool signerChanged,
  String? installedVersion,
}) => showFushiConfirmDialog(
  context: context,
  title: update
      ? t.media_tracking_plugins_update_title
      : t.media_tracking_plugins_install_title,
  icon: FushiIcons.browserExtension,
  confirmLabel: update
      ? t.media_tracking_plugins_update_confirm
      : t.media_tracking_plugins_install_confirm,
  cancelLabel: t.cancel,
  content: TrackingPluginDetails(
    info: info,
    signerChanged: signerChanged,
    installedVersion: update ? installedVersion : null,
  ),
);

/// The details of an installed plugin, read-only.
///
/// [builtIn]: the plugin ships with Fushi (the bundled Bangumi plugin).
Future<void> showTrackingPluginDetails(
  BuildContext context, {
  required TrackingPluginInfo info,
  bool builtIn = false,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    icon: const FushiIcon(FushiIcons.browserExtension),
    title: Text(info.name),
    // The name is the dialog's title already.
    content: TrackingPluginDetails(info: info, builtIn: builtIn, showName: false),
    actions: <Widget>[
      FushiTextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(t.media_tracking_close),
      ),
    ],
  ),
);

/// Name, version, author, site, kinds, permissions in plain words, every
/// network domain and the signer state of a package.
class TrackingPluginDetails extends StatelessWidget {
  const TrackingPluginDetails({
    required this.info,
    this.signerChanged = false,
    this.builtIn = false,
    this.showName = true,
    this.installedVersion,
    super.key,
  });

  final TrackingPluginInfo info;

  /// An update: the installed version, shown before the new one (T2 G16).
  final String? installedVersion;

  /// Ships with Fushi: who made it is not a question (T1 F11 b).
  final bool builtIn;

  /// False where the name is already shown (the details dialog's title).
  final bool showName;

  /// The installed plugin with this id has another signer.
  final bool signerChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TrackingPluginSite? site = info.site;
    final double gap = tokens.spacing.gap * 0.5;
    final List<Widget> children = <Widget>[
      if (showName) Text(info.name, style: type.titleMedium),
      Text(
        <String>[
          switch (installedVersion) {
            final String from when from != info.version =>
              t.media_tracking_plugins_update_version(
                from: from,
                to: info.version,
              ),
            _ => t.media_tracking_plugins_version_label(version: info.version),
          },
          if (info.author != null)
            t.media_tracking_plugins_author_label(author: info.author!),
        ].join(' · '),
        style: type.bodySmall,
      ),
      if (info.description != null)
        Text(info.description!, style: type.bodyMedium),
      if (site != null) ...<Widget>[
        _Labeled(
          label: t.media_tracking_plugins_site_label,
          value: site.siteHost,
        ),
        _Labeled(
          label: t.media_tracking_plugins_kinds_label,
          value: trackingPluginKindsText(site),
        ),
      ],
      _Labeled(
        label: t.media_tracking_plugins_permissions_label,
        value: info.permissions.isEmpty
            ? t.media_tracking_plugins_permissions_none
            : info.permissions.map(trackingPluginPermissionLabel).join('\n'),
      ),
      if (info.networkDomains.isNotEmpty)
        _Labeled(
          label: t.media_tracking_plugins_domains_label,
          value: info.networkDomains.join('\n'),
        ),
      _Note(
        icon: builtIn || info.trustedSigner
            ? FushiIcons.verified
            : FushiIcons.warning,
        text: builtIn
            ? t.media_tracking_plugins_built_in_note
            : trackingPluginSignerText(info),
      ),
      if (signerChanged)
        _Note(
          key: const ValueKey<String>('tracking-plugin-signer-changed'),
          icon: FushiIcons.warning,
          text: t.media_tracking_plugins_signer_changed,
          color: cs.error,
        ),
    ];
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: gap,
        children: <Widget>[
          for (int i = 0; i < children.length; i++)
            FushiStaggeredEntrance(index: i, child: children[i]),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: type.labelLarge),
        Text(value, style: type.bodyMedium),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color, super.key});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap * 0.5,
      children: <Widget>[
        FushiIcon(icon, size: 18, color: color),
        Expanded(
          child: Text(
            text,
            style: context.fushiType.bodySmall.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
