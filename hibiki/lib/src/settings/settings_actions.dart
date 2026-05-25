import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const double _swatchSize = 48.0;

Future<void> pushSettingsPage(
  SettingsContext settingsContext,
  WidgetBuilder builder,
) async {
  await Navigator.of(settingsContext.context).push(
    adaptivePageRoute(
      context: settingsContext.context,
      builder: builder,
    ),
  );
}

Future<void> showSettingsDialog(
  SettingsContext settingsContext,
  WidgetBuilder builder,
) async {
  await showAppDialog(
    context: settingsContext.context,
    builder: builder,
  );
}

void notifyReaderSettingsChanged(SettingsContext settingsContext) {
  ReaderHibikiSource.onSettingsChangedLive?.call();
  settingsContext.refresh();
}

Future<void> setKeepScreenAwake(
  SettingsContext settingsContext,
  bool value,
) async {
  settingsContext.readerSource.toggleKeepScreenAwake();
  try {
    if (settingsContext.readerSource.keepScreenAwake) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  } catch (e) {
    debugPrint('[Hibiki] wakelock toggle failed: $e');
  }
  notifyReaderSettingsChanged(settingsContext);
}

Future<void> confirmDebugChannel(
  SettingsContext settingsContext,
  bool value,
) async {
  final BuildContext context = settingsContext.context;
  if (value) {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.update_debug_channel),
        content: Text(t.update_debug_channel_warning),
        actions: <Widget>[
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
  await settingsContext.appModel.setUpdateDebugChannel(value);
  settingsContext.refresh();
}

Future<void> setUpdateChannel(
  SettingsContext settingsContext,
  String value,
) async {
  final bool debug = value == 'debug';
  if (debug && !settingsContext.appModel.updateDebugChannel) {
    final BuildContext context = settingsContext.context;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.update_debug_channel),
        content: Text(t.update_debug_channel_warning),
        actions: <Widget>[
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

  await settingsContext.appModel.setUpdateDebugChannel(debug);
  await settingsContext.appModel.setUpdateBetaChannel(value == 'beta' || debug);
  settingsContext.refresh();
}

Widget buildDesignSystemSelector(SettingsContext settingsContext) {
  return AdaptiveSettingsSegmentedRow<String>(
    title: t.design_system_label,
    subtitle: t.design_system_hint,
    icon: Icons.devices_outlined,
    segments: <ButtonSegment<String>>[
      ButtonSegment<String>(
        value: 'auto',
        label: Text(t.design_system_auto),
      ),
      const ButtonSegment<String>(value: 'material', label: Text('MD3')),
      const ButtonSegment<String>(value: 'cupertino', label: Text('iOS')),
    ],
    selected: settingsContext.appModel.themeNotifier.designSystem,
    onChanged: (String value) async {
      await settingsContext.appModel.themeNotifier.setDesignSystem(value);
      settingsContext.refresh();
    },
  );
}

Widget buildProfilePickerRow(SettingsContext settingsContext) {
  final ProfileUiState uiState =
      settingsContext.ref.watch(profileViewModelProvider);
  final ProfileViewModel viewModel =
      settingsContext.ref.read(profileViewModelProvider.notifier);

  if (uiState.isLoading || uiState.profiles.isEmpty) {
    return AdaptiveSettingsRow(
      title: t.profile_label,
      icon: Icons.person_outline,
      trailing: SizedBox(
        width: 20,
        height: 20,
        child: adaptiveIndicator(
          context: settingsContext.context,
          strokeWidth: 2,
        ),
      ),
    );
  }

  final int activeId = uiState.profiles.any(
    (ProfileRow profile) => profile.id == uiState.activeProfileId,
  )
      ? uiState.activeProfileId
      : uiState.profiles.first.id;

  return AdaptiveSettingsPickerRow<int>(
    title: t.profile_label,
    icon: Icons.person_outline,
    selected: activeId,
    options: <AdaptiveSettingsPickerOption<int>>[
      for (final ProfileRow profile in uiState.profiles)
        AdaptiveSettingsPickerOption<int>(
          value: profile.id,
          label: profile.name,
        ),
    ],
    onChanged: (int profileId) {
      if (profileId == activeId) return;
      unawaited(
        viewModel.switchProfile(profileId).then<void>(
              (_) => settingsContext.refresh(),
            ),
      );
    },
  );
}

Widget buildThemeSelector(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  final Color systemColor =
      appModel.systemPrimaryColor ?? const Color(0xFF1F4959);

  return AdaptiveSettingsRow(
    title: t.ttu_theme,
    icon: Icons.color_lens_outlined,
    controlBelow: true,
    trailing: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _ColorSwatch(
          color: systemColor,
          selected: appModel.appThemeKey == 'system-theme',
          overlay: Icon(
            Icons.auto_awesome_outlined,
            size: 18,
            color: _onSwatch(systemColor).withValues(alpha: 0.72),
          ),
          onTap: () async {
            await appModel.setAppThemeKey('system-theme');
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        ...AppModel.themePresets.entries.map(
          (MapEntry<String, ({Color seed, Brightness brightness})> entry) {
            return _ColorSwatch(
              color: entry.value.seed,
              selected: appModel.appThemeKey == entry.key,
              onTap: () async {
                await appModel.setAppThemeKey(entry.key);
                notifyReaderSettingsChanged(settingsContext);
              },
            );
          },
        ),
        _ColorSwatch(
          color: appModel.customThemeSeed,
          selected: appModel.appThemeKey == 'custom-theme',
          overlay: Icon(
            Icons.palette_outlined,
            size: 18,
            color: _onSwatch(appModel.customThemeSeed).withValues(alpha: 0.72),
          ),
          onTap: () async {
            await pushSettingsPage(
              settingsContext,
              (_) => const CustomThemePage(),
            );
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
      ],
    ),
  );
}

Widget buildBrightnessSelector(SettingsContext settingsContext) {
  return AdaptiveSettingsSegmentedRow<String>(
    title: t.dark_mode,
    icon: Icons.contrast_outlined,
    segments: const <ButtonSegment<String>>[
      ButtonSegment<String>(
        value: 'light',
        icon: Icon(Icons.light_mode_outlined, size: 16),
      ),
      ButtonSegment<String>(
        value: 'system',
        icon: Icon(Icons.brightness_auto_outlined, size: 16),
      ),
      ButtonSegment<String>(
        value: 'dark',
        icon: Icon(Icons.dark_mode_outlined, size: 16),
      ),
    ],
    selected: settingsContext.appModel.brightnessMode,
    onChanged: (String value) async {
      await settingsContext.appModel.setBrightnessMode(value);
      notifyReaderSettingsChanged(settingsContext);
    },
  );
}

String customFontsTitle(SettingsContext settingsContext) {
  final List<Map<String, dynamic>> fonts =
      settingsContext.readerSource.customFonts;
  final int enabledCount = fonts
      .where((Map<String, dynamic> font) => font['enabled'] as bool? ?? true)
      .length;
  return enabledCount > 0
      ? '${t.custom_fonts} ($enabledCount)'
      : t.custom_fonts;
}

Color _onSwatch(Color color) {
  return ThemeData.estimateBrightnessForColor(color) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.overlay,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _swatchSize,
        height: _swatchSize,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(
                  color: color,
                  width: 3,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: selected
            ? Icon(Icons.check, color: _onSwatch(color), size: 20)
            : overlay,
      ),
    );
  }
}
