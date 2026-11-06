import 'dart:convert';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';

/// Anki 媒体文件名（`<prefix><sha256>.<ext>`，同名即同内容）与上传编码。
///
/// 纯 Dart（无 Flutter）：app 的各后端与无头服务端的落地后端共用同一套命名，
/// 同一份字节在哪边写进库都是同一个文件名。SHA-256 走 Rust 内核（native/fushi_compute，
/// 硬依赖，库不可用抛 [FushiComputeUnavailableError]），本包不再自带 Dart 实现。
String fushiAnkiMediaFilenameForBytes({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  final String ext = _mediaExtensionFromSource(
    sourceName,
    fallbackExtension: fallbackExtension,
  );
  return '${_safeMediaPrefix(prefix)}${ffcSha256Bytes(bytes)}.$ext';
}

/// BUG-933：制卡「未响应」根因之一——旧代码在 **UI isolate** 对整段媒体字节同步跑
/// 纯 Dart 逐字节 SHA256（几 MB 音频=数百万次迭代）和 [base64Encode]，阻塞主线程。
/// 这里把「哈希文件名 + base64」一次卸到后台 isolate，同段字节只跨 isolate 拷贝一次。
/// （SHA-256 现已改走 Rust 的 [ffcSha256Bytes]，4 MiB 约 4 ms；base64 仍是 Dart。）
///
/// 阈值兜底：词典外字（单卡可能数十个、每个仅几 KB）走同步分支——为几 KB 图各起一个
/// isolate 反而挤占资源、拖慢总时长（且不会 jank）；只有封面/音频等大媒体才卸后台。
const int _isolateMediaThresholdBytes = 64 * 1024;

/// AnkiConnect 上传路径：计算 sha256 文件名 + base64 数据。大媒体在后台 isolate 完成，
/// 小媒体同步完成。返回记录 `(filename, base64Data)` 供 `storeMediaFile`。
Future<({String filename, String base64Data})>
fushiAnkiMediaEncodeForUploadAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  ({String filename, String base64Data}) encode() => (
    filename: fushiAnkiMediaFilenameForBytes(
      prefix: prefix,
      bytes: bytes,
      sourceName: sourceName,
      fallbackExtension: fallbackExtension,
    ),
    base64Data: base64Encode(bytes),
  );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<({String filename, String base64Data})>.value(encode());
  }
  return Isolate.run(encode);
}

/// AnkiDroid 路径：媒体由 platform channel 按文件路径落库（不走 base64），只需 sha256
/// 文件名。大媒体在后台 isolate 完成，小媒体同步完成。
Future<String> fushiAnkiMediaFilenameForBytesAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  String compute() => fushiAnkiMediaFilenameForBytes(
    prefix: prefix,
    bytes: bytes,
    sourceName: sourceName,
    fallbackExtension: fallbackExtension,
  );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(compute());
  }
  return Isolate.run(compute);
}

/// [base64Encode] 的按需后台变体（BUG-933）：大媒体卸到 isolate，小媒体同步。用于
/// 文件名已定、只剩 base64 的路径（远端下载音频 / 词典外字上传）。
Future<String> fushiAnkiBase64EncodeAsync(List<int> bytes) {
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(base64Encode(bytes));
  }
  return Isolate.run(() => base64Encode(bytes));
}

String _safeMediaPrefix(String prefix) {
  final String safe = prefix.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return safe.isEmpty ? 'fushi_media_' : safe;
}

String _mediaExtensionFromSource(
  String sourceName, {
  required String fallbackExtension,
}) {
  final String fallback = _safeMediaExtension(
    fallbackExtension,
    fallback: 'bin',
  );
  final Uri? uri = Uri.tryParse(sourceName);
  final String path = (uri != null && uri.path.isNotEmpty)
      ? uri.path
      : sourceName.replaceAll('\\', '/');
  final String name = path.split('/').last;
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return fallback;
  return _safeMediaExtension(name.substring(dot + 1), fallback: fallback);
}

String _safeMediaExtension(String extension, {required String fallback}) {
  final String safe = extension.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  if (safe.isEmpty || safe.length > 12) return fallback;
  return safe;
}
