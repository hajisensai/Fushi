import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
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
        Switch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

Widget _buildSegmentedRow<T extends Object>({
  required String label,
  required List<ButtonSegment<T>> segments,
  required Set<T> selected,
  required ValueChanged<Set<T>> onSelectionChanged,
  String? hint,
  bool scrollable = false,
}) {
  final button = Builder(
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return SegmentedButton<T>(
        showSelectedIcon: false,
        segments: segments,
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        style: ButtonStyle(
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
        ),
      );
    },
  );
  if (scrollable) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              if (hint != null) ...[
                const SizedBox(width: 4),
                _HintIcon(hint: hint),
              ],
            ],
          ),
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
        button,
      ],
    ),
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

class _HintIcon extends StatelessWidget {
  const _HintIcon({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showAppDialog(
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

List<Widget> _buildReaderOnlySwitches(VoidCallback rebuild,
    {AppModel? appModel}) {
  return [
    _buildSwitch(
      label: t.highlight_on_tap,
      value: _source.highlightOnTap,
      onChanged: (_) {
        _source.toggleHighlightOnTap();
        rebuild();
      },
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
      onChanged: (_) {
        _source.toggleVolumePageTurningInverted();
        rebuild();
      },
    ),
    _buildSwitch(
      label: t.adapt_ttu_theme,
      value: _source.adaptTtuTheme,
      onChanged: (_) {
        _source.toggleAdaptTtuTheme();
        rebuild();
      },
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
      onChanged: (_) {
        _source.toggleAutoReadOnLookup();
        rebuild();
      },
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
    if (appModel != null)
      _PopupMaxWidthSlider(appModel: appModel, rebuild: rebuild),
  ];
}

Widget _buildPageTurningSpeed(VoidCallback rebuild) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(t.volume_button_turning_speed)),
        SizedBox(
          width: 140,
          child: Slider(
            value: _source.volumePageTurningSpeed.toDouble(),
            min: 10,
            max: 500,
            divisions: 49,
            label: '${_source.volumePageTurningSpeed}',
            onChanged: (v) {
              _source.setVolumePageTurningSpeed(v.round());
              rebuild();
            },
          ),
        ),
      ],
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
    label:
        enabledCount > 0 ? '${t.custom_fonts} ($enabledCount)' : t.custom_fonts,
    onTap: () {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CustomFontsPage()),
      );
    },
  );
}

ChoiceChip _buildThemeChip({
  required BuildContext context,
  required String label,
  required bool selected,
  required ValueChanged<bool> onSelected,
  Widget? avatar,
}) {
  final ColorScheme chipCs = Theme.of(context).colorScheme;
  return ChoiceChip(
    avatar: avatar,
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    selectedColor: chipCs.primaryContainer,
    labelStyle: selected ? TextStyle(color: chipCs.onPrimaryContainer) : null,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: selected ? chipCs.primaryContainer : chipCs.outline,
      ),
    ),
    onSelected: onSelected,
  );
}

