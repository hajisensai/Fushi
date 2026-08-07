import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-876：书内「点收藏有时跳不过去」。根因：收藏的 `normCharOffset` 可能缺失（写入端
/// `sentenceRange?.offset` 依赖 JS getNormalizedOffset，跨 ruby / 复杂节点选区可能返 null →
/// 存 null）。旧跳转在 offset==null 时：同章 `restoreToCharOffset` 被 `normCharOffset != null`
/// 门吞成静默 no-op、跨章 charOffset=null 落章首 → 能否跳取决于写入时有没有拿到 offset =
/// 「有时能、有时不能」。修复：缺 offset 时回退到与「搜索跳转」同一条 by-text 定位原语
/// `scrollToSearchMatch`（按句文本命中，整句在章内通常唯一）；有效 offset 仍走精确路径。
///
/// headless WebView 不可用（`_jumpToFavoriteSentence` 是 State 私有方法，需真实 WebView +
/// 章节装载），按项目范式用源码扫描守卫：确保回退分支存在、不被误删回退到旧的「offset 缺失
/// 即无声失败」。
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();

  /// 取 `_jumpToFavoriteSentence` 函数体（到下一个方法 `_favoritePositionLabel` 前）。
  String jumpBody() {
    final int start =
        chrome.indexOf('_jumpToFavoriteSentence(FavoriteSentence');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 _jumpToFavoriteSentence 定义');
    final int end = chrome.indexOf('_favoritePositionLabel(', start);
    return chrome.substring(start, end >= 0 ? end : chrome.length);
  }

  group('BUG-876 收藏跳转缺 offset 时按文本回退', () {
    test('_jumpToFavoriteSentence 在缺 offset 时用 scrollToSearchMatch 文本定位', () {
      final String body = jumpBody();
      expect(
        body.contains('scrollToSearchMatchInvocation'),
        isTrue,
        reason: 'normCharOffset 缺失时必须按句文本回退定位，否则同章静默 no-op / 跨章落章首',
      );
    });

    test('仍保留精确 restoreToCharOffset（有效 offset 的正常路径不被替换）', () {
      final String body = jumpBody();
      expect(
        body.contains('restoreToCharOffset'),
        isTrue,
        reason: '有效 offset 仍走精确字符锚恢复，向后兼容既有可跳收藏',
      );
    });

    test('回退按 useOffset / normCharOffset 门控（offset 有效时不走文本搜索）', () {
      final String body = jumpBody();
      expect(
        RegExp(r'useOffset\s*=\s*normCharOffset\s*!=\s*null').hasMatch(body),
        isTrue,
        reason: '必须仅在 offset 缺失时回退文本，offset 有效时保持精确路径',
      );
    });
  });
}
