import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// app 外全局查词卡片「右上/右下圆角消失、左上/左下正常」的防回退守卫（三镜像）。
///
/// 根因：`html.global-lookup { background: transparent }` 让 documentElement 变成
/// 「无背景」，CSS 背景传播规则（css-backgrounds-3 §2.11.2）于是把 `body` 的背景提升
/// 为**画布背景** —— 画布背景铺满视口且永远方角，`body` 自身不再绘制该背景，它的
/// `border-radius: 10px` 就只剩那 1px 边框线还圆。卡片的圆角外观因此寄生在外层 shell
/// 的 `overflow:hidden + border-radius` 裁剪上，只有卡片内容区右缘与 shell 右缘恰好
/// 重合时才成立；文档一旦出现占位式垂直滚动条，gutter 把内容区右缘推开约 9 CSS px，
/// 右侧那两刀裁在空处 → 右上/右下露出方角画布底色，左缘永远重合所以左边一直是好的。
///
/// 修法：给 documentElement 一个「存在但完全透明」的背景层，传播就不发生，body 的
/// 填充留在 body 自己身上被自己的圆角裁剪 —— 四角**自足**地圆，不再依赖外层裁剪。
///
/// 本守卫锁两件事，任一被改回去都红：
///   1. `html.global-lookup` 必须声明一个真实背景层（`linear-gradient(...)`），
///      不能退回裸 `background: transparent` / `background: none`（那等于恢复传播）。
///   2. 该背景层必须全透明（只允许 alpha 为 0 的颜色停靠点），否则 TODO-893 症状 2
///      的「不透明主题色填满方形 iframe → 被 shell 裁成一圈白框」会回归。
///   3. `html.global-lookup body` 仍要有 border-radius —— 卡片圆角的唯一来源。
///
/// 注意：断言前必须掩掉 CSS 注释再看声明。上面这段说明和 popup.css 里的注释都包含
/// `background: transparent` 字样，直接对原文 grep 会假阳/假阴（见 CLAUDE.md 的
/// 源码扫描守卫纪律）。掩码走共享的 `helpers/source_guard.dart`（`maskCssComments`
/// 是**等长**掩码，注释内容变空格、换行保留），不手写剥离：删除式剥离会让后续
/// indexOf/substring 的下标与原文错位，且块注释形态漏剪会让要求型断言被注释骗绿
/// —— 这正是 `source_guard_adoption_test` 锁的那条纪律。
///
/// flutter test cwd 是 fushi 包根。
void main() {
  /// 抽取 `<selector> { ... }` 规则块（行首锚定，避免命中后代规则）。
  String ruleBody(String css, String selectorPattern) {
    final RegExp re = RegExp(r'(?:^|\n)' + selectorPattern + r'\s*\{([^}]*)\}');
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull, reason: 'rule "$selectorPattern" not found');
    return m!.group(1)!;
  }

  const Map<String, String> cssMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };

  cssMirrors.forEach((String name, String relPath) {
    group('[$name] app 外全局查词卡片圆角', () {
      late final String css;
      setUpAll(() {
        css = maskCssComments(File(relPath).readAsStringSync());
      });

      test('html.global-lookup 声明真实背景层，阻止 body 背景传播成方角画布底', () {
        final String body = ruleBody(css, r'html\.global-lookup');
        final RegExp backgroundDecl =
            RegExp(r'(?:^|[;{\s])background(?:-image)?\s*:([^;]*)');
        final RegExpMatch? decl = backgroundDecl.firstMatch(body);
        expect(decl, isNotNull,
            reason: 'html.global-lookup 必须显式声明背景，否则会继承 html,body 的不透明主题色');

        final String value = decl!.group(1)!.trim();
        expect(value.contains('linear-gradient'), isTrue,
            reason: '必须是一个真实存在的背景层（全透明渐变）。裸 transparent/none 会让 '
                'documentElement 变成「无背景」，body 背景被提升为方角画布背景，'
                '卡片右上/右下圆角随即消失');
      });

      test('该背景层全透明，不会让 TODO-893 的方形「白框」回归', () {
        final String body = ruleBody(css, r'html\.global-lookup');
        final RegExp colorStop = RegExp(r'rgba?\(([^)]*)\)');
        final Iterable<RegExpMatch> stops = colorStop.allMatches(body);
        expect(stops, isNotEmpty, reason: '渐变必须用 rgba() 颜色停靠点，便于机器校验 alpha');
        for (final RegExpMatch stop in stops) {
          final List<String> parts =
              stop.group(1)!.split(',').map((String s) => s.trim()).toList();
          expect(parts.length, 4,
              reason: '颜色停靠点必须写成 rgba(r, g, b, a) 四元组：${stop.group(0)}');
          expect(double.parse(parts[3]), 0,
              reason: '停靠点 alpha 必须为 0（纯透明层），否则会在卡片外画出不透明方角：'
                  '${stop.group(0)}');
        }
      });

      test('html.global-lookup body 仍是圆角卡片（圆角的唯一来源）', () {
        final String body = ruleBody(css, r'html\.global-lookup body');
        expect(RegExp(r'border-radius\s*:').hasMatch(body), isTrue,
            reason: '卡片圆角由 body 自己画；去掉它，四角只能靠外层 shell 裁剪碰运气');
        expect(RegExp(r'(^|[;{\s])border\s*:').hasMatch(body), isTrue,
            reason: '卡片 1px 描边与圆角同属一套卡片 chrome');
      });
    });
  });
}
