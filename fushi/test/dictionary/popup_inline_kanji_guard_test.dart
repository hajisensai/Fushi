import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// design-2026-08 讨论区反馈守卫：词头汉字**内联**可点，旧 kanji-breakdown chip 行不得复活。
///
/// 为什么需要这条守卫：删除工作本身在 2026-08-15 就做完了（`851d6089ff`，三镜像同步
/// 全到位），但那个提交**从没开过 PR、从没合并进 develop**，只活在一个孤儿分支上。
/// 于是「同一个汉字在词头下面再重复一排灰方块才可点」的旧 UI 在 develop 上原封不动
/// 继续跑了 8 天，直到用户截图报「我记得这两个字我删掉了来着」。
///
/// 代码层面没有任何东西能发现这种「删除从未落地」——三份镜像彼此一致（都是旧的），
/// 定向测试按功能域挑也挑不到一个「本该不存在」的函数。这条守卫就是那个缺失的断言：
/// 把「chip 行已死、内联可点是唯一形态」钉成三镜像上的结构不变式。
///
/// 断言必须跑在**掩码后**的语料上：三份 popup.js / popup.css 的解释性注释里至今仍
/// 写着 `kanji-breakdown` 与 `kanji-tag`（说明这段历史），裸 `contains` 会被注释喂成
/// 假红；反过来，若有人删掉实现只留同文注释，不掩码的要求型断言又会假绿。
///
/// flutter test cwd 是 hibiki package 根。
void main() {
  const String appPopup = 'assets/popup';
  const String extAssets = 'assets/browser_extension';
  const String extTools = '../tools/browser-extension';

  /// popup.js / popup.css 的三份镜像（in-app 渲染器 + 两个扩展 vendor 副本）。
  const List<String> jsMirrors = <String>[
    '$appPopup/popup.js',
    '$extAssets/vendor/popup.js',
    '$extTools/vendor/popup.js',
  ];
  const List<String> cssMirrors = <String>[
    '$appPopup/popup.css',
    '$extAssets/vendor/popup.css',
    '$extTools/vendor/popup.css',
  ];

  /// content.css 是 popup.css 的生成镜像（generate-content-css.mjs），只有扩展侧有。
  const List<String> generatedCssMirrors = <String>[
    '$extAssets/vendor/content.css',
    '$extTools/vendor/content.css',
  ];

  String read(String p) => File(p).readAsStringSync();

  group('旧 kanji-breakdown chip 行不得复活', () {
    for (final String path in jsMirrors) {
      test('[$path] 没有 createKanjiBreakdown 实现', () {
        final String src = read(path);
        expect(
          containsIdentifier(src, 'createKanjiBreakdown'),
          isFalse,
          reason:
              '$path 重新引入了 createKanjiBreakdown——那是把词头每个汉字在下一行'
              '重复成灰方块 chip 才可点的旧 UI。可点性现在内联在词头里'
              '（wrapExpressionInlineKanji + .kanji-inline），不要恢复 chip 行。',
        );
      });
    }

    for (final String path in <String>[...cssMirrors, ...generatedCssMirrors]) {
      test('[$path] 没有 .kanji-tag / .kanji-breakdown 样式', () {
        final String css = maskCssComments(read(path));
        for (final String dead in const <String>[
          '.kanji-tag',
          '.kanji-breakdown',
        ]) {
          expect(
            css.contains(dead),
            isFalse,
            reason:
                '$path 重新引入了 $dead 样式规则（旧 chip 行的外观）。'
                '内联形态的样式是 .kanji-inline。',
          );
        }
      });
    }
  });

  group('内联可点汉字是唯一形态', () {
    for (final String path in jsMirrors) {
      test('[$path] wrapExpressionInlineKanji 已定义且挂在 postProcessRuby 尾部', () {
        final String src = read(path);
        expect(
          containsIdentifier(src, 'wrapExpressionInlineKanji'),
          isTrue,
          reason:
              '$path 丢了 wrapExpressionInlineKanji——词头汉字将不再可点，'
              '而 chip 行也已删除，等于整个「查单字」入口消失。',
        );

        // 包裹 pass 必须挂在 postProcessRuby 的**函数体内**：那是每条渲染路径
        // （首词条 / 延迟尾部词条 / 增量更新）都会流经的唯一 ruby 后处理接缝。
        // 只断言「文件里出现过这次调用」不够——挂到别的函数上，延迟渲染的词条
        // 就静默失去可点性，而文件级断言照样绿。
        final String body = methodBody(
          src,
          'function postProcessRuby',
          lexicon: SourceLexicon.js,
        );
        expect(
          containsIdentifierCall(body, 'wrapExpressionInlineKanji'),
          isTrue,
          reason:
              '$path 的 wrapExpressionInlineKanji 调用不在 postProcessRuby 体内。'
              '挂在别处会让延迟渲染的词条拿不到内联可点汉字。',
        );
      });
    }

    for (final String path in <String>[...cssMirrors, ...generatedCssMirrors]) {
      test('[$path] 有 .kanji-inline 的点线 affordance', () {
        final String css = maskCssComments(read(path));
        expect(
          css.contains('.kanji-inline'),
          isTrue,
          reason: '$path 丢了 .kanji-inline 规则——内联汉字将没有任何可点提示。',
        );
      });
    }
  });
}
