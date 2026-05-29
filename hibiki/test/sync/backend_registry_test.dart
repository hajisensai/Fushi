import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backend_registry.dart';
import 'package:hibiki/src/sync/sync_backend.dart';

import 'fallback_sync_backend_test.dart';

void main() {
  group('SyncBackendRegistry', () {
    late SyncBackendRegistry registry;

    setUp(() {
      registry = SyncBackendRegistry();
    });

    test('registers and resolves a backend', () {
      final backend = MockSyncBackend('test');
      registry.register(SyncBackendType.googleDrive, () => backend);
      expect(registry.resolve(SyncBackendType.googleDrive), same(backend));
    });

    test('throws for unregistered backend type', () {
      expect(
        () => registry.resolve(SyncBackendType.oneDrive),
        throwsA(isA<StateError>()),
      );
    });

    test('lists registered types', () {
      final backend = MockSyncBackend('test');
      registry.register(SyncBackendType.googleDrive, () => backend);
      registry.register(SyncBackendType.webDav, () => backend);
      expect(
        registry.registeredTypes,
        containsAll([SyncBackendType.googleDrive, SyncBackendType.webDav]),
      );
    });

    test('hasBackend returns correct values', () {
      final backend = MockSyncBackend('test');
      registry.register(SyncBackendType.ftp, () => backend);
      expect(registry.hasBackend(SyncBackendType.ftp), isTrue);
      expect(registry.hasBackend(SyncBackendType.sftp), isFalse);
    });
  });
}
