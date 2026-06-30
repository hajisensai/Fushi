import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

class CustomThemePage extends BasePage {
  // TODO-930: edit an existing custom theme by id, or (null) create a new one.
  // The swatch row passes a concrete id (long-press / edit button / +new after
  // upsert); a null id keeps the legacy "edit the active custom theme" path.
  const CustomThemePage({super.key, this.themeId});

  final String? themeId;

  @override
  BasePageState createState() => _CustomThemePageState();
}

class _CustomThemePageState extends BasePageState<CustomThemePage> {
  late Color _seed;
  late String _brightnessMode;
  Color? _fontColor;
  bool _useFontColor = false;
  Color? _bgColor;
  bool _useBgColor = false;
  Color? _selectionColor;
  bool _useSelectionColor = false;
  Color? _primaryColor;
  bool _usePrimaryColor = false;
  Color? _secondaryColor;
  bool _useSecondaryColor = false;
  Color? _tertiaryColor;
  bool _useTertiaryColor = false;
  Color? _containerColor;
  bool _useContainerColor = false;
  Color? _sasayakiColor;
  bool _useSasayakiColor = false;
  Color? _linkColor;
  bool _useLinkColor = false;

  // TODO-930: the entry being edited. Resolved in initState from widget.themeId
  // (or the active custom theme / a fresh id when null). Name is optional.
  late String _entryId;
  late TextEditingController _nameController;

  ScrollHoldController? _pickerScrollHold;

  // TODO-928: 种子色选色区默认收起，避免手机端滑动页面误触又大又宽的色板。
  // 种子色是必填基色、无「启用/禁用」语义，故不复用 _buildOptionalColorPicker 的
  // switch+panel，而用这个 ExpansionTile 式的展开/收起状态。
  bool _seedExpanded = false;

  @override
  void initState() {
    super.initState();
    // TODO-930: resolve which entry we are editing. Prefer the explicit
    // widget.themeId; else fall back to the active custom theme; else a fresh
    // id for a brand-new theme. Initial colors come from that entry when it
    // exists, otherwise from the legacy flat getters (keeps the pre-930
    // single-theme edit path identical for a null/missing id).
    final CustomThemeEntry? entry = widget.themeId != null
        ? appModelNoUpdate.customThemeById(widget.themeId!)
        : appModelNoUpdate.activeCustomThemeEntry;
    _entryId = entry?.id ??
        widget.themeId ??
        'ct-${DateTime.now().microsecondsSinceEpoch}';
    _nameController = TextEditingController(text: entry?.name ?? '');

    Color? roleColor(int? fromEntry, Color? Function() legacy) {
      if (entry != null) return fromEntry != null ? Color(fromEntry) : null;
      return legacy();
    }

    _seed =
        entry != null ? Color(entry.seed) : appModelNoUpdate.customThemeSeed;
    _brightnessMode = appModelNoUpdate.brightnessMode;
    _fontColor = roleColor(
        entry?.fontColor, () => appModelNoUpdate.customThemeFontColor);
    _useFontColor = _fontColor != null;
    _fontColor ??= Colors.black;
    _bgColor = roleColor(
        entry?.bgColor, () => appModelNoUpdate.customThemeBackgroundColor);
    _useBgColor = _bgColor != null;
    _bgColor ??= Colors.white;
    _selectionColor = roleColor(entry?.selectionColor,
        () => appModelNoUpdate.customThemeSelectionColor);
    _useSelectionColor = _selectionColor != null;
    _selectionColor ??= Colors.grey;
    final ColorScheme generated = _generatedScheme;
    _primaryColor = roleColor(
        entry?.primaryColor, () => appModelNoUpdate.customThemePrimaryColor);
    _usePrimaryColor = _primaryColor != null;
    _primaryColor ??= generated.primary;
    _secondaryColor = roleColor(entry?.secondaryColor,
        () => appModelNoUpdate.customThemeSecondaryColor);
    _useSecondaryColor = _secondaryColor != null;
    _secondaryColor ??= generated.secondary;
    _tertiaryColor = roleColor(
        entry?.tertiaryColor, () => appModelNoUpdate.customThemeTertiaryColor);
    _useTertiaryColor = _tertiaryColor != null;
    _tertiaryColor ??= generated.tertiary;
    _containerColor = roleColor(entry?.containerColor,
        () => appModelNoUpdate.customThemeContainerColor);
    _useContainerColor = _containerColor != null;
    _containerColor ??= generated.primaryContainer;
    // TODO-977：音频高亮色是**全局偏好**（与主题解耦），从 appModel.audioHighlightColor
    // 读，不再依赖被编辑的 custom-theme 条目；这样它对所有主题生效，编辑它也不强制
    // 切到本自定义主题。entry/encode/decode 仍保留 sasayakiColor 字段供分享码兼容。
    _sasayakiColor = appModelNoUpdate.audioHighlightColor;
    _useSasayakiColor = _sasayakiColor != null;
    _sasayakiColor ??= HibikiColor.defaultSasayakiColor;
    _linkColor = roleColor(
        entry?.linkColor, () => appModelNoUpdate.customThemeLinkColor);
    _useLinkColor = _linkColor != null;
    _linkColor ??= generated.primary;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pickerScrollHold?.cancel();
    super.dispose();
  }

