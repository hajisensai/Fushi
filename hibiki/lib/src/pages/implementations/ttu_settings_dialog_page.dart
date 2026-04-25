import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock/wakelock.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

// ─── Shared setting-item builders ────────────────────────────────────────────

ReaderTtuSource get _source => ReaderTtuSource.instance;

Widget _buildSwitch({
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return Row(
    children: [
      Expanded(child: Text(label)),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}

Widget _buildTapRow({
  required BuildContext context,
  required IconData icon,
  required String label,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: Theme.of(context).textTheme.bodyMedium?.fontSize),
          const Space.normal(),
          Text(label),
        ],
      ),
    ),
  );
}

Widget _buildNumberRow({
  required String label,
  required double value,
  required double step,
  required double min,
  required double max,
  required String Function(double) format,
  required ValueChanged<double> onChanged,
  String? hint,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label)),
              if (hint != null) ...[
                const SizedBox(width: 4),
                _HintIcon(hint: hint),
              ],
            ],
          ),
        ),
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

class _HintIcon extends StatelessWidget {
  const _HintIcon({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(hint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
      child: Icon(
        Icons.info_outline,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
      ),
    );
  }
}

Widget _buildDisplaySettings(VoidCallback rebuild) {
  return StatefulBuilder(
    builder: (_, StateSetter setLocal) {
      void update(VoidCallback fn) {
        fn();
        setLocal(() {});
        rebuild();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildNumberRow(
            label: t.ttu_font_size,
            value: _source.ttuFontSize,
            step: 1, min: 8, max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => update(() => _source.setTtuFontSize(v)),
            hint: t.hint_font_size,
          ),
          _buildNumberRow(
            label: t.ttu_line_height,
            value: _source.ttuLineHeight,
            step: 0.1, min: 1.0, max: 3.0,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => update(
                () => _source.setTtuLineHeight((v * 100).roundToDouble() / 100)),
            hint: t.hint_line_height,
          ),
          _buildNumberRow(
            label: t.ttu_text_indentation,
            value: _source.ttuTextIndentation,
            step: 1, min: 0, max: 10,
            format: (v) => '${v.round()}',
            onChanged: (v) => update(() => _source.setTtuTextIndentation(v)),
            hint: t.hint_text_indentation,
          ),
          _buildNumberRow(
            label: t.ttu_first_dimension_margin,
            value: _source.ttuFirstDimensionMargin,
            step: 5, min: 0, max: 100,
            format: (v) => '${v.round()}',
            onChanged: (v) => update(() => _source.setTtuFirstDimensionMargin(v)),
            hint: t.hint_margin,
          ),
          _buildNumberRow(
            label: t.ttu_second_dimension_max,
            value: _source.ttuSecondDimensionMaxValue,
            step: 50, min: 0, max: 2000,
            format: (v) => v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
            onChanged: (v) => update(() => _source.setTtuSecondDimensionMaxValue(v)),
            hint: t.hint_max_width_height,
          ),
          _buildNumberRow(
            label: t.ttu_page_columns,
            value: _source.ttuPageColumns.toDouble(),
            step: 1, min: 0, max: 4,
            format: (v) => v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
            onChanged: (v) => update(() => _source.setTtuPageColumns(v.round())),
            hint: t.hint_page_columns,
          ),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.ttu_writing_direction),
                    const SizedBox(width: 4),
                    _HintIcon(hint: t.hint_writing_direction),
                  ],
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'horizontal-tb', label: Text(t.ttu_horizontal)),
                  ButtonSegment(value: 'vertical-rl', label: Text(t.ttu_vertical)),
                ],
                selected: {_source.ttuWritingMode},
                onSelectionChanged: (sel) =>
                    update(() => _source.setTtuWritingMode(sel.first)),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.ttu_view_mode_label),
                    const SizedBox(width: 4),
                    _HintIcon(hint: t.hint_view_mode),
                  ],
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'paginated', label: Text(t.ttu_paginated)),
                  ButtonSegment(value: 'continuous', label: Text(t.ttu_scroll)),
                ],
                selected: {_source.ttuViewMode},
                onSelectionChanged: (sel) =>
                    update(() => _source.setTtuViewMode(sel.first)),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.ttu_vert_text_orient),
                    const SizedBox(width: 4),
                    _HintIcon(hint: t.hint_vert_text_orient),
                  ],
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'mixed', label: Text(t.ttu_orient_mixed)),
                  ButtonSegment(value: 'upright', label: Text(t.ttu_orient_upright)),
                ],
                selected: {_source.ttuVerticalTextOrientation},
                onSelectionChanged: (sel) =>
                    update(() => _source.setTtuVerticalTextOrientation(sel.first)),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _buildSwitch(
            label: t.ttu_hide_furigana,
            value: _source.ttuHideFurigana,
            onChanged: (v) => update(() => _source.setTtuHideFurigana(v)),
          ),
          Row(
            children: [
              Expanded(child: Text(t.ttu_furigana_style)),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'Partial', label: Text(t.ttu_furigana_partial)),
                  ButtonSegment(value: 'Full', label: Text(t.ttu_furigana_full)),
                  ButtonSegment(value: 'Toggle', label: Text(t.ttu_furigana_toggle)),
                ],
                selected: {_source.ttuFuriganaStyle},
                onSelectionChanged: (sel) =>
                    update(() => _source.setTtuFuriganaStyle(sel.first)),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _buildSwitch(
            label: t.ttu_text_justify,
            value: _source.ttuEnableTextJustification,
            onChanged: (v) => update(() => _source.setTtuEnableTextJustification(v)),
          ),
          _buildSwitch(
            label: t.ttu_vert_kerning,
            value: _source.ttuEnableVerticalFontKerning,
            onChanged: (v) => update(() => _source.setTtuEnableVerticalFontKerning(v)),
          ),
          _buildSwitch(
            label: t.ttu_font_vpal,
            value: _source.ttuEnableFontVPAL,
            onChanged: (v) => update(() => _source.setTtuEnableFontVPAL(v)),
          ),
          _buildSwitch(
            label: t.ttu_reader_styles,
            value: _source.ttuPrioritizeReaderStyles,
            onChanged: (v) => update(() => _source.setTtuPrioritizeReaderStyles(v)),
          ),
        ],
      );
    },
  );
}

