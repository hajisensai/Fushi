import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/audiobook/audiobook_jump_threshold.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_library_dialog.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_style.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/overlay_color_setting_item.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 「听书」的两个设置分区（有声书 + 悬浮歌词）。
///
/// 2026-08-24 用户决策：不再作为独立一级分类，由 [buildReadingDestination] 展开进
/// 「阅读」末尾。同一本 EPUB 的「读」与「听」原本被拆在两个一级分类里，用户得在两
/// 处找同一本书的设置；而听书统共十来项、其中大半还是悬浮歌词一个子功能，撑不起
/// 一个一级分类。
///
/// 合并只动**归属**：item id（`listening.*`）、持久化 key、各项的 visible 门控全部
/// 原样保留；`SettingsDestinationId.listening` 随之删除——它没有任何持久化用途
/// （只做内存态选中项身份）。
///
/// 「功能模块」门控原先挂在 destination 上（关掉听书模块 = 整条分类不渲染 / 不进
/// 搜索索引）。并类之后没有 destination 可挂了，**门控下放到这两个分区自己身上**，
/// 否则关掉模块的用户会在「阅读」里重新看到听书设置——那是并类顺手放开了一道门。
///
/// 保持独立 library 而不是把这 300 行搬进已很长的 settings_schema_reading.dart：
/// 领域文件边界不变，settings_redesign_static_test 的「一域一文件」契约照旧成立。
List<SettingsSection> buildListeningSections() {
  bool listeningModuleOn(SettingsContext c) =>
      c.appModel.moduleVisibility.isEnabledOrUngated(ModuleId.listening);
  return <SettingsSection>[
    SettingsSection(
      // 模块门原先挂在 destination 上，并入阅读后下放到分区自己身上。
      visible: listeningModuleOn,
      id: 'listening.section.playback',
      presentation: SettingsSectionPresentation.alwaysExpanded,
      title: t.section_audiobook,
      items: <SettingsItem>[
        // TODO-702：有声书退出即停（默认 OFF）/ 后台续播（开启）。默认关 = 退出
        // 阅读页就停止有声书播放；开启后退书后会话继续在后台播。
        SettingsSwitchItem(
          id: 'listening.audiobook_background_play',
          title: t.audiobook_background_play,
          subtitle: t.audiobook_background_play_hint,
          icon: FushiIcons.playCircle,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.audiobookBackgroundPlay,
          onChanged: (SettingsContext settingsContext, bool value) async {
            await settingsContext.appModel.setAudiobookBackgroundPlay(
              value: value,
            );
            settingsContext.refresh();
          },
        ),
        // 朗读声音（TTS）：没有录音有声书的书也能由阅读器朗读并逐句高亮。
        SettingsActionItem(
          id: 'listening.tts_voices',
          title: t.audiobook_tts_voice_settings,
          subtitle: t.audiobook_tts_voice_settings_hint,
          icon: FushiIcons.voice,
          cli: const SettingsCliAction.unsupported(
            '朗读声音的增删改与设默认用 fushi_cli voice ls/add/set/use/rm',
          ),
          onTap: (SettingsContext settingsContext) async {
            await openTtsVoiceSettingsPage(
              settingsContext.context,
              TtsServices.of(settingsContext.appModel.prefsRepo),
            );
            settingsContext.refresh();
          },
        ),
        // 有声书素材库：按作品身份命名的字幕/正文目录。下载完成后据此配齐
        // 「正文 + 字幕 + 音频」，配不齐时由用户在导入框里手动补。
        SettingsActionItem(
          id: 'listening.audiobook_material_library',
          title: t.audiobook_material_library,
          subtitle: t.audiobook_material_library_hint,
          icon: FushiIcons.dictionary,
          // CLI：加 / 删素材目录（代替目录选择器），每次都重扫并回报认出几部作品。
          cli: SettingsCliAction(
            params: const <SettingsCliParam>[
              SettingsCliParam(
                'add',
                help: '要加入的素材目录（绝对路径）',
                required: false,
                path: true,
              ),
              SettingsCliParam(
                'remove',
                help: '要移除的素材目录（与列表里的写法一致）',
                required: false,
              ),
            ],
            run: (SettingsContext c, Map<String, String> args) =>
                editAudiobookMaterialDirs(
                  c.appModel,
                  add: args['add'],
                  remove: args['remove'],
                ),
          ),
          onTap: (SettingsContext settingsContext) async {
            await showAppDialog<void>(
              context: settingsContext.context,
              builder: (_) => AudiobookMaterialLibraryDialog(
                appModel: settingsContext.appModel,
              ),
            );
            settingsContext.refresh();
          },
        ),
        // 只有音频的有声书下载完成后自动转录入库（默认开）。本机没有设备端
        // ASR 的平台这条开关没有意义，不显示。
        SettingsSwitchItem(
          id: 'listening.audiobook_auto_transcribe',
          title: t.audiobook_auto_transcribe,
          subtitle: t.audiobook_auto_transcribe_hint,
          icon: FushiIcons.voice,
          visible: (_) => isAsrSupported,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.audiobookAutoTranscribe,
          onChanged: (SettingsContext settingsContext, bool value) async {
            await settingsContext.appModel.setAudiobookAutoTranscribe(
              value: value,
            );
            settingsContext.refresh();
          },
        ),
        SettingsSwitchItem(
          id: 'listening.media_notification',
          title: t.show_media_notification,
          subtitle: t.show_media_notification_hint,
          icon: FushiIcons.notifications,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.showMediaNotification,
          onChanged: (SettingsContext settingsContext, bool value) async {
            await settingsContext.appModel.setShowMediaNotification(value);
            // 退书后台听书时会话仍在播：当场换通知形态（完整 ↔ 最简），与阅读器
            // 快捷设置的开关走同一入口（BUG-3777 A）。
            settingsContext.appModel.audiobookSession
                .onMediaNotificationToggled(enabled: value);
            settingsContext.refresh();
          },
        ),
        SettingsSwitchItem(
          id: 'listening.volume_key_sentence_nav',
          title: t.volume_key_sentence_nav,
          icon: FushiIcons.skipNext,
          // VolumeKeyChannel 仅 Android 实现，桌面隐藏此项（TODO-1155）。
          visible: (_) => Platform.isAndroid,
          reader: const ReaderPlacement(group: ReaderGroup.behavior, order: 10),
          value: (SettingsContext settingsContext) =>
              settingsContext.readerSource.volumeKeySentenceNavEnabled,
          onChanged: (SettingsContext settingsContext, bool value) {
            settingsContext.readerSource.toggleVolumeKeySentenceNavEnabled();
            notifyReaderSettingsChanged(settingsContext);
          },
        ),
        // 反馈 0AwuVqrNFn：「返回原位置」胶囊的跳转距离。旧值写死 15 秒，没听清往回拖
        // 一分钟也弹胶囊；出厂改 2 分钟、可在 15 秒–30 分钟间选。会话按闭包读实时值，
        // 改完对正在播的书立即生效。
        SettingsSegmentedItem<int>(
          id: 'listening.audiobook_jump_threshold',
          title: t.audiobook_jump_threshold,
          subtitle: t.audiobook_jump_threshold_hint,
          icon: FushiIcons.history,
          dropdown: true,
          defaultValue: kAudiobookJumpThresholdSecDefault,
          options: <SettingsSegmentOption<int>>[
            for (final int sec in kAudiobookJumpThresholdSecChoices)
              SettingsSegmentOption<int>(
                value: sec,
                label: audiobookJumpThresholdLabel(sec),
              ),
          ],
          selected: (SettingsContext settingsContext) =>
              settingsContext.appModel.audiobookJumpThresholdSec,
          onChanged: (SettingsContext settingsContext, int value) async {
            await settingsContext.appModel.setAudiobookJumpThresholdSec(value);
            settingsContext.refresh();
          },
        ),
      ],
    ),
    // 悬浮歌词：总开关 + 常用行为独立成组；外观 / 排版另起一组默认折叠
    // （与 galgame 台词浮窗「窗口与可读性」同构——两者是同一个原生窗类）。
    SettingsSection(
      // 模块门原先挂在 destination 上，并入阅读后下放到分区自己身上。
      visible: listeningModuleOn,
      id: 'listening.section.floating_lyric',
      presentation: SettingsSectionPresentation.alwaysExpanded,
      title: t.section_floating_lyric,
      items: <SettingsItem>[
        SettingsSwitchItem(
          id: 'listening.floating_lyric',
          title: t.show_floating_lyric,
          subtitle: t.floating_lyric_hint,
          icon: FushiIcons.subtitles,
          // 有原生后端的平台都要看得到这个开关（Android overlay / Windows
          // floating_lyric_window.cpp / macOS FushiFloatingLyric.swift）——当年只放
          // Android 时桌面用户找不到它，被当成「功能坏了 / 要权限」（TODO-038）。
          // 平台判据只认 channel 那一处。
          visible: (_) => FloatingLyricChannel.supported,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.showFloatingLyric,
          onChanged: (SettingsContext settingsContext, bool value) async {
            // TODO-1069/1070：走语义意图入口，置位（非翻转）+ 有会话时原子拉/隐
            // 原生悬浮窗 + 写意图 pref。旧实现只裸写 setShowFloatingLyric 旁路，
            // 不真正显隐窗，导致开关不即时、与书内翻转显隐反相。
            await settingsContext.appModel.setFloatingLyricEnabled(value);
            settingsContext.refresh();
          },
        ),
        // 同时显示句数（当前句居中，与歌词模式一致）。0 = 自动：桌面原生窗（Windows /
        // macOS）按窗口高度显示（拖高窗口看到更多句），Android 没有可裁的视口，自动档
        // 不提供。
        // 改值后调 resyncFloatingLyricText 即时重推文本。
        SettingsStepperItem(
          id: 'listening.floating_lyric_visible_lines',
          title: t.floating_lyric_visible_lines,
          subtitle: t.floating_lyric_visible_lines_hint,
          icon: Icons.format_line_spacing_outlined,
          visible: _floatingLyricOn,
          defaultValue: PreferencesRepository.floatingLyricVisibleLinesDefault
              .toDouble(),
          min: floatingLyricDesktopWindowOn(Platform.operatingSystem) ? 0 : 1,
          max: PreferencesRepository.floatingLyricVisibleLinesMax.toDouble(),
          step: 1,
          value: (SettingsContext settingsContext) {
            final int lines =
                settingsContext.appModel.floatingLyricVisibleLines;
            // Android 上自动档按 3 句渲染（见 floatingLyricVisibleSpan）。
            final bool autoAvailable = floatingLyricDesktopWindowOn(
              Platform.operatingSystem,
            );
            return (!autoAvailable && lines == 0 ? 3 : lines).toDouble();
          },
          format: (double value) => value.round() == 0
              ? t.floating_lyric_visible_lines_auto
              : value.round().toString(),
          onChanged: (SettingsContext settingsContext, double value) async {
            await settingsContext.appModel.setFloatingLyricVisibleLines(
              value.round(),
            );
            await settingsContext.appModel.audiobookSession
                .resyncFloatingLyricText();
            settingsContext.refresh();
          },
        ),
        SettingsStepperItem(
          id: 'listening.floating_lyric_font_size',
          title: t.floating_lyric_font_size,
          icon: FushiIcons.fontSize,
          visible: _floatingLyricOn,
          min: 8,
          max: 64,
          step: 1,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.floatingLyricFontSize,
          format: (double value) => value.round().toString(),
          onChanged: (SettingsContext settingsContext, double value) async {
            await settingsContext.appModel.setFloatingLyricFontSize(value);
            // TODO-1069：改字号后把整支 style（含 fontSize）经 FloatingLyricChannel
            // .updateStyle 即时推给原生悬浮窗——与透明度三项对齐。漏掉这一步时字号
            // 只写了 pref，原生窗不刷新，得等改透明度才顺带把字号推过去。
            await settingsContext.appModel.audiobookSession
                .applyFloatingLyricStyle();
            settingsContext.refresh();
          },
        ),
        SettingsSwitchItem(
          id: 'listening.floating_lyric_click_lookup',
          title: t.floating_lyric_click_lookup,
          subtitle: t.floating_lyric_click_lookup_hint,
          icon: FushiIcons.touch,
          visible: _floatingLyricOn,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.floatingLyricClickLookup,
          onChanged: (SettingsContext settingsContext, bool value) async {
            await settingsContext.appModel.setFloatingLyricClickLookup(value);
            settingsContext.refresh();
          },
        ),
      ],
    ),
    SettingsSection(
      // 分区级只判模块门（与另外两个听书分区同粒度）；平台与「悬浮字幕开没开」
      // 由每一项自己的 visible 判，项全不可见时分区整个被过滤掉。
      visible: listeningModuleOn,
      id: 'listening.section.floating_lyric_appearance',
      title: t.floating_lyric_appearance_section,
      collapsedByDefault: true,
      items: <SettingsItem>[
        // 字体只有桌面原生窗（Windows DirectWrite / macOS TextKit）吃；Android
        // TextView 用系统字体。
        SettingsNavigationItem(
          id: 'listening.floating_lyric_font',
          title: t.floating_lyric_font,
          subtitle: t.floating_lyric_font_hint,
          icon: FushiIcons.font,
          showIcon: true,
          visible: _floatingLyricDesktopOn,
          onTap: (SettingsContext settingsContext) async {
            await pushSettingsPage(
              settingsContext,
              (_) => const CustomFontsPage(target: FontTarget.floatingLyric),
            );
            await settingsContext.appModel.audiobookSession
                .applyFloatingLyricStyle();
            settingsContext.refresh();
          },
        ),
        SettingsSwitchItem(
          id: 'listening.floating_lyric_vertical',
          title: t.floating_lyric_vertical,
          subtitle: t.floating_lyric_vertical_hint,
          icon: FushiIcons.textVertical,
          // 竖排只有 Windows 原生窗实现（macOS 后端没有竖排排版）。
          visible: _floatingLyricVerticalOn,
          defaultValue: false,
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricVertical,
          onChanged: (SettingsContext c, bool value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricVertical(value),
              ),
        ),
        SettingsSwitchItem(
          id: 'listening.floating_lyric_bold',
          title: t.gal_hook_text_bold,
          subtitle: t.gal_hook_text_bold_hint,
          icon: FushiIcons.bold,
          visible: _floatingLyricDesktopOn,
          defaultValue: true,
          value: (SettingsContext c) => c.appModel.prefsRepo.floatingLyricBold,
          onChanged: (SettingsContext c, bool value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricBold(value),
              ),
        ),
        SettingsSliderItem(
          id: 'listening.floating_lyric_line_height',
          title: t.gal_hook_text_line_height,
          subtitle: t.gal_hook_text_line_height_hint,
          icon: FushiIcons.lineSpacing,
          visible: _floatingLyricDesktopOn,
          defaultValue: PreferencesRepository.floatingLyricLineHeightDefault,
          min: PreferencesRepository.floatingLyricLineHeightMin,
          max: PreferencesRepository.floatingLyricLineHeightMax,
          divisions: 24,
          step: 0.05,
          titleReadout: true,
          label: (double value) => '${value.toStringAsFixed(2)}×',
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricLineHeight,
          onChanged: (SettingsContext c, double value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricLineHeight(value),
              ),
        ),
        SettingsSliderItem(
          id: 'listening.floating_lyric_letter_spacing',
          title: t.gal_hook_text_letter_spacing,
          subtitle: t.gal_hook_text_letter_spacing_hint,
          icon: FushiIcons.spaceBar,
          visible: _floatingLyricDesktopOn,
          defaultValue: 0,
          min: PreferencesRepository.floatingLyricLetterSpacingMin,
          max: PreferencesRepository.floatingLyricLetterSpacingMax,
          divisions: 28,
          step: 0.5,
          titleReadout: true,
          label: (double value) => '${value.toStringAsFixed(1)} px',
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricLetterSpacing,
          onChanged: (SettingsContext c, double value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricLetterSpacing(value),
              ),
        ),
        SettingsSegmentedItem<int>(
          id: 'listening.floating_lyric_text_alignment',
          title: t.gal_hook_text_alignment,
          icon: FushiIcons.alignJustify,
          visible: _floatingLyricDesktopOn,
          defaultValue: 0,
          options: <SettingsSegmentOption<int>>[
            SettingsSegmentOption<int>(
              value: 0,
              label: t.gal_hook_text_alignment_center,
            ),
            SettingsSegmentOption<int>(
              value: 1,
              label: t.gal_hook_text_alignment_left,
            ),
          ],
          selected: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricTextAlignment,
          onChanged: (SettingsContext c, int value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricTextAlignment(value),
              ),
        ),
        SettingsSliderItem(
          id: 'listening.floating_lyric_text_padding',
          title: t.gal_hook_text_padding,
          subtitle: t.gal_hook_text_padding_hint,
          icon: FushiIcons.formatShapes,
          visible: _floatingLyricDesktopOn,
          defaultValue: PreferencesRepository.floatingLyricTextPaddingDefault
              .toDouble(),
          min: 0,
          max: PreferencesRepository.floatingLyricTextPaddingMax.toDouble(),
          divisions: PreferencesRepository.floatingLyricTextPaddingMax ~/ 2,
          step: 2,
          titleReadout: true,
          label: (double value) => '${value.round()} px',
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricTextPadding.toDouble(),
          onChanged: (SettingsContext c, double value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricTextPadding(
                  value.round(),
                ),
              ),
        ),
        _floatingLyricColorItem(
          id: 'listening.floating_lyric_color_text',
          visible: _floatingLyricOn,
          title: t.gal_hook_text_color,
          icon: FushiIcons.textFields,
          role: FloatingLyricColorRole.text,
        ),
        _floatingLyricColorItem(
          id: 'listening.floating_lyric_color_current',
          title: t.floating_lyric_current_line_color,
          icon: FushiIcons.lightbulb,
          role: FloatingLyricColorRole.current,
          visible: _floatingLyricDesktopOn,
        ),
        _floatingLyricColorItem(
          id: 'listening.floating_lyric_color_background',
          visible: _floatingLyricOn,
          title: t.gal_hook_text_background_color,
          icon: FushiIcons.blur,
          role: FloatingLyricColorRole.background,
        ),
        // TODO-576: 悬浮字幕/歌词条「背景透明度」自定义（0..100%，默认 70=更不挡
        // 视野）。
        _floatingLyricPercentItem(
          id: 'listening.floating_lyric_bg_opacity',
          visible: _floatingLyricOn,
          title: t.floating_lyric_bg_opacity,
          icon: Icons.gradient_outlined,
          value: (SettingsContext c) => c.appModel.floatingLyricBgOpacity,
          write: (SettingsContext c, int v) =>
              c.appModel.setFloatingLyricBgOpacity(v),
        ),
        // TODO-370: 悬浮字幕「文字透明度」+「按钮底色透明度」自定义（0..100%，
        // 100=保持现观感）。
        _floatingLyricPercentItem(
          id: 'listening.floating_lyric_text_opacity',
          visible: _floatingLyricOn,
          title: t.floating_lyric_text_opacity,
          icon: Icons.opacity_outlined,
          value: (SettingsContext c) => c.appModel.floatingLyricTextOpacity,
          write: (SettingsContext c, int v) =>
              c.appModel.setFloatingLyricTextOpacity(v),
        ),
        _floatingLyricPercentItem(
          id: 'listening.floating_lyric_context_opacity',
          title: t.floating_lyric_context_opacity,
          subtitle: t.floating_lyric_context_opacity_hint,
          icon: FushiIcons.blurLinear,
          visible: _floatingLyricDesktopOn,
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricContextOpacity,
          write: (SettingsContext c, int v) =>
              c.appModel.prefsRepo.setFloatingLyricContextOpacity(v),
        ),
        _floatingLyricPercentItem(
          id: 'listening.floating_lyric_button_bg_opacity',
          visible: _floatingLyricOn,
          title: t.floating_lyric_button_bg_opacity,
          icon: Icons.smart_button_outlined,
          value: (SettingsContext c) => c.appModel.floatingLyricButtonBgOpacity,
          write: (SettingsContext c, int v) =>
              c.appModel.setFloatingLyricButtonBgOpacity(v),
        ),
        SettingsSliderItem(
          id: 'listening.floating_lyric_outline_width',
          title: t.gal_hook_text_outline_width,
          subtitle: t.gal_hook_text_outline_width_hint,
          icon: FushiIcons.outline,
          visible: _floatingLyricDesktopOn,
          defaultValue: 0,
          min: 0,
          max: PreferencesRepository.floatingLyricOutlineWidthMax,
          divisions: 24,
          step: 0.25,
          titleReadout: true,
          label: (double value) => '${value.toStringAsFixed(2)} px',
          value: (SettingsContext c) =>
              c.appModel.prefsRepo.floatingLyricOutlineWidth,
          onChanged: (SettingsContext c, double value) =>
              _commitFloatingLyricStyle(
                c,
                () => c.appModel.prefsRepo.setFloatingLyricOutlineWidth(value),
              ),
        ),
        _floatingLyricColorItem(
          id: 'listening.floating_lyric_color_outline',
          title: t.gal_hook_text_outline_color,
          icon: FushiIcons.outlineColor,
          role: FloatingLyricColorRole.outline,
          visible: _floatingLyricDesktopOn,
          enableAlpha: true,
        ),
        // TODO-708 P2: 悬浮字幕/歌词条「圆角半径」自定义（dp，0=直角）。
        SettingsStepperItem(
          id: 'listening.floating_lyric_corner_radius',
          title: t.floating_lyric_corner_radius,
          subtitle: t.floating_lyric_corner_radius_hint,
          icon: Icons.rounded_corner_outlined,
          visible: _floatingLyricOn,
          defaultValue: PreferencesRepository.floatingLyricCornerRadiusDefault
              .toDouble(),
          min: 0,
          max: 48,
          step: 2,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.floatingLyricCornerRadius.toDouble(),
          format: (double value) => '${value.round()}',
          onChanged: (SettingsContext settingsContext, double value) async {
            await settingsContext.appModel.setFloatingLyricCornerRadius(
              value.round(),
            );
            await settingsContext.appModel.audiobookSession
                .applyFloatingLyricStyle();
            settingsContext.refresh();
          },
        ),
        // TODO-708 P2: 悬浮字幕/歌词条「宽度」自定义（dp，0=平台默认宽 / Windows
        // 拖角缩放后的宽度）。0 显示为「自动」，其余 200..1200 逐 40 dp 步进。
        SettingsStepperItem(
          id: 'listening.floating_lyric_width',
          title: t.floating_lyric_width,
          subtitle: t.floating_lyric_width_hint,
          icon: Icons.width_normal_outlined,
          visible: _floatingLyricOn,
          min: 0,
          max: 1200,
          step: 40,
          value: (SettingsContext settingsContext) =>
              settingsContext.appModel.floatingLyricWidth.toDouble(),
          format: (double value) =>
              value.round() == 0 ? t.audio_panel_auto : '${value.round()}',
          onChanged: (SettingsContext settingsContext, double value) async {
            // 0=自动；其余夹到 [200,1200]（<200 的步进值向上取到 200，保持哨兵语义只在 0）。
            final int rounded = value.round();
            final int width = rounded <= 0
                ? 0
                : (rounded < 200 ? 200 : rounded);
            await settingsContext.appModel.setFloatingLyricWidth(width);
            await settingsContext.appModel.audiobookSession
                .applyFloatingLyricStyle();
            settingsContext.refresh();
          },
        ),
      ],
    ),
  ];
}

