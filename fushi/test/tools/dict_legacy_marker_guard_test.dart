import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// fushidicts 查询侧必须继续认存量的 `.hoshidicts_1` 完成标记。
///
/// 真实事故（2026-08-09，用户 Windows 实测）：改名把词典目录的完成标记从
/// `.hoshidicts_1` 换成 `.fushidicts_1`，**写入端改了，读取端也改了，但没人管
/// 用户磁盘上已经导入好的词典**——它们的标记还是旧名。而 `add_dict` 的第一行就是
/// 「没有标记就 return」，于是 26 个词典一个都没进引擎，查词永远零结果，可词典的
/// blobs.bin / hash.table / index.json 全都完好无损，元数据表 26 行也在。
///
/// 这条守卫钉死「读侧兼容旧名」。写侧不需要兼容（新导入统一用新名），也**不得**
/// 去重命名用户磁盘上的存量文件：那不可逆，且会让回退到旧版的用户反过来坏掉。
void main() {
  test('query.cpp 的完成标记/版本判定同时接受新旧全部名字', () {
    final File f = File('../native/fushidicts/fushidicts_src/query.cpp');
    expect(f.existsSync(), isTrue,
        reason: '找不到 ${f.path}——native 目录挪了就更新这条守卫，别删');
    final String src = f.readAsStringSync();

    // 上游同步批4起，标记文件名同时承担格式版本语义；单一真相源从
    // kDictCompleteMarkers 数组升级为 dict_format_version 函数。候选名必须落在
    // **函数体**里，而不是只在注释里提一句。
    final int fnStart = src.indexOf('int dict_format_version(');
    expect(fnStart, greaterThan(-1),
        reason: '标记候选名必须集中成单一真相源 dict_format_version');
    final int fnEnd = src.indexOf('\n}', fnStart);
    expect(fnEnd, greaterThan(fnStart));
    final String body = src.substring(fnStart, fnEnd);

    expect(body, contains('.fushidicts_2'),
        reason: '当前写入端（import_yomitan）产出的 v2 名字必须在候选里');
    expect(body, contains('.fushidicts_1'),
        reason: 'write_simple_dict 仍产出 v1 名字，删掉它＝MDX/StarDict 词典全失效');
    expect(body, contains('.hoshidicts_1'),
        reason: '删掉它＝所有从旧版升级上来的用户词典全部失效（查词零结果）');

    // 且 add_dict 必须真的走这个判定，而不是自己再判一次单一名字。
    final int addIdx = src.indexOf('void DictionaryQuery::add_dict');
    expect(addIdx, greaterThan(-1));
    final String addBody =
        src.substring(addIdx, (addIdx + 400).clamp(0, src.length));
    expect(addBody, contains('dict_format_version'),
        reason: 'add_dict 必须用共享判定，否则兼容改了也够不着');
    expect(addBody.contains('".fushidicts_1"'), isFalse,
        reason: 'add_dict 里不得再硬编码单一标记名——那正是本次事故的形态');
  });
}
