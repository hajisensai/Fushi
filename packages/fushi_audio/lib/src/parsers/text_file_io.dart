import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_charset_detector/flutter_charset_detector.dart';

/// 文本字节流的 Unicode 家族编码。由 BOM 或（无 BOM 时）字节分布启发式判定。
///
/// 只覆盖 Unicode 家族——Shift-JIS / CP932 / GBK / Big5 / EUC-JP 等传统多字节
/// 编码无法靠 BOM 或简单字节分布可靠区分，交给 [tryPlatformCharsetDecode]。
enum UnicodeTextEncoding {
  /// UTF-8，带 `EF BB BF` BOM。
  utf8Bom(bomLength: 3),

  /// UTF-16 小端，带 `FF FE` BOM。
  utf16leBom(bomLength: 2),

  /// UTF-16 大端，带 `FE FF` BOM。
  utf16beBom(bomLength: 2),

  /// UTF-32 小端，带 `FF FE 00 00` BOM。**必须先于 [utf16leBom] 判定**——
  /// 它的前两字节与 UTF-16LE BOM 完全相同，先判 UTF-16 会把 UTF-32 文本
  /// 解成一堆交替的 NUL 字符。
  utf32leBom(bomLength: 4),

  /// UTF-32 大端，带 `00 00 FE FF` BOM。
  utf32beBom(bomLength: 4),

  /// UTF-16 小端，**无 BOM**（启发式判定）。ASS/SRT 字幕的常见形态。
  utf16leBomless(bomLength: 0),

  /// UTF-16 大端，**无 BOM**（启发式判定）。
  utf16beBomless(bomLength: 0);

  const UnicodeTextEncoding({required this.bomLength});

  /// 该编码的 BOM 字节数；无 BOM 变体为 0。解码时需跳过这些字节。
  final int bomLength;
}

/// UTF-16 无 BOM 启发式的采样上限（字节）。取够判定分布即可，不必扫全文件。
const int _kHeuristicSampleBytes = 4096;

/// **纯函数**：按 BOM 判定 [bytes] 的编码。无可识别 BOM 时返回 null。
///
/// 判定顺序刻意让长 BOM 优先：`FF FE 00 00`（UTF-32LE）是 `FF FE`（UTF-16LE）
/// 的严格超集前缀，反过来判会把 UTF-32LE 误认成 UTF-16LE。
UnicodeTextEncoding? detectEncodingFromBom(List<int> bytes) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0xFF &&
        bytes[1] == 0xFE &&
        bytes[2] == 0x00 &&
        bytes[3] == 0x00) {
      return UnicodeTextEncoding.utf32leBom;
    }
    if (bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0xFE &&
        bytes[3] == 0xFF) {
      return UnicodeTextEncoding.utf32beBom;
    }
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return UnicodeTextEncoding.utf8Bom;
  }
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return UnicodeTextEncoding.utf16leBom;
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return UnicodeTextEncoding.utf16beBom;
    }
  }
  return null;
}

/// **纯函数**：无 BOM 时按字节分布判定 [bytes] 是否 UTF-16。不像 UTF-16 时返回 null。
///
/// 依据：字幕/播放列表这类文本以 ASCII（时间码、`Dialogue:`、标签、数字）为主，
/// 用 UTF-16 存时每个 ASCII 字符都会配一个 `0x00` 字节，且**固定落在同一奇偶位**
/// ——LE 在奇数位、BE 在偶数位。真正的 UTF-8 / 传统多字节文本几乎不含 `0x00`。
///
/// 判据（在前 [_kHeuristicSampleBytes] 字节内统计）：
/// - 某一奇偶位的 `0x00` 占该位字节数 **> 30%**；且
/// - 另一奇偶位的 `0x00` 占比 **< 5%**（否则是二进制垃圾，不是 UTF-16 文本）。
///
/// 阈值不取 50% 是为了容忍整行 CJK 的字幕（CJK 在 UTF-16 里两个字节都非零），
/// 但 ASS/SRT 必然含大量 ASCII 结构字符，30% 有充足余量。
UnicodeTextEncoding? detectBomlessUtf16(List<int> bytes) {
  final int limit = bytes.length < _kHeuristicSampleBytes
      ? bytes.length
      : _kHeuristicSampleBytes;
  // 少于 4 字节没有统计意义；奇数长度不可能是完整的 UTF-16 流。
  if (limit < 4 || bytes.length.isOdd) {
    return null;
  }
  final int pairs = limit ~/ 2;
  int zerosAtEven = 0;
  int zerosAtOdd = 0;
  for (int i = 0; i < pairs * 2; i += 2) {
    if (bytes[i] == 0x00) {
      zerosAtEven++;
    }
    if (bytes[i + 1] == 0x00) {
      zerosAtOdd++;
    }
  }
  final double evenRatio = zerosAtEven / pairs;
  final double oddRatio = zerosAtOdd / pairs;
  if (oddRatio > 0.30 && evenRatio < 0.05) {
    return UnicodeTextEncoding.utf16leBomless;
  }
  if (evenRatio > 0.30 && oddRatio < 0.05) {
    return UnicodeTextEncoding.utf16beBomless;
  }
  return null;
}

