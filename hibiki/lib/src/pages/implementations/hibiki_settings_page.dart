import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/profile/profile_selector.dart';
import 'package:hibiki/utils.dart';

// ─── Shared setting-item builders ────────────────────────────────────────────

ReaderHibikiSource get _source => ReaderHibikiSource.instance;

Widget _buildSwitch({
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
  String? hint,
  IconData? icon,
}) {
  return SwitchListTile.adaptive(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    secondary: icon != null ? Icon(icon, size: 20) : null,
    title: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(label)),
        if (hint != null) ...[
          const SizedBox(width: 4),
          _HintIcon(hint: hint),
        ],
      ],
    ),
    value: value,
    onChanged: onChanged,
  );
}

Widget _buildSegmentedRow<T extends Object>({
  required BuildContext context,
  required String label,
  required List<ButtonSegment<T>> segments,
  required Set<T> selected,
  required ValueChanged<Set<T>> onSelectionChanged,
  String? hint,
  bool scrollable = false,
}) {
  final button = adaptiveSegmentedButton<T>(
    context: context,
    segments: segments,
    selected: selected,
    onSelectionChanged: onSelectionChanged,
    style: kSettingsSegmentedStyle,
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
  final cs = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 24),
          const Space.normal(),
          Expanded(child: Text(label)),
          Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
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
    final Widget icon = Icon(
      Icons.info_outline,
      size: 16,
      color:
          Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
    if (isDesktopPlatform) {
      return Tooltip(message: hint, child: icon);
    }
    return GestureDetector(
      onTap: () => showAppDialog(
        context: context,
        builder: (ctx) => adaptiveAlertDialog(
          context: ctx,
          content: Text(hint),
          actions: [
            adaptiveDialogAction(
              context: ctx,
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
      child: icon,
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
      label: t.volume_key_sentence_nav,
      value: _source.volumeKeySentenceNavEnabled,
      onChanged: (_) {
        _source.toggleVolumeKeySentenceNavEnabled();
        rebuild();
      },
    ),
    _buildSwitch(
      label: t.invert_swipe_direction,
      value: _source.invertSwipeDirection,
      onChanged: (_) {
        _source.toggleInvertSwipeDirection();
        rebuild();
      },
    ),
    _buildSwitch(
      label: t.keep_screen_awake,
      value: _source.keepScreenAwake,
      onChanged: (_) async {
        _source.toggleKeepScreenAwake();
        try {
          if (_source.keepScreenAwake) {
            await WakelockPlus.enable();
          } else {
            await WakelockPlus.disable();
          }
        } catch (_) {}
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
            child: Builder(
              builder: (BuildContext context) => adaptiveSlider(
                context: context,
                value: _source.dismissSwipeSensitivity,
                min: 0.1,
                divisions: 9,
                label: _source.dismissSwipeSensitivity.toStringAsFixed(1),
                onChanged: (v) {
                  _source.setDismissSwipeSensitivity(v);
                  rebuild();
                },
              ),
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
          child: Builder(
            builder: (BuildContext context) => adaptiveSlider(
              context: context,
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
    icon: Icons.font_download_outlined,
    label:
        enabledCount > 0 ? '${t.custom_fonts} ($enabledCount)' : t.custom_fonts,
    onTap: () {
      Navigator.push(
        context,
        adaptivePageRoute(builder: (_) => const CustomFontsPage()),
      ).then((_) {
        ReaderHibikiSource.onSettingsChangedLive?.call();
      });
    },
  );
}

const double _kSwatchSize = 48.0;

Widget _buildColorSwatch({
  required Color color,
  required bool selected,
  required VoidCallback onTap,
  Widget? overlay,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: _kSwatchSize,
      height: _kSwatchSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: selected
            ? Border.all(
                color: color,
                width: 3,
                strokeAlign: BorderSide.strokeAlignOutside)
            : null,
      ),
      child: selected
          ? Icon(Icons.check,
              color:
                  ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                      ? Colors.white
                      : Colors.black,
              size: 20)
          : overlay,
    ),
  );
}

/// Theme selector (color swatches + custom) — calls [AppModel.setAppThemeKey].
Widget _buildThemeSelector(AppModel appModel,
    {required BuildContext navContext}) {
  final systemColor = appModel.systemPrimaryColor ?? const Color(0xFF1F4959);

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(t.ttu_theme),
      const SizedBox(height: 8),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _buildColorSwatch(
            color: systemColor,
            selected: appModel.appThemeKey == 'system-theme',
            overlay: Icon(
              Icons.auto_awesome_outlined,
              size: 18,
              color: ThemeData.estimateBrightnessForColor(systemColor) ==
                      Brightness.dark
                  ? Colors.white70
                  : Colors.black54,
            ),
            onTap: () {
              appModel.setAppThemeKey('system-theme');
              ReaderHibikiSource.onSettingsChangedLive?.call();
            },
          ),
          ...AppModel.themePresets.entries.map((e) {
            return _buildColorSwatch(
              color: e.value.seed,
              selected: appModel.appThemeKey == e.key,
              onTap: () {
                appModel.setAppThemeKey(e.key);
                ReaderHibikiSource.onSettingsChangedLive?.call();
              },
            );
          }),
          _buildColorSwatch(
            color: appModel.customThemeSeed,
            selected: appModel.appThemeKey == 'custom-theme',
            overlay: Icon(
              Icons.palette_outlined,
              size: 18,
              color: ThemeData.estimateBrightnessForColor(
                          appModel.customThemeSeed) ==
                      Brightness.dark
                  ? Colors.white70
                  : Colors.black54,
            ),
            onTap: () {
              Navigator.push(
                navContext,
                adaptivePageRoute(builder: (_) => const CustomThemePage()),
              ).then((_) {
                ReaderHibikiSource.onSettingsChangedLive?.call();
              });
            },
          ),
        ],
      ),
      const SizedBox(height: 12),
      _buildBrightnessSelector(appModel, navContext: navContext),
    ],
  );
}

Widget _buildBrightnessSelector(AppModel appModel,
    {required BuildContext navContext}) {
  return Row(
    children: [
      Expanded(child: Text(t.dark_mode)),
      adaptiveSegmentedButton<String>(
        context: navContext,
        segments: const [
          ButtonSegment(
            value: 'light',
            icon: Icon(Icons.light_mode_outlined, size: 16),
          ),
          ButtonSegment(
            value: 'system',
            icon: Icon(Icons.brightness_auto_outlined, size: 16),
          ),
          ButtonSegment(
            value: 'dark',
            icon: Icon(Icons.dark_mode_outlined, size: 16),
          ),
        ],
        selected: {appModel.brightnessMode},
        onSelectionChanged: (selected) {
          appModel.setBrightnessMode(selected.first);
          ReaderHibikiSource.onSettingsChangedLive?.call();
        },
        style: kSettingsSegmentedStyle,
      ),
    ],
  );
}

// ─── Dialog version (used inside the reader) ─────────────────────────────────

class HibikiSettingsDialogPage extends BasePage {
  const HibikiSettingsDialogPage({super.key});

  @override
  BasePageState createState() => _HibikiSettingsDialogPageState();
}

class _HibikiSettingsDialogPageState extends BasePageState {
  final ScrollController _contentScrollController = ScrollController();

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return adaptiveAlertDialog(
      context: context,
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
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _contentScrollController,
        child: SingleChildScrollView(
          controller: _contentScrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildThemeSelector(appModel, navContext: context),
              const HibikiDivider(),
              _buildFontEntry(context),
              _buildTapRow(
                context: context,
                icon: Icons.text_fields,
                label: t.display_settings,
                onTap: () {
                  Navigator.push(
                    context,
                    adaptivePageRoute(
                        builder: (_) => const DisplaySettingsPage()),
                  ).then((_) => setState(() {}));
                },
              ),
              const HibikiDivider(),
              ..._buildReaderOnlySwitches(() => setState(() {}),
                  appModel: appModel),
              const HibikiDivider(),
              _buildPageTurningSpeed(() => setState(() {})),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Full-page version (home "调整" tab) ──────────────────────────────────────

class HibikiSettingsContent extends BasePage {
  const HibikiSettingsContent({super.key});

  @override
  BasePageState createState() => _HibikiSettingsContentState();
}

class _HibikiSettingsContentState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.settings,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildThemeSelector(appModel, navContext: context),
          const HibikiDivider(),
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const Icon(Icons.person_outline, size: 24),
            title: const ProfileSelector(),
          ),
          _categoryTile(
            context,
            icon: Icons.style_outlined,
            label: t.anki_settings_label,
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(builder: (_) => const AnkiSettingsPage()),
              );
            },
          ),
          _categoryTile(
            context,
            icon: Icons.auto_stories_outlined,
            label: t.reader_settings_section,
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(
                    builder: (_) => const _ReaderBehaviorSettingsPage()),
              ).then((_) => setState(() {}));
            },
          ),
          _categoryTile(
            context,
            icon: Icons.system_update_outlined,
            label: t.section_update,
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(builder: (_) => const _UpdateSettingsPage()),
              ).then((_) => setState(() {}));
            },
          ),
          _categoryTile(
            context,
            icon: Icons.widgets_outlined,
            label: t.miscellaneous_settings,
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(
                    builder: (_) => const MiscellaneousSettingsPage()),
              );
            },
          ),
          _categoryTile(
            context,
            icon: Icons.bug_report_outlined,
            label:
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(builder: (_) => const ErrorLogPage()),
              ).then((_) => setState(() {}));
            },
          ),
          if (DebugLogService.instance.enabled)
            _categoryTile(
              context,
              icon: Icons.terminal_outlined,
              label: t.debug_log_title(
                  count: DebugLogService.instance.entries.length),
              onTap: () {
                Navigator.push(
                  context,
                  adaptivePageRoute(builder: (_) => const DebugLogPage()),
                ).then((_) => setState(() {}));
              },
            ),
        ],
      ),
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
      leading: Icon(icon, size: 24),
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
      appBar: adaptiveAppBar(
          context: context, title: Text(t.reader_settings_section)),
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
                adaptivePageRoute(builder: (_) => const DisplaySettingsPage()),
              ).then((_) => setState(() {}));
            },
          ),
          _buildTapRow(
            context: context,
            icon: Icons.audiotrack_outlined,
            label: t.audiobook_settings,
            onTap: () {
              Navigator.push(
                context,
                adaptivePageRoute(
                    builder: (_) => const _AudiobookSettingsPage()),
              ).then((_) => setState(() {}));
            },
          ),
          const HibikiDivider(),
          ..._buildReaderOnlySwitches(() => setState(() {}),
              appModel: appModel),
          const HibikiDivider(),
          _buildPageTurningSpeed(() => setState(() {})),
        ],
      ),
    );
  }
}

