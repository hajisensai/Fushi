import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// BUG-763/766 守卫：「制卡·选择句子上下文」现为 **app 原生顶层 Flutter 对话框**
/// （[SentenceContextDialog]），**不再**画在查词弹窗 WebView 内（那受弹窗表面尺寸/半透明
/// 限制——句子框重叠、透出下面一层、显示不全；用户报「句子和句子之间是重叠的，有层透明」
/// 「这个是要顶层弹窗，不是查词弹窗内」）。
///
/// 本守卫钉死：① 旧 WebView HTML 模态（openSentenceContextModal / .scm-* 样式）已彻底删除；
/// ② 词条入口按钮（现为「高级制卡」）改成 `callHandler('openAdvancedMining',
/// {entryIndex, matched, expression})`；③ Dart 侧 handler → layer → base/mixin 弹原生对话框，
/// 确认制卡回 WebView 精确点中该词条并带上覆盖项（fushiPopupMineEntryByIndex /
/// mineEntryByIndex）；④ 宿主后端预览/增减回调仍在（对话框的句子分区复用）。
/// 无头测试照不到真实 WebView，故用源码扫描守卫钉死每段接线（对话框行为另见 widget 测试）。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  group('旧 WebView HTML 模态已彻底删除（BUG-763/766）', () {
    test('popup.js 不再有内联模态构建器', () {
      final String js = read('assets/popup/popup.js');
      for (final String gone in const <String>[
        'function openSentenceContextModal(',
        'function buildContextBox(',
        'function buildHighlightedCurrentText(',
        "className: 'sentence-context-modal'",
      ]) {
        expect(js.contains(gone), isFalse,
            reason: 'popup.js 仍残留旧模态代码：$gone（应已删，改走原生对话框）');
      }
    });

    test('popup.css 不再有 .scm-* 模态样式', () {
      final String css = read('assets/popup/popup.css');
      expect(css.contains('.scm-'), isFalse,
          reason: 'popup.css 仍残留 .scm-* 模态样式（应随模态一起删除）');
      expect(css.contains('.sentence-context-modal'), isFalse);
    });

    test('扩展 content.css 镜像也不再有模态样式', () {
      for (final String root in const <String>[
        'assets/browser_extension',
        '../tools/browser-extension',
      ]) {
        final String content = read('$root/vendor/content.css');
        expect(content.contains('.scm-'), isFalse,
            reason: '$root/vendor/content.css 仍残留 .scm-*（重跑 generate-content-css.mjs）');
      }
    });
  });

  group('词条「高级制卡」按钮触发原生对话框（原「调整上下文」）', () {
    test('popup.js 按钮门控 advancedMiningEnabled，callHandler openAdvancedMining 带 entryIndex+matched+expression+reading', () {
      final String js = read('assets/popup/popup.js');
      expect(js.contains('ctx-adjust-button'), isTrue);
      expect(js.contains('window.advancedMiningEnabled === true'), isTrue,
          reason: '入口必须由宿主注入的 advancedMiningEnabled 门控');
      expect(js.contains("'openAdvancedMining'"), isTrue,
          reason: '按钮必须 callHandler openAdvancedMining 弹宿主原生对话框');
      expect(
          js.contains(
              "{ entryIndex: idx, matched: matched, expression: expression, reading: reading || '' }"),
          isTrue,
          reason: '参数是对象（BUG-1326），带 entryIndex / matched / expression / reading');
      // entryIndex 用点击时的稳定 DOM 序（:scope > .entry），与回点同源。
      expect(js.contains(':scope > .entry'), isTrue);
      // 提示文案用「高级制卡」那份（宿主注入的 i18nCtx.advancedMining）。
      expect(js.contains('ctxI18n.advancedMining'), isTrue);
    });

    test('popup.js 提供 fushiPopupMineEntryByIndex 供确认制卡精确回点', () {
      final String js = read('assets/popup/popup.js');
      expect(js.contains('window.fushiPopupMineEntryByIndex'), isTrue);
      // 回点同样按 :scope > .entry DOM 序，点该词条的 .mine-button。
      expect(
          js.contains("querySelectorAll(':scope > .entry')") &&
              js.contains('.mine-button'),
          isTrue);
    });
  });

  group('Dart 侧原生对话框接线', () {
    test('webview 注册 openAdvancedMining handler + onOpenAdvancedMining 字段 + mineEntryByIndex', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(src.contains("handlerName: 'openAdvancedMining'"), isTrue);
      expect(src.contains('widget.onOpenAdvancedMining'), isTrue);
      expect(src.contains('final OpenAdvancedMiningCallback? onOpenAdvancedMining;'),
          isTrue);
      // 确认制卡回点：Dart 精确点第 idx 个词条（复用 mineEntry 全逻辑）。
      // BUG-2627：必须回传「有没有真的点到」，否则 popup.js 的三条 return false
      // 与「控制器已没了」一样被整个吞掉，任何关栈竞态都长成「点了没反应」。
      expect(src.contains('Future<bool> mineEntryByIndex('), isTrue);
      expect(src.contains('fushiPopupMineEntryByIndex'), isTrue);
      // 入口门控随宿主回调注入（热槽重发键含它），app 里不再有旧的双入口。
      expect(src.contains(r'window.advancedMiningEnabled = $advancedMiningEnabled;'),
          isTrue);
      expect(src.contains('advancedMining: advancedMiningEnabled'), isTrue,
          reason: 'extrasKey 必须把高级制卡门控算进去，否则热槽 WebView 残留旧值');
      expect(src.contains('sentenceContextPreviewEnabled'), isFalse,
          reason: 'app 内不再注入旧入口门控（只留高级制卡一个入口）');
      expect(src.contains("handlerName: 'openSentenceContextModal'"), isFalse);
    });

    test('layer 透传 onOpenAdvancedMining', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_layer.dart');
      expect(src.contains('final OpenAdvancedMiningCallback? onOpenAdvancedMining;'),
          isTrue);
      expect(src.contains('this.onOpenAdvancedMining,'), isTrue);
      expect(src.contains('onOpenAdvancedMining: onOpenAdvancedMining'), isTrue);
    });

    test('reader 车道 (base) 弹原生对话框 + 确认回点 mineEntryByIndex 带覆盖项', () {
      final String src = read('lib/src/pages/base_source_page.dart');
      // 入口只跟制卡模块走（纯查词页也有，只是只有卡组分区）。
      expect(
        RegExp(r'onOpenAdvancedMining:\s*cardCreationEnabled').hasMatch(src),
        isTrue,
      );
      // 「+句」草稿门控仍然 AND 上「该表面支持草稿」，不能只剩模块闸。
      expect(
        RegExp(r'sentenceDraftEnabled\s*=[\s\S]{0,80}?supportsSentenceDraft')
            .hasMatch(src),
        isTrue,
        reason: '草稿门控必须仍然 AND 上「该表面支持草稿」，不能只剩模块闸',
      );
      expect(src.contains('showAdvancedMiningDialog('), isTrue);
      expect(src.contains('loadAdvancedMiningDeckSection(ref)'), isTrue);
      expect(src.contains('buildAdvancedMiningSections(matched: matched)'),
          isTrue);
      expect(src.contains('webViewKey.currentState?.mineEntryByIndex('), isTrue);
      expect(src.contains('overrides: overrides,'), isTrue,
          reason: '确认时必须把对话框的覆盖项并进这次回点');
    });

    test('video 车道 (mixin) 弹原生对话框 + 确认回点带覆盖项', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_page_mixin.dart');
      expect(src.contains('onOpenAdvancedMining:'), isTrue);
      expect(src.contains('showAdvancedMiningDialog('), isTrue);
      expect(src.contains('buildAdvancedMiningSections(matched: matched)'),
          isTrue);
      expect(src.contains('webViewKey.currentState?.mineEntryByIndex('), isTrue);
      expect(src.contains('overrides: overrides,'), isTrue);
    });
  });

  group('AdvancedMiningDialog 顶层对话框本体（原「调整上下文」对话框演进）', () {
    // 对话框拆成了入口 / 状态控制器 / 分区组件三个文件，按整组源码判断。
    final String src = <String>[
      'lib/src/mining/advanced_mining/advanced_mining_dialog.dart',
      'lib/src/mining/advanced_mining/advanced_mining_controller.dart',
      'lib/src/mining/advanced_mining/advanced_mining_sections.dart',
    ].map((String p) => File(p).readAsStringSync()).join();

    test('文件存在且由 showAppDialog / 自适应底部面板弹出', () {
      expect(src.contains('class AdvancedMiningDialog'), isTrue);
      expect(src.contains('showAppDialog<void>('), isTrue);
    });

    test('文案走 slang t.popup_ctx_* / t.popup_advanced_mining_*（无需 JS i18nCtx）',
        () {
      for (final String key in const <String>[
        't.popup_advanced_mining_title',
        't.popup_advanced_mining_sentence_count',
        't.popup_ctx_box_prev',
        't.popup_ctx_box_current',
        't.popup_ctx_box_next',
        't.popup_ctx_prev_plus',
        't.popup_ctx_next_plus',
        't.popup_ctx_confirm',
        't.popup_ctx_cancel',
      ]) {
        expect(src.contains(key), isTrue, reason: '对话框缺文案 key：$key');
      }
    });

    test('当前句词高亮用 Text.rich（offset 命中优先，失配 indexOf）', () {
      expect(src.contains('Text.rich('), isTrue);
      expect(src.contains('indexOf(matched)'), isTrue);
    });

    test('确认走注入 onConfirm、取消还原快照', () {
      // 覆盖项 + 单词音频选择一起交给 onConfirm（单词音频不进覆盖项 wire）。
      expect(src.contains('widget.capabilities.onConfirm('), isTrue);
      expect(src.contains('wordAudioUrl: wordAudioUrl'), isTrue);
      expect(src.contains('restoreSentenceSnapshot()'), isTrue);
    });
  });

  group('后端预览/增减回调仍在（对话框复用，未改后端）', () {
    test('base 保留 onSentenceContextPreviewFromDraft / onSetSentenceContextToDraft', () {
      final String src = readReaderPageSource();
      expect(
        src.contains(
            'Future<Map<String, Object?>> onSentenceContextPreviewFromDraft() async'),
        isTrue,
      );
      expect(src.contains('buildSentenceContextPreview('), isTrue);
    });
  });
}
