import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1308 问题②（BUG-696）源码守卫：导航跳转落章节开头的三个根因不得回归。
///
/// 用户复诉「跳转后还是没到对应文字位置，只在章节开头」。三个根因（均已真机路径核实）：
///
/// 根因①（单位契约）：`fav.normCharOffset` 是 JS `getNormalizedOffset` 产的章内**绝对
/// 可匹配字符索引**（写入端 lookup.part / mining.part 的 sentenceNormalizedOffset），
/// 不是书签的 0-10000 进度分数。书内收藏面板跳转（chrome.part.dart onJumpToFavorite）
/// 曾把它 /10000.0 当分数 → 恒落章节开头。BUG-459 只修了收藏页冷启动入口（charAnchor），
/// 书内面板这条从未修到。修复=与冷启动同构：跨章把 charOffset(+句尾锚) 烘进
/// `_navigateToChapterAndWait`，同章直接 `restoreToCharOffset`。
///
/// 根因②（Range DOM 手术）：共享 `scrollToSearchMatch` 在连续模式（无 scrollToRange）
/// 的兜底曾用 `range.surroundContents(span)`——rb/rtc 形态书（JIS mono-ruby）上命中词
/// 跨相邻 `<rb>` 基字时 Range 部分包含元素节点 → 抛 InvalidStateError → 滚动被跳过，
/// 跨章搜索停在章节开头。修复=直接 `this.scrollToTarget(range)`（getRect 走
/// getClientRects，Range 原生支持，零 DOM 手术）。
///
/// 根因③（竖排死分支）：见 chapter_start_illustration_charoffset_guard_test.dart 的
/// 轴向归一守卫（连续保位 hint 竖排为负 scrollX，旧 `> 0` 判据在竖排永假）。
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();
  final String nav = File(
    'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
  ).readAsStringSync();
  final String js = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  /// 取 _jumpToFavoriteSentence 方法体（TODO-1308 问题②把 onJumpToFavorite 闭包抽成
  /// 方法，quick settings sheet 与 debugJumpToFavorite 测试钩子共用这一条真实路径）。
  String favoriteBlock() {
    final int start = chrome.indexOf(
        'Future<void> _jumpToFavoriteSentence(FavoriteSentence fav) async {');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'chrome.part.dart 必须有 _jumpToFavoriteSentence 方法');
    final int end = chrome.indexOf(
        'class _ReaderGalleryPage extends StatefulWidget {', start);
    expect(end, greaterThan(start));
    return chrome.substring(start, end);
  }

  test('根因①：书内收藏跳转不得把绝对字符索引 /10000 当分数', () {
    final String fav = favoriteBlock();
    expect(fav.contains('/ 10000'), isFalse,
        reason: 'fav.normCharOffset 是 getNormalizedOffset 的绝对字符索引，'
            '/10000 当分数会恒落章节开头（BUG-696 根因①）');
    expect(fav.contains('restoreProgress('), isFalse,
        reason: '同章收藏跳转必须走 restoreToCharOffset 绝对锚，不得走分数 restoreProgress');
    // BUG-876：offset 缺失时回退按文本定位后，charOffset 由 `useOffset` 门控条件运输
    // （offset 有效才烘绝对锚，null 走 scrollToSearchMatch 文本回退）；仍必须把绝对字符锚
    // 烘进 _navigateToChapterAndWait(charOffset:)，只是从裸 `normCharOffset` 变条件形。
    expect(norm(fav).contains('charOffset: useOffset ? normCharOffset : null'),
        isTrue,
        reason: '跨章收藏跳转必须把绝对字符锚（offset 有效时）烘进 '
            '_navigateToChapterAndWait(charOffset:)');
    expect(fav.contains('.restoreToCharOffset('), isTrue,
        reason: '同章收藏跳转必须直接 restoreToCharOffset（与冷启动 charAnchor 同构）');
  });

  test('根因①：导航链路必须能运输字符锚（_navigateToChapterAndWait 带 charOffset/charOffsetEnd）',
      () {
    final String n = norm(nav);
    expect(
        n.contains('Future<bool> _navigateToChapterAndWait( int index, '
            '{ bool manual = false, double progress = 0.0, int? charOffset, '
            'int charOffsetEnd = -1, String? preciseLocateJs, })'),
        isTrue,
        reason: '_navigateToChapterAndWait 必须带 charOffset/charOffsetEnd 参数'
            '（书内收藏跳转的绝对锚运输通道）');
    expect(n.contains('_initialCharOffsetEnd = charOffsetEnd;'), isTrue,
        reason: '_beginNavigation 必须拥有并每次导航复位句尾锚，防冷启动收藏跳转的'
            '_initialCharOffsetEnd 泄漏进后续无关导航');
  });

  test('根因②：搜索跳转连续兜底不得做 surroundContents DOM 手术', () {
    // 剥掉行注释后断言（修复说明注释里提到旧 API 名不算回归）。
    final String code = js
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('surroundContents'), isFalse,
        reason: 'range.surroundContents 在 rb/rtc 形态书上跨基字命中时抛 '
            'InvalidStateError → 跨章搜索停在章节开头（BUG-696 根因②）；'
            '兜底必须直接 scrollToTarget(range)');
    expect(code.contains('this.scrollToTarget(range);'), isTrue,
        reason: '连续模式搜索跳转兜底必须直接滚 Range（getRect 原生支持 Range）');
  });
}
