import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/fallback_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class MockSyncBackend implements SyncBackend {
  MockSyncBackend(this.name, {this.shouldFail = false});

  final String name;
  bool shouldFail;
  bool nonRetryableFailure = false;
  bool authenticated = true;
  int callCount = 0;

  @override
  Future<bool> get isAuthenticated async => authenticated;
  @override
  Future<String?> get currentEmail async => '$name@test.com';
  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    callCount++;
    if (shouldFail) throw SyncBackendError('$name failed');
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {}
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => authenticated;
  @override
  Future<void> refreshAuth() async {}

  @override
  Future<String> findOrCreateRootFolder() async {
    callCount++;
    if (nonRetryableFailure) throw SyncBackendError('$name failed');
    if (shouldFail) throw SyncBackendError('$name failed', isRetryable: true);
    return '/root/$name';
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => [];
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async {
    if (shouldFail) throw SyncBackendError('$name failed');
    return '$rootFolderId/$bookTitle';
  }

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      const DriveSyncFiles();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async => TtuProgress(
      dataId: 0,
      exploredCharCount: 0,
      progress: 0,
      lastBookmarkModified: 0);
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async => [];
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      TtuAudioBook(title: '', playbackPositionSec: 0, lastAudioBookModified: 0);
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    if (shouldFail) throw SyncBackendError('$name failed');
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {}
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {}
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<DriveFile?> findContentFile(
          String folderId, String fileName) async =>
      null;
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => null;
  @override
  Map<String, String> get cachedFolderIds => {};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
}

void main() {
  group('FallbackSyncBackend', () {
    test('uses first backend when it succeeds', () async {
      final primary = MockSyncBackend('primary');
      final secondary = MockSyncBackend('secondary');
      final fallback = FallbackSyncBackend([primary, secondary]);

      final result = await fallback.findOrCreateRootFolder();
      expect(result, '/root/primary');
      expect(primary.callCount, 1);
      expect(secondary.callCount, 0);
    });

    test('falls back to second backend when first fails', () async {
      final primary = MockSyncBackend('primary', shouldFail: true);
      final secondary = MockSyncBackend('secondary');
      final fallback = FallbackSyncBackend([primary, secondary]);

      final result = await fallback.findOrCreateRootFolder();
      expect(result, '/root/secondary');
      expect(primary.callCount, 1);
      expect(secondary.callCount, 1);
    });

    test('throws when all backends fail', () async {
      final primary = MockSyncBackend('primary', shouldFail: true);
      final secondary = MockSyncBackend('secondary', shouldFail: true);
      final fallback = FallbackSyncBackend([primary, secondary]);

      expect(
        () => fallback.findOrCreateRootFolder(),
        throwsA(isA<SyncBackendError>()),
      );
    });

    test('activeBackend returns the last successful backend', () async {
      final primary = MockSyncBackend('primary', shouldFail: true);
      final secondary = MockSyncBackend('secondary');
      final fallback = FallbackSyncBackend([primary, secondary]);

      await fallback.findOrCreateRootFolder();
      expect(fallback.activeBackendIndex, 1);
    });

    test('empty backends list throws', () {
      expect(() => FallbackSyncBackend([]), throwsA(isA<ArgumentError>()));
    });

    test('auth delegates to active backend not fallback chain', () async {
      final primary = MockSyncBackend('primary');
      final secondary = MockSyncBackend('secondary');
      final fallback = FallbackSyncBackend([primary, secondary]);

      expect(await fallback.isAuthenticated, isTrue);
      expect(await fallback.currentEmail, 'primary@test.com');
    });

    test('non-retryable error rethrows without trying next backend', () async {
      final primary = MockSyncBackend('primary');
      final secondary = MockSyncBackend('secondary');
      primary.nonRetryableFailure = true;
      final fallback = FallbackSyncBackend([primary, secondary]);

      expect(
        () => fallback.findOrCreateRootFolder(),
        throwsA(isA<SyncBackendError>()),
      );
      expect(secondary.callCount, 0);
    });

    test('three-level fallback works', () async {
      final a = MockSyncBackend('a', shouldFail: true);
      final b = MockSyncBackend('b', shouldFail: true);
      final c = MockSyncBackend('c');
      final fallback = FallbackSyncBackend([a, b, c]);

      final result = await fallback.findOrCreateRootFolder();
      expect(result, '/root/c');
      expect(fallback.activeBackendIndex, 2);
    });
  });
}
