import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 真 FFI 走一遍游戏 OCR 台词流的判定核心（ocrline.rs）：整窗 PNG → 裁框 → action，
/// OCR 文本 → 去重 / 续写。判定细节的穷举在 Rust 单元测试里，这里守 ABI 与数据往返。
void main() {
  test('PNG frame: settle → OCR crop → idle → cleared', () {
    final FfcOcrLineTracker tracker = FfcOcrLineTracker();
    addTearDown(tracker.close);
    final Uint8List withText = _png(400, 200, textRows: (150, 170));
    final Uint8List blank = _png(400, 200);

    FfcOcrLineFrame feed(Uint8List png) =>
        tracker.feedPng(png, left: 0, top: 0.5, width: 1, height: 0.5);

    expect(feed(withText).action, FfcOcrLineFrameAction.settling);
    final FfcOcrLineFrame ocr = feed(withText);
    expect(ocr.action, FfcOcrLineFrameAction.ocr);
    expect((ocr.width, ocr.height), (400, 100));
    expect(ocr.rgba!.length, 400 * 100 * 4);
    expect(feed(withText).action, FfcOcrLineFrameAction.idle);
    expect(feed(blank).action, FfcOcrLineFrameAction.cleared);
  });

  test('feedPngAt works by address (background isolate path)', () {
    final FfcOcrLineTracker tracker = FfcOcrLineTracker();
    addTearDown(tracker.close);
    final Uint8List png = _png(100, 40, textRows: (10, 30));
    FfcOcrLineFrame feed() => FfcOcrLineTracker.feedPngAt(
      tracker.address,
      png,
      left: 0,
      top: 0,
      width: 1,
      height: 1,
    );
    expect(feed().action, FfcOcrLineFrameAction.settling);
    expect(feed().action, FfcOcrLineFrameAction.ocr);
  });

  test('bad PNG / region outside the frame throw', () {
    final FfcOcrLineTracker tracker = FfcOcrLineTracker();
    addTearDown(tracker.close);
    expect(
      () => tracker.feedPng(
        Uint8List.fromList(<int>[1, 2, 3]),
        left: 0,
        top: 0,
        width: 1,
        height: 1,
      ),
      throwsFormatException,
    );
    expect(
      () => tracker.feedPng(_png(10, 10), left: 2, top: 2, width: 1, height: 1),
      throwsArgumentError,
    );
  });

  test('text: CJK spacing removed, dedup, extend, empty', () {
    final FfcOcrLineTracker tracker = FfcOcrLineTracker();
    addTearDown(tracker.close);
    expect(tracker.feedText('今日は と て も\nいい天気ですね'), (
      kind: FfcOcrLineTextKind.newLine,
      text: '今日はとてもいい天気ですね',
    ));
    expect(
      tracker.feedText('今日はとてもいい天気ですね').kind,
      FfcOcrLineTextKind.duplicate,
    );
    expect(tracker.feedText('今日はとてもいい天気ですね、散歩に行こう'), (
      kind: FfcOcrLineTextKind.extend,
      text: '今日はとてもいい天気ですね、散歩に行こう',
    ));
    expect(tracker.feedText('  ').kind, FfcOcrLineTextKind.empty);
    tracker.reset();
    expect(tracker.feedText('はい').kind, FfcOcrLineTextKind.newLine);
  });

  test('closed tracker refuses calls', () {
    final FfcOcrLineTracker tracker = FfcOcrLineTracker()..close();
    tracker.close();
    expect(() => tracker.feedText('x'), throwsStateError);
  });
}

/// 白底 RGBA PNG；[textRows] 给出时在这些行上画间隔的黑竖条（模拟一行字）。
Uint8List _png(int width, int height, {(int, int)? textRows}) {
  final BytesBuilder raw = BytesBuilder();
  for (int y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    for (int x = 0; x < width; x++) {
      final bool ink =
          textRows != null &&
          y >= textRows.$1 &&
          y < textRows.$2 &&
          x >= 4 &&
          (x - 4) % 8 < 4;
      final int v = ink ? 0 : 255;
      raw.add(<int>[v, v, v, 255]);
    }
  }
  final BytesBuilder out = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final List<int> typeBytes = type.codeUnits;
    out.add(_u32(data.length));
    out.add(typeBytes);
    out.add(data);
    out.add(_u32(_crc32(<int>[...typeBytes, ...data])));
  }

  chunk('IHDR', <int>[..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibCodec().encode(raw.takeBytes()));
  chunk('IEND', const <int>[]);
  return out.takeBytes();
}

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

int _crc32(List<int> bytes) {
  int crc = 0xffffffff;
  for (final int b in bytes) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
