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

Future<bool> showSettingsConfirmationDialog(
  SettingsContext settingsContext, {
  required String title,
  required String body,
  String? cancelLabel,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final BuildContext context = settingsContext.context;
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
      return HibikiDialogFrame(
        maxWidth: 420,
        maxHeightFactor: 0.86,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        scrollable: false,
        child: HibikiModalSheetFrame(
          title: title,
          scrollable: true,
          bodyPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            0,
            tokens.spacing.card,
            tokens.spacing.gap,
          ),
          footerPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.gap,
            tokens.spacing.card,
            tokens.spacing.card,
          ),
          body: Text(body, style: tokens.type.listSubtitle),
          footer: Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              adaptiveDialogAction(
                context: ctx,
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(cancelLabel ?? t.dialog_cancel),
              ),
              adaptiveDialogAction(
                context: ctx,
                isDefaultAction: true,
                isDestructiveAction: destructive,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(confirmLabel ?? t.dialog_done),
              ),
            ],
          ),
        ),
      );
    },
  );
  return confirmed == true;
}

Future<void> showSettingsProgressDialog(
  SettingsContext settingsContext, {
  required String message,
}) {
  return showAppDialog<void>(
    context: settingsContext.context,
    barrierDismissible: false,
    builder: (BuildContext ctx) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
      return PopScope(
        canPop: false,
        child: HibikiDialogFrame(
          maxWidth: 360,
          maxHeightFactor: 0.72,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          scrollable: false,
          child: HibikiModalSheetFrame(
            bodyPadding: EdgeInsets.all(tokens.spacing.card),
            body: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: adaptiveIndicator(context: ctx, strokeWidth: 2),
                ),
                SizedBox(width: tokens.spacing.gap + 4),
                Expanded(
                  child: Text(message, style: tokens.type.listSubtitle),
                ),
              ],
            ),
          ),
        ),
      );
    },
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
  if (value) {
    final bool confirmed = await showSettingsConfirmationDialog(
      settingsContext,
      title: t.update_debug_channel,
      body: t.update_debug_channel_warning,
    );
    if (!confirmed) return;
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
    final bool confirmed = await showSettingsConfirmationDialog(
      settingsContext,
      title: t.update_debug_channel,
      body: t.update_debug_channel_warning,
    );
    if (!confirmed) return;
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
        tooltip: t.design_system_auto,
      ),
      const ButtonSegment<String>(
        value: 'material',
        label: Text('MD3'),
        tooltip: 'Material Design 3',
      ),
      const ButtonSegment<String>(
        value: 'cupertino',
        label: Text('iOS'),
        tooltip: 'iOS (Cupertino)',
      ),
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
    segments: <ButtonSegment<String>>[
      ButtonSegment<String>(
        value: 'light',
        icon: const Icon(Icons.light_mode_outlined, size: 16),
        tooltip: t.dark_mode_light,
      ),
      ButtonSegment<String>(
        value: 'system',
        icon: const Icon(Icons.brightness_auto_outlined, size: 16),
        tooltip: t.dark_mode_system,
      ),
      ButtonSegment<String>(
        value: 'dark',
        icon: const Icon(Icons.dark_mode_outlined, size: 16),
        tooltip: t.dark_mode_dark,
      ),
    ],
    selected: settingsContext.appModel.brightnessMode,
    onChanged: (String value) async {
      await settingsContext.appModel.setBrightnessMode(value);
      notifyReaderSettingsChanged(settingsContext);
    },
  );
}

// HBK-AUDIT-129: removed dead `customFontsTitle`. It computed a count-aware
// title ('${t.custom_fonts} (N)') but had zero callers — the custom-fonts row
// uses `customFontsTitlePlaceholder` (settings_schema.dart). Keeping both a
// static placeholder and an unused dynamic title is a maintenance trap, so the
// disconnected dynamic helper is deleted.

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
    return HibikiFocusable(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(_swatchSize)),
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
