import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show CustomThemeEntry, ThemePreset, kCustomThemeDefaultSeed;
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/theme_preset_card.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/utils/misc/screen_wakelock.dart';

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
      final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
      return FushiDialogFrame(
        maxWidth: 420,
        maxHeightFactor: 0.86,
        insetPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.card,
        ),
        scrollable: false,
        child: FushiModalSheetFrame(
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

void notifyReaderSettingsChanged(SettingsContext settingsContext) {
  ReaderFushiSource.onSettingsChangedLive?.call();
  settingsContext.refresh();
}

/// Like [notifyReaderSettingsChanged], but for structural layout keys (writing
/// mode / view mode / page columns / spread mode / spread direction /
/// prioritize reader styles) whose effect needs a full chapter reload rather
/// than a live CSS re-injection. Fires the reader's layout-reload hook so the
/// pagination engine re-runs; the CSS-only path cannot express these changes.
void notifyReaderLayoutChanged(SettingsContext settingsContext) {
  ReaderFushiSource.onLayoutReloadLive?.call();
  settingsContext.refresh();
}

/// Like [notifyReaderSettingsChanged], but for pure Flutter chrome layout keys
/// (e.g. reverse reader bottom bar) that neither re-inject CSS nor reload the
/// chapter. Fires the reader's chrome-reload hook so the underlying reader page
/// rebuilds once and re-reads the preference live, instead of only refreshing
/// the quick-settings sheet (which left the reader stale until re-entry).
void notifyReaderChromeChanged(SettingsContext settingsContext) {
  ReaderFushiSource.onChromeReloadLive?.call();
  settingsContext.refresh();
}

/// Like [notifyReaderChromeChanged], but for chrome keys whose change alters the
/// reserved chrome HEIGHT fed to the WebView (TODO-975: toggling the top
/// progress bar on/off, or flipping the top/bottom chrome between squeeze and
/// floating mode). Fires the reader's chrome-reanchor hook so the page re-reads
/// the preference, re-applies the chrome insets, AND re-anchors the continuous-
/// mode scroll position (a bare rebuild would let the reflow zero scrollY and
/// bounce to chapter start). Pure floating reveal/hide does NOT use this — only
/// the mode/visibility-of-progress switches that move the reserve do.
void notifyReaderChromeReanchored(SettingsContext settingsContext) {
  ReaderFushiSource.onChromeReanchorLive?.call();
  settingsContext.refresh();
}

/// 关掉 / 开回阅读器的顶栏和底栏（设置开关、顶栏 / 底栏 / 悬浮球上的同一颗键
/// 共用这一个写入口）。栏关掉后由应用内悬浮球接管，偏好只在球开着时生效
/// （`readerToolbarsHidden`），所以关栏时球若关着就一并打开——否则开关拨过去
/// 什么都不会发生。开回栏不动球。调用方随后要让阅读器重下 chrome 预留
/// （设置页经 [notifyReaderChromeReanchored]，阅读器内直接同步）。
Future<void> setHideReaderToolbars(AppModel appModel, bool hide) async {
  if (hide && !appModel.prefsRepo.floatingBallInApp) {
    await appModel.prefsRepo.setFloatingBallInApp(true);
  }
  await ReaderFushiSource.instance.setHideToolbars(hide);
}

Future<void> setKeepScreenAwake(
  SettingsContext settingsContext,
  bool value,
) async {
  settingsContext.readerSource.toggleKeepScreenAwake();
  await setScreenWakelock(
    enable: settingsContext.readerSource.keepScreenAwake,
    source: 'settings',
  );
  notifyReaderSettingsChanged(settingsContext);
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
  // Apple 设计系统选项和历史值不对外开放；Cupertino / macOS renderer 仅作为
  // 内部能力保留。ThemeNotifier 会在加载、刷新和写入边界把这些隐藏值归一化为 auto。
  const List<String> visibleValues = <String>['auto', 'material', 'glass'];
  final String persisted = settingsContext.appModel.themeNotifier.designSystem;
  // 分段控件要求 selected 必须落在 segments 内；这里保留防御性钳制，持久层的
  // Apple / 未知旧值已由 ThemeNotifier 迁移为 auto。
  final String selected =
      visibleValues.contains(persisted) ? persisted : 'auto';
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
        label: Text('M3E'),
        tooltip: 'Material 3 Expressive',
      ),
      ButtonSegment<String>(
        value: 'glass',
        label: Text(t.design_system_glass),
        tooltip: t.design_system_glass,
      ),
    ],
    selected: selected,
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