/// 跳转距离档位的显示文案：整分钟显示「N 分钟」，否则「N 秒」。
String audiobookJumpThresholdLabel(int seconds) => seconds % 60 == 0
    ? t.audiobook_jump_threshold_minutes(n: seconds ~/ 60)
    : t.audiobook_jump_threshold_seconds(n: seconds);

/// 悬浮字幕有原生后端（Android overlay / Windows 原生窗 / macOS NSPanel）且已开启。
bool _floatingLyricOn(SettingsContext c) =>
    FloatingLyricChannel.supported && c.appModel.showFloatingLyric;

/// 只有桌面富文本原生窗吃的项（Windows DirectWrite，与 galgame 台词浮窗同一个
/// 窗类；macOS TextKit NSPanel）：字体 / 粗体 / 行高 / 字距 / 对齐 / 边距 / 描边 /
/// 当前句色 / 上下文透明度。
bool _floatingLyricDesktopOn(SettingsContext c) =>
    FloatingLyricChannel.supported &&
    floatingLyricDesktopWindowOn(Platform.operatingSystem) &&
    c.appModel.showFloatingLyric;

/// 竖排：只有 Windows 原生窗实现。
bool _floatingLyricVerticalOn(SettingsContext c) =>
    FloatingLyricChannel.supported &&
    floatingLyricVerticalTextOn(Platform.operatingSystem) &&
    c.appModel.showFloatingLyric;

