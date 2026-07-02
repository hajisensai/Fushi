import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/webview_asset_url.dart';

void main() {
  group('appleBundleWebViewAssetUrl', () {
    const String executable = '/tmp/Hibiki.app/Contents/MacOS/hibiki';
    const String asset = 'assets/popup/popup.html';

    test('uses App.framework Resources flutter_assets on macOS bundles', () {
      final String url = appleBundleWebViewAssetUrl(
        assetPath: asset,
        resolvedExecutable: executable,
        existsSync: (String path) =>
            path.endsWith('/App.framework/Resources/flutter_assets/$asset'),
      );

      expect(
        Uri.parse(url).toFilePath(),
        '/tmp/Hibiki.app/Contents/Frameworks/App.framework/Resources/flutter_assets/$asset',
      );
    });

    test('keeps compatibility with flat App.framework flutter_assets bundles',
        () {
      final String url = appleBundleWebViewAssetUrl(
        assetPath: asset,
        resolvedExecutable: executable,
        existsSync: (String path) =>
            path.endsWith('/App.framework/flutter_assets/$asset'),
      );

      expect(
        Uri.parse(url).toFilePath(),
        '/tmp/Hibiki.app/Contents/Frameworks/App.framework/flutter_assets/$asset',
      );
    });

    test('falls back to the macOS Resources location when neither exists', () {
      final String url = appleBundleWebViewAssetUrl(
        assetPath: asset,
        resolvedExecutable: executable,
        existsSync: (_) => false,
      );

      expect(
        Uri.parse(url).toFilePath(),
        '/tmp/Hibiki.app/Contents/Frameworks/App.framework/Resources/flutter_assets/$asset',
      );
    });
  });
}
