import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：`AppModel.targetLanguage` 假抽象不得复活。
///
/// 历史：app 曾有 ja/en/zh 三个 Language 子类 + `setTargetLanguage`，但语言选择
/// 从未有 UI 调用方，2026-06-05（c51330b5b / 78f01e246）删光了 en/zh 与 setter，
/// getter 钉死返回 [JapaneseLanguage.instance]——一个假装可配置、实际恒定的
/// 间接层。2026-07-26 按用户指令整体删除：日语专属功能（振假名/音高/字体/
/// 字幕语言码/helloWorld 预热等）直接引用 `JapaneseLanguage.instance`。
///
/// 注意这**不**影响多语言查词：查词流水线（trie 命中 + 去屈折）语言无关，
/// 18 种语言变换表全量加载是有意设计（deinflector 条件按 lang:key 命名空间
/// 隔离），从来不经过 targetLanguage。
void main() {
  test('AppModel 不再声明或访问 targetLanguage', () {
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    // 钉具体形态而非任意出现（历史说明注释允许提到这个名字）。
    expect(
      appModel.contains(RegExp(r'get\s+targetLanguage|targetLanguage\s*=>'
          r'|\.targetLanguage\b|targetLanguage\.')),
      isFalse,
      reason: '假抽象已删——日语专属功能直接用 JapaneseLanguage.instance，'
          '别再引入恒定单值的 targetLanguage 间接层',
    );
  });
}
