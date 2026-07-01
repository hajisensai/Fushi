import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/lookup/browser_extension_installer.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_fields.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_host.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildLookupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.lookup,
    title: t.settings_destination_lookup,
    summary: t.dictionary_settings,
    icon: Icons.manage_search_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.manager,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'lookup.dictionaries',
            title: t.dictionaries,
            icon: Icons.auto_stories_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const DictionaryDialogPage(),
              );
              settingsContext.refresh();
            },
          ),
          SettingsActionItem(
            id: 'lookup.custom_css',
            title: t.custom_dict_css,
            icon: Icons.code_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => const DictCssEditorDialog(),
              );
            },
          ),
          SettingsActionItem(
            id: 'lookup.audio_sources',
            title: t.manage_audio_sources,
            icon: Icons.volume_up_outlined,
            onTap: (SettingsContext settingsContext) {
              final AppModel appModel = settingsContext.appModel;
              return showSettingsDialog(
                settingsContext,
                (_) => AudioSourcesDialog(
                  sources: List<AudioSourceConfig>.from(
                    appModel.audioSourceConfigs,
                  ),
                  onSave: appModel.setAudioSourceConfigs,
                  onPickLocalDb: (bool reference) async {
                    final FilePickerResult? result =
                        await FilePicker.platform.pickFiles();
                    // 用户取消选择：result 为 null，正常无声返回（不是失败）。
                    if (result == null) return null;
                    // BUG-446：旧实现用 `result.files.single`，0/多文件时抛 StateError
                    // 被上层 `catch (_)` 吞成「导入失败」无信息文案。改为显式区分
                    // 「文件数异常」与「path 为空」，各记一条诊断日志（含文件数）。
                    final PlatformFile picked = result.files.first;
                    final String? pickedPath = picked.path;
                    if (result.files.length != 1 || pickedPath == null) {
                      ErrorLogService.instance.log(
                        'AudioSourcesDialog.pickLocalDb',
                        'unexpected file selection: count=${result.files.length}, '
                            'pathNull=${pickedPath == null}, '
                            'name=${picked.name}',
                      );
                      // path 为空（部分平台只回 bytes 不回 path）才算失败，交给上层
                      // catch 弹可见反馈；多文件但首个有 path 时仍按首个导入（容错）。
                      if (pickedPath == null) {
                        throw Exception(
                            'picked audio db has no file path (platform '
                            'returned bytes without a path)');
                      }
                    }
                    final LocalAudioDbEntry entry =
                        await appModel.importLocalAudioDbFile(
                      pickedPath,
                      displayName: picked.name,
                      reference: reference,
                    );
                    return AudioSourceConfig.localAudio(
                      label: entry.displayName,
                      path: entry.path,
                      enabled: true,
                    );
                  },
                  onEditLocalSources: (String path) async {
                    await showSettingsDialog(
                      settingsContext,
                      (_) => LocalAudioSourcesDialog(
                        dbPath: path,
                        savedPrefs: appModel.sourcePrefsForLocalDb(path),
                        listSources: () => appModel.listLocalAudioSources(path),
                        onApply: (List<LocalAudioSourcePref> prefs) =>
                            appModel.setLocalAudioDbSources(path, prefs),
                      ),
                    );
                    settingsContext.refresh();
                  },
                ),
              );
            },
          ),
          // TODO-1000：浏览器扩展「安装助手」——把随 app 打包的扩展解压到磁盘 + 引导
          // 「开发者模式 → 加载已解压 → 粘贴路径」（自建 MV3 无真·一键，浏览器封了侧载）。
          SettingsActionItem(
            id: 'lookup.install_browser_extension',
            title: t.install_browser_extension,
            icon: Icons.extension_outlined,
            onTap: (SettingsContext settingsContext) async {
              // TODO-1087：解压时注入当前 server 真值（host 固定环回，port/token 取
              // AppModel），扩展默认即连本机 app，无需用户手填 host/port/token。
              final AppModel appModel = settingsContext.appModel;
              final String dir = await prepareBundledBrowserExtension(
                serverConfig: BrowserExtensionServerConfig(
                  host: '127.0.0.1',
                  port: appModel.yomitanApiPort,
                  token: appModel.yomitanApiKey,
                ),
              );
              await Clipboard.setData(ClipboardData(text: dir));
              if (!settingsContext.context.mounted) return;
              await showSettingsDialog(
                settingsContext,
                (_) => _BrowserExtensionInstallDialog(
                  path: dir,
                  serverEnabled: appModel.yomitanApiServerEnabled,
                  hasToken: appModel.yomitanApiKey.isNotEmpty,
                ),
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_behavior,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.auto_search',
            title: t.auto_search,
            icon: Icons.manage_search_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.autoSearchEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleAutoSearchEnabled();
              settingsContext.refresh();
            },
          ),
          // TODO-861②（移植 Hoshi `07b5c09`）：扫描非日文文本。关闭后选区/查词遇非
          // 日文码点即停（不吃相邻拉丁词/数字）。默认 true = 现状，向后兼容。重进
          // 阅读器章节后注入端生效（window.scanNonJapaneseText）。
          SettingsSwitchItem(
            id: 'lookup.scan_non_japanese',
            title: t.scan_non_japanese_text,
            subtitle: t.scan_non_japanese_text_hint,
            icon: Icons.language_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.scanNonJapaneseText,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setScanNonJapaneseText(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.remote_lookup',
            title: t.remote_dict_lookup,
            subtitle: t.remote_dict_lookup_hint,
            icon: Icons.hub_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.remoteLookupEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setRemoteLookupEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.yomitan_api_server',
            title: t.yomitan_api_server,
            subtitle:
                t.yomitan_api_server_hint + t.settings_experimental_suffix,
            icon: Icons.api_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.yomitanApiServerEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setYomitanApiServerEnabled(value);
              if (value) {
                try {
                  await settingsContext.appModel.startYomitanApiServer();
                } on SyncServerPortInUseException {
                  // startYomitanApiServer 已在抛出前把开关复位为 false。
                  final BuildContext ctx = settingsContext.context;
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          t.sync_server_port_in_use(
                            port: settingsContext.appModel.yomitanApiPort,
                          ),
                        ),
                      ),
                    );
                  }
                }
              } else {
                await settingsContext.appModel.stopYomitanApiServer();
              }
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.yomitan_api_key',
            icon: Icons.key_outlined,
            builder: _buildYomitanApiKeyField,
          ),
          SettingsSwitchItem(
            id: 'lookup.texthooker',
            title: t.texthooker_enabled,
            subtitle:
                t.texthooker_enabled_hint + t.settings_experimental_suffix,
            icon: Icons.sensors_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.texthookerEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setTexthookerEnabled(value);
              if (value) {
                TexthookerWsClientHost.instance
                    .start(settingsContext.appModel.texthookerUrls);
              } else {
                await TexthookerWsClientHost.instance.stop();
              }
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.desktop_clipboard',
            title: t.desktop_clipboard_enabled,
            subtitle: t.desktop_clipboard_enabled_hint +
                t.settings_experimental_suffix,
            icon: Icons.content_paste_search,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setDesktopClipboardEnabled(value);
              if (!value) {
                await DesktopLookupService.instance.stop();
              }
              settingsContext.refresh();
            },
          ),
          SettingsSegmentedItem<DesktopClipboardWindowMode>(
            id: 'lookup.desktop_clipboard_window_mode',
            title: t.desktop_clipboard_window_mode,
            subtitle: t.desktop_clipboard_window_mode_hint,
            icon: Icons.vertical_align_top_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled,
            options: <SettingsSegmentOption<DesktopClipboardWindowMode>>[
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.normal,
                label: t.desktop_clipboard_window_mode_normal,
                tooltip: t.desktop_clipboard_window_mode_normal,
              ),
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.lookup,
                label: t.desktop_clipboard_window_mode_lookup,
                tooltip: t.desktop_clipboard_window_mode_lookup,
              ),
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.always,
                label: t.desktop_clipboard_window_mode_always,
                tooltip: t.desktop_clipboard_window_mode_always,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardWindowMode,
            onChanged: (
              SettingsContext settingsContext,
              DesktopClipboardWindowMode value,
            ) async {
              await settingsContext.appModel.setDesktopClipboardWindowMode(
                value,
              );
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.auto_read_on_lookup',
            title: t.auto_read_on_lookup,
            icon: Icons.record_voice_over_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 0,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.autoReadOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleAutoReadOnLookup();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'lookup.audio_volume',
            title: t.lookup_audio_volume,
            icon: Icons.volume_up_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 1,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.lookupAudioVolume.toDouble(),
            min: 0,
            max: 100,
            // 与有声书音量行（AudiobookVolumeRow）同款粒度契约：拖动 1% 一档
            // （0–100% 共 100 档），键盘 / 手柄左右键 5% 一步（step 与档位解
            // 耦——按键也走 1% 的话 0–100% 要按 100 下），标题带实时百分比读数。
            divisions: 100,
            step: 5,
            titleReadout: true,
            label: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource.setLookupAudioVolume(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.pause_on_lookup',
            title: t.pause_on_lookup,
            icon: Icons.pause_circle_outline,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 2,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.pauseOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource.setPauseOnLookup(value: value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-756b：“鼠标悬停即自动查词”。开启后无需按住 Shift，鼠标悬停在字幕/正文
          // 字符上即查词（与 TODO-756a 的 Shift-悬停同链路）；关闭退回 756a 的 Shift+悬停。
          // 悬停是桌面鼠标行为、移动端无 OS hover，故仅桌面显示（DesktopLookupService.isDesktop）。
          SettingsSwitchItem(
            id: 'lookup.hover_auto_lookup',
            title: t.hover_auto_lookup,
            subtitle: t.hover_auto_lookup_hint,
            icon: Icons.ads_click_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 5,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.hoverAutoLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource
                  .setHoverAutoLookup(value: value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-436/407②/716：是否允许"水平滑动关闭查词弹窗"。这是查词弹窗的手势
          // 行为，归「查词」分组（与查词朗读/暂停/音量并列），同时出现在阅读器快捷设置
          // 的查词段。开启后既驱动弹窗顶栏滑动关闭（[SwipeDismissWrapper]），也让桌面在
          // 弹窗正文区（全屏 barrier）水平拖过阈关一层（TODO-716，对齐手机手势）。
          // Windows/Linux 默认关闭（鼠标框选正文与滑动手势同形易误触），其余平台默认
          // 开启；任何平台均可用弹窗顶栏的 X 关闭。
          SettingsSwitchItem(
            id: 'reading_controls.enable_swipe_to_close',
            title: t.enable_swipe_to_close,
            icon: Icons.swipe_left_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 3,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.enableSwipeToClose,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource.setEnableSwipeToClose(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-625：滑动关闭的灵敏度阈值，与上面的"允许水平滑动关闭查词弹窗"开关
          // 配套，同属查词弹窗手势行为（ReaderGroup.lookup，紧邻开关），与开关相邻摆放。
          // id/偏好 key 沿用 'reading_controls.' 前缀作向后兼容（持久化无关展示分类）。
          SettingsSliderItem(
            id: 'reading_controls.dismiss_swipe_sensitivity',
            title: t.dismiss_swipe_sensitivity,
            icon: Icons.swipe_down_outlined,
            min: 0.1,
            max: 1,
            divisions: 9,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 4,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.dismissSwipeSensitivity,
            label: (double value) => value.toStringAsFixed(1),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource
                  .setDismissSwipeSensitivity(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsCustomItem(
            id: 'lookup.auto_search_debounce_delay',
            icon: Icons.timer_outlined,
            builder: _buildSearchDebounceField,
          ),
          SettingsCustomItem(
            id: 'lookup.maximum_terms',
            icon: Icons.format_list_numbered_outlined,
            builder: _buildMaximumTermsField,
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_display,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.collapse_dictionaries',
            title: t.collapse_dictionaries,
            icon: Icons.unfold_less_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.collapseDictionaries,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleCollapseDictionaries();
              settingsContext.refresh();
            },
          ),
          // TODO-845: how many leading dictionary blocks the popup auto-expands
          // even when "collapse dictionaries" is on. int preference surfaced
          // through a double slider; min/max (0..6) match the repository clamp.
          SettingsSliderItem(
            id: 'lookup.popup_auto_expand_dictionaries',
            title: t.popup_auto_expand_dictionaries,
            subtitle: t.popup_auto_expand_dictionaries_hint,
            icon: Icons.unfold_more_outlined,
            min: 0,
            max: 6,
            divisions: 6,
            titleReadout: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupAutoExpandDictionaries.toDouble(),
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel
                  .setPopupAutoExpandDictionaries(value.round());
              settingsContext.refresh();
            },
          ),
          // TODO-776: dictionaries-per-row grid (experimental). int preference
          // surfaced through a double slider, so value/onChanged bridge int↔double.
          SettingsSliderItem(
            id: 'lookup.popup_dictionary_columns',
            title: t.popup_dictionary_columns,
            subtitle: t.popup_dictionary_columns_hint +
                t.settings_experimental_suffix,
            icon: Icons.view_column_outlined,
            min: 1,
            max: 4,
            divisions: 3,
            titleReadout: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupDictionaryColumns.toDouble(),
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupDictionaryColumns(value.round());
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.show_expression_tags',
            title: t.show_expression_tags,
            icon: Icons.sell_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showExpressionTags,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleShowExpressionTags();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.deduplicate_pitch_accents',
            title: t.deduplicate_pitch_accents,
            icon: Icons.filter_alt_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.deduplicatePitchAccents,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleDeduplicatePitchAccents();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.harmonic_frequency',
            title: t.harmonic_frequency,
            icon: Icons.bar_chart_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.harmonicFrequency,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleHarmonicFrequency();
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.dictionary_font_size',
            icon: Icons.format_size,
            builder: _buildDictionaryFontSizeField,
          ),
          SettingsSliderItem(
            id: 'lookup.popup_max_width',
            title: t.popup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 1000,
            divisions: 75,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.popup_max_height',
            title: t.popup_max_height,
            icon: Icons.height_outlined,
            min: 200,
            max: 800,
            divisions: 60,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxHeight(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.popup_instant_scroll',
            title: t.popup_instant_scroll,
            subtitle: t.popup_instant_scroll_hint,
            icon: Icons.animation_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupInstantScroll,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPopupInstantScroll(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.popup_bottom_docked',
            title: t.popup_bottom_docked,
            subtitle: t.popup_bottom_docked_hint,
            icon: Icons.vertical_align_bottom_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupBottomDocked,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPopupBottomDocked(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

Widget _buildYomitanApiKeyField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.yomitan_api_key,
    icon: Icons.key_outlined,
    initialValue: settingsContext.appModel.yomitanApiKey,
    obscureText: true,
    keyboardType: TextInputType.visiblePassword,
    onChanged: (String value) async {
      await settingsContext.appModel.setYomitanApiKey(value);
      await _restartYomitanApiServerIfEnabled(settingsContext);
    },
  );
}

Future<void> _restartYomitanApiServerIfEnabled(
  SettingsContext settingsContext,
) async {
  if (!settingsContext.appModel.yomitanApiServerEnabled) return;
  await settingsContext.appModel.stopYomitanApiServer();
  try {
    await settingsContext.appModel.startYomitanApiServer();
  } on SyncServerPortInUseException {
    final BuildContext ctx = settingsContext.context;
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          t.sync_server_port_in_use(
            port: settingsContext.appModel.yomitanApiPort,
          ),
        ),
      ),
    );
  }
}

Widget _buildSearchDebounceField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return SettingsNumberField(
    title: t.auto_search_debounce_delay,
    icon: Icons.timer_outlined,
    suffixText: t.unit_milliseconds,
    initialValue: appModel.searchDebounceDelay.toString(),
    resetValue: appModel.defaultSearchDebounceDelay.toString(),
    onChanged: (String value) {
      int newDelay = int.tryParse(value) ?? appModel.defaultSearchDebounceDelay;
      if (newDelay.isNegative) newDelay = appModel.defaultSearchDebounceDelay;
      appModel.setSearchDebounceDelay(newDelay);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setSearchDebounceDelay(appModel.defaultSearchDebounceDelay);
      settingsContext.refresh();
    },
  );
}

Widget _buildDictionaryFontSizeField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return SettingsNumberField(
    title: t.dictionary_font_size,
    icon: Icons.format_size,
    suffixText: t.unit_pixels,
    initialValue: appModel.dictionaryFontSize.toString(),
    resetValue: appModel.defaultDictionaryFontSize.toString(),
    onChanged: (String value) {
      double newSize =
          double.tryParse(value) ?? appModel.defaultDictionaryFontSize;
      if (newSize.isNegative) newSize = appModel.defaultDictionaryFontSize;
      appModel.setDictionaryFontSize(newSize);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setDictionaryFontSize(appModel.defaultDictionaryFontSize);
      settingsContext.refresh();
    },
  );
}

Widget _buildMaximumTermsField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return SettingsNumberField(
    title: t.maximum_terms,
    icon: Icons.format_list_numbered_outlined,
    initialValue: appModel.maximumTerms.toString(),
    resetValue: appModel.defaultMaximumDictionaryTermsInResult.toString(),
    onChanged: (String value) {
      int newAmount =
          int.tryParse(value) ?? appModel.defaultMaximumDictionaryTermsInResult;
      if (newAmount.isNegative) {
        newAmount = appModel.defaultMaximumDictionaryTermsInResult;
      }
      appModel.setMaximumTerms(newAmount);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setMaximumTerms(appModel.defaultMaximumDictionaryTermsInResult);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
  );
}

/// TODO-1087：暴露安装引导弹窗给 widget 测试（验证可复制字段 + 分步渲染），
/// 不改变生产调用路径（生产仍走上面的 SettingsActionItem）。
@visibleForTesting
Widget buildBrowserExtensionInstallDialogForTest({
  required String path,
  required bool serverEnabled,
  required bool hasToken,
}) {
  return _BrowserExtensionInstallDialog(
    path: path,
    serverEnabled: serverEnabled,
    hasToken: hasToken,
  );
}

/// TODO-1000/1087：浏览器扩展安装引导弹窗。路径已在打开前解压好并复制到剪贴板，且当前
/// server 真值已注入扩展 hibiki-defaults.js（自动配置）。这里给出分步图文教程 + 可复制的
/// chrome://extensions 地址 + 可复制的扩展文件夹路径。自建 MV3 无真·一键（浏览器封侧载），
/// 故为半自动引导；但 host/port/token 已自动配置，用户无需手填。
///
/// 图位：每步用「编号圆点 + Icon + 文案」把操作可视化。真实浏览器截图（chrome://extensions
/// 页的开发者模式开关 / 加载已解压按钮）在 bg 环境无法采集，故此处用 Flutter Icon 示意；
/// 若后续要放真实截图，把资产落到 `assets/help/browser_extension/step_*.png` 并在对应步骤下
/// 用 Image.asset 渲染（下方每步已预留插图位注释）。
class _BrowserExtensionInstallDialog extends StatelessWidget {
  const _BrowserExtensionInstallDialog({
    required this.path,
    required this.serverEnabled,
    required this.hasToken,
  });

  /// 解压出的扩展目录绝对路径（供「加载已解压」时选择）。
  final String path;

  /// yomitan-api server 是否已开启（决定自动配置横幅是成功还是提醒）。
  final bool serverEnabled;

  /// 是否已设 API token（未设时连接虽通但鉴权会失败，一并提醒）。
  final bool hasToken;

  /// 一步：编号圆点 + 图标 + 正文（可含尾随可复制字段）。
  Widget _step(
    BuildContext context, {
    required int index,
    required IconData icon,
    required String text,
    Widget? trailing,
  }) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(text),
                if (trailing != null) ...<Widget>[
                  const SizedBox(height: 6),
                  trailing,
                ],
                // 图位：如需真实截图，此处 Image.asset('assets/help/browser_extension/
                // step_$index.png') 渲染对应步骤的浏览器截图（待用户后续补图）。
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 可复制字段：等宽显示 [value]，尾随复制按钮（HibikiIconButton），复制后 SnackBar 反馈。
  /// 表面走共享 HibikiCard（MD3 token 半径/配色），不自造本地 chrome。
  Widget _copyableField(BuildContext context, String value) {
    return HibikiCard(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          HibikiIconButton(
            icon: Icons.copy,
            size: 18,
            tooltip: t.copy,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t.copied)),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool autoReady = serverEnabled && hasToken;
    final Color bannerColor = autoReady
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.tertiaryContainer;
    final Color bannerFg = autoReady
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onTertiaryContainer;
    return AlertDialog(
      title: Text(t.install_browser_extension),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 自动配置状态横幅：server+token 就绪 → 成功；否则提醒先开 server。
              // 走共享 HibikiCard（token 半径），配色按就绪状态用 ColorScheme 语义角色。
              HibikiCard(
                color: bannerColor,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      autoReady ? Icons.check_circle : Icons.info_outline,
                      color: bannerFg,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        autoReady
                            ? t.browser_extension_step_done_auto
                            : t.browser_extension_enable_server_first,
                        style: TextStyle(color: bannerFg),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 步骤 1：打开扩展管理页（chrome:// 无法程序化导航，给可复制文本）。
              _step(
                context,
                index: 1,
                icon: Icons.open_in_browser_outlined,
                text: t.browser_extension_step_open_page,
                trailing: _copyableField(
                  context,
                  browserExtensionsPageUrl(BrowserKind.chrome),
                ),
              ),
              // 步骤 2：开启开发者模式。
              _step(
                context,
                index: 2,
                icon: Icons.developer_mode_outlined,
                text: t.browser_extension_step_dev_mode,
              ),
              // 步骤 3：点「加载已解压」。
              _step(
                context,
                index: 3,
                icon: Icons.drive_folder_upload_outlined,
                text: t.browser_extension_step_load_unpacked,
              ),
              // 步骤 4：选择扩展文件夹（路径已复制，可再复制）。
              _step(
                context,
                index: 4,
                icon: Icons.folder_open_outlined,
                text: t.browser_extension_step_pick_folder,
                trailing: _copyableField(context, path),
              ),
              // 步骤 5：完成，自动配置生效。
              _step(
                context,
                index: 5,
                icon: Icons.check_circle_outline,
                text: t.browser_extension_step_done_auto,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_done),
        ),
      ],
    );
  }
}
