import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 根因守卫（BUG-054，与阅读器 BUG-039 同因）：全局「界面大小」用 FittedBox 把整棵
/// 渲染树当一张画布拉伸，WebView 是平台视图纹理、被拉大必糊。跨平台唯一干净解法是让
/// 词典 WebView 永远在原生密度渲染——即必须处在 [HibikiAppUiScaleNeutralizer] 之下。
///
/// 这组守卫锁住两件事，确保「逐页打补丁」演化成「不变式被强制执行」：
///   1. 共享叶子 DictionaryPopupWebView.build 带运行时不变式 assert
///      （被全局缩放且未中和时立刻炸，而非等用户撞糊）；
///   2. 每一处把 DictionaryPopupWebView 挂在全局缩放下的活跃表面，都用中和器包裹。
///
/// 悬浮词典（floating_dict_page → DictionaryPopupNative）是原生渲染、且 floating_dict_main
/// 不套 HibikiAppUiScale，故不在此列。native 渲染链 DictionaryResultPage→DictionaryHtmlWidget
/// 全仓无构造点（死代码），同样不纳入。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('DictionaryPopupWebView.build 带净缩放=1 的不变式 assert', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src.contains('assert('), isTrue,
        reason: '不变式必须是 assert（debug/测试触发），不是注释');
    expect(src.contains('HibikiAppUiScale.of(context)'), isTrue,
        reason: 'DictionaryPopupWebView 必须在 build 里读取当前界面缩放');
    expect(src.contains('HibikiAppUiScale.defaultScale'), isTrue,
        reason: 'assert 必须断言净缩放=defaultScale(中和后)，否则被全局缩放拉糊');
  });

  test('home_dictionary_page 查词结果区用中和器包裹（且在 LayoutBuilder 外层）', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: '首页词典标签查词结果（DictionaryPopupWebView+嵌套弹窗）'
            '必须用中和器包裹整块区域');
    // 关键不变式：中和器必须在 LayoutBuilder 外层——内层 constraints 才是真实视口、
    // WebView 与嵌套弹窗共用同一净缩放=1 坐标系。若错放进 LayoutBuilder 内层只中和
    // 局部，会重蹈被撤销的 HibikiNativeScale 坐标错位坑。锚点用代码形态 child:
    // LayoutBuilder（注释里的「LayoutBuilder」字样不带 child: 前缀，不会误命中）。
    expect(
      src.indexOf('HibikiAppUiScaleNeutralizer') <
          src.indexOf('child: LayoutBuilder'),
      isTrue,
      reason: '中和器必须包在 LayoutBuilder 外层（净缩放=1 的真实视口坐标系）',
    );
  });

  test('popup_dictionary_page 整页用中和器包裹 _buildOuterContainer', () {
    final String src =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: '弹窗词典窗口经 popup_main 套了 HibikiAppUiScale，'
            '其 DictionaryPopupWebView 必须用中和器包裹');
    // 中和器必须包住整块 _buildOuterContainer（透明关闭遮罩+卡片+嵌套层同坐标系）。
    expect(
      src.indexOf('HibikiAppUiScaleNeutralizer') <
          src.indexOf('child: _buildOuterContainer'),
      isTrue,
      reason: '中和器必须包裹 _buildOuterContainer 整块（同坐标系）',
    );
  });
}
