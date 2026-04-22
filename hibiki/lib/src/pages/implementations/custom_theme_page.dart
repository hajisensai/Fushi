import 'package:flutter/material.dart';
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
  late bool _dark;

  @override
  void initState() {
    super.initState();
    _seed = appModelNoUpdate.customThemeSeed;
    _dark = appModelNoUpdate.customThemeDark;
  }

  ColorScheme get _preview =>
      ColorScheme.fromSeed(seedColor: _seed, brightness: _dark ? Brightness.dark : Brightness.light);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.custom_theme)),
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
          FilledButton.icon(
            onPressed: () => appModel.applyCustomTheme(seed: _seed, dark: _dark),
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
                style: TextStyle(color: cs.onSurface),
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
