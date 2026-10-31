import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-036 守卫：sync_asset_package_service.dart 不得回归到「整文件/整 zip 进内存」。
/// OOM 根因正是 readAsBytes 整文件 + ZipEncoder().encode / ZipDecoder().decodeBytes
/// 整 zip 在内存。打包必须走 archive_io 流式 + Isolate.run。
void main() {
  test('package service stays streaming (no whole-file/zip in memory)', () {
    final String src = File(
      '../packages/fushi_engine/lib/sync/sync_asset_package_service.dart',
    ).readAsStringSync();

    expect(
      src.contains('readAsBytes'),
      isFalse,
      reason: '资源文件不得 readAsBytes 整文件入内存，用 ZipFileEncoder.addFile 流式',
    );
    expect(
      src.contains('ZipEncoder()'),
      isFalse,
      reason: '不得用内存 ZipEncoder().encode，用 ZipFileEncoder 流式落盘',
    );
    expect(
      src.contains('decodeBytes'),
      isFalse,
      reason:
          '不得 ZipDecoder().decodeBytes 整包入内存，用 decodeBuffer(InputFileStream)',
    );
    expect(
      src.contains('Isolate.run'),
      isTrue,
      reason: 'zip 编解码必须在后台 isolate，勿阻塞 UI isolate',
    );
    expect(src.contains('ZipFileEncoder'), isTrue);
    expect(src.contains('InputFileStream'), isTrue);
    // 条目读写交给引擎的原生 zlib 通道（native_zip.dart，行为由
    // packages/fushi_engine/test/utils/archive/native_zip_test.dart 钉住）。
    expect(
      src.contains('writeZipEntryStreaming(file, out)'),
      isTrue,
      reason: '导入条目必须分块流式落盘（STORE 拷贝 / DEFLATE 原生 zlib），不得整文件入内存',
    );
    expect(
      src.contains('addFileNativeDeflate(encoder, file, entry.key)'),
      isTrue,
      reason: '词典包导出必须走原生 zlib deflate，不用 archive 纯 Dart 的 GZIP 档',
    );
    expect(
      src.contains('ZipFileEncoder.GZIP'),
      isFalse,
      reason: 'archive 的 GZIP 档是纯 Dart Deflate 且整文件入内存',
    );
    expect(
      src.contains('addFileStored(encoder, file, entry.key)'),
      isTrue,
      reason:
          '音频包导出必须用 STORE 流式（避免大文件整入内存 + deflate 浪费），'
          'CRC 走 native_zip 的 Rust ffcCrc32',
    );
    expect(
      src.contains('ZipFileEncoder.STORE'),
      isFalse,
      reason: 'archive 的 STORE 档用纯 Dart getCrc32 逐字节算 CRC，改用 addFileStored',
    );
  });
}
