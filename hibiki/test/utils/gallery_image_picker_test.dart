// BUG-1074：桌面端 image_picker 无平台实现（pubspec.lock 只有 android/ios/
// for_web），`ImagePicker().pickImage` 走默认 MethodChannel 直接抛
// MissingPluginException → 书架编辑弹窗「更新封面」点了没反应。
// 本测试守住平台感知入口 `pickGalleryImageFile` 的分流不变式：
// 桌面平台必须走 file_picker，绝不触碰 image_picker 的 MethodChannel。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/gallery_image_picker.dart';

/// 记录调用并返回固定结果的假 file_picker 实现（extends 以拿到 token 校验）。
class _FakeFilePicker extends FilePicker {
  FileType? lastType;
  bool? lastAllowMultiple;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastType = type;
    lastAllowMultiple = allowMultiple;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(name: 'cover.png', size: 0, path: 'C:/tmp/cover.png'),
    ]);
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('galleryImagePickerBackendFor 平台分流', () {
    test('移动端（Android/iOS）走 image_picker 相册', () {
      expect(
        galleryImagePickerBackendFor(TargetPlatform.android),
        GalleryImagePickerBackend.imagePicker,
      );
      expect(
        galleryImagePickerBackendFor(TargetPlatform.iOS),
        GalleryImagePickerBackend.imagePicker,
      );
    });

    test('桌面端（Windows/macOS/Linux/fuchsia）走 file_picker', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          galleryImagePickerBackendFor(platform),
          GalleryImagePickerBackend.filePicker,
          reason: '$platform 必须走 file_picker（image_picker 无桌面实现）',
        );
      }
    });
  });

  test('Windows 平台 pickGalleryImageFile 走 file_picker，不触碰 image_picker 通道',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    // 哨兵：一旦有人把 image_picker 的默认 MethodChannel 路径带回桌面分支，
    // 这里立即暴露（而不是靠真机上的 MissingPluginException 静默失败）。
    const MethodChannel imagePickerChannel =
        MethodChannel('plugins.flutter.io/image_picker');
    bool imagePickerChannelCalled = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      imagePickerChannel,
      (MethodCall call) async {
        imagePickerChannelCalled = true;
        return null;
      },
    );
    addTearDown(() => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(imagePickerChannel, null));

    final _FakeFilePicker fakePicker = _FakeFilePicker();
    FilePicker.platform = fakePicker;

    final File? picked = await pickGalleryImageFile();

    expect(picked, isNotNull);
    expect(picked!.path, 'C:/tmp/cover.png');
    expect(fakePicker.lastType, FileType.image, reason: '桌面端必须限定图片类型');
    expect(fakePicker.lastAllowMultiple, isFalse);
    expect(
      imagePickerChannelCalled,
      isFalse,
      reason: '桌面分支不得触碰 image_picker MethodChannel（BUG-1074 根因）',
    );
  });
}
