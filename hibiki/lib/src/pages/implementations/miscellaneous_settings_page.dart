import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/base_page.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/utils/misc/app_icon_preferences.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/window_caption_channel.dart';
import 'package:hibiki/utils.dart';

/// 应用图标（app icon）设置子页。薄壳：把 [MiscellaneousSettingsBody] 投影进与
/// 统一设置详情面板完全一致的页壳（见 [buildSettingsDetailShell]），不再使用自带
/// 的 [AdaptiveSettingsScaffold]——从「外观」设置点进来不会再有脚手架/卡片风格跳变
/// （TODO-317）。正文是 Android/Windows 的图标网格，故走 `SettingsDestination.body`
/// 逃生口而非 schema items。
class MiscellaneousSettingsPage extends BasePage {
  const MiscellaneousSettingsPage({super.key});

  @override
  BasePageState<MiscellaneousSettingsPage> createState() =>
      _MiscellaneousSettingsPageState();
}

class _MiscellaneousSettingsPageState
    extends BasePageState<MiscellaneousSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );

    final SettingsDestination destination = SettingsDestination(
      id: SettingsDestinationId.appearance,
      title: t.app_icon_label,
      icon: Icons.widgets_outlined,
      sections: const <SettingsSection>[],
      body: (_) => const MiscellaneousSettingsBody(),
    );

    return buildSettingsDetailShell(
      context: context,
      settingsContext: settingsContext,
      destination: destination,
    );
  }
}

/// 应用图标设置正文（无脚手架）。返回一个 [Column]，自身不带 `Scaffold` / 独立
/// 滚动——外层（统一设置详情壳或脚手架）已提供滚动与内边距，与 [AnkiSettingsBody]
/// / [ProfileManagementBody] 同范式。
class MiscellaneousSettingsBody extends BasePage {
  const MiscellaneousSettingsBody({super.key});

  @override
  BasePageState<MiscellaneousSettingsBody> createState() =>
      _MiscellaneousSettingsBodyState();
}

class _MiscellaneousSettingsBodyState
    extends BasePageState<MiscellaneousSettingsBody> {
  String _currentIcon = 'default';
  bool _switching = false;
  bool _customSupported = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentIcon();
  }

  Future<void> _loadCurrentIcon() async {
    if (Platform.isAndroid) {
      final results = await Future.wait([
        HibikiChannels.iconSwitch.invokeMethod<String>('getCurrentIcon'),
        HibikiChannels.iconSwitch
            .invokeMethod<bool>('isCustomShortcutSupported'),
      ]);
      if (!mounted) return;
      setState(() {
        _currentIcon = (results[0] as String?) ?? 'default';
        _customSupported = (results[1] as bool?) ?? false;
      });
    } else if (Platform.isWindows) {
      final String key = await loadIconPresetKey();
      if (!mounted) return;
      setState(() {
        _currentIcon = key;
        _customSupported = true; // Windows 支持任意图片
      });
    }
  }

  Future<void> _switchPreset(String key) async {
    if (_switching || _currentIcon == key) return;
    setState(() => _switching = true);

    try {
      bool ok = false;
      if (Platform.isAndroid) {
        ok = (await HibikiChannels.iconSwitch.invokeMethod<bool>(
              'switchPresetIcon',
              {'alias': key},
            )) ==
            true;
      } else if (Platform.isWindows) {
        final String path = await exportPresetIconToFile(key);
        ok = await WindowCaptionChannel.setWindowIcon(path);
      }
      if (ok && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        await saveIconPresetKey(key);
        if (!mounted) return;
        setState(() => _currentIcon = key);
        messenger.showSnackBar(
          SnackBar(content: Text(t.icon_switch_success)),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _pickCustomIcon() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.icon_custom_confirm_title,
            leadingIcon: Icons.add_photo_alternate_outlined,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: Text(t.icon_custom_confirm_body),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: [
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true) return;

    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    bool ok = false;
    if (Platform.isAndroid) {
      final bytes = await file.readAsBytes();
      ok = (await HibikiChannels.iconSwitch.invokeMethod<bool>(
            'createCustomShortcut',
            {'imageBytes': bytes},
          )) ==
          true;
    } else if (Platform.isWindows) {
      final String persisted = await persistCustomIconFile(file.path);
      ok = await WindowCaptionChannel.setWindowIcon(persisted);
      if (ok) {
        await saveCustomIconPath(persisted);
        await saveIconPresetKey(customIconKey);
        if (mounted) setState(() => _currentIcon = customIconKey);
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(Platform.isAndroid
            ? (ok ? t.icon_shortcut_created : t.icon_shortcut_unsupported)
            : (ok ? t.icon_switch_success : t.icon_shortcut_unsupported)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (Platform.isAndroid || Platform.isWindows)
          AdaptiveSettingsSection(
            title: t.app_icon_label,
            children: [
              AdaptiveSettingsRow(
                title: t.app_icon_label,
                controlBelow: true,
                trailing: _buildIconGrid(),
              ),
              if (_customSupported) ...[
                AdaptiveSettingsRow(
                  title: t.icon_custom_hint,
                ),
              ],
            ],
          )
        else
          AdaptiveSettingsSection(
            title: t.app_icon_label,
            children: [
              AdaptiveSettingsRow(
                title: t.icon_shortcut_unsupported,
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildIconGrid() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final presets = [
      _IconOption(
        key: 'default',
        label: t.icon_default,
        asset: presetIconAssets['default']!,
      ),
      _IconOption(
        key: 'hibiki_full',
        label: t.icon_full,
        asset: presetIconAssets['hibiki_full']!,
      ),
    ];

    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: [
        for (final preset in presets) _buildPresetTile(preset),
        if (_customSupported) _buildCustomTile(),
      ],
    );
  }

  Widget _buildPresetTile(_IconOption option) {
    final bool selected = _currentIcon == option.key;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return _AppIconTile(
      label: option.label,
      selected: selected,
      enabled: !_switching,
      onTap: () => _switchPreset(option.key),
      child: ClipRRect(
        borderRadius: tokens.radii.chipRadius,
        child: Image.asset(option.asset, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildCustomTile() {
    return _AppIconTile(
      label: t.icon_custom,
      enabled: !_switching,
      onTap: _pickCustomIcon,
      child: Icon(
        Icons.add_photo_alternate_outlined,
        size: 32,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _AppIconTile extends StatelessWidget {
  const _AppIconTile({
    required this.label,
    required this.child,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
  });

  final String label;
  final Widget child;
  final VoidCallback onTap;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SizedBox(
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 72,
            child: HibikiCard(
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              selected: selected,
              borderColor: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              onTap: enabled ? onTap : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child,
                  if (selected)
                    Align(
                      alignment: Alignment.bottomRight,
                      child: HibikiBadge(
                        icon: Icons.check,
                        background: theme.colorScheme.primary,
                        foreground: theme.colorScheme.onPrimary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconOption {
  const _IconOption({
    required this.key,
    required this.label,
    required this.asset,
  });
  final String key;
  final String label;
  final String asset;
}
