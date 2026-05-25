import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/base_page.dart';
import 'package:hibiki/utils.dart';

const iconPresetKey = 'app_icon_preset';

const iconAssetMap = <String, String>{
  'default': 'assets/meta/icon.png',
  'hibiki_full': 'assets/meta/launcher_icon_full.png',
  'hibiki_minimal': 'assets/meta/launcher_icon_minimal.png',
};

const _iconChannel = MethodChannel('app.hibiki.reader/icon_switch');

class MiscellaneousSettingsPage extends BasePage {
  const MiscellaneousSettingsPage({super.key});

  @override
  BasePageState<MiscellaneousSettingsPage> createState() =>
      _MiscellaneousSettingsPageState();
}

class _MiscellaneousSettingsPageState
    extends BasePageState<MiscellaneousSettingsPage> {
  String _currentIcon = 'default';
  bool _switching = false;
  bool _customSupported = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentIcon();
  }

  Future<void> _loadCurrentIcon() async {
    if (!Platform.isAndroid) return;
    final results = await Future.wait([
      _iconChannel.invokeMethod<String>('getCurrentIcon'),
      _iconChannel.invokeMethod<bool>('isCustomShortcutSupported'),
    ]);
    if (!mounted) return;
    setState(() {
      _currentIcon = (results[0] as String?) ?? 'default';
      _customSupported = (results[1] as bool?) ?? false;
    });
  }

  Future<void> _switchPreset(String key) async {
    if (_switching || _currentIcon == key) return;
    setState(() => _switching = true);

    try {
      final ok = await _iconChannel.invokeMethod<bool>(
        'switchPresetIcon',
        {'alias': key},
      );
      if (ok == true && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(iconPresetKey, key);
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
      builder: (ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.icon_custom_confirm_title),
        content: Text(t.icon_custom_confirm_body),
        actions: [
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
    );
    if (confirmed != true) return;

    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    final ok = await _iconChannel.invokeMethod<bool>(
      'createCustomShortcut',
      {'imageBytes': bytes},
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            ok == true ? t.icon_shortcut_created : t.icon_shortcut_unsupported),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsScaffold(
      title: Text(t.app_icon_label),
      children: [
        if (Platform.isAndroid)
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
          ),
      ],
    );
  }

  Widget _buildIconGrid() {
    final presets = [
      _IconOption(
        key: 'default',
        label: t.icon_default,
        asset: 'assets/meta/splash_source.png',
      ),
      _IconOption(
        key: 'hibiki_full',
        label: t.icon_full,
        asset: 'assets/meta/launcher_icon_full.png',
      ),
      _IconOption(
        key: 'hibiki_minimal',
        label: t.icon_minimal,
        asset: 'assets/meta/launcher_icon_minimal.png',
      ),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final preset in presets) _buildPresetTile(preset),
        if (_customSupported) _buildCustomTile(),
      ],
    );
  }

  Widget _buildPresetTile(_IconOption option) {
    final selected = _currentIcon == option.key;
    return GestureDetector(
      onTap: _switching ? null : () => _switchPreset(option.key),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Stack(
                children: [
                  Image.asset(option.asset, fit: BoxFit.cover),
                  if (selected)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 14,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            option.label,
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

  Widget _buildCustomTile() {
    return GestureDetector(
      onTap: _switching ? null : _pickCustomIcon,
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Icon(
              Icons.add_photo_alternate_outlined,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.icon_custom,
            style: textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
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
