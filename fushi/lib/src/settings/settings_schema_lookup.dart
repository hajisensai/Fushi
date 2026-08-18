import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/lookup/clipboard_panel_controller.dart';
import 'package:fushi/src/lookup/clipboard_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/port_kill_confirm.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/port_process_terminator.dart';
import 'package:fushi/src/sync/texthooker_ws_client_manager.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart'
    show kYomitanApiDefaultPort;
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;

String _yomitanApiPortInUseMessage(int port) {
  return port == kYomitanApiDefaultPort
      ? t.browser_extension_yomitan_port_conflict(port: port)
      : t.sync_server_port_in_use(port: port);
}

void _showSettingsSnackBar(SettingsContext settingsContext, String message) {
  final BuildContext ctx = settingsContext.context;
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(message)));
}

/// 端口冲突提示：说明占用者（默认端口时通常是浏览器拉起的 yomitan-api Python
/// 进程），并在支持的桌面平台附「结束进程并重试」action——直接结束占用进程后
/// 自动重试开启，免去用户去 Yomitan 高级设置绕一圈。
void _showYomitanPortConflictSnackBar(SettingsContext settingsContext) {
  final BuildContext ctx = settingsContext.context;
  if (!ctx.mounted) return;
  final int port = settingsContext.appModel.yomitanApiPort;
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(
      content: Text(_yomitanApiPortInUseMessage(port)),
      duration: const Duration(seconds: 10),
      action: PortProcessTerminator.isSupported
          ? SnackBarAction(
              label: t.yomitan_port_kill_action,
              onPressed: () => unawaited(
                _terminatePortOwnerAndRetry(settingsContext, port),
              ),
            )
          : null,
    ),
  );
}

