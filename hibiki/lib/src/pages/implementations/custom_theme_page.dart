import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

class CustomThemePage extends BasePage {
  const CustomThemePage({super.key});

  @override
  BasePageState createState() => _CustomThemePageState();
}

class _CustomThemePageState extends BasePageState {
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

  ScrollHoldController? _pickerScrollHold;

  @override
  void initState() {
    super.initState();
    _seed = appModelNoUpdate.customThemeSeed;
    _brightnessMode = appModelNoUpdate.brightnessMode;
    _fontColor = appModelNoUpdate.customThemeFontColor;
    _useFontColor = _fontColor != null;
    _fontColor ??= Colors.black;
    _bgColor = appModelNoUpdate.customThemeBackgroundColor;
    _useBgColor = _bgColor != null;
    _bgColor ??= Colors.white;
    _selectionColor = appModelNoUpdate.customThemeSelectionColor;
    _useSelectionColor = _selectionColor != null;
    _selectionColor ??= Colors.grey;
    final ColorScheme generated = _generatedScheme;
    _primaryColor = appModelNoUpdate.customThemePrimaryColor;
    _usePrimaryColor = _primaryColor != null;
    _primaryColor ??= generated.primary;
    _secondaryColor = appModelNoUpdate.customThemeSecondaryColor;
    _useSecondaryColor = _secondaryColor != null;
    _secondaryColor ??= generated.secondary;
    _tertiaryColor = appModelNoUpdate.customThemeTertiaryColor;
    _useTertiaryColor = _tertiaryColor != null;
    _tertiaryColor ??= generated.tertiary;
    _containerColor = appModelNoUpdate.customThemeContainerColor;
    _useContainerColor = _containerColor != null;
    _containerColor ??= generated.primaryContainer;
    _sasayakiColor = appModelNoUpdate.customThemeSasayakiColor;
    _useSasayakiColor = _sasayakiColor != null;
    _sasayakiColor ??= HibikiColor.defaultSasayakiColor;
    _linkColor = appModelNoUpdate.customThemeLinkColor;
    _useLinkColor = _linkColor != null;
    _linkColor ??= generated.primary;
  }

  @override
  void dispose() {
    _pickerScrollHold?.cancel();
    super.dispose();
  }