List<Widget> _buildReaderOnlySwitches(VoidCallback rebuild) {
  return [
    _buildSwitch(
      label: t.highlight_on_tap,
      value: _source.highlightOnTap,
      onChanged: (_) { _source.toggleHighlightOnTap(); rebuild(); },
    ),
    _buildSwitch(
      label: t.volume_button_page_turning,
      value: _source.volumePageTurningEnabled,
      onChanged: (_) {
        _source.toggleVolumePageTurningEnabled();
        VolumeKeyChannel.instance
            .setInterceptEnabled(_source.volumePageTurningEnabled);
        rebuild();
      },
    ),
    _buildSwitch(
      label: t.invert_volume_buttons,
      value: _source.volumePageTurningInverted,
      onChanged: (_) { _source.toggleVolumePageTurningInverted(); rebuild(); },
    ),
    _buildSwitch(
      label: t.extend_page_beyond_navbar,
      value: _source.extendPageBeyondNavigationBar,
      onChanged: (_) { _source.toggleExtendPageBeyondNavigationBar(); rebuild(); },
    ),
    _buildSwitch(
      label: t.adapt_ttu_theme,
      value: _source.adaptTtuTheme,
      onChanged: (_) { _source.toggleAdaptTtuTheme(); rebuild(); },
    ),
    _buildSwitch(
      label: t.keep_screen_awake,
      value: _source.keepScreenAwake,
      onChanged: (_) async {
        _source.toggleKeepScreenAwake();
        if (_source.keepScreenAwake) {
          await Wakelock.enable();
        } else {
          await Wakelock.disable();
        }
        rebuild();
      },
    ),
    _buildSwitch(
      label: t.auto_read_on_lookup,
      value: _source.autoReadOnLookup,
      onChanged: (_) { _source.toggleAutoReadOnLookup(); rebuild(); },
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(t.dismiss_swipe_sensitivity)),
          SizedBox(
            width: 140,
            child: Slider(
              value: _source.dismissSwipeSensitivity,
              min: 0.1,
              max: 1.0,
              divisions: 9,
              label: _source.dismissSwipeSensitivity.toStringAsFixed(1),
              onChanged: (v) {
                _source.setDismissSwipeSensitivity(v);
                rebuild();
              },
            ),
          ),
        ],
      ),
    ),
  ];
}

Widget _buildPageTurningSpeed({
  required BuildContext context,
  required TextEditingController controller,
}) {
  return TextField(
    onChanged: (value) {
      double newSpeed = double.tryParse(value) ??
          ReaderTtuSource.defaultScrollingSpeed.toDouble();
      if (newSpeed.isNegative) {
        newSpeed = ReaderTtuSource.defaultScrollingSpeed.toDouble();
        controller.text = newSpeed.toString();
      }
      _source.setVolumePageTurningSpeed(newSpeed.toInt());
    },
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      floatingLabelBehavior: FloatingLabelBehavior.always,
      suffixIcon: JidoujishoIconButton(
        tooltip: t.reset,
        size: 18,
        onTap: () async {
          controller.text = ReaderTtuSource.defaultScrollingSpeed.toString();
          _source.setVolumePageTurningSpeed(
              ReaderTtuSource.defaultScrollingSpeed);
          FocusScope.of(context).unfocus();
        },
        icon: Icons.undo,
      ),
      labelText: t.volume_button_turning_speed,
    ),
  );
}

/// Font management entry — opens the [CustomFontsPage].
Widget _buildFontEntry(BuildContext context) {
  final fonts = _source.customFonts;
  final enabledCount = fonts.where((e) => e['enabled'] as bool? ?? true).length;
  return _buildTapRow(
    context: context,
    icon: Icons.font_download,
    label: enabledCount > 0
        ? '${t.custom_fonts} ($enabledCount)'
        : t.custom_fonts,
    onTap: () {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CustomFontsPage()),
      );
    },
  );
}

