/// 「悬浮球」一级分类：悬浮球唯一的设置入口（`docs/specs/2026-09-28-floating-ball.md`）。
///
/// 两个独立开关——应用内（默认开）/ 应用外（仅 Android，默认关）——加每个场景一组
/// 按钮勾选：阅读器 / 漫画 / 视频按当前页面的语料分，「其它页面」是没有登记场景的
/// 页面，「应用外」是 Android 系统球。各场景的按钮目录见 [FloatingBallScope]。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout_editor.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

SettingsDestination buildFloatingBallDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.floatingBall,
    title: t.settings_destination_floating_ball,
    summary: t.floating_ball_summary,
    icon: Icons.blur_circular_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'floating_ball.section.display',
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'floating_ball.in_app',
            title: t.floating_ball_in_app,
            subtitle: t.floating_ball_in_app_hint,
            icon: Icons.blur_circular_outlined,
            value: (SettingsContext c) => _prefs(c).floatingBallInApp,
            onChanged: (SettingsContext c, bool value) async {
              await _prefs(c).setFloatingBallInApp(value);
              c.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'floating_ball.system',
            title: t.floating_ball_system,
            subtitle: t.floating_ball_system_hint,
            icon: Icons.open_in_new,
            // iOS 不允许应用外悬浮，桌面没有这个概念。
            visible: (SettingsContext c) => Platform.isAndroid,
            value: (SettingsContext c) => _prefs(c).floatingBallSystem,
            onChanged: (SettingsContext c, bool value) async {
              await _prefs(c).setFloatingBallSystem(value);
              c.refresh();
              // 要「显示在其他应用上层」权限：没有就说明原因并跳授权页，回到前台时
              // 悬浮球宿主会再试一次起服务。
              if (value && !await FloatingBallChannel.canDrawOverlays()) {
                final BuildContext ctx = c.context;
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(t.floating_ball_overlay_permission_needed),
                    ),
                  );
                }
                await FloatingBallChannel.requestOverlayPermission();
              }
            },
          ),
        ],
      ),
      for (final FloatingBallScope scope in FloatingBallScope.values)
        _buttonsSection(scope),
    ],
  );
}

PreferencesRepository _prefs(SettingsContext c) => c.appModel.prefsRepo;

SettingsSection _buttonsSection(FloatingBallScope scope) {
  return SettingsSection(
    id: 'floating_ball.section.${scope.storageValue}',
    title: _scopeTitle(scope),
    footer: t.floating_ball_buttons_hint,
    presentation: scope == FloatingBallScope.system
        ? SettingsSectionPresentation.alwaysExpanded
        : SettingsSectionPresentation.expanded,
    visible: (SettingsContext c) => _scopeVisible(c, scope),
    items: <SettingsItem>[
      for (final String id in scope.catalog)
        SettingsSwitchItem(
          id: 'floating_ball.${scope.storageValue}.$id',
          title: _buttonLabel(scope, id),
          icon: _buttonIcon(scope, id),
          visible: (SettingsContext c) => _buttonAvailable(id),
          value: (SettingsContext c) =>
              _prefs(c).floatingBallButtons(scope).contains(id),
          onChanged: (SettingsContext c, bool value) async {
            final Set<String> ids = _prefs(
              c,
            ).floatingBallButtons(scope).toSet();
            if (value) {
              ids.add(id);
            } else {
              ids.remove(id);
            }
            await _prefs(c).setFloatingBallButtons(scope, ids);
            c.refresh();
          },
        ),
    ],
  );
}

/// 场景那组按钮什么时候值得配：对应的球开着、对应的模块没被关掉。
bool _scopeVisible(SettingsContext c, FloatingBallScope scope) {
  final PreferencesRepository prefs = _prefs(c);
  return switch (scope) {
    FloatingBallScope.system => Platform.isAndroid && prefs.floatingBallSystem,
    FloatingBallScope.manga =>
      prefs.floatingBallInApp &&
          c.appModel.moduleVisibility.isEnabled(ModuleId.manga),
    FloatingBallScope.video =>
      prefs.floatingBallInApp &&
          c.appModel.moduleVisibility.isEnabled(ModuleId.video),
    FloatingBallScope.reader =>
      prefs.floatingBallInApp &&
          c.appModel.moduleVisibility.isEnabled(ModuleId.books),
    FloatingBallScope.general => prefs.floatingBallInApp,
  };
}