/// Theme selector (6 presets + custom) — calls [AppModel.setAppThemeKey].
Widget _buildThemeSelector(AppModel appModel,
    {required BuildContext navContext}) {
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
            final bool selected = appModel.appThemeKey == e.key;
            return _buildThemeChip(
              context: navContext,
              label: AppModel.themeLabel(e.key),
              selected: selected,
              onSelected: (on) {
                if (!on) {
                  return;
                }
                appModel.setAppThemeKey(e.key);
              },
            );
          }),
          _buildThemeChip(
            context: navContext,
            selected: appModel.appThemeKey == 'custom-theme',
            avatar: Icon(
              Icons.palette,
              size: 18,
              color: appModel.appThemeKey == 'custom-theme'
                  ? Theme.of(navContext).colorScheme.onPrimaryContainer
                  : null,
            ),
            label: t.custom_theme,
            onSelected: (_) {
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
              const JidoujishoDivider(),
              const Space.small(),
              _buildFontEntry(context),
              _buildTapRow(
                context: context,
                icon: Icons.text_fields,
                label: t.display_settings,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DisplaySettingsPage()),
                  ).then((_) => setState(() {}));
                },
              ),
              const Space.small(),
              const JidoujishoDivider(),
              const Space.small(),
              ..._buildReaderOnlySwitches(() => setState(() {}),
                  appModel: appModel),
              _buildSwitch(
                label: t.disable_dialog_scrim,
                value: appModel.disableDialogScrim,
                onChanged: (v) {
                  appModel.setDisableDialogScrim(v);
                  setState(() {});
                },
              ),
              const Space.small(),
              const JidoujishoDivider(),
              _buildPageTurningSpeed(() => setState(() {})),
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
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        _buildThemeSelector(appModel, navContext: context),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _categoryTile(
          context,
          icon: Icons.style,
          label: t.anki_settings_label,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AnkiSettingsPage()),
            );
          },
        ),
        _categoryTile(
          context,
          icon: Icons.auto_stories,
          label: t.reader_settings_section,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const _ReaderBehaviorSettingsPage()),
            ).then((_) => setState(() {}));
          },
        ),
        _categoryTile(
          context,
          icon: Icons.system_update,
          label: t.section_update,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const _UpdateSettingsPage()),
            ).then((_) => setState(() {}));
          },
        ),
        _categoryTile(
          context,
          icon: Icons.bug_report,
          label: t.error_log_label(n: ErrorLogService.instance.entries.length),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ErrorLogPage()),
            ).then((_) => setState(() {}));
          },
        ),
      ],
    );
  }

  Widget _categoryTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 22),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}

// ─── Sub-pages for home settings ────────────────────────────────────────────

class _ReaderBehaviorSettingsPage extends BasePage {
  const _ReaderBehaviorSettingsPage();

  @override
  BasePageState createState() => _ReaderBehaviorSettingsPageState();
}

class _ReaderBehaviorSettingsPageState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.reader_settings_section)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          8 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _buildFontEntry(context),
          _buildTapRow(
            context: context,
            icon: Icons.text_fields,
            label: t.display_settings,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const DisplaySettingsPage()),
              ).then((_) => setState(() {}));
            },
          ),
          const Space.small(),
          const JidoujishoDivider(),
          const Space.small(),
          ..._buildReaderOnlySwitches(() => setState(() {}),
              appModel: appModel),
          _buildSwitch(
            label: t.disable_dialog_scrim,
            value: appModel.disableDialogScrim,
            onChanged: (v) {
              appModel.setDisableDialogScrim(v);
              setState(() {});
            },
          ),
          const Space.small(),
          const JidoujishoDivider(),
          _buildPageTurningSpeed(() => setState(() {})),
        ],
      ),
    );
  }
}

class _UpdateSettingsPage extends BasePage {
  const _UpdateSettingsPage();

  @override
  BasePageState createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.section_update)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          8 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
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
          _buildSwitch(
            label: t.update_beta_channel,
            value: appModel.updateBetaChannel,
            onChanged: (v) {
              appModel.setUpdateBetaChannel(v);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _PopupMaxWidthSlider extends StatefulWidget {
  const _PopupMaxWidthSlider({required this.appModel, required this.rebuild});
  final AppModel appModel;
  final VoidCallback rebuild;

  @override
  State<_PopupMaxWidthSlider> createState() => _PopupMaxWidthSliderState();
}

class _PopupMaxWidthSliderState extends State<_PopupMaxWidthSlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.appModel.popupMaxWidth;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('${t.popup_max_width} (${_value.round()})')),
          SizedBox(
            width: 140,
            child: Slider(
              value: _value,
              min: 250,
              max: 600,
              divisions: 35,
              onChanged: (v) {
                setState(() => _value = v);
              },
              onChangeEnd: (v) {
                widget.appModel.setPopupMaxWidth(v);
                widget.rebuild();
              },
            ),
          ),
        ],
      ),
    );
  }
}
