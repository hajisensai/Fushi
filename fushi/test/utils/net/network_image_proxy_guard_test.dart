import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network image constructors must use the app proxy-aware providers', () {
    final List<String> violations = <String>[];
    final RegExp rawImage = RegExp(
        r'\b(?:Image\s*\.\s*network|NetworkImage|CachedNetworkImageProvider|CachedNetworkImage|FadeInImage\s*\.\s*(?:assetNetwork|memoryNetwork)|ExtendedImage\s*\.\s*network|SvgPicture\s*\.\s*network|SvgNetworkLoader|DefaultCacheManager)\s*\(');
    for (final File file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final String path = file.path.replaceAll('\\', '/');
      if (path.endsWith('/utils/net/app_http_image.dart')) continue;
      final String text = file
          .readAsStringSync()
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
          .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
      if (rawImage.hasMatch(text)) violations.add(path);
      // Existing NetworkToFileImage calls are strictly local-file providers.
      if (RegExp(r'NetworkToFileImage\([^)]*\burl\s*:', dotAll: true)
          .hasMatch(text)) {
        violations.add(path);
      }
    }
    expect(violations, isEmpty,
        reason:
            'Use AppHttpImage or AppCachedHttpImage; preserve headers and disk caching.');
  });
}
