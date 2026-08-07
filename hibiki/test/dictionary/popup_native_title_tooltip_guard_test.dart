// BUG-842 源码扫描守卫：查词弹窗的内联动作按钮不得再用 HTML 原生 `title` 出提示。
//
// 根因：Windows 桌面 WebView2 走离屏合成（CompositionController → DirectComposition
// visual → Windows Graphics Capture → Flutter texture，父 HWND 是原点(0,0) 不可见子窗口），
// 可见像素再经 FushiAppUiScale 的 FittedBox 拉伸。原生 `title` 工具提示是 WebView2 生成的
// 独立 top-level OS 窗口，按「父 HWND 原点 + WebView 内部未拉伸逻辑坐标」定位，与纹理真正
// 合成的位置乖离 → 提示「飞」到窗口角落（截图：视频上查词弹窗 tune 按钮提示跑到画面右上角）。
// 修复：改用 DOM 内自绘 `.hoshi-btn-tip`（随纹理正确合成），并移除原生 title。
//
// 弹窗跑在 WebView 里没有 headless 渲染、原生 OS 提示窗更难自动复现，故用源码文本扫描锁住
// 这些约束防回退。三镜像/content.css 完整性由 test/build/browser_extension_popup_parity_
// guard_test.dart 覆盖，这里只针对 in-app 真值 assets/popup/*。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // flutter test 的 cwd 是 hibiki 包根。
  late final String js;
  late final String css;

  setUpAll(() {
    js = File('assets/popup/popup.js').readAsStringSync();
    css = File('assets/popup/popup.css').readAsStringSync();
  });

  // 切出某个顶层 `function name(` 到下一个顶层 `\nfunction ` 之间的本体，避免正则
  // 贪婪跨越到别处的 `.title =`（如 imageContainer.title —— 那是词典内容，不在范围）。
  String funcBody(String src, String header) {
    final int start = src.indexOf(header);
    expect(start, greaterThanOrEqualTo(0), reason: '$header 应存在');
    final int end = src.indexOf('\nfunction ', start + 1);
    return src.substring(start, end < 0 ? src.length : end);
  }

  group('BUG-842 内联动作按钮不再依赖原生 title 提示', () {
    test('存在 DOM 提示助手 setInlineButtonTip，且会移除 title 并挂 .hoshi-btn-tip', () {
      expect(js, contains('function setInlineButtonTip('),
          reason: '需要 DOM 提示助手替代原生 title');
      expect(js, contains('function __hoshiShowButtonTip('),
          reason: '需要按屏幕坐标定位 .hoshi-btn-tip 的展示函数');
      // 关键：助手必须显式去掉原生 title（否则离屏 WebView2 上仍会飞）。
      expect(
          RegExp(r"function setInlineButtonTip\([\s\S]*?removeAttribute\('title'\)")
              .hasMatch(js),
          isTrue,
          reason: 'setInlineButtonTip 必须 removeAttribute(title)');
      // 提示元素用 .hoshi-btn-tip（DOM 内，随纹理合成）。
      expect(js, contains("className: 'hoshi-btn-tip'"),
          reason: 'DOM 提示元素类名为 hoshi-btn-tip');
      // 监听只挂一次（refresh 反复调用不叠加）。
      expect(js, contains('dataset.hoshiTipBound'),
          reason: '用 dataset 标志保证监听只挂一次');
    });

    test('调整上下文（tune）与清空已加句子（clear-draft）按钮改走 setInlineButtonTip', () {
      // 「调整上下文」按钮不得在 el() 里设 title，且用 setInlineButtonTip 挂提示。
      expect(js.contains('title: (window.i18nCtx && window.i18nCtx.adjust)'),
          isFalse,
          reason: 'ctx-adjust-button 不得再用原生 title（离屏 WebView2 会飞）');
      expect(js, contains('setInlineButtonTip(adjustBtn'),
          reason: '「调整上下文」按钮改走 DOM 提示');
      // 「清空已加句子」按钮的 refresh 不得再设 button.title，改走 setInlineButtonTip。
      final String refreshBody =
          funcBody(js, 'function refreshClearDraftButton(');
      expect(RegExp(r'\btitle\s*=').hasMatch(refreshBody), isFalse,
          reason: 'refreshClearDraftButton 不得再设原生 title');
      expect(refreshBody, contains('setInlineButtonTip('),
          reason: '清空已加句子按钮改走 DOM 提示');
    });

    test('无音频反馈 showNoAudioHint 不再设原生 title（本就有自绘 .audio-hint）', () {
      final int start = js.indexOf('function showNoAudioHint(');
      expect(start, greaterThanOrEqualTo(0), reason: 'showNoAudioHint 应存在');
      final int end = js.indexOf('\nfunction ', start + 1);
      final String body = js.substring(start, end < 0 ? js.length : end);
      expect(RegExp(r'\bbutton\.title\s*=').hasMatch(body), isFalse,
          reason: 'showNoAudioHint 不得设原生 title（已有 .audio-hint DOM 提示）');
      expect(body, contains("setAttribute('aria-label'"),
          reason: '保留 aria-label 以维持可访问性');
    });

    test('popup.css 定义 .hoshi-btn-tip（与 .audio-hint 共用视觉）', () {
      expect(css, contains('.hoshi-btn-tip'),
          reason: 'popup.css 需定义 .hoshi-btn-tip 提示样式');
      // 与 .audio-hint 同一规则块（position:fixed + 主题化背景/边框），共用视觉。
      // BUG-1064 又给这条规则接了第三个共享者 `.inline-hint`（app 外页内提示气泡），
      // 故允许两者之间再插入其它选择器——守的是「共用同一条基础规则」这个意图，
      // 不是选择器列表的具体长度。
      expect(
          RegExp(r'\.audio-hint,\s*\n(?:\s*\.[\w-]+,\s*\n)*\s*\.hoshi-btn-tip\s*\{')
              .hasMatch(css),
          isTrue,
          reason: '.hoshi-btn-tip 与 .audio-hint 共用基础规则');
      expect(
          RegExp(r'\.audio-hint\.visible,\s*\n(?:\s*\.[\w-]+\.visible,\s*\n)*'
                  r'\s*\.hoshi-btn-tip\.visible')
              .hasMatch(css),
          isTrue,
          reason: '.hoshi-btn-tip.visible 与 .audio-hint.visible 共用淡入');
    });
  });
}
