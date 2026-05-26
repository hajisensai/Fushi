import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';

class DisplaySettingsPage extends BasePage {
  const DisplaySettingsPage({super.key});

  @override
  BasePageState createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends BasePageState {
  ReaderHibikiSource get _source => ReaderHibikiSource.instance;
  ReaderSettings? _settings;

  @override
  void initState() {
    super.initState();
    _settings = ReaderHibikiSource.readerSettings;
    if (_settings == null) {
      final rs = ReaderSettings(appModel.database);
      rs.refreshFromDb().then((_) {
        ReaderHibikiSource.readerSettings = rs;
        if (mounted) setState(() {});
      });
      _settings = rs;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isVertical = _source.ttuWritingMode.startsWith('vertical');
    return AdaptiveSettingsScaffold(
      title: Text(t.display_settings),
      children: [
        AdaptiveSettingsSection(
          title: t.section_typography,
          children: [
            _numberStepper(
              label: t.ttu_font_size,
              value: _source.ttuFontSize,
              step: 1,
              min: 8,
              max: 64,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuFontSize(v)),
            ),
            _numberStepper(
              label: t.ttu_line_height,
              value: _source.ttuLineHeight,
              step: 0.1,
              min: 1,
              max: 3,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => _update(() =>
                  _source.setTtuLineHeight((v * 100).roundToDouble() / 100)),
            ),
            _numberStepper(
              label: t.ttu_text_indentation,
              value: _source.ttuTextIndentation,
              step: 1,
              min: 0,
              max: 10,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuTextIndentation(v)),
            ),
            _numberStepper(
              label: t.margin_top,
              value: _source.ttuMarginTop,
              step: 1,
              min: -5,
              max: 30,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuMarginTop(v)),
            ),
            _numberStepper(
              label: t.margin_bottom,
              value: _source.ttuMarginBottom,
              step: 1,
              min: -5,
              max: 30,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuMarginBottom(v)),
            ),
            _numberStepper(
              label: t.margin_left,
              value: _source.ttuMarginLeft,
              step: 1,
              min: -5,
              max: 30,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuMarginLeft(v)),
            ),
            _numberStepper(
              label: t.margin_right,
              value: _source.ttuMarginRight,
              step: 1,
              min: -5,
              max: 30,
              format: (v) => '${v.round()}',
              onChanged: (v) => _update(() => _source.setTtuMarginRight(v)),
            ),
            _numberStepper(
              label: t.columns_per_page,
              value: _source.ttuPageColumns.toDouble(),
              step: 1,
              min: 0,
              max: 4,
              format: (v) =>
                  v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
              onChanged: (v) =>
                  _update(() => _source.setTtuPageColumns(v.round())),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.section_layout,
          children: [
            AdaptiveSettingsSegmentedRow<String>(
              title: t.spread_mode,
              segments: [
                ButtonSegment(
                  value: 'off',
                  label: Text(t.spread_off),
                  tooltip: t.spread_off,
                ),
                ButtonSegment(
                  value: 'on',
                  label: Text(t.spread_on),
                  tooltip: t.spread_on,
                ),
                ButtonSegment(
                  value: 'auto',
                  label: Text(t.spread_auto),
                  tooltip: t.spread_auto,
                ),
              ],
              selected: _source.ttuSpreadMode,
              onChanged: (value) =>
                  _update(() => _source.setTtuSpreadMode(value)),
            ),
            if (_source.ttuSpreadMode != 'off')
              AdaptiveSettingsSegmentedRow<String>(
                title: t.spread_direction,
                segments: const [
                  ButtonSegment(
                    value: 'rtl',
                    label: Text('RTL'),
                    tooltip: 'Right to Left',
                  ),
                  ButtonSegment(
                    value: 'ltr',
                    label: Text('LTR'),
                    tooltip: 'Left to Right',
                  ),
                ],
                selected: _source.ttuSpreadDirection,
                onChanged: (value) =>
                    _update(() => _source.setTtuSpreadDirection(value)),
              ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_writing_direction,
              segments: [
                ButtonSegment(
                  value: 'horizontal-tb',
                  label: Text(t.ttu_horizontal),
                  tooltip: t.ttu_horizontal,
                ),
                ButtonSegment(
                  value: 'vertical-rl',
                  label: Text(t.ttu_vertical),
                  tooltip: t.ttu_vertical,
                ),
              ],
              selected: _source.ttuWritingMode,
              onChanged: (value) =>
                  _update(() => _source.setTtuWritingMode(value)),
            ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_view_mode_label,
              segments: [
                ButtonSegment(
                  value: 'paginated',
                  label: Text(t.ttu_paginated),
                  tooltip: t.ttu_paginated,
                ),
                ButtonSegment(
                  value: 'continuous',
                  label: Text(t.ttu_scroll),
                  tooltip: t.ttu_scroll,
                ),
              ],
              selected: _source.ttuViewMode,
              onChanged: (value) =>
                  _update(() => _source.setTtuViewMode(value)),
            ),
            if (isVertical)
              AdaptiveSettingsSegmentedRow<String>(
                title: t.ttu_vert_text_orient,
                segments: [
                  ButtonSegment(
                    value: 'mixed',
                    label: Text(t.ttu_orient_mixed),
                    tooltip: t.ttu_orient_mixed,
                  ),
                  ButtonSegment(
                    value: 'upright',
                    label: Text(t.ttu_orient_upright),
                    tooltip: t.ttu_orient_upright,
                  ),
                ],
                selected: _source.ttuVerticalTextOrientation,
                onChanged: (value) =>
                    _update(() => _source.setTtuVerticalTextOrientation(value)),
              ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_furigana_mode,
              controlBelow: true,
              segments: [
                ButtonSegment(
                  value: 'show',
                  label: Text(t.ttu_furigana_show),
                  tooltip: t.ttu_furigana_show,
                ),
                ButtonSegment(
                  value: 'hide',
                  label: Text(t.ttu_furigana_hide),
                  tooltip: t.ttu_furigana_hide,
                ),
                ButtonSegment(
                  value: 'partial',
                  label: Text(t.ttu_furigana_partial),
                  tooltip: t.ttu_furigana_partial,
                ),
                ButtonSegment(
                  value: 'toggle',
                  label: Text(t.ttu_furigana_toggle),
                  tooltip: t.ttu_furigana_toggle,
                ),
              ],
              selected: _source.ttuFuriganaMode,
              onChanged: (value) =>
                  _update(() => _source.setTtuFuriganaMode(value)),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.section_advanced_colors,
          children: [
            AdaptiveSettingsSwitchRow(
              title: t.ttu_text_justify,
              value: _source.ttuEnableTextJustification,
              onChanged: (v) =>
                  _update(() => _source.setTtuEnableTextJustification(v)),
            ),
            if (isVertical)
              AdaptiveSettingsSwitchRow(
                title: t.ttu_vert_kerning,
                value: _source.ttuEnableVerticalFontKerning,
                onChanged: (v) =>
                    _update(() => _source.setTtuEnableVerticalFontKerning(v)),
              ),
            if (isVertical)
              AdaptiveSettingsSwitchRow(
                title: t.ttu_font_vpal,
                value: _source.ttuEnableFontVPAL,
                onChanged: (v) =>
                    _update(() => _source.setTtuEnableFontVPAL(v)),
              ),
            AdaptiveSettingsSwitchRow(
              title: t.ttu_reader_styles,
              value: _source.ttuPrioritizeReaderStyles,
              onChanged: (v) =>
                  _update(() => _source.setTtuPrioritizeReaderStyles(v)),
            ),
          ],
        ),
      ],
    );
  }

  void _update(VoidCallback fn) {
    fn();
    setState(() {});
    ReaderHibikiSource.onSettingsChangedLive?.call();
  }

  Widget _numberStepper({
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return AdaptiveSettingsStepperRow(
      title: label,
      value: value,
      step: step,
      min: min,
      max: max,
      format: format,
      onChanged: onChanged,
    );
  }
}
