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

/// 记录调用并返回可配置结果的假 file_picker 实现（extends 以拿到 token 校验）。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker([this.result]);

  /// `null` = 用户取消；否则原样返回（可构造空 files / 空 path 的病态结果）。
  final FilePickerResult? result;

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
    return result;
  }
}

/// 正常结果：一张有真实 path 的图。
FilePickerResult _okResult() => FilePickerResult(<PlatformFile>[
      PlatformFile(name: 'cover.png', size: 0, path: 'C:/tmp/cover.png'),
    ]);

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

    final _FakeFilePicker fakePicker = _FakeFilePicker(_okResult());
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

  // 「没选到图」的病态结果必须一律收敛成 null，不得抛异常。
  //
  // 回归背景：P3 统一封面服务把三岛的选图守卫收进本入口后，
  // `games_library_page._setCover` 原有的 `picked.files.isNotEmpty` 守卫被删掉，
  // 只剩 `if (picked == null) return;`。若入口里写成 `result?.files.first.path`，
  // file_picker 返回「非 null 但空 list」时 `.first` 抛 StateError——
  // async onTap 无人捕获，用户点「设置封面」直接吞掉（甚至崩到 zone error）。
  group('空结果一律返回 null（不抛 StateError）', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('用户取消（result == null）', () async {
      FilePicker.platform = _FakeFilePicker();
      expect(await pickGalleryImageFile(), isNull);
    });

    test('结果集为空 list（.first 会抛 StateError 的形态）', () async {
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult(const <PlatformFile>[]));
      await expectLater(pickGalleryImageFile(), completion(isNull));
    });

    test('条目无 path（path == null）', () async {
      FilePicker.platform = _FakeFilePicker(FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'cover.png', size: 0),
      ]));
      expect(await pickGalleryImageFile(), isNull);
    });

    test('条目 path 是空串', () async {
      FilePicker.platform = _FakeFilePicker(FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'cover.png', size: 0, path: ''),
      ]));
      expect(await pickGalleryImageFile(), isNull);
    });
  });
}
