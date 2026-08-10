import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频发现、系列与作品详情的远端封面统一使用磁盘缓存', () {
    const List<String> paths = <String>[
      'lib/src/pages/implementations/video_discovery_page.dart',
      'lib/src/pages/implementations/video_discovery_detail_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/video_work_detail_page.dart',
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ];

    for (final String path in paths) {
      final String source = File(path).readAsStringSync();
      expect(
        source,
        contains('CachedNetworkImageProvider('),
        reason: '$path 必须给远端封面提供跨刷新、跨重启的磁盘缓存',
      );
      expect(
        source,
        isNot(contains('NetworkImage(')),
        reason: '$path 不应退回仅有易淘汰内存缓存的 NetworkImage',
      );
    }
  });
}
