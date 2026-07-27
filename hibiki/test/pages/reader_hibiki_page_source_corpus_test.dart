import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// 「合并语料」自身的守卫。
///
/// 90+ 个静态守卫读 [readReaderPageSource]，其中 25 个文件里带 `isNot(contains(...))`
/// 这类**负向**断言。负向断言有个天然弱点：语料少读一个文件，它照样绿——不是符号真的
/// 没了，是根本没扫到。清单以前是手写常量，新增 / 改名一个 part 就正好制造这种真空。
///
/// 清单已改成从磁盘枚举，本文件锁住这条契约：磁盘上每个 part 都必须真的进语料。
void main() {
  group('阅读器页合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 *.part.dart 都在清单里，且顺序确定', () {
      final List<String> files = readerHibikiPageFiles();
      expect(
          files.first, 'lib/src/pages/implementations/reader_hibiki_page.dart');
      final List<String> parts = files.skip(1).toList();
      expect(parts, isNotEmpty);
      expect(parts, orderedEquals(<String>[...parts]..sort()),
          reason: '清单必须按路径排序，否则语料内容随文件系统枚举顺序漂移');

      final Set<String> onDisk =
          Directory('lib/src/pages/implementations/reader_hibiki')
              .listSync()
              .whereType<File>()
              .map((File f) => f.path.replaceAll(r'\', '/'))
              .where((String p) => p.endsWith('.part.dart'))
              .toSet();
      expect(parts.toSet(), onDisk,
          reason: '磁盘上的 part 与语料清单必须一一对应——漏一个，'
              '落在它里面的负向断言（isNot(contains(...))）就会真空通过');
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      final String corpus = readReaderPageSource();
      for (final String path in readerHibikiPageFiles()) {
        final String body = File(path).readAsStringSync().replaceAll(
              '\r\n',
              '\n',
            );
        // 取该文件里最长的一行当指纹：跨文件重复的概率可以忽略，且不需要人工维护。
        final String fingerprint = body
            .split('\n')
            .reduce((String a, String b) => b.length > a.length ? b : a);
        expect(fingerprint.trim(), isNotEmpty, reason: '$path 是空文件？');
        expect(corpus, contains(fingerprint),
            reason: '$path 的内容不在合并语料里——读取环节把它丢了');
      }
    });
  });
}
