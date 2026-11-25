import 'dart:io';

import 'package:test/test.dart';

import '../helpers/source_guard.dart';

/// fushidicts 查询侧必须继续认存量的 `.hoshidicts_1` 完成标记。
///
/// 真实事故（2026-08-09，用户 Windows 实测）：改名把词典目录的完成标记从
/// `.hoshidicts_1` 换成 `.fushidicts_1`，**写入端改了，读取端也改了，但没人管
/// 用户磁盘上已经导入好的词典**——它们的标记还是旧名。而 `add_dict` 的第一行就是
/// 「没有标记就 return」，于是 26 个词典一个都没进引擎，查词永远零结果，可词典的
/// blobs.bin / hash.table / index.json 全都完好无损，元数据表 26 行也在。
///
/// 这条守卫钉死「读侧兼容旧名」。写侧不需要兼容（新导入统一用新名）。唯一会改动
/// 存量标记的是 key.index 原地升级（upgrade.cpp）：索引换成 key.index 之后旧引擎本来
/// 就读不了，标记随之换成 `.fushidicts_3`，让旧引擎「不加载」而不是静默查不到词
/// （拍板台 pr3554，维护者 2026-11-17 拍板「升一下」）。
void main() {
  const String srcDir = '../native/fushidicts/fushidicts_src';

  String readSource(String relative) {
    final File f = File('$srcDir/$relative');
    expect(
      f.existsSync(),
      isTrue,
      reason: '找不到 ${f.path}——native 目录挪了就更新这条守卫，别删',
    );
    return f.readAsStringSync();
  }

  String functionBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(-1), reason: '找不到 $signature');
    final int end = src.indexOf('\n}', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  test('完成标记/版本判定（util/dict_marker.hpp）同时接受新旧全部名字', () {
    final String marker = readSource('util/dict_marker.hpp');

    // 四个名字以常量形式落在代码里（不是只在注释里提一句）。
    for (final String name in <String>[
      '.fushidicts_3',
      '.fushidicts_2',
      '.fushidicts_1',
      '.hoshidicts_1',
    ]) {
      expect(
        marker,
        contains('= "$name";'),
        reason: '$name 必须是 dict_marker.hpp 里的常量',
      );
    }

    // 读侧判定：record_version 先看 .fushidicts_3，否则落到旧式三名。
    final String recordVersion = functionBody(
      marker,
      'inline int record_version(',
    );
    expect(recordVersion, contains('kKeyIndexMarker'));
    expect(recordVersion, contains('legacy_record_version'));
    final String legacy = functionBody(
      marker,
      'inline int legacy_record_version(',
    );
    expect(
      legacy,
      contains('kV2Marker'),
      reason: '退回旧式索引的 import_yomitan 仍产出 v2 名字',
    );
    expect(
      legacy,
      contains('kV1Marker'),
      reason: 'write_simple_dict 退回旧式索引时仍产出 v1 名字，删掉它＝MDX/StarDict 词典全失效',
    );
    expect(
      legacy,
      contains('kLegacyV1Marker'),
      reason: '删掉它＝所有从旧版升级上来的用户词典全部失效（查词零结果）',
    );
  });

  test('query.cpp 的 add_dict 走共享判定', () {
    final String src = readSource('query.cpp');
    final String fn = functionBody(src, 'int dict_format_version(');
    expect(
      fn,
      contains('dict_marker::record_version'),
      reason: 'dict_format_version 必须委托给单一真相源',
    );

    // 且 add_dict 必须真的走这个判定，而不是自己再判一次单一名字。
    final int addIdx = src.indexOf('void DictionaryQuery::add_dict');
    expect(addIdx, greaterThan(-1));
    final String addBody = src.substring(
      addIdx,
      (addIdx + 400).clamp(0, src.length),
    );
    expect(
      addBody,
      contains('dict_format_version'),
      reason: 'add_dict 必须用共享判定，否则兼容改了也够不着',
    );
    expect(
      addBody.contains('".fushidicts_1"'),
      isFalse,
      reason: 'add_dict 里不得再硬编码单一标记名——那正是本次事故的形态',
    );
  });

  test('别处不再硬编码标记名（只在 dict_marker.hpp 定义）', () {
    for (final String relative in <String>[
      'query.cpp',
      'importer.cpp',
      'upgrade.cpp',
      'util/redirect_glossary.cpp',
    ]) {
      final String src = maskComments(readSource(relative));
      expect(
        RegExp(r'"/?\.(fushidicts|hoshidicts)_\d"').hasMatch(src),
        isFalse,
        reason: '$relative 里出现了硬编码的完成标记名，改用 dict_marker 常量',
      );
    }
  });
}
