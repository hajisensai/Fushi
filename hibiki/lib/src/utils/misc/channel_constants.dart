// Java counterpart: app.hibiki.reader.constants.ChannelNames
// Both files MUST stay in sync. If you add a channel here, add it there too.

import 'package:flutter/services.dart';

abstract final class HibikiChannels {
  static const String _prefix = 'app.hibiki.reader';

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
  static const MethodChannel iconSwitch = MethodChannel('$_prefix/icon_switch');
  static const MethodChannel clipboardImage =
      MethodChannel('$_prefix/clipboard_image');
  static const MethodChannel screenBrightness =
      MethodChannel('$_prefix/screen_brightness');
  // TODO-617: drives the desktop global lookup overlay (bare WebView2 window).
  static const MethodChannel globalLookup =
      MethodChannel('$_prefix/global_lookup');
}
