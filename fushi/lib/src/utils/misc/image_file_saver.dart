/// 「保存图片」的唯一实现：阅读器正文 / 阅读器与书架端插图册 / 缩放看图 /
/// 歌词模式插图共用（长按图片的全局动作见 `reader/image_actions_sheet.dart`）。
///
/// 平台分流：
/// - Android / iOS：写进系统相册（[gal]）。Android 10 及以下要
///   `WRITE_EXTERNAL_STORAGE`（manifest 里 `maxSdkVersion="29"`），11+ 走
///   MediaStore 无需权限、落在 `Pictures/Fushi`；iOS 只申请「仅添加」权限
///   （`NSPhotoLibraryAddUsageDescription`），不建相簿——建相簿要完整相册读写权限。
/// - 桌面：另存为对话框（默认文件名 = 原文件名），再复制过去；Linux 没有系统相册。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 保存目的地：系统相册或另存为文件。
enum ImageSaveDestination { gallery, file }

/// 一次保存的结局（[saveImageFileWithFeedback] 按它出提示）。
enum ImageSaveStatus { saved, cancelled, denied, unavailable, failed }

/// 保存结果：[path] 只在桌面另存为成功时有值；[error] 只在 failed 时有值。
class ImageSaveResult {
  const ImageSaveResult(this.status, {this.path, this.error});

  final ImageSaveStatus status;
  final String? path;
  final Object? error;
}

/// 纯函数：按平台选目的地。只有手机有「系统相册」这个用户心智；macOS 虽然
/// 有照片 App，但桌面用户长按 / 右键「保存图片」期待的是存成文件。
ImageSaveDestination imageSaveDestinationFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS => ImageSaveDestination.gallery,
      _ => ImageSaveDestination.file,
    };

/// Android 上落进的相簿名（`Pictures/<album>`）。iOS 传 null（见文件头）。
const String kImageSaveAndroidAlbum = 'Fushi';

/// 纯函数：另存为对话框的默认文件名——保留原名（EPUB 内插图名常是
/// `i-012.jpg` 这类，至少扩展名对）；没有扩展名时补 `.png` 让系统能认出是图。
String suggestedImageFileName(String sourcePath) {
  final String name = p.basename(sourcePath);
  if (name.isEmpty) return 'image.png';
  return p.extension(name).isEmpty ? '$name.png' : name;
}

/// 平台后端：测试替换它，生产用 [PlatformImageFileSaver]。
abstract class ImageFileSaver {
  Future<ImageSaveResult> save(File file);
}

/// 生产实现：相册走 [gal]，文件走 [FilePicker.saveFile]。
class PlatformImageFileSaver implements ImageFileSaver {
  const PlatformImageFileSaver({required this.destination, this.album});

  final ImageSaveDestination destination;

  /// 相册内的相簿名；null = 写进相册根（iOS）。
  final String? album;

  @override
  Future<ImageSaveResult> save(File file) async {
    if (!file.existsSync()) {
      return const ImageSaveResult(ImageSaveStatus.unavailable);
    }
    return switch (destination) {
      ImageSaveDestination.gallery => _saveToGallery(file),
      ImageSaveDestination.file => _saveAs(file),
    };
  }

  Future<ImageSaveResult> _saveToGallery(File file) async {
    final bool toAlbum = album != null;
    try {
      if (!await Gal.hasAccess(toAlbum: toAlbum) &&
          !await Gal.requestAccess(toAlbum: toAlbum)) {
        return const ImageSaveResult(ImageSaveStatus.denied);
      }
      await Gal.putImage(file.path, album: album);
      return const ImageSaveResult(ImageSaveStatus.saved);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        return const ImageSaveResult(ImageSaveStatus.denied);
      }
      return ImageSaveResult(ImageSaveStatus.failed, error: e.type.message);
    }
  }

  Future<ImageSaveResult> _saveAs(File file) async {
    final String name = suggestedImageFileName(file.path);
    final String ext = p.extension(name).replaceFirst('.', '');
    final String? target = await FilePicker.platform.saveFile(
      dialogTitle: t.reader_image_save,
      fileName: name,
      type: ext.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: ext.isEmpty ? null : <String>[ext],
    );
    if (target == null || target.trim().isEmpty) {
      return const ImageSaveResult(ImageSaveStatus.cancelled);
    }
    await file.copy(target);
    return ImageSaveResult(ImageSaveStatus.saved, path: target);
  }
}

/// 当前平台的默认保存后端。
ImageFileSaver defaultImageFileSaver() {
  final TargetPlatform platform = defaultTargetPlatformForImageSave();
  final ImageSaveDestination destination = imageSaveDestinationFor(platform);
  return PlatformImageFileSaver(
    destination: destination,
    album: platform == TargetPlatform.android ? kImageSaveAndroidAlbum : null,
  );
}

/// 测试注入口：非 null 时 [saveImageFileWithFeedback] 用它而不是平台后端。
ImageFileSaver? debugImageFileSaverOverride;

/// 当前宿主平台（不读 Theme：保存去哪由真实操作系统决定，不随设计系统变）。
TargetPlatform defaultTargetPlatformForImageSave() {
  if (Platform.isAndroid) return TargetPlatform.android;
  if (Platform.isIOS) return TargetPlatform.iOS;
  if (Platform.isMacOS) return TargetPlatform.macOS;
  if (Platform.isWindows) return TargetPlatform.windows;
  return TargetPlatform.linux;
}

/// 保存一张图并按结局出 toast；返回结局供调用方（和测试）判断。
Future<ImageSaveResult> saveImageFileWithFeedback(File file) async {
  final ImageFileSaver saver =
      debugImageFileSaverOverride ?? defaultImageFileSaver();
  ImageSaveResult result;
  try {
    result = await saver.save(file);
  } catch (e, stack) {
    ErrorLogService.instance.log('ImageFileSaver.save', e, stack);
    result = ImageSaveResult(ImageSaveStatus.failed, error: e);
  }
  switch (result.status) {
    case ImageSaveStatus.saved:
      final String? path = result.path;
      FushiToast.show(
        msg: path == null
            ? t.reader_image_save_done_gallery
            : t.reader_image_save_done_file(path: path),
        severity: ToastSeverity.success,
      );
    case ImageSaveStatus.cancelled:
      break;
    case ImageSaveStatus.denied:
      FushiToast.show(
        msg: t.reader_image_save_denied,
        severity: ToastSeverity.error,
      );
    case ImageSaveStatus.unavailable:
      FushiToast.show(
        msg: t.reader_image_file_unavailable,
        severity: ToastSeverity.error,
      );
    case ImageSaveStatus.failed:
      FushiToast.show(
        msg: t.reader_image_save_failed(error: result.error ?? ''),
        severity: ToastSeverity.error,
      );
  }
  return result;
}
