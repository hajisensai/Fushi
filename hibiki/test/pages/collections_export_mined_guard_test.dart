import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-913 收藏夹导出修复的源码守卫：
/// ① 收藏词 ☆ 按钮已复活并接 favoriteEntry 桥（FavoriteWords 写入入口不得再丢）。
/// ② 制卡句进导出管线（getAllMinedSentences → buildMinedExport）。
/// ③ 导出抽屉走 MD3 范式（HibikiModalSheetFrame + HibikiDesignTokens），范围含 allMined。
/// ④ 不回归 BUG-123：竖排选区 rt/rp 遮罩仍在 reader_content_styles.dart。
void main() {
  test('① popup.js 复活收藏按钮且调 favoriteEntry（FavoriteWords 写入入口）', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, contains('createFavoriteButton'));
    expect(js, contains("'favoriteEntry'"));
    expect(js, contains('buttonsContainer.appendChild(createFavoriteButton('));
  });

  test('② collection_exporter 提供制卡句导出管线 buildMinedExport', () {
    final String src =
        File('lib/src/utils/misc/collection_exporter.dart').readAsStringSync();
    expect(src, contains('class ExportMinedSentence'));
    expect(src, contains('String buildMinedExport('));
    // CSV 表头含 sentence + 词条字段。
    expect(src, contains("'sentence',"));
  });

  test('③ collections_page 经 getAllMinedSentences 导出 + MD3 抽屉 + allMined 范围',
      () {
    final String src =
        File('lib/src/pages/implementations/collections_page.dart')
            .readAsStringSync();
    // 制卡句导出读真实 DB API。
    expect(src, contains('getAllMinedSentences()'));
    expect(src, contains('buildMinedExport('));
    // TODO-914：范围从单选 _ExportKind 升级为可勾选 ExportScope，原 enum 已移除；
    // 制卡句范围标签（collection_export_all_mined）仍是导出抽屉的勾选项。
    expect(src, contains('ExportScope.mined'));
    expect(src, contains('t.collection_export_all_mined'));
    // 抽屉外壳走 MD3 范式，不再裸 showModalBottomSheet + 手写 Padding(16)。
    expect(src, contains('class _ExportSheet'));
    expect(src, contains('HibikiModalSheetFrame('));
    expect(src, contains('HibikiDesignTokens.of(context)'));
    // 门控放开为「收藏句或制卡句」任一存在。
    expect(src, contains('_hasExportableItems'));
  });

  test('④ 不回归 BUG-123/125：竖排选区 ruby class 分流机制仍在（与 ☆ 复活无耦合）', () {
    final String css =
        File('lib/src/reader/reader_content_styles.dart').readAsStringSync();
    // BUG-123→BUG-125 的现行修复是「ruby 元素 class 分流 + 预合成不透明色」，rt/rp
    // 不透明遮罩已被 BUG-125 删除（会抹基字右缘）。复活 popup.js 的 ☆ 收藏按钮只动
    // 弹窗资产，与这套竖排选区高亮渲染零耦合，故分流机制必须仍在：
    expect(css, contains('ruby.hoshi-selection-ruby-active'),
        reason: '竖排选区 ruby class 分流（BUG-123/125 修复核心）必须仍在');
    expect(css, contains('composeOpaqueColor'),
        reason: 'BUG-125 预合成不透明色机制必须仍在');
    // 反向：不得复活已删除的 rt/rp 遮罩（与 ruby_highlight_guard 一致）。
    expect(css.contains('ruby.hoshi-selection-ruby-active > rt'), isFalse,
        reason: 'BUG-125 已删除会抹基字的 rt 遮罩，不得复活');
  });

  test('⑤ TODO-914 去重聚合 + 可勾选模式守卫（纯函数 + UI 控件存在）', () {
    final String exporter =
        File('lib/src/utils/misc/collection_exporter.dart').readAsStringSync();
    // 去重聚合纯函数 + 载体 + 全部模式合并 builder 必须存在。
    expect(exporter, contains('enum ExportScope'));
    expect(exporter, contains('class ExportMinedSentenceGroup'));
    expect(exporter, contains('List<ExportMinedSentenceGroup> dedupeMinedBySentence('));
    expect(exporter, contains('List<ExportSentence> dedupeSentences('));
    expect(exporter, contains('String buildMinedGroupedExport('));
    expect(exporter, contains('String buildCombinedExport('));

    final String src =
        File('lib/src/pages/implementations/collections_page.dart')
            .readAsStringSync();
    // 范围从单选 RadioListTile 升级为可勾选 CheckboxListTile + 去重 SwitchListTile。
    expect(src, contains('CheckboxListTile('));
    expect(src, contains('SwitchListTile('));
    expect(src, contains('ExportScope.mined'));
    expect(src, contains('ExportScope.favorites'));
    // 去重接线：勾选去重时走聚合 builder。
    expect(src, contains('dedupeMinedBySentence('));
    expect(src, contains('buildCombinedExport('));
  });

}
