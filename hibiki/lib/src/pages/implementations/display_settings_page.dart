import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/profile/profile_selector.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';

class DisplaySettingsPage extends BasePage {
  const DisplaySettingsPage({super.key});

  @override
  BasePageState createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends BasePageState {
  ReaderHoshiSource get _source => ReaderHoshiSource.instance;
  ReaderSettings? _settings;

  @override
  void initState() {
    super.initState();
    _settings =
        ReaderHoshiSource.readerSettings ?? ReaderSettings(appModel.database);
    ReaderHoshiSource.readerSettings = _settings;
    _settings!.ready.then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isVertical = _source.ttuWritingMode.startsWith('vertical');
    return Scaffold(
      appBar: AppBar(title: Text(t.display_settings)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          8 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          const ProfileSelector(),
          const Divider(),
          _numberStepper(
            theme,
            label: t.ttu_font_size,
            value: _source.ttuFontSize,
            step: 1,
            min: 8,
            max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuFontSize(v)),
          ),
          _numberStepper(
            theme,
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
            theme,
            label: t.ttu_text_indentation,
            value: _source.ttuTextIndentation,
            step: 1,
            min: 0,
            max: 10,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuTextIndentation(v)),
          ),
          _numberStepper(
            theme,
            label: t.margin_top,
            value: _source.ttuMarginTop,
            step: 1,
            min: -5,
            max: 30,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuMarginTop(v)),
          ),
          _numberStepper(
            theme,
            label: t.margin_bottom,
            value: _source.ttuMarginBottom,
            step: 1,
            min: -5,
            max: 30,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuMarginBottom(v)),
          ),
          _numberStepper(
            theme,
            label: t.margin_left,
            value: _source.ttuMarginLeft,
            step: 1,
            min: -5,
            max: 30,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuMarginLeft(v)),
          ),
          _numberStepper(
            theme,
            label: t.margin_right,
            value: _source.ttuMarginRight,
            step: 1,
            min: -5,
            max: 30,
            format: (v) => '${v.round()}',
            onChanged: (v) => _update(() => _source.setTtuMarginRight(v)),
          ),
          _numberStepper(
            theme,
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
          const Space.small(),
          const HibikiDivider(),
          const Space.small(),
          _settingRow(
            theme,
            label: t.ttu_writing_direction,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                    value: 'horizontal-tb', label: Text(t.ttu_horizontal)),
                ButtonSegment(
                    value: 'vertical-rl', label: Text(t.ttu_vertical)),
              ],
              selected: {_source.ttuWritingMode},
              onSelectionChanged: (sel) =>
                  _update(() => _source.setTtuWritingMode(sel.first)),
              style: _segmentedStyle(theme),
            ),
          ),
          _settingRow(
            theme,
            label: t.ttu_view_mode_label,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'paginated', label: Text(t.ttu_paginated)),
                ButtonSegment(value: 'continuous', label: Text(t.ttu_scroll)),
              ],
              selected: {_source.ttuViewMode},
              onSelectionChanged: (sel) =>
                  _update(() => _source.setTtuViewMode(sel.first)),
              style: _segmentedStyle(theme),
            ),
          ),
          if (isVertical)
            _settingRow(
              theme,
              label: t.ttu_vert_text_orient,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                      value: 'mixed', label: Text(t.ttu_orient_mixed)),
                  ButtonSegment(
                      value: 'upright', label: Text(t.ttu_orient_upright)),
                ],
                selected: {_source.ttuVerticalTextOrientation},
                onSelectionChanged: (sel) => _update(
                    () => _source.setTtuVerticalTextOrientation(sel.first)),
                style: _segmentedStyle(theme),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.ttu_furigana_mode, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                          value: 'show', label: Text(t.ttu_furigana_show)),
                      ButtonSegment(
                          value: 'hide', label: Text(t.ttu_furigana_hide)),
                      ButtonSegment(
                          value: 'partial',
                          label: Text(t.ttu_furigana_partial)),
                      ButtonSegment(
                          value: 'toggle', label: Text(t.ttu_furigana_toggle)),
                    ],
                    selected: {_source.ttuFuriganaMode},
                    onSelectionChanged: (sel) {
                      if (sel.isEmpty) return;
                      _update(() => _source.setTtuFuriganaMode(sel.first));
                    },
                    style: _segmentedStyle(theme),
                  ),
                ),
              ],
            ),
          ),
          const Space.small(),
          const HibikiDivider(),
          const Space.small(),
          _settingRow(
            theme,
            label: t.ttu_text_justify,
            child: Switch(
              value: _source.ttuEnableTextJustification,
              onChanged: (v) =>
                  _update(() => _source.setTtuEnableTextJustification(v)),
            ),
          ),
          if (isVertical)
            _settingRow(
              theme,
              label: t.ttu_vert_kerning,
              child: Switch(
                value: _source.ttuEnableVerticalFontKerning,
                onChanged: (v) =>
                    _update(() => _source.setTtuEnableVerticalFontKerning(v)),
              ),
            ),
          if (isVertical)
            _settingRow(
              theme,
              label: t.ttu_font_vpal,
              child: Switch(
                value: _source.ttuEnableFontVPAL,
                onChanged: (v) =>
                    _update(() => _source.setTtuEnableFontVPAL(v)),
              ),
            ),
          _settingRow(
            theme,
            label: t.ttu_reader_styles,
            child: Switch(
              value: _source.ttuPrioritizeReaderStyles,
              onChanged: (v) =>
                  _update(() => _source.setTtuPrioritizeReaderStyles(v)),
            ),
          ),
        ],
      ),
    );
  }

  void _update(VoidCallback fn) {
    fn();
    setState(() {});
    ReaderHoshiSource.onSettingsChangedLive?.call();
  }

  Widget _settingRow(
    ThemeData theme, {
    required String label,
    required Widget child,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (hint != null && hint.isNotEmpty)
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  ButtonStyle _segmentedStyle(ThemeData theme) {
    final cs = theme.colorScheme;
    return ButtonStyle(
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
  }

  Widget _numberStepper(
    ThemeData theme, {
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return _settingRow(
      theme,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value - step).clamp(min, max)),
          ),
          SizedBox(
            width: 42,
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
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
}
