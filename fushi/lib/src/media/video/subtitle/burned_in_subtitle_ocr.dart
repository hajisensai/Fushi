/// 视频字幕生成读画面硬字幕的宿主 OCR（引擎端口 [SubtitleFrameTextReader]，拍板台
/// `d-fO4eGxKx`）：用设置里选的本机 OCR 模型（离线、不上传），走截屏识字同一个入口
/// [LocalScreenOcr]（PP 行检测 + 逐行识别，会话常驻复用、空闲自动释放）。
///
/// 只把画面下方的字幕带（[kSubtitleBurnedInBandTop] 以下）交给 OCR：字少、图小，一帧
/// 快得多；行坐标再换回整帧的归一化坐标交给引擎挑台词行。
///
/// 模型没下载 / 平台不支持本机 OCR（移动端）时 [identity] 返回 null，管线不读硬字幕。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/manga_ocr_provider.dart'
    show createMangaOcrService;
import 'package:fushi/src/ocr/local_screen_ocr.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_burned_in_evidence.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:image/image.dart' as img;

/// 生产实现：[modelKey] 现读设置里的本机 OCR 模型（换了模型下一次调用就跟着换）。
class AppBurnedInSubtitleOcr implements SubtitleFrameTextReader {
  AppBurnedInSubtitleOcr({
    required String Function() modelKey,
    LocalScreenOcr Function(String modelKey)? ocrFor,
  }) : _modelKey = modelKey,
       _ocrFor = ocrFor ?? _defaultOcr;

  final String Function() _modelKey;
  final LocalScreenOcr Function(String modelKey) _ocrFor;

  String? _key;
  LocalScreenOcr? _ocr;

  static LocalScreenOcr _defaultOcr(String modelKey) => LocalScreenOcr(
    createMangaOcrService(localModel: MangaOcrLocalModel.forPlatform(modelKey)),
  );

  LocalScreenOcr _current() {
    final String key = _modelKey();
    final LocalScreenOcr? ocr = _ocr;
    if (ocr != null && key == _key) return ocr;
    if (ocr != null) unawaited(ocr.dispose());
    _key = key;
    return _ocr = _ocrFor(key);
  }

  @override
  Future<String?> identity() async {
    final LocalScreenOcr ocr = _current();
    return await ocr.isAvailable() ? 'local-ocr:$_key' : null;
  }

  @override
  Future<List<SubtitleFrameTextLine>> read(Uint8List frame) async {
    final SubtitleBandCrop? band = await Isolate.run(
      () => cropSubtitleBand(frame),
    );
    if (band == null) {
      throw const FormatException('video frame could not be decoded');
    }
    final SystemOcrPageResult page = await _current().recognize(
      band.bytes,
      language: 'ja',
    );
    return subtitleFrameLinesFromBand(page, band);
  }
}

/// 字幕带裁剪结果：[bytes] 是裁出的 BMP，[top] 是裁剪上沿（整帧像素），[frameWidth]
/// / [frameHeight] 是整帧尺寸。
class SubtitleBandCrop {
  const SubtitleBandCrop({
    required this.bytes,
    required this.top,
    required this.frameWidth,
    required this.frameHeight,
  });

  final Uint8List bytes;
  final int top;
  final int frameWidth;
  final int frameHeight;
}

/// 解码一帧、裁出 [kSubtitleBurnedInBandTop] 以下的字幕带；解不了返回 null。
SubtitleBandCrop? cropSubtitleBand(Uint8List frame) {
  final img.Image? image;
  try {
    image = img.decodeImage(frame);
  } on Object {
    return null;
  }
  if (image == null || image.width <= 0 || image.height <= 0) return null;
  final int top = (image.height * kSubtitleBurnedInBandTop).floor();
  final img.Image band = img.copyCrop(
    image,
    x: 0,
    y: top,
    width: image.width,
    height: image.height - top,
  );
  return SubtitleBandCrop(
    bytes: img.encodeBmp(band),
    top: top,
    frameWidth: image.width,
    frameHeight: image.height,
  );
}

/// 字幕带上的 OCR 行（带内像素）→ 整帧归一化坐标的行。
List<SubtitleFrameTextLine> subtitleFrameLinesFromBand(
  SystemOcrPageResult page,
  SubtitleBandCrop band,
) {
  final double w = band.frameWidth.toDouble();
  final double h = band.frameHeight.toDouble();
  return <SubtitleFrameTextLine>[
    for (final SystemOcrTextLine line in page.lines)
      if (!line.isVertical)
        SubtitleFrameTextLine(
          text: line.text,
          left: line.rect.left / w,
          right: line.rect.right / w,
          top: (band.top + line.rect.top) / h,
          bottom: (band.top + line.rect.bottom) / h,
        ),
  ];
}
