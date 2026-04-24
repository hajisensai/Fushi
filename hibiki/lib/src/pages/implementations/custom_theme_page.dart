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

  @override
  void initState() {
    super.initState();
    _seed = appModelNoUpdate.customThemeSeed;
    _dark = appModelNoUpdate.customThemeDark;
    _fontColor = appModelNoUpdate.customThemeFontColor;
    _useFontColor = _fontColor != null;
    _fontColor ??= Colors.black;
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
    return code;
  }

  static ({Color seed, bool dark, Color? fontColor})? _decodeTheme(String code) {
    final parts = code.trim().split(':');
    if (parts.length < 3 || parts[0] != 'hibiki-theme') return null;
    final colorVal = int.tryParse(parts[1], radix: 16);
    if (colorVal == null) return null;
    final dark = parts[2] == 'dark';
    if (parts[2] != 'dark' && parts[2] != 'light') return null;
    Color? fontColor;
    if (parts.length >= 4 && parts[3].startsWith('fc')) {
      final fcVal = int.tryParse(parts[3].substring(2), radix: 16);
      if (fcVal != null) fontColor = Color(fcVal);
    }
    return (seed: Color(colorVal), dark: dark, fontColor: fontColor);
  }

  void _shareTheme() {
    final code = _encodeTheme();
    Clipboard.setData(ClipboardData(text: code));
    Fluttertoast.showToast(msg: t.theme_code_copied);
  }

  void _importTheme() {
    final controller = TextEditingController();
    showDialog(
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
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          ColorPicker(
            pickerColor: _seed,
            onColorChanged: (c) => setState(() => _seed = c),
            colorPickerWidth: MediaQuery.of(context).size.width - 64,
            pickerAreaHeightPercent: 0.6,
            enableAlpha: false,
            displayThumbColor: true,
            hexInputBar: true,
            labelTypes: const [],
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
            ColorPicker(
              pickerColor: _fontColor!,
              onColorChanged: (c) => setState(() => _fontColor = c),
              colorPickerWidth: MediaQuery.of(context).size.width - 64,
              pickerAreaHeightPercent: 0.5,
              enableAlpha: true,
              displayThumbColor: true,
              hexInputBar: true,
              labelTypes: const [],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              appModel.applyCustomTheme(
                seed: _seed,
                dark: _dark,
                fontColor: _useFontColor ? _fontColor : null,
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
                _swatch(cs.primary, 'Primary'),
                const SizedBox(width: 8),
                _swatch(cs.secondary, 'Secondary'),
                const SizedBox(width: 8),
                _swatch(cs.tertiary, 'Tertiary'),
                const SizedBox(width: 8),
                _swatch(cs.primaryContainer, 'Container'),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '日本語のテキストプレビュー\nSample text preview',
                style: TextStyle(color: _useFontColor ? _fontColor : cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(Color color, String label) {
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
          Text(label, style: const TextStyle(fontSize: 10), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
