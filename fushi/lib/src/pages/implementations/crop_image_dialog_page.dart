import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

/// The content of the dialog when using the crop image enhancement.
class CropImageDialogPage extends BasePage {
  /// Create an instance of this page.
  const CropImageDialogPage({
    required this.imageFile,
    required this.onCrop,
    this.aspectRatio,
    super.key,
  });

  /// Initial file.
  final File imageFile;

  /// On crop action.
  final Function(File) onCrop;

  /// 锁定裁剪框宽高比；null = 自由裁剪。
  ///
  /// 应用图标传 1：图标最终是按正方形渲染的，自由裁出来的长条会被系统拉伸变形，
  /// 用户以为自己裁歪了。
  final double? aspectRatio;

  @override
  BasePageState createState() => _CropImageDialogPageState();
}

class _CropImageDialogPageState extends BasePageState<CropImageDialogPage> {
  late final CropController _controller =
      CropController(aspectRatio: widget.aspectRatio);
  late final ImageProvider _provider = FileImage(widget.imageFile);

  /// BUG-2496：[CropImage] 只拿传入 `Image` 的 provider 自己 `resolve`，从不把那个
  /// `Image` 挂进树，所以 `errorBuilder` 在这里是死代码；它自己挂的监听器又没有
  /// `onError`——坏文件（截断/非图片字节）解码失败时 completer 上没有任何错误监听者，
  /// 只能走 `FlutterError.reportError` 变成致命错误，裁剪框还永远转圈。这里由对话框
  /// 自己在同一个 completer 上挂带 `onError` 的监听者接住：留诊断痕迹、切成占位、
  /// 禁用「裁剪」。
  late final ImageStreamListener _decodeListener = ImageStreamListener(
    (ImageInfo _, bool __) {},
    onError: _onDecodeError,
  );
  ImageStream? _stream;
  Object? _decodeError;

  @override
  void initState() {
    super.initState();
    _stream = _provider.resolve(ImageConfiguration.empty)
      ..addListener(_decodeListener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_decodeListener);
    super.dispose();
  }

  void _onDecodeError(Object error, StackTrace? stack) {
    ErrorLogService.instance.logDiagnostic(
      'CropImageDialogPage.coverDecode',
      '${widget.imageFile.path}: $error',
    );
    if (!mounted) return;
    setState(() => _decodeError = error);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
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
    if (_decodeError != null) {
      return Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Center(
      child: CropImage(
          minimumImageSize: 25,
          gridColor: Theme.of(context).colorScheme.onSurfaceVariant,
          controller: _controller,
          image: Image(image: _provider)),
    );
  }

  Widget buildCropButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: _decodeError == null ? executeCrop : null,
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

/// 弹出裁剪对话框，返回裁好的文件；用户取消返回 null。
///
/// [CropImageDialogPage] 本身是回调式的（`onCrop` + 自己 pop），三个调用点各写一遍
/// 「用局部变量接住回调结果」很容易漏掉取消分支。这里收敛成一个 Future 接口。
Future<File?> showCropImageDialog(
  BuildContext context,
  File source, {
  double? aspectRatio,
}) async {
  File? cropped;
  await showAppDialog<void>(
    context: context,
    builder: (_) => CropImageDialogPage(
      imageFile: source,
      aspectRatio: aspectRatio,
      onCrop: (File file) => cropped = file,
    ),
  );
  return cropped;
}
