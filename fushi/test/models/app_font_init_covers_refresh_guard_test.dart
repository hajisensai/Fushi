import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 首帧前的字体装载（`AppModel.initialise` 里那一段）必须覆盖 `refreshAppFont` 填的
/// **每一个**字体字段。
///
/// 回归背景（SRS「吃掉字体」）：`refreshAppFont` 早就解析了复习卡片用途
/// （`FontTarget.srsCard`）并写 `_srsCardFonts` / `_srsCardFontFamilies`，但 init 只装了
/// appUi / 视频字幕 / 游戏文本三条链。于是每次启动后复习卡面都没有字体库字体，直到用户
/// 在字体库里随手关掉再打开一个开关（触发 `refreshAppFont`）才生效。新加字体用途时只改
/// 其中一处是静默的（编译、单测都绿），所以用源码扫描把两处钉成同一份字段集合。
void main() {
  test('init 的字体装载覆盖 refreshAppFont 写的全部字段', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();

    final int refreshStart = src.indexOf(
      'Future<void> refreshAppFont() async {',
    );
    expect(refreshStart, isNonNegative, reason: '找不到 refreshAppFont');
    final int refreshEnd = src.indexOf('\n  }\n', refreshStart);
    expect(refreshEnd, greaterThan(refreshStart));
    final String refreshBody = src.substring(refreshStart, refreshEnd);

    final Set<String> refreshFields = <String>{
      for (final RegExpMatch m in RegExp(
        r'^\s*(_\w+)\s*=\s',
        multiLine: true,
      ).allMatches(refreshBody))
        m.group(1)!,
    };
    expect(
      refreshFields,
      containsAll(<String>['_appFontFamilies', '_srsCardFonts']),
      reason: 'refreshAppFont 的字段赋值没扫到，守卫退化成空壳',
    );

    // init 那一段：从首帧前注册字体的注释起，到把 readerSettings 交给阅读源为止。
    final int initStart = src.indexOf(
      "Register the user's custom app-wide fonts",
    );
    expect(initStart, isNonNegative, reason: '找不到 init 的字体装载段');
    final int initEnd = src.indexOf(
      'ReaderFushiSource.readerSettings = readerSettings;',
      initStart,
    );
    expect(initEnd, greaterThan(initStart));
    final String initBody = src.substring(initStart, initEnd);

    for (final String field in refreshFields) {
      expect(
        RegExp(
          '^\\s*${RegExp.escape(field)}\\s*=\\s',
          multiLine: true,
        ).hasMatch(initBody),
        isTrue,
        reason:
            'refreshAppFont 会写 $field，但首帧前的 init 没写：启动后这个字体用途'
            '一直是空的，要等用户改一次字体设置才生效',
      );
    }
  });
}
