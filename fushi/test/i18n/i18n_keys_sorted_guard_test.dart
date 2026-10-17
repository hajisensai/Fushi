import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/i18n_sync.dart';

/// 17 份 i18n json 的顶层 key 必须严格按字典序排列，且文件字节与
/// `i18n_sync.dart` 的写出格式一致。
///
/// 为什么钉死：旧做法把新 key 追加到文件末尾，任意两条加 key 的并发 PR 都改
/// 同一处尾部，合并必冲突。全排序后每个 key 只有一个合法位置，`--add` 插到
/// 该位置，不同 PR 的新增落在文件各处，git 能按行合并；相邻 key 剩下的冲突由
/// 按 key 三方合并的驱动（`tool/i18n_merge_driver.dart`）解决。手改 json 往末尾
/// 一追加，这里就红——修法是 `dart tool/i18n_sync.dart --sort`。
void main() {
  final Directory i18nDir = Directory('lib/i18n');
  final List<File> files =
      i18nDir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.i18n.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test('i18n 文件数量（防止扫描路径失效变成空壳）', () {
    expect(files, hasLength(17));
  });

  for (final File file in files) {
    final String name = file.uri.pathSegments.last;
    test('$name 顶层 key 严格按字典序且为 i18n_sync 写出格式', () {
      final String text = file.readAsStringSync();
      final Map<String, dynamic> json =
          jsonDecode(text) as Map<String, dynamic>;
      final List<String> keys = json.keys.toList();
      final List<String> outOfOrder = <String>[
        for (int i = 1; i < keys.length; i++)
          if (keys[i - 1].compareTo(keys[i]) >= 0)
            '${keys[i - 1]} > ${keys[i]}',
      ];
      expect(
        outOfOrder,
        isEmpty,
        reason:
            '$name 有乱序 key（前 5 处）：${outOfOrder.take(5).join('; ')}。'
            '新增 key 请用 dart tool/i18n_sync.dart --add，修复跑 --sort',
      );
      expect(
        text.replaceAll('\r\n', '\n'),
        encodeI18nJson(json),
        reason: '$name 不是 i18n_sync 的写出格式（缩进 / 结尾换行），跑 --sort 重写',
      );
    });
  }

  test('.gitattributes 把 i18n json 接到按 key 合并驱动', () {
    final String attributes = File('../.gitattributes').readAsStringSync();
    expect(
      attributes,
      contains('fushi/lib/i18n/*.i18n.json merge=fushi-i18n-json'),
    );
    final String setup = File('../tool/setup_worktree.ps1').readAsStringSync();
    expect(
      setup,
      contains(
        'merge.fushi-i18n-json.driver "dart fushi/tool/i18n_merge_driver.dart %O %A %B"',
      ),
    );
  });
}
