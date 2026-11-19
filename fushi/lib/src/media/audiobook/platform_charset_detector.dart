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
/// 时返回 null，`decodeTextBytes` 接着走 Rust 计算内核的本地多字节编码识别
/// （`decodeLegacyText`：Shift_JIS / CP932、GBK、EUC-JP、Big5，五端同一份），
/// 仍判不出才降级到宽松 UTF-8。
///
/// 移动端保留插件并让它先判：它覆盖的编码更多（韩文 EUC-KR、Windows-125x 等），
/// 而这些编码的字节按 GBK / Big5 读往往零错误，交给 Rust 那一级会被解成汉字乱码。
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
