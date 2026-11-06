import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/popup_channel.dart';
import 'package:image/image.dart' as img;

/// 反馈 Gz7z6Y6Mbr：截屏识字 / 拍照查词制卡带图——卡图取所点文字所在文本块并留白、
/// 按制卡图片质量档缩放，四条识字链路共用本模块。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('screenOcrTextBlockRect（只有行框的平台把同一段文字并成块）', () {
    ScreenOcrLineBox h(double l, double t, double r, double b) =>
        (rect: Rect.fromLTRB(l, t, r, b), vertical: false);
    ScreenOcrLineBox v(double l, double t, double r, double b) =>
        (rect: Rect.fromLTRB(l, t, r, b), vertical: true);

    test('横排：行距不超过一个行高、左右有重叠的相邻行并成一块（逐步扩张）', () {
      final List<ScreenOcrLineBox> lines = <ScreenOcrLineBox>[
        h(100, 100, 500, 130), // 0
        h(100, 140, 480, 170), // 1：紧挨 0
        h(100, 180, 300, 210), // 2：紧挨 1（与 0 不相邻，靠扩张并入）
        h(100, 400, 500, 430), // 3：隔得远，另一段
        h(700, 100, 900, 130), // 4：同一高度但左右不重叠，另一栏
      ];
      expect(
        screenOcrTextBlockRect(lines: lines, hitIndex: 0),
        const Rect.fromLTRB(100, 100, 500, 210),
      );
      expect(
        screenOcrTextBlockRect(lines: lines, hitIndex: 3),
        const Rect.fromLTRB(100, 400, 500, 430),
      );
    });

    test('竖排：左右相邻的列并成一块；横排行与粗细差太多的行不并入', () {
      final List<ScreenOcrLineBox> lines = <ScreenOcrLineBox>[
        v(400, 100, 430, 500), // 0
        v(360, 100, 390, 420), // 1：紧挨 0 的左边
        h(360, 520, 430, 550), // 2：横排，不并
        v(300, 100, 350, 500), // 3：粗细 50（> 1.6×30），不并
      ];
      expect(
        screenOcrTextBlockRect(lines: lines, hitIndex: 0),
        const Rect.fromLTRB(360, 100, 430, 500),
      );
    });
  });

  group('screenOcrCardCropRect（留白 + 夹进图内）', () {
    test('四周留出 1.5 倍行粗', () {
      expect(
        screenOcrCardCropRect(
          textBlock: const Rect.fromLTRB(400, 400, 600, 500),
          line: const Rect.fromLTRB(400, 400, 600, 420),
          image: const Size(1000, 1000),
        ),
        const Rect.fromLTRB(370, 370, 630, 530),
      );
    });

    test('行很细时至少留图短边的 2%；贴边时夹进图内', () {
      expect(
        screenOcrCardCropRect(
          textBlock: const Rect.fromLTRB(0, 10, 300, 14),
          line: const Rect.fromLTRB(0, 10, 300, 14),
          image: const Size(2000, 1000),
        ),
        const Rect.fromLTRB(0, 0, 320, 34),
      );
    });
  });

  group('writeScreenOcrCardImage（与漫画卡图同一裁切内核）', () {
    test('从截图裁出文本块 + 留白，长边按质量档缩放，写成独立临时文件', () async {
      final img.Image page = img.Image(width: 1200, height: 800);
      img.fill(page, color: img.ColorRgb8(255, 255, 255));
      final Uint8List png = img.encodePng(page);
      final ScreenOcrCardImage source = ScreenOcrCardImage(
        bytes: png,
        textBlock: const Rect.fromLTRB(100, 100, 700, 300),
        line: const Rect.fromLTRB(100, 100, 700, 140),
      );
      final ({String path, Directory dir})? out = await writeScreenOcrCardImage(
        source,
        imageTier: 3,
      );
      expect(out, isNotNull);
      addTearDown(() => deleteScreenOcrCardDir(out!.dir));
      final img.Image card = img.decodeImage(
        await File(out!.path).readAsBytes(),
      )!;
      // 留白 = max(40×1.5, 800×0.02) = 60：裁框 (40,40)-(760,360) = 720×320。
      expect(card.width / card.height, closeTo(720 / 320, 0.02));
      expect(out.path.endsWith('.png'), isTrue, reason: '源是 PNG 保持 PNG');
    });

    test('Android 定格帧文件已不在（被下一次截屏清掉）：不带图，不抛', () async {
      final ScreenOcrCardImage source = ScreenOcrCardImage(
        path: '${Directory.systemTemp.path}/fushi-missing-frame-x.jpg',
        textBlock: const Rect.fromLTRB(0, 0, 10, 10),
        line: const Rect.fromLTRB(0, 0, 10, 10),
      );
      expect(await writeScreenOcrCardImage(source, imageTier: 2), isNull);
    });
  });

  test('screenOcrCardImageForHit：用识别图 + 并出来的文本块 + 被点行', () {
    const SystemOcrTextLine a = SystemOcrTextLine(
      text: '吾輩は',
      rect: Rect.fromLTRB(100, 100, 400, 130),
      isVertical: false,
    );
    const SystemOcrTextLine b = SystemOcrTextLine(
      text: '猫である',
      rect: Rect.fromLTRB(100, 140, 380, 170),
      isVertical: false,
    );
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final ScreenOcrCardImage image = screenOcrCardImageForHit(
      bytes: bytes,
      lines: const <SystemOcrTextLine>[a, b],
      hit: b,
    );
    expect(image.bytes, same(bytes));
    expect(image.textBlock, const Rect.fromLTRB(100, 100, 400, 170));
    expect(image.line, b.rect);
  });

  group('PopupChannel：Android 截屏识字把卡图来源带进查词窗', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.popup, null);
    });

    test('冷启动载荷带 cardImagePath / 块框 / 行框 → sourceBlock.cardImage', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.popup, (
            MethodCall call,
          ) async {
            if (call.method != 'getInitialProcessText') return null;
            return <String, Object?>{
              'text': '吾輩は猫',
              'charIndex': 0,
              'sourceBlock': '吾輩は猫',
              'sourceBlockOffset': 0,
              'cardImagePath': '/cache/screen_ocr_card/frame-1.jpg',
              'cardImageBlock': <int>[10, 20, 300, 80],
              'cardImageLine': <int>[10, 20, 300, 50],
            };
          });
      final PopupSourceBlock? block =
          (await PopupChannel.instance.getInitialProcessText()).sourceBlock;
      final ScreenOcrCardImage? image = block?.cardImage;
      expect(image, isNotNull);
      expect(image!.path, '/cache/screen_ocr_card/frame-1.jpg');
      expect(image.textBlock, const Rect.fromLTRB(10, 20, 300, 80));
      expect(image.line, const Rect.fromLTRB(10, 20, 300, 50));
    });

    test('「制卡带图」关着（原生不带图键）：cardImage 为 null，句子块照常', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.popup, (
            MethodCall call,
          ) async {
            return <String, Object?>{
              'text': '吾輩は猫',
              'charIndex': 0,
              'sourceBlock': '吾輩は猫',
              'sourceBlockOffset': 0,
            };
          });
      final PopupSourceBlock? block =
          (await PopupChannel.instance.getInitialProcessText()).sourceBlock;
      expect(block?.text, '吾輩は猫');
      expect(block?.cardImage, isNull);
    });
  });
}