/// 全局按钮按平台能力出现（截屏识字只有 Android / iOS）；专属按钮恒可配。
bool _buttonAvailable(String id) {
  final FloatingBallGlobalAction? global = FloatingBallGlobalAction.fromStorage(
    id,
  );
  return global == null ||
      global.availableOn(isAndroid: Platform.isAndroid, isIOS: Platform.isIOS);
}

String _scopeTitle(FloatingBallScope scope) => switch (scope) {
  FloatingBallScope.reader => t.floating_ball_scope_reader,
  FloatingBallScope.manga => t.floating_ball_scope_manga,
  FloatingBallScope.video => t.floating_ball_scope_video,
  FloatingBallScope.general => t.floating_ball_scope_general,
  FloatingBallScope.system => t.floating_ball_scope_system,
};

String _buttonLabel(FloatingBallScope scope, String id) {
  final FloatingBallGlobalAction? global = FloatingBallGlobalAction.fromStorage(
    id,
  );
  if (global != null) {
    return switch (global) {
      FloatingBallGlobalAction.lookup => t.floating_ball_action_lookup,
      FloatingBallGlobalAction.popupLookup =>
        t.floating_ball_action_popup_lookup,
      FloatingBallGlobalAction.clipboard => t.floating_ball_action_clipboard,
      FloatingBallGlobalAction.screenOcr => t.floating_ball_action_screen_ocr,
    };
  }
  if (scope == FloatingBallScope.reader) {
    final ReaderControlItem? item = ReaderControlItem.fromStorage(id);
    if (item != null) return readerControlItemLabel(item);
  }
  return switch (id) {
    // 视频（与视频页登记的按钮同一组文案）。
    'play_pause' => t.video_control_play_pause,
    'prev_cue' => t.video_control_previous_cue,
    'next_cue' => t.video_control_next_cue,
    'favorite' => t.shortcut_action_video_toggle_favorite_sentence,
    'screenshot' => t.video_control_screenshot,
    // 漫画（与漫画页登记的按钮同一组文案）。
    'previous' => t.shortcut_action_manga_page_backward,
    'next' => t.shortcut_action_manga_page_forward,
    'ocr_boxes' => t.manga_ocr_boxes_toggle,
    'ocr_volume' => t.manga_reader_ocr_volume,
    'ocr_rerun' => t.manga_reader_ocr_rerun,
    'chapters' => t.manga_series_chapters_action,
    _ => id,
  };
}

IconData _buttonIcon(FloatingBallScope scope, String id) {
  final FloatingBallGlobalAction? global = FloatingBallGlobalAction.fromStorage(
    id,
  );
  if (global != null) {
    return switch (global) {
      FloatingBallGlobalAction.lookup => Icons.search,
      FloatingBallGlobalAction.popupLookup =>
        Icons.picture_in_picture_alt_outlined,
      FloatingBallGlobalAction.clipboard => Icons.content_paste_search,
      FloatingBallGlobalAction.screenOcr => Icons.document_scanner_outlined,
    };
  }
  if (scope == FloatingBallScope.reader) {
    final ReaderControlItem? item = ReaderControlItem.fromStorage(id);
    if (item != null) return readerControlItemIcon(item);
  }
  return switch (id) {
    'play_pause' => Icons.play_arrow,
    'prev_cue' => Icons.skip_previous,
    'next_cue' => Icons.skip_next,
    'favorite' => Icons.star_border,
    'screenshot' => Icons.photo_camera_outlined,
    'previous' => Icons.chevron_left,
    'next' => Icons.chevron_right,
    'ocr_boxes' => Icons.highlight_alt_outlined,
    'ocr_volume' || 'ocr_rerun' => Icons.document_scanner_outlined,
    'chapters' => Icons.list_alt_outlined,
    _ => Icons.circle_outlined,
  };
}
