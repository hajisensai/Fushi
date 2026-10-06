/// 「悬浮球」一级分类：悬浮球唯一的设置入口（`docs/specs/2026-09-28-floating-ball.md`）。
///
/// 两个独立开关——应用内（默认开）/ 应用外（Android / Windows / macOS，默认关）——、
/// 关闭后自动恢复的三态（[FloatingBallAutoRestore]），加每个场景一组按钮勾选：阅读器 / 漫画 / 视频按当前页面的语料分，「其它页面」是
/// 没有登记场景的页面，「应用外」是原生系统球。各场景的按钮目录见 [FloatingBallScope]。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
    icon: FushiIcons.floatingBall,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'floating_ball.section.display',
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'floating_ball.in_app',
            title: t.floating_ball_in_app,
            subtitle: t.floating_ball_in_app_hint,
            icon: FushiIcons.floatingBall,
            value: (SettingsContext c) => _prefs(c).floatingBallInApp,
            onChanged: (SettingsContext c, bool value) async {
              await _prefs(c).setFloatingBallInApp(value);
              c.refresh();
            },
            defaultValue: true,
          ),
          SettingsSwitchItem(
            id: 'floating_ball.system',
            title: t.floating_ball_system,
            // 只有 Android 要「显示在其他应用上层」权限。
            subtitle: Platform.isAndroid
                ? t.floating_ball_system_hint
                : t.floating_ball_system_hint_desktop,
            icon: FushiIcons.openInNew,
            // iOS 不允许应用外悬浮，Linux 没有实现。
            visible: (SettingsContext c) => _systemBallSupported,
            value: (SettingsContext c) => _prefs(c).floatingBallSystem,
            onChanged: (SettingsContext c, bool value) async {
              await _prefs(c).setFloatingBallSystem(value);
              c.refresh();
              // 要「显示在其他应用上层」权限：没有就说明原因并跳授权页，回到前台时
              // 悬浮球宿主会再试一次起服务。
              if (value &&
                  Platform.isAndroid &&
                  !await FloatingBallChannel.canDrawOverlays()) {
                final BuildContext ctx = c.context;
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    FushiSnackBar(
                      content: Text(t.floating_ball_overlay_permission_needed),
                    ),
                  );
                }
                await FloatingBallChannel.requestOverlayPermission();
              }
            },
            defaultValue: false,
          ),
          SettingsSwitchItem(
            id: 'floating_ball.show_labels',
            title: t.floating_ball_show_labels,
            subtitle: t.floating_ball_show_labels_hint,
            icon: Icons.text_fields,
            value: (SettingsContext c) => _prefs(c).floatingBallShowLabels,
            onChanged: (SettingsContext c, bool value) async {
              await _prefs(c).setFloatingBallShowLabels(value);
              c.refresh();
            },
            defaultValue: true,
          ),
          SettingsSegmentedItem<FloatingBallAutoRestore>(
            id: 'floating_ball.auto_restore',
            title: t.floating_ball_auto_restore,
            subtitle: t.floating_ball_auto_restore_hint,
            icon: Icons.restore,
            visible: (SettingsContext c) =>
                _prefs(c).floatingBallInApp ||
                (_systemBallSupported && _prefs(c).floatingBallSystem),
            options: <SettingsSegmentOption<FloatingBallAutoRestore>>[
              // 没有应用外球的平台（iOS / Linux）只剩「恢复 / 不恢复」两档。
              if (_systemBallSupported)
                SettingsSegmentOption<FloatingBallAutoRestore>(
                  value: FloatingBallAutoRestore.both,
                  label: t.floating_ball_auto_restore_both,
                ),
              SettingsSegmentOption<FloatingBallAutoRestore>(
                value: FloatingBallAutoRestore.inApp,
                label: t.floating_ball_auto_restore_in_app,
              ),
              SettingsSegmentOption<FloatingBallAutoRestore>(
                value: FloatingBallAutoRestore.off,
                label: t.floating_ball_auto_restore_off,
              ),
            ],
            selected: (SettingsContext c) => _autoRestoreShown(c),
            onChanged:
                (SettingsContext c, FloatingBallAutoRestore value) async {
                  await _prefs(c).setFloatingBallAutoRestore(value);
                  c.refresh();
                },
            defaultValue: FloatingBallAutoRestore.fallback,
          ),
        ],
      ),
      for (final FloatingBallScope scope in FloatingBallScope.values)
        _buttonsSection(scope),
    ],
  );
}

PreferencesRepository _prefs(SettingsContext c) => c.appModel.prefsRepo;

bool get _systemBallSupported => FloatingBallScope.systemBallSupported(
  isAndroid: Platform.isAndroid,
  isDesktop: isDesktopSystemBallPlatform,
);

/// 没有应用外球的平台上，「应用内外」与「仅应用内」行为相同，按后者显示。
FloatingBallAutoRestore _autoRestoreShown(SettingsContext c) {
  final FloatingBallAutoRestore value = _prefs(c).floatingBallAutoRestore;
  return !_systemBallSupported && value == FloatingBallAutoRestore.both
      ? FloatingBallAutoRestore.inApp
      : value;
}

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
          visible: (SettingsContext c) => _buttonAvailable(c, scope, id),
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
    FloatingBallScope.system =>
      _systemBallSupported && prefs.floatingBallSystem,
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

/// 全局按钮按平台与场景能力出现（截屏识字 / 拍照查词只有 Android / iOS；桌面
/// 应用外球另有一套、并受查词模块开关约束，见
/// [FloatingBallGlobalAction.availableIn]）；专属按钮恒可配。
bool _buttonAvailable(SettingsContext c, FloatingBallScope scope, String id) {
  final FloatingBallGlobalAction? global = FloatingBallGlobalAction.fromStorage(
    id,
  );
  return global == null ||
      global.availableIn(
        scope,
        isAndroid: Platform.isAndroid,
        isIOS: Platform.isIOS,
        isDesktop: isDesktopSystemBallPlatform,
        lookupModuleEnabled: c.appModel.moduleVisibility.isEnabled(
          ModuleId.lookup,
        ),
      );
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
      FloatingBallGlobalAction.cameraOcr => t.floating_ball_action_camera_ocr,
      FloatingBallGlobalAction.sync => t.sync_now,
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
      FloatingBallGlobalAction.lookup => FushiIcons.search,
      FloatingBallGlobalAction.popupLookup =>
        FushiIcons.pictureInPicture,
      FloatingBallGlobalAction.clipboard => Icons.content_paste_search,
      FloatingBallGlobalAction.screenOcr => FushiIcons.ocr,
      FloatingBallGlobalAction.cameraOcr => Icons.photo_camera_outlined,
      FloatingBallGlobalAction.sync => FushiIcons.sync,
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
    'favorite' => FushiIcons.star,
    'screenshot' => Icons.photo_camera_outlined,
    'previous' => FushiIcons.chevronLeft,
    'next' => FushiIcons.chevronRight,
    'ocr_boxes' => Icons.highlight_alt_outlined,
    'ocr_volume' || 'ocr_rerun' => FushiIcons.ocr,
    'chapters' => Icons.list_alt_outlined,
    _ => Icons.circle_outlined,
  };
}