  Brightness get _previewBrightness {
    switch (_brightnessMode) {
      case 'light':
        return Brightness.light;
      case 'dark':
        return Brightness.dark;
      default:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

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

  void _setBrightnessMode(String mode) {
    setState(() {
      _brightnessMode = mode;
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

  void _importTheme() {
    final controller = TextEditingController();
    showAppDialog(
      context: context,
      builder: (ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.import_theme),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: t.import_theme_hint),
          autofocus: true,
        ),
        actions: [
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
                    brightness = WidgetsBinding
                        .instance.platformDispatcher.platformBrightness;
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
                _containerColor =
                    result.containerColor ?? generated.primaryContainer;
                _useContainerColor = result.containerColor != null;
                _sasayakiColor =
                    result.sasayakiColor ?? HibikiColor.defaultSasayakiColor;
                _useSasayakiColor = result.sasayakiColor != null;
                _linkColor = result.linkColor ?? generated.primary;
                _useLinkColor = result.linkColor != null;
              });
              HibikiToast.show(msg: t.import_theme_success);
            },
            child: Text(t.dialog_import),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = _preview;

    return AdaptiveSettingsScaffold(
      title: Text(t.custom_theme),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 +
            MediaQuery.of(context).padding.bottom +
            MediaQuery.of(context).viewInsets.bottom,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.content_paste_outlined),
          tooltip: t.import_theme,
          onPressed: _importTheme,
        ),
        IconButton(
          icon: const Icon(Icons.share_outlined),
          tooltip: t.share_theme,
          onPressed: _shareTheme,
        ),
      ],
      children: [
        _buildPreviewCard(cs),
        const SizedBox(height: 16),
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsSegmentedRow<String>(
              title: t.dark_mode,
              icon: Icons.dark_mode_outlined,
              controlBelow: true,
              segments: [
                ButtonSegment<String>(
                  value: 'light',
                  icon: const Icon(Icons.light_mode_outlined, size: 16),
                  tooltip: t.dark_mode_light,
                ),
                ButtonSegment<String>(
                  value: 'system',
                  icon: const Icon(Icons.brightness_auto_outlined, size: 16),
                  tooltip: t.dark_mode_system,
                ),
                ButtonSegment<String>(
                  value: 'dark',
                  icon: const Icon(Icons.dark_mode_outlined, size: 16),
                  tooltip: t.dark_mode_dark,
                ),
              ],
              selected: _brightnessMode,
              onChanged: _setBrightnessMode,
            ),
          ],
        ),
        // ── 种子色 ──
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsRow(
              title: t.seed_color,
              subtitle: t.seed_color_desc,
              icon: Icons.palette_outlined,
              controlBelow: true,
              trailing: LayoutBuilder(
                builder: (layoutContext, constraints) {
                  final double pickerWidth = constraints.maxWidth.clamp(
                    0.0,
                    MediaQuery.of(layoutContext).size.width - 64,
                  );
                  final bool isLandscape =
                      MediaQuery.of(layoutContext).orientation ==
                          Orientation.landscape;
                  return Listener(
                    onPointerDown: (_) => _holdScroll(layoutContext),
                    onPointerUp: (_) => _releaseScroll(),
                    onPointerCancel: (_) => _releaseScroll(),
                    child: ColorPicker(
                      pickerColor: _seed,
                      onColorChanged: _setSeed,
                      colorPickerWidth: pickerWidth,
                      pickerAreaHeightPercent: isLandscape ? 0.4 : 0.6,
                      enableAlpha: false,
                      displayThumbColor: true,
                      hexInputBar: true,
                      labelTypes: const [],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        // ── 主色（音频高亮、按钮、链接等全局强调色）──
        AdaptiveSettingsSection(
          children: [
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
        // ── 阅读器颜色 ──
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
            _buildOptionalColorPicker(
              label: t.color_sasayaki,
              description: t.color_sasayaki_desc,
              preview: _buildSasayakiPreview(cs),
              enabled: _useSasayakiColor,
              onEnabledChanged: (bool value) =>
                  setState(() => _useSasayakiColor = value),
              color: _sasayakiColor!,
              onChanged: (Color color) =>
                  setState(() => _sasayakiColor = color),
              enableAlpha: true,
            ),
          ],
        ),
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
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () async {
            final NavigatorState navigator = Navigator.of(context);
            await appModel.applyCustomTheme(
              seed: _seed,
              brightnessMode: _brightnessMode,
              fontColor: _useFontColor ? _fontColor : null,
              backgroundColor: _useBgColor ? _bgColor : null,
              selectionColor: _useSelectionColor ? _selectionColor : null,
              primaryColor: _usePrimaryColor ? _primaryColor : null,
              secondaryColor: _useSecondaryColor ? _secondaryColor : null,
              tertiaryColor: _useTertiaryColor ? _tertiaryColor : null,
              containerColor: _useContainerColor ? _containerColor : null,
              sasayakiColor: _useSasayakiColor ? _sasayakiColor : null,
              linkColor: _useLinkColor ? _linkColor : null,
            );
            if (!mounted) {
              return;
            }
            navigator.pop();
          },
          icon: const Icon(Icons.check),
          label: Text(t.apply_theme),
        ),
      ],
    );
  }

  // ── 预览卡片 ──

  Widget _buildPreviewCard(ColorScheme cs) {
    final Color textColor = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bgColor = _useBgColor ? _bgColor! : cs.surfaceContainerLow;

    return HibikiCard(
      color: cs.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.preview,
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              _swatch(cs.primary, t.color_primary, cs.onSurface),
              const SizedBox(width: 8),
              _swatch(cs.secondary, t.color_secondary, cs.onSurface),
              const SizedBox(width: 8),
              _swatch(cs.tertiary, t.color_tertiary, cs.onSurface),
              const SizedBox(width: 8),
              _swatch(cs.primaryContainer, t.color_container, cs.onSurface),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: TextStyle(color: textColor, fontSize: 15),
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
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _useSasayakiColor
                        ? _sasayakiColor
                        : HibikiColor.defaultSasayakiColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '♪ 音声ハイライト',
                    style: TextStyle(color: textColor, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 6),
                RichText(
                  text: TextSpan(
                    style: TextStyle(color: textColor, fontSize: 13),
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
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 40,
                height: 22,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.all(2),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(t.preview_switch,
                  style: TextStyle(color: cs.onSurface, fontSize: 12)),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(t.preview_badge,
                    style: TextStyle(
                        color: cs.onSecondaryContainer, fontSize: 11)),
              ),
              const SizedBox(width: 8),
              Container(
                width: 40,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.tertiary,
                  borderRadius: BorderRadius.circular(4),
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
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('あいうえお', style: TextStyle(color: fc, fontSize: 13)),
    );
  }

  Widget _buildBgColorPreview(ColorScheme cs) {
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
      ),
      child: Text('日本語', style: TextStyle(color: fc, fontSize: 13)),
    );
  }

  Widget _buildSelectionPreview(ColorScheme cs) {
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color sel = _useSelectionColor ? _selectionColor! : Colors.grey;
    return RichText(
      text: TextSpan(
        style: TextStyle(color: fc, fontSize: 13),
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
    final Color primary = _primaryColor!;
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('♪ ハイライト', style: TextStyle(color: fc, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Container(
          width: 32,
          height: 18,
          decoration: BoxDecoration(
            color: (_useContainerColor
                    ? _containerColor
                    : _generatedScheme.primaryContainer) ??
                cs.primaryContainer,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSecondaryPreview(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('辞書',
          style: TextStyle(color: cs.onSecondaryContainer, fontSize: 11)),
    );
  }

  Widget _buildTertiaryPreview(ColorScheme cs) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 8,
          decoration: BoxDecoration(
            color: _tertiaryColor,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 4),
        Container(
          width: 32,
          height: 8,
          decoration: BoxDecoration(
            color: _tertiaryColor?.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }

  Widget _buildContainerPreview(ColorScheme cs) {
    return Container(
      width: 40,
      height: 22,
      decoration: BoxDecoration(
        color: _containerColor,
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.all(2),
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: _primaryColor,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _buildSasayakiPreview(ColorScheme cs) {
    final Color fc = _useFontColor ? _fontColor! : cs.onSurface;
    final Color bg = _useBgColor ? _bgColor! : cs.surfaceContainerLow;
    final Color sas =
        _useSasayakiColor ? _sasayakiColor! : HibikiColor.defaultSasayakiColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(color: fc, fontSize: 13),
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
    final Color lc = _useLinkColor ? _linkColor! : cs.primary;
    return Text(
      'リンク',
      style: TextStyle(
        color: lc,
        fontSize: 13,
        decoration: TextDecoration.underline,
        decorationColor: lc,
      ),
    );
  }

  // ── 通用组件 ──

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
    return AdaptiveSettingsSwitchActionRow(
      title: label,
      subtitle: description,
      value: enabled,
      onChanged: onEnabledChanged,
      body: Row(
        children: [
          _colorDot(color),
          if (preview != null) ...[
            const SizedBox(width: 8),
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

  Widget _colorDot(Color color) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
    );
  }

  Widget _swatch(Color color, String label, Color textColor) {
    return Expanded(
      child: Column(
        children: [
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(fontSize: 10, color: textColor),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
