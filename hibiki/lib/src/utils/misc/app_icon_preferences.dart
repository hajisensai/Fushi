import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图标预设偏好键（与已有 Android 切换共用同一 key）。
const String iconPresetPrefKey = 'app_icon_preset';

/// 用户自定义图标的本地文件路径偏好键（桌面端）。
const String iconCustomPathPrefKey = 'app_icon_custom_path';

/// 三套预设 key → 用于预览/桌面窗口图标的 asset 路径。
/// `default` 指向文字 wordmark（与默认启动器图标一致）。
const Map<String, String> presetIconAssets = <String, String>{
  'default': 'assets/meta/launcher_icon_minimal.png',
  'hibiki_full': 'assets/meta/launcher_icon_full.png',
  'hibiki_minimal': 'assets/meta/launcher_icon_minimal.png',
};

/// 自定义槽的保留 key。
const String customIconKey = 'custom';

/// 是否为内置预设 key（custom / 未知都返回 false）。
bool isPresetKey(String key) => presetIconAssets.containsKey(key);

/// 预设 key → asset 路径；未知 key 回退到 `default`；`custom` 返回 null。
String? windowIconAssetForPreset(String key) {
  if (key == customIconKey) {
    return null;
  }
  return presetIconAssets[key] ?? presetIconAssets['default'];
}

/// 把预设 asset 导出成 app support 目录下的 PNG 文件，返回其路径。
/// 供 Windows `setWindowIcon` 使用（原生侧从文件路径解码）。
Future<String> exportPresetIconToFile(String presetKey) async {
  final String asset =
      windowIconAssetForPreset(presetKey) ?? presetIconAssets['default']!;
  final Directory dir = await getApplicationSupportDirectory();
  final File file = File('${dir.path}/window_icon_$presetKey.png');
  final ByteData data = await rootBundle.load(asset);
  await file.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  return file.path;
}

/// 把用户选择的自定义图片拷贝到 app support 目录（稳定路径，便于启动重应用）。
/// 返回拷贝后的路径。
Future<String> persistCustomIconFile(String sourcePath) async {
  final Directory dir = await getApplicationSupportDirectory();
  // 固定单一落点：原生 WIC 按内容解码不依赖扩展名，固定路径避免换图时残留孤儿文件。
  final File dest = File('${dir.path}/window_icon_custom.png');
  await File(sourcePath).copy(dest.path);
  return dest.path;
}

/// 读已持久化的预设 key（默认 `default`）。
Future<String> loadIconPresetKey() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString(iconPresetPrefKey) ?? 'default';
}

/// 读已持久化的自定义图标路径（可能为 null）。
Future<String?> loadCustomIconPath() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString(iconCustomPathPrefKey);
}

/// 写预设 key。
Future<void> saveIconPresetKey(String key) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString(iconPresetPrefKey, key);
}

/// 写自定义图标路径。
Future<void> saveCustomIconPath(String path) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString(iconCustomPathPrefKey, path);
}
