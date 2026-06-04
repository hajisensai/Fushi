import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-036 守卫：sync_asset_package_service.dart 不得回归到「整文件/整 zip 进内存」。
/// OOM 根因正是 readAsBytes 整文件 + ZipEncoder().encode / ZipDecoder().decodeBytes
/// 整 zip 在内存。打包必须走 archive_io 流式 + Isolate.run。
void main() {
  test('package service stays streaming (no whole-file/zip in memory)', () {
    final String src = File(
      'lib/src/sync/sync_asset_package_service.dart',
    ).readAsStringSync();

    expect(src.contains('readAsBytes'), isFalse,
        reason: '资源文件不得 readAsBytes 整文件入内存，用 ZipFileEncoder.addFile 流式');
    expect(src.contains('ZipEncoder()'), isFalse,
        reason: '不得用内存 ZipEncoder().encode，用 ZipFileEncoder 流式落盘');
    expect(src.contains('decodeBytes'), isFalse,
        reason:
            '不得 ZipDecoder().decodeBytes 整包入内存，用 decodeBuffer(InputFileStream)');
    expect(src.contains('Isolate.run'), isTrue,
        reason: 'zip 编解码必须在后台 isolate，勿阻塞 UI isolate');
    expect(src.contains('ZipFileEncoder'), isTrue);
    expect(src.contains('InputFileStream'), isTrue);
  });
}