  /// TODO-930: build the [CustomThemeEntry] from the current editor state.
  CustomThemeEntry _buildEntry() {
    int? argb(Color? c) => c?.toARGB32();
    return CustomThemeEntry(
      id: _entryId,
      name: _nameController.text.trim(),
      seed: _seed.toARGB32(),
      fontColor: _useFontColor ? argb(_fontColor) : null,
      bgColor: _useBgColor ? argb(_bgColor) : null,
      selectionColor: _useSelectionColor ? argb(_selectionColor) : null,
      primaryColor: _usePrimaryColor ? argb(_primaryColor) : null,
      secondaryColor: _useSecondaryColor ? argb(_secondaryColor) : null,
      tertiaryColor: _useTertiaryColor ? argb(_tertiaryColor) : null,
      containerColor: _useContainerColor ? argb(_containerColor) : null,
      sasayakiColor: _useSasayakiColor ? argb(_sasayakiColor) : null,
      linkColor: _useLinkColor ? argb(_linkColor) : null,
    );
  }

  /// TODO-930: 1-based index of this entry in the list, for the default name
  /// hint (`Custom N`). Falls back to list length + 1 for a not-yet-persisted
  /// new entry.
  int get _defaultNameIndex {
    final int idx = appModelNoUpdate.customThemes
        .indexWhere((CustomThemeEntry e) => e.id == _entryId);
    return idx >= 0 ? idx + 1 : appModelNoUpdate.customThemes.length + 1;
  }

  // TODO-928: 预览跟随当前真实全局明暗（自定义主题不再有自己的明暗开关）。
  // 同一组自定义色在 light/dark 下由 buildHibikiColorScheme 各自从 seed 派生。
  Brightness get _previewBrightness =>
      appModelNoUpdate.isDarkMode ? Brightness.dark : Brightness.light;

  ColorScheme get _generatedScheme =>
      ColorScheme.fromSeed(seedColor: _seed, brightness: _previewBrightness);

  ColorScheme get _preview => buildHibikiColorScheme(
        seedColor: _seed,
        brightness: _previewBrightness,
        primary: _usePrimaryColor ? _primaryColor : null,
        secondary: _useSecondaryColor ? _secondaryColor : null,
        tertiary: _useTertiaryColor ? _tertiaryColor : null,
        primaryContainer: _useContainerColor ? _containerColor : null,
      );

  void _refreshInactiveRoleColors() {
    final ColorScheme generated = _generatedScheme;
    if (!_usePrimaryColor) _primaryColor = generated.primary;
    if (!_useSecondaryColor) _secondaryColor = generated.secondary;
    if (!_useTertiaryColor) _tertiaryColor = generated.tertiary;
    if (!_useContainerColor) _containerColor = generated.primaryContainer;
    if (!_useLinkColor) _linkColor = generated.primary;
  }

  void _setSeed(Color color) {
    setState(() {
      _seed = color;
      _refreshInactiveRoleColors();
    });
  }

  void _holdScroll(BuildContext innerContext) {
    _pickerScrollHold?.cancel();
    _pickerScrollHold = Scrollable.maybeOf(innerContext)?.position.hold(() {});
  }

  void _releaseScroll() {
    _pickerScrollHold?.cancel();
    _pickerScrollHold = null;
  }