/// **纯函数**：按 [encoding] 解码 [bytes]（自动跳过 BOM 字节）。
///
/// [UnicodeTextEncoding.utf8Bom] 走**严格**解码，字节与 BOM 声明不符时抛
/// [FormatException]（现实中存在「加了 UTF-8 BOM 但正文是 CP932」的坏文件，
/// 那种应该继续交给字符集检测，而不是就地糊成 U+FFFD）。UTF-16 / UTF-32
/// 分支不会抛 [FormatException]。
///
/// UTF-16 走 [ByteData.getUint16] 逐 code unit 读，不用 `Uint16List.view`
/// ——后者受宿主字节序和 2 字节对齐约束，在大端机或非对齐偏移上会给出错误结果。
/// Dart 的 `String` 内部就是 UTF-16 code unit 序列，因此代理对（surrogate pair）
/// 原样透传即可，不需要额外拼接。
String decodeWithUnicodeEncoding(
    Uint8List bytes, UnicodeTextEncoding encoding) {
  final int offset = encoding.bomLength;
  switch (encoding) {
    case UnicodeTextEncoding.utf8Bom:
      return utf8.decode(Uint8List.sublistView(bytes, offset));
    case UnicodeTextEncoding.utf16leBom:
    case UnicodeTextEncoding.utf16leBomless:
      return _decodeUtf16(bytes, offset: offset, endian: Endian.little);
    case UnicodeTextEncoding.utf16beBom:
    case UnicodeTextEncoding.utf16beBomless:
      return _decodeUtf16(bytes, offset: offset, endian: Endian.big);
    case UnicodeTextEncoding.utf32leBom:
      return _decodeUtf32(bytes, offset: offset, endian: Endian.little);
    case UnicodeTextEncoding.utf32beBom:
      return _decodeUtf32(bytes, offset: offset, endian: Endian.big);
  }
}

String _decodeUtf16(Uint8List bytes,
    {required int offset, required Endian endian}) {
  final ByteData view = ByteData.sublistView(bytes, offset);
  final int units = view.lengthInBytes ~/ 2; // 末尾落单字节按截断文件忽略
  final Uint16List codeUnits = Uint16List(units);
  for (int i = 0; i < units; i++) {
    codeUnits[i] = view.getUint16(i * 2, endian);
  }
  return String.fromCharCodes(codeUnits);
}

String _decodeUtf32(Uint8List bytes,
    {required int offset, required Endian endian}) {
  final ByteData view = ByteData.sublistView(bytes, offset);
  final int units = view.lengthInBytes ~/ 4;
  final List<int> runes = <int>[];
  for (int i = 0; i < units; i++) {
    final int rune = view.getUint32(i * 4, endian);
    // 越界或代理区码位在 UTF-32 里非法；替换成 U+FFFD 而不是整体失败。
    runes.add(
      (rune > 0x10FFFF || (rune >= 0xD800 && rune <= 0xDFFF)) ? 0xFFFD : rune,
    );
  }
  return String.fromCharCodes(runes);
}

