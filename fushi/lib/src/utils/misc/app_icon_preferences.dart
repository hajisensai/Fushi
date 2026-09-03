import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, immutable;
import 'package:flutter/painting.dart'
    show AssetImage, FileImage, ImageProvider, ResizeImage;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图标预设偏好键（与已有 Android 切换共用同一 key）。
const String iconPresetPrefKey = 'app_icon_preset';

/// 用户自定义图标的本地文件路径偏好键（桌面端）。
const String iconCustomPathPrefKey = 'app_icon_custom_path';

/// 三套预设 key → 用于预览/桌面窗口图标的 asset 路径。
/// `default` 指向不透明白色圆角方形（squircle）图标（任意壁纸可见，TODO-1241 起为默认）；
/// `hibiki_transparent` 指向透明无背景的藏青 wordmark（旧默认，保留为可选项）；
/// `hibiki_full` 指向響·书本精绘图标。
/// 历史上曾有 `hibiki_minimal` 档，但它与旧 `default` 映射同一张图（重复选项），已去重
/// 移除；老用户残留的 `hibiki_minimal` 由 [windowIconAssetForPreset] 安全回退到 default。
const Map<String, String> presetIconAssets = <String, String>{
  'default': 'assets/meta/launcher_icon_squircle.png',
  'hibiki_transparent': 'assets/meta/launcher_icon_minimal.png',
  'hibiki_full': 'assets/meta/launcher_icon_full.png',
};

/// 自定义槽的保留 key。
const String customIconKey = 'custom';

/// 侧栏品牌位最大仅约 48 逻辑像素；给高 DPI 留足余量，但绝不把用户选择的
/// 8K/相机原图整帧解码进 Flutter ImageCache。
const int appIconDecodePixelWidth = 256;

/// 当前真正生效的应用图标。
///
/// [revision] 不持久化，只用于区分连续两次选择了同一个自定义文件路径的情况。
/// Windows 自定义图标始终覆盖同一个稳定文件；没有这一代号时 Flutter 会复用旧
/// [FileImage] 的 image stream，即使文件内容已经换掉也仍显示旧图。
@immutable
class AppIconSelection {
  const AppIconSelection({
    required this.presetKey,
    this.customPath,
    this.revision = 0,
  });

  final String presetKey;
  final String? customPath;
  final int revision;

  bool get usesCustomFile => presetKey == customIconKey && customPath != null;

  AppIconSelection withRevision(int value) => AppIconSelection(
    presetKey: presetKey,
    customPath: customPath,
    revision: value,
  );
}

/// 主窗口侧栏与设置页共享的运行时真值。启动恢复和每次成功切换都只发布到这里，
/// 避免窗口图标、偏好和 Flutter 品牌位各维护一份互不通知的状态（BUG-1920）。
final ValueNotifier<AppIconSelection> currentAppIconSelection =
    ValueNotifier<AppIconSelection>(
      const AppIconSelection(presetKey: 'default'),
    );

/// 是否为内置预设 key（custom / 未知都返回 false）。
bool isPresetKey(String key) => presetIconAssets.containsKey(key);

bool _appIconFileExists(String path) => File(path).existsSync();

/// 把持久化输入收敛成可安全渲染的选择：未知预设、自定义路径为空或文件已被删除时
/// 都回退 default，而不是让侧栏保留坏的 [FileImage]。
AppIconSelection resolveAppIconSelection({
  required String presetKey,
  String? customPath,
  bool Function(String path)? pathExists,
}) {
  final bool Function(String path) exists = pathExists ?? _appIconFileExists;
  if (presetKey == customIconKey &&
      customPath != null &&
      customPath.isNotEmpty &&
      exists(customPath)) {
    return AppIconSelection(presetKey: customIconKey, customPath: customPath);
  }
  return AppIconSelection(
    presetKey: isPresetKey(presetKey) ? presetKey : 'default',
  );
}

/// 当前选择对应的 Flutter 图片源。组件和启动预缓存共用这个映射，保证窗口恢复与
/// 侧栏显示不会再次分叉。
ImageProvider<Object> appIconImageProvider(AppIconSelection selection) {
  if (selection.usesCustomFile) {
    return ResizeImage(
      FileImage(File(selection.customPath!)),
      width: appIconDecodePixelWidth,
      allowUpscaling: false,
    );
  }
  return AssetImage(
    windowIconAssetForPreset(selection.presetKey) ??
        presetIconAssets['default']!,
  );
}

/// 发布新的当前选择，并在发布前逐出旧图片缓存。
///
/// 逐出必须住在这里而不是调用方：自定义图标的落盘路径是**固定**的
/// （app support 下同一个文件名），换图后 [FileImage] 的 key 一模一样，
/// `imageCache.putIfAbsent` 会直接把上一张图的解码结果还回来——新 revision
/// 只能让组件重新 resolve，拦不住缓存命中。两级都要逐：裸 [FileImage] 的 key
/// 和外层 [ResizeImage] 的 key 不是同一个。
///
/// 曾经它写在 [saveAppIconSelection] 里，于是「偏好落盘失败 → 直接 publish」
/// 那条兜底路径绕过了逐出，用户第二次换自定义图时 rail 仍显示第一张。收进这个
/// 唯一发布点后，任何调用方都不可能再漏掉。
Future<AppIconSelection> publishAppIconSelection(
  AppIconSelection selection,
) async {
  final AppIconSelection resolved = resolveAppIconSelection(
    presetKey: selection.presetKey,
    customPath: selection.customPath,
  ).withRevision(currentAppIconSelection.value.revision + 1);
  if (resolved.usesCustomFile) {
    await FileImage(File(resolved.customPath!)).evict();
    await appIconImageProvider(resolved).evict();
  }
  currentAppIconSelection.value = resolved;
  return resolved;
}

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

/// 读取并发布已持久化的选择。主入口在 runApp 前调用，侧栏第一帧即可显示正确图标。
Future<AppIconSelection> loadAppIconSelection() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return publishAppIconSelection(
    resolveAppIconSelection(
      presetKey: prefs.getString(iconPresetPrefKey) ?? 'default',
      customPath: prefs.getString(iconCustomPathPrefKey),
    ),
  );
}

/// 顺序保存并发布当前选择。通知只发生在偏好写入成功之后；缓存逐出与 revision
/// 递增都在 [publishAppIconSelection] 里完成。调用方在原生图标已切换而持久化
/// 失败时负责改调 [publishAppIconSelection] 发布本次运行态。
Future<AppIconSelection> saveAppIconSelection(
  AppIconSelection selection,
) async {
  final AppIconSelection resolved = resolveAppIconSelection(
    presetKey: selection.presetKey,
    customPath: selection.customPath,
  );
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (resolved.usesCustomFile) {
    final bool customPathSaved = await prefs.setString(
      iconCustomPathPrefKey,
      resolved.customPath!,
    );
    if (!customPathSaved) {
      throw StateError('Failed to persist the custom app icon path.');
    }
  }
  final bool presetSaved = await prefs.setString(
    iconPresetPrefKey,
    resolved.presetKey,
  );
  if (!presetSaved) {
    throw StateError('Failed to persist the app icon preset.');
  }
  return publishAppIconSelection(resolved);
}
