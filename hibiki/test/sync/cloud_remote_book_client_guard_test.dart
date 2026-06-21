import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-665 阶段1）：CloudRemoteBookClient 的契约纪律。
///
/// 1. 不得裸构造任何具体云后端（如 `GoogleDriveSyncBackend(`）——必须经
///    `resolveSyncBackend(type)`，否则丢掉 ObfuscatingSyncBackend 解混淆装饰层，
///    下载下来的 .epub 是混淆字节无法导入。
/// 2. 云盘 getRemoteBook 只下载不导入——不得调 `importRemoteBookFolder` 或
///    `EpubImporter`（导入由书架页 `_importRemoteBookFile` 负责，避免双重导入）。
void main() {
  group('cloud_remote_book_client source guard', () {
    final File src = File('lib/src/sync/cloud_remote_book_client.dart');

    test('source file exists', () {
      expect(src.existsSync(), isTrue);
    });

    test('does not bare-construct concrete cloud backends', () {
      final String code = src.readAsStringSync();
      for (final String ctor in const <String>[
        'GoogleDriveSyncBackend(',
        'WebDavSyncBackend(',
        'OneDriveSyncBackend(',
        'DropboxSyncBackend(',
        'FtpSyncBackend(',
        'SftpSyncBackend(',
      ]) {
        expect(code.contains(ctor), isFalse,
            reason: '必须经 resolveSyncBackend 获取后端（带解混淆装饰层），不得裸构造 $ctor');
      }
    });

    test('does not double-import (no importRemoteBookFolder / EpubImporter)',
        () {
      final String code = src.readAsStringSync();
      expect(code.contains('importRemoteBookFolder'), isFalse,
          reason: 'getRemoteBook 只下载不导入，导入由书架页负责');
      expect(code.contains('EpubImporter'), isFalse,
          reason: 'getRemoteBook 只下载不导入，导入由书架页负责');
    });

    test('book shelf wires CloudRemoteBookClient for non-hibikiServer backends',
        () {
      final File part =
          File('lib/src/pages/implementations/reader_history/remote.part.dart');
      final String code = part.readAsStringSync();
      // 非 hibikiServer 分支经 resolveSyncBackend 并返回 CloudRemoteBookClient。
      expect(code.contains('resolveSyncBackend('), isTrue);
      expect(code.contains('CloudRemoteBookClient('), isTrue);
      // hibikiServer 分支仍返回裸 HibikiClientSyncBackend（保留 live 库 API）。
      expect(code.contains('HibikiClientSyncBackend.instance'), isTrue);
    });
  });
}
