import 'dart:typed_data';

/// 封面写侧唯一入口只收「可解码」字节（BUG-2496，`isDecodableImageBytes`）：JPEG 要
/// `FF D8 FF … FF D9`、PNG 要以 IEND chunk 收尾。测试里「随便几个字节当封面」的
/// fixture 自那之后都会被拒收、不落盘——这里造最小合法外形的假图，内容仍是填充，
/// 便于按字节断言「写进去的就是下载到的」。
Uint8List fakeJpegBytes({int length = 64, int fill = 4}) {
  assert(length >= 5);
  return Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    0xFF,
    ...List<int>.filled(length - 5, fill),
    0xFF,
    0xD9,
  ]);
}

Uint8List fakePngBytes({int length = 64, int fill = 7}) {
  const List<int> magic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  const List<int> iend = <int>[0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82];
  assert(length >= magic.length + iend.length);
  return Uint8List.fromList(<int>[
    ...magic,
    ...List<int>.filled(length - magic.length - iend.length, fill),
    ...iend,
  ]);
}
