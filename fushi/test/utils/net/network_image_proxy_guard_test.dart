import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/scan_scale.dart';
import '../../helpers/source_guard.dart';

/// 远端图片必须走 `AppHttpImage` / `AppCachedHttpImage`——它们把请求接进全应用
/// 代理装配；裸的 provider 会绕过代理，让「挑战出口 ≠ 请求出口」重新出现。
///
/// 注释剥离走 helpers/source_guard.dart 的 [maskComments]（手写剥离被
/// test/tools/source_guard_adoption_test.dart 禁止：手写版会把字符串字面量里的
/// `//` 当注释切掉，把守卫弄瞎）。
void main() {
  test('network image constructors must use the app proxy-aware providers', () {
    final List<String> violations = <String>[];
    final RegExp rawImage = RegExp(
        r'\b(?:Image\s*\.\s*network|NetworkImage|CachedNetworkImageProvider|CachedNetworkImage|FadeInImage\s*\.\s*(?:assetNetwork|memoryNetwork)|ExtendedImage\s*\.\s*network|SvgPicture\s*\.\s*network|SvgNetworkLoader|DefaultCacheManager)\s*\(');
    int scanned = 0;
    for (final File file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final String path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('/utils/net/app_http_image.dart')) continue;
      scanned++;
      final String text = maskComments(file.readAsStringSync());
      if (rawImage.hasMatch(text)) violations.add(path);
      // Existing NetworkToFileImage calls are strictly local-file providers.
      if (RegExp(r'NetworkToFileImage\([^)]*\burl\s*:', dotAll: true)
          .hasMatch(text)) {
        violations.add(path);
      }
    }
    // 禁止型断言全绿 ≠ 它在工作：扫描根改名 / 过滤写反都长成「零违规」。
    expectScanScale(scanned,
        what: 'lib/ 下参与远端图片 provider 扫描的 dart 文件',
        atLeast: 1050,
        measured: 1318);
    expect(violations, isEmpty,
        reason:
            'Use AppHttpImage or AppCachedHttpImage; preserve headers and disk caching.');
  });
}
