import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 静息制卡 '+' 的「可见大小」与「可见位置」守卫。
///
/// BUG-932 / BUG-1895 两轮都在用同一条路子：'+' 是文本字形，文本字形只占 em 盒约
/// 一半高，于是放大 font-size（18px → 24px → 30px）去凑相邻 1em SVG 的可见轮廓。
/// 这条路把「可见大小」和「可见位置」绑死在同一个字号上，而字形的垂直位置根本不由
/// 布局决定，只由字体度量决定：墨迹中心相对行几何中心的偏移
/// = (ascent - descent) / 2 - 数学轴。Edge 4x 像素实测 Segoe UI 与 Segoe UI Symbol
/// 同为 +0.125em、DejaVu Sans +0.066em、Roboto ≈ +0.02em、Arial 0.000em——所以
/// Windows 上 '+' 天生比同排图标低 0.125em，且字号越大偏得越多：24px 偏低 3.0px，
/// BUG-1895 为补大小改到 30px 后偏低 3.75px（用户「加号还是低了」= BUG-1923）。
///
/// BUG-1923 的根治不是再调一次字号、也不是加一个 translateY 常量（补偿量随平台实际
/// 命中的字体在 0 ~ 0.125em 之间变，把 Windows 补正就会把 Arial/Roboto 反向补歪），
/// 而是让静息 '+' 不再由字形绘制：两条以按钮盒为参照绝对居中的矩形拼出十字，位置与
/// 大小都与任何平台字体无关。下面锁住这组不变式，防止回退成字形补偿。
void main() {
  // 静息 '+' 的样式在 5 份产物里都要成立：app 内弹窗 popup.css（真源）、两处扩展
  // vendor popup.css 字节镜像，以及由 popup.css 生成的两份扩展 content.css——把
  // content.css 一并锁住，才能抓到「改了 popup.css 但忘了重新生成 content.css」。
  const Map<String, String> cssMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension asset': 'assets/browser_extension/vendor/popup.css',
    'extension source': '../tools/browser-extension/vendor/popup.css',
    'extension content.css (assets)':
        'assets/browser_extension/vendor/content.css',
    'extension content.css (tools)':
        '../tools/browser-extension/vendor/content.css',
  };
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension asset': 'assets/browser_extension/vendor/popup.js',
    'extension source': '../tools/browser-extension/vendor/popup.js',
  };

  // 静息态主规则块（`\s*\{` 只会命中规则本体，不会命中 `::before,` / `::after` 那条
  // 组合选择器，因为后者在类名后紧跟的是 `::`）。
  final RegExp staticBlock = RegExp(
    r'\.mine-button:not\(\.duplicate\)\s*\{([^}]*)\}',
  );
  final RegExp beforeArm = RegExp(
    r'\.mine-button:not\(\.duplicate\)::before\s*\{\s*width:\s*([\d.]+)em;\s*height:\s*([\d.]+)em;\s*\}',
  );
  final RegExp afterArm = RegExp(
    r'\.mine-button:not\(\.duplicate\)::after\s*\{\s*width:\s*([\d.]+)em;\s*height:\s*([\d.]+)em;\s*\}',
  );

  for (final MapEntry<String, String> mirror in cssMirrors.entries) {
    group('[${mirror.key}] 静息制卡 + 的几何绘制', () {
      late String css;
      late String staticBody;

      setUpAll(() {
        css = File(mirror.value).readAsStringSync();
        final RegExpMatch? m = staticBlock.firstMatch(css);
        expect(m, isNotNull, reason: '缺 .mine-button:not(.duplicate) 静息态规则块');
        staticBody = m!.group(1)!;
      });

      test('字形不参与呈现（可见形状不再取决于字体度量）', () {
        expect(
          RegExp(
            r'-webkit-text-fill-color\s*:\s*transparent',
          ).hasMatch(staticBody),
          isTrue,
          reason:
              'BUG-1923：静息 + 必须关掉文本填充，可见十字改由伪元素几何绘制；'
              '否则字形重新参与呈现，位置又会被字体度量拉低（Windows 实测 0.125em）。',
        );
      });

      test('十字两条臂以按钮盒为参照绝对居中', () {
        final RegExpMatch? arms = RegExp(
          r'\.mine-button:not\(\.duplicate\)::before,\s*\.mine-button:not\(\.duplicate\)::after\s*\{([^}]*)\}',
        ).firstMatch(css);
        expect(
          arms,
          isNotNull,
          reason: 'BUG-1923：缺 ::before/::after 共享块，静息 + 没有几何绘制的十字',
        );
        final String body = arms!.group(1)!;
        for (final String decl in <String>[
          r"content\s*:\s*''",
          r'position\s*:\s*absolute',
          r'top\s*:\s*50%',
          r'left\s*:\s*50%',
          r'transform\s*:\s*translate\(\s*-50%\s*,\s*-50%\s*\)',
          r'background\s*:\s*currentColor',
        ]) {
          expect(
            RegExp(decl).hasMatch(body),
            isTrue,
            reason:
                'BUG-1923：十字臂缺 `$decl`。居中必须相对按钮的 padding box '
                '（按钮盒本身由 .header-buttons 的 align-items:center 精确居中），'
                '这样加号的可见中心才恒等于同排 SVG 图标的中心。',
          );
        }
      });

      test('横臂与竖臂互为转置且用 em（跟随内容缩放）', () {
        final RegExpMatch? b = beforeArm.firstMatch(css);
        final RegExpMatch? a = afterArm.firstMatch(css);
        expect(
          b,
          isNotNull,
          reason:
              'BUG-1923：::before 横臂必须声明 em 单位的 width/height；'
              '绝对 px 不跟踪弹窗内容缩放。',
        );
        expect(
          a,
          isNotNull,
          reason:
              'BUG-1923：::after 竖臂必须声明 em 单位的 width/height；'
              '绝对 px 不跟踪弹窗内容缩放。',
        );
        final double bw = double.parse(b!.group(1)!);
        final double bh = double.parse(b.group(2)!);
        final double aw = double.parse(a!.group(1)!);
        final double ah = double.parse(a.group(2)!);
        expect(bw, greaterThan(bh), reason: 'BUG-1923：::before 是横臂，宽必须大于高');
        expect(
          <double>[aw, ah],
          <double>[bh, bw],
          reason:
              'BUG-1923：竖臂必须是横臂的转置（改一条就要同步改另一条），'
              '否则十字不再等臂。',
        );
      });

      test('静息态本体不得再靠字号或垂直位移补偿字形', () {
        expect(
          RegExp(r'translateY|translate\s*\(').hasMatch(staticBody),
          isFalse,
          reason:
              'BUG-1923：静息态本体不得加 translate/translateY 去「补正」加号位置——'
              '补偿量随平台实际命中的字体在 0 ~ 0.125em 之间变，补正 Windows 就会把 '
              'Arial/Roboto 那类本来就居中的字体反向补歪。可见位置由伪元素几何决定。',
        );
      });
    });
  }

  for (final MapEntry<String, String> mirror in jsMirrors.entries) {
    test('[${mirror.key}] 制卡按钮复用可点击的动作按钮布局', () {
      final String js = File(mirror.value).readAsStringSync();
      expect(
        js,
        contains("className: 'inline-action-button mine-button'"),
        reason:
            'BUG-1895: shared class provides inline-flex centering and pointer cursor',
      );
    });

    test('[${mirror.key}] 静息态 textContent 仍是 + 文本标记', () {
      final String js = File(mirror.value).readAsStringSync();
      expect(
        RegExp(r'mineButton\.textContent\s*=\s*isMined\s*\?').hasMatch(js),
        isTrue,
        reason:
            'BUG-1923：可见十字改成几何绘制后，textContent 仍必须是 + / ✓ / ✓↩ '
            '文本标记（TODO-1325 用户要求，且无障碍朗读与 setMineState 状态机依赖它）。',
      );
    });
  }
}
