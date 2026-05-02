import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

class DisplaySettingsPage extends BasePage {
  const DisplaySettingsPage({super.key});

  @override
  BasePageState createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends BasePageState {
  ReaderTtuSource get _source => ReaderTtuSource.instance;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.display_settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _numberRow(
            label: t.ttu_font_size,
            value: _source.ttuFontSize,
            step: 1,
            min: 8,
            max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuFontSize(v)),
          ),
          _numberRow(
            label: t.ttu_line_height,
            value: _source.ttuLineHeight,
            step: 0.1,
            min: 1.0,
            max: 3.0,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _update(
                () => _source.setTtuLineHeight((v * 100).roundToDouble() / 100)),
          ),
          _numberRow(
            label: t.ttu_text_indentation,
            value: _source.ttuTextIndentation,
            step: 1,
            min: 0,
            max: 10,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuTextIndentation(v)),
          ),
          _numberRow(
            label: t.ttu_first_dimension_margin,
            value: _source.ttuFirstDimensionMargin,
            step: 5,
            min: 0,
            max: 100,
            format: (v) => '${v.round()}',
            onChanged: (v) =>
                _update(() => _source.setTtuFirstDimensionMargin(v)),
          ),
          _numberRow(
            label: t.ttu_second_dimension_margin,
            value: _source.ttuSecondDimensionMargin,
            step: 5,
            min: 0,
            max: 100,
            format: (v) => '${v.round()}',
            onChanged: (v) =>
                _update(() => _source.setTtuSecondDimensionMargin(v)),
          ),
          _numberRow(
            label: t.ttu_second_dimension_max,
            value: _source.ttuSecondDimensionMaxValue,
            step: 50,
            min: 0,
            max: 2000,
            format: (v) =>
                v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
            onChanged: (v) =>
                _update(() => _source.setTtuSecondDimensionMaxValue(v)),
          ),
          _numberRow(
            label: t.ttu_page_columns,
            value: _source.ttuPageColumns.toDouble(),
            step: 1,
            min: 0,
            max: 4,
            format: (v) =>
                v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
            onChanged: (v) =>
                _update(() => _source.setTtuPageColumns(v.round())),
          ),
          const Space.small(),
          const JidoujishoDivider(),
          const Space.small(),
          _segmentedRow(
            label: t.ttu_writing_direction,
            segments: [
              ButtonSegment(
                  value: 'horizontal-tb', label: Text(t.ttu_horizontal)),
              ButtonSegment(
                  value: 'vertical-rl', label: Text(t.ttu_vertical)),
            ],
            selected: {_source.ttuWritingMode},
            onSelectionChanged: (sel) =>
                _update(() => _source.setTtuWritingMode(sel.first)),
            cs: cs,
          ),
          _segmentedRow(
            label: t.ttu_view_mode_label,
            segments: [
              ButtonSegment(
                  value: 'paginated', label: Text(t.ttu_paginated)),
              ButtonSegment(
                  value: 'continuous', label: Text(t.ttu_scroll)),
            ],
            selected: {_source.ttuViewMode},
            onSelectionChanged: (sel) =>
                _update(() => _source.setTtuViewMode(sel.first)),
            cs: cs,
          ),
          _segmentedRow(
            label: t.ttu_vert_text_orient,
            segments: [
              ButtonSegment(
                  value: 'mixed', label: Text(t.ttu_orient_mixed)),
              ButtonSegment(
                  value: 'upright', label: Text(t.ttu_orient_upright)),
            ],
            selected: {_source.ttuVerticalTextOrientation},
            onSelectionChanged: (sel) =>
                _update(() => _source.setTtuVerticalTextOrientation(sel.first)),
            cs: cs,
          ),
          _segmentedRow(
            label: t.ttu_furigana_mode,
            scrollable: true,
            segments: [
              ButtonSegment(
                  value: 'show', label: Text(t.ttu_furigana_show)),
              ButtonSegment(
                  value: 'hide', label: Text(t.ttu_furigana_hide)),
              ButtonSegment(
                  value: 'partial', label: Text(t.ttu_furigana_partial)),
              ButtonSegment(
                  value: 'toggle', label: Text(t.ttu_furigana_toggle)),
            ],
            selected: {_source.ttuFuriganaMode},
            onSelectionChanged: (sel) {
              if (sel.isEmpty) return;
              _update(() => _source.setTtuFuriganaMode(sel.first));
            },
            cs: cs,
          ),
          const Space.small(),
          const JidoujishoDivider(),
          const Space.small(),
          _switchRow(
            label: t.ttu_text_justify,
            value: _source.ttuEnableTextJustification,
            onChanged: (v) =>
                _update(() => _source.setTtuEnableTextJustification(v)),
          ),
          _switchRow(
            label: t.ttu_vert_kerning,
            value: _source.ttuEnableVerticalFontKerning,
            onChanged: (v) =>
                _update(() => _source.setTtuEnableVerticalFontKerning(v)),
          ),
          _switchRow(
            label: t.ttu_font_vpal,
            value: _source.ttuEnableFontVPAL,
            onChanged: (v) => _update(() => _source.setTtuEnableFontVPAL(v)),
          ),
          _switchRow(
            label: t.ttu_reader_styles,
            value: _source.ttuPrioritizeReaderStyles,
            onChanged: (v) =>
                _update(() => _source.setTtuPrioritizeReaderStyles(v)),
          ),
        ],
      ),
    );
  }

  void _update(VoidCallback fn) {
    fn();
    setState(() {});
  }

  Widget _numberRow({
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value - step).clamp(min, max)),
          ),
          SizedBox(
            width: 42,
            child: Text(format(value), textAlign: TextAlign.center),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value + step).clamp(min, max)),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _segmentedRow({
    required String label,
    required List<ButtonSegment<String>> segments,
    required Set<String> selected,
    required ValueChanged<Set<String>> onSelectionChanged,
    required ColorScheme cs,
    bool scrollable = false,
  }) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return cs.primaryContainer;
        }
        return null;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return cs.onPrimaryContainer;
        }
        return null;
      }),
    );
    final button = SegmentedButton<String>(
      segments: segments,
      selected: selected,
      onSelectionChanged: onSelectionChanged,
      style: style,
    );
    if (scrollable) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: button,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          button,
        ],
      ),
    );
  }
}