Future<void> _terminatePortOwnerAndRetry(
  SettingsContext settingsContext,
  int port,
) async {
  final AppModel appModel = settingsContext.appModel;
  // 杀前必须确认：弹窗展示实际占用者（进程名 + PID + 路径；hibiki 旧实例
  // 特别标注），关键系统进程直接拒杀。端口是用户可配置偏好，占用者完全可能
  // 是 IDE 辅助进程/dev server，未经确认一键 taskkill 不可接受。
  final PortKillDecision decision =
      await decidePortKill(settingsContext.context, port: port);
  switch (decision.kind) {
    case PortKillDecisionKind.cancelled:
      return;
    case PortKillDecisionKind.refusedProtected:
      _showSettingsSnackBar(
        settingsContext,
        t.yomitan_port_kill_protected(
          process: describePortListener(decision.listener!),
        ),
      );
      return;
    case PortKillDecisionKind.listenerChanged:
      // 占用者换人：重走冲突提示，让用户对新占用者重新发起并确认。
      _showYomitanPortConflictSnackBar(settingsContext);
      return;
    case PortKillDecisionKind.confirmed:
      final PortListenerInfo listener = decision.listener!;
      final bool killed = await PortProcessTerminator.terminate(listener);
      if (!killed) {
        _showSettingsSnackBar(
          settingsContext,
          t.yomitan_port_kill_failed(process: describePortListener(listener)),
        );
        return;
      }
    case PortKillDecisionKind.noListener:
      break;
  }
  // 占用进程已结束（或本就已退出）：重试开启。进程退出后 OS 释放端口可能有极短
  // 延迟，端口仍占时再等一拍重试一次，仍失败按端口冲突报出。
  await appModel.setYomitanApiServerEnabled(true);
  for (int attempt = 0;; attempt++) {
    try {
      await appModel.startYomitanApiServer();
      break;
    } on SyncServerPortInUseException {
      if (attempt >= 1) {
        _showSettingsSnackBar(
          settingsContext,
          _yomitanApiPortInUseMessage(port),
        );
        settingsContext.refresh();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // startYomitanApiServer 抛出前把开关复位成 false，重试前需重新置位。
      await appModel.setYomitanApiServerEnabled(true);
    }
  }
  _showSettingsSnackBar(settingsContext, t.yomitan_api_server_started);
  settingsContext.refresh();
}

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
          // 用户词典可视化编辑器：词条真相源在偏好，保存后经现有导入链整部
          // 重建挂载（详见 user_dictionary_store.dart 库注释）。
          SettingsNavigationItem(
            id: 'lookup.user_dictionary',
            title: t.dict_user_title,
            icon: Icons.edit_note_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const UserDictionaryEditorPage(),
              );
              settingsContext.refresh();
            },
          ),
          // 「管理音频来源」抽成共享 builder：查词分类与 Hibiki 互联分类都引用同一份
          // 定义（互联音频源 fushiRemote 就在该对话框里管，故互联分类也提供入口）。
          buildManageAudioSourcesItem(),
          // 浏览器扩展「安装助手」已独立成桌面专属顶层页（BrowserExtensionPage，仅桌面
          // 出现），复杂正文（安装引导 + 连接检测 + 版本信息）不再埋在查词设置里；这里
          // 保留一条可搜索的导航项直达该页（审计 K：独立成页后设置搜索完全搜不到它）。
          SettingsNavigationItem(
            id: 'lookup.browser_extension',
            title: t.nav_browser_extension,
            icon: Icons.extension_outlined,
            showIcon: true,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const BrowserExtensionPage(),
              );
            },
          ),
        ],
      ),
      // 原「查词行为」19+ 项平铺长列表，按职责拆为四组：查词触发 / 外部集成 /
      // 剪贴板与全局查词 / 朗读与反馈。纯展示重组：item id、持久化 key、
      // onChanged、ReaderPlacement 全部不变。
      SettingsSection(
        title: t.settings_section_lookup_trigger,
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
              // galgame Hook 台词浮窗是独立 native 窗口，读不到 Dart 侧偏好：不 live
              // 推一次，用户得关掉浮窗重开才生效（阅读器 / 视频页由
              // notifyReaderSettingsChanged 覆盖，浮窗不在那条链路上）。
              await GalHookTextOverlayController.instance
                  .applyHoverAutoLookupFromPreferences();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // 一等数字项：负值经 min:0 夹取（旧散装字段把负值回退成默认值——语义
          // 收敛为「非负」，正常正值写穿完全一致）。解析失败不写（新数字项契约）。
          SettingsNumberItem(
            id: 'lookup.auto_search_debounce_delay',
            title: t.auto_search_debounce_delay,
            icon: Icons.timer_outlined,
            integer: true,
            min: 0,
            suffixText: t.unit_milliseconds,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.searchDebounceDelay,
            resetValue: (SettingsContext settingsContext) =>
                settingsContext.appModel.defaultSearchDebounceDelay,
            onChanged: (SettingsContext settingsContext, num value) {
              settingsContext.appModel.setSearchDebounceDelay(value.toInt());
              settingsContext.refresh();
            },
          ),
          SettingsNumberItem(
            id: 'lookup.maximum_terms',
            title: t.maximum_terms,
            icon: Icons.format_list_numbered_outlined,
            integer: true,
            min: 0,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.maximumTerms,
            resetValue: (SettingsContext settingsContext) =>
                settingsContext.appModel.defaultMaximumDictionaryTermsInResult,
            onChanged: (SettingsContext settingsContext, num value) {
              settingsContext.appModel.setMaximumTerms(value.toInt());
              settingsContext.appModel.clearDictionaryResultsCache();
              settingsContext.refresh();
            },
          ),
        ],
      ),
      // 原「查词显示」17 项拆两组：词条内容（词典结果怎么渲染）/ 弹窗窗口
      //（弹窗容器的尺寸与交互，含从行为区移来的滑动关闭手势对——它们改的是
      // 弹窗窗口的关闭手势，与尺寸/停靠为伍）。
      SettingsSection(
        title: t.settings_section_lookup_content,
        collapsedByDefault: true,
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
          // TODO-845: how many leading *rows* of dictionary blocks the popup
          // auto-expands even when "collapse dictionaries" is on. The unit is
          // rows so the expanded region always fills whole top rows of the
          // --dict-columns masonry (popup.js autoExpandCount = rows × effective
          // columns) instead of fighting it with a column-blind block count.
          // int preference surfaced through a double slider; min/max (0..6)
          // match the repository clamp.
          // 仅当「折叠词典显示」开启时才有意义（折叠关闭时所有词典本就展开，「自动展开
          // 前 N 本」无从谈起）；据此对齐用户预期，仅折叠开启时才显示本项。
          SettingsSliderItem(
            id: 'lookup.popup_auto_expand_dictionaries',
            title: t.popup_auto_expand_dictionaries,
            subtitle: t.popup_auto_expand_dictionaries_hint,
            icon: Icons.unfold_more_outlined,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.collapseDictionaries,
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
            // 语义收敛：列数一直是「自动填充、封顶用户值」（effective = min(用户值,
            // 视口可容)），文案随之改为「词典最多列数（自动填充）」，不改底层算法。
            title: t.popup_dictionary_max_columns,
            subtitle: t.popup_dictionary_max_columns_hint +
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
          // BUG-1026: 查词弹窗滚轮速度倍率。默认 1.0（与改前一致），0.5–5.0。倍率乘进
          // popup.js 的 wheel factor，一处存储驱动 in-app 三种弹窗 + 浏览器扩展弹窗。
          SettingsSliderItem(
            id: 'lookup.popup_wheel_speed',
            title: t.popup_wheel_speed,
            subtitle: t.popup_wheel_speed_hint,
            icon: Icons.mouse_outlined,
            min: 0.5,
            max: 5.0,
            divisions: 9,
            titleReadout: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupWheelSpeed,
            label: (double value) => '${value.toStringAsFixed(1)}×',
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupWheelSpeed(value);
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
          SettingsNumberItem(
            id: 'lookup.dictionary_font_size',
            title: t.dictionary_font_size,
            // TODO-1353: 提示 Ctrl+滚轮可在查词弹窗内直接缩放（改的就是这个词典
            // 字号，持久化）。
            subtitle: t.dictionary_font_size_zoom_hint,
            icon: Icons.format_size,
            min: 0,
            suffixText: t.unit_pixels,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.dictionaryFontSize,
            resetValue: (SettingsContext settingsContext) =>
                settingsContext.appModel.defaultDictionaryFontSize,
            onChanged: (SettingsContext settingsContext, num value) {
              settingsContext.appModel.setDictionaryFontSize(value.toDouble());
              settingsContext.refresh();
            },
          ),
        ],
      ),
      // 朗读与反馈：查中词后的语音朗读与播放暂停联动。
      SettingsSection(
        title: t.settings_section_lookup_audio,
        items: <SettingsItem>[
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
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_popup_window,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsSliderItem(
            id: 'lookup.popup_max_width',
            titleReadout: true,
            // TODO-1352: 放宽查词弹窗最大宽度的强制上限（1000→2000），让宽屏 / 4K 下
            // 弹窗能拉到接近占满（实际宽度仍由 resolvePopupRect 按当前屏宽 clamp，
            // 绝不会超出屏幕）。divisions 保持 10px 步进（1750/175）。
            title: t.popup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 2000,
            divisions: 175,
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
            titleReadout: true,
            // TODO-1352 后续：放宽最大高度上限（800→1600），配合高分屏 / 精细调整；
            // 实际高度仍由 resolvePopupRect 按当前屏高 clamp，绝不会超出屏幕。
            // 步进保持 10px（1400/140）。
            title: t.popup_max_height,
            icon: Icons.height_outlined,
            min: 200,
            max: 1600,
            divisions: 140,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxHeight(value);
              settingsContext.refresh();
            },
          ),
          // 弹窗尺寸精细化：app 外覆盖查词窗独立尺寸开关 + 仅在开启时展示的宽/高滑杆。
          // 关闭时跟随上面的 app 内最大宽高（overlayLookupEffectiveSize 解析）。
          SettingsSwitchItem(
            id: 'lookup.overlay_lookup_independent_size',
            title: t.overlay_lookup_independent_size,
            subtitle: t.overlay_lookup_independent_size_hint,
            icon: Icons.open_in_new_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.overlayLookupIndependentSize,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setOverlayLookupIndependentSize(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.overlay_lookup_max_width',
            titleReadout: true,
            title: t.overlay_lookup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 2000,
            divisions: 175,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.overlayLookupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.overlayLookupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setOverlayLookupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.overlay_lookup_max_height',
            titleReadout: true,
            title: t.overlay_lookup_max_height,
            icon: Icons.height_outlined,
            min: 200,
            max: 1600,
            divisions: 140,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.overlayLookupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.overlayLookupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setOverlayLookupMaxHeight(value);
              settingsContext.refresh();
            },
          ),
          // 弹窗尺寸精细化：浏览器扩展弹窗独立尺寸开关 + 仅在开启时展示的宽/高滑杆。
          // 关闭时跟随 app 内最大宽高（extensionPopupEffectiveSize 解析，经 theme 下发）。
          SettingsSwitchItem(
            id: 'lookup.extension_popup_independent_size',
            title: t.extension_popup_independent_size,
            subtitle: t.extension_popup_independent_size_hint,
            icon: Icons.extension_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.extensionPopupIndependentSize,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setExtensionPopupIndependentSize(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.extension_popup_max_width',
            titleReadout: true,
            title: t.extension_popup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 2000,
            divisions: 175,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.extensionPopupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.extensionPopupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setExtensionPopupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.extension_popup_max_height',
            titleReadout: true,
            title: t.extension_popup_max_height,
            icon: Icons.height_outlined,
            min: 200,
            max: 1600,
            divisions: 140,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.extensionPopupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.extensionPopupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setExtensionPopupMaxHeight(value);
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
          // TODO-436/407②/716：是否允许"水平滑动关闭查词弹窗"。这是查词弹窗窗口的
          // 关闭手势，与弹窗尺寸/停靠同组；同时经 ReaderPlacement 出现在阅读器快捷
          // 设置的查词段。开启后既驱动弹窗顶栏滑动关闭（[SwipeDismissWrapper]），也让
          // 桌面在弹窗正文区（全屏 barrier）水平拖过阈关一层（TODO-716，对齐手机手势）。
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
        ],
      ),
      // 剪贴板与全局查词：桌面剪贴板监听全家桶（总开关 + 去向/窗口模式/不透明度）
      // 和 app 外全局查词的上下文抓取，仅桌面平台可见的一整条链路。
      SettingsSection(
        title: t.settings_section_lookup_clipboard,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.desktop_clipboard',
            title: t.desktop_clipboard_enabled,
            // 文案统一（阶段 F）：平台标记 + 实验性合并为单个括注
            // （桌面·实验性）已并入 desktop_clipboard_enabled_hint 值本身，
            // 不再叠加共享的 settings_experimental_suffix（否则出现双重括注）。
            subtitle: t.desktop_clipboard_enabled_hint,
            icon: Icons.content_paste_search,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              // spec 2026-07-10 §7：setter 内部经 applyDesktopClipboardLifecycle
              // 幂等 start/stop，此处不再直接操作服务。
              await settingsContext.appModel.setDesktopClipboardEnabled(value);
              // 默认去向=panel（用户拍板）：开总开关时若去向是面板则补预热
              // （启动预热要求「开关开 且 去向 panel」双条件）；关总开关时收起
              // 面板（服务已停，面板不该留着最后一句挂在屏上）。
              if (ClipboardPanelController.isSupported) {
                if (value &&
                    settingsContext.appModel.desktopClipboardDestination ==
                        DesktopClipboardDestination.panel) {
                  unawaited(
                      ClipboardPanelController.instance.ensurePrewarmed());
                } else if (!value) {
                  await ClipboardPanelController.instance.hidePanel();
                }
              }
              settingsContext.refresh();
            },
          ),
          // 复制后是否自动查词。关掉后剪贴板面板/查词只显示复制到的文字，点词才查
          // （见 ClipboardPanelController 纯文字态）。仅桌面 + 剪贴板总开关开时可见。
          SettingsSwitchItem(
            id: 'lookup.desktop_clipboard_auto_lookup',
            title: t.desktop_clipboard_auto_lookup,
            subtitle: t.desktop_clipboard_auto_lookup_hint,
            icon: Icons.search_off_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardAutoLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setDesktopClipboardAutoLookup(value);
              settingsContext.refresh();
            },
          ),
          SettingsSegmentedItem<DesktopClipboardWindowMode>(
            id: 'lookup.desktop_clipboard_window_mode',
            title: t.desktop_clipboard_window_mode,
            // 副标题保留：spec 2026-07-10 §7 守卫要求 hint 描述置顶行为、且旧的
            // 「仅在查词页监听」措辞不得复活（desktop_lookup_to_dictionary_tab_test）。
            subtitle: t.desktop_clipboard_window_mode_hint,
            icon: Icons.vertical_align_top_outlined,
            // spec 2026-07-10：本项管的是主窗置顶策略，仅 destination==main 时
            // 有意义（面板/瞬态去向不经主窗显示结果）。
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled &&
                settingsContext.appModel.desktopClipboardDestination ==
                    DesktopClipboardDestination.main,
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
          // spec 2026-07-10 §4/§7 — 剪贴板查词去向三选。main = 主窗查词 tab
          // （现状默认）；transient = 光标处瞬态弹卡（复用全局查词覆盖窗）；
          // panel = 常驻悬浮面板（M2 落地后加入选项）。覆盖窗是 Windows-only
          // （GlobalLookupController.isSupported），其余桌面平台不显示本项、
          // 隐含恒为 main。
          SettingsSegmentedItem<DesktopClipboardDestination>(
            id: 'lookup.desktop_clipboard_destination',
            title: t.desktop_clipboard_destination,
            icon: Icons.picture_in_picture_alt_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled &&
                GlobalLookupController.isSupported,
            options: <SettingsSegmentOption<DesktopClipboardDestination>>[
              SettingsSegmentOption<DesktopClipboardDestination>(
                value: DesktopClipboardDestination.main,
                label: t.desktop_clipboard_destination_main,
                tooltip: t.desktop_clipboard_destination_main,
              ),
              SettingsSegmentOption<DesktopClipboardDestination>(
                value: DesktopClipboardDestination.panel,
                label: t.desktop_clipboard_destination_panel,
                tooltip: t.desktop_clipboard_destination_panel,
              ),
              SettingsSegmentOption<DesktopClipboardDestination>(
                value: DesktopClipboardDestination.transient,
                label: t.desktop_clipboard_destination_transient,
                tooltip: t.desktop_clipboard_destination_transient,
              ),
              SettingsSegmentOption<DesktopClipboardDestination>(
                value: DesktopClipboardDestination.textWindow,
                label: t.desktop_clipboard_destination_text_window,
                tooltip: t.desktop_clipboard_destination_text_window,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardDestination,
            onChanged: (
              SettingsContext settingsContext,
              DesktopClipboardDestination value,
            ) async {
              await settingsContext.appModel
                  .setDesktopClipboardDestination(value);
              // 去向切走时收起面板（不留孤儿常驻窗）；切到面板时补预热（启动预热仅
              // destination==panel 时做——默认 main 不常驻第二 WebView2）。BUG-717：
              // 面板不再有 × 暂停态，切回面板无需「解除暂停」，下一条剪贴板自然重开。
              if (ClipboardPanelController.isSupported) {
                if (value == DesktopClipboardDestination.panel) {
                  unawaited(
                      ClipboardPanelController.instance.ensurePrewarmed());
                } else {
                  await ClipboardPanelController.instance.hidePanel();
                }
              }
              // 切走透明文字窗去向时收起它（不留孤儿透明窗）；透明窗无需预热，
              // native 窗到首个 textWindow 分区请求才创建。
              if (ClipboardTextOverlayController.isSupported &&
                  value != DesktopClipboardDestination.textWindow) {
                await ClipboardTextOverlayController.instance.hide();
              }
              settingsContext.refresh();
            },
          ),
          // spec 2026-07-10 §6 真机修正 — 面板整窗不透明度（LWA_ALPHA 真透视，
          // Win10/11 通用），destination==panel 即显示（原 acrylic backdropOk
          // 门控随路线废弃删除）。
          SettingsSliderItem(
            id: 'lookup.clipboard_panel_opacity',
            title: t.clipboard_panel_opacity,
            subtitle: t.clipboard_panel_opacity_hint,
            icon: Icons.opacity_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled &&
                settingsContext.appModel.desktopClipboardDestination ==
                    DesktopClipboardDestination.panel,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.clipboardPanelOpacity * 100,
            min: 50,
            max: 100,
            divisions: 50,
            step: 5,
            titleReadout: true,
            label: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setClipboardPanelOpacity(value / 100);
              await ClipboardPanelController.instance.refreshOpacity();
            },
          ),
          // 真透明剪切板文字窗的背景不透明度（destination==textWindow 时显示）。
          // 默认 0% = 完全透明背景只露实心文字（用户诉求）；亮色游戏上白字看不清
          // 时上抬垫一层暗底。与面板整窗 LWA_ALPHA 不同，这里只压背景 alpha。
          SettingsSliderItem(
            id: 'lookup.clipboard_text_window_bg_opacity',
            title: t.clipboard_text_window_bg_opacity,
            subtitle: t.clipboard_text_window_bg_opacity_hint,
            icon: Icons.gradient_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled &&
                settingsContext.appModel.desktopClipboardDestination ==
                    DesktopClipboardDestination.textWindow,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.clipboardTextWindowBgOpacity * 100,
            min: 0,
            max: 100,
            divisions: 20,
            step: 5,
            titleReadout: true,
            label: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setClipboardTextWindowBgOpacity(value / 100);
              await ClipboardTextOverlayController.instance.refreshStyle();
            },
          ),
          // TODO-1030 M0：全局查词（应用外）抓取选中文本周围上下文句。开启后按热键
          // 查词时，除选中词外还经 UI Automation 读取前台应用选区前后各约 600 字，裁出
          // 当前句在弹窗展示（Yomitan {sentence} 风格）。隐私敏感——读前台应用文本，
          // 默认关闭；关闭时只用剪贴板拿到的纯选中串（现状）。UIA 是 Windows 平台能力，
          // 故仅桌面（DesktopLookupService.isDesktop）显示。
          SettingsSwitchItem(
            id: 'lookup.global_context_capture',
            title: t.global_context_capture,
            subtitle: t.global_context_capture_hint,
            icon: Icons.short_text_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.globalContextCaptureEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setGlobalContextCaptureEnabled(value);
              settingsContext.refresh();
            },
          ),
          // 防截屏（用户诉求）：桌面查词/剪贴板悬浮窗经 native
          // SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) 从截图/录屏/串流中
          // 排除。默认关（用户要求，2026-07）。仅 Windows——display affinity 是 Win32 能力。
          // 与面板栏 🛡 按钮同一 pref、同一 native 通道（ClipboardPanelController
          // .applyBlockCapture → OverlayWindowChannel.setBlockCapture），改设置即时
          // 重应用，不新起并行机制。applyBlockCapture 是唯一扇出入口：面板窗 +
          // 瞬态全局查词窗（GlobalLookupController.applyBlockCapture）一起保护。
          SettingsSwitchItem(
            id: 'lookup.block_capture',
            title: t.clipboard_panel_block_capture,
            subtitle: t.clipboard_panel_block_capture_hint,
            icon: Icons.shield_outlined,
            visible: (SettingsContext settingsContext) =>
                ClipboardPanelController.isSupported,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.clipboardPanelBlockCapture,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setClipboardPanelBlockCapture(value);
              // 即时重应用到已打开的面板窗（同 🛡 按钮路径）。
              if (ClipboardPanelController.isSupported) {
                await ClipboardPanelController.instance
                    .applyBlockCapture(value);
              }
              settingsContext.refresh();
            },
          ),
        ],
      ),
      // 外部集成：远程查词 / Yomitan API / texthooker——都是「让别的程序或设备
      // 参与查词」的接线项，与本机查词触发行为分开。
      SettingsSection(
        title: t.settings_section_lookup_integrations,
        items: <SettingsItem>[
          // 远端词典查询抽成共享 builder：查词分类与 Hibiki 互联分类都引用（它直连
          // 互联对端的词典，逻辑上属互联，故互联分类也提供入口）。
          buildRemoteDictionaryLookupItem(),
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
                  _showYomitanPortConflictSnackBar(settingsContext);
                }
              } else {
                await settingsContext.appModel.stopYomitanApiServer();
              }
              settingsContext.refresh();
            },
          ),
          // 一等文本项（secret）：行尾自动获得眼睛显隐切换。写穿后重启 Yomitan
          // API 服务（若已开启）。
          SettingsTextItem(
            id: 'lookup.yomitan_api_key',
            title: t.yomitan_api_key,
            icon: Icons.key_outlined,
            secret: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.yomitanApiKey,
            onChanged: (SettingsContext settingsContext, String value) async {
              await settingsContext.appModel.setYomitanApiKey(value);
              await _restartYomitanApiServerIfEnabled(settingsContext);
            },
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
                TexthookerWsClientManager.instance
                    .start(settingsContext.appModel.texthookerUrls);
              } else {
                await TexthookerWsClientManager.instance.stop();
              }
              settingsContext.refresh();
            },
          ),
          // 窗口超分**故意不在这里**（BUG-1191）。它是每局游戏才有意义的东西，藏在
          // 「设置 → 查词」里既不好找，也逼着还没启动过任何游戏的用户去决定一个看不见
          // 效果的开关。现在改成第一次真要超分的那一刻当场问
          // （`magpie_upscaling_prompt.dart`），事后在捕获工作台「更多」菜单里改。
          // 加回设置项前请先想清楚它凭什么值得占一个全局条目。
        ],
      ),
      // BUG-1095: galgame Hook 台词浮窗此前在设置页**一条条目都没有**——字号只能靠
      // 「把窗口拖高」这个副作用去改，而 native 同时按窗高把字放大，可见行数几乎不涨
      // （「放不下，上下拖还是放不下」）。字号现在是与窗口几何完全解耦的独立偏好，这里
      // 是它唯一的入口。挂在查词分类：浮窗对用户就是「显示台词 + 点词查词」的那块面板，
      // 紧邻上面的 texthooker（台词的来源）。仅 Windows——galgame Hook 只做 Windows。
      SettingsSection(
        title: t.settings_section_gal_hook_overlay,
        visible: (_) => Platform.isWindows,
        items: <SettingsItem>[
          SettingsStepperItem(
            id: 'lookup.gal_hook_text_font_size',
            title: t.gal_hook_text_font_size,
            subtitle: t.gal_hook_text_font_size_hint,
            icon: Icons.format_size,
            visible: (_) => Platform.isWindows,
            min: PreferencesRepository.galHookTextFontSizeMin,
            max: PreferencesRepository.galHookTextFontSizeMax,
            step: 1,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextFontSize,
            format: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setGalHookTextFontSize(value);
              // 与悬浮字幕字号同款纪律（TODO-1069）：写完 pref 立刻把整支 style 推给
              // native 浮窗，否则字号只落了盘，浮窗要等下次改透明度才顺带刷新。
              await GalHookTextOverlayController.instance
                  .applyFontSizeFromPreferences();
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

/// 「管理音频来源」配置项。查词分类与 Hibiki 互联分类共享同一份定义（单一真相源）：
/// 音频来源对话框统管远端(含互联 fushiRemote)/本地音频源，逻辑上与互联相关，故两处
/// 都用同一入口。id 沿用 `lookup.` 前缀（历史命名，非持久化 key，两处同 id 无冲突——
/// 覆盖遍历按 `<destId>/<title>` 去重，action 型行不产生持久化断言）。
SettingsItem buildManageAudioSourcesItem() {
  return SettingsActionItem(
    id: 'lookup.audio_sources',
    title: t.manage_audio_sources,
    icon: Icons.volume_up_outlined,
    onTap: (SettingsContext settingsContext) {
      return showAudioSourcesManagerDialog(
        context: settingsContext.context,
        appModel: settingsContext.appModel,
        onLocalSourcesEdited: settingsContext.refresh,
      );
    },
  );
}

/// 打开「管理音频来源」对话框的共享编排入口：设置项（查词/互联两分类）与新手引导
/// 共用同一份实现（单一真相源）。不依赖 [SettingsContext]，任何持有 [BuildContext]
/// 的调用点都能用；[onLocalSourcesEdited] 在「编辑本地子来源」对话框关闭后回调
/// （设置页用它触发 schema 刷新，向导不需要可不传）。
Future<void> showAudioSourcesManagerDialog({
  required BuildContext context,
  required AppModel appModel,
  VoidCallback? onLocalSourcesEdited,
}) {
  return showAppDialog(
    context: context,
    builder: (_) => AudioSourcesDialog(
      sources: List<AudioSourceConfig>.from(
        appModel.audioSourceConfigs,
      ),
      // 本地音频源是跨设备同步的共享池（__local_audio__）：移除一个源默认传播删除
      // （syncEverywhere），接收设备仍会逐条确认后才删本地，用户控制在接收端保留。
      // 列表编辑式 UX 无单条删除确认时机，故不在源端逐条弹选择。
      onSave: (List<AudioSourceConfig> next) => appModel
          .setAudioSourceConfigs(next, scope: DeleteScope.syncEverywhere),
      onPickLocalDb: (bool reference) async {
        // BUG-1667：本地音频库曾是全 app 唯一还在用裸 `FilePicker.pickFiles()`
        // 的大文件导入入口，偏偏承载体积最大的文件（Yomitan 本地音频服务器的
        // android.db 常见 1~6 GB）。安卓上 file_picker 会先把整份文件同步复制进
        // app cache 再返回缓存路径，随后 `importFile` 又复制一份进库目录 →
        // 峰值需要 **2 倍库体积的内部存储**，6 GB 的库要 12 GB，且全程只有一个
        // 转圈、无进度无取消，多数手机直接失败或看起来永久卡死 = 「安卓上用
        // android.db 配本地音频怎么都跑不通」。视频/书/有声书/漫画/字幕/制卡音频
        // 早已统一走 [pickRealFilePathDetailed]（安卓 SAF 解析真实路径、零复制），
        // 这条是最后的漏网。
        final PickedFilePath? picked;
        try {
          picked = await pickRealFilePathDetailed(
            context: context,
            appModel: appModel,
          );
        } on PickedFileWithoutPathException catch (e) {
          // BUG-446：平台交回了条目却没给可用 path（只回 bytes）**不是取消**，
          // 是失败。记完整诊断（含条目数）后显式抛出，交给上层弹可见反馈——
          // 静默返回会让用户以为自己没选中，真因全丢。
          ErrorLogService.instance.log(
            'AudioSourcesDialog.pickLocalDb',
            'unexpected file selection: count=${e.count}, pathNull=true',
          );
          throw Exception('picked audio db has no file path (platform '
              'returned bytes without a path)');
        }
        // 用户取消选择：返回 null，正常无声返回（不是失败）。
        if (picked == null) return null;
        // 引用只在**事实上拿到用户真实路径**时才成立（BUG-1667）。安卓未授予
        // 全文件访问时降级回 file_picker，拿到的是 app cache 临时副本——引用它
        // 等于引用一个清缓存就消失的文件，必须落回复制，并告诉用户为什么。
        final bool canReference = picked.isRealPath;
        if (reference && !canReference && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.local_audio_reference_unavailable)),
          );
        }
        final LocalAudioDbEntry entry = await appModel.importLocalAudioDbFile(
          picked.path,
          displayName: p.basename(picked.path),
          reference: reference && canReference,
        );
        return AudioSourceConfig.localAudio(
          label: entry.displayName,
          path: entry.path,
          enabled: true,
        );
      },
      onEditLocalSources: (String path) async {
        await showAppDialog(
          context: context,
          builder: (_) => LocalAudioSourcesDialog(
            dbPath: path,
            savedPrefs: appModel.sourcePrefsForLocalDb(path),
            listSources: () => appModel.listLocalAudioSources(path),
            onApply: (List<LocalAudioSourcePref> prefs) =>
                appModel.setLocalAudioDbSources(path, prefs),
          ),
        );
        onLocalSourcesEdited?.call();
      },
    ),
  );
}

/// 远端词典查询开关。查词分类与 Hibiki 互联分类共享同一份定义：本地查不到时向已配置
/// 的 Hibiki 互联对端查询，逻辑上属互联。id 沿用 `lookup.` 前缀（非持久化 key）。
SettingsItem buildRemoteDictionaryLookupItem() {
  return SettingsSwitchItem(
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
    _showYomitanPortConflictSnackBar(settingsContext);
  }
}