  String _encodeTheme() {
    final hex = _seed.toARGB32().toRadixString(16).padLeft(8, '0');
    var code = 'hibiki-theme:$hex:$_brightnessMode';
    if (_useFontColor && _fontColor != null) {
      final fontHex = _fontColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':fc$fontHex';
    }
    if (_useBgColor && _bgColor != null) {
      final bgHex = _bgColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':bg$bgHex';
    }
    if (_useSelectionColor && _selectionColor != null) {
      final selHex =
          _selectionColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':sc$selHex';
    }
    if (_usePrimaryColor && _primaryColor != null) {
      final primaryHex =
          _primaryColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':pr$primaryHex';
    }
    if (_useSecondaryColor && _secondaryColor != null) {
      final secondaryHex =
          _secondaryColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':sr$secondaryHex';
    }
    if (_useTertiaryColor && _tertiaryColor != null) {
      final tertiaryHex =
          _tertiaryColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':tr$tertiaryHex';
    }
    if (_useContainerColor && _containerColor != null) {
      final containerHex =
          _containerColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':cr$containerHex';
    }
    if (_useSasayakiColor && _sasayakiColor != null) {
      final sasayakiHex =
          _sasayakiColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':sk$sasayakiHex';
    }
    if (_useLinkColor && _linkColor != null) {
      final linkHex = _linkColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':lk$linkHex';
    }
    return code;
  }

