import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog when using the crop image enhancement.
class CropImageDialogPage extends BasePage {
  /// Create an instance of this page.
  const CropImageDialogPage({
    required this.imageFile,
    required this.onCrop,
    super.key,
  });

  /// Initial file.
  final File imageFile;

  /// On crop action.
  final Function(File) onCrop;

  @override
  BasePageState createState() => _CropImageDialogPageState();
}

class _CropImageDialogPageState extends BasePageState<CropImageDialogPage> {
  final CropController _controller = CropController();

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.creator_enhancement_crop_image,
        leadingIcon: Icons.crop_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: SizedBox(
          width: double.maxFinite,
          child: buildContent(),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }

  List<Widget> get actions => [
        buildCancelButton(),
        buildCropButton(),
      ];

  Widget buildContent() {
    return Center(
      child: CropImage(
          minimumImageSize: 25,
          gridColor: Theme.of(context).colorScheme.onSurfaceVariant,
          controller: _controller,
          image: Image(image: FileImage(widget.imageFile))),
    );
  }

  Widget buildCropButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeCrop,
      child: Text(t.dialog_crop),
    );
  }

  Widget buildCancelButton() {
    return adaptiveDialogAction(
      context: context,
      child: Text(t.dialog_cancel),
      onPressed: () => Navigator.pop(context),
    );
  }

  void executeCrop() async {
    final navigator = Navigator.of(context);
    Directory appDirDoc = await getApplicationSupportDirectory();
    String cropImagePath = '${appDirDoc.path}/crop';
    Directory cropImageDir = Directory(cropImagePath);
    if (cropImageDir.existsSync()) {
      cropImageDir.deleteSync(recursive: true);
    }
    cropImageDir.createSync(recursive: true);

    String timestamp = DateFormat('yyyyMMddTkkmmss').format(DateTime.now());
    Directory imageDir = Directory('$cropImagePath/$timestamp');
    ui.Image croppedImage = await _controller.croppedBitmap();
    ByteData? data =
        await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    Uint8List bytes = data!.buffer.asUint8List();

    String imagePath = '${imageDir.path}/cropped';
    File imageFile = File(imagePath);
    imageFile.createSync(recursive: true);
    imageFile.writeAsBytesSync(bytes);

    widget.onCrop(imageFile);
    navigator.pop();
  }
}
