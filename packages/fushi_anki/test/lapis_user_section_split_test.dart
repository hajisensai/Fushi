// PR#457 审查 §10-2（用户拍板方案甲）守卫：从备份恢复之后，字号选择器必须与
// 卡片上实际生效的字号一致。
//
// 修复前：恢复把整段用户区段（含 Hibiki 生成的 `:root` 缩放块）塞进
// `lapisCustomCss` 并把百分比归 100。之后用户再调字号，新缩放块排在正文之前、
// 旧缩放块排在之后，两块特异性相同 → 后者胜出 → 选择器成了死控件。
//
// 这里锁死逆运算 [splitLapisUserSectionBody] 的契约：正文能被拆回
// 「百分比 + 自由 CSS」，且拆出来的自由 CSS 里**不再残留缩放块**。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

void main() {
  test('每个档位都能原样往返（buildLapisUserSectionBody 的逆运算）', () {
    for (final int percent in kLapisFontScalePresets) {
      final String body = buildLapisUserSectionBody(
        fontScalePercent: percent,
        customCss: '.mine { color: #0f0; }',
      );
      final LapisUserSectionSplit split = splitLapisUserSectionBody(body);
      expect(split.fontScalePercent, percent, reason: '档位 $percent 反解失败');
      expect(split.customCss, '.mine { color: #0f0; }');
    }
  });

  test('档位之间产出的缩放块互不相同（反解不会张冠李戴）', () {
    final Map<String, int> seen = <String, int>{};
    for (final int percent in kLapisFontScalePresets) {
      final String css = buildLapisFontScaleCss(percent);
      if (percent == 100) {
        expect(css, isEmpty);
        continue;
      }
      expect(seen.containsKey(css), isFalse,
          reason: '$percent% 与 ${seen[css]}% 产出了同一份缩放块');
      seen[css] = percent;
    }
  });

  test('只有缩放块 / 只有自由 CSS / 空正文', () {
    expect(
      splitLapisUserSectionBody(buildLapisFontScaleCss(125)).fontScalePercent,
      125,
    );
    expect(
      splitLapisUserSectionBody(buildLapisFontScaleCss(125)).customCss,
      isEmpty,
    );
    final LapisUserSectionSplit onlyCustom =
        splitLapisUserSectionBody('.a { color: red; }');
    expect(onlyCustom.fontScalePercent, 100);
    expect(onlyCustom.customCss, '.a { color: red; }');
    expect(splitLapisUserSectionBody('').fontScalePercent, 100);
    expect(splitLapisUserSectionBody('').customCss, isEmpty);
  });

  test('用户手写的 :root 块不会被误认成 Hibiki 缩放块', () {
    const String handWritten = ':root {\n  --pc-vocab-font-size: 99px;\n}';
    final LapisUserSectionSplit split = splitLapisUserSectionBody(handWritten);
    expect(split.fontScalePercent, 100);
    expect(split.customCss, handWritten);
  });

  test('恢复语义：选择器读到备份当时的字号，且自由 CSS 里不再残留缩放块', () {
    final String backupCss = composeLapisCss(
      fontScalePercent: 125,
      customCss: '.mine { color: #0f0; }',
    );
    final String body = extractLapisUserSectionBody(backupCss)!;
    final LapisUserSectionSplit split = splitLapisUserSectionBody(body);

    expect(split.fontScalePercent, 125);
    expect(split.customCss, isNot(contains('--pc-')));
    expect(split.customCss, isNot(contains('--mobile-')));
    // 期望态必须逐字节等于恢复态，否则下次启动的漂移判定会把刚恢复的内容覆写。
    expect(
      composeLapisCss(
        fontScalePercent: split.fontScalePercent,
        customCss: split.customCss,
      ),
      backupCss,
    );
  });

  test('恢复之后再调字号：旧缩放块不会残留下来盖住新的（本条就是原 bug）', () {
    final String backupCss =
        composeLapisCss(fontScalePercent: 125, customCss: '.mine { }');
    final LapisUserSectionSplit split =
        splitLapisUserSectionBody(extractLapisUserSectionBody(backupCss)!);

    final String afterUserPicks150 = composeLapisCss(
      fontScalePercent: 150,
      customCss: split.customCss,
    );
    // 修复前 customCss == 整段正文，125% 的块会跟着一起被写回去并排在 150%
    // 之后胜出；现在它必须彻底消失。
    expect(afterUserPicks150.contains(buildLapisFontScaleCss(125)), isFalse);
    expect(afterUserPicks150.contains(buildLapisFontScaleCss(150)), isTrue);
  });
}