  static ({
    Color seed,
    String brightnessMode,
    Color? fontColor,
    Color? bgColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sasayakiColor,
    Color? linkColor,
  })? _decodeTheme(String code) {
    final parts = code.trim().split(':');
    if (parts.length < 3 || parts[0] != 'hibiki-theme') return null;
    final colorVal = int.tryParse(parts[1], radix: 16);
    if (colorVal == null) return null;
    final String brightnessMode;
    switch (parts[2]) {
      case 'dark':
      case 'light':
      case 'system':
        brightnessMode = parts[2];
      default:
        return null;
    }
    Color? fontColor;
    Color? bgColor;
    Color? selectionColor;
    Color? primaryColor;
    Color? secondaryColor;
    Color? tertiaryColor;
    Color? containerColor;
    Color? sasayakiColor;
    Color? linkColor;
    for (int i = 3; i < parts.length; i++) {
      if (parts[i].startsWith('fc')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) fontColor = Color(v);
      } else if (parts[i].startsWith('bg')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) bgColor = Color(v);
      } else if (parts[i].startsWith('sc')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) selectionColor = Color(v);
      } else if (parts[i].startsWith('pr')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) primaryColor = Color(v);
      } else if (parts[i].startsWith('sr')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) secondaryColor = Color(v);
      } else if (parts[i].startsWith('tr')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) tertiaryColor = Color(v);
      } else if (parts[i].startsWith('cr')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) containerColor = Color(v);
      } else if (parts[i].startsWith('sk')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) sasayakiColor = Color(v);
      } else if (parts[i].startsWith('lk')) {
        final v = int.tryParse(parts[i].substring(2), radix: 16);
        if (v != null) linkColor = Color(v);
      }
    }
    return (
      seed: Color(colorVal),
      brightnessMode: brightnessMode,
      fontColor: fontColor,
      bgColor: bgColor,
      selectionColor: selectionColor,
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
      containerColor: containerColor,
      sasayakiColor: sasayakiColor,
      linkColor: linkColor,
    );
  }

  void _shareTheme() {
    final code = _encodeTheme();
    Clipboard.setData(ClipboardData(text: code));
    HibikiToast.show(msg: t.theme_code_copied);
  }

  void _applyImportedTheme(
      ({
        Color seed,
        String brightnessMode,
        Color? fontColor,
        Color? bgColor,
        Color? selectionColor,
        Color? primaryColor,
        Color? secondaryColor,
        Color? tertiaryColor,
        Color? containerColor,
        Color? sasayakiColor,
        Color? linkColor,
      }) result) {
    setState(() {
      _seed = result.seed;
      _brightnessMode = result.brightnessMode;
      _fontColor = result.fontColor ?? Colors.black;
      _useFontColor = result.fontColor != null;
      _bgColor = result.bgColor ?? Colors.white;
      _useBgColor = result.bgColor != null;
      _selectionColor = result.selectionColor ?? Colors.grey;
      _useSelectionColor = result.selectionColor != null;
      final Brightness brightness;
      switch (result.brightnessMode) {
        case 'dark':
          brightness = Brightness.dark;
        case 'light':
          brightness = Brightness.light;
        default:
          brightness =
              WidgetsBinding.instance.platformDispatcher.platformBrightness;
      }
      final ColorScheme generated = buildHibikiColorScheme(
        seedColor: result.seed,
        brightness: brightness,
      );
      _primaryColor = result.primaryColor ?? generated.primary;
      _usePrimaryColor = result.primaryColor != null;
      _secondaryColor = result.secondaryColor ?? generated.secondary;
      _useSecondaryColor = result.secondaryColor != null;
      _tertiaryColor = result.tertiaryColor ?? generated.tertiary;
      _useTertiaryColor = result.tertiaryColor != null;
      _containerColor = result.containerColor ?? generated.primaryContainer;
      _useContainerColor = result.containerColor != null;
      _sasayakiColor = result.sasayakiColor ?? HibikiColor.defaultSasayakiColor;
      _useSasayakiColor = result.sasayakiColor != null;
      _linkColor = result.linkColor ?? generated.primary;
      _useLinkColor = result.linkColor != null;
    });
    // TODO-977：导入的音频高亮色也写穿全局偏好（与主题解耦），保持与手动改色一致。
    appModel.setAudioHighlightColor(result.sasayakiColor);
  }

  Future<void> _importTheme() async {
    final controller = TextEditingController();
    try {
      await showAppDialog(
        context: context,
        builder: (ctx) {
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
          return HibikiDialogFrame(
            maxWidth: 480,
            maxHeightFactor: 0.78,
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.import_theme,
              leadingIcon: Icons.content_paste_outlined,
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
              body: HibikiTextField(
                controller: controller,
                hintText: t.import_theme_hint,
                autofocus: true,
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: [
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(t.dialog_close),
                  ),
                  adaptiveDialogAction(
                    context: ctx,
                    isDefaultAction: true,
                    onPressed: () {
                      final result = _decodeTheme(controller.text);
                      if (result == null) {
                        HibikiToast.show(msg: t.import_theme_invalid);
                        return;
                      }
                      Navigator.pop(ctx);
                      _applyImportedTheme(result);
                      HibikiToast.show(msg: t.import_theme_success);
                    },
                    child: Text(t.dialog_import),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = _preview;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return AdaptiveSettingsScaffold(
      title: Text(t.custom_theme),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.page,
        tokens.spacing.gap +
            tokens.spacing.gap / 2 +
            MediaQuery.of(context).padding.bottom +
            MediaQuery.of(context).viewInsets.bottom,
      ),
      actions: [
        HibikiIconButton(
          icon: Icons.content_paste_outlined,
          tooltip: t.import_theme,
          onTap: _importTheme,
        ),
        HibikiIconButton(
          icon: Icons.share_outlined,
          tooltip: t.share_theme,
          onTap: _shareTheme,
        ),
      ],
      children: [
        _buildPreviewCard(cs),
        SizedBox(height: tokens.spacing.card),
        // TODO-928: 删自定义主题专属的「深色模式」三段开关——自定义主题跟随全局明暗，
        // 改明暗去外观设置里的全局 brightness 选择器（自带/自定义一视同仁）。
        // ── 板块 1：系统主题色（种子色 + 主色）──
        // TODO-072：把种子色与全局主色归到「系统主题色」一块。
        AdaptiveSettingsSection(
          title: t.section_system_theme,
          children: [
            // TODO-930: 主题名称（可选，留空显示「自定义 N」默认名）。
            _buildNameField(),
            // TODO-071：提示用户色板预览的是种子实际生成的色；想固定某色当主色
            // 强调色，请打开「主色」开关显式指定（否则灰种子会回退成绿）。
            _buildHintRow(t.theme_seed_preview_hint),
            _buildSeedColorPicker(),
            _buildOptionalColorPicker(
              label: t.color_primary,
              description: t.color_primary_desc,
              preview: _buildPrimaryPreview(cs),
              enabled: _usePrimaryColor,
              onEnabledChanged: (bool value) {
                setState(() {
                  _usePrimaryColor = value;
                  _primaryColor = value
                      ? _primaryColor ?? _generatedScheme.primary
                      : _generatedScheme.primary;
                });
              },
              color: _primaryColor!,
              onChanged: (Color color) => setState(() => _primaryColor = color),
              enableAlpha: false,
            ),
          ],
        ),
        // ── 板块 2：有声书与歌词（笹語高亮 + 选区高亮）──
        AdaptiveSettingsSection(
          title: t.section_audiobook_lyrics,
          children: [
            _buildOptionalColorPicker(
              label: t.color_sasayaki,
              description: t.color_sasayaki_desc,
              preview: _buildSasayakiPreview(cs),
              enabled: _useSasayakiColor,
              // TODO-977：音频高亮是全局偏好，开关/改色立即写穿，对所有主题生效，
              // 不必依赖「保存并切到本自定义主题」。关闭 → 写 null 回退到随主题取色。
              onEnabledChanged: (bool value) {
                setState(() => _useSasayakiColor = value);
                appModel.setAudioHighlightColor(value ? _sasayakiColor : null);
              },
              color: _sasayakiColor!,
              onChanged: (Color color) {
                setState(() => _sasayakiColor = color);
                if (_useSasayakiColor) {
                  appModel.setAudioHighlightColor(color);
                }
              },
              enableAlpha: true,
            ),
            _buildOptionalColorPicker(
              label: t.selection_color,
              description: t.selection_color_desc,
              preview: _buildSelectionPreview(cs),
              enabled: _useSelectionColor,
              onEnabledChanged: (bool value) =>
                  setState(() => _useSelectionColor = value),
              color: _selectionColor!,
              onChanged: (Color color) =>
                  setState(() => _selectionColor = color),
              enableAlpha: true,
            ),
          ],
        ),
        // ── 板块 3：阅读器文字（字色 + 背景 + 链接）──
        AdaptiveSettingsSection(
          title: t.section_reader_colors,
          children: [
            _buildOptionalColorPicker(
              label: t.font_color,
              description: t.font_color_desc,
              preview: _buildFontColorPreview(cs),
              enabled: _useFontColor,
              onEnabledChanged: (bool value) =>
                  setState(() => _useFontColor = value),
              color: _fontColor!,
              onChanged: (Color color) => setState(() => _fontColor = color),
              enableAlpha: true,
            ),
            _buildOptionalColorPicker(
              label: t.background_color,
              description: t.background_color_desc,
              preview: _buildBgColorPreview(cs),
              enabled: _useBgColor,
              onEnabledChanged: (bool value) =>
                  setState(() => _useBgColor = value),
              color: _bgColor!,
              onChanged: (Color color) => setState(() => _bgColor = color),
              enableAlpha: false,
            ),
            _buildOptionalColorPicker(
              label: t.color_link,
              description: t.color_link_desc,
              preview: _buildLinkPreview(cs),
              enabled: _useLinkColor,
              onEnabledChanged: (bool value) {
                setState(() {
                  _useLinkColor = value;
                  _linkColor = value
                      ? _linkColor ?? _generatedScheme.primary
                      : _generatedScheme.primary;
                });
              },
              color: _linkColor!,
              onChanged: (Color color) => setState(() => _linkColor = color),
              enableAlpha: false,
            ),
          ],
        ),
        // TODO-072：视频字幕颜色不在此页配置，只放一行说明。
        _buildNoteRow(t.video_subtitle_color_note),
        // ── 高级选项 ──
        AdaptiveSettingsSection(
          title: t.section_advanced_colors,
          children: [
            _buildOptionalColorPicker(
              label: t.color_secondary,
              description: t.color_secondary_desc,
              preview: _buildSecondaryPreview(cs),
              enabled: _useSecondaryColor,
              onEnabledChanged: (bool value) {
                setState(() {
                  _useSecondaryColor = value;
                  _secondaryColor = value
                      ? _secondaryColor ?? _generatedScheme.secondary
                      : _generatedScheme.secondary;
                });
              },
              color: _secondaryColor!,
              onChanged: (Color color) =>
                  setState(() => _secondaryColor = color),
              enableAlpha: false,
            ),
            _buildOptionalColorPicker(
              label: t.color_tertiary,
              description: t.color_tertiary_desc,
              preview: _buildTertiaryPreview(cs),
              enabled: _useTertiaryColor,
              onEnabledChanged: (bool value) {
                setState(() {
                  _useTertiaryColor = value;
                  _tertiaryColor = value
                      ? _tertiaryColor ?? _generatedScheme.tertiary
                      : _generatedScheme.tertiary;
                });
              },
              color: _tertiaryColor!,
              onChanged: (Color color) =>
                  setState(() => _tertiaryColor = color),
              enableAlpha: false,
            ),
            _buildOptionalColorPicker(
              label: t.color_container,
              description: t.color_container_desc,
              preview: _buildContainerPreview(cs),
              enabled: _useContainerColor,
              onEnabledChanged: (bool value) {
                setState(() {
                  _useContainerColor = value;
                  _containerColor = value
                      ? _containerColor ?? _generatedScheme.primaryContainer
                      : _generatedScheme.primaryContainer;
                });
              },
              color: _containerColor!,
              onChanged: (Color color) =>
                  setState(() => _containerColor = color),
              enableAlpha: false,
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.card),
        FilledButton.icon(
          onPressed: _applyAndClose,
          icon: const Icon(Icons.check),
          label: Text(t.apply_theme),
        ),
        SizedBox(height: tokens.spacing.gap),
        // TODO-930 M2: 删除当前编辑的主题（确认后），回退由 deleteCustomTheme +
        // _resolveThemeKeyAfterDelete 处理（决策 1：列表非空选第一项，空→system）。
        OutlinedButton.icon(
          onPressed: _confirmDelete,
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline),
          label: Text(t.delete_custom_theme),
        ),
      ],
    );
  }

  /// TODO-930 M2: persist the edited theme into the list, select it, point the
  /// app theme key at it, then close. Replaces the legacy applyCustomTheme call
  /// so naming + multi-theme selection round-trip through the list model.
  Future<void> _applyAndClose() async {
    final NavigatorState navigator = Navigator.of(context);
    final CustomThemeEntry entry = _buildEntry();
    await appModel.upsertCustomTheme(entry);
    await appModel.selectCustomTheme(entry.id);
    await appModel.setAppThemeKey('custom-theme:${entry.id}');
    if (!mounted) return;
    navigator.pop();
  }

  /// TODO-930 M2: confirm + delete the current theme. After delete, repoint the
  /// app theme key per decision 1 (first remaining custom theme, else
  /// system-theme) so the app never points at a now-missing custom entry.
  Future<void> _confirmDelete() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext ctx) {
            final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
            return HibikiDialogFrame(
              maxWidth: 420,
              maxHeightFactor: 0.6,
              scrollable: false,
              child: HibikiModalSheetFrame(
                title: t.delete_custom_theme,
                leadingIcon: Icons.delete_outline,
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
                body: Text(
                  t.delete_custom_theme_confirm,
                  style: tokens.type.listSubtitle,
                ),
                footer: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: [
                    adaptiveDialogAction(
                      context: ctx,
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.dialog_close),
                    ),
                    adaptiveDialogAction(
                      context: ctx,
                      isDestructiveAction: true,
                      isDefaultAction: true,
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(t.delete_custom_theme),
                    ),
                  ],
                ),
              ),
            );
          },
        ) ??
        false;
    if (!confirmed) return;

    final String nextKey = _resolveThemeKeyAfterDelete(_entryId);
    await appModel.deleteCustomTheme(_entryId);
    await appModel.setAppThemeKey(nextKey);
    if (!mounted) return;
    navigator.pop();
  }

  /// TODO-930 M2 decision 1: after deleting [deletedId], the app theme key
  /// should point at the first remaining custom theme (`custom-theme:<id>`), or
  /// fall back to `system-theme` when the list becomes empty. Pure for testing.
  String _resolveThemeKeyAfterDelete(String deletedId) {
    final List<CustomThemeEntry> remaining = appModelNoUpdate.customThemes
        .where((CustomThemeEntry e) => e.id != deletedId)
        .toList();
    if (remaining.isEmpty) return 'system-theme';
    return 'custom-theme:${remaining.first.id}';
  }

  /// TODO-930 M2: the optional name field. Empty name is allowed (decision 3);
  /// the hint shows the localized default `Custom N`.
  Widget _buildNameField() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: HibikiTextField(
        controller: _nameController,
        labelText: t.custom_theme_name,
        hintText: t.custom_theme_default_name(n: _defaultNameIndex),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  // ── 预览卡片 ──

  Widget _buildPreviewCard(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color textColor = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bgColor = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.bold,
    );
    final TextStyle bodyStyle = tokens.type.listSubtitle.copyWith(
      color: textColor,
    );
    final TextStyle metaStyle = tokens.type.metadata.copyWith(
      color: cs.onSurface,
    );
    final TextStyle badgeStyle = tokens.type.metadata.copyWith(
      color: cs.onSecondaryContainer,
    );

    return HibikiCard(
      color: cs.surface,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.preview, style: titleStyle),
          SizedBox(height: tokens.spacing.gap),
          Row(
            children: [
              _swatch(cs.primary, t.color_primary, cs.onSurface),
              SizedBox(width: tokens.spacing.gap),
              _swatch(cs.secondary, t.color_secondary, cs.onSurface),
              SizedBox(width: tokens.spacing.gap),
              _swatch(cs.tertiary, t.color_tertiary, cs.onSurface),
              SizedBox(width: tokens.spacing.gap),
              _swatch(cs.primaryContainer, t.color_container, cs.onSurface),
            ],
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          Container(
            width: double.infinity,
            padding:
                EdgeInsets.all(tokens.spacing.gap + tokens.spacing.gap / 2),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: tokens.radii.chipRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: bodyStyle,
                    children: [
                      const TextSpan(text: '日本語の'),
                      TextSpan(
                        text: 'テキスト',
                        style: TextStyle(
                          backgroundColor:
                              _useSelectionColor ? _selectionColor : null,
                        ),
                      ),
                      const TextSpan(text: 'プレビュー'),
                    ],
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap * 0.75,
                    vertical: tokens.spacing.gap / 4,
                  ),
                  decoration: BoxDecoration(
                    color: _useSasayakiColor
                        ? _sasayakiColor
                        : HibikiColor.defaultSasayakiColor,
                    borderRadius: tokens.radii.chipRadius,
                  ),
                  child: Text(
                    '♪ 音声ハイライト',
                    style: bodyStyle,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap * 0.75),
                RichText(
                  text: TextSpan(
                    style: bodyStyle,
                    children: [
                      const TextSpan(text: '♪ '),
                      TextSpan(
                        text: '字幕同期',
                        style: TextStyle(
                          backgroundColor: _useSasayakiColor
                              ? _sasayakiColor
                              : HibikiColor.defaultSasayakiColor,
                        ),
                      ),
                      const TextSpan(text: 'テスト　'),
                      TextSpan(
                        text: 'リンク',
                        style: TextStyle(
                          color: _useLinkColor ? _linkColor! : cs.primary,
                          decoration: TextDecoration.underline,
                          decorationColor:
                              _useLinkColor ? _linkColor! : cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          Row(
            children: [
              HibikiPreviewSwitch(
                trackColor: cs.primaryContainer,
                thumbColor: cs.primary,
              ),
              SizedBox(width: tokens.spacing.gap),
              Text(t.preview_switch, style: metaStyle),
              SizedBox(width: tokens.spacing.card),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.gap,
                  vertical: tokens.spacing.gap * 0.375,
                ),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: tokens.radii.controlRadius,
                ),
                child: Text(t.preview_badge, style: badgeStyle),
              ),
              SizedBox(width: tokens.spacing.gap),
              Container(
                width: 40,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.tertiary,
                  borderRadius: tokens.radii.chipRadius,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 每种颜色的使用场景迷你预览 ──

  Widget _buildFontColorPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Text(
        'あいうえお',
        style: tokens.type.listSubtitle.copyWith(color: fc),
      ),
    );
  }

  Widget _buildBgColorPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: tokens.radii.chipRadius,
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        '日本語',
        style: tokens.type.listSubtitle.copyWith(color: fc),
      ),
    );
  }

  Widget _buildSelectionPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color sel = _useSelectionColor ? _selectionColor! : Colors.grey;
    return RichText(
      text: TextSpan(
        style: tokens.type.listSubtitle.copyWith(color: fc),
        children: [
          const TextSpan(text: '読み'),
          TextSpan(
            text: '選択中',
            style: TextStyle(backgroundColor: sel),
          ),
          const TextSpan(text: 'テスト'),
        ],
      ),
    );
  }

  Widget _buildPrimaryPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color primary = _primaryColor!;
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color track = (_useContainerColor
            ? _containerColor
            : _generatedScheme.primaryContainer) ??
        cs.primaryContainer;
    return Row(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.gap * 0.75,
            vertical: tokens.spacing.gap / 4,
          ),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.34),
            borderRadius: tokens.radii.chipRadius,
          ),
          child: Text(
            '♪ ハイライト',
            style: tokens.type.metadata.copyWith(color: fc),
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
        HibikiPreviewSwitch(
          trackColor: track,
          thumbColor: primary,
        ),
      ],
    );
  }

  Widget _buildSecondaryPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap * 0.375,
      ),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: tokens.radii.controlRadius,
      ),
      child: Text(
        '辞書',
        style: tokens.type.metadata.copyWith(
          color: cs.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _buildTertiaryPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Row(
      children: [
        Container(
          width: 48,
          height: 8,
          decoration: BoxDecoration(
            color: _tertiaryColor,
            borderRadius: tokens.radii.chipRadius,
          ),
        ),
        SizedBox(width: tokens.spacing.gap / 2),
        Container(
          width: 32,
          height: 8,
          decoration: BoxDecoration(
            color: _tertiaryColor?.withValues(alpha: 0.5),
            borderRadius: tokens.radii.chipRadius,
          ),
        ),
      ],
    );
  }

  Widget _buildContainerPreview(ColorScheme cs) {
    return HibikiPreviewSwitch(
      trackColor: _containerColor ?? cs.primaryContainer,
      thumbColor: _primaryColor ?? cs.primary,
    );
  }

  Widget _buildSasayakiPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    final Color sas =
        _useSasayakiColor ? _sasayakiColor! : HibikiColor.defaultSasayakiColor;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: RichText(
        text: TextSpan(
          style: tokens.type.listSubtitle.copyWith(color: fc),
          children: [
            const TextSpan(text: '♪ '),
            TextSpan(
              text: '字幕',
              style: TextStyle(backgroundColor: sas),
            ),
            const TextSpan(text: 'テスト'),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkPreview(ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color lc = _useLinkColor ? _linkColor! : cs.primary;
    return Text(
      'リンク',
      style: tokens.type.listSubtitle.copyWith(
        color: lc,
        decoration: TextDecoration.underline,
        decorationColor: lc,
      ),
    );
  }

  // ── 通用组件 ──

  /// TODO-928: 种子色折叠选色区。默认收起，点标题行展开/收起；展开后才挂
  /// ColorPicker，避免它常驻滚动主路径被手指扫到改色（诉求3）。种子色无启用语义，
  /// 故不是 switch 而是 ExpansionTile 式的纯展开/收起。
  Widget _buildSeedColorPicker() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _seedExpanded = !_seedExpanded),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.palette_outlined, color: cs.onSurfaceVariant),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(t.seed_color, style: tokens.type.listTitle),
                      SizedBox(height: tokens.spacing.gap / 4),
                      Text(
                        t.seed_color_desc,
                        style: tokens.type.metadata.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                HibikiColorSwatch(
                  color: _seed,
                  size: 20,
                  shape: HibikiColorSwatchShape.dot,
                  borderColor: Theme.of(context).dividerColor,
                ),
                SizedBox(width: tokens.spacing.gap),
                AnimatedRotation(
                  turns: _seedExpanded ? 0.5 : 0.0,
                  duration: hibikiMd3StateDuration,
                  child: Icon(
                    Icons.expand_more,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_seedExpanded)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: _buildCompactColorPicker(
              color: _seed,
              onChanged: _setSeed,
              enableAlpha: false,
            ),
          ),
      ],
    );
  }

  Widget _buildCompactColorPicker({
    required Color color,
    required ValueChanged<Color> onChanged,
    required bool enableAlpha,
  }) {
    return LayoutBuilder(
      builder: (layoutContext, constraints) {
        final pickerWidth = constraints.maxWidth
            .clamp(0.0, MediaQuery.of(layoutContext).size.width - 64);
        final isLandscape =
            MediaQuery.of(layoutContext).orientation == Orientation.landscape;
        return Listener(
          onPointerDown: (_) => _holdScroll(layoutContext),
          onPointerUp: (_) => _releaseScroll(),
          onPointerCancel: (_) => _releaseScroll(),
          child: ColorPicker(
            pickerColor: color,
            onColorChanged: onChanged,
            portraitOnly: true,
            colorPickerWidth: pickerWidth,
            pickerAreaHeightPercent: isLandscape ? 0.35 : 0.5,
            enableAlpha: enableAlpha,
            displayThumbColor: true,
            hexInputBar: true,
            labelTypes: const [],
          ),
        );
      },
    );
  }

  Widget _buildOptionalColorPicker({
    required String label,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    required Color color,
    required ValueChanged<Color> onChanged,
    required bool enableAlpha,
    String? description,
    Widget? preview,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AdaptiveSettingsSwitchActionRow(
      title: label,
      subtitle: description,
      value: enabled,
      onChanged: onEnabledChanged,
      body: Row(
        children: [
          HibikiColorSwatch(
            color: color,
            size: 20,
            shape: HibikiColorSwatchShape.dot,
            borderColor: Theme.of(context).dividerColor,
          ),
          if (preview != null) ...[
            SizedBox(width: tokens.spacing.gap),
            Expanded(child: preview),
          ],
        ],
      ),
      panel: enabled
          ? _buildCompactColorPicker(
              color: color,
              onChanged: onChanged,
              enableAlpha: enableAlpha,
            )
          : null,
    );
  }

  Widget _swatch(Color color, String label, Color textColor) {
    return Expanded(
      child: HibikiColorSwatch(
        color: color,
        width: double.infinity,
        height: 36,
        label: label,
        textColor: textColor,
      ),
    );
  }

  // ── TODO-071 / TODO-072 提示与说明行 ──

  /// A non-interactive hint row (lightbulb icon + secondary text) used inside a
  /// settings section to explain a behaviour to the user. TODO-071 uses it to
  /// tell the user the swatches below preview the seed's *generated* colour and
  /// how to pin a colour as the primary accent.
  Widget _buildHintRow(String text) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 18,
            color: cs.primary,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: tokens.type.metadata.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A standalone note line (info icon + secondary text) shown between or below
  /// sections. TODO-072 uses it to point out that subtitle colours live in the
  /// video player, not on this page.
  Widget _buildNoteRow(String text) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: cs.onSurfaceVariant,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: tokens.type.metadata.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
