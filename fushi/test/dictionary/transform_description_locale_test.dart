// BUG-2038：界面语言标签 → 译文资产候选名的解析顺序。
//
// 17 种界面语言里有 `zh-CN` / `zh-HK` / `pt-BR` 这种带地区的标签，译文资产按需要
// 可以只放语言级的一份（`zh.json`），所以解析必须是「完整标签 → 仅语言」两级。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/dictionary/transform_description_locale.dart';

void main() {
  test('带地区的标签先找完整标签，再回落到语言级', () {
    expect(transformDescriptionLocaleCandidates('zh-CN'), <String>[
      'zh-CN',
      'zh',
    ]);
    expect(transformDescriptionLocaleCandidates('pt-BR'), <String>[
      'pt-BR',
      'pt',
    ]);
  });

  test('纯语言标签只有一个候选', () {
    expect(transformDescriptionLocaleCandidates('ja'), <String>['ja']);
  });

  test('容忍 Locale.toString() 的下划线写法', () {
    expect(transformDescriptionLocaleCandidates('zh_CN'), <String>[
      'zh-CN',
      'zh',
    ]);
  });

  test('空标签不产生候选（避免去加载 .json 这种路径）', () {
    expect(transformDescriptionLocaleCandidates(''), isEmpty);
    expect(transformDescriptionLocaleCandidates('   '), isEmpty);
  });
}
