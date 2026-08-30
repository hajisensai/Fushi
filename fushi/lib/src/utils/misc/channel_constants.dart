// Java counterpart: app.fushi.reader.constants.ChannelNames
// Both files MUST stay in sync. If you add a channel here, add it there too.

import 'package:flutter/services.dart';

abstract final class FushiChannels {
  static const String _prefix = 'app.fushi.reader';

  static const MethodChannel splash = MethodChannel('$_prefix/splash');
  static const MethodChannel anki = MethodChannel('$_prefix/anki');
  static const MethodChannel popup = MethodChannel('$_prefix/popup');
  static const MethodChannel tts = MethodChannel('$_prefix/tts');
  static const MethodChannel update = MethodChannel('$_prefix/update');
  static const MethodChannel volumeKeys = MethodChannel('$_prefix/volume_keys');
  static const MethodChannel floatingLyric =
      MethodChannel('$_prefix/floating_lyric');
  static const MethodChannel floatingDict =
      MethodChannel('$_prefix/floating_dict');
  static const MethodChannel lifecycle = MethodChannel('$_prefix/lifecycle');
  static const MethodChannel fonts = MethodChannel('$_prefix/fonts');
  static const MethodChannel saf = MethodChannel('$_prefix/saf');

  /// Hibiki→Fushi 跨包名迁移（探测/拉起新包、卸载引导、注销系统入口）。
  static const MethodChannel migration = MethodChannel('$_prefix/migration');
  static const MethodChannel iconSwitch = MethodChannel('$_prefix/icon_switch');
  static const MethodChannel clipboardImage =
      MethodChannel('$_prefix/clipboard_image');
  static const MethodChannel screenBrightness =
      MethodChannel('$_prefix/screen_brightness');
  static const MethodChannel selectionActions =
      MethodChannel('$_prefix/selection_actions');
  static const MethodChannel aidokuRuntime =
      MethodChannel('$_prefix/aidoku_runtime');
  // TODO-617: drives the desktop global lookup overlay (bare WebView2 window).
  static const MethodChannel globalLookup =
      MethodChannel('$_prefix/global_lookup');
  // Windows galgame Hook 台词浮窗：独立的 FloatingLyricWindow 实例。
  static const MethodChannel galHookText =
      MethodChannel('$_prefix/gal_hook_text');
  // TODO-1232 A3: render-backend experiment toggle (persist "disable Impeller"
  // so MainActivity can force Skia at the next launch; Android-only).
  static const MethodChannel render = MethodChannel('$_prefix/render');
}
