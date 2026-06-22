import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildListeningDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.listening,
    title: t.settings_destination_listening,
    summary: t.floating_lyric_hint,
    icon: Icons.headphones_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_audiobook,
        items: <SettingsItem>[
          // TODO-702：有声书退出即停（默认 OFF）/ 后台续播（开启）。默认关 = 退出
          // 阅读页就停止有声书播放；开启后退书后会话继续在后台播。
          SettingsSwitchItem(
            id: 'listening.audiobook_background_play',
            title: t.audiobook_background_play,
            subtitle: t.audiobook_background_play_hint,
            icon: Icons.play_circle_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.audiobookBackgroundPlay,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setAudiobookBackgroundPlay(value: value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.media_notification',
            title: t.show_media_notification,
            icon: Icons.notifications_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showMediaNotification,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowMediaNotification(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.floating_lyric',
            title: t.show_floating_lyric,
            subtitle: t.floating_lyric_hint,
            icon: Icons.subtitles_outlined,
            // The strip is the desktop counterpart of the Android overlay
            // (windows/runner/floating_lyric_window.cpp), so Windows must see
            // this switch too — gating it to Android hid it from desktop users
            // and was the "floating subtitle setting missing/permission"
            // complaint (TODO-038). The Dart channel's isSupported already
            // allows Android + Windows.
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showFloatingLyric,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowFloatingLyric(value);
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'listening.floating_lyric_font_size',
            title: t.floating_lyric_font_size,
            icon: Icons.format_size,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 8,
            max: 64,
            step: 1,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricFontSize,
            format: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setFloatingLyricFontSize(value);
              settingsContext.refresh();
            },
          ),
          // TODO-370: 悬浮字幕「文字透明度」+「按钮底色透明度」自定义（0..100%，
          // 100=保持现观感）。与字号一样仅 Android/Windows 可见（有原生悬浮窗后端）。
          SettingsStepperItem(
            id: 'listening.floating_lyric_text_opacity',
            title: t.floating_lyric_text_opacity,
            subtitle: t.floating_lyric_text_opacity_hint,
            icon: Icons.opacity_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 0,
            max: 100,
            step: 5,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricTextOpacity.toDouble(),
            format: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setFloatingLyricTextOpacity(value.round());
              await settingsContext.appModel.audiobookSession
                  .applyFloatingLyricStyle();
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'listening.floating_lyric_button_bg_opacity',
            title: t.floating_lyric_button_bg_opacity,
            subtitle: t.floating_lyric_button_bg_opacity_hint,
            icon: Icons.smart_button_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 0,
            max: 100,
            step: 5,
            value: (SettingsContext settingsContext) => settingsContext
                .appModel.floatingLyricButtonBgOpacity
                .toDouble(),
            format: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setFloatingLyricButtonBgOpacity(value.round());
              await settingsContext.appModel.audiobookSession
                  .applyFloatingLyricStyle();
              settingsContext.refresh();
            },
          ),
          // TODO-576: 悬浮字幕/歌词条「背景透明度」自定义（0..100%，默认 70=更不挡
          // 视野）。同样仅 Android/Windows 可见（有原生悬浮窗后端）。
          SettingsStepperItem(
            id: 'listening.floating_lyric_bg_opacity',
            title: t.floating_lyric_bg_opacity,
            subtitle: t.floating_lyric_bg_opacity_hint,
            icon: Icons.gradient_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 0,
            max: 100,
            step: 5,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricBgOpacity.toDouble(),
            format: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setFloatingLyricBgOpacity(value.round());
              await settingsContext.appModel.audiobookSession
                  .applyFloatingLyricStyle();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.floating_lyric_click_lookup',
            title: t.floating_lyric_click_lookup,
            subtitle: t.floating_lyric_click_lookup_hint,
            icon: Icons.touch_app_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricClickLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setFloatingLyricClickLookup(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.volume_key_sentence_nav',
            title: t.volume_key_sentence_nav,
            icon: Icons.skip_next_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 9,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumeKeySentenceNavEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumeKeySentenceNavEnabled();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
    ],
  );
}
