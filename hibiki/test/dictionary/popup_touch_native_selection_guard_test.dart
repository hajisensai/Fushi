import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-762 守卫：词典弹窗触屏抑制原生选区（防长按弹系统 ActionMode「翻译/复制/分享/全选…」
/// 后 app 卡死）必须由 popup_settings_injection 的注入体承载——**不**放进共享 popup.css
/// （那份被 content.css 生成器 re-root 进浏览器扩展宿主页会误伤扩展触屏选文本，且生成器不
/// 支持 @media 嵌套 at-rule 会直接抛错）。与阅读器 reader_content_styles TODO-1279 同款。
///
/// flutter test cwd = hibiki 包根。无头测试照不到真实 WebView，用源码扫描钉死接线。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing $rel');
    return f.readAsStringSync();
  }

  String injectionSrc() =>
      read('lib/src/pages/implementations/popup_settings_injection.dart');

  test('注入体含 @media(pointer:coarse) 触屏 user-select/callout 抑制', () {
    final String src = injectionSrc();
    expect(src.contains('@media (pointer: coarse)'), isTrue,
        reason: '缺触屏（粗指针）门控——桌面细指针不受影响，只掐触屏原生选区');
    expect(src.contains('-webkit-user-select:none !important'), isTrue);
    expect(src.contains('user-select:none !important'), isTrue);
    expect(src.contains('-webkit-touch-callout:none !important'), isTrue,
        reason: '缺 iOS 长按 callout 抑制');
  });

  test('抑制以 id 守卫 <style> 幂等注入（热槽 WebView 重复注入不叠加）', () {
    final String src = injectionSrc();
    expect(
        src.contains("getElementById('hoshi-popup-touch-noselect')"), isTrue);
    expect(src.contains("s.id = 'hoshi-popup-touch-noselect'"), isTrue);
  });

  test('抑制常量被拼进 static 注入 head（真会下发）', () {
    final String src = injectionSrc();
    expect(src.contains(r'$_touchNoSelectStyleJs'), isTrue,
        reason: 'head 模板必须引用注入常量，否则只是死代码');
  });

  test('刻意不写进共享 popup.css（避免生成器 re-root 进扩展宿主页 + @media 抛错）', () {
    final String popupCss = read('assets/popup/popup.css');
    expect(popupCss.contains('pointer: coarse'), isFalse,
        reason: 'popup.css 不得含触屏抑制——必须走 Dart 注入体（BUG-762 决策）');
  });
}
