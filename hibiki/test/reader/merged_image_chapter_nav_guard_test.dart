import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1128 回归守卫（源码扫描）：图片章嵌正文（方案 A）开启后，被吸收的单图片章
/// 不得在任何导航路径被当独立页加载——否则它自己的单图页（第 1 份）+ 宿主正文顶部
/// 内联注入同图（第 2 份）= 图片重复。此守卫锁住去重接线不被回退：
///   1. 存在 `_resolveNavChapter`（把被吸收章重定向到宿主文本章的 helper）。
///   2. 所有裸导航入口都过该守卫：`_navigateToChapter` / `_navigateToChapterWithFragment`
///      / 开书恢复(webview `_loadChapterDirectly`) / 结构性重载(chrome `_reloadWithCurrentSettings`)
///      / 有声书跨章(audiobook `_pauseThroughImageOnlyChapters`)。
///   3. `_handlePageTurnLimit` 不再用 `spreadMode != 'off'` 门控虚拟页翻页——
///      off 模式也必须走虚拟页 map 跳过被吸收章。
void main() {
  final Directory base = Directory(
    'lib/src/pages/implementations/reader_fushi',
  );
  String read(String name) => File('${base.path}/$name').readAsStringSync();

  group('TODO-1128 merged-image-chapter nav dedup guard', () {
    test('_resolveNavChapter helper exists and redirects via the spread map',
        () {
      final String nav = read('navigation.part.dart');
      expect(nav.contains('int _resolveNavChapter('), isTrue,
          reason: '被吸收章重定向 helper 必须存在');
      // The helper must resolve through the spread map's absorbed check +
      // host-page lookup (the exact redirect the reader relies on).
      expect(nav.contains('isAbsorbedImageChapter('), isTrue);
      expect(nav.contains('virtualPageForChapter('), isTrue);
    });

    test('_navigateToChapter / withFragment / andWait route through the guard',
        () {
      final String nav = read('navigation.part.dart');
      // Count the guard usages: helper def + navigateToChapter guard +
      // withFragment guard + andWait resolved-target check = at least 4.
      final int uses = '_resolveNavChapter'.allMatches(nav).length;
      expect(uses, greaterThanOrEqualTo(4),
          reason: '裸导航入口（翻章/内链/有声书 wait）都必须过 _resolveNavChapter，实测 $uses 处');
    });

    test('open-book restore and live reload redirect absorbed chapters', () {
      expect(read('webview.part.dart').contains('_resolveNavChapter('), isTrue,
          reason: '开书恢复 (_loadChapterDirectly 前) 必须重定向被吸收章');
      expect(read('chrome.part.dart').contains('_resolveNavChapter('), isTrue,
          reason: '结构性重载 (_reloadWithCurrentSettings) 必须重定向被吸收章');
      expect(
          read('audiobook.part.dart').contains('_resolveNavChapter('), isTrue,
          reason: '有声书跨章 pause-through 必须按宿主去重');
    });

    test(
        '_handlePageTurnLimit no longer gates the virtual-page map on off mode',
        () {
      final String nav = read('navigation.part.dart');
      // The old gate `_spreadMap != null && _settings?.spreadMode != 'off'`
      // must be gone — page turns unify through the virtual map in all modes so
      // off mode also skips absorbed chapters.
      expect(nav.contains("_settings?.spreadMode != 'off'"), isFalse,
          reason: '翻页不得再用 spreadMode != off 门控虚拟页 map（会让 off 模式落被吸收章重复）');
    });
  });
}
