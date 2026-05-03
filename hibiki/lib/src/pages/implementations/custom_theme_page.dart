import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:fluttertoast/fluttertoast.dart';
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
  late bool _dark;
  Color? _fontColor;
  bool _useFontColor = false;
  Color? _bgColor;
  bool _useBgColor = false;
  Color? _selectionColor;
  bool _useSelectionColor = false;

  @override
  void initState() {
    super.initState();
    _seed = appModelNoUpdate.customThemeSeed;
    _dark = appModelNoUpdate.customThemeDark;
    _fontColor = appModelNoUpdate.customThemeFontColor;
    _useFontColor = _fontColor != null;
    _fontColor ??= Colors.black;
    _bgColor = appModelNoUpdate.customThemeBackgroundColor;
    _useBgColor = _bgColor != null;
    _bgColor ??= Colors.white;
    _selectionColor = appModelNoUpdate.customThemeSelectionColor;
    _useSelectionColor = _selectionColor != null;
    _selectionColor ??= Colors.grey;
  }

  ColorScheme get _preview =>
      ColorScheme.fromSeed(seedColor: _seed, brightness: _dark ? Brightness.dark : Brightness.light);

  String _encodeTheme() {
    final hex = _seed.toARGB32().toRadixString(16).padLeft(8, '0');
    var code = 'hibiki-theme:$hex:${_dark ? "dark" : "light"}';
    if (_useFontColor && _fontColor != null) {
      final fontHex = _fontColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':fc$fontHex';
    }
    if (_useBgColor && _bgColor != null) {
      final bgHex = _bgColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':bg$bgHex';
    }
    if (_useSelectionColor && _selectionColor != null) {
      final selHex = _selectionColor!.toARGB32().toRadixString(16).padLeft(8, '0');
      code += ':sc$selHex';
    }
    return code;
  }

  static ({Color seed, bool dark, Color? fontColor, Color? bgColor, Color? selectionColor})? _decodeTheme(String code) {
    final parts = code.trim().split(':');
    if (parts.length < 3 || parts[0] != 'hibiki-theme') return null;
    final colorVal = int.tryParse(parts[1], radix: 16);
    if (colorVal == null) return null;
    final dark = parts[2] == 'dark';
    if (parts[2] != 'dark' && parts[2] != 'light') return null;
    Color? fontColor;
    Color? bgColor;
    Color? selectionColor;
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
      }
    }
    return (seed: Color(colorVal), dark: dark, fontColor: fontColor, bgColor: bgColor, selectionColor: selectionColor);
  }

  void _shareTheme() {
    final code = _encodeTheme();
    Clipboard.setData(ClipboardData(text: code));
    Fluttertoast.showToast(msg: t.theme_code_copied);
  }

  void _importTheme() {
    final controller = TextEditingController();
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.import_theme),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: t.import_theme_hint),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
          FilledButton(
            onPressed: () {
              final result = _decodeTheme(controller.text);
              if (result == null) {
                Fluttertoast.showToast(msg: t.import_theme_invalid);
                return;
              }
              Navigator.pop(ctx);
              setState(() {
                _seed = result.seed;
                _dark = result.dark;
                _fontColor = result.fontColor ?? Colors.black;
                _useFontColor = result.fontColor != null;
                _bgColor = result.bgColor ?? Colors.white;
                _useBgColor = result.bgColor != null;
                _selectionColor = result.selectionColor ?? Colors.grey;
                _useSelectionColor = result.selectionColor != null;
              });
              Fluttertoast.showToast(msg: t.import_theme_success);
            },
            child: Text(t.dialog_import),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.custom_theme),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste),
            tooltip: t.import_theme,
            onPressed: _importTheme,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: t.share_theme,
            onPressed: _shareTheme,
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom + MediaQuery.of(context).viewInsets.bottom,
        ),
        children: [
          _buildPreviewCard(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text(t.dark_mode)),
              Switch(
                value: _dark,
                onChanged: (v) => setState(() => _dark = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(t.seed_color, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final pickerWidth = constraints.maxWidth.clamp(0.0, MediaQuery.of(context).size.width - 64);
              final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
              return ColorPicker(
                pickerColor: _seed,
                onColorChanged: (c) => setState(() => _seed = c),
                colorPickerWidth: pickerWidth,
                pickerAreaHeightPercent: isLandscape ? 0.4 : 0.6,
                enableAlpha: false,
                displayThumbColor: true,
                hexInputBar: true,
                labelTypes: const [],
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text(t.font_color)),
              Switch(
                value: _useFontColor,
                onChanged: (v) => setState(() => _useFontColor = v),
              ),
            ],
          ),
          if (_useFontColor) ...[
            const SizedBox(height: 8),
            _buildCompactColorPicker(
              color: _fontColor!,
              onChanged: (c) => setState(() => _fontColor = c),
              enableAlpha: true,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text(t.background_color)),
              Switch(
                value: _useBgColor,
                onChanged: (v) => setState(() => _useBgColor = v),
              ),
            ],
          ),
          if (_useBgColor) ...[
            const SizedBox(height: 8),
            _buildCompactColorPicker(
              color: _bgColor!,
              onChanged: (c) => setState(() => _bgColor = c),
              enableAlpha: false,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text(t.selection_color)),
              Switch(
                value: _useSelectionColor,
                onChanged: (v) => setState(() => _useSelectionColor = v),
              ),
            ],
          ),
          if (_useSelectionColor) ...[
            const SizedBox(height: 8),
            _buildCompactColorPicker(
              color: _selectionColor!,
              onChanged: (c) => setState(() => _selectionColor = c),
              enableAlpha: true,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              appModel.applyCustomTheme(
                seed: _seed,
                dark: _dark,
                fontColor: _useFontColor ? _fontColor : null,
                backgroundColor: _useBgColor ? _bgColor : null,
                selectionColor: _useSelectionColor ? _selectionColor : null,
              );
              Navigator.pop(context);
            },
            icon: const Icon(Icons.check),
            label: Text(t.apply_theme),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    final cs = _preview;
    return Card(
      color: cs.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.preview, style: TextStyle(color: cs.onSurface, fontSize: 16, fontWeight: FontWeight.bold)),
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
                color: _useBgColor ? _bgColor : cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(color: _useFontColor ? _fontColor : cs.onSurface),
                  children: [
                    const TextSpan(text: '日本語の'),
                    TextSpan(
                      text: 'テキスト',
                      style: TextStyle(
                        backgroundColor: _useSelectionColor ? _selectionColor : null,
                      ),
                    ),
                    const TextSpan(text: 'プレビュー\nSample text preview'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactColorPicker({
    required Color color,
    required ValueChanged<Color> onChanged,
    required bool enableAlpha,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pickerWidth = constraints.maxWidth.clamp(0.0, MediaQuery.of(context).size.width - 64);
        final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
        return ColorPicker(
          pickerColor: color,
          onColorChanged: onChanged,
          colorPickerWidth: pickerWidth,
          pickerAreaHeightPercent: isLandscape ? 0.35 : 0.5,
          enableAlpha: enableAlpha,
          displayThumbColor: true,
          hexInputBar: true,
          labelTypes: const [],
        );
      },
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
          Text(label, style: TextStyle(fontSize: 10, color: textColor), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
