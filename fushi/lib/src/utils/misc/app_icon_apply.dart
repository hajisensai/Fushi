import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/shortcut_icon_sync.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';

/// 应用图标「真正换上去」的执行体：原生图标切换 + 偏好落盘 + 发布当前选择。
///
/// 从应用图标设置页（`MiscellaneousSettingsBody`）搬出来，页面与控制通道
/// （`fushi_cli config set/run appearance.app_icon.cli.*`）共用同一份实现。
/// 只负责业务，不弹框、不管 SnackBar。

/// 本平台支不支持换应用图标（Android launcher alias / Windows 窗口图标）。
bool get appIconSwitchSupported => Platform.isAndroid || Platform.isWindows;

/// 原生图标已切换成功后落盘选择。偏好写失败时降级为只发布本次运行态（原生
/// 窗口 / launcher 图标已经换了，rail 与设置不能继续显示旧值），并留诊断日志。
Future<AppIconSelection> persistAppliedAppIcon(
  AppIconSelection selection,
) async {
  try {
    return await saveAppIconSelection(selection);
  } catch (e) {
    debugPrint('[Fushi] app icon preference persist failed: $e');
    return await publishAppIconSelection(selection);
  }
}

/// 切到预设图标 [key]（[presetIconAssets] 的键）。已是当前图标时直接返回 true。
/// 返回原生切换是否成功；未知 key 抛 [ArgumentError]，本平台不支持抛
/// [UnsupportedError]。
Future<bool> applyPresetAppIcon(String key) async {
  if (!isPresetKey(key)) {
    throw ArgumentError('未知预设图标「$key」，可选：${presetIconAssets.keys.join(' / ')}');
  }
  if (!appIconSwitchSupported) {
    throw UnsupportedError('本平台不支持更换应用图标（仅 Android / Windows）');
  }
  if (currentAppIconSelection.value.presetKey == key) return true;
  bool ok = false;
  if (Platform.isAndroid) {
    ok =
        (await FushiChannels.iconSwitch.invokeMethod<bool>(
          'switchPresetIcon',
          <String, Object?>{'alias': key},
        )) ==
        true;
  } else if (Platform.isWindows) {
    final String path = await exportPresetIconToFile(key);
    ok = await WindowCaptionChannel.setWindowIcon(path);
    if (ok) {
      // TODO-901：换图标后把桌面 / 开始菜单的 .lnk 图标也同步成新图。
      await syncWindowsShortcutIcons(await File(path).readAsBytes());
    }
  }
  if (ok) await persistAppliedAppIcon(AppIconSelection(presetKey: key));
  return ok;
}

/// 用 [imagePath]（已裁好的图片）当应用图标：Android 建自定义图标的桌面快捷
/// 方式，Windows 拷进 app support 并设为窗口图标、落盘选择。返回是否成功。
/// 文件不存在抛 [ArgumentError]，本平台不支持抛 [UnsupportedError]。
Future<bool> applyCustomAppIcon(String imagePath) async {
  if (!appIconSwitchSupported) {
    throw UnsupportedError('本平台不支持更换应用图标（仅 Android / Windows）');
  }
  if (!File(imagePath).existsSync()) {
    throw ArgumentError('图片不存在：$imagePath');
  }
  if (Platform.isAndroid) {
    final Uint8List bytes = await File(imagePath).readAsBytes();
    return (await FushiChannels.iconSwitch.invokeMethod<bool>(
          'createCustomShortcut',
          <String, Object?>{'imageBytes': bytes},
        )) ==
        true;
  }
  final String persisted = await persistCustomIconFile(imagePath);
  final bool ok = await WindowCaptionChannel.setWindowIcon(persisted);
  if (ok) {
    await persistAppliedAppIcon(
      AppIconSelection(presetKey: customIconKey, customPath: persisted),
    );
    // TODO-901：同步桌面 / 开始菜单 .lnk 图标到用户自定义图。
    await syncWindowsShortcutIcons(await File(persisted).readAsBytes());
  }
  return ok;
}
