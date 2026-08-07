import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:network_to_file_image/network_to_file_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/utils/misc/gallery_image_picker.dart';

/// An enhancement that can be used to select a picture with the
class PickImageEnhancement extends ImageEnhancement {
  /// Initialise this enhancement with the hardset parameters.
  PickImageEnhancement()
      : super(
          uniqueKey: key,
          label: 'Pick Image',
          description: 'Pick a new image to use with an external picker.',
          icon: Icons.upload_file_outlined,
          field: ImageField.instance,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'pick_image';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_pick_image;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    ImageExportField imageField = field as ImageExportField;
    // BUG-1074：桌面端 image_picker 无平台实现（MissingPluginException），
    // 统一走平台感知入口：移动端相册、桌面端 file_picker 文件对话框。
    final File? pickedFile = await pickGalleryImageFile();

    if (pickedFile == null) {
      return;
    }

    Directory appDirDoc = await getApplicationSupportDirectory();
    String pickImagePath = '${appDirDoc.path}/imagePicker';
    Directory pickImageDir = Directory(pickImagePath);
    if (pickImageDir.existsSync()) {
      pickImageDir.deleteSync(recursive: true);
    }
    pickImageDir.createSync(recursive: true);

    String timestamp = DateFormat('yyyyMMddTkkmmss').format(DateTime.now());
    Directory imageDir = Directory('$pickImagePath/$timestamp');
    String imagePath = '${imageDir.path}/image';
    imageDir.createSync(recursive: true);

    // 与旧 XFile.saveTo 等价：把选中文件复制到 app 私有目录再引用副本。
    await pickedFile.copy(imagePath);
    File pickedImage = File(imagePath);

    await imageField.setImages(
      cause: cause,
      appModel: appModel,
      creatorModel: creatorModel,
      newAutoCannotOverride: false,
      generateImages: () async {
        List<NetworkToFileImage> images = [
          NetworkToFileImage(file: pickedImage),
        ];

        return images;
      },
    );
  }
}
