@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_seamless_chapters_script.dart';
import 'package:test/test.dart';

import '../helpers/node_runtime.dart';

/// novel-d6：网页小说书阅读中途 spine 末尾长出新章时，已装文档的无缝阅读序接上新章。
///
/// 阅读序只在装页时随配置下发一次；宿主并进新章后用
/// [readerSeamlessExtendOrderInvocation] 生成的调用把新章接到 ORDER 末尾。这里把生产
/// 安装脚本与生产生成的调用放进真 Chrome，断言：正读着原来末章时新章作为下一章挂上；
/// 章号不大于现有末章的重复下发不改序、不重复取。
void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe(needsChrome: true);

  test(
    'appended chapters extend the seamless order and mount after the old last '
    'chapter',
    () async {
      final String node = runtime.requireNode();
      final Process process = await Process.start(node, <String>[
        'test/reader/seamless_extend_order_harness.mjs',
      ]);
      final Future<String> stdout = process.stdout
          .transform(utf8.decoder)
          .join();
      final Future<String> stderr = process.stderr
          .transform(utf8.decoder)
          .join();
      process.stdin.add(
        utf8.encode(
          jsonEncode(<String, String>{
            'seamless': kSeamlessChaptersInstallJs,
            'extend': readerSeamlessExtendOrderInvocation(
              const <ReaderSeamlessChapterEntry>[
                ReaderSeamlessChapterEntry(
                  index: 2,
                  url: 'http://book.test/ch2.xhtml',
                ),
              ],
            ),
            'extendStale': readerSeamlessExtendOrderInvocation(
              const <ReaderSeamlessChapterEntry>[
                ReaderSeamlessChapterEntry(
                  index: 1,
                  url: 'http://book.test/ch1.xhtml',
                ),
                ReaderSeamlessChapterEntry(
                  index: 2,
                  url: 'http://book.test/ch2.xhtml',
                ),
              ],
            ),
          }),
        ),
      );
      await process.stdin.close();
      final int exitCode = await process.exitCode;
      final String out = await stdout;
      expect(exitCode, 0, reason: '$out\n${await stderr}');
      expect(out, contains('PASS seamless extend order'));
    },
    skip: runtime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