/// Theme selector (6 presets + custom) — calls [AppModel.setAppThemeKey].
Widget _buildThemeSelector(AppModel appModel, {BuildContext? navContext}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(t.ttu_theme),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          ...AppModel.themePresets.entries.map((e) {
            return ChoiceChip(
              label: Text(e.value.label),
              selected: appModel.appThemeKey == e.key,
              onSelected: (on) {
                if (!on) return;
                appModel.setAppThemeKey(e.key);
              },
            );
          }),
          if (navContext != null)
            ActionChip(
              avatar: Icon(
                Icons.palette,
                size: 18,
                color: appModel.appThemeKey == 'custom-theme'
                    ? Theme.of(navContext).colorScheme.primary
                    : null,
              ),
              label: Text(
                t.custom_theme,
                style: appModel.appThemeKey == 'custom-theme'
                    ? TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(navContext).colorScheme.primary,
                      )
                    : null,
              ),
              onPressed: () {
                Navigator.push(
                  navContext,
                  MaterialPageRoute(builder: (_) => const CustomThemePage()),
                );
              },
            ),
        ],
      ),
    ],
  );
}

// ─── Dialog version (used inside the reader) ─────────────────────────────────

class TtuSettingsDialogPage extends BasePage {
  const TtuSettingsDialogPage({super.key});

  @override
  BasePageState createState() => _TtuSettingsDialogPageState();
}

class _TtuSettingsDialogPageState extends BasePageState {
  late TextEditingController _speedController;

  @override
  void initState() {
    super.initState();
    _speedController = TextEditingController(
        text: _source.volumePageTurningSpeed.toString());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal.copyWith(
                left: Spacing.of(context).spaces.semiBig,
                right: Spacing.of(context).spaces.semiBig,
              ),
      actionsPadding: Spacing.of(context).insets.exceptBottom.normal.copyWith(
            left: Spacing.of(context).spaces.normal,
            right: Spacing.of(context).spaces.normal,
            bottom: Spacing.of(context).spaces.normal,
            top: Spacing.of(context).spaces.extraSmall,
          ),
      content: _buildContent(),
      actions: [
        TextButton(
          child: Text(t.dialog_close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final controller = ScrollController();
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: controller,
        child: SingleChildScrollView(
          controller: controller,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildThemeSelector(appModel, navContext: context),
              const Space.small(),
              _buildFontEntry(context),
              const Space.small(),
              const JidoujishoDivider(),
              const Space.small(),
              _buildDisplaySettings(() => setState(() {})),
              const Space.small(),
              const JidoujishoDivider(),
              const Space.small(),
              ..._buildReaderOnlySwitches(() => setState(() {})),
              const Space.small(),
              const JidoujishoDivider(),
              _buildPageTurningSpeed(
                context: context,
                controller: _speedController,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Full-page version (home "调整" tab) ──────────────────────────────────────

class TtuSettingsDialogContent extends BasePage {
  const TtuSettingsDialogContent({super.key});

  @override
  BasePageState createState() => _TtuSettingsDialogContentState();
}

class _TtuSettingsDialogContentState extends BasePageState {
  late TextEditingController _speedController;

  @override
  void initState() {
    super.initState();
    _speedController = TextEditingController(
        text: _source.volumePageTurningSpeed.toString());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        _buildThemeSelector(appModel, navContext: context),
        const Space.small(),
        _buildTapRow(
          context: context,
          icon: Icons.style,
          label: t.anki_settings_label,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AnkiSettingsPage()),
            );
          },
        ),
        const Space.small(),
        _buildFontEntry(context),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildDisplaySettings(() => setState(() {})),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        ..._buildReaderOnlySwitches(() => setState(() {})),
        const Space.small(),
        const JidoujishoDivider(),
        _buildPageTurningSpeed(
          context: context,
          controller: _speedController,
        ),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildTapRow(
          context: context,
          icon: Icons.translate,
          label: t.options_language,
          onTap: appModel.showLanguageMenu,
        ),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildSwitch(
          label: t.update_never_remind,
          value: appModel.updateNeverRemind,
          onChanged: (v) {
            appModel.setUpdateNeverRemind(v);
            setState(() {});
          },
        ),
        _buildSwitch(
          label: t.update_auto_install,
          value: appModel.updateAutoInstall,
          onChanged: (v) {
            appModel.setUpdateAutoInstall(v);
            setState(() {});
          },
        ),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildTapRow(
          context: context,
          icon: Icons.bug_report,
          label: t.error_log_label(n: ErrorLogService.instance.entries.length),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ErrorLogPage()),
            ).then((_) => setState(() {}));
          },
        ),
        const Space.small(),
        _buildTapRow(
          context: context,
          icon: Icons.code,
          label: t.options_github,
          onTap: () {
            launchUrl(
              Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
              mode: LaunchMode.externalApplication,
            );
          },
        ),
      ],
    );
  }
}
