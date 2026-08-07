import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/shortcut_icon_sync.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/utils.dart';

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
      id: SettingsDestinationId.appIcon,
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
        FushiChannels.iconSwitch.invokeMethod<String>('getCurrentIcon'),
        FushiChannels.iconSwitch
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
        ok = (await FushiChannels.iconSwitch.invokeMethod<bool>(
              'switchPresetIcon',
              {'alias': key},
            )) ==
            true;
      } else if (Platform.isWindows) {
        final String path = await exportPresetIconToFile(key);
        ok = await WindowCaptionChannel.setWindowIcon(path);
        if (ok) {
          // TODO-901：换图标后把桌面 / 开始菜单的 .lnk 图标也同步成新图。
          // 失败只降级 debugPrint，不影响上面已成功的运行时窗口图标。
          await syncWindowsShortcutIcons(await File(path).readAsBytes());
        }
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: FushiModalSheetFrame(
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
                // 统一走 slang t.*（MaterialLocalizations 跟系统 locale，与
                // 应用内语言切换脱节）。
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.dialog_ok),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true) return;

    // 选图统一走 file_picker：image_picker 在桌面（Windows）无平台实现，直接调
    // pickImage 会抛 MissingPluginException（TODO-1239）。file_picker 已是本仓库
    // 依赖且在 Android/Windows 均有实现，覆盖两个平台。
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null) return;
    final String? pickedPath = result.files.first.path;
    if (pickedPath == null) return;

    bool ok = false;
    if (Platform.isAndroid) {
      final bytes = await File(pickedPath).readAsBytes();
      ok = (await FushiChannels.iconSwitch.invokeMethod<bool>(
            'createCustomShortcut',
            {'imageBytes': bytes},
          )) ==
          true;
    } else if (Platform.isWindows) {
      final String persisted = await persistCustomIconFile(pickedPath);
      ok = await WindowCaptionChannel.setWindowIcon(persisted);
      if (ok) {
        await saveCustomIconPath(persisted);
        await saveIconPresetKey(customIconKey);
        // TODO-901：同步桌面 / 开始菜单 .lnk 图标到用户自定义图。
        await syncWindowsShortcutIcons(await File(persisted).readAsBytes());
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 静态提示不再伪装成设置行（行标题会被 titleMaxLines 截断、还带行高/分隔线
    // 语义），改用与 schema section footer 同款的说明文字样式。
    TextStyle? footerStyle(BuildContext context) =>
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: FushiDesignTokens.of(context).surfaces.onVariant,
            );
    if (!Platform.isAndroid && !Platform.isWindows) {
      // 本平台不支持换图标：占位说明，不渲染空设置卡。
      return FushiPlaceholderMessage(
        icon: Icons.widgets_outlined,
        message: t.icon_shortcut_unsupported,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // section 标题用「预设」语义；页头已经是「应用图标」，行级不再第三次
        // 重复同一文案（图标网格直接作为卡片内容，不套多余的行标题）。
        AdaptiveSettingsSection(
          title: t.app_icon_presets,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.rowHorizontal,
                vertical: tokens.spacing.rowVertical,
              ),
              child: _buildIconGrid(),
            ),
          ],
        ),
        if (_customSupported)
          SettingsSectionFooter(t.icon_custom_hint, style: footerStyle),
      ],
    );
  }

  Widget _buildIconGrid() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final presets = [
      _IconOption(
        key: 'default',
        label: t.icon_default,
        asset: presetIconAssets['default']!,
      ),
      _IconOption(
        key: 'hibiki_transparent',
        label: t.icon_transparent,
        asset: presetIconAssets['hibiki_transparent']!,
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 72,
            child: FushiCard(
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
                      child: FushiBadge(
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
