@TestOn('!windows')
// appleBundleWebViewAssetUrl 只在 iOS/macOS 运行时被调用（webViewAssetUrl 用
// Platform.isIOS || isMacOS 门控），其内部依赖 package:path 的**环境 style**做
// join/canonicalize + Uri.file。iOS/macOS/Linux CI 均为 POSIX style，断言的 POSIX
// 期望值成立；仅在 Windows 宿主上 path 走 Windows style（反斜杠 + 盘符锚定 + 小写），
// 与被测的 Apple 运行时语义不符，故这条 Apple 路径单测在 Windows 宿主上无意义——用
// 文件级 @TestOn('!windows') 门控（CI 跑在 ubuntu-latest，仍完整覆盖），而非改动
// 生产函数（生产端只在 Apple 上执行，行为正确）。
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