/// 写偏好 → 整份样式重推给原生窗 → 刷新设置页。
Future<void> _commitFloatingLyricStyle(
  SettingsContext context,
  Future<void> Function() write,
) async {
  await write();
  await context.appModel.audiobookSession.applyFloatingLyricStyle();
  context.refresh();
}

SettingsStepperItem _floatingLyricPercentItem({
  required String id,
  required String title,
  required IconData icon,
  required int Function(SettingsContext c) value,
  required Future<void> Function(SettingsContext c, int value) write,
  String? subtitle,
  required bool Function(SettingsContext c) visible,
}) {
  return SettingsStepperItem(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    visible: visible,
    min: 0,
    max: 100,
    step: 5,
    value: (SettingsContext c) => value(c).toDouble(),
    format: (double v) => '${v.round()}%',
    onChanged: (SettingsContext c, double v) =>
        _commitFloatingLyricStyle(c, () => write(c, v.round())),
  );
}

/// 悬浮字幕颜色行：默认跟随主题（M3E 配对色，与浮窗下发同一个
/// [floatingLyricThemeColor]），可自选。与 galgame 台词浮窗共用同一个组件。
SettingsCustomItem _floatingLyricColorItem({
  required String id,
  required String title,
  required IconData icon,
  required FloatingLyricColorRole role,
  required bool Function(SettingsContext c) visible,
  bool enableAlpha = false,
}) {
  return overlayColorSettingItem(
    id: id,
    title: title,
    icon: icon,
    visible: visible,
    enableAlpha: enableAlpha,
    followThemeValue: PreferencesRepository.floatingLyricColorFollowTheme,
    followsTheme: (int stored) =>
        stored == PreferencesRepository.floatingLyricColorFollowTheme,
    value: (SettingsContext c) => c.appModel.prefsRepo.floatingLyricColor(role),
    themedColor: (ThemeData theme) =>
        floatingLyricThemeColor(theme.colorScheme, role),
    commit: (SettingsContext c, int color) => _commitFloatingLyricStyle(
      c,
      () => c.appModel.prefsRepo.setFloatingLyricColor(role, color),
    ),
  );
}