/// **纯函数**：不依赖任何平台插件地把 [bytes] 解成文本。
///
/// 顺序：BOM 判定 → 无 BOM UTF-16 启发式 → UTF-8 严格解码。
/// 三者都不成立时返回 null，表示「这不是 Unicode 家族」，交给上层做字符集检测。
///
/// 启发式**必须排在 UTF-8 严格解码之前**：纯 ASCII 内容的 UTF-16LE 字节
/// （如 `41 00 42 00`）在 UTF-8 眼里全是合法字节（`0x00` 是合法的 NUL），
/// `utf8.decode` 不会抛异常，只会静默产出夹满 U+0000 的垃圾串。
String? decodeUnicodeText(Uint8List bytes) {
  final UnicodeTextEncoding? detected =
      detectEncodingFromBom(bytes) ?? detectBomlessUtf16(bytes);
  try {
    if (detected != null) {
      return decodeWithUnicodeEncoding(bytes, detected);
    }
    return utf8.decode(bytes);
  } on FormatException {
    // 只可能来自 UTF-8（有无 BOM 均然）严格解码：字节不是 UTF-8。
    return null;
  }
}

/// 调用平台字符集检测插件解码 [bytes]；插件在本平台**不可用**时返回 null。
///
/// 兼容层说明（按仓库规则记录原因、影响范围与清理条件）：
/// - **为什么无法根治**：`flutter_charset_detector` 1.0.2 只提供 android / ios
///   联邦实现（其 pubspec 的 `flutter.plugin.platforms` 仅这两项），
///   Windows / macOS / Linux 落回 `MethodChannelCharsetDetector`，
///   `invokeMethod` 必然抛 [MissingPluginException]。这是**上游依赖的平台覆盖
///   缺口**，不是本仓能修的调用错误。
/// - **影响范围**：桌面三端读取 Shift-JIS / CP932 / GBK / Big5 / EUC-JP 等
///   传统多字节编码的字幕、弹幕、m3u8、纯文本书时，无法做字符集自动识别，
///   只能降级到宽松 UTF-8（少数字符变 U+FFFD）。Unicode 家族（含本函数上游的
///   UTF-8 / UTF-16 / UTF-32 判定）不受影响。
/// - **清理条件**：上游补齐桌面实现、或换成纯 Dart 的字符集检测实现后，
///   删掉这里的 null 降级分支，直接 `await CharsetDetector.autoDecode`。
Future<String?> tryPlatformCharsetDecode(Uint8List bytes) async {
  try {
    final DecodingResult result = await CharsetDetector.autoDecode(bytes);
    return result.string;
  } on MissingPluginException {
    // 桌面三端：插件无本平台实现。
    return null;
  } on UnimplementedError {
    // 平台接口未被任何实现覆盖（测试替身 / 未来新平台）。
    return null;
  } on PlatformException {
    // 原生侧检测失败（字节确实无法归到任何已知字符集）。
    return null;
  }
}

/// 解码文本字节，自动识别编码。**永远返回字符串，不会因编码问题抛异常**。
///
/// 分级策略：
/// 1. [decodeUnicodeText]——纯 Dart，覆盖 UTF-8（含 BOM）/ UTF-16 LE·BE
///    （含无 BOM）/ UTF-32 LE·BE。BOM 在此处**统一剥除**。
/// 2. [tryPlatformCharsetDecode]——移动端插件识别 Shift-JIS / CP932 / EUC-JP 等。
/// 3. `utf8.decode(allowMalformed: true)`——最后兜底。宁可少数字符变 U+FFFD，
///    也不能让整个字幕/弹幕/播放列表加载失败（BUG-1490）。
Future<String> decodeTextBytes(Uint8List bytes) async {
  final String? unicode = decodeUnicodeText(bytes);
  if (unicode != null) {
    return unicode;
  }
  final String? detected = await tryPlatformCharsetDecode(bytes);
  if (detected != null) {
    // 原生检测器对 UTF-16/UTF-8 也可能返回带 BOM 的串，统一剥掉。
    return stripLeadingBom(detected);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// U+FEFF 的字符形态（BOM / 零宽不换行空格）。源码里写转义而不是裸字符——
/// 裸 U+FEFF 在编辑器里不可见，改坏了看不出来。
const String kBomChar = '\uFEFF';

/// **纯函数**：剥掉字符串开头的 [kBomChar]。
String stripLeadingBom(String text) =>
    text.startsWith(kBomChar) ? text.substring(1) : text;

/// 读取文本文件并自动识别编码。解码细节见 [decodeTextBytes]。
Future<String> readTextWithEncoding(File file) async {
  final Uint8List bytes = await file.readAsBytes();
  return decodeTextBytes(bytes);
}
