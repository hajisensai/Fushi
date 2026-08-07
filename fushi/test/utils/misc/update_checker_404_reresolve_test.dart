import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

/// TODO-1123 / BUG-539 regression: the debug channel serves a mirrored
/// `latest-debug.json` manifest. The app resolves `asset.url` at CHECK time and
/// trusts it later at DOWNLOAD time. CI's rolling `debug-rolling` tag prunes
/// every asset that is not the current seq on each push, so a device holding a
/// stale manifest (old seq) hits 404 when the old APK was already pruned.
///
/// The client-side fix: on a 404 download failure, re-fetch the manifest once,
/// and if the freshly resolved URL differs, retry the download exactly once
/// with the new URL. These tests drive the pure orchestration
/// [UpdateChecker.downloadAssetWithStaleRetry] with injected closures — no
/// network — and assert: (1) 404 → re-resolve → success with the new URL, only
/// one re-resolve + one retry; (2) re-resolve still 404 → the error bubbles up.
void main() {
  UpdateAsset assetFor(String url) => UpdateAsset(name: 'hibiki.apk', url: url);

  group('isStaleAssetDownloadFailure', () {
    test('classifies HttpException(404) as a stale-asset failure', () {
      expect(
        isStaleAssetDownloadFailure(
          const HttpException('download failed (404): https://x/y'),
        ),
        isTrue,
      );
    });

    test('does NOT classify other HTTP status / non-HTTP errors', () {
      expect(
        isStaleAssetDownloadFailure(
          const HttpException('download failed (403): https://x/y'),
        ),
        isFalse,
      );
      expect(
        isStaleAssetDownloadFailure(
          const SocketException('failed host lookup'),
        ),
        isFalse,
      );
      expect(
        isStaleAssetDownloadFailure(
          const UpdateDownloadCancelledException(),
        ),
        isFalse,
      );
    });
  });

  group('downloadAssetWithStaleRetry', () {
    test('404 on stale url → re-resolves manifest → retries new url once',
        () async {
      const String oldUrl =
          'https://github.com/o/r/releases/download/debug-rolling/hibiki-0.1-debug.6421-a.apk';
      const String newUrl =
          'https://github.com/o/r/releases/download/debug-rolling/hibiki-0.1-debug.6425-b.apk';
      final File expected = File('${Directory.systemTemp.path}/ok.apk');

      final List<String> downloadedUrls = <String>[];
      var reResolveCalls = 0;

      final File result = await UpdateChecker.downloadAssetWithStaleRetry(
        asset: assetFor(oldUrl),
        download: (UpdateAsset target) async {
          downloadedUrls.add(target.url);
          if (target.url == oldUrl) {
            // Simulate the pruned asset: server returns 404.
            throw const HttpException('download failed (404): $oldUrl');
          }
          return expected;
        },
        reResolveAsset: () async {
          reResolveCalls++;
          return assetFor(newUrl);
        },
      );

      expect(result.path, expected.path);
      // Old url attempted, then exactly the new url — one retry, no loop.
      expect(downloadedUrls, <String>[oldUrl, newUrl]);
      expect(reResolveCalls, 1, reason: 're-resolve must happen exactly once');
    });

    test('404 then re-resolve still 404 → bubbles the original error',
        () async {
      const String oldUrl = 'https://x/old.apk';
      const String newUrl = 'https://x/new.apk';

      final List<String> downloadedUrls = <String>[];
      var reResolveCalls = 0;

      await expectLater(
        UpdateChecker.downloadAssetWithStaleRetry(
          asset: assetFor(oldUrl),
          download: (UpdateAsset target) async {
            downloadedUrls.add(target.url);
            throw HttpException('download failed (404): ${target.url}');
          },
          reResolveAsset: () async {
            reResolveCalls++;
            return assetFor(newUrl);
          },
        ),
        throwsA(isA<HttpException>()),
      );

      // Both urls attempted (retry happened) but re-resolve only once.
      expect(downloadedUrls, <String>[oldUrl, newUrl]);
      expect(reResolveCalls, 1);
    });

    test('re-resolve returns same url → no retry, original error bubbles',
        () async {
      const String url = 'https://x/same.apk';
      final List<String> downloadedUrls = <String>[];
      var reResolveCalls = 0;

      await expectLater(
        UpdateChecker.downloadAssetWithStaleRetry(
          asset: assetFor(url),
          download: (UpdateAsset target) async {
            downloadedUrls.add(target.url);
            throw HttpException('download failed (404): ${target.url}');
          },
          reResolveAsset: () async {
            reResolveCalls++;
            return assetFor(url); // Same url — nothing new to retry.
          },
        ),
        throwsA(isA<HttpException>()),
      );

      expect(downloadedUrls, <String>[url],
          reason: 'no retry on unchanged url');
      expect(reResolveCalls, 1);
    });

    test('re-resolve returns null → no retry, original error bubbles',
        () async {
      const String url = 'https://x/gone.apk';
      final List<String> downloadedUrls = <String>[];

      await expectLater(
        UpdateChecker.downloadAssetWithStaleRetry(
          asset: assetFor(url),
          download: (UpdateAsset target) async {
            downloadedUrls.add(target.url);
            throw HttpException('download failed (404): ${target.url}');
          },
          reResolveAsset: () async => null,
        ),
        throwsA(isA<HttpException>()),
      );

      expect(downloadedUrls, <String>[url]);
    });

    test('non-404 failure bubbles without re-resolve', () async {
      const String url = 'https://x/net.apk';
      var reResolveCalls = 0;

      await expectLater(
        UpdateChecker.downloadAssetWithStaleRetry(
          asset: assetFor(url),
          download: (UpdateAsset target) async {
            throw const SocketException('connection refused');
          },
          reResolveAsset: () async {
            reResolveCalls++;
            return assetFor('https://x/other.apk');
          },
        ),
        throwsA(isA<SocketException>()),
      );

      expect(reResolveCalls, 0, reason: 'network failure must not re-resolve');
    });

    test('happy path (no 404) does not re-resolve', () async {
      final File expected = File('${Directory.systemTemp.path}/direct.apk');
      var reResolveCalls = 0;

      final File result = await UpdateChecker.downloadAssetWithStaleRetry(
        asset: assetFor('https://x/first.apk'),
        download: (UpdateAsset target) async => expected,
        reResolveAsset: () async {
          reResolveCalls++;
          return null;
        },
      );

      expect(result.path, expected.path);
      expect(reResolveCalls, 0);
    });
  });
}
