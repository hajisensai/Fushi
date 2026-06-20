import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/obfuscating_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';

/// resolveSyncBackend 的包裹策略守卫（TODO-623 A1）：
/// 云后端必须被 ObfuscatingSyncBackend 包裹（防扫盘），局域网 hibikiServer 不包裹。
void main() {
  group('resolveSyncBackend obfuscation wrapping policy', () {
    const cloudTypes = <SyncBackendType>[
      SyncBackendType.googleDrive,
      SyncBackendType.webDav,
      SyncBackendType.oneDrive,
      SyncBackendType.dropbox,
      SyncBackendType.ftp,
      SyncBackendType.sftp,
    ];

    test('all cloud/remote backends are wrapped in ObfuscatingSyncBackend', () {
      for (final type in cloudTypes) {
        final backend = resolveSyncBackend(type);
        expect(backend, isA<ObfuscatingSyncBackend>(),
            reason: 'cloud backend must be obfuscation-wrapped (anti-scan)');
      }
    });

    test('hibikiServer (LAN) is NOT wrapped', () {
      final backend = resolveSyncBackend(SyncBackendType.hibikiServer);
      expect(backend, isNot(isA<ObfuscatingSyncBackend>()));
      expect(backend, isA<HibikiClientSyncBackend>());
    });

    test('every SyncBackendType is handled (no enum drift)', () {
      for (final type in SyncBackendType.values) {
        expect(() => resolveSyncBackend(type), returnsNormally);
      }
    });
  });

  _guardSourceFiles();
}

void _guardSourceFiles() {
  group('source guard: obfuscator uses crypto hash, no base64/encrypt lib', () {
    test('sync_obfuscator.dart uses crypto, no encryption lib / base64', () {
      final src = File('lib/src/sync/sync_obfuscator.dart').readAsStringSync();
      // 计划要求：用现有 crypto hash 依赖，不引入加密库、不用 base64。
      expect(src.contains('package:crypto/crypto.dart'), isTrue);
      expect(src.contains('package:encrypt'), isFalse);
      expect(src.contains('package:pointycastle'), isFalse);
      expect(src.contains('base64Encode'), isFalse);
      expect(src.contains('base64Decode'), isFalse);
      expect(src.contains('magicHeader'), isTrue);
    });
  });

  group('source guard: concrete backends untouched (only factory wraps)', () {
    test('no concrete backend file references the obfuscator', () {
      const backendFiles = <String>[
        'lib/src/sync/google_drive_sync_backend.dart',
        'lib/src/sync/webdav_sync_backend.dart',
        'lib/src/sync/onedrive_sync_backend.dart',
        'lib/src/sync/dropbox_sync_backend.dart',
        'lib/src/sync/ftp_sync_backend.dart',
        'lib/src/sync/sftp_sync_backend.dart',
        'lib/src/sync/hibiki_client_sync_backend.dart',
      ];
      for (final path in backendFiles) {
        final src = File(path).readAsStringSync();
        expect(src.contains('obfuscating_sync_backend.dart'), isFalse,
            reason: 'backend file must not import the decorator');
        expect(src.contains('SyncObfuscator'), isFalse,
            reason: 'backend file must not reference the obfuscator');
      }
    });
  });
}