class _AudiobookSettingsPage extends BasePage {
  const _AudiobookSettingsPage();

  @override
  BasePageState createState() => _AudiobookSettingsPageState();
}

class _AudiobookSettingsPageState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          adaptiveAppBar(context: context, title: Text(t.audiobook_settings)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          8 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _buildSwitch(
            label: t.show_media_notification,
            value: appModel.showMediaNotification,
            onChanged: (_) {
              appModel.toggleShowMediaNotification();
              setState(() {});
            },
          ),
          _buildSwitch(
            label: t.show_floating_lyric,
            value: appModel.showFloatingLyric,
            onChanged: (_) async {
              await appModel.setShowFloatingLyric(!appModel.showFloatingLyric);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(t.floating_lyric_font_size)),
                IconButton(
                  icon: const Icon(Icons.remove, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    final double v =
                        (appModel.floatingLyricFontSize - 1).clamp(8, 64);
                    await appModel.setFloatingLyricFontSize(v);
                    setState(() {});
                  },
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    appModel.floatingLyricFontSize.round().toString(),
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    final double v =
                        (appModel.floatingLyricFontSize + 1).clamp(8, 64);
                    await appModel.setFloatingLyricFontSize(v);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
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
      appBar: adaptiveAppBar(context: context, title: Text(t.section_update)),
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
          const HibikiDivider(),
          _buildSwitch(
            label: t.update_debug_channel,
            value: appModel.updateDebugChannel,
            onChanged: (v) async {
              if (v) {
                final confirmed = await showAppDialog<bool>(
                  context: context,
                  builder: (ctx) => adaptiveAlertDialog(
                    context: ctx,
                    title: Text(t.update_debug_channel),
                    content: Text(t.update_debug_channel_warning),
                    actions: [
                      adaptiveDialogAction(
                        context: ctx,
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.dialog_cancel),
                      ),
                      adaptiveDialogAction(
                        context: ctx,
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.dialog_done),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
              }
              appModel.setUpdateDebugChannel(v);
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
            child: adaptiveSlider(
              context: context,
              value: _value,
              min: 250,
              max: 1000,
              divisions: 75,
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