/// App-UI language picker. With 17 locales it crosses
/// [kSettingsPickerInlineLimit], so [AdaptiveSettingsPickerRow] renders a
/// chevron row that pushes the searchable full-page selector instead of an
/// overlay dropdown that would overflow the screen.
Widget buildLanguageSelector(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  final String current = appModel.appLocale.toLanguageTag();
  return AdaptiveSettingsPickerRow<String>(
    title: t.options_language,
    icon: Icons.translate_outlined,
    selected: current,
    options: <AdaptiveSettingsPickerOption<String>>[
      for (final MapEntry<String, String> entry
          in FushiLocalisations.localeNames.entries)
        AdaptiveSettingsPickerOption<String>(
          value: entry.key,
          label: entry.value,
        ),
    ],
    onChanged: (String tag) {
      appModel.setAppLocale(tag);
      settingsContext.refresh();
    },
  );
}

Widget buildThemeSelector(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  final Color systemColor =
      appModel.systemPrimaryColor ?? const Color(0xFF1F4959);
  final FushiDesignTokens tokens =
      FushiDesignTokens.of(settingsContext.context);
  // BUG-1894: 行尾「编辑」按钮的目标只能是**当前活跃的自定义主题**。解析一次放在
  // 这里，既给按钮的 onTap 用，也给它的 enabled 门用——两者必须读同一个值，否则
  // 又会长出「按钮亮着但没有目标」的状态。
  final String? activeCustomThemeId = appModel.activeCustomThemeEntry?.id;
  // 2026-10 M3E：预设只决定种子色、不决定明暗——所有色卡按**当前**明暗（含
  // 「纯黑深色背景」）预览，与选中后真实生效的配色同源。
  final Brightness brightness =
      appModel.isDarkMode ? Brightness.dark : Brightness.light;
  final bool pureBlack = appModel.pureBlackDark;

  return AdaptiveSettingsRow(
    title: t.reader_theme,
    // TODO-928: 提示自定义主题「点击切换 · 长按编辑」的发现性文案。
    subtitle: t.custom_theme_long_press_hint,
    icon: Icons.color_lens_outlined,
    controlBelow: true,
    trailing: Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // 跟随系统取色（Material You 动态色）。
        FushiThemePresetCard(
          key: const ValueKey<String>('theme-preset-system-theme'),
          seed: systemColor,
          scheme: buildFushiColorScheme(
            seedColor: systemColor,
            brightness: brightness,
            pureBlack: pureBlack,
          ),
          label: AppModel.themeLabel('system-theme'),
          overlay: FushiIcons.ai,
          selected: appModel.appThemeKey == 'system-theme',
          onTap: () async {
            await appModel.setAppThemeKey('system-theme');
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        // M3 经典种子预设（基线紫 + Google 经典色板 + 中性灰）。
        ...AppModel.themePresets.entries.map(
          (MapEntry<String, ThemePreset> entry) {
            return FushiThemePresetCard(
              key: ValueKey<String>('theme-preset-${entry.key}'),
              seed: entry.value.seed,
              scheme: AppModel.buildPresetColorScheme(
                entry.value,
                brightness,
                pureBlack: pureBlack,
              ),
              label: AppModel.themeLabel(entry.key),
              selected: appModel.appThemeKey == entry.key,
              onTap: () async {
                await appModel.setAppThemeKey(entry.key);
                notifyReaderSettingsChanged(settingsContext);
              },
            );
          },
        ),
        // TODO-930 M1: 每个自定义主题一张卡。单击=切换到该主题
        // （写 app_theme_key=custom-theme:<id>），长按=进编辑页编辑该主题。
        // 预览读各 entry 的种子+角色色 + 当前真实全局明暗（自定义主题跟随
        // 全局明暗，custom_theme_dark 已停写、不是真值）。
        ...appModel.customThemes.asMap().entries.map(
          (MapEntry<int, CustomThemeEntry> indexed) {
            final CustomThemeEntry e = indexed.value;
            final String key = 'custom-theme:${e.id}';
            final Color seed = e.followSystemAccent
                ? (appModel.systemPrimaryColor ?? Color(e.primaryColor ?? e.seed))
                : Color(e.primaryColor ?? e.seed);
            return FushiThemePresetCard(
              key: ValueKey<String>('theme-preset-$key'),
              seed: seed,
              scheme: appModel.themeNotifier.buildCustomThemeColorScheme(
                e,
                brightness,
              ),
              label: e.name.trim().isNotEmpty
                  ? e.name.trim()
                  : t.custom_theme_default_name(n: indexed.key + 1),
              // 选中 = 当前 app_theme_key 指向这个 entry（精确 custom-theme:<id>，
              // 或裸 custom-theme 解析到的当前活跃 entry）。
              selected: appModel.appThemeKey == key ||
                  (appModel.appThemeKey == 'custom-theme' &&
                      appModel.activeCustomThemeEntry?.id == e.id),
              onTap: () async {
                await appModel.setAppThemeKey(key);
                notifyReaderSettingsChanged(settingsContext);
              },
              onLongPress: () async {
                await pushSettingsPage(
                  settingsContext,
                  (_) => CustomThemePage(themeId: e.id),
                );
                notifyReaderSettingsChanged(settingsContext);
              },
            );
          },
        ),
        // TODO-930 M1: 末尾「+新建」卡。打开一个空草稿编辑页（种子取品牌默认色，
        // 沿用 928），用户点「应用」才写进列表。焦点/手柄用户单击（Enter / A）
        // 即可新建，无需长按。
        // BUG-1841：进编辑页前不得 upsert——否则只是点开看看也会多出一个主题。
        FushiThemePresetCard(
          key: const ValueKey<String>('theme-preset-new-custom'),
          seed: const Color(kCustomThemeDefaultSeed),
          scheme: buildFushiColorScheme(
            seedColor: const Color(kCustomThemeDefaultSeed),
            brightness: brightness,
            pureBlack: pureBlack,
          ),
          label: t.custom_theme,
          overlay: Icons.add,
          selected: false,
          onTap: () async {
            await pushSettingsPage(
              settingsContext,
              (_) => const CustomThemePage(),
            );
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        // TODO-930 M1: 焦点/手柄没有长按，故保留一个焦点可达的「编辑」按钮，编辑
        // 当前活跃的自定义主题（先切到某个自定义 swatch，再用此按钮编辑它）。
        // BUG-1894: 当前不在自定义主题上时**没有可编辑的对象**，按钮禁用。它以前
        // 回落到打开空草稿编辑页，与左邻「+」卡片逐字节等价——同一行里两个按钮做
        // 同一件事，其中挂着「编辑」图标的那个却在新建，和 tooltip 自相矛盾。修法
        // 是承认这个空状态而不是给它编个目标：enabled=false 会同时置灰图标、把
        // InkWell.onTap 置 null、并让 FushiFocusTarget(enabled: false) 把按钮摘出
        // 焦点/手柄遍历，于是新建入口唯一收敛在「+」卡片上。
        // Material 祖先：Cupertino 渲染器下没有 Material，FushiIconButton 的
        // InkWell 需要 Material 祖先；各 swatch 自带 Material，独立按钮要自己补。
        Material(
          type: MaterialType.transparency,
          child: FushiIconButton(
            icon: Icons.edit_outlined,
            tooltip: t.edit_custom_theme,
            enabled: activeCustomThemeId != null,
            constraints: BoxConstraints.tightFor(
              width: _swatchSize,
              height: _swatchSize,
            ),
            onTap: () async {
              await pushSettingsPage(
                settingsContext,
                (_) => CustomThemePage(themeId: activeCustomThemeId),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
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
        icon: const FushiIcon(Icons.light_mode_outlined, size: 16),
        tooltip: t.dark_mode_light,
      ),
      ButtonSegment<String>(
        value: 'system',
        icon: const FushiIcon(Icons.brightness_auto_outlined, size: 16),
        tooltip: t.dark_mode_system,
      ),
      ButtonSegment<String>(
        value: 'dark',
        icon: const FushiIcon(Icons.dark_mode_outlined, size: 16),
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

// TODO-374 的「界面大小」自定义滑条行（buildAppUiScaleSelector /
// _AppUiScaleSliderRow）已删除：拖动解耦语义由通用的
// SettingsSliderItem(commitOnRelease: true) 承担（settings_schema_appearance
// 的 'appearance.app_ui_scale'），消掉 commit-on-release 双实现，并顺带获得
// 常驻标题读数与搜索索引。

// HBK-AUDIT-129: removed dead `customFontsTitle`. It computed a count-aware
// title ('${t.custom_fonts} (N)') but had zero callers — the custom-fonts row
// uses `customFontsTitlePlaceholder` (settings_schema.dart). Keeping both a
// static placeholder and an unused dynamic title is a maintenance trap, so the
// disconnected dynamic helper is deleted.
