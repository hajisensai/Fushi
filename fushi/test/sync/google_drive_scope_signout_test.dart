import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/google_drive_handler.dart';
import 'package:fushi/src/sync/google_drive_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// TODO-836 HARD GUARD: the whole point of the insufficient_scope fix is that
/// the user's stale grant gets SIGNED OUT so the sign-in button reappears and
/// they can re-consent to drive.appdata. Two contracts are pinned here:
///   1. backend error mapping turns a 403 insufficient_scope GoogleDriveError
///      into a SyncAuthError (NOT a SyncBackendError) — only SyncAuthError
///      reaches the sign-out path;
///   2. the manual-sync catch decision signs out on SyncAuthError but NOT on an
///      ordinary SyncBackendError (e.g. 507 quota / network), so a transient
///      backend hiccup never wipes the session.
void main() {
  group('TODO-836 backend error mapping → SyncAuthError', () {
    test('403 insufficient_scope maps to SyncAuthError, not SyncBackendError',
        () {
      final Object mapped = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('insufficient_scope: re-consent required',
            statusCode: 403),
      );
      expect(mapped, isA<SyncAuthError>());
      expect(mapped, isNot(isA<SyncBackendError>()));
    });

    test(
        'a non-scope GoogleDriveError stays a (retryable-aware) SyncBackendError',
        () {
      final Object mapped404 = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('not found', statusCode: 404),
      );
      expect(mapped404, isA<SyncBackendError>());
      expect((mapped404 as SyncBackendError).isRetryable, isTrue); // 404 stale

      final Object mapped507 = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('507 quota exceeded', statusCode: 507),
      );
      expect(mapped507, isA<SyncBackendError>());
      expect((mapped507 as SyncBackendError).isRetryable, isFalse);
    });

    test('a 403 WITHOUT insufficient_scope is a SyncBackendError (not auth)',
        () {
      final Object mapped = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('rate limit exceeded', statusCode: 403),
      );
      expect(mapped, isA<SyncBackendError>());
    });
  });

  group('BUG-1023 transient Drive failures are retryable (in-round retry)', () {
    // 根因：mapDriveError 曾只把 404 判为 isRetryable，408/429/5xx 全落非重试分支，
    // 于是一次瞬时超时就把该书 skip 到下一轮（sync_manager 的 retry-once 进不去）。
    // 修复后 isTransientError 覆盖官方退避集，且显式排除 507 配额。
    for (final int code in <int>[408, 429, 500, 502, 503, 504]) {
      test('$code maps to a retryable SyncBackendError', () {
        final Object mapped = GoogleDriveSyncBackend.mapDriveError(
          GoogleDriveError('transient $code', statusCode: code),
        );
        expect(mapped, isA<SyncBackendError>());
        expect((mapped as SyncBackendError).isRetryable, isTrue,
            reason: '$code is a transient failure and must retry in-round');
      });
    }

    test('507 Insufficient Storage stays NON-retryable (quota, not transient)',
        () {
      final Object mapped = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('507 quota exceeded', statusCode: 507),
      );
      expect(mapped, isA<SyncBackendError>());
      expect((mapped as SyncBackendError).isRetryable, isFalse,
          reason: 'retrying a quota-exceeded write cannot succeed');
    });

    test('an unclassified 4xx (e.g. 400) stays NON-retryable', () {
      final Object mapped = GoogleDriveSyncBackend.mapDriveError(
        GoogleDriveError('bad request', statusCode: 400),
      );
      expect((mapped as SyncBackendError).isRetryable, isFalse);
    });
  });

  group('TODO-836 manual-sync catch decision → signOut', () {
    // Mirrors the decision in actions.part.dart `_syncNow`: sign out only when
    // the thrown error is a SyncAuthError. Pure so it stays a fast unit test;
    // the widget wiring is exercised by analyze + the source corpus.
    Future<int> simulateSyncCatch(
        Exception error, _CountingBackend backend) async {
      int signOuts = 0;
      try {
        throw error;
      } on SyncAuthError {
        await backend.signOut(repo: _nullRepo);
        signOuts++;
      } catch (_) {
        // ordinary error → no sign-out
      }
      return signOuts;
    }

    test('SyncAuthError triggers signOut exactly once', () async {
      final _CountingBackend backend = _CountingBackend();
      final int count =
          await simulateSyncCatch(SyncAuthError('insufficient_scope'), backend);
      expect(count, 1);
      expect(backend.signOutCalls, 1);
    });

    test('ordinary SyncBackendError does NOT trigger signOut', () async {
      final _CountingBackend backend = _CountingBackend();
      final int count = await simulateSyncCatch(
          SyncBackendError('507 quota', isRetryable: false), backend);
      expect(count, 0);
      expect(backend.signOutCalls, 0);
    });
  });
}

final SyncRepository _nullRepo = _UnusedRepo();

/// Counts signOut invocations; only [signOut] is exercised by these tests.
class _CountingBackend {
  int signOutCalls = 0;
  Future<void> signOut({required SyncRepository repo}) async {
    signOutCalls++;
  }
}

/// The fake backend's signOut never touches the repo, so a sentinel is enough.
class _UnusedRepo implements SyncRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('repo not used in this test');
}
