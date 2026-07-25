import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// 「从相册 / 文件系统选一张图片」的平台感知统一入口（BUG-1074）。
///
/// 为什么不能到处直接调 `ImagePicker().pickImage(...)`：本仓钉的
/// image_picker 0.8.7+5 只带 android / ios / for_web 三个平台实现
/// （见 pubspec.lock，没有 image_picker_windows / _macos / _linux）。
/// 桌面端没有任何实现注册 `ImagePickerPlatform.instance`，它保持默认的
/// `MethodChannelImagePicker`（image_picker_platform_interface-2.9.2
/// `image_picker_platform.dart:26`），`pickImage` 最终走
/// `_channel.invokeMethod('pickImage', ...)`（`method_channel_image_picker.dart:107`，
/// channel `plugins.flutter.io/image_picker`）——桌面原生侧无 handler，
/// 直接抛 `MissingPluginException`。异常在 async onTap 里无人捕获，
/// UI 零反馈，表现为「点了没反应」。
///
/// 取舍：不升级 image_picker、也不新增 image_picker_windows 依赖（老
/// Flutter 钉版环境，升级爆炸半径大）；file_picker 已是本仓直接依赖、
/// 带全部桌面实现，且本就是既有的桌面文件选取路径（见
/// `real_path_directory_picker.dart` / `miscellaneous_settings_page.dart`）。
/// 因此：移动端（Android/iOS）维持 image_picker 的系统相册体验；桌面端
/// （Windows/macOS/Linux）走 file_picker 的 `FileType.image` 原生文件对话框。
///
/// 相机拍照（`ImageSource.camera`）不在本入口范围内——它没有 file_picker
/// 等价物，且唯一调用点 `camera_enhancement.dart` 已有 `isMobilePlatform`
/// 门禁，桌面不可达。
enum GalleryImagePickerBackend {
  /// 移动端：image_picker 系统相册。
  imagePicker,

  /// 桌面端：file_picker 原生文件对话框（`FileType.image`）。
  filePicker,
}

/// 按平台决定图片选取后端。纯函数，供 [pickGalleryImageFile] 与单测共用。
GalleryImagePickerBackend galleryImagePickerBackendFor(
  TargetPlatform platform,
) {
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return GalleryImagePickerBackend.imagePicker;
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return GalleryImagePickerBackend.filePicker;
  }
}

/// 选一张图片并返回其 [File]；用户取消返回 null。
///
/// 移动端返回的是 image_picker 复制到 app cache 的副本路径（与旧行为一致，
/// 调用方应按「单次会话内使用 / 自行落盘持久化」处理）；桌面端返回
/// file_picker 给出的真实文件路径。
Future<File?> pickGalleryImageFile() async {
  switch (galleryImagePickerBackendFor(defaultTargetPlatform)) {
    case GalleryImagePickerBackend.imagePicker:
      final XFile? pickedFile =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      return pickedFile == null ? null : File(pickedFile.path);
    case GalleryImagePickerBackend.filePicker:
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      final String? pickedPath = result?.files.first.path;
      return pickedPath == null ? null : File(pickedPath);
  }
}
