import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';

import '../../helpers/source_guard.dart';

/// manga-17a 守卫：Android 运行时的取图线程池宽度 = 在线直读并发 + 下载页并发。
///
/// 以前池宽写死 4，注释按「直读 3 + 下载 1」算，而下载服务默认 4 页并发：一章整章
/// 下载就把取图池占满，同时在线读另一章时直读的页全排在下载请求后面。池宽现在由
/// Kotlin 伴生对象里的两个常量相加得出，这里把它们钉在 Dart 侧真正生效的两个常量
/// 上——任一边改了另一边没跟，就红。
///
/// 仓库没有 Android JVM 单测基建，能落地的最强层是源码守卫。
void main() {
  late final String code = maskComments(
    File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    ).readAsStringSync(),
  );

  int kotlinConst(String name) {
    final RegExpMatch? match = RegExp(
      'const val $name\\s*=\\s*(\\d+)\\b',
    ).firstMatch(code);
    expect(match, isNotNull, reason: 'MihonChannelHandler.kt 里找不到 $name');
    return int.parse(match!.group(1)!);
  }

  test('Kotlin 两个并发常量与 Dart 侧一致', () {
    expect(
      kotlinConst('STREAM_PAGE_CONCURRENCY'),
      kOnlineMangaPageConcurrency,
      reason: '直读并发改了要同步 MihonChannelHandler.kt',
    );
    expect(
      kotlinConst('DOWNLOAD_PAGE_CONCURRENCY'),
      kMangaDownloadPageConcurrency,
      reason: '下载页并发改了要同步 MihonChannelHandler.kt',
    );
  });

  test('取图池宽度由两个常量相加得出，不是写死的数字', () {
    final RegExpMatch? pool = RegExp(
      r'imageExecutor\s*:\s*ExecutorService\s*=\s*'
      r'Executors\.newFixedThreadPool\(([^)]*)\)',
    ).firstMatch(code);
    expect(pool, isNotNull, reason: '找不到 imageExecutor 的建池语句');
    final Set<String> terms = pool!
        .group(1)!
        .split('+')
        .map((String term) => term.trim())
        .toSet();
    expect(terms, <String>{
      'STREAM_PAGE_CONCURRENCY',
      'DOWNLOAD_PAGE_CONCURRENCY',
    });
  });
}
