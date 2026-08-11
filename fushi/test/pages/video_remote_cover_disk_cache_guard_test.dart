import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 远端封面必须走 `CachedNetworkImageProvider`（cached_network_image 自带磁盘
/// 缓存），而不是只有内存缓存的 `NetworkImage` / `Image.network`。
///
/// 这条守卫按**每一处用法**判定：任何一行出现禁用写法都会点名文件与行号。早期
/// 版本只断言「文件里出现过一次 CachedNetworkImageProvider」，那只能证明有人写
/// 对过一次，同文件其余封面继续裸联网也测不出来；`Image.network(` 更是完全绕过
/// 了 `isNot(contains('NetworkImage('))`。
void main() {
  const List<String> paths = <String>[
    'lib/src/pages/implementations/video_discovery_page.dart',
    'lib/src/pages/implementations/video_discovery_detail_page.dart',
    'lib/src/pages/implementations/home_video_page.dart',
    'lib/src/pages/implementations/video_work_detail_page.dart',
    'lib/src/pages/implementations/media_collection_detail_page.dart',
  ];

  // `CachedNetworkImage(` 里也含有 `NetworkImage(` 子串，所以裸 NetworkImage 的
  // 判据要求前面不是标识符字符，避免把带磁盘缓存的写法误判成违规。
  final RegExp bareNetworkImage = RegExp(r'(?<![A-Za-z0-9_$])NetworkImage\(');
  final RegExp imageDotNetwork = RegExp(r'\bImage\s*\.\s*network\(');

  test('视频发现、系列与作品详情的每一处远端封面都使用磁盘缓存', () {
    final List<String> offenders = <String>[];
    for (final String path in paths) {
      final List<String> lines = File(path).readAsLinesSync();
      for (int index = 0; index < lines.length; index++) {
        final String line = lines[index];
        if (imageDotNetwork.hasMatch(line)) {
          offenders.add('$path:${index + 1}: ${line.trim()}');
        } else if (bareNetworkImage.hasMatch(line)) {
          offenders.add('$path:${index + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '远端封面只能用 CachedNetworkImageProvider，'
          '以下位置退回了仅有内存缓存的写法：\n${offenders.join('\n')}',
    );
  });

  test('被守卫的页面确实还在渲染带磁盘缓存的远端封面', () {
    for (final String path in paths) {
      expect(
        File(path).readAsStringSync(),
        contains('CachedNetworkImageProvider('),
        reason: '$path 不再出现磁盘缓存封面用法：'
            '要么封面被删（请同步收缩本守卫清单），要么被换成了别的远端图片写法',
      );
    }
  });
}
