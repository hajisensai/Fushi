import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「主壳 + part 目录」型**合并语料**自身的守卫断言（TODO-2707）。
///
/// 几十到 90+ 个静态守卫读这些语料，其中大量是**负向**断言（`isNot(contains(...))`）。
/// 负向断言有个天然弱点：语料少读一个文件，它照样绿——不是被禁的符号真的没了，是根本
/// 没扫到。本文件锁住的契约就一条：**磁盘上每个 part 都必须真的进语料**。
///
/// 🔴 **为什么这里要自己再枚举一遍磁盘，而不是复用 `part_corpus.dart` 的
/// `partCorpusFiles`**：守卫和被守对象共用同一个枚举函数时，那个函数的缺陷会让双方
/// **在同一处同时失明**——枚举漏掉的文件，被守方读不到，守卫也「看不见它本该在」，于是
/// 静默双绿。本仓 `tool/bug.dart` 就踩过同型结构（`buildRenumberPlan` 与
/// `findResidualRefs` 共用 `repoScanPaths()`）。所以：
/// - 目录路径由**调用方原样再写一遍字面量**，不从生产侧常量导入——生产侧路径改了而这里
///   没跟，会当场红，而不是跟着一起漂走；
/// - 枚举实现刻意与生产侧**不同**：生产侧用 `whereType<File>()` + `endsWith('.part.dart')`，
///   这里用 `FileSystemEntity.isFileSync` + 全部 `.dart`。
///
/// 用「全部 `.dart`」而不是「全部 `.part.dart`」做基准是有意的：它同时堵住「新文件没按
/// `.part.dart` 命名，于是被生产侧的后缀过滤静默跳过」这条路——那种文件同样会被
/// `part of` 编进 library，同样能藏下被禁写法。
void expectPartManifestMatchesDisk({
  required List<String> manifest,
  required String shellPath,
  required String partDirPath,
}) {
  expect(manifest.first, shellPath,
      reason: '主壳必须恒在语料首位——多份守卫断言 build 域内 widget 的相对顺序');

  final List<String> parts = manifest.skip(1).toList();
  expect(parts, isNotEmpty,
      reason: '$partDirPath 一个 part 都没进语料——语料只剩主壳时，'
          '所有落在 part 里的负向断言都会真空通过');
  expect(parts, orderedEquals(<String>[...parts]..sort()),
      reason: '清单必须按路径排序，否则语料内容随文件系统枚举顺序漂移，'
          '「同一份代码两次运行结果不同」的守卫等于没有');

  final Directory dir = Directory(partDirPath);
  expect(dir.existsSync(), isTrue,
      reason: '$partDirPath 不存在——part 目录被搬走了，语料及其全部消费方守卫需同步更新');
  final Set<String> onDisk = dir
      .listSync(followLinks: false)
      .map((FileSystemEntity e) => e.path.replaceAll(r'\', '/'))
      .where(FileSystemEntity.isFileSync)
      .where((String p) => p.endsWith('.dart'))
      .toSet();
  expect(parts.toSet(), onDisk,
      reason: '磁盘上的 part 与语料清单必须一一对应——漏一个，落在它里面的负向断言'
          '（isNot(contains(...))）就会真空通过。'
          '若新文件不叫 *.part.dart，生产侧的后缀过滤会静默跳过它，同样算漏。');
}

/// 清单里的每个文件，内容都真的进了 [corpus]（不只是路径进了清单）。
///
/// 与 [expectPartManifestMatchesDisk] 分开断言：前者管「清单对不对」，本条管「读取
/// 环节有没有把它丢了」。两件事都会让负向断言真空通过，但成因和修法完全不同。
void expectPartContentsInCorpus({
  required List<String> manifest,
  required String corpus,
}) {
  for (final String path in manifest) {
    final String body = File(path).readAsStringSync().replaceAll('\r\n', '\n');
    // 取该文件里最长的一行当指纹：跨文件重复的概率可以忽略，且不需要人工维护。
    final String fingerprint = body
        .split('\n')
        .reduce((String a, String b) => b.length > a.length ? b : a);
    expect(fingerprint.trim(), isNotEmpty, reason: '$path 是空文件？');
    expect(corpus, contains(fingerprint),
        reason: '$path 的内容不在合并语料里——路径进了清单，但读取环节把它丢了');
  }
}
