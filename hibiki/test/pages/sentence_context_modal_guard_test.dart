import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-763/766 守卫：「制卡·选择句子上下文」现为 **app 原生顶层 Flutter 对话框**
/// （[SentenceContextDialog]），**不再**画在查词弹窗 WebView 内（那受弹窗表面尺寸/半透明
/// 限制——句子框重叠、透出下面一层、显示不全；用户报「句子和句子之间是重叠的，有层透明」
/// 「这个是要顶层弹窗，不是查词弹窗内」）。
///
/// 本守卫钉死：① 旧 WebView HTML 模态（openSentenceContextModal / .scm-* 样式）已彻底删除；
/// ② 词条「调整上下文」按钮改成 `callHandler('openSentenceContextModal', {entryIndex, matched})`；
/// ③ Dart 侧新 handler → layer → base/mixin 弹原生对话框，确认制卡回 WebView 精确点中该词条
/// （fushiPopupMineEntryByIndex / mineEntryByIndex）；④ 宿主后端预览/增减回调仍在（对话框复用）。
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

  group('词条「调整上下文」按钮改触发原生对话框', () {
    test('popup.js 按钮 callHandler openSentenceContextModal 带 entryIndex+matched', () {
      final String js = read('assets/popup/popup.js');
      expect(js.contains('ctx-adjust-button'), isTrue);
      expect(js.contains("'openSentenceContextModal'"), isTrue,
          reason: '按钮必须 callHandler openSentenceContextModal 弹宿主原生对话框');
      expect(js.contains('entryIndex'), isTrue);
      expect(js.contains('matched: matched'), isTrue);
      // entryIndex 用点击时的稳定 DOM 序（:scope > .entry），与回点同源。
      expect(js.contains(':scope > .entry'), isTrue);
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
    test('webview 注册 openSentenceContextModal handler + onOpenSentenceContextModal 字段 + mineEntryByIndex', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(src.contains("handlerName: 'openSentenceContextModal'"), isTrue);
      expect(src.contains('widget.onOpenSentenceContextModal'), isTrue);
      expect(src.contains('onOpenSentenceContextModal'), isTrue);
      // 确认制卡回点：Dart 精确点第 idx 个词条（复用 mineEntry 全逻辑）。
      expect(src.contains('Future<void> mineEntryByIndex('), isTrue);
      expect(src.contains('fushiPopupMineEntryByIndex'), isTrue);
      // 预览/增减 handler 仍在（对话框仍复用后端）。
      expect(src.contains("handlerName: 'sentenceContextPreview'"), isTrue);
    });

    test('layer 透传 onOpenSentenceContextModal', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_layer.dart');
      expect(
          src.contains(
              'final Future<void> Function(int entryIndex, String matched)?'),
          isTrue);
      expect(src.contains('this.onOpenSentenceContextModal,'), isTrue);
      expect(
          src.contains(
              'onOpenSentenceContextModal: onOpenSentenceContextModal'),
          isTrue);
    });

    test('reader 车道 (base) 弹原生对话框 + 确认回点 mineEntryByIndex', () {
      final String src = read('lib/src/pages/base_source_page.dart');
      expect(src.contains('onOpenSentenceContextModal: supportsSentenceDraft'),
          isTrue);
      expect(src.contains('showAppDialog<void>'), isTrue);
      expect(src.contains('SentenceContextDialog('), isTrue);
      expect(src.contains('webViewKey.currentState?.mineEntryByIndex('), isTrue);
      // 后端预览/增减回调仍复用（未改）。
      expect(src.contains('fetchPreview: onSentenceContextPreviewFromDraft'),
          isTrue);
      expect(src.contains('setContext: onSetSentenceContextToDraft'), isTrue);
    });

    test('video 车道 (mixin) 弹原生对话框 + 确认回点', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_page_mixin.dart');
      expect(src.contains('onOpenSentenceContextModal:'), isTrue);
      expect(src.contains('showAppDialog<void>'), isTrue);
      expect(src.contains('SentenceContextDialog('), isTrue);
      expect(src.contains('webViewKey.currentState?.mineEntryByIndex('), isTrue);
    });
  });

  group('SentenceContextDialog 顶层对话框本体', () {
    final String src =
        File('lib/src/pages/implementations/sentence_context_dialog.dart')
            .readAsStringSync();

    test('文件存在且是 showAppDialog 弹的 AlertDialog', () {
      expect(src.contains('class SentenceContextDialog'), isTrue);
      expect(src.contains('AlertDialog('), isTrue);
    });

    test('文案走 slang t.popup_ctx_*（无需 JS i18nCtx）', () {
      for (final String key in const <String>[
        't.popup_ctx_modal_title',
        't.popup_ctx_modal_count',
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
      expect(src.contains('widget.onConfirm()'), isTrue);
      expect(src.contains('_snapPrev') && src.contains('_snapNext'), isTrue);
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
