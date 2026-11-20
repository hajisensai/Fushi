import 'dart:io';

import 'package:test/test.dart';

import '../helpers/source_guard.dart';

/// 远端封面必须走 `AppCachedHttpImage`（`extends CachedNetworkImageProvider`，
/// 磁盘缓存语义不变，另外把请求接进全应用代理装配 —— 裸
/// `CachedNetworkImageProvider` 已被 network_image_proxy_guard_test 禁掉），
/// 而不是只有内存缓存的 `NetworkImage` / `Image.network`。
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
    // 刮削图远程回落的共用 provider（#3722 video-18）：库页与作品详情页经它取图。
    'lib/src/media/video/metadata/video_metadata_image_provider.dart',
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
      reason:
          '远端封面只能用 AppCachedHttpImage，'
          '以下位置退回了仅有内存缓存的写法：\n${offenders.join('\n')}',
    );
  });

  test('被守卫的页面确实还在渲染带磁盘缓存的远端封面', () {
    for (final String path in paths) {
      // 直接写 `AppCachedHttpImage(`，或经共用的 `metadataRemoteImage(`（它本身在
      // 清单里，内部就是 AppCachedHttpImage + 解码上限）。
      expect(
        File(path).readAsStringSync(),
        anyOf(
          contains('AppCachedHttpImage('),
          contains('metadataRemoteImage('),
        ),
        reason:
            '$path 不再出现磁盘缓存封面用法：'
            '要么封面被删（请同步收缩本守卫清单），要么被换成了别的远端图片写法',
      );
    }
  });

  // #3722 video-18：库页（剧照 / 作品图远程回落、hero）与作品详情页的远端图全是
  // 刮削图（默认 TMDB 原图），必须经 `metadataRemoteImage` 带解码上限。这两页里
  // 再出现裸 `AppCachedHttpImage(` 就是整帧解码退回来了——库页那两处远程回落
  // 只有本守卫兜着（页面状态太重，没有行为级用例覆盖）。
  test('库页与作品详情页的远端刮削图不裸用 AppCachedHttpImage', () {
    final RegExp bareCachedHttpImage = identifierCall(
      'AppCachedHttpImage',
      allowNamedConstructor: false,
    );
    final List<String> offenders = <String>[];
    for (final String path in const <String>[
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/video_work_detail_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      // maskComments 保持长度与换行位置不变：在掩码串上匹配（行注释、块注释、
      // 行尾注释里的字面量都不算），再拿下标回原串报行号与原文。
      final String code = maskComments(source);
      final List<String> lines = source.split('\n');
      for (final RegExpMatch match in bareCachedHttpImage.allMatches(code)) {
        final int lineIndex = '\n'
            .allMatches(code.substring(0, match.start))
            .length;
        offenders.add('$path:${lineIndex + 1}: ${lines[lineIndex].trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '刮削图远端地址要经 metadataRemoteImage（AppCachedHttpImage + 解码上限），'
          '以下位置退回了整帧解码：\n${offenders.join('\n')}',
    );
  });
}
