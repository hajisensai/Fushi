import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1017 源码守卫：固定版式 SVG 竖排 EPUB 打开一片空白。
///
/// 根因 = 每章 HTML 注入的 `#hoshi-cloak`（`body{visibility:hidden}` 防 FOUC）唯一的摘除点
/// 在 reader-setup IIFE（webview.part.dart）尾部。分页/连续外壳的 boot（reader_pagination_scripts
/// 的 `_sharedInitBoot`）在 `readyState==='complete'`（onLoadStop 恒真）下**同步**跑
/// `initialize()`，且**无 try/catch**。固定版式 SVG 竖排零文本封面页上 `initialize()` 抛同步异常
/// → 冲出 IIFE、到不了尾部 → cloak 永留 → 整本书 `visibility:hidden` = 永久白屏。
/// （VN 外壳早已用 try/catch 包 boot 修好同类，见 reader_visual_novel_scripts.dart；分页/连续漏了。）
///
/// 修复两层：
/// ① `_sharedInitBoot` 经 `_fushiBootInitialize` 用 try/catch 包 `initialize()` 并 console.error
///    暴露真错——异常被就地含住，IIFE 继续跑到尾部摘 cloak。分页/连续外壳共享此 boot，一改两覆盖。
/// ② webview.part.dart 的 setup IIFE 顶部排一个幂等 microtask 无条件摘 `hoshi-cloak`，兜底任意抛点
///    （caret/furigana 等），彻底消除「cloak 依赖整段 IIFE 不抛」这个脆弱契约。
///
/// 守卫落在最强可靠可落地的源码语料层（ReaderHibikiPage 过重无法在 widget test 拉起跑该 boot，
/// 与 reader_* 一系列 *_static_test / BUG-868 守卫同纪律）。删掉任一保护即红。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('分页/连续外壳共享的 boot 必须 try/catch 包 initialize()（BUG-1017 ①）', () {
    final String src = read('lib/src/reader/reader_pagination_scripts.dart');

    // 定位 `_sharedInitBoot` 常量体。
    final int start = src.indexOf("static const String _sharedInitBoot = '''");
    expect(start, greaterThan(-1), reason: '找不到 _sharedInitBoot');
    final int end = src.indexOf("''';", start);
    expect(end, greaterThan(start), reason: 'boot 常量未闭合');
    final String boot = src.substring(start, end);

    // boot 定义受保护的 `_fushiBootInitialize`：try 里调 initialize()，catch 里 console.error。
    expect(boot.contains('function _fushiBootInitialize()'), isTrue,
        reason: 'boot 必须经受保护的 _fushiBootInitialize 调用 initialize()');
    expect(boot.contains('try {'), isTrue,
        reason: 'boot 必须 try 包 initialize()');
    expect(boot.contains('window.fushiReader.initialize();'), isTrue,
        reason: 'boot 仍要调 initialize()');
    expect(boot.contains('} catch (e) {'), isTrue,
        reason: 'boot 必须 catch 住 initialize() 的同步抛（否则冲出 IIFE 卡 cloak）');
    expect(boot.contains('console.error'), isTrue,
        reason: 'boot catch 必须 console.error 暴露真错供定位');
    // 裸调用（不经 _fushiBootInitialize）会绕过保护 —— boot 里两处触发都必须走它
    // （带分号的调用点，排除 `function _fushiBootInitialize()` 定义本身）。
    expect(RegExp(r'_fushiBootInitialize\(\);').allMatches(boot).length, 2,
        reason: 'load 事件与 readyState==="complete" 两处都必须走受保护的 boot');
  });

  test('reader-setup IIFE 必须无条件兜底摘 hoshi-cloak（BUG-1017 ②）', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki/webview.part.dart');

    // 顶部幂等 microtask 兜底摘 cloak：Promise.resolve().then 里 getElementById('hoshi-cloak').remove()。
    // BUG-1140 第二阶段①：整段 setup 由 IIFE 变成 `window.__fushiEngine.install(C)`
    // 的函数体（外链静态引擎，执行时刻不变）。按 install 签名定位，不绑定外层写法
    // ——本守卫钉的是函数体内容，与是否包了压缩器 / 是不是 IIFE 无关。
    final int iifeStart = src.indexOf('install: function(C) {');
    expect(iifeStart, greaterThan(-1), reason: '找不到 reader-setup install 函数体');
    final String iife = src.substring(iifeStart);
    expect(iife.contains('Promise.resolve().then(function() {'), isTrue,
        reason: 'IIFE 顶部必须排 microtask 兜底（任意抛点后仍摘 cloak）');
    expect(
        RegExp(r"getElementById\('hoshi-cloak'\)").allMatches(iife).length >= 2,
        isTrue,
        reason: '兜底 microtask 与尾部快路径两处都要摘 hoshi-cloak');
  });
}
