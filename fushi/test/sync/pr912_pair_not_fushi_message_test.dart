import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1741 收尾（PR#912 审查）：`sync_pair_not_fushi` 的后半句是一句**承诺**
/// （"The address was saved." / 「已保存该地址」），只有手动输入 IP 那条路径成立
/// ——`_addOrEditUrl` 在探测之前就 `_persistUrls()` 了。发现列表的
/// `_connectToDevice` 在同一分型上直接 return，一个字都没写库，用同一句就是在
/// 对用户撒谎。所以发现路径单独用 `sync_pair_not_fushi_discovered`。
///
/// 这条测试钉的是**两个 key 的文案差异本身**：一旦有人把「已保存该地址」补回
/// discovered 那条，或把它从手动那条删掉，分流就失去意义。
void main() {
  Map<String, dynamic> load(String file) => (jsonDecode(
        File('lib/i18n/$file').readAsStringSync(),
      ) as Map<String, dynamic>);

  test('手动路径文案保留「已保存该地址」承诺', () {
    final Map<String, dynamic> en = load('strings.i18n.json');
    final Map<String, dynamic> zh = load('strings_zh-CN.i18n.json');
    // 锚点字面量：'saved' / '已保存'
    expect(
      (en['sync_pair_not_fushi'] as String).toLowerCase(),
      contains('saved'),
      reason: '手动路径确实先落库了地址，这半句是实话，删掉等于丢信息',
    );
    expect((zh['sync_pair_not_fushi'] as String), contains('已保存'));
  });

  test('发现路径文案**不得**出现「已保存该地址」（这条分支根本不写库）', () {
    final Map<String, dynamic> en = load('strings.i18n.json');
    final Map<String, dynamic> zh = load('strings_zh-CN.i18n.json');
    final String enMsg = en['sync_pair_not_fushi_discovered'] as String;
    final String zhMsg = zh['sync_pair_not_fushi_discovered'] as String;
    expect(enMsg, isNotEmpty);
    expect(
      enMsg.toLowerCase(),
      isNot(contains('saved')),
      reason: '发现列表这条分支直接 return，承诺「已保存该地址」就是假承诺',
    );
    expect(zhMsg, isNot(contains('已保存')));
  });
}
