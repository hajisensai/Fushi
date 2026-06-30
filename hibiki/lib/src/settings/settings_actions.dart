import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/theme_notifier.dart'
    show ThemeNotifier, CustomThemeEntry, kCustomThemeDefaultSeed;
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
        insetPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.card,
        ),
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
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
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

/// Like [notifyReaderSettingsChanged], but for structural layout keys (writing
/// mode / view mode / page columns / spread mode / spread direction /
/// prioritize reader styles) whose effect needs a full chapter reload rather
/// than a live CSS re-injection. Fires the reader's layout-reload hook so the
/// pagination engine re-runs; the CSS-only path cannot express these changes.
void notifyReaderLayoutChanged(SettingsContext settingsContext) {
  ReaderHibikiSource.onLayoutReloadLive?.call();
  settingsContext.refresh();
}

/// Like [notifyReaderSettingsChanged], but for pure Flutter chrome layout keys
/// (e.g. reverse reader bottom bar) that neither re-inject CSS nor reload the
/// chapter. Fires the reader's chrome-reload hook so the underlying reader page
/// rebuilds once and re-reads the preference live, instead of only refreshing
/// the quick-settings sheet (which left the reader stale until re-entry).
void notifyReaderChromeChanged(SettingsContext settingsContext) {
  ReaderHibikiSource.onChromeReloadLive?.call();
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
  ReaderHibikiSource.onChromeReanchorLive?.call();
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
  // iOS (Cupertino) 设计系统暂时不对外开放（后续推出再把分段加回来）。这里只隐藏
  // 选择入口，底层能力（themeNotifier 持久化 / cupertino renderer / auto 在真
  // iOS 机上仍走 Cupertino）保持不变，恢复时把 cupertino 分段加回即可。
  const List<String> visibleValues = <String>['auto', 'material'];
  final String persisted = settingsContext.appModel.themeNotifier.designSystem;
  // 历史上可能已持久化 'cupertino'，而分段控件要求 selected 必须落在 segments
  // 内否则断言崩溃——钳到 'auto' 仅用于显示，不改写持久值。
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
          in HibikiLocalisations.localeNames.entries)
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

/// TODO-930: a custom theme entry's display name. The name is optional
/// (decision 3); an empty name falls back to the localized default
/// `Custom N`, where N is the entry's 1-based position in the list. Pure so
/// both the swatch row and the editor hint can share one source of truth.
String customThemeDisplayName(AppModel appModel, CustomThemeEntry entry) {
  if (entry.name.trim().isNotEmpty) return entry.name;
  final int index = appModel.customThemes.indexWhere(
    (CustomThemeEntry e) => e.id == entry.id,
  );
  final int position =
      index >= 0 ? index + 1 : appModel.customThemes.length + 1;
  return t.custom_theme_default_name(n: position);
}

/// TODO-930: the default seed for a brand-new custom theme. Sticks with the
/// 928 brand-teal default (the new theme then follows the current global
/// brightness, decision 6); kept as a helper so the swatch row and editor agree.
Color blankCustomThemeSeed() => const Color(kCustomThemeDefaultSeed);

/// TODO-930: create + persist a brand-new empty custom theme and return it.
/// upsert adds it to the list and selects it; the caller then pushes the editor
/// for `entry.id`. The seed defaults to [blankCustomThemeSeed]; name is empty so
/// the UI shows the `Custom N` default until the user types one.
Future<CustomThemeEntry> createBlankCustomTheme(AppModel appModel) async {
  final CustomThemeEntry entry = CustomThemeEntry(
    id: 'ct-${DateTime.now().microsecondsSinceEpoch}',
    name: '',
    seed: blankCustomThemeSeed().toARGB32(),
  );
  await appModel.upsertCustomTheme(entry);
  return entry;
}

