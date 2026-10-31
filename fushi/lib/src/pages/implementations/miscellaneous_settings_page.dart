import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/pages/implementations/crop_image_dialog_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/app_icon_apply.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
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
      readerSource: ReaderFushiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );

    final SettingsDestination destination = SettingsDestination(
      id: SettingsDestinationId.appIcon,
      title: t.app_icon_label,
      icon: FushiIcons.widgets,
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
  /// 当前生效的预设 key。**不留本地副本**：唯一真值是
  /// [currentAppIconSelection]（rail 与窗口图标读的也是它）。此前这里存了一份
  /// `_currentIcon`，与那个 notifier 各写各的——正是本 PR 要消灭的形状。
  String get _currentIcon => currentAppIconSelection.value.presetKey;
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
        FushiChannels.iconSwitch.invokeMethod<bool>(
          'isCustomShortcutSupported',
        ),
      ]);
      await publishAppIconSelection(
        AppIconSelection(presetKey: (results[0] as String?) ?? 'default'),
      );
      if (!mounted) return;
      setState(() {
        _customSupported = (results[1] as bool?) ?? false;
      });
    } else if (Platform.isWindows) {
      await loadAppIconSelection();
      if (!mounted) return;
      setState(() {
        _customSupported = true; // Windows 支持任意图片
      });
    }
  }

  Future<void> _switchPreset(String key) async {
    if (_switching || _currentIcon == key) return;
    setState(() => _switching = true);

    try {
      // 原生切换 + 落盘 + 发布与控制通道共用（app_icon_apply.dart）。
      final bool ok = await applyPresetAppIcon(key);
      if (ok) {
        if (!mounted) return;
        // 选中态由 _currentIcon getter 从已发布的真值读；这里只需触发重建。
        setState(() {});
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(FushiSnackBar(content: Text(t.icon_switch_success)));
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
            leadingIcon: FushiIcons.image,
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
                FushiDialogAction(
                  label: t.dialog_cancel,
                  onPressed: () => Navigator.pop(ctx, false),
                ),
                FushiDialogAction(
                  label: t.dialog_ok,
                  kind: FushiDialogActionKind.primary,
                  onPressed: () => Navigator.pop(ctx, true),
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
      // BUG-3601 复查（WkL9BvD7Z9）：file_picker 8.x 安卓对 image/* 默认在**裸线程**
      // 里做 JPEG 重压缩（FileUtils.compressImage）——往公共 Pictures 目录建临时
      // 文件，Android 9/10 未授予运行时 WRITE_EXTERNAL_STORAGE 时抛 IOException 被包成
      // RuntimeException、decodeStream 返回 null 时 NPE，都直接杀进程且 Dart 零日志。
      // 我们自己的裁剪链路已按 appIconSourceMaxPixels 封顶，不需要它压缩。
      allowCompression: false,
    );
    if (result == null) return;
    final String? pickedPath = result.files.first.path;
    if (pickedPath == null) return;

    // 裁剪步骤：图标最终按**正方形**渲染，直接拿一张长条照片去当图标只会被拉伸
    // 变形，用户没有任何机会挑出想要的那一块。锁 1:1，取消裁剪 = 取消整个流程
    // （裁剪框默认铺满整图，不想裁的人直接确认即可拿到等价于原图的结果）。
    if (!mounted) return;
    final File? cropped = await showCropImageDialog(
      context,
      File(pickedPath),
      aspectRatio: 1,
      maxDimension: appIconSourceMaxPixels,
    );
    if (cropped == null) return;
    final String iconPath = cropped.path;

    // Android 建快捷方式 / Windows 换窗口图标 + 落盘，与控制通道共用。
    final bool ok = await applyCustomAppIcon(iconPath);
    if (ok && Platform.isWindows && mounted) setState(() {});

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      FushiSnackBar(
        content: Text(
          Platform.isAndroid
              ? (ok ? t.icon_shortcut_created : t.icon_shortcut_unsupported)
              : (ok ? t.icon_switch_success : t.icon_shortcut_unsupported),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (!Platform.isAndroid && !Platform.isWindows) {
      // 本平台不支持换图标：占位说明，不渲染空设置卡。
      return FushiPlaceholderMessage(
        icon: FushiIcons.widgets,
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
          // 静态提示不伪装成设置行（行标题会被 titleMaxLines 截断、还带行高 /
          // 分隔线语义），用 schema section footer 同款的分组脚注（样式按设计
          // 系统由 SettingsSectionFooter 自己取）。
          SettingsSectionFooter(t.icon_custom_hint),
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
    return _AppIconTile(
      label: option.label,
      selected: selected,
      enabled: !_switching,
      onTap: () => _switchPreset(option.key),
      child: ClipRRect(
        // M3E 卡内小块 12 圆角（与图标卡 20 圆角同心）。
        borderRadius: FushiM3eShape.smallRadius,
        child: Image.asset(option.asset, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildCustomTile() {
    return _AppIconTile(
      label: t.icon_custom,
      enabled: !_switching,
      onTap: _pickCustomIcon,
      child: FushiIcon(
        FushiIcons.image,
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
              // Apple：未选中的图标卡只是实色底，不勾 separator 描边框；
              // 选中仍是强调色细边 + 角标对勾。
              borderColor: selected
                  ? theme.colorScheme.primary
                  : (isGlassDesign(context)
                        ? null
                        : theme.colorScheme.outlineVariant),
              onTap: enabled ? onTap : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child,
                  if (selected)
                    Align(
                      alignment: Alignment.bottomRight,
                      child: FushiBadge(
                        icon: FushiIcons.check,
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
