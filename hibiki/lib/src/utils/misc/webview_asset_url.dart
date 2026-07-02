import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Resolves a Flutter asset path to a URL loadable by InAppWebView.
///
/// On Android: `file:///android_asset/flutter_assets/<assetPath>`
/// On iOS/macOS: uses the App.framework bundled flutter_assets directory.
/// On Windows/Linux: absolute file:// URL to the bundled flutter_assets directory.
String webViewAssetUrl(String assetPath) {
  if (Platform.isAndroid) {
    return 'file:///android_asset/flutter_assets/$assetPath';
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return appleBundleWebViewAssetUrl(
      assetPath: assetPath,
      resolvedExecutable: Platform.resolvedExecutable,
    );
  }
  // Windows / Linux
  final String exeDir = p.dirname(Platform.resolvedExecutable);
  final String fullPath = p.join(exeDir, 'data', 'flutter_assets', assetPath);
  return Uri.file(fullPath).toString();
}

@visibleForTesting
String appleBundleWebViewAssetUrl({
  required String assetPath,
  required String resolvedExecutable,
  bool Function(String path)? existsSync,
}) {
  final String executableDir = p.dirname(resolvedExecutable);
  final String macOSFrameworkRoot = p.join(
    executableDir,
    '..',
    'Frameworks',
    'App.framework',
  );
  final String iOSFrameworkRoot = p.join(
    executableDir,
    'Frameworks',
    'App.framework',
  );
  final List<String> frameworkRoots = <String>[
    macOSFrameworkRoot,
    iOSFrameworkRoot,
  ];
  final List<String> candidates = <String>[
    for (final String frameworkRoot in frameworkRoots) ...<String>[
      p.join(frameworkRoot, 'Resources', 'flutter_assets', assetPath),
      p.join(frameworkRoot, 'flutter_assets', assetPath),
    ],
  ];
  final String fallback = p.join(
    p.dirname(resolvedExecutable),
    '..',
    'Frameworks',
    'App.framework',
    'Resources',
    'flutter_assets',
    assetPath,
  );
  final bool Function(String path) exists =
      existsSync ?? ((String path) => File(path).existsSync());
  for (final String candidate in candidates) {
    if (exists(candidate)) {
      return Uri.file(p.canonicalize(candidate)).toString();
    }
  }
  return Uri.file(p.canonicalize(fallback)).toString();
}