Widget buildThemeSelector(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  final Color systemColor =
      appModel.systemPrimaryColor ?? const Color(0xFF1F4959);
  final HibikiDesignTokens tokens =
      HibikiDesignTokens.of(settingsContext.context);

  return AdaptiveSettingsRow(
    title: t.ttu_theme,
    // TODO-928: 提示自定义主题「点击切换 · 长按编辑」的发现性文案。
    subtitle: t.custom_theme_long_press_hint,
    icon: Icons.color_lens_outlined,
    controlBelow: true,
    trailing: Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        HibikiSchemeSwatch(
          colors: hibikiSchemeSwatchColors(
            buildHibikiColorScheme(
              seedColor: systemColor,
              brightness: Theme.of(settingsContext.context).brightness,
            ),
          ),
          size: _swatchSize,
          selected: appModel.appThemeKey == 'system-theme',
          // Size inherited from HibikiSchemeSwatch's badge IconTheme (14) so the
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
            return HibikiSchemeSwatch(
              colors: hibikiSchemeSwatchColors(
                buildHibikiColorScheme(
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
        ...appModel.customThemes.map((CustomThemeEntry e) {
          final String key = 'custom-theme:${e.id}';
          return HibikiSchemeSwatch(
            colors: hibikiSchemeSwatchColors(
              buildHibikiColorScheme(
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
            label: customThemeDisplayName(appModel, e),
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
        // TODO-930 M1: 末尾「+新建」圈。新建一个空 entry（种子取当前全局明暗对应
        // 的品牌默认色，沿用 928），upsert 后进编辑页编辑它。焦点/手柄用户单击
        // （Enter / A）即可新建，无需长按。
        HibikiSchemeSwatch(
          colors: hibikiSchemeSwatchColors(
            buildHibikiColorScheme(
              seedColor: const Color(kCustomThemeDefaultSeed),
              brightness:
                  appModel.isDarkMode ? Brightness.dark : Brightness.light,
            ),
          ),
          size: _swatchSize,
          selected: false,
          overlay: const Icon(Icons.add),
          onTap: () async {
            final CustomThemeEntry created = await createBlankCustomTheme(
              appModel,
            );
            await pushSettingsPage(
              settingsContext,
              (_) => CustomThemePage(themeId: created.id),
            );
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        // TODO-930 M1: 焦点/手柄没有长按，故保留一个焦点可达的「编辑」按钮，编辑
        // 当前活跃的自定义主题（先切到某个自定义 swatch，再用此按钮编辑它）。
        // 列表为空时无活跃 entry，按钮新建一个再编辑。
        // Material 祖先：Cupertino 渲染器下没有 Material，HibikiIconButton 的
        // InkWell 需要 Material 祖先；各 swatch 自带 Material，独立按钮要自己补。
        Material(
          type: MaterialType.transparency,
          child: HibikiIconButton(
            icon: Icons.edit_outlined,
            tooltip: t.edit_custom_theme,
            constraints: BoxConstraints.tightFor(
              width: _swatchSize,
              height: _swatchSize,
            ),
            onTap: () async {
              final CustomThemeEntry? active = appModel.activeCustomThemeEntry;
              final String themeId =
                  active?.id ?? (await createBlankCustomTheme(appModel)).id;
              await pushSettingsPage(
                settingsContext,
                (_) => CustomThemePage(themeId: themeId),
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

/// 「界面大小」设置项。
///
/// TODO-374: 删除「自动/自定义」模式切换。界面大小不再有模式概念——首次启动时
/// [ThemeNotifier.resolveAppUiScaleForViewport] 已按屏幕算出合适值落盘成具体百分比，
/// 之后用户始终面对一个可拖的具体数值。因此这里恒渲染可拖滑条（[_AppUiScaleSliderRow]），
/// 不再有内联分段切换、不再有「自动模式只读展示」分支。
Widget buildAppUiScaleSelector(SettingsContext settingsContext) {
  return _AppUiScaleSliderRow(appModel: settingsContext.appModel);
}

/// 「界面大小」滑条行。
///
/// 该滑条位于受 [HibikiAppUiScale] 的 [Transform.scale] 缩放的子树内（`main.dart`
/// 用 `appModel.appUiScale` 驱动整树缩放）。若拖动每帧都提交真实缩放，整棵树会立刻
/// 按新比例重排，滑块在手指下被缩放位移，拖动手势随即丢失目标——表现为「改一下就
/// 断、无法连续拖」。
///
/// 因此把拖动中的临时值 [_dragValue] 放在与拖动 UI 同生命周期的本 [State] 里：拖动
/// 中只更新本地值跟手、不碰全局缩放；松手 `onChangeEnd` 才一次性提交。面板销毁时本
/// State 一并消失，未提交的临时值不会泄漏到全局单例，所有布局下都不会有显示残留。
class _AppUiScaleSliderRow extends StatefulWidget {
  const _AppUiScaleSliderRow({required this.appModel});

  final AppModel appModel;

  @override
  State<_AppUiScaleSliderRow> createState() => _AppUiScaleSliderRowState();
}

class _AppUiScaleSliderRowState extends State<_AppUiScaleSliderRow> {
  /// 拖动进行中的临时值；非拖动时为 null，显示已提交的 [AppModel.appUiScale]。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = widget.appModel;
    final double value = (_dragValue ?? appModel.appUiScale)
        .clamp(
          HibikiAppUiScale.minScale,
          HibikiAppUiScale.maxScale,
        )
        .toDouble();
    return AdaptiveSettingsSliderRow(
      title: t.app_ui_scale,
      subtitle: t.app_ui_scale_hint,
      icon: Icons.format_size_outlined,
      min: HibikiAppUiScale.minScale,
      max: HibikiAppUiScale.maxScale,
      divisions: 27,
      value: value,
      label: '${(value * 100).round()}%',
      // 拖动中只更新本地值跟手，不触发全局 Transform 重排（滑条稳定可连续拖）。
      onChanged: (double next) => setState(() => _dragValue = next),
      // 松手一次性提交真实缩放并清空本地拖动值，全局界面随之缩放。
      onChangeEnd: (double next) async {
        await appModel.setAppUiScale(next);
        if (mounted) setState(() => _dragValue = null);
      },
    );
  }
}

// HBK-AUDIT-129: removed dead `customFontsTitle`. It computed a count-aware
// title ('${t.custom_fonts} (N)') but had zero callers — the custom-fonts row
// uses `customFontsTitlePlaceholder` (settings_schema.dart). Keeping both a
// static placeholder and an unused dynamic title is a maintenance trap, so the
// disconnected dynamic helper is deleted.
