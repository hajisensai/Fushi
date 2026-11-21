import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_charset_detector/flutter_charset_detector.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// `flutter_charset_detector` method-channel 插件对 [PlatformCharsetDecoder]
/// 的实现。住在 app 而不是 `fushi_audio`：`fushi_audio` 已不依赖 Flutter SDK
/// （无头服务端直接消费它），插件实现经 [platformCharsetDecoder] 装配点注入。
///
/// 插件只有 android / ios 实现（`flutter.plugin.platforms` 仅这两项），所以
/// [installPlatformCharsetDetector] 只在这两端装配；桌面三端不装，非 Unicode
/// 字节直接交给 Rust 计算内核的旧编码识别（`decodeLegacyText`：中日编码、韩文
/// EUC-KR、Windows-125x 等，五端同一份），仍判不出才降级到宽松 UTF-8。
///
/// 平台接口未被任何实现覆盖（测试替身，[UnimplementedError]）或原生侧识别失败
/// （[PlatformException]）时返回 null，`decodeTextBytes` 接着走同一条 Rust 路径。
///
/// 移动端保留插件并让它先判（沿用既有行为）；它判不出时 Rust 那一级照样能认韩文
/// EUC-KR、Windows-125x 等编码，不会再被解成汉字乱码。
Future<String?> pluginCharsetDecode(Uint8List bytes) async {
  try {
    final DecodingResult result = await CharsetDetector.autoDecode(bytes);
    return result.string;
  } on UnimplementedError {
    // 平台接口未被任何实现覆盖（测试替身 / 未来新平台）。
    return null;
  } on PlatformException {
    // 原生侧检测失败（字节确实无法归到任何已知字符集）。
    return null;
  }
}

/// 在插件有实现的平台（android / ios）把插件实现写入 [platformCharsetDecoder]
/// 装配点；其余平台清空装配点（桌面三端没有插件实现，装了每次调用都只会吃一个
/// `MissingPluginException`）。Flutter app 在 `main()` 里调一次。测试要走
/// `CharsetDetectorPlatform.instance` 替身时直接把 [pluginCharsetDecode] 写进
/// 装配点。
void installPlatformCharsetDetector() {
  platformCharsetDecoder = Platform.isAndroid || Platform.isIOS
      ? pluginCharsetDecode
      : null;
}
