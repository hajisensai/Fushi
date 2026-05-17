import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves a Flutter asset path to a URL loadable by InAppWebView.
///
/// On Android: `file:///android_asset/flutter_assets/<assetPath>`
/// On iOS: uses the main bundle path
/// On Desktop: absolute file:// URL to the bundled flutter_assets directory
String webViewAssetUrl(String assetPath) {
  if (Platform.isAndroid) {
    return 'file:///android_asset/flutter_assets/$assetPath';
  }
  if (Platform.isIOS || Platform.isMacOS) {
    final String bundlePath = p.join(
      p.dirname(Platform.resolvedExecutable),
      '..',
      'Frameworks',
      'App.framework',
      'flutter_assets',
      assetPath,
    );
    return Uri.file(p.canonicalize(bundlePath)).toString();
  }
  // Windows / Linux
  final String exeDir = p.dirname(Platform.resolvedExecutable);
  final String fullPath = p.join(exeDir, 'data', 'flutter_assets', assetPath);
  return Uri.file(fullPath).toString();
}
