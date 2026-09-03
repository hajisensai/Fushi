import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show CustomThemeEntry, kCustomThemeDefaultSeed;
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
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
    debugPrint('[Fushi] wakelock toggle failed: $e');
  }
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
  const List<String> visibleValues = <String>['auto', 'material'];
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
        label: Text('MD3'),
        tooltip: 'Material Design 3',
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

  return AdaptiveSettingsRow(
    title: t.reader_theme,
    // TODO-928: 提示自定义主题「点击切换 · 长按编辑」的发现性文案。
    subtitle: t.custom_theme_long_press_hint,
    icon: Icons.color_lens_outlined,
    controlBelow: true,
    trailing: Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        FushiSchemeSwatch(
          colors: fushiSchemeSwatchColors(
            buildFushiColorScheme(
              seedColor: systemColor,
              brightness: Theme.of(settingsContext.context).brightness,
            ),
          ),
          size: _swatchSize,
          selected: appModel.appThemeKey == 'system-theme',
          // Size inherited from FushiSchemeSwatch's badge IconTheme (14) so the
          // icon fits the smaller inner dot; an explicit size here would override
          // it and crowd the dot.
          overlay: const Icon(Icons.auto_awesome_outlined),
          onTap: () async {
            await appModel.setAppThemeKey('system-theme');
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        ...AppModel.themePresets.entries.map(
          (MapEntry<
                  String,
                  ({
                    Color seed,
                    Brightness brightness,
                    DynamicSchemeVariant variant
                  })>
              entry) {
            return FushiSchemeSwatch(
              colors: fushiSchemeSwatchColors(
                buildFushiColorScheme(
                  seedColor: entry.value.seed,
                  brightness: entry.value.brightness,
                  variant: entry.value.variant,
                ),
              ),
              size: _swatchSize,
              selected: appModel.appThemeKey == entry.key,
              onTap: () async {
                await appModel.setAppThemeKey(entry.key);
                notifyReaderSettingsChanged(settingsContext);
              },
            );
          },
        ),
        // TODO-930 M1: 每个自定义主题一个 swatch。单击=切换到该主题
        // （写 app_theme_key=custom-theme:<id>），长按=进编辑页编辑该主题。
        // 预览圈读各 entry 的种子+角色色 + 当前真实全局明暗（自定义主题跟随
        // 全局明暗，custom_theme_dark 已停写、不是真值）。
        // TODO-1320: swatch 下不再渲染主题名 caption——系统/预设/自定义所有主题
        // 卡片统一只显示完整对角预览、无底部多余文字（选中与否都完整、且高度一致，
        // 不再因自定义带 label 而比预设高）。主题名仍可在长按/编辑按钮进入的编辑页查看修改。
        ...appModel.customThemes.map((CustomThemeEntry e) {
          final String key = 'custom-theme:${e.id}';
          return FushiSchemeSwatch(
            colors: fushiSchemeSwatchColors(
              buildFushiColorScheme(
                seedColor: Color(e.seed),
                brightness:
                    appModel.isDarkMode ? Brightness.dark : Brightness.light,
                primary: e.primaryColor != null ? Color(e.primaryColor!) : null,
                secondary:
                    e.secondaryColor != null ? Color(e.secondaryColor!) : null,
                tertiary:
                    e.tertiaryColor != null ? Color(e.tertiaryColor!) : null,
                primaryContainer:
                    e.containerColor != null ? Color(e.containerColor!) : null,
              ),
            ),
            size: _swatchSize,
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
        }),
        // TODO-930 M1: 末尾「+新建」圈。打开一个空草稿编辑页（种子取品牌默认色，
        // 沿用 928），用户点「应用」才写进列表。焦点/手柄用户单击（Enter / A）
        // 即可新建，无需长按。
        // BUG-1841：进编辑页前不得 upsert——否则只是点开看看也会多出一个主题。
        FushiSchemeSwatch(
          colors: fushiSchemeSwatchColors(
            buildFushiColorScheme(
              seedColor: const Color(kCustomThemeDefaultSeed),
              brightness:
                  appModel.isDarkMode ? Brightness.dark : Brightness.light,
            ),
          ),
          size: _swatchSize,
          selected: false,
          overlay: const Icon(Icons.add),
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
