import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_charset_detector/flutter_charset_detector.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// `flutter_charset_detector` method-channel 插件对 [PlatformCharsetDecoder]
/// 的实现。住在 app 而不是 `fushi_audio`：`fushi_audio` 已不依赖 Flutter SDK
/// （无头服务端直接消费它），插件实现经 [platformCharsetDecoder] 装配点注入。
///
/// 插件在本平台不可用（桌面三端无联邦实现 → [MissingPluginException]；测试替身
/// / 未来新平台 → [UnimplementedError]）或原生侧识别失败（[PlatformException]）
/// 时返回 null，由 `decodeTextBytes` 降级到宽松 UTF-8——与拆分前逐字节一致。
Future<String?> pluginCharsetDecode(Uint8List bytes) async {
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

/// 把插件实现写入 [platformCharsetDecoder] 装配点。Flutter app 在 `main()`
/// 里调一次；测试里若要走 `CharsetDetectorPlatform.instance` 替身，也先调它。
void installPlatformCharsetDetector() {
  platformCharsetDecoder = pluginCharsetDecode;
}
